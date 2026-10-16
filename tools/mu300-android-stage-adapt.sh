#!/system/bin/sh
# Install the driver-adaptation pass into the flashed OpenWrt rootfs, from Android:
#   1. stage the 25 vendor modules our own 5.4 build carries but never shipped (touch among them);
#   2. install the three /opt/mu300/bin scripts and the updated mu300-hw init script;
#   3. add the bootdiag cron line;
#   4. verify every file landed with the right hash *and* that the loaders still say what they must.
# Nothing here touches the boot image or misc; the touchscreen stays off (no loader references it).
#
# Run it through tools/stage-adapt.sh --stage, which builds adapt-modules.tar from the repo on the spot
# and pushes this file next to it.  The tarball carries opt/manifest.tsv, generated in that same run
# from the very files that went in -- so the hashes checked here are the build tree's, not a snapshot's.
#
# Why step 4 reads the loaders by content: on 2026-10-16 02:42 this install was made from a
# hand-assembled snapshot in work/adapt/ (mtime 02:42) while the repo's overlay had already moved on
# (03:10-03:13).  The two differ in exactly the way that matters --
#   * vendor-modules: snapshot defaults to `crypto usbnet misc`, repo to `crypto usbnet`.  The misc
#     group arms a timer with a NULL callback and takes the kernel down with `CFI failure
#     (target: 0x0)` about three seconds after it loads, which is why it is opt-in now;
#   * bootdiag: snapshot has no usb_recover() and no bisect hook.
# Every hash check passed anyway, because the snapshot was verified against itself.  A hash proves the
# file arrived; it cannot prove the file is the right one.  So the assertions below name the behaviour.
set -e
T=${MU300_TMP:-/data/local/tmp}   # where stage-adapt.sh pushed the tarball and the mount helper
M=${MU300_MNT:-/mnt/mu300}        # the rootfs mount point
VM=5.4.254-gb50db5b6224c
OFF=77858865152
BINDIR=/opt/mu300/bin
say() { echo "[stage] $*"; }
die() { say "FAILED: $*"; unmount; exit 1; }

# The rootfs was last written by a Linux boot that never unmounted: ext4 replays its journal on
# mount, and that write comes from the loop kworker as u:r:kernel:s0, denied on ufs_device unless
# SELinux is permissive.  android-mount-mu300root.sh does that itself and restores it on -u; this
# only has to remember what it found, so that a failed install cannot leave the box permissive.
prev_enforce=$(getenforce 2>/dev/null || echo unknown)

# Cleanup has to survive whatever went wrong before it, including a helper that exits non-zero: `die` is
# the last command of an `||` list, so errexit applies inside it, and one failing command in here used to
# kill the shell before the SELinux restore -- leaving the box on Android with SELinux off (seen
# 2026-10-16 08:06).  Nothing in here may return non-zero.
unmount() {
    if mount | grep -q " $M "; then
        sh $T/android-mount-mu300root.sh -u $M || say "  note: the unmount helper returned $? (the loop is normally already auto-detached)"
    fi
    rm -f $T/.mu300-selinux.prev
    case "$prev_enforce" in
    Enforcing)  [ "$(getenforce 2>/dev/null)" = Enforcing ] || setenforce 1 2>/dev/null || true ;;
    Permissive) setenforce 0 2>/dev/null || true ;;
    esac
    say "selinux=$(getenforce 2>/dev/null) (was $prev_enforce)"
    return 0
}

rm -f $T/.mu300-selinux.prev
if mount | grep -q " $M "; then
    say "rootfs already mounted"
else
    # A stale loop on the same offset would make the helper (rightly) refuse; ours is the only
    # consumer of this geometry, so clean up before mounting rather than after it fails.
    for o in /sys/block/loop*/loop/offset; do
        [ "$(cat "$o" 2>/dev/null)" = "$OFF" ] || continue
        d=/dev/block/${o#/sys/block/}; d=${d%/loop/offset}
        mount | grep -q "^$d " && continue
        losetup -d "$d" 2>/dev/null
    done
    sh $T/android-mount-mu300root.sh $M || die "mount helper failed"
fi
mount | grep -q " $M " || die "not mounted"

D=$M/openwrt
MD=$D/lib/modules/$VM
[ -d "$MD" ] || die "no $MD"
[ -f "$T/adapt-modules.tar" ] || die "no adapt-modules.tar pushed"
# Which shell parses the scripts?  It has to be one that actually RUNS HERE.  The first real run
# (2026-10-16 08:06) picked /bin/busybox out of the mounted rootfs -- which is musl-linked, so executing
# it from Android fails outright (no /lib/ld-musl-aarch64.so.1) -- and because `-x` was the only test,
# the 127 that came back was reported as "does not parse".  A check that never ran must not look like a
# check that failed.  So each candidate is exercised before it is trusted, in this order:
#   * the static busybox build-rootfs.sh ships in /opt/mu300/bin (same busybox-ash dialect as the box's
#     own shell, and it runs anywhere);
#   * the rootfs's own busybox directly, in case a future one is not musl-linked;
#   * Android's own /system/bin/sh (last resort -- a different dialect, but it does run).
# Running the rootfs's /bin/busybox through the rootfs's own loader -- `ld-musl-aarch64.so.1 <busybox>`,
# which would be the box's exact shell -- does not work from Android as written: that loader is a symlink
# to libc.so and resolves its own dependencies from /lib, which Android does not have (it needs
# `--library-path $D/lib`).  Not worth a candidate that only ever prints a skip note: any busybox ash
# catches what this check exists for, the dash-vs-busybox-ash dialect gap.
pick_shell() {
    for c in "$D/opt/mu300/bin/busybox ash" "$D/bin/busybox ash" "$D/usr/bin/busybox ash" \
             "/system/bin/sh"; do
        exe=${c%% *}
        [ -x "$exe" ] || continue
        # stdout of this function IS the answer ($(...) captures it), so anything informational has to
        # go to stderr -- a note printed to stdout becomes part of the shell path
        if $c -c ':' >/dev/null 2>&1; then echo "$c"; return 0; fi
        say "  note: $exe exists but will not execute here -- skipping it" >&2
    done
    return 1
}
SH=$(pick_shell) || die "no shell on this device can parse the scripts (the rootfs busyboxes and /system/bin/sh all failed to run)"
say "parse check with: $SH"
before=$(ls $MD/*.ko | wc -l)
say "modules before: $before"

say "== 1. extract the staging tarball into a scratch dir on the rootfs first"
rm -rf $D/tmp/adapt-stage
mkdir -p $D/tmp/adapt-stage
tar -xf $T/adapt-modules.tar -C $D/tmp/adapt-stage || die "tar failed"
[ -f $D/tmp/adapt-stage/opt/manifest.tsv ] || die "tarball lacks the manifest"

say "== 2. modules"
n=0
while IFS="$(printf '\t')" read -r grp name want; do
    [ -n "$name" ] || continue
    src=$D/tmp/adapt-stage/modules/$name
    [ -f "$src" ] || die "staged file $name missing"
    got=$(sha256sum "$src" | cut -c1-16)
    [ "$got" = "$want" ] || die "$name hash $got != manifest $want (tarball damaged in transit?)"
    cp -f "$src" $MD/$name || die "copy $name failed"
    back=$(sha256sum $MD/$name | cut -c1-16)
    [ "$back" = "$want" ] || die "$name landed as $back"
    echo "MODULE $back $name"
    n=$((n + 1))
done < $D/tmp/adapt-stage/opt/manifest.tsv
say "  copied and verified $n modules"
after=$(ls $MD/*.ko | wc -l)
say "  modules now: $after (was $before)"
[ "$after" -ge "$before" ] || die "module count went backwards"

say "== 3. scripts"
for f in vendor-modules touch-ctl bootdiag; do
    cp -f $D/tmp/adapt-stage/opt/$f $D$BINDIR/$f || die "copy $f failed"
    chmod 755 $D$BINDIR/$f
    cmp -s $D/tmp/adapt-stage/opt/$f $D$BINDIR/$f || die "$f differs after copy"
    # report what the shell actually said: "does not parse" with no diagnostic is how a failed exec
    # (127) passed for a syntax error
    out=$($SH -n $D$BINDIR/$f 2>&1) || die "$f does not parse under '$SH': $out"
    echo "INSTALLED $(sha256sum $D$BINDIR/$f | cut -c1-16) $BINDIR/$f"
done
cp -f $D/tmp/adapt-stage/etc/mu300-hw $D/etc/init.d/mu300-hw || die "copy mu300-hw failed"
chmod 755 $D/etc/init.d/mu300-hw
out=$($SH -n $D/etc/init.d/mu300-hw 2>&1) || die "mu300-hw does not parse under '$SH': $out"
echo "INSTALLED $(sha256sum $D/etc/init.d/mu300-hw | cut -c1-16) /etc/init.d/mu300-hw"
say "  installed + parses: etc/init.d/mu300-hw"

say "== 4. the loaders still say what they must (a hash cannot prove this)"
# misc in the default set = the CFI panic on the next boot.  Read the line the kernel path reads.
grep -q 'MU300_VENDOR_GROUPS:-crypto usbnet}' $D$BINDIR/vendor-modules || \
    die "vendor-modules does not default to 'crypto usbnet' -- misc in the default groups panics the kernel (CFI failure target 0x0)"
grep -q 'bisect_verdict' $D$BINDIR/vendor-modules || die "vendor-modules lost the bisect verdict"
grep -q 'usb_recover' $D$BINDIR/bootdiag || die "bootdiag lost usb_recover (the late-UDC repair)"
grep -q 'vendor-modules bisect' $D$BINDIR/bootdiag || die "bootdiag lost the bisect hook"
grep -q 'vendor-modules' $D/etc/init.d/mu300-hw || die "mu300-hw lost the vendor-modules hook"
grep -q "$BINDIR/vendor-modules" $D/etc/init.d/mu300-hw || die "mu300-hw does not invoke $BINDIR/vendor-modules"
grep -q "$BINDIR/bootdiag" $D/etc/init.d/mu300-hw || die "mu300-hw does not invoke $BINDIR/bootdiag"
# A second copy of one of these scripts elsewhere on the rootfs is how the box keeps running old bytes
# while every check in this file passes (docs/mu300/debug-toolbox.md: the tools live in two places).
# It only matters if something calls it by that path, so look for callers rather than for copies.
for f in vendor-modules touch-ctl bootdiag; do
    extra=$(find $D -xdev -path "$D/tmp" -prune -o -name $f -print 2>/dev/null | grep -v "^$D$BINDIR/$f$" || true)
    for e in $extra; do
        rel=${e#$D}   # how a caller inside the box spells it: /bin/vendor-modules, not the mount path
        say "  WARNING: second copy of $f: $rel"
        # a path boundary, not a substring: /bin/vendor-modules also "appears" in /opt/mu300/bin/...
        callers=$(grep -rlE -- "(^|[^/[:alnum:]_-])${rel}([^/[:alnum:]_-]|\$)" \
                       $D/etc/init.d $D/etc/crontabs $D$BINDIR 2>/dev/null | grep -v "^$e$" || true)
        [ -z "$callers" ] || die "something invokes $rel: $(echo $callers | tr '\n' ' ') -- the box would run that copy, not $BINDIR/$f"
    done
done
say "  default groups / bisect / usb_recover / hooks all in place"

say "== 5. crontab"
if grep -q 'mu300/bin/bootdiag' $D/etc/crontabs/root 2>/dev/null; then
    say "  bootdiag line already there"
else
    echo '* * * * * /opt/mu300/bin/bootdiag >/dev/null 2>&1' >> $D/etc/crontabs/root
    say "  added bootdiag line"
fi
chmod 600 $D/etc/crontabs/root 2>/dev/null || say "  WARNING: crontab mode not set"
grep -n 'bootdiag\|charge-fix\|openclash' $D/etc/crontabs/root | sed 's/^/    /'

say "== 6. touch stays off"
if [ -e $D/etc/mu300/touch ]; then
    say "  WARNING: /etc/mu300/touch says '$(cat $D/etc/mu300/touch)' -- touch WILL load at boot"
else
    say "  no /etc/mu300/touch flag: touch will not load at boot"
fi
# Nothing that the init scripts or cron run may name a touch module; only touch-ctl may.
for f in $D$BINDIR/vendor-modules $D$BINDIR/bootdiag $D$BINDIR/extra-modules $D$BINDIR/display-modules; do
    [ -f "$f" ] || continue
    bad=$(sed 's/#.*//' "$f" | grep -nE 'zte[-_]tpd|spi[-_]sprd|lcd[-_]state[-_]notify' || true)
    [ -z "$bad" ] || die "$f loads a touch module ($bad) -- touch is off by default"
done
grep -q 'zte_tpd' $D$BINDIR/touch-ctl || die "touch-ctl no longer knows the touch modules"
say "  touch reachable only through touch-ctl"

rm -rf $D/tmp/adapt-stage
sync
say "== 7. done"
unmount
echo MU300-ADAPT-OK
