#!/usr/bin/env python3
"""Add the mainline bindings the 7552N's vendor DTB is missing, then repack vendor_boot.

Why this exists
---------------
Upstream's whole 6.18 port works *on the stock vendor DTB*: LK picks the DTB out of vendor_boot, merges its
dtbo overlays and fixes it up, and mainline drivers are either patched to accept the vendor compatibles or are
driven by port/drivers shims.  (A *replacement* DTB was tried upstream and hung in setup_machine_fdt -- LK
itself parses the DTB, so removing vendor nodes is fatal.  Adding properties is not.)

Our board is the one thing upstream never had: the 7552N boots from **UFS**, and
`drivers/ufs/host/ufs-sprd.c` wants a node that the vendor writes differently:

    mainline binding (sprd,ums9620-ufs)        vendor node (sprd,ufshc)
    ------------------------------------       ---------------------------------------------
    compatible = "sprd,ums9620-ufs"            compatible = "sprd,ufshc"
    reset-names = "controller","device"        reset-names = "ufs_soft_rst","ufsdev_soft_rst"
    sprd,ufs-anlg-syscon = <&anlg>             phy_sram_* = <0x12 0x0c 0x0{1,2,4}>   (raw triple)
    sprd,aon-apb-syscon = <&ap_apb>            ufsdev_refclk_en = <0x02 0xce8 0x02>  (raw triple)
                                               usb31pllv_ref2mphy_en = <0x02 0xcfc 0x01>

The vendor's raw triples are exactly (syscon phandle, offset, bit) and match the driver's regmap_update_bits()
calls one for one (0xc bits 1/2/4 on the analog glbregs; 0xce8 bit 1 and 0xcfc bit 0 on the AP-APB glbregs).
So the driver needs no code change -- only those four properties.

Everything here is *additive*: the vendor compatible stays in the list (so the 5.4 vendor kernel, which binds
"sprd,ufshc" and looks resets up by the vendor names, keeps working off the same vendor_boot), and the vendor
reset-names/entries are kept with the mainline names appended.

usage:
  patch-vendor-dtb.py --vendor-boot work/dumps/vendor_boot_b.img --out work/vendor_boot_b-7552n.img
  patch-vendor-dtb.py --dtb-only out.dtb          # just produce the patched DTB (no repack)

Needs `dtc` and python3; upstream/mkvendorboot.py does the repack.  Run it where dtc exists, e.g.
  docker run --rm -v "$PWD":/w -v /tmp:/tmp changxing60-cross \
      python3 /w/mainline-7552n/tools/patch-vendor-dtb.py --vendor-boot /w/work/dumps/vendor_boot_b.img \
                                                          --out /w/work/vendor_boot_b-7552n.img
"""
import argparse
import re
import struct
import subprocess
import sys
import os

DT_TABLE_MAGIC = 0xd7b7ab1e

# The syscon phandles are *raw cells*, deliberately: dtc keeps the explicit `phandle = <...>;` properties the
# vendor DTB carries, so the numbers survive a dtc round trip and stay valid.  verify() below asserts that.
NODE_EDITS = {
    # ufs@2000000 lives at /soc/ap-ahb/ufs@2000000, but the unit name is unique in the tree -- and unlike the
    # path it cannot be broken by a differently-spelled parent node.
    "ufs@2000000": {
        "compatible": '"sprd,ums9620-ufs", "sprd,ufshc"',
        # 0x12 = syscon@64380000, which the vendor dtsi labels &anlg_phy_g12_regs: the vendor's
        # phy_sram_init_done/ext_ld_done/bypass triples are its offset 0xc bits 1/2/4, i.e. exactly the
        # writes ufs-sprd.c makes through SPRD_UFS_ANLG.
        "sprd,ufs-anlg-syscon": "<0x12>",
        # 0x02 = syscon@64900000, the AON APB glbregs (&aon_apb_regs): +0xCE8 is REG_AON_APB_UFSDEV_REG
        # (the driver's APB_UFSDEV_REG) and +0xCFC is REG_AON_APB_USB31PLL_CTRL_MISC (APB_USB31PLL_CTRL)
        # -- the same offsets as the vendor's dt-bindings header for qogirn6pro.
        "sprd,aon-apb-syscon": "<0x02>",
        # vendor names first so the 5.4 kernel still finds them, mainline names appended
        "reset-names": '"ufs_soft_rst", "ufsdev_soft_rst", "controller", "device"',
        # same two entries, duplicated under the mainline names (reset_control_get() looks them up by name,
        # so entry order is what matters and each entry keeps its own provider phandle)
        "resets": "<0x0d 0x04 0x11 0x45 0x0d 0x04 0x11 0x45>",
    },
    # USB: the trial boot came up with udc=none, and this is why.
    #
    # dwc3@25100000 carries `usb-phy = <0x60 0x24>` -> index 0 = dummyphy, index 1 = ssphy@25310000.
    # mainline dwc3_core_get_phy() resolves those through the *legacy* USB PHY framework
    # (devm_usb_get_phy_by_phandle).  __of_usb_find_phy() returns -ENODEV -- which dwc3 deliberately
    # treats as "no phy configured", non-fatal -- only when the node is NOT available; otherwise it
    # returns -EPROBE_DEFER.
    #
    # The ssphy is fine: the ported phy-sprd-ums9620-ssphy.c registers a real usb_phy
    # (usb_add_phy_dev(), line ~811), so index 1 resolves.  But `sprd,usb-dummy-phy` has no driver
    # anywhere in 6.18 (tree-wide grep: nothing), so index 0 deferred forever -> dwc3 never probed ->
    # no UDC -> no usb0 -> no management interface.
    #
    # Disabling the node (additively: the node stays, only its status changes) makes that lookup return
    # -ENODEV, which is exactly the mainline meaning of this DT: usb2_phy = NULL, usb3_phy = ssphy.
    #
    # !! vendor_boot_b IS SHARED WITH THE 5.4 OPENWRT BOOT -- read this before flashing it !!
    # LK takes the DTB from the selected slot's vendor_boot, so the *same* vendor_boot_b feeds both the
    # 6.18 mainline trial and the 5.4 OpenWrt boot.  Disabling dummyphy is right for mainline and fatal
    # for 5.4: there the node is what creates the platform device our phy_sprd_dummy binds to, so with
    # status="disabled" nothing registers a usb_phy, dwc3-sprd's legacy lookup fails ("unable to get
    # usb2.0 phy device"), and the boot finishes with no UDC, no gadget and no management interface --
    # the box boots and is unreachable.  That is not hypothetical: this edit was flashed on 2026-10-14
    # and every slot-b OpenWrt boot after it came up with dead USB until 2026-10-16, which was
    # misdiagnosed twice (first as a sipa_dele.ko regression, then as a module-order race) because the
    # boot images being compared were not where the difference lived.
    #
    # The way back is cheap and does not need a repack: "disabled" is 9 bytes with the NUL and "okay" 5,
    # both padding into a 12-byte slot, so `vendor-dtb-status.py --set okay` rewrites the 9 bytes in
    # place, leaves the blob the same size, and is verified by a full-partition sha256.  Do that before
    # returning to OpenWrt (tools/changxing60-dtb-fix.sh drives it from Android over adb); for the opposite
    # direction -- okay -> disabled, which does not fit the padding and *does* need this script and a
    # repack -- run this tool again.
    "dummyphy": {
        "status": '"disabled"',
    },
    # GPU: the vendor DTB leaves the GPU unpowered, and that is the whole reason Mali never came up.
    #
    # The first trial boot with Mali enabled froze the system in the same millisecond mali_kbase.ko loaded
    # (t=13.7s).  console-ramoops holds the story and it ends like this:
    #
    #   [13.718963] mali 23140000.gpu: supply gpu not found, using dummy regulator
    #   [13.733363] mali_power_on vddgpu is not ready! in_progress:1 gpu_power_state:0
    #   [13.745080] WARNING: ... mali_kbase_config_qogirn6pro.c:837 mali_power_on+0x1a0/0x210 [mali_kbase]
    #   [13.984596] ---[ end trace 0000000000000000 ]---
    #   <nothing, ever>
    #
    # No panic and no "reboot: Restarting system" -- the CPUs stopped on a bus access and sprd_pmic_wdt
    # (loaded at t=3.5s) hard-reset the board.  mali_top_state_check() polls gpu_top_state and printk()s every
    # 20 iterations; not one of those lines appears, so the freeze is at or before its first regmap_read, i.e.
    # in mali_power_on()'s prologue: top_force_shutdown (0x649112c4 bit 25), the gpll_cfg force-off/on pair
    # (0x64910a20 bits 1/0) and reset_control_assert/deassert(gpu_soft_rst) on "sprd,ums9620-pmu-gate".
    #
    # The cause is upstream of those writes.  mali_poweron_first_part() only advances the state machine
    # through devm_regulator_get(dev, "gpu"):
    #
    #   if (!regulator_is_enabled(gpu_reg_ptr)) { regulator_enable(...); atomic_inc(&dcdc_gpu_state); }
    #
    # but the vendor node has no `gpu-supply` and its DCDC_GPU regulator is `status = "disabled"`, so the
    # driver falls back to the *dummy* regulator, whose regulator_is_enabled() is hard-wired to 1.  The
    # enable is skipped, dcdc_gpu_state stays 0, mali_power_on() WARNs -- and then powers up the GPU domain
    # and switches GPLL on a rail nobody ever turned on.  The vendor kernel gets away with it because its
    # bootloader already left vddgpu running.
    #
    # The fix is a DT fix, not a driver port: mainline's ump9620-regulator.c *does* implement DCDC_GPU
    # (UMP9620_REGU_LINEAR(DCDC_GPU, UMP9620_POWER_PD_SW, UMP9620_DCDC_GPU_PD_MASK, UMP9620_DCDC_GPU_VOL, ...)),
    # and enabling it switches the GPU power domain as well (the PD_SW mask is the same register the node's
    # `dcdc_gpu_pd = <0x04 0x201c 0x08>` names).  So: turn DCDC_GPU back on, and point the GPU node's
    # gpu-supply at it.  Then regulator_enable() really raises vddgpu, dcdc_gpu_state advances and
    # mali_power_on()'s prologue runs against a powered domain.
    #
    # (The isolation used while this was being worked out -- status = "disabled" on the GPU node -- is gone:
    # it only ever stopped the platform driver from binding.)
    "DCDC_GPU": {
        "status": '"okay"',
    },
    "gpu@23140000": {
        "status": '"okay"',
        # phandle 0x17f = the DCDC_GPU node above, asserted by EXPECT_PHANDLES before and after the edit
        "gpu-supply": "<0x17f>",
    },
}

# phandle -> what we expect it to be, checked before and after the edit so a dtc round trip can never
# silently repoint a syscon at some other node.  DCDC_GPU is the GPU's supply (see NODE_EDITS): the
# driver's devm_regulator_get(dev, "gpu") follows gpu-supply, so a stale repoint would hand the GPU
# somebody else's rail.
EXPECT_PHANDLES = {0x02: "syscon@64900000", 0x12: "syscon@64380000", 0x17f: "DCDC_GPU"}


def run(cmd, **kw):
    return subprocess.run(cmd, check=True, **kw)


def extract_dtb(vendor_boot):
    """Pull the (single-entry) DTB out of a vendor_boot v4 image's DT table."""
    b = open(vendor_boot, 'rb').read()
    if b[:8] != b'VNDRBOOT' or struct.unpack_from('<I', b, 8)[0] != 4:
        sys.exit('not a vendor_boot v4 image')
    page, = struct.unpack_from('<I', b, 12)
    vr_size, = struct.unpack_from('<I', b, 24)
    hsize, dtb_size = struct.unpack_from('<II', b, 2096)
    al = lambda x: (x + page - 1) // page * page
    o_dtb = al(hsize) + al(vr_size)
    old = b[o_dtb:o_dtb + dtb_size]
    magic, total, h_size, e_size, e_count, e_off, t_page, t_ver = struct.unpack_from('>8I', old, 0)
    if magic != DT_TABLE_MAGIC or e_count < 1:
        sys.exit('unexpected DTB section format')
    dt_size, dt_off = struct.unpack_from('>II', old, e_off)
    return old[e_off + e_size:e_off + e_size + dt_size]


def dts_of(dtb, dts):
    run(['dtc', '-I', 'dtb', '-O', 'dts', '-o', dts, dtb],
        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    return open(dts).read()


def dtb_of(dts, dtb):
    run(['dtc', '-I', 'dts', '-O', 'dtb', '-o', dtb, dts],
        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    return open(dtb, 'rb').read()


def phandle_map(dts_text):
    """{phandle: unit-name} for the nodes that carry an explicit phandle property."""
    out = {}
    stack = []
    for ln in dts_text.splitlines():
        stripped = ln.strip()
        # note the '@': unit addresses (syscon@64900000) carry one, and dropping it silently broke the
        # stack, which made every phandle come back as '?'
        m = re.match(r'^(?:[A-Za-z_][\w-]*:\s*)?([A-Za-z0-9_,.+@#-]+)\s*\{$', stripped)
        if m:
            stack.append(m.group(1))
            continue
        if stripped.startswith('}'):
            if stack:
                stack.pop()
            continue
        m = re.match(r'phandle = <0x([0-9a-fA-F]+)>;', stripped)
        if m:
            out[int(m.group(1), 16)] = stack[-1] if stack else '?'
    return out


def node_block(lines, needle):
    """(first, last) line indexes of the node whose opening line names `needle`, brace-matched."""
    start = None
    for i, ln in enumerate(lines):
        if re.search(r'(^|\s)' + re.escape(needle) + r'\s*\{', ln):
            start = i
            break
    if start is None:
        sys.exit(f'node {needle} not found in the DTB')
    depth = 0
    for i in range(start, len(lines)):
        depth += lines[i].count('{') - lines[i].count('}')
        if depth == 0 and i > start:
            return start, i
    sys.exit(f'node {needle}: unbalanced braces')


def apply_edits(dts_text):
    for needle, props in NODE_EDITS.items():
        lines = dts_text.splitlines()
        first, last = node_block(lines, needle)
        indent = re.match(r'\s*', lines[first + 1]).group(0) if last > first + 1 else '\t\t\t'
        for name, value in props.items():
            new = f'{indent}{name} = {value};'
            pat = re.compile(r'^\s*' + re.escape(name) + r'\s*=\s*.*;\s*$')
            for i in range(first + 1, last):
                if pat.match(lines[i]):
                    lines[i] = new
                    print(f'  {needle}: replaced {name}')
                    break
            else:
                lines.insert(first + 1, new)
                print(f'  {needle}: added {name}')
                first, last = node_block(lines, needle)
        dts_text = '\n'.join(lines) + '\n'
    return dts_text


def verify(dts_text):
    bad = []
    ph = phandle_map(dts_text)
    for num, want in EXPECT_PHANDLES.items():
        got = ph.get(num)
        if got != want:
            bad.append(f'phandle 0x{num:x} points at {got!r}, expected {want!r}')
    for needle, props in NODE_EDITS.items():
        lines = dts_text.splitlines()
        first, last = node_block(lines, needle)
        body = '\n'.join(lines[first:last])
        for name, value in props.items():
            if f'{name} = {value};' not in body:
                bad.append(f'{needle}: {name} = {value}; missing after edit')
    if bad:
        sys.exit('verification failed:\n  ' + '\n  '.join(bad))
    print('  verify: phandles and properties ok')


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--vendor-boot', help='stock vendor_boot image (v4) to take the DTB from')
    ap.add_argument('--dtb', help='use this DTB instead of extracting one')
    ap.add_argument('--dtb-only', help='write the patched DTB here and stop')
    ap.add_argument('--out', help='write the repacked vendor_boot here')
    ap.add_argument('--mkvendorboot', default=os.path.join(os.path.dirname(os.path.abspath(__file__)),
                                                           '..', '..', 'upstream', 'mkvendorboot.py'))
    a = ap.parse_args()
    if not (a.vendor_boot or a.dtb) or not (a.out or a.dtb_only):
        sys.exit('need --vendor-boot or --dtb, and --out or --dtb-only')

    tmp = '/tmp/vendor-dtb-patch'
    os.makedirs(tmp, exist_ok=True)
    base = os.path.join(tmp, 'base.dtb')
    if a.dtb:
        open(base, 'wb').write(open(a.dtb, 'rb').read())
    else:
        open(base, 'wb').write(extract_dtb(a.vendor_boot))
    print(f'  base DTB {os.path.getsize(base)} bytes')

    base_dts = dts_of(base, os.path.join(tmp, 'base.dts'))
    before = phandle_map(base_dts)
    for num, want in EXPECT_PHANDLES.items():
        if before.get(num) != want:
            sys.exit(f'sanity: base DTB has phandle 0x{num:x} = {before.get(num)!r}, expected {want!r} -- '
                     'this is not a 7552N vendor DTB')

    print('  editing:')
    new_dts_text = apply_edits(base_dts)
    new_dts = os.path.join(tmp, 'new.dts')
    open(new_dts, 'w').write(new_dts_text)
    new_dtb = os.path.join(tmp, 'new.dtb')
    dtb_of(new_dts, new_dtb)
    print(f'  patched DTB {os.path.getsize(new_dtb)} bytes')
    verify(dts_of(new_dtb, os.path.join(tmp, 'new-check.dts')))

    target = a.dtb_only or a.out
    if a.dtb_only:
        open(target, 'wb').write(open(new_dtb, 'rb').read())
        print(f'{target}: patched DTB written')
        return
    run([sys.executable, a.mkvendorboot, '--stock', a.vendor_boot, '--dtb', new_dtb, '--out', target])


if __name__ == '__main__':
    main()
