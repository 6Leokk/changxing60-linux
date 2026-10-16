#!/bin/bash
# Host-side test for the voice control plane: changxing60-voiced's call state machine, the shared library, and the
# changxing60-voice CLI. No modem, no /dev/stty_nr1, no panel.
#
# Why this is worth a test. None of this can be exercised on the device (it is offline), and the failures that
# matter here are all silent ones: a state file that says "active" for a call that ended, a log line written for
# a call still in progress, a call marked "missed" that somebody actually answered. Every one of those is a
# plausible-looking file, and the only way to catch them is to drive the state machine with scripted modem
# replies and read what it wrote.
#
# What it pins down:
#   * a call is only ended by two consecutive replies that say so -- one empty reply is not an ending
#   * a modem that does not answer at all changes nothing (changxing60-at's non-zero exit is the signal)
#   * answered / missed / rejected / failed are told apart, and rejected only from a fresh marker
#   * the talk time is stamped when the call becomes active, not when it rings
#   * the audio hook is asked for exactly one start and one stop per call
#   * the contact book matches across a country code, and refuses to match on a short number
#   * the CLI's argument validation, which is what stands between a typed string and the modem's parser
#
# The daemon is sourced with its main loop stripped (it is an infinite loop), so poll() and read_urcs() can be
# called by hand. That is also why read_urcs() is a function: a test that cannot reach the URC path would not
# notice a caller id that never arrives.
set -uo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
BIN=$HERE/../../rootfs/overlay/opt/changxing60/bin
LIB=$HERE/../../rootfs/overlay/opt/changxing60/lib/voice.sh
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT

[ -r "$LIB" ] || { echo "no $LIB"; exit 1; }
[ -r "$BIN/changxing60-voiced" ] || { echo "no $BIN/changxing60-voiced"; exit 1; }

# --- the world the voice stack talks to ------------------------------------------------------------
mkdir -p "$T/run" "$T/urc" "$T/etc" "$T/at"
# The AT daemon's command fifo. changxing60-voiced waits for it before it touches the channel at all, so the test
# world has to have one or sourcing the daemon blocks for its whole wait budget.
mkfifo "$T/at/cmd"
export CHANGXING60_VOICE_DIR="$T/run" CHANGXING60_VOICE_LOG="$T/etc/call-log" CHANGXING60_VOICE_CONTACTS="$T/etc/contacts"
export CHANGXING60_AT_DIR="$T/at" CHANGXING60_AT_URC_DIR="$T/urc" CHANGXING60_VOICE_LIB="$LIB"

# Stand-in for /opt/changxing60/bin/changxing60-at: prints FAKE_CLCC and exits FAKE_RC. A non-zero FAKE_RC is the real
# client's "the modem returned no final response" -- the case the daemon must not read as "the call ended".
cat > "$T/fake-at" <<'EOS'
#!/bin/bash
printf '%s' "${FAKE_CLCC:-}"
exit "${FAKE_RC:-0}"
EOS
chmod +x "$T/fake-at"
export CHANGXING60_AT_BIN="$T/fake-at"

cat > "$T/fake-audio" <<'EOS'
#!/bin/bash
printf '%s\n' "$1" >> "$FAKE_AUDIO_LOG"
EOS
chmod +x "$T/fake-audio"
export CHANGXING60_VOICE_AUDIO_BIN="$T/fake-audio" FAKE_AUDIO_LOG="$T/audio.log"

# The scripted replies go through the environment, so they have to be EXPORTED: the stub is a separate process
# and a plain shell variable is invisible to it. (Getting this wrong does not look like a broken test -- every
# reply arrives empty, which is a perfectly valid "no call", and the whole state machine then reports idle.)
export FAKE_CLCC='' FAKE_RC=0

# --- harness --------------------------------------------------------------------------------------
pass=0; fail=0
ok() { pass=$((pass + 1)); printf 'ok   %s\n' "$1"; }
no() { fail=$((fail + 1)); printf 'FAIL %s\n' "$1"; }
is() { [ "$2" = "$3" ] && ok "$1" || no "$1 -- got [$2], wanted [$3]"; }

# scripted replies
no_call()  { FAKE_CLCC=$'\r\nOK\r\n'; }
call_up()  { FAKE_CLCC=$(printf '+CLCC: 1,%s,%s,0,0,"%s",129\r\nOK\r\n' "$1" "$2" "$3"); }
reset_all() { rm -f "$T/etc/call-log" "$T/audio.log" "$T/run/state" "$T/run/rejected" "$T/run/nudge"
              : > "$T/audio.log"; FAKE_RC=0; }

# --- the daemon, with its main loop cut off -------------------------------------------------------
sed '/^while :; do$/,$d' "$BIN/changxing60-voiced" > "$T/daemon.sh" || exit 1
grep -q '^poll()' "$T/daemon.sh" || { echo "the daemon did not survive extraction"; exit 1; }
grep -q '^while :; do$' "$T/daemon.sh" && { echo "extraction left the main loop in"; exit 1; }
# shellcheck disable=SC1090
. "$T/daemon.sh"
set +e    # the assertions below deliberately drive the paths that must not fail the test

# --- 1. no call at all ----------------------------------------------------------------------------
reset_all
no_call; poll; poll
is "idle: no state written" "$(state_read state)" ""
is "idle: nothing logged" "$(wc -l < "$T/etc/call-log" 2>/dev/null || echo 0)" 0
is "idle: the audio hook was never asked" "$(wc -c < "$T/audio.log")" 0

# --- 2. an incoming call that is answered ---------------------------------------------------------
call_up 1 4 "+8613800138000"; poll
is "ringing: state" "$(state_read state)" ringing
is "ringing: direction" "$(state_read dir)" in
is "ringing: number" "$(state_read number)" "+8613800138000"
is "ringing: no talk time yet" "$(state_read talk)" ""
is "ringing: the audio hook is not asked yet" "$(wc -c < "$T/audio.log")" 0

call_up 1 0 "+8613800138000"; poll
is "answered: state" "$(state_read state)" active
[ -n "$(state_read talk)" ] && ok "answered: the talk time is stamped" || no "answered: no talk time"
is "answered: the audio hook started once" "$(wc -l < "$T/audio.log")" 1
is "answered: ... with start" "$(cat "$T/audio.log")" start

no_call; poll
is "one empty reply: the call is still up" "$(state_read state)" active
no_call; poll
is "two empty replies: idle" "$(state_read state)" idle
is "the log has one line" "$(wc -l < "$T/etc/call-log")" 1
# The duration is however long this test took to get from the answer to the hangup -- one second or two. Only
# its shape is asserted here; the value is checked in section 10, where log_append is called with a known one.
# Matched with case and not with a pattern: in an ERE a "+" after a "|" is a repetition, not a literal, and
# "+8613800138000" then matches something else entirely.
_line=$(head -1 "$T/etc/call-log")
case $_line in
    *"|in|answered|+8613800138000|"*) ok "logged as an answered incoming call" ;;
    *) no "logged wrong: $_line" ;;
esac
is "the logged duration is a number" \
   "$(printf '%s' "$_line" | awk -F'|' '{ print ($6 ~ /^[0-9]+$/) ? "yes" : "no" }')" "yes"
is "the audio hook was stopped once" "$(wc -l < "$T/audio.log")" 2
is "the audio hook's second word is stop" "$(tail -1 "$T/audio.log")" stop

# --- 2b. the daemon refuses to be the second reader on the channel ---------------------------------
# Without the AT daemon, changxing60-at opens /dev/stty_nr1 for itself, and a second reader on an SIPC channel leaves
# the modem silent until a reboot. So the wait has a deadline and the daemon gives up rather than proceed.
mv "$T/at/cmd" "$T/at/cmd.off"
CHANGXING60_VOICE_AT_WAIT=0 at_wait; is "no AT daemon: the wait gives up (1)" "$?" 1
mv "$T/at/cmd.off" "$T/at/cmd"
at_wait; is "an AT daemon present: the wait returns at once" "$?" 0

# --- 3. ringing and never answered: missed --------------------------------------------------------
reset_all
call_up 1 4 "+8613800138000"; poll
no_call; poll; no_call; poll
grep -q '|in|missed|' "$T/etc/call-log" && ok "a call nobody answered is missed" \
    || no "not missed: $(cat "$T/etc/call-log")"
is "a missed call asks for no audio" "$(wc -c < "$T/audio.log")" 0

# --- 4. ringing and refused by us: rejected -------------------------------------------------------
reset_all
call_up 1 4 "+8613800138000"; poll
date +%s > "$T/run/rejected"        # exactly what changxing60-voice hangup leaves on a ringing call
no_call; poll; no_call; poll
grep -q '|in|rejected|' "$T/etc/call-log" && ok "a call we ended while it rang is rejected" \
    || no "not rejected: $(cat "$T/etc/call-log")"
[ -e "$T/run/rejected" ] && no "the reject marker outlived the call" || ok "the reject marker was cleared"

# --- 5. a stale marker does not make the next missed call rejected --------------------------------
reset_all
call_up 1 4 "+8613800138000"; poll
printf '%s' "$(( $(date +%s) - 600 ))" > "$T/run/rejected"   # ten minutes old: not this call's hangup
no_call; poll; no_call; poll
grep -q '|in|missed|' "$T/etc/call-log" && ok "a stale marker is ignored" \
    || no "a stale marker was believed: $(cat "$T/etc/call-log")"

# --- 6. an outgoing call that never connects: failed ----------------------------------------------
reset_all
call_up 0 2 "+8613800138000"; poll
is "dialling: direction" "$(state_read dir)" out
call_up 0 3 "+8613800138000"; poll
is "alerting: state" "$(state_read state)" alerting
no_call; poll; no_call; poll
grep -q '|out|failed|' "$T/etc/call-log" && ok "an outgoing call that never connected is failed" \
    || no "not failed: $(cat "$T/etc/call-log")"

# --- 7. a modem that stops answering ends nothing -------------------------------------------------
reset_all
call_up 1 4 "+8613800138000"; poll
FAKE_RC=1
no_call; poll; poll; poll
is "a silent modem leaves the state alone" "$(state_read state)" ringing
is "a silent modem logs nothing" "$(wc -l < "$T/etc/call-log" 2>/dev/null || echo 0)" 0
FAKE_RC=0
no_call; poll; no_call; poll
is "and the call ends normally once it answers again" "$(state_read state)" idle

# --- 8. the contact book -------------------------------------------------------------------------
printf '+8613800138000|张三\n13800139000|李四\n' > "$T/etc/contacts"
is "contact: the number as stored" "$(contact_name '+8613800138000')" "张三"
is "contact: without the country code" "$(contact_name '13800138000')" "张三"
is "contact: the other one" "$(contact_name '+8613800139000')" "李四"
is "contact: a stranger" "$(contact_name '+8613900000000')" ""
is "contact: a short number is not a match" "$(contact_name '1380013')" ""
is "contact: nothing in, nothing out" "$(contact_name '')" ""
printf 'garbage line with no separator\n' >> "$T/etc/contacts"
is "contact: a malformed line is skipped, not fatal" "$(contact_name '+8613800138000')" "张三"

# a call from a known number carries the name into the state file and the log
reset_all
call_up 1 4 "13800138000"; poll
is "a known caller's name reaches the state" "$(state_read name)" "张三"
call_up 1 0 "13800138000"; poll
no_call; poll; no_call; poll
grep -q '|answered|13800138000|张三|' "$T/etc/call-log" && ok "the name reaches the call log" \
    || no "the name is missing from the log: $(cat "$T/etc/call-log")"

# --- 9. the URC path: a caller id that arrives before the poll -------------------------------------
reset_all
: > "$T/urc/stty_nr0.log"; : > "$T/urc/stty_nr1.log"
printf '0' > "$T/run/mark.stty_nr0"; printf '0' > "$T/run/mark.stty_nr1"
printf 'RING\r\n+CLIP: "+8613800138000",145,,,,0\r\n' >> "$T/urc/stty_nr0.log"
read_urcs
is "urc: the caller id is picked up" "$ring_num" "+8613800138000"
is "urc: the ring is counted" "$ringing" 1
read_urcs
is "urc: the second read sees nothing new" "$ring_num" ""
is "urc: ... and no ring" "$ringing" 0
# a withheld number arrives as an empty +CLIP: it must not become a number
printf 'RING\r\n+CLIP: "",128,,,,0\r\n' >> "$T/urc/stty_nr0.log"
read_urcs
is "urc: a withheld number stays empty" "$ring_num" ""
is "urc: ... but the ring is still counted" "$ringing" 1
# the daemon truncates the URC log at CHANGXING60_AT_URC_MAX; a mark past the new end must not skip the file
printf 'RING\r\n' > "$T/urc/stty_nr0.log"
read_urcs
is "urc: a truncated log is read from the start" "$ringing" 1

# --- 10. the CLI ----------------------------------------------------------------------------------
VOICE="sh $BIN/changxing60-voice"
reset_all
# A fresh book rather than section 8's: that one carries a deliberately malformed line, and this section's
# contact assertions are about the CLI, not about parsing. The contacts sub-section below starts from nothing.
printf '+8613800138000|张三\n' > "$T/etc/contacts"
state_write ringing in "+8613800138000" "张三" 1 "$(date +%s)" ''
is "cli: state prints the file" "$($VOICE state | head -1)" "state=ringing"
is "cli: status names the caller" "$($VOICE status)" "incoming call from 张三 (+8613800138000)"
is "cli: name finds a contact" "$($VOICE name 13800138000)" "张三"
is "cli: name of a stranger is empty" "$($VOICE name +8613900000000)" ""

# the number check is what stands between a typed string and the modem's parser
$VOICE dial 'abc' >/dev/null 2>&1; is "cli: dial refuses a non-number (2)" "$?" 2
$VOICE dial '+86 138' >/dev/null 2>&1; is "cli: dial refuses a space" "$?" 2
$VOICE dial '' >/dev/null 2>&1; is "cli: dial refuses nothing" "$?" 2
$VOICE dial '++86138' >/dev/null 2>&1; is "cli: dial refuses two pluses" "$?" 2
$VOICE dtmf '+1' >/dev/null 2>&1; is "cli: dtmf refuses a plus" "$?" 2
$VOICE dtmf '' >/dev/null 2>&1; is "cli: dtmf refuses nothing" "$?" 2
$VOICE mute maybe >/dev/null 2>&1; is "cli: mute refuses anything but on|off" "$?" 2
$VOICE nonsense >/dev/null 2>&1; is "cli: an unknown subcommand is a usage error" "$?" 2

FAKE_CLCC=$'\r\nOK\r\n'
$VOICE dial '+8613800138000' >/dev/null 2>&1; is "cli: a good dial succeeds" "$?" 0
[ -e "$T/run/nudge" ] && ok "cli: the dial nudged the daemon" || no "cli: the daemon was not nudged"
# An MMI code is an ordinary call to the network, and the * and # in it are not optional: without them the
# feature codes a phone can dial are simply not reachable from here.
$VOICE dial '*100#' >/dev/null 2>&1; is "cli: an MMI code is dialable" "$?" 0
$VOICE dial '+' >/dev/null 2>&1; is "cli: a lone plus is not" "$?" 2
# DTMF is where * and # matter most: they are how an IVR menu is navigated at all.
$VOICE dtmf '*#123' >/dev/null 2>&1; is "cli: dtmf accepts * and #" "$?" 0
$VOICE dtmf '12A' >/dev/null 2>&1; is "cli: dtmf accepts the A-D column" "$?" 0
FAKE_CLCC=$'\r\nERROR\r\n'
$VOICE dial '+8613800138000' >/dev/null 2>&1; is "cli: an ERROR is not a placed call" "$?" 1
FAKE_CLCC=$'\r\nOK\r\n'
$VOICE answer >/dev/null 2>&1; is "cli: answer succeeds on OK" "$?" 0
FAKE_CLCC=$'\r\nERROR\r\n'
$VOICE answer >/dev/null 2>&1; is "cli: answer fails on ERROR" "$?" 1

# contacts through the CLI
rm -f "$T/etc/contacts"
$VOICE contacts add '+8613800138000' '王五' >/dev/null 2>&1
is "cli: contacts add" "$(cat "$T/etc/contacts")" "+8613800138000|王五"
$VOICE contacts add '+8613800138000' '王五五' >/dev/null 2>&1
is "cli: re-adding the same number replaces it" "$(wc -l < "$T/etc/contacts")" 1
is "cli: ... with the new name" "$($VOICE name +8613800138000)" "王五五"
$VOICE contacts add '+8613800139000' 'a|b' >/dev/null 2>&1
is "cli: a name with the separator is refused (2)" "$?" 2
is "cli: ... and is not written" "$(wc -l < "$T/etc/contacts")" 1
$VOICE contacts del '+8613800138000' >/dev/null 2>&1
is "cli: contacts del" "$?" 0
is "cli: ... and the book is empty again" "$(wc -l < "$T/etc/contacts" 2>/dev/null || echo 0)" 0
$VOICE contacts del '+8613800138000' >/dev/null 2>&1
is "cli: deleting a number that is not there fails (1)" "$?" 1

# the call log, newest first
reset_all
log_append in answered '+8613800138000' '张三' 61
log_append out failed '+8613800139000' '' 0
is "cli: the log is newest first" "$($VOICE log | head -1 | cut -d' ' -f3)" "failed"
is "cli: the log has both" "$($VOICE log | wc -l)" 2
is "cli: the log's duration field" "$($VOICE log | tail -1 | cut -d' ' -f6)" 61
$VOICE log clear >/dev/null 2>&1
is "cli: log clear empties it" "$(wc -c < "$T/etc/call-log")" 0
$VOICE log nonsense >/dev/null 2>&1; is "cli: log refuses a bad page" "$?" 2

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
