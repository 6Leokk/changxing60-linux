# 7552N OpenWrt 容器化架构（v2，替代双启动主方案）

> **⚠ 已归档(2026-10-10 放弃)**:本容器方案已于 2026-09-20 放弃(E35 umount 静默失败删光宿主 /dev
> + E36 重启卡 boot,根因未诊),所属整个移植方案 2026-10-10 正式终止。
> 归档索引与理由见 `docs/changxing60/README.md`(外层仓库)。本文为实验品封存,未经二次实测。

## 为什么放弃双启动作为主方案

双启动（slot B changxing60root 区域独立引导 Linux/OpenWrt）继承自上游 changxing60-linux——
其目标设备 F50/MU300 是 5G 随身热点，没有通话/APP 能力可丢，纯 Linux 合理。
但 7552N 是手机：每次进 OpenWrt 就丢失全部手机功能，且自研内核无原厂
功耗/温控/充电管理，屏幕常亮 ZTE logo，作为常驻路由体验差。

实测痛点（trial-9/10）：WiFi 模块（wcn_bsp/pcie-sprd）漏编译无法加载；
changxing60cell.err 9.4MB 错误循环（SIPC tty 卡死，上游 143d55f 才修复）；
misc re-arm 语义复杂；任何修复都要重新分区级部署。

## 新架构：Android 宿主 + OpenWrt 透明代理网关

```
┌────────────────────────────────────────────────┐
│ Android 原厂系统 (slot A, 原厂内核, APatch root)  │
│   通话/短信/APP ✅ 功耗/温控/充电 ✅ 蜂窝/热点 ✅    │
├────────────────────────────────────────────────┤
│ /data/openwrt  — OpenWrt chroot 容器             │
│   procd + ubus + rpcd + LuCI (uhttpd)            │
│   dnsmasq: DNS 分流 + 防污染                      │
│   sing-box: 透明代理核心 (TPROXY 模式)             │
├────────────────────────────────────────────────┤
│ LAN = Android 热点/USB 共享子网 (客户端接入即代理)  │
│ WAN = 蜂窝 rmnet_data (Android netd 已做 NAT)      │
└────────────────────────────────────────────────┘
```

- **零分区改动**：容器只是 /data/openwrt 一个目录，删除即卸载，OTA 不受影响。
- **共享内核**：chroot 与 Android 同内核同 netns，OpenWrt 只做"服务脑"。
- WiFi AP 由 Android 原厂热点承担（稳定省电）；OpenWrt 不加载任何驱动。

## 原厂内核能力矩阵（rescue/dumps/7552n-stock.config 实测）

| 能力 | 状态 | 用途 |
|---|---|---|
| TUN | =y | sing-box TUN 模式（备选） |
| NETFILTER_XT_TARGET_TPROXY | =y | 透明代理主模式 |
| NETFILTER_XT_MATCH_SOCKET/MARK | =y | 代理分流命中判断 |
| NF_CONNTRACK / MARK / REDIRECT | =y | 分流与 NAT |
| IP_NF_NAT / MASQUERADE 全套 | =y | Android netd 自用（共存不冲突） |
| NF_TABLES (nftables) | **未编译** | OpenWrt fw4 不可用 → 不装防火墙包 |
| NET_NS / NAMESPACES / CGROUPS | =y | chroot 隔离 |

## 流量路径（科学上网）

```
热点客户端 → wlan AP (swlan0/ap0) ─- mangle PREROUTING:
    ├── 目标在国内白名单/私网 → 直连（不动）
    └── 其余 → MARK → TPROXY :7896 (sing-box mixed/tproxy 入站)
             → sing-box 按出站规则: 直连 or 代理服务器 → 蜂窝
DNS: 客户端 → dnsmasq (局域网劫持 53) → 国内 DoH/直连上游
    + 远端解析域名列表走 sing-box 远端解析（防污染）
```

iptables 规则放自定义链（CHANGXING60_*），与 Android netd 的链互不干扰；
Android 热点自身 NAT 已把子网流量 MASQUERADE 出蜂窝，sing-box 出站直接复用。

## 组件与安装形态

| 组件 | 位置 | 来源 |
|---|---|---|
| OpenWrt 25.12.5 armsr rootfs | /data/openwrt | 官方 tarball（已下载校验）+ apk add luci 等 |
| sing-box | /data/openwrt/usr/bin | 上游 vendor 同源或最新 release |
| chroot 启动器 | /data/adb/modules/changxing60-openwrt/service.sh | APatch 模块（参考上游 magisk 971f291 结构） |
| 热点自启 | 同上 service.sh + settings put | adb/cmd 控制 Android 热点开机自启 |
| TPROXY 规则 | 容器内 /etc/changxing60-tproxy.sh，procd 自启 | iptables 自定义链 |

## 启动顺序

1. Android boot → APatch → 模块 service.sh（late_start service）
2. 确认热点接口存在（失败则 cmd 启动热点）→ 等蜂窝 pppoe/rmnet 默认路由
3. mount --bind proc/sys/dev/tmpfs → chroot /data/openwrt /sbin/init
   （procd 起 rpcd/ubus/uhttpd/dnsmasq/sing-box）
4. 容器内 procd 触发 changxing60-tproxy 服务 → iptables TPROXY 链挂载
5. 验证：LuCI http://<热点网关IP>，客户端 curl 国内外分流

## 与双启动遗留的共存

- 双启动安装（changxing60root 区域 + boot_b）保持休眠，misc 指向 slot A，无害。
- 新方案验证稳定后按用户要求回收 50GB：删除 changxing60root 区域并将 userdata
  扩回（GPT 恢复 + resize2fs，最后做、单独演练）。
- rescue 工具链（fastoot/fastboot 镜像、sepolicy 补丁脚本）与新架构完全兼容。

## 对比上游（2026-09-19 同步结论）

上游最新方向（mainline 6.18 GPU/modem 突破、wifi-client、magisk 免电脑切换）
全部服务于"纯 Linux 路由器"路线，与容器化路线不冲突。可继续择优吸收：
- 143d55f changxing60-atd（AT 通道常驻防 SIPC 卡死）——容器内同症状可用
- 2481007 boot-tries 五连断电回安卓——双启动休眠区保留此价值
- d79b018 PATH 链接——容器内同样需要
- 4434277 固件软链思路——chroot 内不需要（共享 Android 固件路径），跳过
