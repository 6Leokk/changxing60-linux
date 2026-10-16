#!/bin/bash
# Host-side test for mobile-data's recovery ladder (reboot -> CP restart).
#
# What it pins down: when the data call has been unusable for MU300_WAN_REBOOT_AFTER seconds and
# repairs are not helping, an *unspent* CP restart is tried first, and the reboot only remains for
# when that restart was already spent (or is disabled). cp_reset itself, the "a healthy call ends
# the outage" clearing of CP_MARK, and the MU300_CP_RESET=0 fallback are all exercised.
#
# It sources mobile-data with the final dispatch case stripped, then replaces the world it talks to
# (link_up / probe_ok / at_state / ps / sleep) with stubs -- no device, no /dev/modem, no reboot.
set -uo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
SRC=$HERE/../../rootfs/overlay/opt/mu300/bin/mobile-data
LIB=$(mktemp); T=$(mktemp -d)
trap 'rm -rf "$LIB" "$T"' EXIT

sed '/^case "${1:-status}" in/,$d' "$SRC" > "$LIB" || exit 1
[ -s "$LIB" ] || { echo "could not extract the function library from $SRC"; exit 1; }

# --- stub world ---------------------------------------------------------------------------------
CPLOG=$T/cp.log; REBOOTLOG=$T/reboot.log
cat > "$T/modem-ioctl" <<'EOS'
#!/bin/sh
echo "$1" >> "$CPLOG_PATH"
exit "${CP_EXIT:-0}"
EOS
chmod 755 "$T/modem-ioctl"

set +u
# shellcheck disable=SC1090
. "$LIB"
set +eu            # mobile-data's own `set -euo pipefail` rides in with the source; undo it

CPLOG_PATH=$CPLOG; export CPLOG_PATH CP_EXIT=0
CP_TOOL=$T/modem-ioctl
CP_DEV=/dev/null            # any character device will do; the preflight only checks that it exists
CP_MARK=$T/cp-mark
REBOOT_MARK=$T/reboot-mark
# a script, not a command line: MU300_REBOOT_CMD is expanded unquoted, so an embedded ">>" would
# be passed to the command as an argument instead of becoming a redirection.
cat > "$T/reboot" <<EOS
#!/bin/sh
echo reboot >> "$REBOOTLOG"
EOS
chmod 755 "$T/reboot"
MU300_REBOOT_CMD=$T/reboot

LINK_UP=1; PROBE_OK=1; AT_STATE=1
link_up()  { [ "$LINK_UP"  = 1 ]; }
probe_ok() { [ "$PROBE_OK" = 1 ]; }
at_state() { return "$AT_STATE"; }          # 0 = answered, 1 = silence, 2 = must not be asked
ps()       { echo " 1234 root /vendor/bin/modem_control"; }
sleep()    { :; }                            # cp_reset's 90 s wait must not slow the test down

read -r U _ < /proc/uptime; U=${U%.*}

pass=0; fail=0
ok()   { pass=$((pass+1)); printf '  PASS  %s\n' "$1"; }
bad()  { fail=$((fail+1)); printf '  FAIL  %s\n' "$1"; }
want() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (want $3, got $2)"; fi; }

reset() { rm -f "$CPLOG" "$REBOOTLOG" "$CP_MARK" "$REBOOT_MARK"; CP_EXIT=0; LINK_UP=1; PROBE_OK=1; AT_STATE=1; MU300_CP_RESET=1; }
cps_called()   { [ -s "$CPLOG" ]; }
rebooted()     { [ -s "$REBOOTLOG" ]; }

echo "== the escalation ladder"

# 1. Nothing to escalate while the call is fine.
reset
set_health ok
want "a healthy call clears CP_MARK" "$([ -e "$CP_MARK" ] && echo yes || echo no)" "no"
touch "$CP_MARK"; set_health ok
want "a later healthy call clears a spent CP restart" "$([ -e "$CP_MARK" ] && echo yes || echo no)" "no"

# 2. Guards: no bad_clock, and a repair still in flight, must not escalate.
reset
maybe_reboot 0 0 >/dev/null 2>&1
want "bad_clock 0 -> no CP restart" "$(cps_called && echo yes || echo no)" "no"
maybe_reboot $((U-400)) $((U-30)) >/dev/null 2>&1
want "repair <60 s old -> no CP restart" "$(cps_called && echo yes || echo no)" "no"

# 3. The wedge that the old path could never fix: address present, AT must not be asked,
#    bad >300 s, repair long done -> CP restart is spent and the call comes back.
reset
AT_STATE=2
PROBE_OK=0
( PROBE_OK=1; maybe_reboot $((U-400)) $((U-300)) ) >/dev/null 2>&1
want "wedge: CP stop+start issued" "$(cat "$CPLOG" 2>/dev/null | tr '\n' ',')" "stop,start,"
want "wedge: CP_MARK now set" "$([ -e "$CP_MARK" ] && echo yes || echo no)" "yes"
want "wedge: no reboot (CP restart worked)" "$(rebooted && echo yes || echo no)" "no"

# 4. CP restart spent and still dead, AT silent -> the reboot remains.
reset
AT_STATE=1; PROBE_OK=0; CP_EXIT=1
maybe_reboot $((U-400)) $((U-300)) >/dev/null 2>&1
want "CP restart failed + AT silent -> reboot" "$(rebooted && echo yes || echo no)" "yes"

# 5. The new case: CP restart spent, AT must not be asked (address still up) -> escalate anyway.
#    The old code vetoed here, so a wedge that keeps its address could never reboot either.
reset
AT_STATE=2; PROBE_OK=0; CP_EXIT=1
maybe_reboot $((U-400)) $((U-300)) >/dev/null 2>&1
want "CP restart failed + AT n/a -> reboot (no infinite watch)" "$(rebooted && echo yes || echo no)" "yes"

# 6. Already spent marker: no second CP restart this outage, straight to the reboot.
reset
touch "$CP_MARK"; AT_STATE=1; PROBE_OK=0
maybe_reboot $((U-400)) $((U-300)) >/dev/null 2>&1
want "spent CP restart -> not retried" "$(cps_called && echo yes || echo no)" "no"
want "spent CP restart + AT silent -> reboot" "$(rebooted && echo yes || echo no)" "yes"

# 7. A live AT port with a dead call: still restart the CP (nothing else could fix it), and the
#    modem answering the reboot probe must never itself trigger a reboot.
reset
AT_STATE=0
( PROBE_OK=1; maybe_reboot $((U-400)) $((U-300)) ) >/dev/null 2>&1
want "AT answers, call dead -> CP restart still tried" "$(cps_called && echo yes || echo no)" "yes"
reset
AT_STATE=0; CP_EXIT=1
maybe_reboot $((U-400)) $((U-300)) >/dev/null 2>&1
want "AT answers + CP restart failed -> no reboot" "$(rebooted && echo yes || echo no)" "no"

# 8. MU300_CP_RESET=0 restores the old reboot-only behaviour exactly.
reset
MU300_CP_RESET=0; AT_STATE=2; PROBE_OK=0
maybe_reboot $((U-400)) $((U-300)) >/dev/null 2>&1
want "CP reset disabled -> no CP restart" "$(cps_called && echo yes || echo no)" "no"
want "CP reset disabled + AT n/a -> no reboot (old behaviour)" "$(rebooted && echo yes || echo no)" "no"
reset
MU300_CP_RESET=0; AT_STATE=1
maybe_reboot $((U-400)) $((U-300)) >/dev/null 2>&1
want "CP reset disabled + AT silent -> reboot (old behaviour)" "$(rebooted && echo yes || echo no)" "yes"

# 9. cp_reset's own preflight: no CP tool, and no modem_control, must both refuse.
reset
( CP_TOOL=$T/does-not-exist; cp_reset ) >/dev/null 2>&1
want "missing CP tool -> refuse" "$?" "1"
reset
ps() { echo " 1 root [kthreadd]"; }
( cp_reset ) >/dev/null 2>&1
want "modem_control absent -> refuse" "$?" "1"
ps() { echo " 1234 root /vendor/bin/modem_control"; }

echo
echo "== $pass passed, $fail failed"
[ "$fail" -eq 0 ]
