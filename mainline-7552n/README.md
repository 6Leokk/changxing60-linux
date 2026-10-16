# mainline-7552n —— 把上游 6.18 移植层适配到 7552N

这里是**我们唯一改动上游的地方**。上游 `upstream/` 整目录原样保留(F50/MU300/U30 Air,eMMC,无屏),
本目录只放 7552N(P720S20,UMS9620,**UFS**,480×854 内屏)相对它的两块板型差量。
上游一动,`upstream/` 整目录替换即可,本目录不受影响。

## 差量一:UFS —— 内核配置

上游 `mu300-mainline.config` 是 eMMC 板:`CONFIG_MMC_SDHCI_SPRD=y`,而 UFS 三项**全是 off**
(`# CONFIG_SCSI_UFSHCD is not set`)—— 6.18 树里明明有 `drivers/ufs/host/ufs-sprd.c`,只是没编。
第一次试启(2026-10-14)就是栽在这:没有 `/dev/sda` → 没有分区表 → 没有 ext4 rootfs → 没有 USB 网口。

`config-7552n.config` 补上:

```
CONFIG_SCSI_UFSHCD=y / CONFIG_SCSI_UFSHCD_PLATFORM=y / CONFIG_SCSI_UFS_SPRD=y / CONFIG_SCSI_UFS_CRYPTO=y
```

**不 fork 上游 build.sh**:`build.sh:35` 把 `/work/mu300-mainline.config` 交给 `merge_config`,
**紧接着 40-45 行逐个 option 断言"配置真的被接受"**(没被接受就硬失败)。所以合并方式是
**把我们的片段追加到上游配置后面,再把结果 bind-mount 盖到 `/work/mu300-mainline.config` 上** ——
一次 merge 的效果与两次相同(later wins),而且我们的 option 也一并被断言。见 `build.sh`。

ufs-sprd 依赖的 clk/reset provider(`SPRD_UMS9620_CLK`)、IPA 电源域、ssphy、regulator、syscon
在上游配置里**已经是 =y**,所以 UFS 是唯一的缺口。

## 差量二:UFS —— 厂商 DTB(这才是真正的坑)

**LK 的 DT 不是从 boot 镜像来的,是从所选槽的 `vendor_boot` DT 表来的**(`dtb_a`/`dtb_b` 两个分区全是 0)。
所以必须改 `vendor_boot_b` 里那份**厂商 DTB**。

上游试过**替换**一份自己写的最小 DTB —— **挂在 `setup_machine_fdt`**:**LK 自己要解析这份 DTB**,
删节点是致命的。**加属性不是。** 所以 `tools/patch-vendor-dtb.py` 走**纯增量**:

| 属性 | 厂商 DTB 原本 | 补成 | 为什么 |
|---|---|---|---|
| `compatible` | `"sprd,ufshc"` | `"sprd,ums9620-ufs", "sprd,ufshc"` | 主线 `ufs-sprd.c` 的 match 表只认前者;**厂商值留在表里,5.4 内核仍绑得上,同一份 vendor_boot 两边通用** |
| `reset-names` | `"ufs_soft_rst","ufsdev_soft_rst"` | 追加 `"controller","device"` | 主线 `devm_reset_control_get(dev,"controller"/"device")` 按**名字**查,厂商名字保留在**前面**,5.4 按老名字查仍命中 |
| `resets` | 2 项 | 同一对**复制**成 4 项 | 与上面名字一一对应(顺序即索引;每项自带 provider phandle) |
| `sprd,ufs-anlg-syscon` | 无 | `<0x12>` | `syscon@64380000` = 厂商 dtsi 的 `&anlg_phy_g12_regs` |
| `sprd,aon-apb-syscon` | 无 | `<0x02>` | `syscon@64900000` = 厂商 dtsi 的 `&aon_apb_regs` |

**为什么这两个 phandle 是对的(不是猜的)**:厂商 DTB 里 UFS 节点本来就带三个**裸三元组**
(如 `ufsdev_refclk_en = <0x02 0xce8 0x02>`),厂商 5.4 驱动用
`syscon_regmap_lookup_by_phandle_args(np, name, 2, args)` 读 —— **第一个 cell 就是真 phandle,后两个是
(offset, mask)**。与主线 `ufs-sprd.c` 的 `regmap_update_bits()` 逐条对上:

- `0x0c` bit `0x1/0x2/0x4` → `SPRD_UFS_ANLG` → `syscon@64380000`(phandle `0x12`)
- `0xce8` bit `0x2`(`REG_AON_APB_UFSDEV_REG`)与 `0xcfc` bit `0x1`(`REG_AON_APB_USB31PLL_CTRL_MISC`)
  → `SPRD_UFS_AON_APB` → `syscon@64900000`(phandle `0x02`)—— 与厂商 `sprd,qogirn6pro-regs.h` 的偏移完全一致

即**驱动一行都不用改**,只是把驱动要的四个属性补进去。工具在改前改后都校验 phandle 映射
(防止 dtc 往返把 syscon 悄悄指到别的节点),并断言每个属性确实写进了节点体。

**已知风险**:厂商节点里还有 `aon_apb_ufs_clk_en = <0x02 0xc14 0xc0>`(UFSHC 的 PCLK|HCLK 使能),
**主线驱动从不碰它**。若 LK 启动时已放开这两路时钟则无事;若没有,UFS 会不响应 —— 下一轮试启看
`diag` 的 dmesg 段(见下)即可判定。

## 差量三:USB —— 同一份 DTB 里再关掉一个节点

第一次试启除了没有 UFS,还 **`udc=none`**(没有 UDC → 没有 usb0 → 没有管理口)。查下来是**同一个 DTB 的
另一个问题**,而且同样是"加/改属性"就能解决:

`dwc3@25100000` 带 `usb-phy = <0x60 0x24>`(index 0 = `dummyphy`,index 1 = `ssphy@25310000`)。
主线 `dwc3_core_get_phy()` 用**老 usb_phy 框架** `devm_usb_get_phy_by_phandle()` 取这两个,
而 `__of_usb_find_phy()`(`drivers/usb/phy/phy.c:66`)的返回是二值的:

- 节点**不可用**(status ≠ okay)→ `-ENODEV` —— dwc3 **刻意当成"没配 phy",非致命**(`usb2_phy = NULL`);
- 否则找不到已注册的 usb_phy → `-EPROBE_DEFER` —— **永远 defer → dwc3 永不 probe → 没有 UDC**。

- index 1 `ssphy` **没问题**:上游移植的 `port/drivers/usb/phy/phy-sprd-ums9620-ssphy.c`
  注册的就是**真 usb_phy**(`usb_add_phy_dev()`,~811 行)。
  旁证:overlay fragment@9 往 ssphy 上写的是 `sprd,hsphy-device/host-eye-pattern` ——
  **这个 PHY 连 USB2 HS 的眼图一起配**,正是这块 SoC 的 combo PHY。
- index 0 `dummyphy`(`compatible = "sprd,usb-dummy-phy"`)**是凶手**:6.18 树里**全树 grep 不到任何
  driver**,节点却是 `status = "okay"` → 永远 `-EPROBE_DEFER`。

**改法:把 `dummyphy` 的 `status` 改成 `"disabled"`**(节点留着,只改状态 —— 仍是增量)。
这让那次查找返回 `-ENODEV`,得到**正是这份 DT 在主线的正确含义**:`usb2_phy = NULL`、`usb3_phy = ssphy`。

USB 胶水节点本身**不用我们管**:上游 `port/install.py` 已经把 `sprd,qogirn6pro-dwc3` 加进
`dwc3-of-simple.c`(通用地处理 clocks/resets/power-domain)、把 `snps,sprd-dwc3` 加进 `dwc3/core.c`。

## 用法

```sh
mainline-7552n/build.sh kernel   # 内核 + 模块(合并我们的配置片段)+ LK 包装 Image.lk
mainline-7552n/build.sh dtb      # 打补丁的 vendor_boot_b(work/vendor_boot_b-7552n.img)
mainline-7552n/build.sh image    # 试启 boot 镜像(work/boot-618-slotb.img)
mainline-7552n/tools/flash-7552n.sh            # 只刷 slot b:vendor_boot_b + boot_b + misc tries
mainline-7552n/tools/flash-7552n.sh --restore-vendor-boot   # 把原厂 vendor_boot_b 刷回去
```

`upstream/` 通过 volume `mu300-mainline`(`:/src`)与 bind mount(`:/work`)参与构建,细节见
`docs/mu300/mainline-6.18.md`(B1 交叉编译决策)。

## 盲启取证

试启镜像**没有屏幕**,而 rootfs/USB 挂不上时 `boot/init` 的 `persist()`(写 boot_b 里那段日志区)
也写不进去 —— **唯一活下来的是 kmsg/pmsg,落在 pstore/ramoops**,回落 Android 后从
`/sys/fs/pstore/{console,pmsg}-ramoops-0` 读。
所以 `boot/init` 新增了 `diag()`:在每个关键节点把**块设备列表 / deferred 探针 / platform 驱动与绑定 /
过滤后的 dmesg**(只留 ufs|scsi|sdhci|dwc3|usb|phy|regulator|clk|deferred|probe|error|fail)压成有界行数
写 kmsg+pmsg。pmsg 环只有几百 KiB,全量 dmesg 会把它冲掉,所以**必须过滤 + 限长**。

## 回滚

`boot_a` / `vendor_boot_a` 全程不动;只刷 slot b,LK 的 tries 兜底 → 回落 slot a 的 Android。
原厂 `vendor_boot_b` 在首次刷写前自动备份到 `work/dumps/vendor_boot_b.stock.img`。
