#!/bin/sh
# The checks behind tools/voice/test-rpcd.sh: the call page's backend (rpcd ucode plugin changxing60voice.uc) and
# the detached dial it drives (changxing60-voice-job), exercised against the fake AT and the real voice CLI.
#
# Nothing here reaches a modem: the AT channel is tools/voice/fake-at, which answers ATD/ATA/CHUP/VTS/CMUT from
# environment knobs and writes every command it was handed to $FAKE_AT_DIALED. What it covers is what a device
# could not tell us - the shape of every reply the page reads, that a dial is handed off and asked after rather
# than run inside the call, that a refused or wedged dial is reported as a failure instead of an eternal
# "dialing", and that two dials at once cannot both reach the modem.
set -u

REPO=${REPO:-/repo}
WORK=${WORK:-/work}
PLUGIN=$REPO/openwrt/overlay/usr/share/rpcd/ucode/changxing60voice.uc
ACL=$REPO/openwrt/overlay/usr/share/rpcd/acl.d/luci-app-changxing60voice.json
MENU=$REPO/openwrt/overlay/usr/share/luci/menu.d/luci-app-changxing60voice.json
VIEW=$REPO/openwrt/overlay/www/luci-static/resources/view/changxing60voice/voice.js
JOB=$REPO/openwrt/overlay/opt/changxing60/bin/changxing60-voice-job
VOICE=$REPO/rootfs/overlay/opt/changxing60/bin/changxing60-voice
LIB=$REPO/rootfs/overlay/opt/changxing60/lib/voice.sh
HARNESS=$REPO/tools/sms/rpcd-harness.uc
FAKE=$REPO/tools/voice/fake-at

for f in "$PLUGIN" "$ACL" "$MENU" "$VIEW" "$JOB" "$VOICE" "$LIB" "$HARNESS" "$FAKE"; do
    [ -e "$f" ] || { echo "missing $f" >&2; exit 2; }
done

tmp=$WORK/t
rm -rf "$tmp"
mkdir -p "$tmp/bin" "$tmp/run" "$tmp/etc" "$tmp/jobroot" "$tmp/atdir" "$tmp/tmpdir"
# the image's /tmp is root-owned and 0755, which a non-root run cannot write in
TMPDIR=$tmp/tmpdir; export TMPDIR

# --------------------------------------------------------------------- the modem side
cp "$FAKE" "$tmp/bin/changxing60-at"
chmod 755 "$tmp/bin/changxing60-at"

PATH="$tmp/bin:$PATH"; export PATH
CHANGXING60_VOICE_BIN=$VOICE;          export CHANGXING60_VOICE_BIN
CHANGXING60_VOICE_LIB=$LIB;            export CHANGXING60_VOICE_LIB
CHANGXING60_AT_BIN=$tmp/bin/changxing60-at; export CHANGXING60_AT_BIN
CHANGXING60_AT_DIR=$tmp/atdir;         export CHANGXING60_AT_DIR
CHANGXING60_VOICE_DIR=$tmp/run;        export CHANGXING60_VOICE_DIR
CHANGXING60_VOICE_STATE=$tmp/run/state; export CHANGXING60_VOICE_STATE
CHANGXING60_VOICE_LOG=$tmp/etc/call-log; export CHANGXING60_VOICE_LOG
CHANGXING60_VOICE_CONTACTS=$tmp/etc/contacts; export CHANGXING60_VOICE_CONTACTS
CHANGXING60_VOICE_JOB_BIN=$JOB;        export CHANGXING60_VOICE_JOB_BIN
CHANGXING60_VOICE_JOB_DIR=$tmp/jobroot; export CHANGXING60_VOICE_JOB_DIR
FAKE_AT_DIALED=$tmp/dialed;            export FAKE_AT_DIALED

# call METHOD [JSON]: the plugin's reply, through the harness (the plugin is a module, so it cannot be run on
# its own, and the arguments go to it as an argument, not on stdin)
call() { ucode "$HARNESS" "$PLUGIN" "$1" "${2:-{\}}"; }
# await_in FILE PATTERN [TRIES]: until the file carries the pattern (a detached command writes it when it gets
# around to it, and the caller is not allowed to have waited for it)
await_in() {
    _n=0
    while [ "$_n" -lt "${3:-10}" ]; do
        grep -q "$2" "$1" 2>/dev/null && return 0
        _n=$((_n + 1)); sleep 1
    done
    grep -q "$2" "$1" 2>/dev/null
}
# await_job [TRIES]: until dialjob stops saying running. Note it leaves its last probe in $out - callers that
# assert on the finished job re-read dialjob afterwards.
await_job() {
    _n=0
    while [ "$_n" -lt "${1:-40}" ]; do
        out=$(call dialjob '{}')
        case "$out" in *'"running": 1'*) _n=$((_n + 1)); sleep 1 ;; *) return 0 ;; esac
    done
    return 1
}
# count_in JSON NEEDLE: how many times a needle appears in a reply - the replies are one line, so grep -c
# would count lines, and what matters here is occurrences
count_in() { printf '%s' "$2" | grep -o "$1" | wc -l; }

fails=0
ok()   { printf 'ok   %s\n' "$1"; }
bad()  { printf 'FAIL %s\n' "$1"; [ $# -gt 1 ] && printf '     %s\n' "$2"; fails=$((fails+1)); }
eq()   { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "got [$2] want [$3]"; fi; }
has()  { case "$2" in *"$3"*) ok "$1" ;; *) bad "$1" "[$2] does not hold [$3]" ;; esac; }
lacks(){ case "$2" in *"$3"*) bad "$1" "[$2] holds [$3]" ;; *) ok "$1" ;; esac; }

# --------------------------------------------------------------------- shapes on an empty system
echo "== an empty system is all zeroes, not an error =="
out=$(call state '{}')
has "state reports idle" "$out" '"state": "idle"'
has "state says not busy" "$out" '"busy": 0'
has "state says not ringing" "$out" '"ringing": 0'
has "state carries the elapsed field" "$out" '"elapsed": 0'
has "state carries the talking field" "$out" '"talking": 0'
lacks "and no error" "$out" '"error"'

out=$(call dialjob '{}')
has "a dial that never ran says so" "$out" '"none": 1'

out=$(call log '{}')
has "an empty log is an empty list" "$out" '"calls": ['
lacks "and no error" "$out" '"error"'

out=$(call contacts '{}')
has "an empty book is an empty list" "$out" '"contacts": ['
lacks "and no error" "$out" '"error"'

echo
echo "== what the page must not be able to ask for =="
out=$(call dial '{"args":{"num":""}}');        has "an empty number is refused" "$out" 'may only contain digits'
out=$(call dial '{"args":{"num":"12a"}}');     has "a number with a letter is refused" "$out" 'may only contain digits'
out=$(call dial '{"args":{"num":"+"}}');       has "a bare + is refused" "$out" 'may only contain digits'
out=$(call dial '{"args":{"num":"123456789012345678901"}}')
has "an over-long number is refused" "$out" 'may only contain digits'
out=$(call dial '{"args":{"num":"12 34"}}');   has "a number with a space is refused" "$out" 'may only contain digits'
out=$(call dial '{"args":{"num":"1;2"}}');     has "a number with a semicolon is refused" "$out" 'may only contain digits'
out=$(call answer '{}');                       has "answering nothing is refused" "$out" 'no call to answer'
out=$(call hangup '{}');                       has "hanging up nothing is refused" "$out" 'no call to end'
out=$(call dtmf '{"args":{"digits":"1x"}}');   has "tones with a letter outside A-D are refused" "$out" 'Tones may only'
out=$(call dtmf '{"args":{"digits":""}}');     has "empty tones are refused" "$out" 'Tones may only'
out=$(call dtmf '{"args":{"digits":"1"}}');    has "tones with no call up are refused" "$out" 'no call up'
out=$(call mute '{"args":{"on":1}}');          has "a mute flag that is not a boolean is refused" "$out" 'must be true or false'
out=$(call mute '{"args":{"on":true}}');       has "muting nothing is refused" "$out" 'no call to mute'
out=$(call contact_add '{"args":{"num":"12a","name":"x"}}')
has "a contact number with a letter is refused" "$out" 'may only contain digits'
out=$(call contact_add '{"args":{"num":"123","name":""}}')
has "an empty contact name is refused" "$out" 'name is empty'
out=$(call contact_add '{"args":{"num":"123","name":"a|b"}}')
has "a name with the field separator is refused" "$out" 'may not contain |'
out=$(call contact_add "{\"args\":{\"num\":\"123\",\"name\":\"$(printf '%065d' 0 | tr '0' 'x')\"}}")
has "an over-long name is refused" "$out" 'too long'
out=$(call contact_del '{"args":{"num":"12a"}}')
has "deleting a non-numeric number is refused" "$out" 'Bad number'
out=$(call contact_del '{"args":{"num":"999"}}')
has "deleting an unknown number is refused" "$out" 'No contact for that number'
lacks "and none of it reached the modem" "$(cat "$FAKE_AT_DIALED" 2>/dev/null)" 'ATD'

echo
echo "== a broken job install is a failure, not a busy modem =="
# the job's runtime directory cannot even be made (its parent is a file, not a directory): the dial must be
# reported as failed, and the fake AT must never have been asked - a busy channel is one specific thing and
# this is not it
out=$(export CHANGXING60_VOICE_JOB_DIR=$tmp/bin/changxing60-at/data; call dial '{"args":{"num":"123"}}')
has "the dial is refused" "$out" '"error"'
lacks "and not told to the user as a busy channel" "$out" '"busy": 1'
lacks "and still nothing reached the modem" "$(cat "$FAKE_AT_DIALED" 2>/dev/null)" 'ATD'

echo
echo "== one dial at a time, and the claim is what enforces it =="
rm -rf "$tmp/jobroot/job"
if "$JOB" claim; then ok "the first claim is taken"; else bad "the first claim is taken"; fi
if "$JOB" claim 2>/dev/null; then bad "the second claim must not be taken"; else ok "the second claim is refused"; fi
out=$(call dial '{"args":{"num":"123"}}')
has "a dial while the claim is held is refused as busy" "$out" '"busy": 1'
rm -rf "$tmp/jobroot/job"

echo
echo "== a dial is handed off, not run inside the call =="
# the modem takes its time answering ATD; the call must not wait for that (rpcd ends a call at 30s, and a real
# dial can outlast it: the lock alone is held for 10-20s at a time by a data attach)
FAKE_AT_DIAL_DELAY=6; export FAKE_AT_DIAL_DELAY
t0=$(date +%s)
out=$(call dial '{"args":{"num":"+8613800138000"}}')
t1=$(date +%s)
has "the dial reports that it started" "$out" '"started": 1'
if [ $((t1 - t0)) -le 4 ]; then
    ok "the call came back without waiting for the modem ($((t1 - t0))s)"
else
    bad "the call came back without waiting for the modem" "it took $((t1 - t0))s, and the modem takes 6"
fi
out=$(call dialjob '{}')
has "the job is running while the modem is" "$out" '"running": 1'
has "and it knows its limit" "$out" '"limit": 60'
has "the modem was asked to dial" "$(cat "$FAKE_AT_DIALED" 2>/dev/null)" 'ATD+8613800138000;'

# and while the first holds the claim, a second dial is refused rather than queued behind it
out=$(call dial '{"args":{"num":"10086"}}')
has "a second dial at once is refused as busy" "$out" '"busy": 1'
lacks "and the second dial never reached the modem" "$(cat "$FAKE_AT_DIALED" 2>/dev/null)" 'ATD10086'

await_job || bad "the job finished" "it is still reporting running after 40s"
out=$(call dialjob '{}')
has "the job finished" "$out" '"done": 1'
has "and the modem accepted the dial" "$out" '"ok": 1'
has "with the CLI's own word for it" "$out" 'dialling'
# a placed dial is not a connected call: the state file is the daemon's word, and nothing here wrote it
has "the state file is still the only authority on the call" "$(call state '{}')" '"state": "idle"'
unset FAKE_AT_DIAL_DELAY

echo
echo "== a wedged or refusing modem is a visible failure, not an eternal dialing =="
FAKE_AT_DIAL=noresp; export FAKE_AT_DIAL
out=$(call dial '{"args":{"num":"10086"}}')
has "the dial is handed off all the same" "$out" '"started": 1'
await_job || bad "the job finished" "still running after 40s"
out=$(call dialjob '{}')
has "the silent modem is a failure" "$out" '"error": "Dial failed"'
has "with the reason" "$out" 'no final response'
lacks "and not a success" "$out" '"ok": 1'

FAKE_AT_DIAL=ERROR; export FAKE_AT_DIAL
out=$(call dial '{"args":{"num":"10086"}}')
await_job || bad "the job finished" "still running after 40s"
out=$(call dialjob '{}')
has "the modem's ERROR is a failure" "$out" '"error": "Dial failed"'
has "with the modem's own word" "$out" 'not placed: ERROR'
lacks "and not a success" "$out" '"ok": 1'

FAKE_AT_DIAL=busy; export FAKE_AT_DIAL
out=$(call dial '{"args":{"num":"10086"}}')
await_job || bad "the job finished" "still running after 40s"
out=$(call dialjob '{}')
has "a busy channel is passed on as busy" "$out" '"busy": 1'
lacks "and not as a dial that worked" "$out" '"ok": 1'
unset FAKE_AT_DIAL FAKE_AT_DIAL_DELAY

echo
echo "== answering =="
"$VOICE" preview ringing +8613800138000 >/dev/null 2>&1
out=$(call state '{}')
has "the seeded state is ringing" "$out" '"ringing": 1'
FAKE_AT_ANSWER_DELAY=6; export FAKE_AT_ANSWER_DELAY
t0=$(date +%s)
out=$(call answer '{}')
t1=$(date +%s)
has "answer reports that it started" "$out" '"started": 1'
if [ $((t1 - t0)) -le 4 ]; then
    ok "answer came back without waiting for the modem ($((t1 - t0))s)"
else
    bad "answer came back without waiting for the modem" "it took $((t1 - t0))s, and the modem takes 6"
fi
await_in "$FAKE_AT_DIALED" '^ATA$' || bad "the modem was asked to answer" "$(cat "$FAKE_AT_DIALED" 2>/dev/null)"
unset FAKE_AT_ANSWER_DELAY
"$VOICE" preview idle >/dev/null 2>&1
out=$(call answer '{}')
has "answering with no call is refused" "$out" 'no call to answer'

echo
echo "== hanging up =="
"$VOICE" preview active +10086 >/dev/null 2>&1
FAKE_AT_HANGUP_DELAY=6; export FAKE_AT_HANGUP_DELAY
t0=$(date +%s)
out=$(call hangup '{}')
t1=$(date +%s)
has "hangup reports that it started" "$out" '"started": 1'
if [ $((t1 - t0)) -le 4 ]; then
    ok "hangup came back without waiting for the modem ($((t1 - t0))s)"
else
    bad "hangup came back without waiting for the modem" "it took $((t1 - t0))s, and the modem takes 6"
fi
await_in "$FAKE_AT_DIALED" 'AT+CHUP' || bad "the modem was asked to hang up" "$(cat "$FAKE_AT_DIALED" 2>/dev/null)"
unset FAKE_AT_HANGUP_DELAY
"$VOICE" preview idle >/dev/null 2>&1
out=$(call hangup '{}')
has "hanging up with no call is refused" "$out" 'no call to end'

echo
echo "== tones and the microphone, in an active call =="
"$VOICE" preview active +10086 >/dev/null 2>&1
out=$(call dtmf '{"args":{"digits":"12#"}}')
has "tones are handed off" "$out" '"started": 1'
await_in "$FAKE_AT_DIALED" 'AT+VTS="1"' \
    && await_in "$FAKE_AT_DIALED" 'AT+VTS="2"' \
    && await_in "$FAKE_AT_DIALED" 'AT+VTS="#"' \
    || bad "each tone went to the modem one at a time" "$(cat "$FAKE_AT_DIALED" 2>/dev/null)"
out=$(call mute '{"args":{"on":true}}')
has "muting is handed off" "$out" '"started": 1'
await_in "$FAKE_AT_DIALED" 'AT+CMUT=1' || bad "the modem was asked to mute" "$(cat "$FAKE_AT_DIALED" 2>/dev/null)"
out=$(call mute '{"args":{"on":false}}')
has "unmuting is handed off" "$out" '"started": 1'
await_in "$FAKE_AT_DIALED" 'AT+CMUT=0' || bad "the modem was asked to unmute" "$(cat "$FAKE_AT_DIALED" 2>/dev/null)"

echo
echo "== the call log =="
# seeded through the log writer itself, so what the page reads back has been written the way the daemon writes
# it - plus one malformed line, which must cost one row and not the page
. "$LIB"
log_append in  answered +8613800138000 "Home" 65
log_append out missed 10086 "" 0
log_append in  rejected 3333 "" 0
printf 'not a log line\n' >> "$CHANGXING60_VOICE_LOG"
out=$(call log '{}')
has "the log lists the calls" "$out" '"calls"'
eq "three entries, the malformed line dropped" "$(count_in '"epoch"' "$out")" "3"
# newest first: the file is append-only, so the last one appended must be listed first. Compared by position
# in the reply, which is all the order is.
_p3=${out%%3333*}; _p1=${out%%8613800138000*}
if [ "$_p3" != "$out" ] && [ "$_p1" != "$out" ] && [ "${#_p3}" -lt "${#_p1}" ]; then
    ok "the newest call is listed first"
else
    bad "the newest call is listed first" "$out"
fi
out=$(call log '{"args":{"limit":1}}')
has "a limit of one is one" "$out" '"3333"'
lacks "and nothing older" "$out" '8613800138000'
out=$(call log '{"args":{"limit":"abc"}}')
eq "a non-numeric limit falls back to the default, not an error" "$(count_in '"epoch"' "$out")" "3"
out=$(call logclear '{}')
has "the log can be cleared" "$out" '"ok": 1'
out=$(call log '{}')
lacks "and it is empty after" "$out" '"epoch"'

echo
echo "== the contact book =="
out=$(call contact_add '{"args":{"num":"+8613800138000","name":"Home"}}')
has "a contact is added" "$out" '"ok": 1'
out=$(call contact_add '{"args":{"num":"10086","name":"Carrier"}}')
has "a second one is added" "$out" '"ok": 1'
out=$(call contact_add '{"args":{"num":"+8613800138000","name":"Home cell"}}')
has "re-adding a number updates it" "$out" '"ok": 1'
out=$(call contacts '{}')
eq "still two contacts, not three" "$(count_in '"number"' "$out")" "2"
has "under the new name" "$out" 'Home cell'
lacks "and not under the old one" "$out" '"name": "Home"'
out=$(call contact_del '{"args":{"num":"10086"}}')
has "a contact is deleted" "$out" '"ok": 1'
out=$(call contacts '{}')
eq "and one is left" "$(count_in '"number"' "$out")" "1"

echo
echo "== the ACL and menu name exactly the methods the backend implements =="
TAB=$(printf '\t')
backend=$(grep -oE "^${TAB}[a-z_]+: \{" "$PLUGIN" | cut -c2- | sed 's/: {//' | sort)
acl=$(grep -oE '"[a-z_0-9]+"' "$ACL" | tr -d '"' | sort -u | grep -vE '^(description|read|write|ubus|changxing60voice)$')
eq "the ACL grants exactly the backend's methods" "$acl" "$backend"
eq "the backend has twelve methods" "$(printf '%s\n' "$backend" | grep -c .)" "12"
for m in state dial dialjob answer hangup dtmf mute log logclear contacts contact_add contact_del; do
    case "$backend" in *"$m"*) ;; *) bad "the backend implements $m" "not found in the plugin" ;; esac
    grep -q "\"$m\"" "$ACL" || bad "the ACL grants $m" "not found in $ACL"
    # the page's rpc.declare name: snake_case to camelCase (state -> callState, contact_add -> callContactAdd)
    case $m in
        contact_add) rpc=callContactAdd ;;
        contact_del) rpc=callContactDel ;;
        *)           rpc=call$(echo "$m" | cut -c1 | tr 'a-z' 'A-Z')$(echo "$m" | cut -c2-) ;;
    esac
    grep -q "$rpc" "$VIEW" || bad "the view calls $m" "no $rpc in voice.js"
done
grep -q '"path": "changxing60voice/voice"' "$MENU" || bad "the menu points at the page" "$(cat "$MENU")"
grep -q '"acl": \[ "luci-app-changxing60voice" \]' "$MENU" || bad "the menu names the ACL" "$(cat "$MENU")"

echo
if [ "$fails" = 0 ]; then echo "all passed"; else echo "$fails FAILED"; fi
exit $((fails > 0))
