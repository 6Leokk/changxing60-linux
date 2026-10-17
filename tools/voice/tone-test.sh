#!/bin/sh
# Device-side: split-test the ANALOGUE OUTPUT half of the audio path.
#
# Why this exists: a live call comes up with the codec chain powered and the
# AGDSP answering SIPC, yet neither direction carries sound. Two candidate
# halves --
#   (a) analogue output: codec DAC -> codec EAR/SPK mixer+PGA -> PA pin -> transducer
#   (b) voice/VBC: FE_ST_VOICE (hw:0,5) -> VBC -> AGDSP -> modem CP
# This exercises (a) ALONE through the ordinary music PCM (FE_ST_NORMAL_AP01 =
# hw:0,0), which never touches the voice path.
#   audible => (a) is alive, look only at (b);
#   silent  => (a) itself is broken (or this script's route is still wrong).
#
# THREE MISTAKES THIS SCRIPT HAD, each one capable of reporting "the transducer
# is dead" when nothing of the sort happened. All three were measured on device:
#
#  1. (v1) aplay at 48k/stereo/4x6000 died with "Unable to install hw params" --
#     the stream never started. The mask dump looks wide, so the rejection is
#     not the parameters: with the routing switch S_NORMAL_AP01_P_CODEC off, the
#     DPCM core has zero enabled backends and dpcm_fe_dai_prepare() returns
#     -EINVAL, which alsa-lib mislabels as a hw-params failure. So the switch is
#     part of the test, not an afterthought.
#  2. (v2) `aplay -n N` DOES NOT EXIST on this device's aplay: it exits rc=1 with
#     "Try `aplay --help' for more information." and plays ZERO samples. Two
#     listening rounds were conducted on that bug -- the user correctly reported
#     silence, and the run looked fine only because the rc was taken through a
#     pipe (`aplay ... | tail` reports tail's status). Playback here is a plain
#     shell loop of `aplay -d SECS`, each pass reporting its own rc.
#  3. (v2) every digital AND analog gain sat at 0. Two separate silent-knob
#     families matter and only one was obvious:
#       analog:  DAC Gain (0..2, idle 0), EAR/HPL Gain (0..15), AO Gain (0..15)
#       DSP:     the per-DAC digital gains -- and the SCENE NUMBER MATTERS. Music
#                is DAC0/DA0 (get_startup_scene_dac_id(VBC_DAI_ID_NORMAL_AP01)),
#                voice is DAC1/DA1. VBC DAC0 DG Set / VBC DAC0 DSP MDG Set /
#                VBC DAC0 AUD MDG Set / VBC_DAC0_DP_EN all idle at 0 == digital
#                silence with a perfectly green stream. Setting the DAC1 family
#                instead (what the call monitor writes) changes nothing audible.
#     Also VBC_IIS_MASTER_ENALBE=enable + VBC_IIS_MST_SEL_0_TYPE=VBC_MASTER_INTERNAL,
#     without which nothing drains the AP->VBC FIFO at all: RUNNING, delay=4000,
#     avail=0, hw_ptr +160 B/s, then XRUN and "write error: I/O error".
#
# Because "rc=0" only proves the DMA ran, this script also MEASURES hw_ptr twice
# and prints what it saw -- green-but-frozen is exactly the failure mode here.
#
# amixer on the device matches BARE names for some controls and refuses compound
# ones ("DAC Gain DAC Playback Volume"), so every write here goes through numid,
# resolved from `amixer -c 0 controls`.
#
# SAFETY: card 0 must be free -- never run during a call, stop the voice monitor
# first (two concurrent ALSA clients on card 0 is what panicked the kernel,
# docs/changxing60/audio-oops). Refuses to start if a call is up.
#
# Usage: tone-test.sh <ear|spk|smtpa> [passes] [seconds]   (default ear 3 8)
set -u

MODE=${1:-ear}
PASSES=${2:-6}
SECS=${3:-6}
W=/tmp/tone8k_max.wav	# 0 dBFS; /tmp/tone8k.wav (0.7 FS) is the fallback
[ -f "$W" ] || W=/tmp/tone8k.wav
LOG=/tmp/tone-test.log
VOICE=/opt/changxing60/bin/changxing60-voice
CARD=/sys/kernel/debug/asoc/sprdphone-sc2730
SUB=/proc/asound/card0/pcm0p/sub0
: > "$LOG"
say() { echo "$@" | tee -a "$LOG"; }

[ -f "$W" ] || { say "missing $W -- push an 8kHz mono S16 wav first"; exit 1; }

st=$("$VOICE" state 2>/dev/null | sed -n 's/^state=//p')
if [ "$st" != idle ]; then
	say "refusing: call state=[$st] -- card 0 must be free"
	exit 1
fi

numid_of() { # numid_of <exact control name>
	amixer -c 0 controls 2>/dev/null |
		sed -n "s/numid=\([0-9]*\),iface=[^,]*,name='$1'.*/\1/p" | head -1
}
put() { # put <name> <value>  -- reports FAIL instead of lying
	n=$(numid_of "$1")
	if [ -z "$n" ]; then say "  !! no such control: $1"; return 1; fi
	if ! amixer -c 0 cset numid="$n" "$2" >/dev/null 2>&1; then
		say "  !! cset FAILED: $1=$2 (numid $n)"; return 1
	fi
	printf "  %-34s = %-22s readback=[%s]\n" "$1" "$2" \
		"$(amixer -c 0 cget numid="$n" 2>/dev/null | sed -n 's/^ *: values=//p' | head -1)" |
		tee -a "$LOG"
}

say "== $MODE, $PASSES x ${SECS}s. Route MUST be set before aplay: the mux caches"
say "   are embedded in the DSP STARTUP message, so a post-start write is ignored."

# -- 0. the DPCM gate: no switch => no backend => "Unable to install hw params"
case "$MODE" in
ear)
	say "-- DPCM gate + earpiece path (DAC -> DACHPL -> EAR_HPL -> EAR -> Ext Ear)"
	put "S_NORMAL_AP01_P_CODEC SWITCH" on
	put "Earpiece Mute" off
	put "Earpiece Function" on
	put "Speaker Function" off
	put "EAR_HPL Mixer DACHPL Switch" on
	put "HPL EAR Sel" EAR
	put "HPL EAR Sel2" EAR
	put "DACAOL Switch" off
	put "AO Mixer AOL Switch" off
	put "AO Mixer AOR Switch" off
	put "DA AOR Switch" off
	;;
spk|smtpa)
	say "-- DPCM gate + speaker path (DAC -> AOL -> SDAAOL -> AO -> SPK Pin -> Ext Spk)"
	say "   smtpa additionally opens the IVS smart-amp BE: this board's power amplifier is an"
	say "   AW87xxx for which no driver exists here, so the AO pin alone may drive nothing at all."
	say "   BE_DAI_ID_FAST_P_SMART_AMP feeds the same codec 'Normal-Playback' widget, so the"
	say "   SMTPA route is the in-driver way to get the amplifier running (ivs_smtpa flag)."
	put "S_NORMAL_AP01_P_CODEC SWITCH" on
	if [ "$MODE" = smtpa ]; then
		put "S_NORMAL_AP01_P_SMTPA SWITCH" on
		put "Speaker Function" on
	else
		put "S_NORMAL_AP01_P_SMTPA SWITCH" off
	fi
	put "Speaker Mute" off
	put "Speaker Function" on
	put "Earpiece Function" off
	put "AO Mixer AOL Switch" on
	put "AOL EAR Sel" AOL
	put "AOL EAR Sel2" AOL
	put "EAR_HPL Mixer DACHPL Switch" off
	;;
*) say "usage: $0 <ear|spk|smtpa> [passes] [seconds]"; exit 1 ;;
esac

# -- 1. get AP samples INTO the DAC at all
say "-- VBC source + IIS master (without the master nothing drains the FIFO: XRUN/EIO)"
# VBC_MUX_DAC0_OUT_SEL is deliberately LEFT ALONE here. Measured on device: its
# cache boots at 0 = DAC_OUT_FROM_IIS and playback is clean (rc=0, hw_ptr
# advancing ~16 KB/s at 8k/mono/S16); writing 1 = DAC_OUT_FROM_VBCIF makes every
# pass die with "write error: I/O error". So the vendor-enum guess "AP-fed
# playback needs VBCIF" is contradicted by this machine -- keep 0, don't chase it.
put "VBC_IIS_MASTER_ENALBE" enable
put "VBC_IIS_MST_SEL_0_TYPE" VBC_MASTER_INTERNAL

# -- 2. the DSP-side digital gains. THE MUSIC SCENE IS DAC0 (DA0); the voice
# scene is DAC1 (DA1). The monitor's tables only carry DAC1 values, so copying
# them into a music test left every DA0 gain at 0 == digital silence behind a
# perfectly green stream. Measured idle here: DAC0 DG 0,0 / DAC0 DSP MDG 0,0 /
# DAC0 AUD MDG 0,0.
#
# UNITS -- the kcontrol TLV on device (`amixer cget`, numid 14) says:
#   VBC DAC0/DAC1/ADC0/ADC2 DG Set: min=0 max=127
#        dBscale-min=-94.50dB, step=1.50dB, mute=1
#   => read literally that makes 0 mute, 64 == 0 dB, and 24 == -60 dB.
#   *** AN EARLIER REVISION OF THIS FILE ASSERTED EXACTLY THAT AND WAS WRONG. ***
#   It concluded "the 24 the call monitor inherited is a near-mute" and raised everything to 64.
#   The vendor's own tables refute it (docs/changxing60/telephony.md §10.3/§10.6, values read out
#   of work/audio/vendor-xml/audio_pga.xml on 2026-10-17): EVERY call scene writes
#   `VBC DAC1 DG Set` volume0 = 0x18 = **24** (25/26 at the top levels), and the MUSIC scenes
#   write `VBC DAC0 DG Set` = 0x19 (Handset) / 0x1c (Headset) / **0x21 = 33 (Handsfree)**.
#   So 24 is NOMINAL on this board and the TLV is cosmetic. The kernel does NO conversion at all:
#   `vbc_dg_put` (vbc-dai.c:611-637) stores the u32s raw in `vbc_codec->dg[id]` and calls
#   `dsp_vbc_dg_set(id, val1, val2)`, which packs `{reload, dg_id, dg_left, dg_right}` raw over
#   SIPC (vbc-phy-v4.c:701-718); the only bound is ALSA's `DG_MAX_VAL = 0x7f` (7 bits), matching the
#   blob's `voice_dg_l/r bits="7" val="0x18"`. Two things follow: the numeric unit belongs to the
#   CLOSED AGDSP firmware (do not invent a formula -- an earlier revision of this file attributed
#   "dg_value = 100 + value/8, DG_MAX_GAIN 0x50" to the kernel; **neither symbol exists anywhere in
#   kernel-src**, grep proved it), and since every `dsp_*` wrapper ends in `return 0` while only
#   pr_err-ing an SIPC failure, **a successful `cset` proves the send was ATTEMPTED, not applied**.
#   The values below are therefore the VENDOR's, not an invented "unity".
#   *_MDG Set (min=0 max=8191) is NOT a gain at all -- see below.
# "0" is still never a safe neutral value for a DG: it is a mute.
#
# VBC_DAC0_DP_EN must stay 0. It is NOT "data path enable" -- it is the vendor
# AUDIO DUMP select (vbc-dai.c:7434: "VBC_DAC0_DP_EN is the parameter of audio
# dump"; vbc-dai.c:5925 turns it on only for a DSP log dump case), and setting
# it to 1 diverts the stream into the diagnostic dump: silent transducer.
# *** AND THE 0 dB LISTENING ROUND THIS SCRIPT CAUSED WAS VOID ***. The line used to be
#     put "VBC DAC0 DSP MDG Set" "1024,1024"
# `vbc_mdg_put` (kernel vbc-dai.c:486-504) prints its own debug as "mute:%02d, step:%02d" and maps
# value[0] -> mdg.mdg_mute, value[1] -> mdg_step, both pushed to the DSP via dsp_vbc_mdg_set().
# So 1024 in slot 0 was a NON-ZERO MUTE request, and "I raised the gain and still heard nothing"
# proved nothing about the analogue half -- the script muted itself and the user correctly heard
# silence. MDG now gets the vendor's unmuted shape (dsp_vbc.xml: mtdg_ctl=1, mtdg_en=1,
# mtdg_step=0x8). Note the call monitor's ROUTES still carries 'VBC DAC1 DSP MDG Set': '1,1024'
# -- same field, same reading -- which is now the prime suspect in telephony.md §10.7.
say "-- digital gains on the DAC0 family (DG: 0 = mute, vendor music values below;"
say "   DP_EN 1 = audio dump; MDG value[0] is the MUTE flag, value[1] the ramp step)"
put "VBC_DAC0_DP_EN" 0
case "$MODE" in
ear)   put "VBC DAC0 DG Set" "25,25" ;;   # vendor Music/Handset/Playback volume0 = 0x19
spk)   put "VBC DAC0 DG Set" "33,33" ;;   # vendor Music/Handsfree/Playback volume0 = 0x21
smtpa) put "VBC DAC0 DG Set" "33,33" ;;
esac
put "VBC DAC0 DSP MDG Set" "0,8"
put "VBC DAC0 AUD MDG Set" "0,8"
# VBC_VOLUME cannot be set while the card is idle: the put returns
# "element write error: Operation not permitted" (EPERM) for any value, so it
# stays at its boot cache 0xffffffff. Not our mute -- but note it for the call
# path, where the monitor does write it while a stream is up.

# -- 3. the analog trims, at their ceiling (the user asked for more volume)
say "-- analog gains"
put "DAC Gain DAC Playback Volume" 2
case "$MODE" in
ear) put "EAR Gain EAR Playback Volume" 15; put "HPL Gain HPL Playback Volume" 15 ;;
spk|smtpa) put "AO Gain AO Playback Volume" 15 ;;
esac

say "== playing $PASSES x ${SECS}s of 1kHz gated tone out of hw:0,0 =="
say "   (a 0.5s on / 0.5s off gate: a steady tone and a buzzing wire are easy to confuse)"
i=1
fail=0
while [ "$i" -le "$PASSES" ]; do
	aplay -q -D hw:0,0 -c 1 -r 8000 -f S16_LE -d "$SECS" "$W" 2>/tmp/tone-err.txt
	rc=$?
	[ "$rc" = 0 ] || fail=$((fail+1))
	printf "  pass %s rc=%s err=[%s] status=%s\n" "$i" "$rc" \
		"$(head -1 /tmp/tone-err.txt 2>/dev/null)" \
		"$(cat "$SUB/status" 2>/dev/null)" | tee -a "$LOG"
	i=$((i+1))
done

say "== final pass: does the position actually advance, and what is powered WHILE it runs? =="
# The /proc/asound status file reads "hw_ptr      : 32080", so the value is the
# THIRD whitespace field (taking $2 yields the colon).
hp() { awk '/hw_ptr/{print $3}' "$SUB/status" 2>/dev/null | head -1; }
aplay -q -D hw:0,0 -c 1 -r 8000 -f S16_LE -d 16 "$W" 2>/tmp/tone-err.txt &
APLAY=$!
# Both samples must be taken while the stream is still OPEN -- sampling after it
# closes reads "closed" and the diff comes out meaningless (it did exactly that).
sleep 2; h1=$(hp)
sleep 4; h2=$(hp)
d1=$((h2-h1))
say "   hw_ptr $h1 -> $h2 over 4s = ${d1} bytes (expect ~64000: 8k/mono/S16 = 16000 B/s;"
say "        ~160 B/s would mean the DSP is not consuming the FIFO at all)"
say "-- DAPM state WITH the stream up (a post-close snapshot reads all-Off and proves nothing) =="
for d in "$CARD/dapm" "$CARD"/*/dapm "$CARD"/FE_*; do
	[ -d "$d" ] || continue
	comp=$(echo "$d" | sed "s|$CARD/||; s|/dapm||; s|^dapm$|CARD|")
	for f in "$d"/*; do
		[ -f "$f" ] || continue
		case "$(basename "$f")" in
		*Ext_Ear*|*Ext_SPK*|*Ext_HP*|*EAR_Pin*|*EAR_Switch*|*SPK_Pin*|*AO_EN*|*DAAOL*|*SDAHPL*|*DAC*|*Normal-Playback*|*S_NORMAL_AP01_P_CODEC*)
			grep -q ': On' "$f" 2>/dev/null || continue
			printf "   %-20s %-24s [%s]\n" "$comp" "$(basename "$f" | sed 's/.*__//')" \
				"$(tr -s ' ' <"$f" | cut -c1-70)" | tee -a "$LOG" ;;
		esac
	done
done
wait "$APLAY"; say "   final aplay rc=$? err=[$(head -1 /tmp/tone-err.txt)]"

say "== verdict =="
say "   $((PASSES-fail))/$PASSES passes completed without error."
say "   audible   => the analogue half works; the call silence is in the voice/VBC/CP half."
say "   NOT heard => re-check this output for cset FAILED lines and for a crawling hw_ptr;"
say "              a green stream + crawling hw_ptr = VBC side, not the codec."
say "   log at $LOG"
