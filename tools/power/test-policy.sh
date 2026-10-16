#!/bin/bash
# Host-side check for the CPU-governor half of the power policy.
#
# power-policy is a shell script against /sys, which does not exist off the device, so it takes its
# three paths from the environment and this points them at a fake tree. The script under test is the
# real one -- not a copy -- so a change to the policy is a change to what is checked here.
#
# The failure this is here to catch: a policy that has no `schedutil` (the big cluster on some
# vendor kernels only offers performance/powersave) must be left exactly as it was, and the ones that
# do have it must be switched. Writing a governor a policy does not offer is a write that "succeeds"
# and changes nothing, which is the silent kind.
#
#   usage: tools/power/test-policy.sh        (exit 0 = all checks passed)
set -u
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
policy="$here/../../rootfs/overlay/opt/mu300/bin/power-policy"
fails=0

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

check() { # check GOT WANT WHAT
	if [ "$1" = "$2" ]; then echo "ok   $3 ($1)"
	else echo "FAIL $3: got '$1' want '$2'"; fails=$((fails + 1)); fi
}

# A policy dir with GOVERNORS offered, currently on CURRENT.
mkpolicy() { # mkpolicy NAME GOVERNORS CURRENT
	mkdir -p "$tmp/cpufreq/$1"
	printf '%s\n' "$2" > "$tmp/cpufreq/$1/scaling_available_governors"
	printf '%s\n' "$3" > "$tmp/cpufreq/$1/scaling_governor"
	printf '400000\n' > "$tmp/cpufreq/$1/scaling_min_freq"
	printf '1800000\n' > "$tmp/cpufreq/$1/scaling_max_freq"
	printf '1800000\n' > "$tmp/cpufreq/$1/cpuinfo_max_freq"
}
gov() { cat "$tmp/cpufreq/$1/scaling_governor"; }

run() { # run [args...]  -- with the fake tree in place
	env MU300_POWER_CPUFREQ="$tmp/cpufreq" MU300_POWER_THERMAL="$tmp/thermal" \
		MU300_POWER_NETDEV="$tmp/net" MU300_PANEL_IDLE_FILE="$tmp/panel-idle" \
		MU300_POWER_CONF="$tmp/power.conf" \
		sh "$policy" "$@" 2>&1
}

mkdir -p "$tmp/thermal" "$tmp/net"
printf '43000\n' > "$tmp/thermal/thermal_zone0.temp" 2>/dev/null || {
	mkdir -p "$tmp/thermal/thermal_zone0"; printf '43000\n' > "$tmp/thermal/thermal_zone0/temp"; }

echo "== a policy that offers the governor is switched, one that does not is left alone =="
mkpolicy policy0 "schedutil performance powersave" performance
mkpolicy policy4 "performance powersave" performance
out=$(run apply); rc=$?
check "$rc" 0 "apply exits 0"
check "$(gov policy0)" "schedutil" "policy0 switched"
check "$(gov policy4)" "performance" "policy4 left alone (does not offer it)"
case "$out" in *"on 1 policy"*) echo "ok   apply counted only the policies it changed";;
*) echo "FAIL apply count: $out"; fails=$((fails + 1));; esac

echo
echo "== the configured governor is the one applied =="
printf 'governor=performance\n' > "$tmp/power.conf"
run apply >/dev/null
check "$(gov policy0)" "performance" "config governor honoured"
check "$(gov policy4)" "performance" "and applied where it exists"

echo
echo "== a governor nothing offers is reported, not silently ignored =="
printf 'governor=ondemand\n' > "$tmp/power.conf"
out=$(run apply); rc=$?
check "$rc" 1 "apply exits nonzero"
case "$out" in *"not applied"*) echo "ok   says so";;
*) echo "FAIL silent failure: $out"; fails=$((fails + 1));; esac

echo
echo "== no cpufreq at all is a clean message, not a crash =="
rm -rf "$tmp/cpufreq"
out=$(run status); rc=$?
check "$rc" 0 "status exits 0"
case "$out" in *"no cpufreq"*) echo "ok   status says there is none";;
*) echo "FAIL status on a kernel without cpufreq: $out"; fails=$((fails + 1));; esac
out=$(run apply)
case "$out" in *"not applied"*) echo "ok   apply says so too";;
*) echo "FAIL apply on a kernel without cpufreq: $out"; fails=$((fails + 1));; esac

echo
echo "== status reads the idle setting where the screen program will look =="
printf '300\n' > "$tmp/panel-idle"
out=$(run status)
case "$out" in *"panel idle  300 s"*) echo "ok   idle setting shown";;
*) echo "FAIL idle setting not shown: $out"; fails=$((fails + 1));; esac
rm -f "$tmp/panel-idle"
out=$(run status)
case "$out" in *"panel idle  off"*) echo "ok   absent idle file reads as off";;
*) echo "FAIL absent idle file: $out"; fails=$((fails + 1));; esac

echo
if [ "$fails" = 0 ]; then echo "all passed"; else echo "$fails FAILED"; fi
exit "$([ "$fails" = 0 ] && echo 0 || echo 1)"
