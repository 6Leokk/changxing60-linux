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
# Mirrors the real modem-ioctl: one report line on stdout, the ioctl's status as the exit code. It
# also mirrors modem_run() itself (sprd_modem_loader.c:806): run_state moves only when the ioctl is
# accepted, because a restricted stop on a state it is already in returns -EINVAL and does nothing.
cat > "$T/modem-ioctl" <<'EOS'
#!/bin/sh
echo "$1" >> "$CPLOG_PATH"
echo "modem-ioctl: $1 (modem_run(0, restrict)) ... rc=${CP_EXIT:-0}"
if [ "${CP_EXIT:-0}" = 0 ] && [ -n "$CP_STATE_PATH" ]; then
	case "$1" in
	stop)  printf 'run_state: 0, remote_flag: 0\n' > "$CP_STATE_PATH" ;;
	start) printf 'run_state: 1, remote_flag: 0\n' > "$CP_STATE_PATH" ;;
	esac
fi
exit "${CP_EXIT:-0}"
EOS
chmod 755 "$T/modem-ioctl"
CP_STATE_PATH=$T/cp-state

set +u
# shellcheck disable=SC1090
. "$LIB"
set +eu            # mobile-data's own `set -euo pipefail` rides in with the source; undo it

CPLOG_PATH=$CPLOG; export CPLOG_PATH CP_EXIT=0 CP_STATE_PATH
CP_TOOL=$T/modem-ioctl
CP_DEV=/dev/null            # any character device will do; the preflight only checks that it exists
CP_MARK=$T/cp-mark
CP_STATE=$CP_STATE_PATH      # cp_state() reads the loader's debugfs node out of this
REBOOT_MARK=$T/reboot-mark
SELFHEAL=$T/selfheal.log     # the durable note must not be written to the real /root from a test
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

reset() { rm -f "$CPLOG" "$REBOOTLOG" "$SELFHEAL" "$CP_MARK" "$REBOOT_MARK"; CP_EXIT=0; LINK_UP=1; PROBE_OK=1; AT_STATE=1; MU300_CP_RESET=1; CP_STATE=$CP_STATE_PATH; printf 'run_state: 1, remote_flag: 0\n' > "$CP_STATE_PATH"; }
cps_called()   { [ -s "$CPLOG" ]; }
rebooted()     { [ -s "$REBOOTLOG" ]; }
noted()        { grep -c -- "$1" "$SELFHEAL" 2>/dev/null || true; }

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
# The lever's own telemetry, which is what the 2026-10-16 wedge could not produce: the stop/start
# status and the tool's one-line report, on the ext4, plus the fact that the box healed itself.
want "wedge: the stop's status and report are on the ext4" \
    "$(noted 'cp-reset: stop rc=0 run_state 1->0 out=\[modem-ioctl: stop')" "1"
want "wedge: and so are the start's" "$(noted 'cp-reset: start rc=0 run_state 0->1 out=\[modem-ioctl: start')" "1"
want "wedge: a self-heal without a reboot is recorded as one" \
    "$(noted 'cp-reset: the call came back by itself after ')" "1"

# 4. CP restart spent and still dead, AT silent -> the reboot remains.
reset
AT_STATE=1; PROBE_OK=0; CP_EXIT=1
maybe_reboot $((U-400)) $((U-300)) >/dev/null 2>&1
want "CP restart failed + AT silent -> reboot" "$(rebooted && echo yes || echo no)" "yes"

# 4b. ... and both steps left a reason on the ext4, because the reboot takes /var/run and the logger
#     ring with it. This is the 2026-10-16 gap: the box restarted and nothing said who did it.
want "the CP restart is written to the durable log" \
    "$(noted 'repairs not helping: restarting the CP')" "1"
want "the reboot is written to the durable log" \
    "$(noted 'no answer to AT (at_state=1, cp_restart_spent=1): rebooting')" "1"
want "a CP restart that ends in a reboot says the lever was pulled" \
    "$(noted 'cp-reset: stop rc=1 run_state 1->1 out=\[modem-ioctl: stop')" "1"
want "and that the 90 s wait expired" "$(noted 'cp-reset: the call did not return within ')" "1"
#    A refused stop has to show the CP *not* moving (1->1): that is the whole point of reading the
#    debugfs node, because rc alone cannot tell "accepted, and the CP ignored it" from "never moved".
#    Five lines now: the intent, the stop, the start, the wait, the reboot. Each one has to be
#    attributable on its own, because after a reboot that is all there is.
want "each line says which script fired" "$(noted ' mobile-data: ')" "5"
want "each line carries the uptime, to line it up with dmesg" \
    "$(grep -c ' uptime=[0-9][0-9]* mobile-data: ' "$SELFHEAL" 2>/dev/null)" "5"
want "and a timestamp" "$(grep -cE '^[0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2} ' "$SELFHEAL")" "5"

# 4c. A log that cannot be written must not stop the reboot: the note is evidence, not a gate.
reset
SELFHEAL=$T/no-such-dir/selfheal.log; AT_STATE=1; PROBE_OK=0; CP_EXIT=1
maybe_reboot $((U-400)) $((U-300)) >/dev/null 2>&1
want "unwritable log still reboots" "$(rebooted && echo yes || echo no)" "yes"
SELFHEAL=$T/selfheal.log

# 4d. The distinction the last wedge could not make: an ioctl that *failed* (the lever never moved --
#     the wedge surviving it proves nothing about the lever) versus one that worked and a stack that
#     stayed dead. Both used to be `|| true`d into the volatile ring, which is why the 1100 s -> 1597 s
#     window of 2026-10-16, with no `modem run` line in it, still cannot be attributed.
reset
CP_EXIT=2; AT_STATE=1; PROBE_OK=0
maybe_reboot $((U-400)) $((U-300)) >/dev/null 2>&1
want "a failed stop records its status" "$(noted 'cp-reset: stop rc=2 run_state 1->1 out=\[modem-ioctl: stop')" "1"
want "a failed start records its status" "$(noted 'cp-reset: start rc=2 run_state 1->1 out=\[modem-ioctl: start')" "1"
want "failed CP restart + AT silent -> reboot" "$(rebooted && echo yes || echo no)" "yes"

# 4e. No debugfs node (not mounted, or the loader gone): the note is still written and still says it
#     does not know, rather than quietly claiming the CP moved -- and the reboot still happens.
reset
CP_STATE=$T/no-such-node; AT_STATE=1; PROBE_OK=0; CP_EXIT=1
maybe_reboot $((U-400)) $((U-300)) >/dev/null 2>&1
want "no debugfs node -> the note says unknown" \
    "$(noted 'cp-reset: stop rc=1 run_state ?->? out=\[modem-ioctl: stop')" "1"
want "no debugfs node -> still reboots" "$(rebooted && echo yes || echo no)" "yes"

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

# 9. cp_reset's own preflight: no CP tool, and no modem_control, must both refuse -- and a refusal is
#    itself the answer to "did the lever move", so it goes to the ext4 too. A wedge whose CP restart
#    was refused must never look like one that was never attempted.
reset
( CP_TOOL=$T/does-not-exist; cp_reset ) >/dev/null 2>&1
want "missing CP tool -> refuse" "$?" "1"
want "missing CP tool -> the refusal is on the ext4" \
    "$(noted 'cp-reset refused: .* is not executable')" "1"
reset
ps() { echo " 1 root [kthreadd]"; }
( cp_reset ) >/dev/null 2>&1
want "modem_control absent -> refuse" "$?" "1"
want "modem_control absent -> the refusal is on the ext4" \
    "$(noted 'cp-reset refused: modem_control is not running')" "1"
ps() { echo " 1234 root /vendor/bin/modem_control"; }

echo
echo "== $pass passed, $fail failed"
[ "$fail" -eq 0 ]
