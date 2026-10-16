#!/system/bin/sh
# mu300-openwrt APatch module: start the OpenWrt chroot container at boot (late_start).
# Android stays the host: modem, power, charging, hotspot. The container adds procd/LuCI/
# dnsmasq/sing-box. Everything is files under /data/openwrt - delete that directory and
# this module to uninstall; no partition or boot-chain change is involved.
MODDIR=${0%/*}
ROOT=/data/openwrt
LOG=/data/local/tmp/mu300-openwrt.log
RUNPID=/data/local/tmp/mu300-container.pid
exec >>"$LOG" 2>&1
echo "---- $(date) service.sh start ----"

# the container rootfs must exist (installed by container/install.sh; not shipped in the module)
[ -x "$ROOT/sbin/init" ] || { echo "no container rootfs at $ROOT, skipping"; exit 0; }

# real root required
[ "$(id -u)" = 0 ] || { echo "not root, skipping"; exit 0; }

wait_net() {   # wait for Android's default route so procd services with network needs do not race it
    for n in $(seq 1 30); do
        ip route 2>/dev/null | grep -q "^default" && return 0
        sleep 2
    done
    return 0
}

start_container() {
    if [ -d /proc/$(cat "$RUNPID" 2>/dev/null 2>&1) ] 2>/dev/null; then
        pid=$(cat "$RUNPID" 2>/dev/null); [ -d "/proc/$pid" ] && { echo "container already running (pid $pid)"; return 0; }
    fi
    # bind the pseudo filesystems; /system (read-only) gives the chroot Android's iptables
    mkdir -p "$ROOT/system"
    mountpoint -q "$ROOT/proc"  || mount -t proc   proc   "$ROOT/proc"
    mountpoint -q "$ROOT/sys"   || mount -o bind /sys    "$ROOT/sys"
    mountpoint -q "$ROOT/dev"   || mount -o bind /dev    "$ROOT/dev"
    mountpoint -q "$ROOT/system" || mount -o ro,bind /system "$ROOT/system"
    # OpenWrt runtime dirs + ubus socket dir (25.12 uses /var/run/ubus/ubus.sock; missing
    # dirs make ubusd die silently). procd as a non-pid1 chroot process does NOT run the
    # rc.d sequence itself, so we drive ubusd -> procd -> rc.d/S* deterministically here.
    # PATH must be the OpenWrt one: the adb/su environment has no /bin, /usr/bin.
    chroot "$ROOT" /usr/bin/env PATH=/usr/sbin:/usr/bin:/sbin:/bin /bin/sh -c '
        mkdir -p /var/run/ubus /var/run/dnsmasq /var/lock /var/log /var/state /var/tmp /tmp/.uci /tmp/resolv.conf.d
        chmod 1777 /var/lock
        ubusd </dev/null >/dev/null 2>&1 &
        sleep 1
        procd </dev/null >/dev/null 2>&1 &
        sleep 2
        for S in /etc/rc.d/S*; do "$S" start >/dev/null 2>&1; done
    ' &
    echo $! > "$RUNPID"
    echo "container started, pid $(cat "$RUNPID")"
}

stop_container() {
    pid=$(cat "$RUNPID" 2>/dev/null)
    [ -n "$pid" ] && kill "$pid" 2>/dev/null
    chroot "$ROOT" /usr/bin/env PATH=/usr/sbin:/usr/bin:/sbin:/bin /bin/sh -c '
        for S in /etc/rc.d/K*; do "$S" stop >/dev/null 2>&1; done
        kill $(pidof ubusd procd 2>/dev/null) 2>/dev/null
        /opt/mu300/bin/mu300-vpn off >/dev/null 2>&1
    '
    umount "$ROOT/proc" "$ROOT/sys" "$ROOT/dev" "$ROOT/system" 2>/dev/null
    echo "container stopped"
}

case "${1:-start}" in
    start)
        wait_net
        start_container
        ;;
    stop)
        stop_container
        ;;
    status)
        pid=$(cat "$RUNPID" 2>/dev/null)
        [ -n "$pid" ] && [ -d "/proc/$pid" ] && echo "running (pid $pid)" || echo "not running"
        ;;
esac
