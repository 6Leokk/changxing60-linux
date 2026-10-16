#!/bin/sh
# The SMS backend where it will actually live: loaded by rpcd, called over ubus.
#
# tools/sms/rpcd-check.sh drives the plugin through a harness, which is the only way to reach a single method's
# return value - but a harness stands in for rpcd, and rpcd is the part that can fail silently: a plugin in the
# wrong directory is never loaded, a method whose arguments are declared wrong is called with nothing, and a reply
# that does not serialize comes back empty. None of that shows up through the harness. So this installs the plugin
# and its ACL where rpcd looks for them, starts a real ubusd and rpcd, and asks over ubus - the same path the LuCI
# page uses. Built on the same fake AT and the same pool CLI as the other checks; nothing here reaches a modem.
set -u

REPO=${REPO:-/repo}
WORK=${WORK:-/work}
PLUGIN=$REPO/openwrt/overlay/usr/share/rpcd/ucode/mu300sms.uc
ACL=$REPO/openwrt/overlay/usr/share/rpcd/acl.d/luci-app-mu300sms.json
JOB=$REPO/openwrt/overlay/opt/mu300/bin/mu300-sms-job
SMS=$REPO/rootfs/overlay/opt/mu300/bin/mu300-sms
AWK=$REPO/rootfs/overlay/opt/mu300/lib/sms-pdu.awk

for f in "$PLUGIN" "$ACL" "$JOB" "$SMS" "$AWK"; do
    [ -e "$f" ] || { echo "missing $f" >&2; exit 2; }
done
[ -e "$WORK/sim" ] || { echo "missing $WORK/sim (test-rpcd.sh makes it)" >&2; exit 2; }

tmp=$WORK/u
rm -rf "$tmp"
mkdir -p "$tmp/bin" "$tmp/atdir" "$tmp/smsrun" "$tmp/jobroot" "$tmp/tmpdir"
cp "$WORK/sim" "$tmp/sim"
# rpcd runs as root here, but the pool CLI's mktemp still needs a TMPDIR it owns - the image's /tmp is 0755 root
TMPDIR=$tmp/tmpdir; export TMPDIR

cp "$REPO/tools/sms/fake-at" "$tmp/bin/mu300-at"; chmod 755 "$tmp/bin/mu300-at"
printf '#!/bin/sh\nexec sleep "$@"\n' > "$tmp/bin/mu300busybox"; chmod 755 "$tmp/bin/mu300busybox"
# the pool CLI refuses to sync or send without the daemon's fifo, which is what it tests for
mkfifo "$tmp/atdir/cmd"

PATH="$tmp/bin:$PATH";            export PATH
MU300_SMS_BIN=$SMS;               export MU300_SMS_BIN
MU300_SMS_POOL=$tmp/pool;         export MU300_SMS_POOL
MU300_AT_DIR=$tmp/atdir;          export MU300_AT_DIR
MU300_SMS_AWK=$AWK;               export MU300_SMS_AWK
MU300_SMS_RUN=$tmp/smsrun;        export MU300_SMS_RUN
MU300_BUSYBOX=$tmp/bin/mu300busybox; export MU300_BUSYBOX
MU300_SMS_HOOK=$tmp/no-hook;      export MU300_SMS_HOOK
MU300_SMS_FORWARD=$tmp/no-forward; export MU300_SMS_FORWARD
MU300_SMS_JOB_BIN=$JOB;           export MU300_SMS_JOB_BIN
MU300_SMS_JOB_DIR=$tmp/jobroot;   export MU300_SMS_JOB_DIR
FAKE_AT_SIM=$tmp/sim;             export FAKE_AT_SIM
FAKE_AT_SENT=$tmp/sent;           export FAKE_AT_SENT

# the two places rpcd looks: the plugin, and the ACL that says who may call what
mkdir -p /usr/share/rpcd/ucode /usr/share/rpcd/acl.d
cp "$PLUGIN" /usr/share/rpcd/ucode/mu300sms.uc
cp "$ACL" /usr/share/rpcd/acl.d/luci-app-mu300sms.json

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

# call METHOD [JSON]: one ubus call, exactly as the LuCI page's rpc.declare would arrive
call() { ubus -t 10 call mu300sms "$1" "${2:-{\}}"; }

echo "== the plugin is registered where the page can reach it =="
if ! ubus list 2>/dev/null | grep -qx 'mu300sms'; then
    bad "rpcd did not register a mu300sms object" "$(cat /tmp/rpcd.log 2>/dev/null | head -3)"
fi
ok "rpcd registered mu300sms"

out=$(ubus -v list mu300sms 2>&1)
for m in list show send job sync delete; do
    has "the $m method is there" "$out" "\"$m\""
done

echo
echo "== the methods answer over ubus, in the shape the page reads =="
out=$(call list '{"page":1}')
has "list answers the counts" "$out" '"total": 0'

out=$(call sync '{}')
has "sync says it started" "$out" '"started": 1'
_n=0
while [ "$_n" -lt 40 ]; do
    out=$(call list '{"page":1}')
    case "$out" in *'"total": 2'*) break ;; esac
    _n=$((_n + 1)); sleep 1
done
has "and the messages arrived in the pool" "$out" '"total": 2'
has "with a sender" "$out" '+8613800138000'
has "and the long one joined back together" "$out" 'part one of a long message and part two of i'

# the page may only ask for a number: the method declares page as a number, so ubus itself refuses a string
# before the plugin is ever entered (the plugin's own refusal is covered in tools/sms/rpcd-check.sh)
out=$(call list '{"page":"x"}' 2>&1)
has "a page that is not a number never reaches the plugin" "$out" 'Invalid argument'

out=$(call send '{"num":"10086","text":"over ubus"}')
has "a send is accepted" "$out" '"started": 1'
_n=0
while [ "$_n" -lt 40 ]; do
    out=$(call job '{}')
    case "$out" in *'"running": 1'*) _n=$((_n + 1)); sleep 1 ;; *) break ;; esac
done
has "and reports how it went" "$out" '"done": 1'
has "as a success" "$out" '"ok": 1'
has "with the modem's own words" "$out" 'sent'

out=$(call send '{"num":"12a","text":"x"}')
has "the send validation survived the ubus layer" "$out" '"error"'

echo
echo "== the ACL is where rpcd reads it, and it names these methods =="
acl=$(cat /usr/share/rpcd/acl.d/luci-app-mu300sms.json 2>/dev/null)
for m in list show job send sync delete; do
    has "the ACL mentions $m" "$acl" "\"$m\""
done

kill $RPCD $UBUSD 2>/dev/null
# this ran as root (ubusd and rpcd need to), so hand the work directory back or the caller cannot clean it up
[ -n "${HOST_UID:-}" ] && chown -R "$HOST_UID:${HOST_GID:-$HOST_UID}" "$WORK" 2>/dev/null
echo
if [ "$fails" = 0 ]; then echo "all passed"; else echo "$fails FAILED"; fi
exit $((fails > 0))
