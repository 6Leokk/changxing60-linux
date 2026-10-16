#!/bin/bash
# 7552N deltas for upstream's *out-of-tree* modules.  Runs inside the mu300-cross container,
# right after upstream's build-modules.sh, and rebuilds only the modules it touches.
#
# Same rule as patches/: upstream/ is never edited, so a re-sync of upstream/ cannot lose this.
# build-modules.sh copies each module to /src/mod-build/<name> and builds there; we edit that
# copy and re-run make for that module alone.
#
# usage (from mainline-7552n/build.sh):  bash /work/mainline-7552n/module-deltas.sh
set -eo pipefail
KV=${KV:-6.18.56}
O=/src/out-$KV
OUT=/work/${OUTDIR:-out}

# --- sprd_wlan_combo: dispatch the SC2355 SDIO variant as well as the PCIe one -----------------
#
# Our 7552N attaches the SC2355 Marlin3 over SDIO (sdio@22220000, "sprd,sc2355-sdio-wifi"),
# upstream's boards over PCIe.  sprd_wlan_probe() therefore refuses hw_type 2 with -EINVAL:
#
#   sprd-wlan: sprd_wlan_probe sprd,sc2355-sdio-wifi 2.
#   sprd-wlan: sprd_wlan_probe error hw_type 2.
#   wlan sprd-marlin3:wlan: probe with driver wlan failed with error -22
#
# ...so no wlan0 is ever created, even though wcn_bsp brings the chip up over SDIO perfectly
# (sdiohal_scan_card finds the card at 8800, func1 is enabled, the 3 MB btwifi firmware is
# downloaded at 32 KB per 2.5 ms, the chip answers its AT channel).  The SDIO variant is *built*
# (sc2355/sdio.o is in the Kbuild, sc2355_sdio_probe() is live at sc2355/sdio.c:1725 and does
# the same sprd_iface_probe() as its PCIe sibling), only the dispatcher is stubbed out.
wlan_c=/src/mod-build/sprd_wlan_combo/common/sprd_wlan.c
[ -f "$wlan_c" ] || { echo "sprd_wlan_combo: $wlan_c missing (run build-modules.sh first)" >&2; exit 1; }
python3 - "$wlan_c" <<'PY'
import sys
p = sys.argv[1]
s = open(p).read()
old = '''\t/* MU300 build: only the SC2355 PCIe variant is compiled in */
\tif (p_match_data->hw_type == SPRD_HW_SC2355_PCIE) {
\t\treturn pcie_probe(pdev);
\t} else {

\t\tpr_err("%s error hw_type %d.\\n", __func__, p_match_data->hw_type);
\t\tdump_stack();
\t\treturn -EINVAL;
\t}'''
new = '''\t/* 7552N: the SC2355 is wired to SDIO here (sdio@22220000, "sprd,sc2355-sdio-wifi"), not
\t * PCIe, so the SDIO variant has to be dispatched too -- upstream's boards attach it over
\t * PCIe and left this branch returning -EINVAL.  Both end in sprd_iface_probe(). */
\tif (p_match_data->hw_type == SPRD_HW_SC2355_PCIE)
\t\treturn pcie_probe(pdev);
\tif (p_match_data->hw_type == SPRD_HW_SC2355_SDIO)
\t\treturn sc2355_sdio_probe(pdev);

\tpr_err("%s error hw_type %d.\\n", __func__, p_match_data->hw_type);
\tdump_stack();
\treturn -EINVAL;'''
if new in s:
    print('  sprd_wlan_combo: SDIO dispatch already applied')
elif old in s:
    open(p, 'w').write(s.replace(old, new, 1))
    print('  sprd_wlan_combo: SDIO dispatch applied')
else:
    sys.exit('  sprd_wlan_combo: sprd_wlan_probe() dispatch block not found -- upstream changed it')
PY

src=/src/mod-build/sprd_wlan_combo
[ -f /src/mod-build/wcn_bsp/Module.symvers ] || { echo "wcn_bsp/Module.symvers missing" >&2; exit 1; }
echo "  sprd_wlan_combo: rebuilding"
make -C "$O" ARCH=arm64 M="$src" KBUILD_EXTRA_SYMBOLS=/src/mod-build/wcn_bsp/Module.symvers \
     -j"$(nproc)" modules > "$OUT/modules/sprd_wlan_combo.log" 2>&1 ||
    { tail -30 "$OUT/modules/sprd_wlan_combo.log"; exit 1; }
cp "$src/sprd_wlan_combo.ko" "$OUT/modules/"
# the kernel's own modules are stripped by modules_install; keep this one consistent
strip --strip-debug "$OUT/modules/sprd_wlan_combo.ko"
ls -l "$OUT/modules/sprd_wlan_combo.ko"
