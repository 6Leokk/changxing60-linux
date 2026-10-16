#!/bin/bash
# Did the dummyphy DTB fix actually give the box its USB back?  One command, one verdict.
#
# The question this answers is narrow on purpose: after `tools/changxing60-dtb-fix.sh` wrote the 9 bytes and
# the box rebooted into OpenWrt, is there a UDC and a gadget again?  Everything the answer depends on
# is a file in sysfs or a line in dmesg, so this collects both and then judges.
#
#   tools/changxing60-verify-usb.sh              # one pass
#   tools/changxing60-verify-usb.sh --wait       # retry until the box answers (short timeouts, 5 s apart)
#
# Two traps this is written around (docs/changxing60/access.md §5.1):
#   * a *failed* ssh to 192.168.77.1 proves nothing -- the host's OpenClash TUN hijacks that route and
#     answers "Connection closed by 192.168.77.1 port 22".  So the box counts as reachable only when
#     `uname -r` comes back, never when a connection merely opened.
#   * the root password on this rootfs is EMPTY, so plain ssh in BatchMode (no key) cannot log in;
#     sshpass is tried second.  Either path is fine, neither is assumed.
set -uo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/.." && pwd)
ADB=${ADB:-/mnt/c/platform-tools/adb.exe}
WAIT=0
[ "${1:-}" = "--wait" ] && WAIT=1
CANDS=(192.168.77.1 fd96:b832:c98b::1)
OPTS=(-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=5)
OUT=${OUT:-$ROOT/work/verify-usb-$(date +%Y%m%d-%H%M)}

say() { echo "[verify] $*"; }

run() { # run HOST CMD  -- key first, then the empty-password path
    local h=$1; shift
    timeout 12 ssh -o BatchMode=yes "${OPTS[@]}" "root@$h" "$@" 2>/dev/null && return 0
    timeout 15 sshpass -p '' ssh -o PubkeyAuthentication=no -o PreferredAuthentications=password \
        "${OPTS[@]}" "root@$h" "$@" 2>/dev/null
}

find_host() {
    local h
    for h in "${CANDS[@]}"; do
        [ -n "$(run "$h" 'uname -r')" ] && { HOST=$h; return 0; }
    done
    return 1
}

usb_electrical() {   # the only signal a route cannot fake
    [ -n "$("$ADB" devices 2>/dev/null | sed -n '2,$p' | grep -v '^$')" ] && return 0
    /mnt/c/Windows/System32/WindowsPowerShell/v1.0/powershell.exe -NoProfile -Command \
        "(Get-PnpDevice -PresentOnly | Where-Object { \$_.InstanceId -like '*VID_1D6B*PID_A4A3*' -or \$_.FriendlyName -like '*changxing60*' }).Count" \
        2>/dev/null | tr -d '\r' | grep -qv '^0$'
}

if [ "$WAIT" = 1 ]; then
    say "waiting for the box (USB signal first, then ssh; 30 tries x 5 s)"
    for _ in $(seq 30); do
        usb_electrical && { say "gadget electrically present"; break; }
        sleep 5
    done
    for _ in $(seq 12); do
        find_host && break
        sleep 5
    done
fi

find_host || { say "unreachable over ssh (${CANDS[*]}); also check: $ADB devices"; exit 1; }
mkdir -p "$OUT"
say "host=$HOST"

COLLECT=$(
run "$HOST" '
echo "kernel=$(uname -r)"
echo "uptime=$(cut -d. -f1 /proc/uptime)"
echo "slot=$(sed -n "s/.*androidboot.slot_suffix=\([^ ]*\).*/\1/p" /proc/cmdline)"
echo "--- udc"; ls /sys/class/udc 2>&1
echo "--- gadget"; cat /sys/kernel/config/usb_gadget/linux/UDC 2>&1
echo "--- usb0"; ip -br addr show usb0 2>&1; ip -br addr show br-lan 2>&1
echo "--- dummyphy device"; for d in /sys/bus/platform/devices/*dummyphy*; do echo "$d -> $(readlink -f $d/driver 2>/dev/null)"; done 2>&1
echo "--- phy module"; grep -E "^phy_sprd_dummy|^dwc3" /proc/modules 2>&1
echo "--- probe lines"; dmesg 2>/dev/null | grep -E "sprd_dummy_phy_probe|probe of soc:ipa-apb:dummyphy|unable to get usb2|dwc3-sprd 25100000" | tail -12
echo "--- deferred"; cat /sys/kernel/debug/devices_deferred 2>&1 | head -10
echo "--- wan"
ubus call network.interface.wan status 2>/dev/null | grep -E "\"up\"|\"address\"|\"device\"" | head -6
cat /tmp/changxing60-wan-health 2>&1 | tail -3
echo "--- sipa"; grep -E "^sipa_dele" /proc/modules 2>&1; ls /sys/kernel/debug/sipa/ 2>&1 >/dev/null || true
echo "--- diag dumps"; ls -t /root/diag/*.log 2>/dev/null | head -3
echo "--- diag: usb sections of the newest dump"
f=$(ls -t /root/diag/*.log 2>/dev/null | head -1); [ -n "$f" ] && sed -n "/--- udc/,/--- usb gadget/p" "$f" | head -25
echo "--- vendor-modules status"; /opt/changxing60/bin/vendor-modules status 2>&1 | head -25
echo "--- bisect log tail"; tail -8 /root/vendor-bisect.log 2>&1
echo VERIFY-COLLECT-END
' )
echo "$COLLECT" | tee "$OUT/device.txt"

echo
echo "================ verdict ================"
pass=0; fail=0
# section_field NAME -> the line after the matching "--- NAME" header, i.e. that section's value
section_field() { echo "$COLLECT" | sed -n "/^--- $1\$/{n;p;}"; }
chk() { # chk LABEL OK_BOOL [DETAIL]
    if [ "$2" = 1 ]; then echo "  PASS  $1${3:+  [$3]}"; pass=$((pass+1));
    else echo "  FAIL  $1${3:+  [$3]}"; fail=$((fail+1)); fi
}
has() { echo "$COLLECT" | grep -qE "$1" && echo 1 || echo 0; }

chk "kernel is our 5.4 build"        "$(has 'kernel=5\.4\.254-gb50db5b6224c')" "$(echo "$COLLECT" | sed -n 's/^kernel=//p')"
udc=$(section_field udc)
chk "UDC exists"                     "$([ -n "$udc" ] && echo 1 || echo 0)"     "${udc:-empty}"
chk "dummyphy is driver-bound"       "$(has 'dummyphy.*->.*sprd-dummy-phy')"     "$(echo "$COLLECT" | grep -m1 'dummyphy.*->')"
# The two checks that used to sit here grepped dmesg for `sprd_dummy_phy_probe enter` and
# `probe of soc:ipa-apb:dummyphy returned 1`.  Those are debug prints, and on the 2026-10-16 08:12
# boot -- the one that actually fixed USB -- they were absent while everything else was healthy, so
# they reported a working box as broken.  The refcount below says the same thing from state instead
# of from logging: a disabled node leaves phy_sprd_dummy at 0 users (that was the whole symptom),
# and a probed one is held by the glue.
chk "dummy phy module is in use"     "$(has '^phy_sprd_dummy [0-9]+ [1-9]')"     "$(echo "$COLLECT" | sed -n 's/^\(phy_sprd_dummy .*\)$/\1/p')"
chk "dwc3 got its usb2.0 phy"        "$([ "$(has 'unable to get usb2.0 phy')" = 0 ] && echo 1 || echo 0)" \
                                     "no 'unable to get usb2.0 phy' in dmesg"
gudc=$(section_field gadget)
chk "gadget UDC attached"            "$([ -n "$gudc" ] && echo 1 || echo 0)"     "${gudc:-empty}"
# Since the LAN split the USB management address sits on br-lan, and usb0 is one of its ports -- so
# `usb0` itself carries no address and the old `usb0.*192.168.77.1` grep called a working box broken.
chk "usb0 is up (br-lan port)"       "$(has '^usb0[[:space:]]+UP')"              "$(echo "$COLLECT" | grep -m1 '^usb0')"
chk "br-lan holds the management address" "$(has '^br-lan[[:space:]]+UP[[:space:]]+192\.168\.77\.1')" \
                                     "$(echo "$COLLECT" | grep -m1 '^br-lan')"
# the deferred list is the tidiest single piece of evidence: a working boot has nothing deferred, and
# a boot where the phy lookup failed shows 25100000.usb3 sitting in it (or shows nothing at all,
# because the glue gave up rather than deferring -- hence the two-sided check below)
dsec=$(echo "$COLLECT" | sed -n '/^--- deferred$/,/^--- /p' | sed '1d;$d')
chk "usb3 is not stuck deferred"     "$([ "$(echo "$dsec" | grep -c usb3)" = 0 ] && echo 1 || echo 0)" \
                                     "$(echo "$dsec" | grep -m1 usb3 || echo 'none deferred')"
echo "  ---- recorded: $OUT/device.txt"
echo "========================================="
if [ "$fail" = 0 ]; then echo "VERIFY-USB-OK (PASS=$pass)"; else echo "VERIFY-USB-INCOMPLETE (PASS=$pass FAIL=$fail)"; fi
