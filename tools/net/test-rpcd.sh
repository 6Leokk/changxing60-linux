#!/bin/bash
# Host-side checks for the network page's backend (openwrt/overlay/usr/share/rpcd/ucode/changxing60net.uc).
#
# The backend is ucode and the target is OpenWrt, so the checks run inside the OpenWrt image
# (changxing60-openwrt-base), against a STUBBED collector (tools/net/fake-net-status): the real
# changxing60-net-status is itself verified separately by tools/net/test-status.sh against a fake AT
# client -- this file verifies the HOP ABOVE it, the backend that runs the collector and hands its
# JSON to the LuCI page.
#
# What is covered is the page's data contract, the part a device cannot tell you about on its own:
#   * a good snapshot passes through VERBATIM -- field for field, null for null. An unanswered RSRP
#     must not arrive at the page as 0, and "verbatim" is the only way that is guaranteed;
#   * the error round (exit 1, top-level error) is the collector's own sentence, with the busy bit,
#     as ok:0 -- distinguishable from the backend itself failing;
#   * a broken collector (silent, non-JSON, two lines) is refused rather than guessed at, and is
#     reported as the backend's error with a detail;
#   * fast selects --fast --json (proven from what the stub was handed, not from the reply).
#
# Two stages, mirroring tools/sms/test-rpcd.sh:
#   1. the harness -- one method call at a time, the exact value it returns (rpcd-harness-net.uc);
#   2. the real thing -- the plugin installed where rpcd reads it, a real ubusd + rpcd, calls over
#      ubus exactly as the page's rpc.declare sends them (rpcd-ubus-check.sh, root in the image).
#
#   usage: tools/net/test-rpcd.sh        (exit 0 = all passed)
set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$here/../.." && pwd)"

IMAGE=${CHANGXING60_IMAGE:-changxing60-openwrt-base:25.12.5}
command -v docker >/dev/null || { echo "docker is needed: the backend is ucode, and the check runs on OpenWrt" >&2; exit 2; }

for f in \
	"$ROOT/openwrt/overlay/usr/share/rpcd/ucode/changxing60net.uc" \
	"$ROOT/tools/net/fake-net-status" \
	"$ROOT/tools/net/rpcd-harness-net.uc" \
	"$ROOT/tools/net/rpcd-ubus-check.sh" \
	"$ROOT/tools/sms/rpcd-harness.uc"; do
	[ -e "$f" ] || { echo "missing $f" >&2; exit 2; }
done

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

# stage 1: the harness, as the image's own user so what it writes under /work is ours to clean up.
# TMPDIR points at the mounted /work because the image's /tmp is root-owned 0755 -- the backend's
# stderr side lands there (the same environment note the SMS checks document).
docker run --rm --platform linux/arm64 \
	-v "$ROOT":/repo:ro -v "$work":/work \
	--user "$(id -u):$(id -g)" \
	-e CHANGXING60_NET_BIN=/work/bin/changxing60-net-status \
	-e TMPDIR=/work/tmp \
	"$IMAGE" sh -c '
		mkdir -p /work/bin /work/tmp
		cp /repo/tools/net/fake-net-status /work/bin/changxing60-net-status
		chmod 755 /work/bin/changxing60-net-status
		ucode /repo/tools/net/rpcd-harness-net.uc
	'
rc=$?

# stage 2: the same backend where it will actually live -- rpcd, over ubus, against the same stub
if [ "$rc" = 0 ]; then
	echo
	docker run --rm --platform linux/arm64 \
		-v "$ROOT":/repo:ro -v "$work":/work \
		-e WORK=/work -e HOST_UID="$(id -u)" -e HOST_GID="$(id -g)" \
		-e CHANGXING60_NET_BIN=/work/bin/changxing60-net-status \
		-e TMPDIR=/work/tmp \
		"$IMAGE" sh -c 'mkdir -p /work/tmp; sh /repo/tools/net/rpcd-ubus-check.sh'
	rc=$?
fi
exit $rc
