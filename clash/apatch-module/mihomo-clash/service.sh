#!/system/bin/sh
# mihomo-clash APatch module: transparent proxy gateway on Android.
# Payload lives in /data/clash (survives module updates); this module only boots it.
#   - TUN mode (kernel /dev/net/tun, auto-route via netlink ip rules - no iptables needed)
#   - hotspot clients' forwarded traffic enters the TUN too (Android already ip_forward's for hotspot)
#   - dashboard: http://<hotspot-ip>:9090/ui (zashboard), or on the phone: 127.0.0.1:9090/ui
MODDIR=${0%/*}
DIR=/data/clash
LOG=$DIR/run.log

wait_net() {
    for n in $(seq 1 45); do
        ip route 2>/dev/null | grep -q "^default" && return 0
        sleep 2
    done
    return 1
}

start_clash() {
    pid=$(cat $DIR/mihomo.pid 2>/dev/null)
    [ -n "$pid" ] && [ -d /proc/$pid ] && { echo "mihomo already running (pid $pid)"; return 0; }
    # hotspot forwarding + asymmetric TUN routing break under rp_filter
    for f in /proc/sys/net/ipv4/conf/*/rp_filter; do echo 0 > "$f" 2>/dev/null; done
    sysctl -w net.ipv4.ip_forward=1 >/dev/null 2>&1
    cd "$DIR" || return 1
    nohup "$DIR/bin/mihomo" -d "$DIR" >>"$LOG" 2>&1 &
    echo $! > "$DIR/mihomo.pid"
    echo "mihomo started, pid $(cat $DIR/mihomo.pid), log $LOG"
}

stop_clash() {
    pid=$(cat $DIR/mihomo.pid 2>/dev/null)
    [ -n "$pid" ] && kill "$pid" 2>/dev/null && echo "mihomo stopped"
    rm -f "$DIR/mihomo.pid"
}

case "${1:-start}" in
    start)  wait_net; start_clash ;;
    stop)   stop_clash ;;
    status) pid=$(cat $DIR/mihomo.pid 2>/dev/null)
            if [ -n "$pid" ] && [ -d /proc/$pid ]; then
                echo "running (pid $pid)"; curl -s -m 4 http://127.0.0.1:9090/version 2>/dev/null || /system/bin/toybox nc 127.0.0.1 9090 </dev/null 2>/dev/null
            else echo "not running"; fi ;;
esac
