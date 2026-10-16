#!/bin/bash
# Behavioural test for tools/deploy-pending.sh, run with no device attached.
#
# WHY. deploy-pending.sh is the one script that has to work when the device comes back, and it fails in
# ways that parse perfectly. Two of them were hit on 2026-10-16:
#
#   1. A hand-written push list that had fallen behind. Three of the four LuCI panels -- the SMS view,
#      the voice view and the voice/SMS backends -- were not in it, so a fix made on the host never
#      reached the device. Nothing about the run looked wrong.
#   2. A single apostrophe in a comment ("the USB link page's helper script") inside one of the
#      single-quoted payloads handed to ssh. That closed the payload early, and the rest of the payload
#      -- modprobe, ls /dev/mali0, the brightness test -- ran *on the host*. bash -n passed the file,
#      the run still ended with "Done." and still exited 0. This is the same class as the trap in
#      build-rootfs.sh, which has a guard; this file does not and cannot, because a quote inside a
#      payload is indistinguishable from the closing quote by reading. So it is caught by running.
#
# The stubs below are what makes that possible without a device: fake ssh and scp on PATH record the
# commands they were asked to run. A truncated payload then shows up either as a local-execution
# signature in the output or as a payload that never reached the log.
#
#   tools/test-deploy-pending.sh        (exit 0 = the push set and the payloads are intact)
set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
top="$(cd "$here/.." && pwd)"
script="$top/tools/deploy-pending.sh"

pass=0
fail=0
ok()   { pass=$((pass + 1)); echo "  ok   $1"; }
bad()  { fail=$((fail + 1)); echo "  FAIL $1"; }
want() { [ "$2" = "$3" ] && ok "$1" || bad "$1 (want $3, got $2)"; }

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
log="$tmp/calls.log"

# The stubs. ssh answers `uname -r` -- that is how the script picks its module set -- and records
# everything else. scp only records. Neither of them ever contacts anything.
cat > "$tmp/ssh" <<STUB
#!/bin/bash
printf 'SSH %s\n' "\$*" >> "$log"
args=("\$@"); last="\${args[-1]}"
[ "\$last" = "uname -r" ] && echo "6.18.0"
exit 0
STUB
cat > "$tmp/scp" <<STUB
#!/bin/bash
printf 'SCP %s\n' "\$*" >> "$log"
exit 0
STUB
chmod +x "$tmp/ssh" "$tmp/scp"

# A password file that does not exist keeps AUTH_CMD empty, so the stub ssh is what gets run.
out=$(CHANGXING60_PASSWORD_FILE="$tmp/absent" PATH="$tmp:$PATH" bash "$script" --apply 2>&1)

echo "== the payloads survived (no truncation) =="
# A payload that closed early runs its remainder locally, and these are the signatures of that: the
# remote commands of a rootfs we are not on, executed here. Checked by name rather than by "exit code",
# because the truncated run exited 0 and still printed Done -- the exit code is exactly the thing that
# does not tell you.
if grep -q 'syntax error' <<<"$out"; then bad "the script hit a syntax error mid-file"; else ok "no syntax error"; fi
for sig in 'modprobe: FATAL' 'ubus: command not found' '/opt/changxing60/bin/power-policy: No such file' '/etc/init.d/rpcd: not found'; do
    if grep -qF "$sig" <<<"$out"; then bad "a payload ran locally: $sig"; else ok "not run locally: $sig"; fi
done

echo
echo "== every LuCI panel part is in the push set =="
# Derived from the tree, not from a list written here: the point is that the push set tracks what is on
# disk. A panel gains a part, or a new panel appears, and this notices without being edited.
for p in "$top"/openwrt/overlay/usr/share/rpcd/ucode/changxing60*.uc \
         "$top"/openwrt/overlay/usr/share/rpcd/acl.d/luci-app-changxing60*.json \
         "$top"/openwrt/overlay/usr/share/luci/menu.d/luci-app-changxing60*.json \
         "$top"/openwrt/overlay/www/luci-static/resources/view/changxing60*/*.js; do
    [ -e "$p" ] || continue
    rel=${p#"$top"/openwrt/overlay/}
    grep -qF ":/$rel" "$log" && ok "pushed /$rel" || bad "NOT pushed /$rel"
done

echo
echo "== the panels that were missing from the old hand-written list =="
# Named outright so the regression that started this cannot come back quietly even if the derivation
# above is ever rewritten.
for rel in www/luci-static/resources/view/changxing60sms/sms.js \
           www/luci-static/resources/view/changxing60voice/voice.js \
           usr/share/rpcd/ucode/changxing60voice.uc \
           usr/share/rpcd/ucode/changxing60sms.uc; do
    grep -qF ":/$rel" "$log" && ok "/$rel" || bad "/$rel still missing"
done

echo
echo "== nothing is pushed to a path the panels do not live at =="
# The LuCI parts go to the path they came from. A push that lands somewhere nothing reads is the same
# silent no-op as not pushing at all.
for p in "$top"/openwrt/overlay/usr/share/rpcd/ucode/changxing60*.uc \
         "$top"/openwrt/overlay/www/luci-static/resources/view/changxing60*/*.js \
         "$top"/openwrt/overlay/usr/share/rpcd/acl.d/luci-app-changxing60*.json \
         "$top"/openwrt/overlay/usr/share/luci/menu.d/luci-app-changxing60*.json; do
    [ -e "$p" ] || continue
    tgt="/${p#"$top"/openwrt/overlay/}"
    grep -qF ":$tgt" "$log" && ok "target $tgt" || bad "wrong or missing target for $tgt"
done

echo
echo "== every init script is in the push set =="
# Derived from the tree, like the panel check. Two of these used to be named by hand and nine were absent
# altogether, so a fix to changxing60-post was pushed, reported success, and never reached the device.
for p in "$top"/openwrt/overlay/etc/init.d/changxing60-*; do
    [ -e "$p" ] || continue
    b=$(basename "$p")
    grep -qF ":/tmp/$b.init" "$log" && ok "pushed $b" || bad "NOT pushed $b"
done
# And the install step must take them from what was pushed, not from a second list.
if grep -qF 'for f in /tmp/changxing60-*.init' "$top/tools/deploy-pending.sh"; then
    ok "install step loops over the tree-derived set"
else
    bad "install step still names init scripts by hand"
fi

echo
echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ] || exit 1
