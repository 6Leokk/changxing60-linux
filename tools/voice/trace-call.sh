#!/bin/sh
# Device-side: trace one outbound voice call end-to-end and dump the DAPM widget
# power states before / during / after, plus the kernel err log and the
# voice-audio monitor's own log.
#
# Why DAPM debugfs instead of amixer: the audio monitor holds card 0, and this
# machine must never have two concurrent ALSA clients on it (see
# docs/changxing60/audio-oops). Reading /sys/kernel/debug/asoc/... touches no
# ALSA userspace API at all, and it reports each widget's real on/off state.
#
# WHY IT SNAPS EVERY COMPONENT, NOT JUST THE CODEC (learned the hard way): the
# widgets are spread over several DAPM contexts and snapshotting only
# sc27xx-audio-codec/dapm silently misses the ones that matter most --
#   sprdphone-sc2730/dapm              card level: DAI links, "Ext Ear"/"Ext Spk"
#                                      pins (board_ext_pin_control targets)
#   sprd-routing-pcm/dapm              S_* routing switches (S_VOICE_P_CODEC ...)
#   sc27xx-audio-codec/dapm            the analog codec widgets
#   56510000.vbc/dapm, sprd-fe-dai, sprd-pcm-audio, sprd-compr-audio
#   FE_* dirs at card level            per-front-end widgets
# An earlier trace did exactly that and produced a wrong conclusion.
#
# Usage: trace-call.sh <number> [seconds-to-hold]
#   e.g. trace-call.sh 10086 12
set -u

NUM=${1:-10086}
HOLD=${2:-12}
ROOT=/sys/kernel/debug/asoc/sprdphone-sc2730
V=/opt/changxing60/bin/changxing60-voice
A=/opt/changxing60/bin/changxing60-voice-audio
OUT=/tmp/voice-trace
rm -rf $OUT; mkdir -p $OUT

# Every dapm dir under the card, plus the card's own one. Each becomes
# $OUT/<phase>/<component>__<Widget>.
snap() { # snap <name>
	mkdir -p "$OUT/$1"
	for d in "$ROOT/dapm" "$ROOT"/*/dapm "$ROOT"/FE_*; do
		[ -d "$d" ] || continue
		comp=$(echo "$d" | sed "s|$ROOT/||; s|/dapm||; s|^dapm$|CARD|")
		for f in "$d"/*; do
			[ -f "$f" ] || continue
			cat "$f" > "$OUT/$1/${comp}__$(basename "$f")" 2>/dev/null
		done
	done
}

# Only lines that actually say something about power; keeps the diff readable.
summary() { # summary <name>
	echo "  widgets ON:   $(grep -lE ': On' "$OUT/$1"/* 2>/dev/null | wc -l)"
	echo "  widgets Off:  $(grep -lE ': Off' "$OUT/$1"/* 2>/dev/null | wc -l)"
	for key in CARD:Ext_EAR CARD:Ext_SPK CARD:Ext_HP \
		sprd-routing-pcm:S_VOICE_P_CODEC sprd-routing-pcm:S_VOICE_C_CODEC \
		FE_VOICE:FE_IF_VOICE_P FE_VOICE:BE_IF_VOICE_CODEC_P; do
		:
	done
	echo "  -- the ones that matter --"
	for pat in 'Ext Ear' 'Ext Spk' 'Ext HP' 'S_VOICE_P_CODEC' 'S_VOICE_C_CODEC' \
		   'S_NORMAL_AP01_P_CODEC' 'FE_IF_VOICE_P' 'BE_IF_VOICE_CODEC_P' \
		   'DAC$' 'EAR Pin' 'EAR Switch' 'SPK Pin' 'Earpiece'; do
		printf "  %-24s " "$pat"
		grep -h "" "$OUT/$1"/* 2>/dev/null >/dev/null
		hit=$(grep -lE "($(basename "$pat"))" "$OUT/$1"/* 2>/dev/null | head -1)
		if [ -n "$hit" ]; then
			printf "%s = %s\n" "$(basename "$hit" | sed 's/.*__//')" "$(cat "$hit" 2>/dev/null | tr -s ' ' | tr '\n' ' ')"
		else
			printf "(not found in any dapm dir)\n"
		fi
	done
}

echo "== state before =="
$V state 2>&1 | head -8
$A status 2>&1 | head -4
snap before
summary before

echo "== dialing $NUM =="
$V dial "$NUM" 2>&1 | head -5
sleep "$HOLD"

echo "== during call =="
$V state 2>&1 | head -8
$A status 2>&1 | head -6
snap during
summary during
echo "  -- what CHANGED between before and during --"
for f in "$OUT/during"/*; do
	b="$OUT/before/$(basename "$f")"
	[ -f "$b" ] || continue
	if ! cmp -s "$f" "$b"; then
		printf "  %-40s %s -> %s\n" "$(basename "$f" | sed 's/.*__//')" \
			"$(tr -s ' ' <"$b" | cut -c1-28)" "$(tr -s ' ' <"$f" | cut -c1-28)"
	fi
done

echo "== monitor log tail =="
tail -40 /root/voice-audio.log 2>/dev/null

echo "== hanging up =="
$V hangup 2>&1 | head -3
sleep 3
$V state 2>&1 | head -8
snap after

echo "== logread (kern.err and up) =="
logread 2>/dev/null | grep -iE 'asoc|codec|voice|vbc|agdsp|sipc|snd' | tail -40

echo "== DONE: /tmp/voice-trace/{before,during,after} =="
