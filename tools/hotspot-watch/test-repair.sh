#!/bin/bash
# Host-side test for hotspot-watch's repair loop and its last-resort reboot.
#
# What it pins down: the reboot fires only after MAX_REPAIR repairs have failed, only once per boot
# (REBOOT_MARK), is reachable through the CHANGXING60_HOTSPOT_REBOOT_CMD seam, and leaves its reason on the
# ext4. That last one is the 2026-10-16 lesson: after the reboot, /tmp and the logger ring are both
# gone, so "which script restarted the box, and why" cost an hour of ramoops forensics.
#
# It sources hotspot-watch with its main loop stripped, then replaces the world it talks to
# (radio_down / wifi / logger / sleep / reboot) with stubs -- no radio, no ubus, no reboot.
set -uo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
SRC=$HERE/../../rootfs/overlay/opt/changxing60/bin/hotspot-watch
LIB=$(mktemp); T=$(mktemp -d)
trap 'rm -rf "$LIB" "$T"' EXIT

# everything up to (not including) the first statement of the main body is the function library
sed '/^# changxing60-hw writes this at boot/,$d' "$SRC" > "$LIB" || exit 1
[ -s "$LIB" ] || { echo "could not extract the function library from $SRC"; exit 1; }
grep -q '^repair() {' "$LIB" || { echo "$SRC: repair() is not in the extracted library"; exit 1; }

# shellcheck disable=SC1090
. "$LIB"

REBOOTLOG=$T/reboot.log; LOGGERLOG=$T/logger.log
REPAIRS=$T/repairs
REBOOT_MARK=$T/rebooted
WIFI_LOCK=$T/wifi.lock       # never let a test mkdir the real /var/run lock
SELFHEAL=$T/selfheal.log      # the durable note must not be written to the real /root from a test
RESETDUMP=$T/reset_dump
ATCMD=$T/atcmd
WHY=                          # what radio_down() reports; empty = the radio is fine

radio_down() { echo "$WHY"; }
wifi()       { :; }
sleep()      { :; }
logger()     { echo "$*" >> "$LOGGERLOG"; }
cat > "$T/reboot" <<EOS
#!/bin/sh
echo reboot >> "$REBOOTLOG"
EOS
chmod 755 "$T/reboot"
CHANGXING60_HOTSPOT_REBOOT_CMD=$T/reboot

pass=0; fail=0
ok()   { pass=$((pass+1)); printf '  PASS  %s\n' "$1"; }
bad()  { fail=$((fail+1)); printf '  FAIL  %s\n' "$1"; }
want() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (want $3, got $2)"; fi; }

reset() { rm -f "$REBOOTLOG" "$LOGGERLOG" "$REPAIRS" "$REBOOT_MARK" "$SELFHEAL" "${WIFILOG:-}"; rm -rf "$WIFI_LOCK"; WHY=; }
rebooted() { [ -s "$REBOOTLOG" ]; }
noted()    { grep -c -- "$1" "$SELFHEAL" 2>/dev/null || true; }

echo "== the repair ladder"

# 1. An ordinary repair: count goes up, radio comes back, nothing else happens.
reset
WHY="atcmd probe failed (firmware not downloaded)"
repair "$WHY"
want "first repair counts 1" "$(cat "$REPAIRS")" "1"
want "no reboot while repairs remain" "$(rebooted && echo yes || echo no)" "no"
want "nothing written to the durable log" "$([ -e "$SELFHEAL" ] && echo yes || echo no)" "no"

# 2. The radio comes back on the last repair: still no reboot, and no note.
reset
printf '5' > "$REPAIRS"
WHY=""
repair "atcmd probe failed"
want "radio back -> no reboot" "$(rebooted && echo yes || echo no)" "no"
want "radio back -> no durable note" "$([ -e "$SELFHEAL" ] && echo yes || echo no)" "no"
want "the recovery was logged" "$(grep -c 'radio back' "$LOGGERLOG")" "1"

# 3. The last repair fails: reboot, once, with the reason on the ext4.
reset
printf '5' > "$REPAIRS"
WHY="atcmd probe failed (firmware not downloaded)"
repair "$WHY"
want "last repair fails -> reboot" "$(rebooted && echo yes || echo no)" "yes"
want "the per-boot mark is set" "$([ -e "$REBOOT_MARK" ] && echo yes || echo no)" "yes"
want "the reason is on the ext4" \
     "$(noted 'radio still down (atcmd probe failed (firmware not downloaded)) after 6 repairs')" "1"
want "the reason says rebooting" "$(noted ': rebooting')" "1"
want "the line says which script fired" "$(noted ' hotspot-watch: ')" "1"
want "the reason carries the uptime" "$(grep -c ' uptime=[0-9][0-9]* hotspot-watch: ' "$SELFHEAL")" "1"
want "and a timestamp" "$(grep -cE '^[0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2} ' "$SELFHEAL")" "1"

# 4. Already rebooted once this boot: the second failure must not reboot again (no reboot loop).
reset
printf '5' > "$REPAIRS"
touch "$REBOOT_MARK"
WHY="atcmd probe failed"
repair "$WHY"
want "already rebooted -> no second reboot" "$(rebooted && echo yes || echo no)" "no"
want "and it says so in the ring" "$(grep -c 'already rebooted once; leaving it' "$LOGGERLOG")" "1"
want "and does not claim a reboot it did not do" "$([ -e "$SELFHEAL" ] && echo yes || echo no)" "no"

# 5. MAX_REPAIR reached: refuse to keep cycling the radio, and do not reboot.
reset
printf '6' > "$REPAIRS"
WHY="atcmd probe failed"
repair "$WHY"
want "at MAX_REPAIR it refuses" "$(grep -c 'already repaired 6 times; not retrying' "$LOGGERLOG")" "1"
want "and does not reboot" "$(rebooted && echo yes || echo no)" "no"
want "and the counter is not bumped" "$(cat "$REPAIRS")" "6"

# 6. A log that cannot be written must not stop the reboot: the note is evidence, not a gate.
#    (The shell prints the failed redirection on stderr; that write is the case under test.)
reset
printf '5' > "$REPAIRS"
SELFHEAL=$T/no-such-dir/selfheal.log
WHY="atcmd probe failed"
repair "$WHY" 2>/dev/null
want "unwritable log still reboots" "$(rebooted && echo yes || echo no)" "yes"
want "the per-boot mark is still set" "$([ -e "$REBOOT_MARK" ] && echo yes || echo no)" "yes"

echo
echo "== the wifi repair lock (shared with wifi-fix, conflicts.md B3)"

# Record what wifi calls actually happen from here on (the lock tests need to see a skipped one).
WIFILOG=$T/wifi.log
wifi() { echo "wifi $*" >> "$WIFILOG"; }

# 7. An ordinary repair takes the lock and gives it back -- wifi-fix could run right after.
reset
WHY="atcmd probe failed"
repair "$WHY"
want "repair ran" "$(cat "$REPAIRS" 2>/dev/null || echo -)" "1"
want "down/up happened" "$(grep -c '^wifi down' "$WIFILOG")" "1"
want "no lock left held" "$([ -e "$WIFI_LOCK" ] && echo yes || echo no)" "no"

# 8. Lock held by a live process (wifi-fix mid-repair at boot): this cycle is skipped entirely --
#    no second wifi down/up stacked on the first, and the skip must not burn a repair from the
#    MAX_REPAIR ladder, because it is not a failed repair.
#    (the holder is this harness's own shell -- `sleep 300 &` would not do, sleep is stubbed out)
reset
WHY="atcmd probe failed (firmware not downloaded)"
mkdir -p "$WIFI_LOCK"; echo "$$" > "$WIFI_LOCK/pid"
repair "$WHY"
want "live owner -> no wifi call" "$([ -e "$WIFILOG" ] && echo yes || echo no)" "no"
want "live owner -> counter untouched" "$([ -e "$REPAIRS" ] && echo yes || echo no)" "no"
want "live owner -> the skip is in the ring" "$(grep -c 'skipping this cycle' "$LOGGERLOG")" "1"
want "live owner -> someone else's lock stays" "$([ -d "$WIFI_LOCK" ] && echo yes || echo no)" "yes"
rm -rf "$WIFI_LOCK"

# 9. A lock whose owner died (kill -9 of wifi-fix, reboot into old code): stale, taken over.
reset; rm -f "$WIFILOG"
WHY="atcmd probe failed (firmware not downloaded)"
mkdir -p "$WIFI_LOCK"; echo 999999 > "$WIFI_LOCK/pid"
repair "$WHY"
want "stale lock -> the repair proceeds" "$(cat "$REPAIRS" 2>/dev/null || echo -)" "1"
want "stale lock -> down/up happened" "$(grep -c '^wifi down' "$WIFILOG")" "1"
want "stale lock -> released again" "$([ -e "$WIFI_LOCK" ] && echo yes || echo no)" "no"

echo
echo "== $pass passed, $fail failed"
[ "$fail" -eq 0 ]
