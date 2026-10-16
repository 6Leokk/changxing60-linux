#!/bin/sh
# The network backend where it will actually live: loaded by rpcd, called over ubus.
#
# tools/net/test-rpcd.sh stage 1 drives the plugin through a harness, which is the only way to reach
# a single method's exact return value - but a harness stands in for rpcd, and rpcd is the part that
# can fail silently: a ucode plugin that does not compile loads as NOTHING AT ALL and ubus list simply
# does not mention it, so the page renders with every control dead and nothing errors. So this
# installs the plugin and its ACL where rpcd looks for them, starts a real ubusd and rpcd, and asks
# over ubus - the same path the LuCI page uses. Same stubbed collector as stage 1
# (tools/net/fake-net-status); nothing here reaches a modem, and nothing here reaches a device.
#
# This script is the one that would have caught the two ways this panel dies silently:
#   * the plugin failing to compile (ubus never mentions changxing60net);
#   * the ACL not granting what the page calls (every call comes back "Invalid object" /
#     "Permission denied" for a logged-in session).
set -u

REPO=${REPO:-/repo}
WORK=${WORK:-/work}
PLUGIN=$REPO/openwrt/overlay/usr/share/rpcd/ucode/changxing60net.uc
ACL=$REPO/openwrt/overlay/usr/share/rpcd/acl.d/luci-app-changxing60net.json
STUB=$WORK/bin/changxing60-net-status

for f in "$PLUGIN" "$ACL" "$STUB"; do
	[ -e "$f" ] || { echo "missing $f" >&2; exit 2; }
done

tmp=$WORK/u
rm -rf "$tmp"

fails=0
ok()  { printf 'ok   %s\n' "$1"; }
bad() { printf 'FAIL %s\n' "$1"; [ $# -gt 1 ] && printf '     %s\n' "$2"; fails=$((fails+1)); }
has() { case "$2" in *"$3"*) ok "$1" ;; *) bad "$1" "[$2] does not hold [$3]" ;; esac }
lacks(){ case "$2" in *"$3"*) bad "$1" "[$2] holds [$3]" ;; *) ok "$1" ;; esac; }

# the two places rpcd looks: the plugin, and the ACL that says who may call what
mkdir -p /usr/share/rpcd/ucode /usr/share/rpcd/acl.d
cp "$PLUGIN" /usr/share/rpcd/ucode/changxing60net.uc
cp "$ACL" /usr/share/rpcd/acl.d/luci-app-changxing60net.json

# the collector the backend runs: the stub, at the path the backend's default points to
mkdir -p /opt/changxing60/bin
cp "$STUB" /opt/changxing60/bin/changxing60-net-status
chmod 755 /opt/changxing60/bin/changxing60-net-status

# stage replies for the stub under /work (the same files the stub reads)
GOOD='{"ts":1760000000,"time":"2026-10-16T12:00:00Z","cfun":1,"reg":{"stat":1,"tac":"400460","cid":"011A7000","act":11},"reg5":{"stat":1,"tac":"400460","cid":"5011A7000","act":11},"ops":{"name":null,"plmn":"46000","act":11},"eng_skip":null,"serving":{"lte":null,"nr":{"rat":"nr","band":41,"arfcn":504990,"pci":274,"rsrp":-88.5,"rsrq":-9.6,"sinr":8.0,"bw_mhz":20,"gnb":"123456","cid":"5011A7000","ul_mcs":null,"dl_mcs":null,"ul_bler":null,"dl_bler":null}},"sig":{"source":"nr","rsrp":-88.5,"rsrq":-9.6,"sinr":8.0,"rssi":null},"csq":{"rssi":null,"ber":null},"cesq":{"rsrp":-88.5,"rsrq":-9.6},"neighbours":{"lte":[],"nr":[{"rat":"nr","band":41,"arfcn":504990,"pci":100,"rsrp":-100.2,"rsrq":null,"sinr":null}]},"traffic":{"iface":"sipa_eth0","present":1,"operstate":"up","rx_bytes":257131423,"tx_bytes":26584089,"rx_packets":288588,"tx_packets":143608}}'
stage() { printf '%s\n' "$1" > "$WORK/case.json"; printf '%s\n' "$2" > "$WORK/case.rc"; }

mkdir -p /var/run/ubus
ubusd >/tmp/ubusd.log 2>&1 &
UBUSD=$!
sleep 1
rpcd >/tmp/rpcd.log 2>&1 &
RPCD=$!
sleep 2

echo "== the plugin is registered where the page can reach it =="
if ! ubus list 2>/dev/null | grep -qx 'changxing60net'; then
	bad "rpcd did not register a changxing60net object" "$(head -3 /tmp/rpcd.log 2>/dev/null)"
fi
ok "rpcd registered changxing60net"

out=$(ubus -v list changxing60net 2>&1)
for m in status fast; do
	has "the $m method is there" "$out" "\"$m\""
done

echo
echo "== the methods answer over ubus, in the shape the page reads =="
stage "$GOOD" 0
out=$(ubus -t 10 call changxing60net status '{}' 2>&1)
has "status answers ok 1" "$out" '"ok": 1'
has "the snapshot came through" "$out" '"cfun": 1'
# the null rule, over the ubus hop: an unanswered field must arrive as a JSON null, not a 0
has "an unanswered rssi is a JSON null" "$out" '"rssi": null'
lacks "no unanswered field became a 0" "$out" '"rssi": 0'
has "the operator PLMN is a string" "$out" '"plmn": "46000"'
has "the neighbours' null rsrq stayed null" "$out" '"rsrq": null'
has "and the answered rsrp is a number" "$out" '"rsrp": -88.5'

# fast: the argument list the stub was handed is the proof the tier was selected
ubus -t 10 call changxing60net fast '{}' >/dev/null 2>&1
has "fast asks the collector --fast --json" "$(cat "$WORK/dialed" 2>/dev/null)" '--fast --json'
stage "$GOOD" 0
ubus -t 10 call changxing60net status '{"fast":true}' >/dev/null 2>&1
has "status with fast:true asks the fast tier" "$(cat "$WORK/dialed" 2>/dev/null)" '--fast --json'

echo
echo "== the error round is the collector's own sentence, over ubus =="
stage '{"ts":1760000000,"time":"2026-10-16T12:00:00Z","busy":1,"error":"AT channel was busy the whole round (another client holds it)"}' 1
out=$(ubus -t 10 call changxing60net status '{}' 2>&1)
has "a refused round answers ok 0" "$out" '"ok": 0'
has "with the collector's words" "$out" 'AT channel was busy'
has "and the busy bit" "$out" '"busy": 1'
lacks "and no snapshot was invented" "$out" '"snap"'

echo
echo "== the ACL is where rpcd reads it, and it names these methods =="
acl=$(cat /usr/share/rpcd/acl.d/luci-app-changxing60net.json 2>/dev/null)
for m in status fast; do
	has "the ACL mentions $m" "$acl" "\"$m\""
done

kill $RPCD $UBUSD 2>/dev/null
# this ran as root (ubusd and rpcd need to), so hand the work directory back or the caller cannot clean it up
[ -n "${HOST_UID:-}" ] && chown -R "$HOST_UID:${HOST_GID:-$HOST_UID}" "$WORK" 2>/dev/null
echo
if [ "$fails" = 0 ]; then echo "all passed"; else echo "$fails FAILED"; fi
exit $((fails > 0))
