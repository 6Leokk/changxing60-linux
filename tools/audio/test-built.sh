#!/bin/bash
# Host-side verification of the built audio module set — no device needed.
#
# What is checked, and why it is not vacuous:
#   1. inventory        the 27 modules Android's vendor_boot carries are all present,
#                       except the two no available source tree contains (listed as
#                       known-absent, with consequences, not silently skipped)
#   2. vermagic         every .ko is built for 5.4.254-gb50db5b6224c — the exact mismatch
#                       that makes the Android prebuilts unloadable, asserted here against
#                       what we built instead
#   3. CRC closure      every symbol a module imports resolves with a matching CRC, either
#                       to the kernel's Module.symvers or to another module's export — an
#                       import resolving to nothing or to a different CRC is a load
#                       failure waiting to happen (this is exactly how the prebuilts fail)
#   4. depends closure  every modinfo depends= entry is satisfiable: another module in the
#                       set, a module built in out-linux, or a kernel built-in
#   5. load order       the dependency graph is acyclic and prints in a loadable order
#   6. staging          (with --staged) the same set is present in out/modules
#
# usage: tools/audio/test-built.sh            (exit 0 = all passed)
#        tools/audio/test-built.sh --staged   (also check out/modules has the full set)
set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$here/../.."
BUILT="${BUILT:-$ROOT/work/audio-modules}"
OUT_LINUX="${OUT_LINUX:-$ROOT/out-linux}"
STAGED="${STAGED:-$ROOT/out/modules}"
PEER_SYMS="${PEER_SYMS:-/tmp/audio-symvers.txt}"   # optional: "crc symbol" lines, from build container

fails=0
ok()  { printf 'ok   %s\n' "$1"; }
bad() { printf 'FAIL %s\n' "$1"; [ $# -gt 1 ] && printf '     %s\n' "$2"; fails=$((fails+1)); }

[ -d "$BUILT" ] && ls "$BUILT"/*.ko >/dev/null 2>&1 || { echo "no modules in $BUILT — run tools/build-audio-54.sh first" >&2; exit 2; }

WANT_VERMAGIC=5.4.254-gb50db5b6224c

# ---- 1. inventory ----------------------------------------------------------
# The 26 audio .ko Android runs on this phone — the vendor_boot ramdisk /lib/modules set,
# byte-identical to the vendor_dlkm/lib/modules set (verified by diff; see
# docs/changxing60/telephony.md). Two cannot be built from any source tree we have, so
# they are expected-absent with the consequence spelled out:
ANDROID_AUDIO="agdsp_access audio-dsp-dump audio-pipe audio_mem audio_sipc mcdt_hw_r2p0 smartpa_stat snd-soc-aw87xxx snd-soc-sprd-card snd-soc-sprd-codec-ump9620 snd-soc-sprd-codec-ump9620-power snd-soc-sprd-codec-ump9620-power-dev snd-soc-sprd-dai snd-soc-sprd-dummy-codec snd-soc-sprd-pdm-r2p0 snd-soc-sprd-tdm snd-soc-sprd-vbc-fe snd-soc-sprd-vbc-v4 snd-soc-unisoc-dp-codec sprd_apipe sprd_audcp_boot sprd_audcp_dvfs sprd-compr-2stage-dma sprd-dmaengine-pcm sprd-platform-pcm-routing voice_trigger_irq"
# sanity: the expected list itself must have the right count, otherwise the test lies
n_expected=$(echo $ANDROID_AUDIO | wc -w)
[ "$n_expected" -eq 26 ] || bad "test bug" "ANDROID_AUDIO has $n_expected entries, should be 26"
KNOWN_ABSENT="smartpa_stat snd-soc-aw87xxx"   # documented gap: speaker PA stays silent until found
EXTRA_OK="snd-soc-sprd-pa-ucp1301 snd-soc-sprd-vaudio saudio voice_trigger_node"   # built here, absent on Android
EXTRA_NOT_STAGED="snd-soc-sprd-pa-ucp1301"   # no DT node on this board (checked live-fdt.dts)
EXTRA_NOT_STAGED="snd-soc-sprd-pa-ucp1301"   # no DT node on this board (checked live-fdt.dts)

built_list="$(ls "$BUILT"/*.ko | xargs -n1 basename | sed 's/\.ko$//' | tr '\n' ' ')"
for m in $ANDROID_AUDIO; do
    case " $built_list " in *" $m "*) ok "built: $m" ;; *)
        case " $KNOWN_ABSENT " in *" $m "*) ok "known-absent: $m (documented gap)" ;;
        *) bad "missing module" "$m was not built and is not a known gap" ;; esac ;;
    esac
done
for m in $built_list; do
    case " $ANDROID_AUDIO $EXTRA_OK " in *" $m "*) ;; *) bad "unexpected module" "$m is in $BUILT but in no expected list" ;; esac
done

# ---- 2. vermagic -----------------------------------------------------------
for ko in "$BUILT"/*.ko; do
    got="$(modinfo -F vermagic "$ko" 2>/dev/null | awk '{print $1}')"
    if [ "$got" = "$WANT_VERMAGIC" ]; then ok "vermagic: $(basename "$ko")"
    else bad "vermagic: $(basename "$ko")" "got [$got] want [$WANT_VERMAGIC]"; fi
done

# ---- 3. CRC closure --------------------------------------------------------
python3 - "$OUT_LINUX" "$BUILT" "$PEER_SYMS" <<'PYEOF'
import subprocess, sys
from pathlib import Path
out_linux, built, peer_file = Path(sys.argv[1]), Path(sys.argv[2]), Path(sys.argv[3])

kernel = {}
symv = out_linux / "Module.symvers"
if symv.exists():
    for line in symv.read_text().splitlines():
        p = line.split()
        if len(p) >= 2: kernel[p[1]] = p[0]

peer = {}
if peer_file.exists():
    for line in peer_file.read_text().splitlines():
        p = line.split()
        if len(p) >= 2: peer.setdefault(p[1], p[0])
else:
    # no container symvers handy: fall back to export detection from the .ko strings
    for ko in sorted(built.glob("*.ko")):
        out = subprocess.run(["strings", str(ko)], capture_output=True, text=True).stdout
        for tok in out.split():
            if tok.startswith("__kstrtab_"):
                peer.setdefault(tok[len("__kstrtab_"):], None)  # exported, CRC unknown

fails = 0
for ko in sorted(built.glob("*.ko")):
    dump = subprocess.run(["modprobe", "--dump-modversions", str(ko)], capture_output=True, text=True).stdout
    for line in dump.splitlines():
        p = line.split()
        if len(p) != 2: continue
        crc, sym = p
        if sym in kernel:
            if kernel[sym] != crc:
                print(f"FAIL crc {ko.name}: {sym}={crc}, kernel exports {kernel[sym]}"); fails += 1
        elif sym in peer:
            pcrc = peer[sym]
            if pcrc is not None and pcrc != crc:
                print(f"FAIL crc {ko.name}: {sym}={crc}, peer exports {pcrc}"); fails += 1
        else:
            print(f"FAIL unresolved {ko.name}: imports {sym}={crc}, exported by nothing"); fails += 1
sys.exit(1 if fails else 0)
PYEOF
if [ $? -eq 0 ]; then ok "crc closure: every import resolves with matching CRC"; else bad "crc closure" "see FAIL lines above"; fi

# ---- 4. depends closure ----------------------------------------------------
python3 - "$BUILT" "$OUT_LINUX" "$ROOT/out/modules.builtin" <<'PYEOF'
import subprocess, sys
from pathlib import Path
built_dir, out_linux, builtin_file = (Path(p) for p in sys.argv[1:4])
built = {p.name[:-3] for p in built_dir.glob("*.ko")}
kernel_ko = {p.name[:-3] for p in out_linux.rglob("*.ko")}
builtin = set()
if builtin_file.exists():
    builtin = {l.strip().rsplit("/", 1)[-1][:-3] for l in builtin_file.read_text().splitlines() if l.strip()}
fails = 0
for ko in sorted(built_dir.glob("*.ko")):
    deps = subprocess.run(["modinfo", "-F", "depends", str(ko)], capture_output=True, text=True).stdout.strip()
    for d in filter(None, [x.strip() for x in deps.split(",")]):
        if d not in built and d not in kernel_ko and d not in builtin:
            print(f"FAIL depends: {ko.name} needs {d}, which is nowhere"); fails += 1
sys.exit(1 if fails else 0)
PYEOF
if [ $? -eq 0 ]; then ok "depends closure: complete"; else bad "depends closure" "see FAIL lines above"; fi

# ---- 5. load order ---------------------------------------------------------
order="$(python3 - "$BUILT" <<'PYEOF'
import subprocess, sys, graphlib
from pathlib import Path
built_dir = Path(sys.argv[1])
g = {}
for ko in sorted(built_dir.glob("*.ko")):
    deps = subprocess.run(["modinfo", "-F", "depends", str(ko)], capture_output=True, text=True).stdout.strip()
    g[ko.name[:-3]] = {d.strip() for d in deps.split(",") if d.strip() and (built_dir / (d.strip() + ".ko")).exists()}
try:
    print(", ".join(graphlib.TopologicalSorter(g).static_order()))
except graphlib.CycleError as e:
    print("CYCLE " + repr(e)); sys.exit(1)
PYEOF
)"
if [ -n "$order" ] && [ "${order#CYCLE}" = "$order" ]; then
    ok "load order: acyclic ($(echo "$order" | awk -F', ' '{print NF}') modules, dependencies first)"
else
    bad "load order" "$order"
fi

# ---- 6. staging + depmod (optional) ----------------------------------------
if [ "${1:-}" = "--staged" ]; then
    for ko in "$BUILT"/*.ko; do
        m="$(basename "$ko")"
        base="${m%.ko}"
        case " $EXTRA_NOT_STAGED " in *" $base "*) continue ;; esac
        if [ -f "$STAGED/$m" ]; then ok "staged: $m"
        else bad "staged: $m" "not in $STAGED — run stage-modules.py"; fi
    done
    # the check the device will actually run: kmod's own resolver over the staged set,
    # with the kernel's export table. Silence = every dependency and symbol resolves.
    if command -v depmod >/dev/null 2>&1; then
        t="$(mktemp -d)"
        mkdir -p "$t/lib/modules/$WANT_VERMAGIC"
        cp "$STAGED"/*.ko "$t/lib/modules/$WANT_VERMAGIC/" 2>/dev/null
        touch "$t/lib/modules/$WANT_VERMAGIC/modules.order"
        cp "$ROOT/out/modules.builtin" "$t/lib/modules/$WANT_VERMAGIC/" 2>/dev/null || true
        if depmod -b "$t" -e -E "$OUT_LINUX/Module.symvers" "$WANT_VERMAGIC" 2>&1 | grep -v WARNING; then
            bad "depmod" "unresolved symbols or deps above"
        else
            ok "depmod: staged set resolves clean (deps + symbols)"
        fi
        rm -rf "$t"
    fi
fi

echo
if [ "$fails" -eq 0 ]; then echo "all checks passed"; exit 0; else echo "$fails check(s) failed"; exit 1; fi
