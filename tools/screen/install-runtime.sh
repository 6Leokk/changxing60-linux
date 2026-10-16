#!/bin/bash
# Push the display modules and the status-page binary to the *running* device and load them.
#
# Deliberately no reboot and no boot-image write: the whole display bring-up is done at runtime over
# ssh so that a bad driver costs an rmmod (or, worst case, a power cycle that falls back to Android
# via the misc trial counter), not a reflash. Only once this is proven does it get persisted into
# the rootfs.
#
#   usage: install-runtime.sh [module-dir] [binary]
#   env:   CHANGXING60_HOST (default the USB-NCM link), KREL (default the 5.4.254 build)
set -euo pipefail

# bare address: ssh rejects the [..] brackets that scp needs to split host:path
ADDR=${CHANGXING60_HOST:-fd96:b832:c98b::1}
HOST="root@$ADDR"
SCP_TARGET="root@[$ADDR]"
KREL=${KREL:-5.4.254-gb50db5b6224c}
# -O = legacy SCP protocol: this rootfs has no sftp-server, which modern scp tries first
SSH=(ssh -o StrictHostKeyChecking=no -o ConnectTimeout=10 -o BatchMode=yes)
SCP=(scp -O -o StrictHostKeyChecking=no -o ConnectTimeout=10 -o BatchMode=yes)

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
root=$(cd "$here/../.." && pwd)
mods=${1:-$root/out/display}
bin=${2:-$here/out/changxing60-screen}
loader=$root/rootfs/overlay/opt/changxing60/bin/display-modules
initscript=$root/openwrt/overlay/etc/init.d/changxing60-screen

[ -d "$mods" ] || { echo "no module directory: $mods" >&2; exit 1; }
[ -f "$bin" ] || { echo "no binary: $bin (run tools/screen/build.sh)" >&2; exit 1; }

echo "== device =="
"${SSH[@]}" "$HOST" 'uname -r; uptime | tr -s " "; ls /dev/dri 2>&1 | head -1'

before=$("${SSH[@]}" "$HOST" 'dmesg | wc -l')
echo "== pushing =="
"${SCP[@]}" "$mods"/*.ko "$SCP_TARGET:/tmp/"
"${SCP[@]}" "$loader" "$SCP_TARGET:/tmp/display-modules"
"${SCP[@]}" "$initscript" "$SCP_TARGET:/tmp/changxing60-screen.init"
"${SCP[@]}" "$bin" "$SCP_TARGET:/tmp/changxing60-screen"

"${SSH[@]}" "$HOST" "
set -e
mkdir -p /lib/modules/$KREL /opt/changxing60/bin
mv /tmp/*.ko /lib/modules/$KREL/
# No coreutils "install" in this rootfs -- plain cp + chmod.
cp /tmp/display-modules /opt/changxing60/bin/display-modules
cp /tmp/changxing60-screen.init /etc/init.d/changxing60-screen
cp /tmp/changxing60-screen /usr/bin/changxing60-screen
chmod 755 /opt/changxing60/bin/display-modules /etc/init.d/changxing60-screen /usr/bin/changxing60-screen
# /tmp is tmpfs and /lib/modules is ext4: the moves above are copies whose dirty pages would be
# lost if the very next thing done is an insmod that hangs the box. Flush before installing.
sync
rm -f /tmp/*.ko /tmp/display-modules /tmp/changxing60-screen.init /tmp/changxing60-screen
echo '== modules =='
/opt/changxing60/bin/display-modules
"

echo "== dmesg (new lines) =="
"${SSH[@]}" "$HOST" "dmesg | tail -n +$((before + 1))" || true

echo
echo "== done. inspect with: =="
echo "  ssh $HOST 'ls -la /dev/dri; dmesg | tail -40'"
echo "  ssh $HOST '/usr/bin/changxing60-screen --once'   # draw one frame and exit"
