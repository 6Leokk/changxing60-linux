#!/bin/bash
# Rename the mu300* names a running device still carries to changxing60*.
#
#   tools/rename-device.sh            show what would happen (no writes)
#   tools/rename-device.sh --apply    do it
#   tools/rename-device.sh --apply --wait   wait for the device first
#
# The repository is already renamed; the device in boot_b is not, because it boots a rootfs that was
# installed before the rename. Until this has run, tools/deploy-pending.sh cannot work at all: it pushes
# to /opt/changxing60/bin and /etc/init.d/changxing60-power, and on the old device those paths do not
# exist, so every push lands somewhere nothing reads.
#
# What runs on the device is tools/rename-device.remote -- read that for what is renamed and what is
# deliberately not. This half is the transport: push the payload, push the three files that have no old
# name to rename (the boot-path adoption script, and the two binaries that were built from the renamed
# sources), run it, and then check the result rather than assume it.
#
# Nothing here writes a boot image and nothing reboots. The next reboot is what proves the rename: it is
# the first boot whose /run and /mnt paths, init scripts and services all come up under the new names.
set -uo pipefail
here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
top=$(cd "$here/.." && pwd)

APPLY=0; WAIT=0
for a in "$@"; do
	case "$a" in
	--apply) APPLY=1 ;;
	--wait)  WAIT=1 ;;
	*) echo "usage: rename-device.sh [--apply] [--wait]" >&2; exit 2 ;;
	esac
done

SSH_OPTS=(-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=5 -o BatchMode=yes)
SCP_OPTS=(-O -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=5 -o BatchMode=yes)
CANDS=(192.168.77.1 fd96:b832:c98b::1)

ssh_try() { local h=$1; shift; timeout 20 ssh "${SSH_OPTS[@]}" "root@$h" "$@" 2>/dev/null; }
# The rename itself is not a 20-second job: it tars a backup, walks / for the inventory and seds 66
# files. With the short timeout the client hangs up mid-report and the exit status reads as a failure
# even though every rename had already landed.
ssh_run() { local h=$1; shift; timeout 600 ssh "${SSH_OPTS[@]}" "root@$h" "$@" 2>/dev/null; }

# Is the gadget electrically present? The only signal a route cannot fake. See docs/changxing60/access.md.
usb_present() {
	[ -n "$(/mnt/c/platform-tools/adb.exe devices 2>/dev/null | sed -n '2,$p' | grep -v '^$')" ] && return 0
	/mnt/c/Windows/System32/WindowsPowerShell/v1.0/powershell.exe -NoProfile -Command \
		"(Get-PnpDevice -PresentOnly | Where-Object { \$_.InstanceId -like '*VID_1D6B*PID_A4A3*' -or \$_.FriendlyName -like '*changxing60*' }).Count" \
		2>/dev/null | tr -d '\r' | grep -qv '^0$'
}

probe() {
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

case "$HOST" in
*:*) SCP_DEST="root@[$HOST]" ;;
*)   SCP_DEST="root@$HOST" ;;
esac

echo
echo "== what will be pushed =="
echo "  tools/rename-device.remote                          -> /tmp/rename-device.remote"
echo "  openwrt/overlay/etc/init.d/changxing60-bootpaths    -> /etc/init.d/changxing60-bootpaths"
echo "  tools/screen/out/changxing60-screen                 -> /usr/bin/changxing60-screen"
echo "  tools/screen/out/keyinject                          -> /usr/bin/keyinject"
echo "  and then: sh /tmp/rename-device.remote"
echo

# The three files that are new rather than renamed go in first, so that the payload's single rc.d pass
# sees changxing60-bootpaths and enables it, and so that the old mu300-screen can be deleted rather
# than renamed onto the new binary.
for f in "$top/tools/screen/out/changxing60-screen" "$top/tools/screen/out/keyinject"; do
	[ -f "$f" ] || { echo "missing build artefact $f -- run tools/screen/build.sh first" >&2; exit 1; }
done

if [ "$APPLY" != 1 ]; then
	echo "dry run: nothing was written. Re-run with --apply."
	exit 0
fi

echo "== pushing =="
scp "${SCP_OPTS[@]}" "$here/rename-device.remote"                    "$SCP_DEST:/tmp/rename-device.remote" || exit 1
scp "${SCP_OPTS[@]}" "$top/openwrt/overlay/etc/init.d/changxing60-bootpaths" "$SCP_DEST:/tmp/changxing60-bootpaths" || exit 1
scp "${SCP_OPTS[@]}" "$top/tools/screen/out/changxing60-screen"      "$SCP_DEST:/tmp/changxing60-screen" || exit 1
scp "${SCP_OPTS[@]}" "$top/tools/screen/out/keyinject"               "$SCP_DEST:/tmp/keyinject" || exit 1

echo
echo "== installing the three new files =="
# cp + chmod, not install(1): this rootfs has no install.
ssh_try "$HOST" 'set -e
cp /tmp/changxing60-bootpaths /etc/init.d/changxing60-bootpaths; chmod 755 /etc/init.d/changxing60-bootpaths
cp /tmp/changxing60-screen    /usr/bin/changxing60-screen;       chmod 755 /usr/bin/changxing60-screen
cp /tmp/keyinject             /usr/bin/keyinject;                chmod 755 /usr/bin/keyinject
echo "installed"' || { echo "install failed" >&2; exit 1; }

echo
echo "== running the rename =="
ssh_run "$HOST" 'sh /tmp/rename-device.remote' || { echo "the rename reported an error -- read its output above" >&2; exit 1; }

echo
echo "== verification (this is the part that decides whether it worked) =="
echo "--- 1. nothing under /opt, /etc, /lib, /usr/bin or /www still carries the old name ---"
ssh_try "$HOST" 'find /opt /etc /lib /usr/bin /usr/share/rpcd /usr/share/luci /www /root -xdev -name "*mu300*" -not -path "*/rename-changxing60.backup/*" 2>/dev/null | sort'
echo "--- 2. services enabled under the new names (expect changxing60-hw/vendor/screen/power/ndp/post/bootpaths) ---"
ssh_try "$HOST" 'ls -l /etc/rc.d/ | grep changxing60'
echo "--- 3. the WAN protocol handler resolves (netifd looks it up by file name) ---"
ssh_try "$HOST" 'echo "proto=$(uci -q get network.wan.proto)"; ls -l /lib/netifd/proto/changxing60cell.sh'
echo "--- 4. the chroot is still there and its mounts came back ---"
ssh_try "$HOST" 'ls -d /opt/changxing60/android; grep " /opt/changxing60/android" /proc/mounts | wc -l; ps w | grep -c "[m]odem_control"'
echo "--- 5. the binaries the rename installed run ---"
ssh_try "$HOST" 'ls -l /usr/bin/changxing60-screen /usr/bin/keyinject; /usr/bin/changxing60-screen --dump 2>&1 | head -3'
echo "--- 6. the boot-path adoption script is in place (it covers /run and /mnt until boot_b is rebuilt) ---"
ssh_try "$HOST" 'ls -l /etc/init.d/changxing60-bootpaths /etc/rc.d/S00changxing60-bootpaths; ls -A /mnt/changxing60-disk/ 2>&1 | head -6'
echo
echo "This renamed the rootfs only. The boot image in boot_b is a separate artifact and still carries"
echo "the old name -- its /init creates /run/mu300, mounts /mnt/mu300-disk, reads"
echo "/newroot/etc/mu300/default-boot and names the USB gadget MU300LINUX. The default-boot one is the"
echo "one that matters: with the file gone the old init writes the slot-a block into misc, arming"
echo "Android for the next boot. Finish it with:"
echo
echo "  tools/repack-ramdisk.py --base work/boot_b-live.img --set init=boot/init --out work/boot-linux-slotb.img"
echo "  tools/flash-boot-b.sh --image work/boot-linux-slotb.img --reboot"
echo
echo "then check /run, /mnt, the gadget strings and the persist log. Until then bootpath-adoption runs"
echo "on every boot. The originals are in /root/rename-changxing60.backup on the device and every step"
echo "here is reversible by hand."
