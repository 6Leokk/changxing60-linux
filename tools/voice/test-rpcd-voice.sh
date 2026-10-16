#!/bin/bash
# Host-side checks for the call page's backend (openwrt/overlay/usr/share/rpcd/ucode/changxing60voice.uc) and
# the detached dial it drives (openwrt/overlay/opt/changxing60/bin/changxing60-voice-job).
#
# The backend is ucode and the target is OpenWrt, so the checks themselves run inside the OpenWrt image; the
# AT channel and the modem are the ones tools/voice/fake-at provides, which is what makes it possible to
# exercise a dial, an answer, a hangup, DTMF and mute without a device. What this covers is the part a device
# cannot tell you about: that every reply has the shape the page reads, that a dial is handed off and asked
# after rather than run inside the call (rpcd would end the call long before a slow dial is done), that a
# refused or wedged dial is reported as a failure rather than an eternal "dialing", and that two dials at once
# cannot both reach the modem.
#
#   usage: tools/voice/test-rpcd-voice.sh        (exit 0 = all passed)
set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$here/../.." && pwd)"

IMAGE=${CHANGXING60_IMAGE:-changxing60-openwrt-base:25.12.5}
command -v docker >/dev/null || { echo "docker is needed: the backend is ucode, and the check runs on OpenWrt" >&2; exit 2; }

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

# --user so that what the container writes under /work belongs to us, and the voice CLI can write its files as us
docker run --rm --platform linux/arm64 \
    -v "$ROOT":/repo:ro -v "$work":/work \
    --user "$(id -u):$(id -g)" \
    -e WORK=/work \
    "$IMAGE" sh /repo/tools/voice/rpcd-check.sh
rc=$?

# Then the same backend where it will actually live: rpcd, over ubus. It starts a real ubusd and rpcd, which need
# root, so this one runs as root and hands /work back afterwards (HOST_UID) or the trap could not clean it up.
if [ "$rc" = 0 ]; then
    echo
    docker run --rm --platform linux/arm64 \
        -v "$ROOT":/repo:ro -v "$work":/work \
        -e WORK=/work -e HOST_UID="$(id -u)" -e HOST_GID="$(id -g)" \
        "$IMAGE" sh /repo/tools/voice/rpcd-ubus-check.sh
    rc=$?
fi
exit $rc
