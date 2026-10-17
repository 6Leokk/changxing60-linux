#!/bin/bash
# Host-side test for ndp-learn's "bearer is being set up" gate (conflicts.md B4).
#
# The loop below the extraction point flips /proc/sys/net/ipv6/conf/sipa_eth0/{accept_ra,disable_ipv6}
# whenever the bearer has no global address. That condition is ALSO true for the whole two minutes
# of a normal attach, and the flip tears down the IPv6 state the attach is still building -- the
# gate must therefore hold off while the mobile-data attach lock is live or netifd says the wan is
# pending, and must NOT starve the re-solicit when either signal lies (kill -9 left a lock behind,
# no ubusd at all).
#
# Sources the function library (everything before the dispatch `case`), overrides the attach lock
# path, and stubs ubus. No interface, no sysctl, no modem.
set -uo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
SRC=$HERE/../../rootfs/overlay/opt/changxing60/bin/ndp-learn
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT

# library = up to (not including) the argument dispatch
sed -n '/^case /q;p' "$SRC" > "$T/lib"
grep -q '^bearer_setting_up() {' "$T/lib" || { echo "$SRC: bearer_setting_up not in the extracted library"; exit 1; }
grep -q 'ATTACH_LOCK=/var/run/changxing60-attach.lock' "$SRC" || { echo "$SRC: the loop must use the real lock path"; exit 1; }

# shellcheck disable=SC1090
. "$T/lib"
ATTACH_LOCK=$T/attach.lock
ubus() { printf '%s' "${UBUS_JSON-}"; }

pass=0; fail=0
ok()   { pass=$((pass+1)); printf '  PASS  %s\n' "$1"; }
bad()  { fail=$((fail+1)); printf '  FAIL  %s\n' "$1"; }
want() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (want $3, got $2)"; fi; }
holding() { if bearer_setting_up; then echo yes; else echo no; fi; }   # yes = do NOT flip sysctls
reset() { rm -rf "$ATTACH_LOCK"; }

echo "== quiet bearer: the re-solicit stays available"
reset; UBUS_JSON='{"up":true,"pending":false}'
want "no lock, not pending -> flip allowed" "$(holding)" "no"

echo "== netifd says the wan is attaching"
reset; UBUS_JSON='{"up":false,"pending":true}'
want "pending -> hold off" "$(holding)" "yes"
UBUS_JSON='{"up":true,"pending": true}'
want "pending, spaced json too -> hold off" "$(holding)" "yes"

echo "== mobile-data holds the attach lock"
reset; mkdir -p "$ATTACH_LOCK"; echo "$$" > "$ATTACH_LOCK/pid"   # this shell: alive
UBUS_JSON='{"up":true,"pending":false}'
want "live lock owner -> hold off" "$(holding)" "yes"

echo "== signals that must NOT starve the re-solicit"
reset; mkdir -p "$ATTACH_LOCK"; echo 999999 > "$ATTACH_LOCK/pid" # dead owner
want "lock from a kill -9 -> flip allowed" "$(holding)" "no"
reset; mkdir -p "$ATTACH_LOCK"                                   # lock with no pid file
want "lock without a pid file -> flip allowed" "$(holding)" "no"
reset; UBUS_JSON=''
want "no ubus answer (no ubusd) -> flip allowed" "$(holding)" "no"

echo "== lock alive AND pending is the boot case the bug was about"
reset; mkdir -p "$ATTACH_LOCK"; echo "$$" > "$ATTACH_LOCK/pid"; UBUS_JSON='{"pending":true}'
want "both signals -> hold off" "$(holding)" "yes"

echo
echo "== $pass passed, $fail failed"
[ "$fail" -eq 0 ]
