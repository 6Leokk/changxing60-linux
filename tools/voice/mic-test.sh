#!/bin/sh
# Device-side: bring up the MICROPHONE (uplink) path one switch at a time and
# MEASURE whether real samples reach the AP -- no ears, no phone call needed.
#
# Why this exists: during a real call the whole downlink chain powers up (DAC ->
# EAR_HPL -> EAR Pin all On) but the capture chain stays OFF: ADC, ADC_1 Gain,
# ADC_1 Mixer, ADC_1 Switch, MIC Pin, Digital ADCL Switch -- all Off. Root cause
# found in source, and it is NOT the same control our monitor writes:
#
#   mic -> ADC_1 Mixer -> ADC_1 Gain -> ADC_1 Switch -> ADie Digital ADCL Switch
#        -> Digital ADC In Sel -> ADC            (ump9620 codec/sprd-codec.c)
#   route: {"ADC_1 Mixer", "MIC1PGA_1 Switch", "MIC Pin"}   sprd-codec.c:3822
#   kctl : SPRD_CODEC_AD_MIXER("MIC1PGA_1 Switch", ANA_CDC1, SMIC1PGA_1_S)  :460
#
# Our monitor writes `Mic Function on`, but that is a MACHINE-layer board pin:
#   BOARD_CODEC_FUNC("Mic Function", BOARD_FUNC_MIC)  sprd-asoc-card-utils-legacy.c:495
#   board_func_set -> snd_soc_dapm_enable_pin() + snd_soc_dapm_sync()      :105-129
# i.e. it enables a DAPM *pin*. A route whose switch control is off conducts
# nothing, so without `ADC_1 Mixer MIC1PGA_1 Switch` the mic path does not
# exist in the graph at all -- which is exactly what the call trace showed.
#
# STAIRCASE: each stage applies its writes, then records 3 s of hw:0,0 capture
# (the codec `ADC` widget's spath is "Normal-Capture-AP01", so an open capture
# stream is what forces DAPM to evaluate this path at all) and prints
# peak/RMS + which widgets came On. Stage order is cumulative: a stage that
# changes nothing means that control was not the gate.
#
# NOT a mute trap here (measured, do not assume from the DAC side):
#   ADC_1 Gain ADC_1 Capture Volume  min=0 max=7  dBscale-min=0.00dB step=3.00dB
#   mute=0  ->  0 means 0 dB, NOT silence.  VBC ADC2 DG Set on the other hand is
#   dBscale-min=-94.50dB step=1.50dB mute=1 -> its 0 IS a mute.
#   ⚠ 2026-10-17 correction: do NOT read that TLV as a dB scale. The vendor's own
#   audio_pga.xml writes volume0 = 0x18 (24) for VBC ADC0/ADC2/ADC3 DG Set in every scene
#   (0x1c = 28 in a couple of ADC3 scenes, one ADC0 scene 0x10) -- so 24 is NOMINAL and the
#   TLV is cosmetic; 0 is still a mute. The stage below used "32,32" (hotter than anything
#   the vendor ships); it now uses the vendor's 24,24 so results stay comparable to a real
#   call. See docs/changxing60/telephony.md §10.6.
#   And ADC_1 Gain: every vendor Handset/Handsfree call scene writes 0x07 (= +21 dB), while
#   this machine idles at 0 and the call port never writes it -- that is a real uplink deficit,
#   telephony.md §10.5.
#
# SAFETY: exactly one ALSA client on card 0, ever (docs/changxing60/audio-oops:
# concurrent clients are what panicked this kernel). Refuses if a call is up or
# if any substream is open. Only capture is used here -- never playback at the
# same time.
set -u

SECS=${1:-3}
VOICE=/opt/changxing60/bin/changxing60-voice
CARD=/sys/kernel/debug/asoc/sprdphone-sc2730
SUBC=/proc/asound/card0/pcm0c/sub0
LOG=/tmp/mic-test.log
: > "$LOG"
say() { echo "$@" | tee -a "$LOG"; }

st=$("$VOICE" state 2>/dev/null | sed -n 's/^state=//p')
[ "$st" = idle ] || { say "refusing: call state=[$st] -- card 0 must be free"; exit 1; }
if [ -d "$SUBC" ]; then
	s=$(cat "$SUBC/status" 2>/dev/null)
	[ "$s" = closed ] || { say "refusing: capture substream is [$s], card busy"; exit 1; }
fi

numid_of() {
	amixer -c 0 controls 2>/dev/null |
		sed -n "s/numid=\([0-9]*\),iface=[^,]*,name='$1'.*/\1/p" | head -1
}
put() { # put <name> <value>
	n=$(numid_of "$1")
	if [ -z "$n" ]; then say "  !! no such control: $1"; return 1; fi
	if ! amixer -c 0 cset numid="$n" "$2" >/dev/null 2>&1; then
		say "  !! cset FAILED: $1=$2 (numid $n)"; return 1
	fi
	printf "  %-36s = %-16s readback=[%s]\n" "$1" "$2" \
		"$(amixer -c 0 cget numid="$n" 2>/dev/null | sed -n 's/^ *: values=//p' | head -1)" |
		tee -a "$LOG"
}

# Widgets that must end up On for the mic to reach the ADC, in graph order.
WATCH='MIC Pin|MICBIAS1|ADC_1 Mixer|ADC_1 Gain|ADC_1 Switch|ADC_1_CLK|ADie Digital ADCL Switch|Digital ADC In Sel|Digital ADCL Switch|ADC$|CLK_ADC|CLK_ADC_Norm|ADC_IBIAS|ADC_VREF_BUF|Normal-Capture-AP01|DMic Pin|MIC2 Pin'

onwidgets() { # onwidgets <when> -- print watched widgets reading ": On", WHILE the stream runs
	# The stream must be OPEN for this to mean anything: DAPM powers the capture
	# path at trigger time and drops it at close, so a post-close snapshot reads
	# all-Off and proves nothing (this exact mistake made tone-test.sh v1 wrong).
	printf "   [status=%s] " "$(cat "$SUBC/status" 2>/dev/null)"
	printf "widgets ON during %s: " "$1"
	n=0
	for d in "$CARD/dapm" "$CARD"/*/dapm; do
		[ -d "$d" ] || continue
		comp=$(echo "$d" | sed "s|$CARD/||; s|/dapm||; s|^dapm$|CARD|")
		for f in "$d"/*; do
			[ -f "$f" ] || continue
			w=$(basename "$f")
			echo "$w" | grep -qE "$WATCH" || continue
			grep -q ': On' "$f" 2>/dev/null || continue
			printf "\n     + %-22s %s" "$w" "$comp"
			n=$((n+1))
		done
	done
	[ "$n" = 0 ] && printf " (none)"
	echo ""
}

measure() { # measure <tag> <wav> -- peak/RMS of the S16 payload, no python needed
	python3 - "$2" <<'PY' 2>/dev/null || say "     (python3 unavailable; size only: $(wc -c <"$2" 2>/dev/null) bytes)"
import array, sys, math
b = open(sys.argv[1], 'rb').read()
i = b.find(b'data')
n = int.from_bytes(b[i+4:i+8], 'little') if i >= 0 else 0
s = array.array('h'); s.frombytes(b[i+8:i+8+n])
if not s:
    print("     EMPTY DATA CHUNK"); raise SystemExit
peak = max(max(s), -min(s))
rms = math.sqrt(sum(x*x for x in s)/len(s))
nz = sum(1 for x in s if x)
print("     samples=%d peak=%d (%.1f%% FS) rms=%.1f nonzero=%.2f%%" %
      (len(s), peak, 100.0*peak/32767.0, rms, 100.0*nz/len(s)))
print("     verdict: %s" % ("DIGITAL SILENCE -- ADC never delivered samples"
      if peak == 0 else
      "all-zero-but-streaming? no: peak small/noise floor" if peak < 30 else
      "REAL SIGNAL -- the mic path is alive"))
PY
}

watch_stream() { # watch_stream <tag> -- catch the stream while it is still open
	# arecord here dies on the FIRST read, so a snapshot taken after `wait` sees
	# only status=closed. Poll the proc file in a tight loop instead and report
	# the moment it is not closed, with the same fields that exposed the music
	# path's crawl (delay high + avail 0 = nothing is draining the FIFO).
	i=0
	while [ "$i" -lt 4000 ]; do
		i=$((i+1))
		s=$(cat "$SUBC/status" 2>/dev/null)
		[ -n "$s" ] || continue
		[ "$s" != closed ] && break
	done
	if [ "$i" -ge 4000 ]; then
		say "   sampler: stream never left [closed] in 4000 polls"
		return 0
	fi
	printf "   caught at poll %s: state=%s\n" "$i" "$s"
	cat "$SUBC/status" 2>/dev/null | tr -s ' ' | tr '\n' '|' | cut -c1-200 | tee -a "$LOG"
	echo ""
	# The status file reads "delay       : 4000", so the value is field 3 -- and
	# busybox awk's `/delay/d` (an undefined-variable statement) prints nothing,
	# which silently produced empty fields on the first run of this script.
	say "   hw_ptr=$(awk '/hw_ptr/{print $3}' "$SUBC/status") delay=$(awk '/delay/{print $3}' "$SUBC/status") avail=$(awk '/avail/{print $3}' "$SUBC/status") xrun=$(awk '/xrun_counter/{print $3}' "$SUBC/status") prepared=$(awk '/prepared/{print $3}' "$SUBC/status")"
	onwidgets "$1 (stream open)"
}

stage() { # stage <name>  -- record, snapshotting the graph WHILE the stream is up
	say ""
	say "########## STAGE $1 ##########"
	NB=$(logread 2>/dev/null | wc -l)
	rm -f "/tmp/mic-$1.wav"
	arecord -q -D hw:0,0 -c 1 -r 8000 -f S16_LE -d "$SECS" "/tmp/mic-$1.wav" 2>/tmp/mic-err.txt &
	AR=$!
	watch_stream "$1"
	wait "$AR"
	rc=$?
	onwidgets "$1 (after close)"
	say "   arecord rc=$rc err=[$(head -1 /tmp/mic-err.txt 2>/dev/null)] size=$(wc -c <"/tmp/mic-$1.wav" 2>/dev/null || echo 0)"
	[ -f "/tmp/mic-$1.wav" ] && measure "$1" "/tmp/mic-$1.wav"
	# EVERY kernel line produced by this attempt, not a filtered tail: the first
	# run of this script grepped for asoc|vbc|codec|dma|pcm and so missed the line
	# that actually names the failing component.
	say "   -- kernel log during this attempt --"
	logread 2>/dev/null | tail -n +$((NB+1)) | grep -viE 'sprd-wlan|sc2355|CMD_TX_DATA|ctx_id' |
		sed -n 's/^.*kernel: //p' | tail -18 | sed 's/^/      /' | tee -a "$LOG"
}

say "== mic uplink staircase, ${SECS}s per stage, capture-only (single ALSA client) =="
say "-- baseline: what is On with the card idle =="
onwidgets "idle baseline"
stage 0-baseline

say ""
say "-- the DPCM capture gate (hw:0,0 capture) + the board mic pin --"
put "S_NORMAL_AP01_C_CODEC SWITCH" on
put "Mic Function" on
stage 1-gate-and-pin

say ""
say "-- now the route switch the port never writes: mic PGA into ADC_1 Mixer --"
put "ADC_1 Mixer MIC1PGA_1 Switch" on
put "ADC_1 Gain ADC_1 Capture Volume" 4
stage 2-pga-switch

say ""
say "-- digital side: route the codec ADC into the VBC/AUD path --"
put "Digital ADC In Sel" ADC
put "AUD ADC0L Switch" on
stage 3-digital-adc

say ""
say "-- if still empty: the VBC-side source. ADC n SOURCE default is ADC_SOURCE_IIS"
say "   (measured: all four read 0 = ADC_SOURCE_IIS), i.e. the DSP's ADC input is"
say "   taken off the IIS bus, NOT from the codec's own ADC (VBCIF). e5 leaves these"
say "   alone and instead muxes ADC2 from IIS1, so BOTH shapes are possible; this"
say "   stage tests VBCIF for the AP01 capture (ADC0) explicitly."
put "VBC_MUX_ADC0_SOURCE" ADC_SOURCE_VBCIF
put "VBC ADC0 DG Set" "24,24"	# audio_pga.xml: ADC0 DG volume0 = 0x18 in every scene
stage 4-vbcif

say ""
say "-- capture-direction clocking. The music path needed VBC_IIS_MASTER_ENALBE and"
say "   VBC_IIS_MST_SEL_0_TYPE=INTERNAL, or the FIFO crawled and died in XRUN/EIO"
say "   (tone-test.sh v3, measured). EIO on every stage above looks identical, so"
say "   test the clock first. Note this is a GLOBALLY shared enable plus a PER-PORT"
say "   type: ADC0..3 select RX ports whose types are MST_SEL_1/2/3, which nothing"
say "   in this repo has ever written (probe leaves all four EXTERNAL, vbc-dai.c"
say "   :5410-5417)."
put "VBC_IIS_MASTER_ENALBE" enable
put "VBC_IIS_MST_SEL_0_TYPE" VBC_MASTER_INTERNAL
put "VBC_IIS_MST_SEL_1_TYPE" VBC_MASTER_INTERNAL
stage 5-clocks

say ""
say "-- last untested knob on this leg: which IIS port actually feeds ADC0 --"
for p in VBC_IIS_PORT_IIS0 VBC_IIS_PORT_IIS1 VBC_IIS_PORT_IIS2; do
	put "VBC_MUX_ADC0_IIS_PORT_SEL" "$p"
	stage "6-adc0-port-${p##*_}"
done

say ""
say "-- cross-check the OTHER capture front ends, sequentially (one client at a time)."
say "   If hw:0,0 capture cannot deliver but some sibling FE can, the fault is in the"
say "   AP01 capture scene, not in the mic/ADC path we just lit up. FE_ST_CAPTURE_DSP"
say "   (hw:0,2) is what the DSP captured; FE_ST_VOICE_C (hw:0,9) is the voice uplink"
say "   FE the CP owns -- expect either a clean EIO (scene not runnable from the AP) or"
say "   zeros-with-success (the no_pcm/no_dma trap, same as sprd-fe-dai.c does for FE 5)."
for dev in 2 9; do
	say ""
	say "########## STAGE cross-hw0$dev ##########"
	NB=$(logread 2>/dev/null | wc -l)
	SUBC=/proc/asound/card0/pcm${dev}c/sub0
	rm -f "/tmp/mic-hw0$dev.wav"
	arecord -q -D "hw:0,$dev" -c 1 -r 8000 -f S16_LE -d "$SECS" "/tmp/mic-hw0$dev.wav" 2>/tmp/mic-err.txt &
	AR=$!
	watch_stream "hw:0,$dev"
	wait "$AR"; rc=$?
	say "   arecord rc=$rc err=[$(head -1 /tmp/mic-err.txt 2>/dev/null)] size=$(wc -c <"/tmp/mic-hw0$dev.wav" 2>/dev/null || echo 0)"
	[ -f "/tmp/mic-hw0$dev.wav" ] && measure "hw0$dev" "/tmp/mic-hw0$dev.wav"
	logread 2>/dev/null | tail -n +$((NB+1)) | grep -viE 'sprd-wlan|sc2355|CMD_TX_DATA|ctx_id' |
		sed -n 's/^.*kernel: //p' | tail -8 | sed 's/^/      /' | tee -a "$LOG"
done
SUBC=/proc/asound/card0/pcm0c/sub0

say ""
say "== restore: put everything back the way this session found it =="
# "as found" -- NOT necessarily kernel boot defaults: VBC_IIS_MASTER_ENALBE and
# VBC_IIS_MST_SEL_0_TYPE were left enabled by tone-test.sh (the music fix), and
# VBC_MUX_ADC0_IIS_PORT_SEL read 1 (IIS1) on arrival. Boot defaults for the two
# clock controls are disable / VBC_MASTER_EXTERNAL (vbc-dai.c:5410-5417).
put "VBC_MUX_ADC0_IIS_PORT_SEL" VBC_IIS_PORT_IIS1
put "VBC_MUX_ADC0_SOURCE" ADC_SOURCE_IIS
put "VBC ADC0 DG Set" "0,0"
put "ADC_1 Mixer MIC1PGA_1 Switch" off
put "ADC_1 Gain ADC_1 Capture Volume" 0
put "Mic Function" off
put "AUD ADC0L Switch" off
put "S_NORMAL_AP01_C_CODEC SWITCH" off

say ""
say "== verdict =="
say "   stage whose first non-zero peak appears = the control that was the gate."
say "   all stages peak=0 => the codec capture path never delivers; the fault is"
say "   upstream of the codec (VBC/AGDSP), so stop tuning analog gains."
say "   real signal at any stage => the mic hardware path works; the call uplink"
say "   failure is then purely the VBC/CP side (voice_capture_type / adc_source)."
say "   wav files: /tmp/mic-*.wav   log: $LOG"
