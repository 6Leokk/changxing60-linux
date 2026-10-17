#!/bin/bash
# Deploy the Simplified-Chinese LuCI catalogs to a LIVE (already-booted) device.
#
# 91-luci-zh-cn in the overlay only runs on FIRST boot, so a device that's
# already up needs this one-shot: drop the two .lmo catalogs, register
# luci.languages.zh_cn, force luci.main.lang=zh_cn, commit, and reload rpcd
# (which serves the ubus translate endpoint the client-side _() calls go
# through). Note: setting luci.languages.main does NOT work — the ucode
# dispatcher reads luci.main.lang for the active language, and in "auto" mode
# only matches languages registered under luci.languages.
#
# Auth mirrors tools/deploy-pending.sh: $CHANGXING60_PASSWORD /
# $CHANGXING60_PASSWORD_FILE (default ~/.changxing60-password, 0600), via
# sshpass -e; falls back to BatchMode (key) when no password is set. scp uses -O
# because this rootfs has no sftp-server.
#
# Host-side only; device must be on USB (check with lsusb for the NCM gadget /
# 192.168.77.1 NIC). Run from the changxing60-linux checkout root.

set -eu

HERE="$(cd "$(dirname "$0")" && pwd)"
TOP="$(cd "$HERE/../.." && pwd)"
I18N_DIR="$TOP/openwrt/overlay/usr/lib/lua/luci/i18n"
HOST="${CHANGXING60_HOST:-root@192.168.77.1}"
REMOTE_DIR="/usr/lib/lua/luci/i18n"

PWFILE=${CHANGXING60_PASSWORD_FILE:-$HOME/.changxing60-password}
if [ -z "${CHANGXING60_PASSWORD:-}" ] && [ -r "$PWFILE" ]; then
	CHANGXING60_PASSWORD=$(cat "$PWFILE")
fi
AUTH=(); OPTS=(-o BatchMode=yes)
if [ -n "${CHANGXING60_PASSWORD:-}" ]; then
	command -v sshpass >/dev/null 2>&1 || { echo "sshpass not installed" >&2; exit 1; }
	export SSHPASS="$CHANGXING60_PASSWORD"
	AUTH=(sshpass -e); OPTS=()
fi
SSH_OPTS=(-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=5 "${OPTS[@]}")
SCP_OPTS=(-O -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=5 "${OPTS[@]}")

for f in base.zh-cn.lmo changxing60.zh-cn.lmo; do
	src="$I18N_DIR/$f"
	[ -f "$src" ] || { echo "missing $src (run tools/i18n/build-i18n.py first)" >&2; exit 1; }
	echo "deploying $f ..."
	# AUTH (sshpass -e, if set) MUST precede scp/ssh — sshpass wraps the command
	# and feeds the password to its ssh subprocess; placing it after makes scp
	# treat "sshpass"/"-e" as local source files. Mirrors deploy-pending.sh.
	"${AUTH[@]}" scp "${SCP_OPTS[@]}" "$src" "$HOST:/tmp/$f"
	"${AUTH[@]}" ssh "${SSH_OPTS[@]}" "$HOST" \
		"mkdir -p '$REMOTE_DIR' && mv /tmp/$f '$REMOTE_DIR/$f'"
done

echo "setting luci.main.lang=zh_cn (+ registering luci.languages.zh_cn) ..."
"${AUTH[@]}" ssh "${SSH_OPTS[@]}" "$HOST" \
	"uci -q delete luci.languages.main; uci -q set luci.languages.zh_cn='简体中文'; uci -q set luci.main.lang='zh_cn'; uci -q commit luci; /etc/init.d/rpcd restart 2>/dev/null || true"

echo
echo "Done. Open the LuCI panel in a fresh browser tab (old tabs hold a cached"
echo "session). Menus should be Chinese; the five changxing60 panels' labels too."
echo "If anything still shows English, run on the device:"
echo "  ls /usr/lib/lua/luci/i18n/   # both .lmo present?"
echo "  uci get luci.main.lang       # -> zh_cn"
echo "  uci get luci.languages.zh_cn # -> 简体中文"
