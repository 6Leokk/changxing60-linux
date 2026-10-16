#!/bin/sh
# mu300-cp-reset.sh - CP (modem firmware) stop/start as a subsystem-level recovery.
#
# Why: the SIPA wedge is CP-side. The AP's 2 s delegator timeout unlocks the AP's
# resource manager, but the CP never answers again, so `mobile-data`'s last resort
# is a full reboot (~16 min cycles, 20-25 a day). The modem loader's own stop/start
# (drivers/unisoc_platform/modem_loader/sprd_modem_loader.c, /dev/modem ioctl) is the
# thing that should recover it. This script is the experiment that answers whether it
# does, before anything is wired into mobile-data.
#
#   cp-reset.sh status   - one snapshot, no side effects
#   cp-reset.sh dry      - on a healthy link: stop the CP, watch the stack fall over,
#                          start it again, and see whether WAN comes back by itself
#   cp-reset.sh recover  - the same, meant to be run *during* a real wedge
#
# What it deliberately does NOT do:
#   * MODEM_ASSERT_CMD (0x0e) - gated on comm=="modem_control" in the kernel.
#   * write "AT" to /dev/stty_nr1 while sipa_eth0 still has an address - the data
#     call and the AT channel are the same port, so that would push bytes into a
#     live packet stream. Same rule as mobile-data's at_state(); it shows up here
#     as "at=skip".
#
# The CP is left stopped for only ~20 s: modem_control (the vendor daemon in the
# chroot) is what keeps the PM co-processor from cutting power, and it must be
# alive for the whole experiment.
#
# Safety: the last-resort reboot is disarmed by creating mobile-data's per-boot
# REBOOT_MARK. Remove the file to hand control back to mobile-data.

IFACE=sipa_eth0
DEV=/dev/modem
ATDEV=/dev/stty_nr1
HELPER=/opt/mu300/bin/modem-ioctl
RMRES=/sys/kernel/debug/sipa/rm_res
MARK=/var/run/mu300-wan-rebooted
LOG=/root/cp-reset-$(date +%s).log

log() { echo "$@" | tee -a "$LOG"; }

uptime_s() { local u; read -r u _ < /proc/uptime 2>/dev/null || u=0; echo "${u%.*}"; }
has_addr() { ip -4 addr show "$IFACE" 2>/dev/null | grep -q "inet "; }
addr_of() { ip -4 addr show "$IFACE" 2>/dev/null | awk '/inet /{print $2; exit}'; }
rmstate() { grep -m1 "$1" "$RMRES" 2>/dev/null | awk '{print $13}'; }

# 0 = the modem answered, 1 = silence, 2 = must not be asked
at_probe() {
	has_addr && return 2
	[ -c "$ATDEV" ] || return 2
	local line st=1
	exec 3<>"$ATDEV" || return 2
	while IFS= read -r -t 0.2 line <&3; do :; done
	printf 'AT\r' >&3
	for _ in 1 2 3 4 5; do
		if IFS= read -r -t 1 line <&3; then st=0; break; fi
	done
	exec 3>&-
	return $st
}

snap() {  # $1 = label
	local at a r c rx tx
	at=$(at_probe; echo $?)
	a=$(addr_of); [ -n "$a" ] || a="-"
	r=$(rmstate SIPA_RM_RES_PROD_CP); c=$(rmstate SIPA_RM_RES_CONS_WWAN_UL)
	rx=$(cat /sys/class/net/$IFACE/statistics/rx_packets 2>/dev/null)
	tx=$(cat /sys/class/net/$IFACE/statistics/tx_packets 2>/dev/null)
	log "$(uptime_s)s $1 addr=$a PROD=${r:--} CONS=${c:--} rx=${rx:--} tx=${tx:--} at=$at"
}

ping_ok() { ping -c1 -W3 223.5.5.5 >/dev/null 2>&1; }

preflight() {
	local ok=0
	[ -x "$HELPER" ] || { log "! $HELPER missing"; ok=1; }
	[ -c "$DEV" ] || { log "! $DEV missing"; ok=1; }
	ps www 2>/dev/null | grep "[v]endor/bin/modem_control" >/dev/null ||
		{ log "! modem_control is not running - the PM co-processor may cut power; aborting"; ok=1; }
	[ -e "$MARK" ] || touch "$MARK"
	log "== preflight: reboot disarmed via $MARK (remove it to hand control back to mobile-data)"
	log "== helper: $($HELPER 2>&1 | head -1)"
	log "== log: $LOG"
	return $ok
}

wait_for() {  # $1 = seconds, $2 = label; samples every 2 s
	local i=0 n=$1
	while [ $i -lt "$n" ]; do
		sleep 2
		i=$((i + 2))
		snap "$2"
	done
}

case "$1" in
status)
	preflight || exit 1
	snap "status"
	exit 0
	;;
dry|recover)
	preflight || exit 1
	;;
*)
	echo "usage: $0 status|dry|recover" >&2
	exit 2
	;;
esac

log ""
log "==== baseline"
snap "baseline"
log "ping: $(ping_ok && echo ok || echo FAIL)  mobile-data: $(ps www 2>/dev/null | grep -c '[m]obile-data') process(es)"

log ""
log "==== STEP 1: stop the CP ($DEV MODEM_STOP_CMD)"
"$HELPER" stop 2>&1 | tee -a "$LOG"
snap "after-stop"
wait_for 20 "stopped"
log "logread (tail):"
logread 2>/dev/null | tail -6 | tee -a "$LOG"

log ""
log "==== STEP 2: start the CP again"
"$HELPER" start 2>&1 | tee -a "$LOG"
snap "after-start"
i=0
while [ $i -lt 90 ]; do
	sleep 3
	i=$((i + 3))
	snap "starting"
	if has_addr && ping_ok; then
		log "   -> address back and ping works at ${i}s"
		break
	fi
done
log "logread (tail):"
logread 2>/dev/null | tail -8 | tee -a "$LOG"

log ""
log "==== VERDICT (${i}s after start)"
if has_addr && ping_ok; then
	log "RECOVERED by itself: CP stop/start restores the data call -> subsystem-level"
	log "recovery is viable; wire it in ahead of the last-resort reboot."
else
	log "NOT recovered by itself: addr=$(addr_of) ; may need a data-path kick"
	log "(ubus call network.interface.wan down/up, or ifup wan) before we conclude."
fi
[ -e "$MARK" ] && log "note: $MARK still present (reboot stays disarmed this boot)"
log "log: $LOG"
