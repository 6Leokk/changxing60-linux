#!/bin/bash
# Push everything that was finished on the host while the device was away, then prove each piece is
# actually live. This exists because the device is only intermittently on USB: the work does not stop
# when it disappears, and coming back should not mean re-deriving which artefacts are stale.
#
#   tools/deploy-pending.sh              show what would change (no writes)
#   tools/deploy-pending.sh --apply      do it
#   tools/deploy-pending.sh --apply --wait    wait for the device first (short timeouts, retrying)
#
# Waiting is deliberately a retry loop with a 5 s connect timeout, not one long timeout: after a
# reboot the device is usually not reachable yet, and a long single timeout just makes the failure
# slower to see. --wait also uses the USB signal (adb / Windows PnP), because a *failed* ssh to
# 192.168.77.1 does not prove the device is absent -- the host's own OpenClash TUN hijacks that route
# and answers with "Connection closed by 192.168.77.1 port 22". See docs/mu300/access.md §5.1.
#
# Nothing here writes a boot image, and nothing reboots. The modules go into the running rootfs, so a
# bad push costs a file copy back, not a reflash. boot_a is never touched.
set -uo pipefail
here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
top=$(cd "$here/.." && pwd)

APPLY=0; WAIT=0
for a in "$@"; do
	case "$a" in
	--apply) APPLY=1 ;;
	--wait)  WAIT=1 ;;
	*) echo "usage: deploy-pending.sh [--apply] [--wait]" >&2; exit 2 ;;
	esac
done

# -O: legacy SCP protocol. This rootfs has no sftp-server, which modern scp tries first and hangs on.
SSH_OPTS=(-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=5 -o BatchMode=yes)
SCP_OPTS=(-O -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=5 -o BatchMode=yes)
CANDS=(192.168.77.1 fd96:b832:c98b::1)

ssh_try() { # ssh_try HOST CMD -> stdout, rc
	local h=$1; shift
	timeout 12 ssh "${SSH_OPTS[@]}" "root@$h" "$@" 2>/dev/null
}

# Is the gadget electrically present? This is the only signal that cannot be faked by a route.
usb_present() {
	[ -n "$(/mnt/c/platform-tools/adb.exe devices 2>/dev/null | sed -n '2,$p' | grep -v '^$')" ] && return 0
	# The gadget is the Linux Foundation composite device, VID 0x1d6b / PID 0xa4a3 -- not a Unisoc
	# VID. Matching the wrong vendor here would report "present" on any ordinary Android phone.
	/mnt/c/Windows/System32/WindowsPowerShell/v1.0/powershell.exe -NoProfile -Command \
		"(Get-PnpDevice -PresentOnly | Where-Object { \$_.InstanceId -like '*VID_1D6B*PID_A4A3*' -or \$_.FriendlyName -like '*MU300*' }).Count" \
		2>/dev/null | tr -d '\r' | grep -qv '^0$'
}

probe() { # sets HOST
	local h out
	for h in "${CANDS[@]}"; do
		out=$(ssh_try "$h" 'uname -r') || continue
		[ -n "$out" ] && { HOST=$h; KREL=$out; return 0; }
	done
	return 1
}

if [ "$WAIT" = 1 ]; then
	echo "waiting for the device: 5 s connect timeouts, retried, USB checked every ~30 s"
	i=0
	while :; do
		i=$((i + 1))
		if probe; then echo "up after ~$((i * 10))s: $HOST, kernel $KREL"; break; fi
		if [ $((i % 3)) -eq 0 ]; then
			usb_present && echo "  (USB is present but ssh is not up yet -- still booting?)" \
				     || echo "  (t=$((i * 10))s: no USB gadget)"
		fi
		sleep 10
	done
else
	probe || { echo "device not reachable. Is it on USB? (--wait to sit and retry)" >&2; exit 1; }
	echo "device: $HOST, kernel $KREL"
fi

# scp needs the brackets to split host:path only for a literal IPv6 address; on IPv4 (or a name) the
# brackets become part of the path and the copy fails.
case "$HOST" in
*:*) SCP_DEST="root@[$HOST]" ;;
*)   SCP_DEST="root@$HOST" ;;
esac

case "$KREL" in
5.4.*) SET=54 ;;
6.*)   SET=618 ;;
*)     echo "unknown kernel $KREL -- refusing to guess which module set belongs on it" >&2; exit 1 ;;
esac
echo "kernel set: $SET"

# A push that lands silently and is not picked up is the failure this script exists to avoid, so every
# push is followed by a check further down that the device is actually running the new thing.
push() { # push LOCAL REMOTE
	local local_f=$1 remote=$2
	echo "  $local_f -> $remote"
	[ "$APPLY" = 1 ] || return 0
	scp "${SCP_OPTS[@]}" "$local_f" "$SCP_DEST:$remote" || return 1
}

echo
echo "== files to push =="
# Scripts and tools that are kernel-independent.
push "$top/rootfs/overlay/opt/mu300/bin/power-policy"    /tmp/power-policy
push "$top/rootfs/overlay/opt/mu300/bin/extra-modules"   /tmp/extra-modules
push "$top/rootfs/overlay/opt/mu300/bin/android-run"         /tmp/android-run
push "$top/rootfs/overlay/opt/mu300/bin/android-gpu-run"     /tmp/android-gpu-run
push "$top/rootfs/overlay/opt/mu300/bin/android-vendor-start" /tmp/android-vendor-start
push "$top/openwrt/overlay/etc/init.d/mu300-power"       /tmp/mu300-power.init
push "$top/tools/mu300-cp-reset.sh"                      /tmp/mu300-cp-reset
push "$top/tools/mu300-wedge-watch.sh"                   /tmp/mu300-wedge-watch
push "$top/tools/screen/out/mu300-screen"                /tmp/mu300-screen
# The synthetic key injector: without it the only way to test the power-key brightness steps is a
# finger on the button, which means goal "brightness steps + memory" can never be *verified* by script.
push "$top/tools/screen/out/keyinject"                   /tmp/keyinject

MODS=
if [ "$SET" = 54 ]; then
	MODS=$(ls "$top"/out/modules/*.ko 2>/dev/null | wc -l)
	echo "  $top/out/modules/*.ko ($MODS modules) -> /lib/modules/$KREL/"
else
	echo "  (6.18: the 5.4 module set does not go here -- the 6.18 modules come from upstream/out)"
fi

if [ "$APPLY" != 1 ]; then
	echo
	echo "dry run: nothing was written. Re-run with --apply."
	exit 0
fi

echo
echo "== installing =="
ssh_try "$HOST" 'set -e
for f in power-policy extra-modules android-run android-gpu-run android-vendor-start \
         mu300-cp-reset mu300-wedge-watch; do
	[ -e /tmp/$f ] || continue
	cp /tmp/$f /opt/mu300/bin/$f; chmod 755 /opt/mu300/bin/$f
done
# mu300-screen and keyinject live in /usr/bin, NOT /opt/mu300/bin: that is where both
# build-rootfs.sh and tools/screen/install-runtime.sh put them, and it is what
# /etc/init.d/mu300-screen execs (`procd_set_param command /usr/bin/mu300-screen`). Installing the
# screen binary under /opt/mu300/bin -- as this script used to -- copies a file nothing reads: the
# service keeps running the old binary and every "deployed" check still passes. Silent no-op, and
# exactly the failure this script exists to prevent.
for f in mu300-screen keyinject; do
	[ -e /tmp/$f ] || continue
	cp /tmp/$f /usr/bin/$f; chmod 755 /usr/bin/$f
done
[ -e /tmp/mu300-power.init ] && { cp /tmp/mu300-power.init /etc/init.d/mu300-power; chmod 755 /etc/init.d/mu300-power; }
n=$(sed -n "s/^START=//p" /etc/init.d/mu300-power 2>/dev/null)
[ -n "$n" ] && ln -sf ../init.d/mu300-power /etc/rc.d/S${n}mu300-power
echo "scripts installed"' || echo "script install reported an error" >&2

if [ "$SET" = 54 ]; then
	echo "pushing $MODS modules to /lib/modules/$KREL/ ..."
	scp "${SCP_OPTS[@]}" "$top"/out/modules/*.ko "$SCP_DEST:/lib/modules/$KREL/" \
		|| { echo "module push failed" >&2; exit 1; }
fi

echo
echo "== verification (this is the part that decides whether it worked) =="
echo "--- services enabled ---"
ssh_try "$HOST" 'ls -l /etc/rc.d/S*mu300-*'
echo "--- module present + loads ---"
if [ "$SET" = 54 ]; then
	ssh_try "$HOST" 'ls -l /lib/modules/'"$KREL"'/mali_kbase.ko; modprobe mali_kbase; echo "modprobe rc=$?"; ls -l /dev/mali0; dmesg | grep -i -m3 -E "mali|kbase"'
	echo "--- extra-modules (expect loaded mali_kbase, no bare FAILED) ---"
	ssh_try "$HOST" '/opt/mu300/bin/extra-modules'
	echo "--- GPU userspace: the real acceptance test ---"
	ssh_try "$HOST" '/opt/mu300/bin/android-gpu-run /system/bin/cltest 2>&1 | head -12'
fi
echo "--- power policy ---"
ssh_try "$HOST" '/opt/mu300/bin/power-policy status; /opt/mu300/bin/power-policy apply'
echo "--- screen binary (must be the one just installed) + remembered brightness ---"
ssh_try "$HOST" 'ls -l /usr/bin/mu300-screen /usr/bin/keyinject; /usr/bin/mu300-screen --dump 2>&1 | head -3; echo "backlight=$(cat /etc/mu300/backlight 2>/dev/null)"'
echo "--- power-key brightness + memory, driven by keyinject (no finger needed) ---"
# The uinput node is created by the mu300-screen init script out of /proc/misc; keyinject needs it.
# keyinject registers its virtual device and *then* waits gap_s before pressing, and mu300-screen only
# scans /dev/input/event* once at startup -- so keyinject has to be up first, then the service starts.
ssh_try "$HOST" 'set -e
# grep+cut, not awk: the whole payload is one single-quoted bash string, so an awk program here would
# have to reach the remote shell as "$2 == ..." inside double quotes -- where the *remote* sh expands
# $2 and hands awk a comparison against its own (empty) positional parameter.
[ -e /dev/input/uinput ] || { m=$(grep -w uinput /proc/misc | cut -d" " -f1); [ -n "$m" ] && mknod /dev/input/uinput c 10 "$m"; }
before=$(cat /etc/mu300/backlight 2>/dev/null || echo none)
ls /dev/input/event* >/dev/null 2>&1 || { echo "no /dev/input/event* -- cannot test"; exit 0; }
/usr/bin/keyinject 116 2 4 >/tmp/keyinject.log 2>&1 &
sleep 1
/etc/init.d/mu300-screen restart >/dev/null 2>&1 || /etc/init.d/mu300-screen start >/dev/null 2>&1
sleep 14
after=$(cat /etc/mu300/backlight 2>/dev/null || echo none)
echo "backlight: $before -> $after"
[ "$before" != "$after" ] && echo "PASS: power key stepped the brightness" || echo "FAIL: brightness did not change (see /tmp/keyinject.log + logread)"
cat /tmp/keyinject.log'

echo
echo "Done. Anything above that does not look right is the next thing to look at."
