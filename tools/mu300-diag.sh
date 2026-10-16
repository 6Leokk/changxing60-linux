#!/bin/sh
# mu300-diag.sh - one read-only snapshot of what the box is doing right now.
#
# Runs ON THE DEVICE (busybox ash), installed at /opt/mu300/bin/mu300-diag.sh. Nothing here
# writes: no AT traffic (see the rule in tools/mu300-cp-reset.sh -- the AT port and the data
# call are the same port on /dev/stty_nr1), no module loads, no config changes. Safe to run
# during a wedge, which is the point: it is the first thing to reach for when the WAN "dies"
# again and you need to know whether the address is gone, the counters are frozen, or only
# the far side is unreachable.
#
#   mu300-diag.sh              print the snapshot
#   mu300-diag.sh label        same, with "== label ==" as the header
#
# Output is also appended to /root/diag/<uptime>s.log so two runs can be diffed (the wedge is
# a *change* in counters, so keep the older file). Remove /root/diag to stop that.

IFACE=sipa_eth0
PROBE=223.5.5.5
RMRES=/sys/kernel/debug/sipa/rm_res
DIR=/root/diag

# Re-run ourselves through tee so the snapshot both prints and persists. Two things this has to
# get right: the marker stops the second copy from recursing, and the explicit exit stops the
# *first* copy from carrying on -- in ash the left side of a pipeline is a subshell, so exec
# there replaces only the subshell and the parent would print the whole snapshot a second time.
if [ -z "$MU300_DIAG_TEE" ]; then
    up=$(cut -d. -f1 /proc/uptime 2>/dev/null)
    if mkdir -p "$DIR" 2>/dev/null && [ -w "$DIR" ]; then
        MU300_DIAG_TEE=$DIR/${up}s.log
        export MU300_DIAG_TEE
        "$0" "$@" 2>&1 | tee "$MU300_DIAG_TEE"
        exit $?
    fi
fi

echo "== mu300-diag ${1:+[$1] }$(date '+%F %T %z')"
echo "== uptime/load"
uptime
echo "kver: $(uname -r)   host: $(cat /proc/sys/kernel/hostname)"
echo "boots: $(dmesg 2>/dev/null | grep -c 'Restarting system') restart(s) in this dmesg buffer"
[ -e /var/run/mu300-wan-rebooted ] && echo "WARNING: mobile-data last-resort reboot is DISARMED this boot (/var/run/mu300-wan-rebooted)"

echo
echo "== memory"
head -3 /proc/meminfo
zram=$(cat /sys/block/zram0/mm_stat 2>/dev/null | awk '{printf "orig=%d compr=%d used=%d\n", $1, $2, $3}')
[ -n "$zram" ] && echo "zram0: $zram"

echo
echo "== cellular / SIPA"
echo -n "$IFACE: "; ip -4 addr show "$IFACE" 2>/dev/null | awk '/inet /{printf "addr=%s ", $2}'
echo "operstate=$(cat /sys/class/net/$IFACE/operstate 2>/dev/null)"
echo "counters: rx_packets=$(cat /sys/class/net/$IFACE/statistics/rx_packets 2>/dev/null) tx_packets=$(cat /sys/class/net/$IFACE/statistics/tx_packets 2>/dev/null)"
echo "health: $(cat /tmp/mu300-wan-health 2>/dev/null)  (\"<ok|dead> <uptime>\" as published by mobile-data for the status page)"
[ -s /root/wedge-watch.log ] && echo "wedge-watch tail: $(tail -3 /root/wedge-watch.log | tr '\n' ' | ')"
if [ -r "$RMRES" ]; then
    echo "rm_res:"
    sed -n 's/^\[res\] name = \([A-Z_0-9]*\) .* ref_count = \([0-9-]*\) state = \([0-9-]*\)$/    \1 ref=\2 state=\3/p' "$RMRES" | head -12
    st=$(sed -n 's/^\[res\] name = SIPA_RM_RES_PROD_CP .* state = \([0-9-]*\)$/\1/p' "$RMRES" | head -1)
    [ "$st" = 2 ] && echo "  -> PROD_CP state=2 (granted)" || echo "  -> PROD_CP state='$st' (NOT granted -- wedge signature is a stuck request here)"
else
    echo "rm_res: not readable (debugfs mounted? /sys/kernel/debug)"
fi
if [ -d /sys/kernel/debug/sipa ]; then
    for f in nic flow_ctrl; do
        [ -r /sys/kernel/debug/sipa/$f ] || continue
        echo "sipa/$f: $(head -6 /sys/kernel/debug/sipa/$f | tr '\n' '|')"
    done
fi
echo -n "ping $PROBE: "; ping -c1 -W3 "$PROBE" >/dev/null 2>&1 && echo ok || echo FAIL

echo
echo "== modules"
lsmod 2>/dev/null | grep -E "^(sipa|sprd_wlan|wcn_bsp|sprdbt|sprd_modem)" | awk '{printf "%-22s %8s %s\n", $1, $2, $3}'

echo
echo "== Wi-Fi"
if iw dev wlan0 info >/dev/null 2>&1; then
    iw dev wlan0 info 2>/dev/null | sed -n '1,6p'
    echo "bssid: $(iw dev wlan0 info 2>/dev/null | awk '/addr/{print $2}')  (must survive reboot: /usr/bin/wifimac pins prodnv value)"
else
    echo "wlan0: not present"
fi
if ubus list 2>/dev/null | grep -q '^hostapd\.'; then
    echo "clients (hostapd; iw station dump is always empty on this driver):"
    ubus call hostapd.wlan0 get_clients 2>/dev/null | tr ',' '\n' | grep -E '"(addr|bytes|signal)"' | tr -d ' ' | tr '\n' ' '; echo
fi
echo "br-wifi: $(ip -4 addr show br-wifi 2>/dev/null | awk '/inet /{print $2}')   br-lan: $(ip -4 addr show br-lan 2>/dev/null | awk '/inet /{print $2}')"

echo
echo "== proxy / IPv6"
if pidof mihomo >/dev/null 2>&1 || pidof clash >/dev/null 2>&1 || pidof openclash >/dev/null 2>&1; then
    echo "clash core: running  utun: $(ip -o link show utun 2>/dev/null | wc -l)  fwmark rule: $(ip rule 2>/dev/null | grep -c 'fwmark 0x162')"
else
    echo "clash core: not running"
fi
echo "v6 default: $(ip -6 route show default 2>/dev/null | head -1)"

echo
echo "== power / thermal"
for c in battery sc27xx-fgu; do
    [ -d /sys/class/power_supply/$c ] || continue
    cap=$(cat /sys/class/power_supply/$c/capacity 2>/dev/null)
    # sc27xx-fgu reports thousandths of a percent, not percent (docs/mu300/power.md)
    [ "$c" = sc27xx-fgu ] && cap="$cap/1000 = $(awk "BEGIN{printf \"%.1f\", $cap/10}")%"
    echo "$c: capacity=$cap status=$(cat /sys/class/power_supply/$c/status 2>/dev/null)"
done
# Some zones exist but their temp node returns EINVAL until the sensor is up (osctsen/outtsen here):
# read the value first and skip anything that is not a number, or awk prints "Unexpected end of string".
for z in /sys/class/thermal/thermal_zone*; do
    t=$(cat "$z/temp" 2>/dev/null) || continue
    case "$t" in '' | *[!0-9-]*) continue ;; esac
    printf "%s=%s " "$(cat "$z/type" 2>/dev/null)" "$(awk "BEGIN{printf \"%.1fC\", $t/1000}")"
done; echo
echo "cpufreq: $(cat /sys/devices/system/cpu/cpufreq/policy0/scaling_cur_freq 2>/dev/null) kHz (policy0)"

echo
echo "== crash evidence"
for f in /sys/fs/pstore/*; do
    [ -e "$f" ] || continue
    echo "  $(wc -c < "$f" 2>/dev/null) $f"
done
[ -s /sys/fs/pstore/console-ramoops-0 ] && grep -m1 -E 'bootcause|panic' /sys/fs/pstore/console-ramoops-0 2>/dev/null | cut -c1-160

echo
echo "== recent kernel noise (routine sipa_dele smsg chatter filtered out)"
dmesg 2>/dev/null | grep -iE "sipa_dele|cp_asserted|assert|panic|oops|watchdog|timed out|fail" |
    grep -vE "smsg_(recv|send)|pd_eb_flag" | tail -12

echo
echo "== logread tail"
logread 2>/dev/null | tail -15

[ -n "$MU300_DIAG_TEE" ] && echo "(snapshot also at $MU300_DIAG_TEE)"
