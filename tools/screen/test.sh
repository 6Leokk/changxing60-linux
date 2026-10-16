#!/bin/bash
# Host-side checks for the screen binaries. Nothing here touches the device.
#
# mu300-screen has two parts that can be pinned down without a panel: the brightness state machine
# (test-backlight.c, self-checking) and the QR encoder on the status page (test-qr.c, diffed
# against python-qrcode one mask at a time). Both are silent failures on the device -- a level that
# comes back wrong after a reboot, or a QR that scans as the wrong URL -- so they are checked here
# instead of by squinting at the screen after a flash.
#
#   usage: tools/screen/test.sh          (exit 0 = all checks passed)
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
CC="${CC:-cc}"

echo "== brightness state machine (test-backlight) =="
"$CC" -O1 -Wall -Wextra -o "$tmp/test-backlight" "$here/test-backlight.c" "$here/qr.c"
"$tmp/test-backlight"

echo
echo "== management address on the panel (test-lan) =="
# The address in the footer is displayed nowhere else, and the wrong one (br-lan's 192.168.77.1,
# from the hotspot reader's point of view) went unnoticed until it was reported from the device.
"$CC" -O1 -Wall -Wextra -o "$tmp/test-lan" "$here/test-lan.c" "$here/qr.c"
"$tmp/test-lan"

echo
echo "== QR encoder vs python-qrcode (test-qr) =="
if ! python3 -c 'import qrcode' 2>/dev/null; then
    echo "skipped: no python3 qrcode module (pip install qrcode)"
    exit 0
fi
"$CC" -O1 -Wall -Wextra -o "$tmp/test-qr" "$here/test-qr.c" "$here/qr.c"

fail=0
for text in "http://192.168.77.1/" "http://192.168.8.1/" "changxing60"; do
    for mask in 0 1 2 3 4 5 6 7; do
        "$tmp/test-qr" "$text" "$mask" > "$tmp/ours" || { echo "FAIL $text mask=$mask: does not fit"; fail=1; continue; }
        n=$(head -1 "$tmp/ours")
        # the reference encoder needs the version, which the module count gives us: n = 4v + 17
        ver=$(( (n - 17) / 4 ))
        python3 "$here/ref-qr.py" "$text" "$ver" "$mask" | tail -n +2 > "$tmp/ref"
        tail -n +2 "$tmp/ours" > "$tmp/ours-body"
        if diff -q "$tmp/ours-body" "$tmp/ref" >/dev/null; then
            echo "ok   $text v$ver mask=$mask"
        else
            echo "FAIL $text v$ver mask=$mask"
            diff "$tmp/ours-body" "$tmp/ref" | head -5
            fail=1
        fi
    done
done

[ "$fail" = 0 ] && echo "all passed" || echo "FAILURES"
exit $fail
