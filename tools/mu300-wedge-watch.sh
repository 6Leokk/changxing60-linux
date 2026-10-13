#!/bin/sh
# 10 s sampler aimed at catching a SIPA wedge as it happens, with the RM state machine in the log.
# Deliberately does NOT ping every tick: the only traffic it makes is one ping a minute, so it
# cannot itself keep the call busy enough to hide the wedge (and it sleeps with the counters
# instead, which are free).
#
# Runs ON THE DEVICE (busybox ash). Install + start:
#   ssh root@192.168.77.1 'cat > /root/wedge-watch.sh && chmod 755 /root/wedge-watch.sh' < tools/mu300-wedge-watch.sh
#   ssh root@192.168.77.1 'setsid /root/wedge-watch.sh >>/root/wedge-watch.log 2>&1 </dev/null &'
# Read the result:  ssh root@192.168.77.1 'tail -40 /root/wedge-watch.log'
# Judgement rule (docs/mu300/sipa-wedge.md §6.3/§7): a healthy-looking WAN before uptime ~1200 s means
# nothing -- wedges have landed at 566/592/628 s. Only "no wedge past ~1200 s" counts.
LOG=${1:-/root/wedge-watch.log}
IFACE=${2:-sipa_eth0}
PROBE=${3:-223.5.5.5}
n=0
while :; do
    up=$(cut -d. -f1 /proc/uptime 2>/dev/null)
    link=$(cat /sys/class/net/$IFACE/operstate 2>/dev/null)
    rx=$(cat /sys/class/net/$IFACE/statistics/rx_packets 2>/dev/null)
    tx=$(cat /sys/class/net/$IFACE/statistics/tx_packets 2>/dev/null)
    # state is the 13th field of each rm_res line (see docs/mu300/sipa-wedge.md §3).
    # -m1 matters: there are two rm_res lines per resource and the second one's field 13 ends in
    # "Released]," which used to break the log format with an embedded newline.
    pp=$(grep -m1 SIPA_RM_RES_PROD_CP /sys/kernel/debug/sipa/rm_res 2>/dev/null | awk '{print $13}')
    cc=$(grep -m1 SIPA_RM_RES_CONS_WWAN_UL /sys/kernel/debug/sipa/rm_res 2>/dev/null | awk '{print $13}')
    n=$((n + 1))
    if [ $((n % 6)) -eq 0 ]; then
        if ping -c1 -W2 "$PROBE" >/dev/null 2>&1; then p=OK; else p=loss; fi
    else
        p=-
    fi
    echo "$up link=${link:-?} PROD=${pp:-?} CONS=${cc:-?} rx=${rx:-?} tx=${tx:-?} ping=$p"
    sleep 10
done
