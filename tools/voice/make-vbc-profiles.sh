#!/bin/sh
# Produce the three VBC profile blobs the kernel needs for call audio, from the board's own vendor
# parameter XML, and stage them where openwrt/build-rootfs.sh will pick them up.
#
#   tools/voice/make-vbc-profiles.sh [XMLDIR] [-o OUTDIR]
#
# XMLDIR defaults to work/audio/odm-xml, OUTDIR to firmware/ (which build-rootfs.sh copies into
# /lib/firmware in the image -- see its line 100). Neither is in git: firmware/ is ignored as
# proprietary build input, and work/ is ignored wholesale.
#
# WHERE THE XML COMES FROM, and why this is not a device step. The four profiles are not stored as
# binaries anywhere on the handset -- not in the rootfs, not in the vendor image, not in any
# partition dump. Android's audio HAL derives them at runtime from /odm/etc/audio_params/sprd/*.xml
# and writes the result into the kernel. So there is nothing to copy; the blobs have to be built. The
# XML is in the odm_a partition inside super, and it is EROFS, which is the one good break here: our
# own kernel mounts it, so the whole extraction happens on the device with no Android boot at all --
# which matters, because booting Android and coming back is the operation that flips the boot slot.
#
#   # once, on the device, with odm_a already dumped (see docs/changxing60/vbc-profile.md §3.2)
#   mkdir -p /tmp/odm && mount -t erofs -o loop,ro /mnt/changxing60-disk/odm_a.img /tmp/odm
#   # then pull the four files this script wants
#
# The alternative route -- let Android load them, then read them back out of /dev/vbc_turningN -- also
# works and needs no converter, but it needs an Android boot. Both should agree; the read-back one is
# the ground truth if they ever do not, because it is what the DSP actually ran on.
#
# WHAT WAS VERIFIED (2026-10-16, on the handset). The three blobs this produces were written to
# /dev/vbc_turning0/1/2 and read back, and each came back byte-for-byte identical:
#
#   audio_structure  48934 bytes  (67 modes x 730)   md5 238c36a07aef0a7cc097b1689c2cec6f
#   dsp_vbc         124728 bytes  (72 modes x 1732)  md5 bfe6097b66ed4dac3ba0d31ffe4c0265
#   cvs              55500 bytes  (67 modes x 828)   md5 76e6b2b32e2682becf8075898054c078
#
# That is the check that matters: it proves the XML->blob reading is the one the driver agrees with,
# including the absolute-offset addressing of the field table. The converter also self-checks and
# prints nothing when it is happy -- a "field(s) landed outside the mode that declares them" or
# "past the end of the array" line on stderr means the offsets did not line up and the blob is wrong.
set -eu

TOP=$(cd "$(dirname "$0")/../.." && pwd)
CONV=$TOP/tools/voice/vbc-profile.py

XMLDIR=$TOP/work/audio/odm-xml
OUTDIR=$TOP/firmware
while [ $# -gt 0 ]; do
    case $1 in
        -o) OUTDIR=${2:-}
            [ -n "$OUTDIR" ] || { echo "make-vbc-profiles: -o needs a directory" >&2; exit 2; }
            shift 2 ;;
        -h|--help) sed -n '2,22p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        -*) echo "make-vbc-profiles: unknown option $1" >&2; exit 2 ;;
        *)  XMLDIR=$1; shift ;;
    esac
done

# The three the kernel actually consumes. dsp_smartamp is deliberately absent: it is the smart-amp
# profile and this board's AW87xxx has no driver, so nothing would read it.
WANT="audio_structure dsp_vbc cvs"

missing=
for n in $WANT; do
    [ -f "$XMLDIR/$n.xml" ] || missing="$missing $n.xml"
done
if [ -n "$missing" ]; then
    cat >&2 <<EOF
make-vbc-profiles: missing$missing in $XMLDIR

These are the board's own vendor parameter files. Get them off the handset (no Android boot needed --
the odm_a partition is EROFS and our kernel mounts it):

  mkdir -p /tmp/odm && mount -t erofs -o loop,ro /mnt/changxing60-disk/odm_a.img /tmp/odm
  for f in audio_structure dsp_vbc cvs; do
      ssh root@192.168.77.1 "cat /tmp/odm/etc/audio_params/sprd/\$f.xml" > $XMLDIR/\$f.xml
  done

(or point this script at a directory you already have: $0 DIR)
EOF
    exit 1
fi

command -v python3 >/dev/null || { echo "make-vbc-profiles: python3 is needed" >&2; exit 2; }
mkdir -p "$OUTDIR"

echo "== building VBC profiles from $XMLDIR =="
# One XML per invocation is not needed, but passing all three at once is what the converter documents.
python3 "$CONV" "$XMLDIR/audio_structure.xml" "$XMLDIR/dsp_vbc.xml" "$XMLDIR/cvs.xml" -o "$OUTDIR"

echo
echo "== staged in $OUTDIR (build-rootfs.sh copies this into /lib/firmware) =="
for n in $WANT; do
    if [ -s "$OUTDIR/$n" ]; then
        printf '  %-18s %8s bytes\n' "$n" "$(wc -c < "$OUTDIR/$n")"
    else
        echo "  $n: NOT PRODUCED" >&2
        exit 1
    fi
done
echo
echo "On the device these are loaded by /opt/changxing60/bin/changxing60-vbc-load, which writes each"
echo "one to /dev/vbc_turningN and then reads it back and compares -- the driver checks only the"
echo "magic, so a blob that is well-formed but wrong would otherwise load silently."
