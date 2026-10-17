#!/bin/bash
# Host-side test for wifi-fix: the one-shot startup repair and its lock against hotspot-watch.
#
# Pins down what conflicts.md B3 asked for: an AP that IS beaconing is never touched, a dead AP
# repairs once and releases /var/run/changxing60-wifi.lock, a live lock holder (hotspot-watch mid
# repair) means wifi-fix does nothing at all -- and a lock left by a dead process is taken over,
# so a crashed sibling can never mute the startup repair.
#
# The script under test gets its sysfs existence guards and its lock path rewritten into a temp
# sandbox, and ubus/wifi/logger are PATH stubs. No radio, no hostapd, no system sysfs.
set -uo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
SRC=$HERE/../../rootfs/overlay/opt/changxing60/bin/wifi-fix
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT

BIN=$T/bin; mkdir -p "$BIN"
cat > "$BIN/ubus" <<EOS
#!/bin/sh
printf '{"bssid": "%s", "status": "ENABLED"}\n' "\${UBUS_BSSID-}"
EOS
cat > "$BIN/wifi" <<EOS
#!/bin/sh
echo "wifi \$*" >> "$T/wifi.log"
EOS
cat > "$BIN/logger" <<EOS
#!/bin/sh
echo "\$*" >> "$T/logger.log"
EOS
chmod 755 "$BIN"/*
export PATH="$BIN:$PATH"

# drop the two sysfs existence guards (they test the chip, not the logic) and move the lock
sed -e '/sys\/class/d' \
    -e "s#^WIFI_LOCK=.*#WIFI_LOCK=$T/wifi.lock#" \
    "$SRC" > "$T/wifi-fix" || exit 1
grep -q '^WIFI_LOCK='"$T" "$T/wifi-fix" || { echo "lock path not rewired in $T/wifi-fix"; exit 1; }

pass=0; fail=0
ok()   { pass=$((pass+1)); printf '  PASS  %s\n' "$1"; }
bad()  { fail=$((fail+1)); printf '  FAIL  %s\n' "$1"; }
want() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (want $3, got $2)"; fi; }
calls() { [ -e "$T/wifi.log" ] && tr '\n' ';' < "$T/wifi.log" || echo "none"; }
logs()  { [ -e "$T/logger.log" ] && cat "$T/logger.log" || echo "none"; }
reset() { rm -f "$T/wifi.log" "$T/logger.log"; rm -rf "$T/wifi.lock"; }

echo "== a healthy AP is left alone"
reset; UBUS_BSSID=5c:4d:bf:xx:xx:xx sh "$T/wifi-fix"
want "no wifi calls"        "$(calls)" "none"
want "no lock left behind"  "$([ -e "$T/wifi.lock" ] && echo yes || echo no)" "no"
want "no repair logged"     "$(logs)" "none"

echo "== a dead AP is repaired once, lock released"
reset; UBUS_BSSID= sh "$T/wifi-fix"
want "down/up happened"     "$(calls)" "wifi down;wifi up;"
want "the repair was logged" "$(grep -c 'AP not beaconing (bssid=missing), restarting' "$T/logger.log")" "1"
want "no lock left held"    "$([ -e "$T/wifi.lock" ] && echo yes || echo no)" "no"
reset; UBUS_BSSID=00:00:00:00:00:00 sh "$T/wifi-fix"
want "an all-zero bssid is the same repair" "$(calls)" "wifi down;wifi up;"

echo "== a live lock holder (hotspot-watch) wins; wifi-fix does nothing"
reset; mkdir -p "$T/wifi.lock"; echo "$$" > "$T/wifi.lock/pid"   # this shell is alive
UBUS_BSSID= sh "$T/wifi-fix"
want "no wifi call while the lock is held" "$(calls)" "none"
want "the skip is reported"                "$(grep -c 'repair already runs' "$T/logger.log")" "1"
want "someone else's lock is untouched"    "$(cat "$T/wifi.lock/pid")" "$$"

echo "== a lock whose owner died is taken over"
reset; mkdir -p "$T/wifi.lock"; echo 999999 > "$T/wifi.lock/pid"
UBUS_BSSID= sh "$T/wifi-fix"
want "the repair proceeds"     "$(calls)" "wifi down;wifi up;"
want "the lock is gone after"  "$([ -e "$T/wifi.lock" ] && echo yes || echo no)" "no"

echo "== a zero bssid counts as dead even though hostapd says ENABLED"
reset; UBUS_BSSID=00:00:00:00:00:00 sh "$T/wifi-fix"
want "repaired" "$(grep -c 'bssid=00:00:00:00:00:00' "$T/logger.log")" "1"

echo
echo "== $pass passed, $fail failed"
[ "$fail" -eq 0 ]
