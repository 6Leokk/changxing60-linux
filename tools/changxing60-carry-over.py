#!/usr/bin/env python3
"""Carry the device-only extra install (OpenClash and friends) from an old changxing60 rootfs into a
freshly built one, so a full-overwrite flash does not drop it.

Why this exists: luci-app-openclash and its ~37 dependencies were installed *on the device* (apk
over the network). They are in no git tree and no build input, so `openwrt/build-rootfs.sh` warns
that a rebuilt rootfs has no OpenClash and reflashing needs a working WAN (docs/changxing60/backlog.md
section 4). This script closes that gap for the "flash the new rootfs over the old one" path.

What it copies, in three passes:

  1. every file of a package that is installed in OLD but not in NEW (from the apk database) --
     this is what brings dnsmasq-full's dnsmasq binary over the plain one, plus ruby, curl, lua,
     the Lua LuCI runtime luci-app-openclash needs, and the OpenClash LuCI assets;
  2. every path that exists on disk in OLD but not in NEW, minus volatile trees -- this catches
     files no package owns (the speed-test blobs in /www, the mihomo core, the subscription);
  3. an explicit always-carry list of configuration that NEW generates at first boot and would
     otherwise overwrite with defaults (the Wi-Fi SSID/PSK, the hotspot config, root's state).

Run it as root (a container is the easy way); it preserves modes, ownership and symlinks.

  changxing60-carry-over.py OLD_ROOTFS_DIR NEW_ROOTFS_DIR
"""
import os
import re
import shutil
import sys

# Trees that must never come back: the old kmods are built for OpenWrt's own 6.12 kernel and are
# dead weight on a 5.4 rootfs, and the rest is per-boot state or host plumbing.
SKIP_PREFIX = (
    "lib/modules/", "proc/", "sys/", "dev/", "tmp/", "var/", "run/", "mnt/", "overlay/",
    "lost+found/",
)
SKIP_SUFFIX = (".log",)

# Pass 3: NEW builds these at first boot (openwrt-wifi-config, net-split, 90-changxing60) and would
# replace the user's working settings with generated defaults if we said nothing.
ALWAYS = (
    "etc/changxing60",           # hotspot.conf, default-boot, wifi-configured marker, backlight state
    "etc/openclash",       # core, 91code.yaml, overwrite rules, history, geo data
    "etc/config/openclash",
    "etc/config/wireless",  # SSID changxing60, the PSK, channel 36, bss_load_update_period 0
    "etc/config/network",
    # Whatever carries `network` has to carry `firewall` with it. br-wifi's 192.168.8.1/24 lives in
    # etc/config/network and survives a reflash; the one line that puts that network into a firewall
    # zone is written by net-split and lives only in etc/config/firewall. The 2026-10-15 rebuild
    # carried the first and reset the second, so the hotspot came up with an address, a DHCP scope,
    # a beaconing AP -- and a firewall that rejected every client packet before dnsmasq saw it.
    "etc/config/firewall",
    "etc/config/system",
    "etc/hostname",
)


def parse_db(path):
    """apk `installed` db -> {package: [relative file paths]}. F: sets the dir, R: a file in it."""
    pkgs, cur, curdir = {}, None, ""
    if not os.path.exists(path):
        return pkgs
    for line in open(path, encoding="utf-8", errors="replace"):
        line = line.rstrip("\n")
        if not line:
            continue
        tag, _, val = line.partition(":")
        if tag == "P":
            cur = val
            pkgs[cur] = []
        elif tag == "F":
            curdir = val
        elif tag == "R" and cur is not None:
            pkgs[cur].append(((curdir + "/" + val) if curdir else val).lstrip("/"))
    return pkgs


def rel_files(root):
    out = set()
    for dirpath, dirnames, filenames in os.walk(root, followlinks=False):
        rel = os.path.relpath(dirpath, root)
        rel = "" if rel == "." else rel
        for n in dirnames + filenames:
            p = (rel + "/" + n) if rel else n
            out.add(p)
    return out


def copy_one(old, new, rel, stats):
    src, dst = os.path.join(old, rel), os.path.join(new, rel)
    if not os.path.lexists(src):
        stats["missing"] += 1
        return
    os.makedirs(os.path.dirname(dst), exist_ok=True)
    if os.path.islink(src):
        if os.path.lexists(dst):
            os.remove(dst)
        os.symlink(os.readlink(src), dst)
        stats["symlink"] += 1
        return
    if os.path.isdir(src):
        os.makedirs(dst, exist_ok=True)
        shutil.copystat(src, dst, follow_symlinks=False)
        os.chown(dst, os.stat(src).st_uid, os.stat(src).st_gid)
        return
    shutil.copy2(src, dst, follow_symlinks=False)
    os.chown(dst, os.stat(src).st_uid, os.stat(src).st_gid)
    stats["file"] += 1


def main():
    if len(sys.argv) != 3:
        sys.exit(__doc__.strip().splitlines()[-1])
    old, new = os.path.abspath(sys.argv[1]), os.path.abspath(sys.argv[2])
    for d in (old, new):
        if not os.path.isdir(d):
            sys.exit("not a directory: " + d)

    oldpk, newpk = parse_db(old + "/lib/apk/db/installed"), parse_db(new + "/lib/apk/db/installed")
    only = sorted(set(oldpk) - set(newpk))
    print(f"packages: old {len(oldpk)}, new {len(newpk)}, installed only in old: {len(only)}")
    print("  " + " ".join(only))

    stats = {"file": 0, "symlink": 0, "missing": 0}
    # pass 1: files of old-only packages (overwrites NEW where both ship the same path)
    p1 = set()
    for p in only:
        for rel in oldpk[p]:
            if rel.startswith(SKIP_PREFIX):
                continue
            p1.add(rel)
    for rel in sorted(p1):
        copy_one(old, new, rel, stats)
    print(f"pass 1: {len(p1)} package files -> copied {stats['file']} files, "
          f"{stats['symlink']} symlinks ({stats['missing']} absent on disk)")

    # pass 2: on-disk paths that exist only in OLD
    before = stats["file"]
    p2 = sorted(rel_files(old) - rel_files(new))
    p2 = [r for r in p2 if not r.startswith(SKIP_PREFIX) and not r.endswith(SKIP_SUFFIX)]
    for rel in p2:
        copy_one(old, new, rel, stats)
    print(f"pass 2: {len(p2)} on-disk paths -> {stats['file'] - before} new files")

    # pass 3: the explicit always-carry list (whole trees, overwriting NEW)
    for rel in ALWAYS:
        src = os.path.join(old, rel)
        if not os.path.exists(src):
            print(f"pass 3: {rel} absent in OLD, skipped")
            continue
        if os.path.isdir(src) and not os.path.islink(src):
            for dirpath, _, filenames in os.walk(src):
                r = os.path.relpath(dirpath, old)
                copy_one(old, new, r, stats)
                for f in filenames:
                    copy_one(old, new, r + "/" + f, stats)
        else:
            copy_one(old, new, rel, stats)
        print(f"pass 3: {rel} carried")
    # rc.d is generated by `enable`, not shipped by apk: recreate the OpenClash symlinks.
    for d in sorted(os.listdir(old + "/etc/rc.d")):
        if d.endswith("openclash"):
            link, dst = os.readlink(old + "/etc/rc.d/" + d), new + "/etc/rc.d/" + d
            os.makedirs(os.path.dirname(dst), exist_ok=True)
            if os.path.lexists(dst):
                os.remove(dst)
            os.symlink(link, dst)
            print(f"pass 3: rc.d/{d} -> {link}")

    print(f"\ntotal: {stats['file']} files, {stats['symlink']} symlinks copied, "
          f"{stats['missing']} package entries absent on disk")
    print("NOTE: the apk database is NOT merged -- `apk list` will not show the carried packages.")
    print("      Nothing at runtime reads it for OpenClash (its init script and Lua controller do "
          "not), and the files are on disk where they matter.")


if __name__ == "__main__":
    main()
