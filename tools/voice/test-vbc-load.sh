#!/bin/bash
# Host test for the changxing60-vbc-load / changxing60-vbc-dump marker gate, against fake device
# nodes. No device, no kernel, nothing in /dev.
#
# WHY THIS EXISTS. The boot service once read /dev/vbc_turning0 before loading anything, the driver
# dereferenced the NULL structure pointer (reads over 24 bytes take the data branch, and that
# branch has no null check), and panic_on_oops turned a dd into a board reboot (2026-10-17,
# docs audio-oops.md). The fix is a per-boot marker: full-size reads happen only when
# /tmp/changxing60-vbc-loaded says audio_structure is in the kernel. This script is that contract:
#
#   1. a cold run loads, sets the marker, and reads back exactly ONCE (the after-snapshot);
#   2. a warm run reads before and after, writes nothing, and says "already loaded";
#   3. --check with no marker reads NOTHING at all -- zero calls into the dump path;
#   4. if audio_structure fails to land, the marker is NOT set and the after-snapshot does not
#      happen either -- that was the second latent crash site;
#   5. the dump itself refuses turning0 without the marker, parses a real profile through its full
#      magic/u32/length cross-check when the marker or ALLOW_UNLOADED lets it read.
#
# CHANGXING60_VBC_DEV_PREFIX exists so this can point both scripts at $TMP/dev/vbc_turningN regular
# files; on the device it is never set and the real nodes are used.
#
# Usage: tools/voice/test-vbc-load.sh
set -uo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
TOP=$(cd "$HERE/../.." && pwd)
LOAD=$TOP/rootfs/overlay/opt/changxing60/bin/changxing60-vbc-load
DUMP=$TOP/tools/voice/changxing60-vbc-dump

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
pass=0; fail=0
ok()   { pass=$((pass + 1)); printf '  ok    %s\n' "$1"; }
no()   { fail=$((fail + 1)); printf '  FAIL  %s\n' "$1"; }
check() { if [ "$2" = "$3" ]; then ok "$1: $3"; else no "$1: expected [$2], got [$3]"; fi; }
# grep -c prints 0 and exits 1 on no match; without || true that would trip pipefail.
count() { c=$(grep -c "$1" "$2" 2>/dev/null) || true; echo "${c:-0}"; }

MARKER=$TMP/marker
CALLS=$TMP/dump-calls
DEVDIR=$TMP/dev/vbc_turning
FWDIR=$TMP/firmware
mkdir -p "$(dirname "$DEVDIR")" "$FWDIR"

# A minimal well-formed profile: magic[16], u32 num_mode=2, u32 len_mode=8, 16 payload bytes = 40.
# vbc-load never inspects contents (it byte-compares), but case 5 runs the REAL dump parser, so
# the fixtures have to be real-enough profiles, not random bytes. The payload carries the name so
# three blobs are distinguishable and a cross-wired node would be caught by cmp.
mkblob() { # mkblob NAME
    {   printf 'audio_profile\0\0\0'
        printf '\002\000\000\000\010\000\000\000'
        printf '%-16.16s' "payload-$1"
    } > "$FWDIR/$1"
}
for b in audio_structure dsp_vbc cvs; do mkblob "$b"; done
check "fixture blob size (magic16 + 2*u32 + 16)" "40" "$(wc -c < "$FWDIR/audio_structure")"

# Stub dump: mimics only the safety contract -- it refuses everything while the marker is absent
# and logs every call -- so "read NOTHING" assertions are direct evidence, not inference from
# file contents.
cat > "$TMP/stub-dump" <<STUB
#!/bin/sh
out=\$1
echo called >> "$TMP/dump-calls"
mkdir -p "\$out" 2>/dev/null
[ -f "$MARKER" ] || exit 1
i=0
for name in audio_structure dsp_vbc cvs dsp_smartamp; do
    node="$(dirname "$DEVDIR")/vbc_turning\$i"
    [ -s "\$node" ] && cp "\$node" "\$out/\$name.bin" 2>/dev/null
    i=\$((i + 1))
done
exit 0
STUB
chmod +x "$TMP/stub-dump"

envbase=(CHANGXING60_VBC_DEV_PREFIX="$DEVDIR" CHANGXING60_VBC_FW="$FWDIR"
         CHANGXING60_VBC_LOG="$TMP/vbc-load.log" CHANGXING60_VBC_LOADED="$MARKER"
         CHANGXING60_VBC_DUMP="$TMP/stub-dump")

run_load() { local out=$1; shift
    env "${envbase[@]}" sh "$LOAD" "$@" >"$out" 2>&1; }
run_dump() { local out=$1; shift
    env CHANGXING60_VBC_DEV_PREFIX="$DEVDIR" CHANGXING60_VBC_LOADED="$MARKER" \
        sh "$DUMP" "$@" >"$out" 2>&1; }
reset() { rm -f "$MARKER" "$CALLS" "$TMP/vbc-load.log"; rm -f "$DEVDIR"0 "$DEVDIR"1 "$DEVDIR"2 "$DEVDIR"3;
         # the real driver CREATES the nodes at module load and writes them later; the loader must
         # not be asked to simulate that, and must refuse a missing node (the case 4 blob check
         # and the device behaviour both depend on nodes existing-but-empty)
         touch "$DEVDIR"0 "$DEVDIR"1 "$DEVDIR"2 "$DEVDIR"3; }

echo "changxing60-vbc-load/dump marker test (host, fake nodes)"

echo
echo "[1] cold boot: no marker, kernel empty"
reset
rc=0; run_load "$TMP/out1" || rc=$?
check "exit" "0" "$rc"
[ -f "$MARKER" ] && ok "marker set after a successful audio_structure write" || no "marker NOT set"
check "dump calls (before skipped, after runs)" "1" "$(count called "$CALLS")"
[ "$(count 'snap: skipped' "$TMP/vbc-load.log")" = 1 ] && ok "before-snapshot skipped and logged" || no "skip not logged"
cmp -s "$FWDIR/audio_structure" "$DEVDIR"0 && ok "audio_structure written to node 0" || no "node 0 content wrong"
cmp -s "$FWDIR/dsp_vbc" "$DEVDIR"1 && ok "dsp_vbc written to node 1" || no "node 1 content wrong"
cmp -s "$FWDIR/cvs" "$DEVDIR"2 && ok "cvs written to node 2" || no "node 2 content wrong"
check "verified count in log" "3" "$(count 'verified:' "$TMP/vbc-load.log")"
grep -q 'complete: 3 profiles' "$TMP/vbc-load.log" && ok "log closes with complete" || no "no complete line"

echo
echo "[2] warm run: marker present, kernel already holds them"
rm -f "$CALLS"
rc=0; run_load "$TMP/out2" || rc=$?
check "exit" "0" "$rc"
check "dump calls (before AND after)" "2" "$(count called "$CALLS")"
check "already-loaded count" "3" "$(count 'already loaded:' "$TMP/vbc-load.log")"
check "writes this run" "0" "$(count 'wrote:' "$TMP/vbc-load.log")"
check "verified count" "3" "$(count 'verified:' "$TMP/vbc-load.log")"

echo
echo "[3] --check with no marker: zero reads, would-load only"
reset
rc=0; run_load "$TMP/out3" --check || rc=$?
check "exit" "0" "$rc"
check "dump calls" "0" "$(count called "$CALLS")"
check "would-load lines" "3" "$(count 'would load' "$TMP/out3")"
[ ! -f "$MARKER" ] && ok "--check never touches the marker" || no "--check SET the marker"

echo
echo "[4] audio_structure fails to land: marker stays off, NO after-snapshot"
reset
mv "$FWDIR/audio_structure" "$TMP/audio_structure.held"
rc=0; run_load "$TMP/out4" || rc=$?
check "exit (incomplete must be 1)" "1" "$rc"
[ ! -f "$MARKER" ] && ok "marker NOT set when structure did not load" || no "marker set anyway"
check "dump calls (after-snapshot skipped too)" "0" "$(count called "$CALLS")"
[ "$(count 'wrote: dsp_vbc' "$TMP/vbc-load.log")" = 1 ] && ok "the safe writes still happened" || no "dsp_vbc not written"
mv "$TMP/audio_structure.held" "$FWDIR/audio_structure"

echo
echo "[5] the real dump against fake nodes: refuse, marker, parse"
reset
cp "$FWDIR/audio_structure" "$DEVDIR"0
cp "$FWDIR/dsp_vbc" "$DEVDIR"1
cp "$FWDIR/cvs" "$DEVDIR"2
rc=0; run_dump "$TMP/out5a" "$TMP/dump5a" || rc=$?
grep -q 'refused' "$TMP/out5a" && ok "turning0 refused without the marker" || no "no refusal for turning0"
# nodes 1/2 hold profiles and their reads are the safe ENOMEM-checked kind: exit is 0 because the
# dump got SOMETHING, and the asymmetry (0 gated, 1-3 not) is the whole point of the gate.
check "exit: profiles 1-2 still readable without the marker" "0" "$rc"
[ ! -f "$TMP/dump5a/audio_structure.bin" ] && ok "no audio_structure.bin was produced" || no "dump produced audio_structure WITHOUT the marker"
[ -f "$TMP/dump5a/dsp_vbc.bin" ] && ok "dsp_vbc/cvs still parsed on a gated run" || no "safe nodes not parsed"
touch "$MARKER"
rc=0; run_dump "$TMP/out5b" "$TMP/dump5b" || rc=$?
check "exit with marker" "0" "$rc"
cmp -s "$FWDIR/audio_structure" "$TMP/dump5b/audio_structure.bin" \
    && ok "marker allows the read; 40-byte profile passes the cross-check" \
    || no "marker run did not parse node 0"
rm -f "$MARKER"
rc=0; env CHANGXING60_VBC_ALLOW_UNLOADED=1 CHANGXING60_VBC_DEV_PREFIX="$DEVDIR" \
    CHANGXING60_VBC_LOADED="$MARKER" sh "$DUMP" "$TMP/dump5c" >"$TMP/out5c" 2>&1 || rc=$?
check "exit with ALLOW_UNLOADED=1 (Android shape)" "0" "$rc"
[ -f "$TMP/dump5c/audio_structure.bin" ] && ok "override reads turning0 anyway" || no "override did not read node 0"

echo
echo "pass=$pass fail=$fail"
[ "$fail" = 0 ] || exit 1
echo "OK"
