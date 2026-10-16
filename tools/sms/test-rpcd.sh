#!/bin/bash
# Host-side checks for the SMS page's backend (openwrt/overlay/usr/share/rpcd/ucode/changxing60sms.uc) and the
# detached sender it drives (openwrt/overlay/opt/changxing60/bin/changxing60-sms-job).
#
# The backend is ucode and the target is OpenWrt, so the checks themselves run inside the OpenWrt image; the
# message pool, the AT channel and the modem are the ones tools/sms/fake-at provides, which is what makes it
# possible to exercise a send, a sync and a delete without a device. What this covers is the part a device cannot
# tell you about: that every reply has the shape the page reads, that a send is handed off and asked after rather
# than run inside the call (rpcd would end the call long before a slow send is done), and that a busy AT channel
# is not reported as a message sent.
#
#   usage: tools/sms/test-rpcd.sh        (exit 0 = all passed)
set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$here/../.." && pwd)"

IMAGE=${CHANGXING60_IMAGE:-changxing60-openwrt-base:25.12.5}
command -v docker >/dev/null || { echo "docker is needed: the backend is ucode, and the check runs on OpenWrt" >&2; exit 2; }
command -v python3 >/dev/null || { echo "python3 is needed: it builds the SIM the check starts from (deliver.py)" >&2; exit 2; }

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

# The SIM the pool is filled from: one plain message and one long one whose two parts must be joined back
# together. Made here because the image has no python3 - and by deliver.py, which is an implementation of its own,
# so that what the pool reads back has not been through the same code that wrote it.
p1=$(python3 "$here/deliver.py" "+8613800138000" "Hello from the SIM")
p2=$(python3 "$here/deliver.py" "10086"           "part one of a long message " 42 2 1)
p3=$(python3 "$here/deliver.py" "10086"           "and part two of it." 42 2 2)
printf '1\t0\t%s\n2\t0\t%s\n3\t0\t%s\n' "$p1" "$p2" "$p3" > "$work/sim"

# --user so that what the container writes under /work belongs to us, and the trap can clean it up
docker run --rm --platform linux/arm64 \
    -v "$ROOT":/repo:ro -v "$work":/work \
    --user "$(id -u):$(id -g)" \
    -e WORK=/work \
    "$IMAGE" sh /repo/tools/sms/rpcd-check.sh
rc=$?

# Then the same backend where it will actually live: rpcd, over ubus. It starts a real ubusd and rpcd, which need
# root, so this one runs as root and hands /work back afterwards (HOST_UID) or the trap could not clean it up.
if [ "$rc" = 0 ]; then
    echo
    docker run --rm --platform linux/arm64 \
        -v "$ROOT":/repo:ro -v "$work":/work \
        -e WORK=/work -e HOST_UID="$(id -u)" -e HOST_GID="$(id -g)" \
        "$IMAGE" sh /repo/tools/sms/rpcd-ubus-check.sh
    rc=$?
fi
exit $rc
