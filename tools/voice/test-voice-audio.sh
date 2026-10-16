#!/bin/bash
# End-to-end test for changxing60-voice-audio, run against a live device over ssh.
#
# This is the test that would have caught the real bug found on 2026-10-16: the first version of the
# daemon reported "restoring the mixer on stop failed" on every stop, because restore rewrote
# SYS_IIS0 with the value it already had and this board rejects that write with EINVAL. The card was
# in fact being restored perfectly, but nothing was checking, so the only evidence was a log line
# saying the opposite. This script checks the claim instead of reading it.
#
# It brings the voice path up with NO call in progress. That is deliberate and it is the interesting
# case: it proves the FE_ST_VOICE pair opens, that the route sequence lands, and that stop puts all
# 319 mixer controls back exactly as they were. It does not touch the modem, the AT channels, any
# module, or the boot slot, and it leaves nothing running.
#
# Usage: tools/voice/test-voice-audio.sh [--host root@192.168.77.1]
set -uo pipefail

HOST=root@192.168.77.1
[ "${1:-}" = "--host" ] && HOST=$2

V=/opt/changxing60/bin/changxing60-voice-audio
TMP=$(mktemp -d)
pass=0
fail=0

ssh_() { ssh -o StrictHostKeyChecking=no -o ConnectTimeout=10 "$HOST" "$@"; }

ok() { pass=$((pass + 1)); printf '  ok    %s\n' "$1"; }
no() { fail=$((fail + 1)); printf '  FAIL  %s\n' "$1"; }
check() { if [ "$2" = "$3" ]; then ok "$1: $3"; else no "$1: expected [$2], got [$3]"; fi; }

# Never leave a live voice path behind, whatever happens below.
cleanup() {
	ssh_ "$V stop" >/dev/null 2>&1
	rm -rf "$TMP"
}
trap cleanup EXIT

echo "changxing60-voice-audio test against $HOST"

echo
echo "[reachability]"
if ! ssh_ true 2>/dev/null; then
	echo "  FAIL  cannot reach $HOST" >&2
	exit 1
fi
ok "ssh to $HOST"

echo
echo "[selftest]"
if ssh_ "$V selftest" >"$TMP/selftest.txt" 2>&1; then
	ok "selftest exits 0"
else
	no "selftest exits non-zero"
	sed 's/^/        /' "$TMP/selftest.txt"
fi
grep -q 'selftest: PASSED' "$TMP/selftest.txt" && ok "selftest reports PASSED" \
	|| no "selftest did not report PASSED"
missing=$(grep -c 'MISSING' "$TMP/selftest.txt")
check "controls missing from the card" "0" "$missing"

echo
echo "[idle before the test]"
ssh_ "$V stop" >/dev/null 2>&1
ssh_ "$V dump" >"$TMP/before.txt"
check "controls captured" "319" "$(wc -l <"$TMP/before.txt")"
check "pcm5p idle" "closed" "$(ssh_ 'head -1 /proc/asound/card0/pcm5p/sub0/status')"
check "pcm5c idle" "closed" "$(ssh_ 'head -1 /proc/asound/card0/pcm5c/sub0/status')"

echo
echo "[start, exactly the way changxing60-voiced calls it]"
ssh_ "$V start >/dev/null 2>&1"
check "start returns 0" "0" "$?"
check "state file says running" "running" "$(ssh_ "$V status" | sed -n 's/^state=//p')"
check "pcm5p running" "state: RUNNING" "$(ssh_ 'head -1 /proc/asound/card0/pcm5p/sub0/status')"
check "pcm5c running" "state: RUNNING" "$(ssh_ 'head -1 /proc/asound/card0/pcm5c/sub0/status')"

# The FE is hostless: the playback pointer has to be pushed forward by FORWARD, because ALSA will
# not start an empty playback stream and there is no AP DMA to fill one.
ssh_ 'cat /proc/asound/card0/pcm5p/sub0/status' >"$TMP/status"
appl=$(sed -n 's/^appl_ptr *: *//p' "$TMP/status")
if [ "${appl:-0}" -gt 0 ]; then ok "playback pointer advanced to $appl (FORWARD worked)"; else
	no "playback pointer is ${appl:-missing}, FORWARD did not run"; fi
# The exact hw_params matter, so check them rather than trusting the code that asked for them.
ssh_ 'cat /proc/asound/card0/pcm5p/sub0/hw_params' >"$TMP/hw"
check "hw_params" "S16_LE/1/8000/640/1280" \
	"$(awk -F': ' '/^(format|channels|rate|period_size|buffer_size):/ {v=$2; sub(/ .*/,"",v);
		printf "%s%s", (n++ ? "/" : ""), v}' "$TMP/hw")"

# A Select word is (mode << 24) | (mode << 16) | 5 and the card declares max 0x0fffffff, so amixer
# would clamp it to 268435455 and the kernel would apply the clamped word as a different dsp_case.
# Reading it back through the raw ioctl is the only way to know the driver took the whole word.
# `dump` reads every control the same way, so this is the register, not the intended value.
# The numbers below are decimal because that is what the ioctl returns: 0x00000005 and 0x07070005.
select_word() { ssh_ "$V dump" | awk -F'\t' '$1=="DSP VBC Profile Select"{print $2}'; }
check "profile Select took the full 32-bit word" "5" "$(select_word)"

echo
echo "[runtime commands]"
check "speaker on" "speaker" "$(ssh_ "$V speaker on" | sed -n 's/^output=//p')"
check "speaker on reaches the Select register" "117899269" "$(select_word)"
check "speaker off" "receiver" "$(ssh_ "$V speaker off" | sed -n 's/^output=//p')"
check "speaker off reaches the Select register" "5" "$(select_word)"

# The reason the mixer is driven by raw ioctl and not amixer, tested rather than asserted. A Select
# word is (mode << 24) | ... and the control declares max 0x0fffffff, so a Bluetooth mode (28 and up)
# overflows it. Measured here: the raw ioctl carries 0x1c1c0005 intact, and amixer silently turns the
# same input into 0x0fffffff -- which the kernel applies as mode 15, a different mode, without an
# error. If this ever stops clamping, the raw path is still correct, but the comment in the daemon
# saying so would need revisiting.
select_via_amixer() { ssh_ "amixer -c 0 cset name='DSP VBC Profile Select' 471072773 >/dev/null 2>&1
	amixer -c 0 cget name='DSP VBC Profile Select' 2>/dev/null | sed -n 's/^  : values=//p'"; }
check "raw ioctl carries a Bluetooth Select word intact" "0x1c1c0005" \
	"$(ssh_ "$V select 0x1c1c0005" | awk -F'\t' '$1=="DSP VBC Profile Select"{print $2}')"
check "amixer silently clamps the same word" "268435455" "$(select_via_amixer)"
ssh_ "$V select 0" >/dev/null
check "mute on" "1" "$(ssh_ "$V mute on" | sed -n 's/^muted=//p')"
check "mute off" "0" "$(ssh_ "$V mute off" | sed -n 's/^muted=//p')"
check "volume 12" "12" "$(ssh_ "$V volume 12" | sed -n 's/^volume=//p')"
check "band WB" "wideband" "$(ssh_ "$V band WB" | sed -n 's/^band=//p')"
check "band NB" "narrowband" "$(ssh_ "$V band NB" | sed -n 's/^band=//p')"
check "the PCM survived every command" "state: RUNNING" \
	"$(ssh_ 'head -1 /proc/asound/card0/pcm5p/sub0/status')"
check "a second start is a no-op" "running" "$(ssh_ "$V start" | sed -n 's/^state=//p')"

echo
echo "[stop and restore]"
check "stop returns 0" "0" "$(ssh_ "$V stop >/dev/null 2>&1"; echo $?)"
check "status is idle" "idle (no call audio running)" "$(ssh_ "$V status")"
check "pcm5p closed" "closed" "$(ssh_ 'head -1 /proc/asound/card0/pcm5p/sub0/status')"
check "pcm5c closed" "closed" "$(ssh_ 'head -1 /proc/asound/card0/pcm5c/sub0/status')"
check "no process left" "0" "$(ssh_ 'ps | grep -c "[c]hangxing60-voice-audio"')"
check "no runtime files left" "" "$(ssh_ 'ls -A /run/changxing60-voice-audio/ 2>/dev/null | tr "\n" " "')"

# The claim that actually matters, and the one the first version got wrong.
ssh_ "$V dump" >"$TMP/after.txt"
if diff -q "$TMP/before.txt" "$TMP/after.txt" >/dev/null; then
	ok "all 319 controls identical before and after the cycle"
else
	no "stop did not restore the mixer:"
	diff "$TMP/before.txt" "$TMP/after.txt" | sed 's/^/        /'
fi

echo
echo "[log]"
if ssh_ 'grep -qE "restore failed|cannot write|Traceback|listener did not come back" /root/voice-audio.log' 2>/dev/null; then
	no "the log has errors:"
	ssh_ 'grep -E "restore failed|cannot write|Traceback|listener did not come back" /root/voice-audio.log' | sed 's/^/        /'
else
	ok "no errors in /root/voice-audio.log"
fi
check "the notification listener started" "yes" \
	"$(ssh_ 'grep -q "notification listener started" /root/voice-audio.log && echo yes || echo no')"
check "the listener came back on stop" "no" \
	"$(ssh_ 'grep -q "did not come back" /root/voice-audio.log && echo yes || echo no')"

echo
echo "$pass passed, $fail failed"
[ "$fail" = 0 ] || exit 1
