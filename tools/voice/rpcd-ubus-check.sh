#!/bin/sh
# The voice backend where it will actually live: loaded by rpcd, called over ubus.
#
# tools/voice/rpcd-check.sh drives the plugin through a harness, which is the only way to reach a single method's
# return value - but a harness stands in for rpcd, and rpcd is the part that can fail silently: a plugin in the
# wrong directory is never loaded, a method whose arguments are declared wrong is called with nothing, and a
# reply that does not serialize comes back empty. None of that shows up through the harness. So this installs
# the plugin and its ACL where rpcd looks for them, starts a real ubusd and rpcd, and asks over ubus - the same
# path the call page uses. Built on the same fake AT and the same voice CLI as the other checks; nothing here
# reaches a modem.
set -u

REPO=${REPO:-/repo}
WORK=${WORK:-/work}
PLUGIN=$REPO/openwrt/overlay/usr/share/rpcd/ucode/changxing60voice.uc
ACL=$REPO/openwrt/overlay/usr/share/rpcd/acl.d/luci-app-changxing60voice.json
JOB=$REPO/openwrt/overlay/opt/changxing60/bin/changxing60-voice-job
VOICE=$REPO/rootfs/overlay/opt/changxing60/bin/changxing60-voice
LIB=$REPO/rootfs/overlay/opt/changxing60/lib/voice.sh
FAKE=$REPO/tools/voice/fake-at

for f in "$PLUGIN" "$ACL" "$JOB" "$VOICE" "$LIB" "$FAKE"; do
    [ -e "$f" ] || { echo "missing $f" >&2; exit 2; }
done

tmp=$WORK/u
rm -rf "$tmp"
mkdir -p "$tmp/bin" "$tmp/run" "$tmp/etc" "$tmp/jobroot" "$tmp/atdir" "$tmp/tmpdir"
# rpcd runs as root here, but the voice CLI's helpers still need a TMPDIR they can write: the image's /tmp is
# 0755 root. (The voice CLI makes no temp files, but its sed/awk children may, through some implementations.)
TMPDIR=$tmp/tmpdir; export TMPDIR

cp "$FAKE" "$tmp/bin/changxing60-at"; chmod 755 "$tmp/bin/changxing60-at"

PATH="$tmp/bin:$PATH";             export PATH
CHANGXING60_VOICE_BIN=$VOICE;           export CHANGXING60_VOICE_BIN
CHANGXING60_VOICE_LIB=$LIB;             export CHANGXING60_VOICE_LIB
CHANGXING60_AT_BIN=$tmp/bin/changxing60-at; export CHANGXING60_AT_BIN
CHANGXING60_AT_DIR=$tmp/atdir;          export CHANGXING60_AT_DIR
CHANGXING60_VOICE_DIR=$tmp/run;         export CHANGXING60_VOICE_DIR
CHANGXING60_VOICE_STATE=$tmp/run/state; export CHANGXING60_VOICE_STATE
CHANGXING60_VOICE_LOG=$tmp/etc/call-log; export CHANGXING60_VOICE_LOG
CHANGXING60_VOICE_CONTACTS=$tmp/etc/contacts; export CHANGXING60_VOICE_CONTACTS
CHANGXING60_VOICE_JOB_BIN=$JOB;         export CHANGXING60_VOICE_JOB_BIN
CHANGXING60_VOICE_JOB_DIR=$tmp/jobroot; export CHANGXING60_VOICE_JOB_DIR
FAKE_AT_DIALED=$tmp/dialed;             export FAKE_AT_DIALED

# the two places rpcd looks: the plugin, and the ACL that says who may call what
mkdir -p /usr/share/rpcd/ucode /usr/share/rpcd/acl.d
cp "$PLUGIN" /usr/share/rpcd/ucode/changxing60voice.uc
cp "$ACL" /usr/share/rpcd/acl.d/luci-app-changxing60voice.json

fails=0
ok()  { printf 'ok   %s\n' "$1"; }
bad() { printf 'FAIL %s\n' "$1"; [ $# -gt 1 ] && printf '     %s\n' "$2"; fails=$((fails+1)); }
has() { case "$2" in *"$3"*) ok "$1" ;; *) bad "$1" "[$2] does not hold [$3]" ;; esac; }

mkdir -p /var/run/ubus
ubusd >/tmp/ubusd.log 2>&1 &
UBUSD=$!
sleep 1
# no config file: rpcd's defaults are what a stock OpenWrt uses, and it must come up without one
rpcd >/tmp/rpcd.log 2>&1 &
RPCD=$!
sleep 2

# call METHOD [JSON]: one ubus call, exactly as the call page's rpc.declare would arrive
call() { ubus -t 10 call changxing60voice "$1" "${2:-{\}}"; }

echo "== the plugin is registered where the page can reach it =="
if ! ubus list 2>/dev/null | grep -qx 'changxing60voice'; then
    bad "rpcd did not register a changxing60voice object" "$(head -3 /tmp/rpcd.log 2>/dev/null)"
fi
ok "rpcd registered changxing60voice"

out=$(ubus -v list changxing60voice 2>&1)
for m in state dial dialjob answer hangup dtmf mute log logclear contacts contact_add contact_del; do
    has "the $m method is there" "$out" "\"$m\""
done

echo
echo "== the methods answer over ubus, in the shape the page reads =="
out=$(call state '{}')
has "state answers" "$out" '"state": "idle"'

out=$(call dialjob '{}')
has "dialjob answers" "$out" '"none": 1'

# the page may only ask for a number: the method declares num as a string, so ubus itself refuses anything
# else before the plugin is ever entered (the plugin's own refusals are covered in tools/voice/rpcd-check.sh)
out=$(call dial '{"num":123}' 2>&1)
has "a num that is not a string never reaches the plugin" "$out" 'Invalid argument'

out=$(call dial '{"num":"12a"}')
has "the validation survived the ubus layer" "$out" 'may only contain digits'

echo
echo "== a dial goes through over ubus, and reports how it went =="
out=$(call dial '{"num":"+8613800138000"}')
has "the dial is accepted" "$out" '"started": 1'
_n=0
while [ "$_n" -lt 40 ]; do
    out=$(call dialjob '{}')
    case "$out" in *'"running": 1'*) _n=$((_n + 1)); sleep 1 ;; *) break ;; esac
done
has "and reports how it went" "$out" '"done": 1'
has "as a success" "$out" '"ok": 1'
has "with the CLI's own word for it" "$out" 'dialling'

# the state file was never written by any of this: only changxing60-voiced writes it, and it is not running
has "the state file stayed the daemon's" "$(call state '{}')" '"state": "idle"'

echo
echo "== the ACL is where rpcd reads it, and it names these methods =="
acl=$(cat /usr/share/rpcd/acl.d/luci-app-changxing60voice.json 2>/dev/null)
for m in state dial dialjob answer hangup dtmf mute log logclear contacts contact_add contact_del; do
    has "the ACL mentions $m" "$acl" "\"$m\""
done

kill $RPCD $UBUSD 2>/dev/null
# this ran as root (ubusd and rpcd need to), so hand the work directory back or the caller cannot clean it up
[ -n "${HOST_UID:-}" ] && chown -R "$HOST_UID:${HOST_GID:-$HOST_UID}" "$WORK" 2>/dev/null
echo
if [ "$fails" = 0 ]; then echo "all passed"; else echo "$fails FAILED"; fi
exit $((fails > 0))
