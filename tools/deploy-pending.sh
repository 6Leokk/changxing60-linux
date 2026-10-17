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
# and answers with "Connection closed by 192.168.77.1 port 22". See docs/changxing60/access.md §5.1.
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

# The device requires a root password as of 2026-10-16; it used to have an empty one, so plain ssh
# just worked. Two ways in, and this script accepts either: a key at ~/.ssh/id_changxing60 (see the
# Host 192.168.77.1 block in ~/.ssh/config, and docs/changxing60/access.md section 2.1), or the
# password from $CHANGXING60_PASSWORD / $CHANGXING60_PASSWORD_FILE (default ~/.changxing60-password,
# 0600) -- deliberately outside the repository so it is never committed, supplied by sshpass. When no
# password is available the connection falls back to BatchMode=yes, so an unauthenticated run fails
# fast and reports the device unreachable instead of blocking on a prompt that nothing can answer.
PWFILE=${CHANGXING60_PASSWORD_FILE:-$HOME/.changxing60-password}
if [ -z "${CHANGXING60_PASSWORD:-}" ] && [ -r "$PWFILE" ]; then
	CHANGXING60_PASSWORD=$(cat "$PWFILE")
fi
AUTH_CMD=(); AUTH_OPTS=(-o BatchMode=yes)
if [ -n "${CHANGXING60_PASSWORD:-}" ]; then
	command -v sshpass >/dev/null 2>&1 || { echo "deploy-pending: a password is set but sshpass is not installed" >&2; exit 1; }
	export SSHPASS="$CHANGXING60_PASSWORD"   # sshpass -e: keeps the password out of the process list
	AUTH_CMD=(sshpass -e)
	# BatchMode=yes would disable password auth outright, so it must not be combined with this. The
	# rest stays at the default order deliberately: publickey first, password only if that fails, so
	# the (working) key wins and sshpass goes unused. Forcing PreferredAuthentications=password here
	# would disable the key instead -- backwards now that both paths work.
	AUTH_OPTS=(-o NumberOfPasswordPrompts=1)
fi
# -O: legacy SCP protocol. This rootfs has no sftp-server, which modern scp tries first and hangs on.
SSH_OPTS=(-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=5 "${AUTH_OPTS[@]}")
SCP_OPTS=(-O -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=5 "${AUTH_OPTS[@]}")
CANDS=(192.168.77.1 fd96:b832:c98b::1)

ssh_try() { # ssh_try HOST CMD -> stdout, rc
	local h=$1; shift
	timeout 12 "${AUTH_CMD[@]}" ssh "${SSH_OPTS[@]}" "root@$h" "$@" 2>/dev/null
}

# Is the gadget electrically present? This is the only signal that cannot be faked by a route.
usb_present() {
	[ -n "$(/mnt/c/platform-tools/adb.exe devices 2>/dev/null | sed -n '2,$p' | grep -v '^$')" ] && return 0
	# The gadget is the Linux Foundation composite device, VID 0x1d6b / PID 0xa4a3 -- not a Unisoc
	# VID. Matching the wrong vendor here would report "present" on any ordinary Android phone.
	/mnt/c/Windows/System32/WindowsPowerShell/v1.0/powershell.exe -NoProfile -Command \
		"(Get-PnpDevice -PresentOnly | Where-Object { \$_.InstanceId -like '*VID_1D6B*PID_A4A3*' -or \$_.FriendlyName -like '*changxing60*' }).Count" \
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
	"${AUTH_CMD[@]}" scp "${SCP_OPTS[@]}" "$local_f" "$SCP_DEST:$remote" || return 1
}

echo
echo "== files to push =="
# Scripts and tools that are kernel-independent.
push "$top/rootfs/overlay/opt/changxing60/bin/power-policy"    /tmp/power-policy
push "$top/rootfs/overlay/opt/changxing60/bin/extra-modules"   /tmp/extra-modules
push "$top/rootfs/overlay/opt/changxing60/bin/android-run"         /tmp/android-run
push "$top/rootfs/overlay/opt/changxing60/bin/android-gpu-run"     /tmp/android-gpu-run
push "$top/rootfs/overlay/opt/changxing60/bin/android-vendor-start" /tmp/android-vendor-start
# The init scripts are NOT named here one by one -- they come from the tree-derived pass further down.
# Two of the eleven used to be listed here by hand, so the other nine could not be delivered at all.
push "$top/tools/changxing60-cp-reset.sh"                      /tmp/changxing60-cp-reset
push "$top/tools/changxing60-wedge-watch.sh"                   /tmp/changxing60-wedge-watch
push "$top/tools/screen/out/changxing60-screen"                /tmp/changxing60-screen
# The synthetic key injector: without it the only way to test the power-key brightness steps is a
# finger on the button, which means goal "brightness steps + memory" can never be *verified* by script.
push "$top/tools/screen/out/keyinject"                   /tmp/keyinject

# The USB link's mode switch (goal W1): manage (address only) or share (the PC routes through this device).
# Kernel-independent, touches no modem, so it is pushed with the rest rather than behind the AT staging.
# Only the helper script is here: it is a /opt/changxing60/bin script and needs the staging plus chmod,
# while the LuCI half of the page is picked up by the panel pass below like every other panel.
push "$top/rootfs/overlay/opt/changxing60/bin/changxing60-usb-mode" /tmp/changxing60-usb-mode

# The scripts the 2026-10-17 conflict scan touches (docs/changxing60/conflicts.md section 9). None of
# these was ever named here, so until now a host-side fix to any of them had NO route to a running
# device -- the same silence the init.d glob was added to kill on 2026-10-16, one directory over.
# The list is deliberately explicit: these six boot-run scripts are the ones with device-visible state.
push "$top/rootfs/overlay/opt/changxing60/bin/net-split"            /tmp/net-split
push "$top/rootfs/overlay/opt/changxing60/bin/openwrt-wifi-config"  /tmp/openwrt-wifi-config
push "$top/rootfs/overlay/opt/changxing60/bin/hotspot-watch"        /tmp/hotspot-watch
push "$top/rootfs/overlay/opt/changxing60/bin/wifi-fix"             /tmp/wifi-fix
push "$top/rootfs/overlay/opt/changxing60/bin/ndp-learn"            /tmp/ndp-learn
push "$top/openwrt/overlay/opt/changxing60/bin/vendor-modules"      /tmp/vendor-modules

# ---- the LuCI panels, as one pass over the tree ----
# Every panel is the same four parts and all four are needed before the page works: the ucode is the
# backend rpcd loads, the ACL is what lets the page call it, the menu is what makes it appear at all,
# and the view JS is what uhttpd serves. Any one missing is silent -- the page does not appear, or it
# appears with every control dead -- which is how the SMS panel spent a day looking installed while the
# half that does the forwarding was present and executable and no route to it existed.
#
# This used to name four files per panel by hand, and by 2026-10-16 that list had already fallen
# behind: the SMS view and the voice view were both fixed on the host and never pushed, and the voice
# and SMS backends were missing from it as well. The one script whose entire job is "push everything
# that was finished while the device was away" was quietly shipping half of it. So it globs instead:
# a new panel, or a new part of an old one, is picked up with no edit here.
#
# The ACL and menu are deliberately not one-per-app: the SMS page is one page with two halves (the
# pool and the forwarding), and luci-app-changxing60sms.json is the superset that grants and lists
# both halves.
LUCI_PARTS=(
    "$top"/openwrt/overlay/usr/share/rpcd/ucode/changxing60*.uc
    "$top"/openwrt/overlay/usr/share/rpcd/acl.d/luci-app-changxing60*.json
    "$top"/openwrt/overlay/usr/share/luci/menu.d/luci-app-changxing60*.json
    "$top"/openwrt/overlay/www/luci-static/resources/view/changxing60*/*.js
)
# Each file goes to the path it came from -- repo path minus the overlay prefix -- so there is no second
# list to keep in step and the install step below has nothing to copy. scp will not create a directory,
# and a panel that is new on the host has no view directory on the device yet, so the directories that
# are needed are made first in a single ssh.
LUCI_REL=(); LUCI_DIRS=
for p in "${LUCI_PARTS[@]}"; do
    [ -e "$p" ] || continue
    rel=${p#"$top"/openwrt/overlay/}
    LUCI_REL+=("$rel")
    case " $LUCI_DIRS " in
    *" /$(dirname "$rel") "*) ;;
    *) LUCI_DIRS="$LUCI_DIRS /$(dirname "$rel")" ;;
    esac
done
if [ "$APPLY" = 1 ] && [ ${#LUCI_REL[@]} -gt 0 ]; then
    ssh_try "$HOST" "mkdir -p $LUCI_DIRS" >/dev/null
fi
for rel in "${LUCI_REL[@]}"; do
    push "$top/openwrt/overlay/$rel" "/$rel"
done

# ---- the init scripts, as one pass over the tree ----
# Same disease as the panels above, found the same way and on the same day (2026-10-16). This list named
# two scripts by hand -- changxing60-power and changxing60-modemd -- while the device runs eleven, so a
# fix to any of the other nine had no route to the device whatsoever. It was found by pushing a change to
# changxing60-post (the boot-reason record): the script reported success, and the device was still
# running the 09:52 file -- different md5, no complaint. The alternative to globbing here is remembering
# to add a line every time a service is added, which is the thing that already failed.
INITD_BASE=()
for p in "$top"/openwrt/overlay/etc/init.d/changxing60-*; do
    [ -e "$p" ] || continue
    INITD_BASE+=("$(basename "$p")")
done
for b in "${INITD_BASE[@]}"; do
    push "$top/openwrt/overlay/etc/init.d/$b" "/tmp/$b.init"
done

# The e5 telephony port (goal W3): the client half of modem_control's CP-reset protocol. Built by
# tools/modem/build.sh; the binary is committed there. It is not started by this script -- see the
# verification section, which restarts changxing60-vendor first, because modem_control creates the
# @modemd socket only at its own startup.
push "$top/tools/modem/changxing60-modemd"                  /tmp/changxing60-modemd

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
         changxing60-cp-reset changxing60-wedge-watch \
         net-split openwrt-wifi-config hotspot-watch wifi-fix ndp-learn vendor-modules; do
	[ -e /tmp/$f ] || continue
	cp /tmp/$f /opt/changxing60/bin/$f; chmod 755 /opt/changxing60/bin/$f
done
# changxing60-screen and keyinject live in /usr/bin, NOT /opt/changxing60/bin: that is where both
# build-rootfs.sh and tools/screen/install-runtime.sh put them, and it is what
# /etc/init.d/changxing60-screen execs (`procd_set_param command /usr/bin/changxing60-screen`). Installing the
# screen binary under /opt/changxing60/bin -- as this script used to -- copies a file nothing reads: the
# service keeps running the old binary and every "deployed" check still passes. Silent no-op, and
# exactly the failure this script exists to prevent.
for f in changxing60-screen keyinject; do
	[ -e /tmp/$f ] || continue
	cp /tmp/$f /usr/bin/$f; chmod 755 /usr/bin/$f
done
# init.d: install whatever the tree-derived pass pushed, then enable it the way rc.common would. START is
# read out of the file itself, so a service whose start order changed gets its symlink moved with no
# second list to keep in step. Two of these used to be hardcoded here.
for f in /tmp/changxing60-*.init; do
	[ -e "$f" ] || continue
	b=$(basename "$f" .init)
	cp "$f" /etc/init.d/$b; chmod 755 /etc/init.d/$b
	n=$(sed -n "s/^START=//p" /etc/init.d/$b 2>/dev/null)
	[ -n "$n" ] && ln -sf ../init.d/$b /etc/rc.d/S${n}$b
done

# The helper script for the USB link page. The LuCI half of every panel was pushed straight to the path
# it is read from, so there is nothing to copy for those.
# NOTE: no apostrophes anywhere inside the single-quoted payloads below -- this note itself is inside one.
[ -e /tmp/changxing60-usb-mode ] && { cp /tmp/changxing60-usb-mode /opt/changxing60/bin/changxing60-usb-mode; chmod 755 /opt/changxing60/bin/changxing60-usb-mode; }

# What is left for the panels is the restart, and it is not optional: a rpcd backend is a plugin, read
# once when rpcd starts, and the ACL and menu files are read at that same moment. Without the restart the
# files sit on disk, ubus never lists the object, and the LuCI page loads with every control dead --
# which looks like a front-end bug and is not one.
/etc/init.d/rpcd restart >/dev/null 2>&1 || true

# modemd: the binary and its procd unit, enabled by hand because "enable" needs ubus and this push runs
# outside rc.common. S12 is what the unit declares; a service installed but never enabled does not fail,
# it just never runs.
[ -e /tmp/changxing60-modemd ] && { cp /tmp/changxing60-modemd /opt/changxing60/bin/changxing60-modemd; chmod 755 /opt/changxing60/bin/changxing60-modemd; }
echo "scripts installed"' || echo "script install reported an error" >&2

if [ "$SET" = 54 ]; then
	echo "pushing $MODS modules to /lib/modules/$KREL/ ..."
	"${AUTH_CMD[@]}" scp "${SCP_OPTS[@]}" "$top"/out/modules/*.ko "$SCP_DEST:/lib/modules/$KREL/" \
		|| { echo "module push failed" >&2; exit 1; }
fi

echo
echo "== verification (this is the part that decides whether it worked) =="
echo "--- services enabled ---"
ssh_try "$HOST" 'ls -l /etc/rc.d/S*changxing60-*'
echo "--- module present + loads ---"
if [ "$SET" = 54 ]; then
	ssh_try "$HOST" 'ls -l /lib/modules/'"$KREL"'/mali_kbase.ko; modprobe mali_kbase; echo "modprobe rc=$?"; ls -l /dev/mali0; dmesg | grep -i -m3 -E "mali|kbase"'
	echo "--- extra-modules (expect loaded mali_kbase, no bare FAILED) ---"
	ssh_try "$HOST" '/opt/changxing60/bin/extra-modules'
	echo "--- GPU userspace: the real acceptance test ---"
	ssh_try "$HOST" '/opt/changxing60/bin/android-gpu-run /system/bin/cltest 2>&1 | head -12'
fi
echo "--- power policy ---"
ssh_try "$HOST" '/opt/changxing60/bin/power-policy status; /opt/changxing60/bin/power-policy apply'
echo "--- USB link mode switch (goal W1) ---"
# Not just "the file is there": the helper has to run and the mode has to read back as one of the two.
# A rpcd ucode plugin that fails to compile loads as nothing at all and ubus list is silent about it,
# so the backend check is an actual call.
ssh_try "$HOST" 'ls -l /opt/changxing60/bin/changxing60-usb-mode
/opt/changxing60/bin/changxing60-usb-mode state || echo "usb-mode state FAILED"
ubus -v list changxing60usb 2>&1 | head -4
ubus call changxing60usb status 2>&1 | head -20'

echo "--- every LuCI panel is on the device byte for byte (W2 / W4 / W5) ---"
# The criterion is the file the device will actually serve, compared against the one in the tree -- not
# "the push printed no error". A view JS that was never pushed is a page that still runs the old code,
# and nothing about the deploy looks wrong. That is exactly how the reported "ReferenceError: dom is not
# defined" would have survived its own fix: three of the four panels were not in the push list at all.
for p in "$top"/openwrt/overlay/www/luci-static/resources/view/changxing60*/*.js; do
    [ -e "$p" ] || continue
    rel=${p#"$top"/openwrt/overlay/}
    loc=$(md5sum "$p" | cut -d' ' -f1)
    dev=$(ssh_try "$HOST" "md5sum /$rel 2>/dev/null | cut -d' ' -f1")
    if [ -n "$dev" ] && [ "$dev" = "$loc" ]; then
        echo "  ok    /$rel"
    else
        echo "  STALE /$rel (host $loc, device ${dev:-absent})"
    fi
done

echo "--- every init script is on the device byte for byte ---"
# Same criterion, same reason, and this one has a receipt: a change to changxing60-post was reported as
# pushed while the device went on running the 09:52 file, because post was not in the hand-written list.
# Nothing about that deploy looked wrong -- which is precisely the failure mode worth a check.
for b in "${INITD_BASE[@]}"; do
    loc=$(md5sum "$top/openwrt/overlay/etc/init.d/$b" | cut -d' ' -f1)
    dev=$(ssh_try "$HOST" "md5sum /etc/init.d/$b 2>/dev/null | cut -d' ' -f1")
    if [ -n "$dev" ] && [ "$dev" = "$loc" ]; then
        echo "  ok    /etc/init.d/$b"
    else
        echo "  STALE /etc/init.d/$b (host $loc, device ${dev:-absent})"
    fi
done

echo "--- every pushed /opt/changxing60/bin script is on the device byte for byte ---"
# The init.d pass above learned this the hard way; the bin scripts had the same gap until the 2026-10-17
# conflict fixes. A stale copy here does not look stale from the device either: the boot runs the file,
# so whatever the file says is what everybody believes. The md5 pair is the only witness.
# (vendor-modules lives in openwrt/overlay, everything else in rootfs/overlay -- two trees, one /bin.)
BIN_PUSHED="net-split openwrt-wifi-config hotspot-watch wifi-fix ndp-learn vendor-modules \
power-policy extra-modules android-run android-gpu-run android-vendor-start"
for rel in $BIN_PUSHED; do
    case "$rel" in
    vendor-modules) src="$top/openwrt/overlay/opt/changxing60/bin/$rel" ;;
    *)              src="$top/rootfs/overlay/opt/changxing60/bin/$rel" ;;
    esac
    [ -e "$src" ] || continue
    loc=$(md5sum "$src" | cut -d' ' -f1)
    dev=$(ssh_try "$HOST" "md5sum /opt/changxing60/bin/$rel 2>/dev/null | cut -d' ' -f1")
    if [ -n "$dev" ] && [ "$dev" = "$loc" ]; then
        echo "  ok    /opt/changxing60/bin/$rel"
    else
        echo "  STALE /opt/changxing60/bin/$rel (host $loc, device ${dev:-absent})"
    fi
done

echo "--- every panel backend answers (objective W2/W4/W5) ---"
# Same lesson as the USB block above, and the reason this is a call rather than an ls: a rpcd ucode
# plugin that fails to compile loads as nothing at all, ubus list simply does not mention it, and the
# LuCI page then renders with every control dead.
ssh_try "$HOST" 'for d in changxing60sms changxing60fwd changxing60usb changxing60voice changxing60net; do
    printf "%-20s %s\n" "$d" "$(ubus -v list $d 2>&1 | head -1)"
done
echo "forward_status: $(ubus call changxing60fwd forward_status 2>&1 | head -c 200)"
echo "voice state:    $(ubus call changxing60voice state 2>&1 | head -c 200)"
echo "net status:     $(ubus call changxing60net status 2>&1 | head -c 400)"
echo "net fast:       $(ubus call changxing60net fast 2>&1 | head -c 300)"'
ssh_try "$HOST" 'ls -l /opt/changxing60/bin/changxing60-sms-forward'
echo "--- screen binary (must be the one just installed) + remembered brightness ---"
ssh_try "$HOST" 'ls -l /usr/bin/changxing60-screen /usr/bin/keyinject; /usr/bin/changxing60-screen --dump 2>&1 | head -3; echo "backlight=$(cat /etc/changxing60/backlight 2>/dev/null)"'
echo "--- power-key brightness + memory, driven by keyinject (no finger needed) ---"
# The uinput node is created by the changxing60-screen init script out of /proc/misc; keyinject needs it.
# keyinject registers its virtual device and *then* waits gap_s before pressing, and changxing60-screen only
# scans /dev/input/event* once at startup -- so keyinject has to be up first, then the service starts.
ssh_try "$HOST" 'set -e
# grep+cut, not awk: the whole payload is one single-quoted bash string, so an awk program here would
# have to reach the remote shell as "$2 == ..." inside double quotes -- where the *remote* sh expands
# $2 and hands awk a comparison against its own (empty) positional parameter.
[ -e /dev/input/uinput ] || { m=$(grep -w uinput /proc/misc | cut -d" " -f1); [ -n "$m" ] && mknod /dev/input/uinput c 10 "$m"; }
before=$(cat /etc/changxing60/backlight 2>/dev/null || echo none)
ls /dev/input/event* >/dev/null 2>&1 || { echo "no /dev/input/event* -- cannot test"; exit 0; }
/usr/bin/keyinject 116 2 4 >/tmp/keyinject.log 2>&1 &
sleep 1
/etc/init.d/changxing60-screen restart >/dev/null 2>&1 || /etc/init.d/changxing60-screen start >/dev/null 2>&1
sleep 14
after=$(cat /etc/changxing60/backlight 2>/dev/null || echo none)
echo "backlight: $before -> $after"
[ "$before" != "$after" ] && echo "PASS: power key stepped the brightness" || echo "FAIL: brightness did not change (see /tmp/keyinject.log + logread)"
cat /tmp/keyinject.log'

echo "--- e5 telephony port: the @modemd socket, and a client on it (goal W3) ---"
# This is the acceptance test, and it is deliberately not "the binary is installed". The socket only
# exists because modem_control read ro.vendor.radio.modemtype as something other than "not_find" at its
# own startup, which it could not do until android-vendor-start started chowning the property area to
# root -- so a socket here proves the property fix as well as the port. modem_control creates it only
# once, at startup, so the vendor service is restarted first; that is safe (it re-runs the same
# idempotent script) and the WAN comes back on its own.
ssh_try "$HOST" 'echo "property area (must be root:root):"; ls -l /dev/__properties__/property_info
echo "modemtype: $(LD_LIBRARY_PATH=/apex/com.android.runtime/lib64/bionic:/system/lib64:/vendor/lib64 chroot /opt/changxing60/android /vendor/bin/getprop ro.vendor.radio.modemtype 2>&1)"
echo "modem_control threads before restart: $(ls /proc/$(pgrep modem_control)/task 2>/dev/null | wc -l)"
/etc/init.d/changxing60-vendor restart >/dev/null 2>&1
sleep 20
echo "modem_control threads after restart: $(ls /proc/$(pgrep modem_control)/task 2>/dev/null | wc -l)  (2 = listen thread created)"
echo "@modemd in /proc/net/unix:"; grep -i modemd /proc/net/unix || echo "  ABSENT -- modem_control did not create it"
/etc/init.d/changxing60-modemd restart >/dev/null 2>&1
sleep 3
echo "modemd client: $(pgrep changxing60-modemd >/dev/null && echo running || echo NOT RUNNING)"
tail -3 /root/changxing60-modemd.log 2>/dev/null || echo "  (no log yet)"
echo "WAN after: $(ip -brief addr show sipa_eth0 2>&1 | tr -s " ")"
echo "default route: $(ip route | grep -c "^default")"'

echo
echo "Done. Anything above that does not look right is the next thing to look at."
