#!/bin/sh
# Diagnostic: does a WAN that is never idle still wedge ~10 min after boot?
#
# The wedge (docs/mu300/sipa-wedge.md) kills the call about 10 minutes after every boot, and the
# call is otherwise nearly idle (a couple of packets every 12-15 s). One candidate is the modem's
# own idle/sleep path: SIPA/RM logs show suspend transitions ("ready to suspend and change to
# single", "nic can't sleep") right around the wedge. A small steady ping keeps the call busy,
# so if the wedge stops happening, the trigger is the idle/sleep path and not the traffic itself.
#
# One ping every 5 s, logged with the ping result AND the RM state, so the log alone shows both
# "was the link alive" and "was the state machine stuck".
#
# Runs ON THE DEVICE. Two ways to start it:
#   manual:      ssh root@192.168.77.1 'setsid /root/wan-keepalive.sh >>/root/wan-keepalive.log 2>&1 </dev/null &'
#   as a service (survives reboot, what was actually used): install
#                tools/mu300-wan-keepalive.init as /etc/init.d/mu300-wan-keepalive, then
#                /etc/init.d/mu300-wan-keepalive enable && /etc/init.d/mu300-wan-keepalive start
#                (procd sends its stdout to syslog -> read with `logread | grep keepalive`)
# Remove when done:  /etc/init.d/mu300-wan-keepalive disable && rm /etc/init.d/mu300-wan-keepalive
#
# Status of the experiment (2026-10-13): INCONCLUSIVE -- see docs/mu300/sipa-wedge.md §6.4.1.
# First attempt never ran inside the window that matters; the second one reached 708 s with zero
# wedge events, but OpenClash was also generating traffic (confound) and the device was unplugged
# before ~1200 s, so nothing is proven either way.
LOG=${1:-/root/wan-keepalive.log}
PROBE=${2:-223.5.5.5}
IFACE=${3:-sipa_eth0}
while :; do
    up=$(cut -d. -f1 /proc/uptime 2>/dev/null)
    rc=loss
    ping -c1 -W2 "$PROBE" >/dev/null 2>&1 && rc=ok
    pp=$(grep -m1 SIPA_RM_RES_PROD_CP /sys/kernel/debug/sipa/rm_res 2>/dev/null | awk '{print $13}')
    tot=$(awk 'NR==1{print $1+$2}' /sys/class/net/$IFACE/statistics/rx_packets \
                                    /sys/class/net/$IFACE/statistics/tx_packets 2>/dev/null)
    echo "$up ping=$rc PROD=${pp:-?} pkts=${tot:-?}"
    sleep 5
done
