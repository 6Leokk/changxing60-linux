#!/bin/sh
# The checks behind tools/sms/test-rpcd.sh: the SMS page's backend (rpcd ucode plugin changxing60sms.uc) and the
# detached sender it drives (changxing60-sms-job), exercised against the fake AT and the real pool CLI.
#
# Nothing here reaches a modem: the AT channel is tools/sms/fake-at, the PDUs come from tools/sms/deliver.py (the
# host side makes them and drops the SIM in /work/sim). What it covers is what a device could not tell us - the
# shape of every reply the page reads, and that a send is handed off and asked after rather than run in the call.
set -u

REPO=${REPO:-/repo}
WORK=${WORK:-/work}
PLUGIN=$REPO/openwrt/overlay/usr/share/rpcd/ucode/changxing60sms.uc
JOB=$REPO/openwrt/overlay/opt/changxing60/bin/changxing60-sms-job
SMS=$REPO/rootfs/overlay/opt/changxing60/bin/changxing60-sms
AWK=$REPO/rootfs/overlay/opt/changxing60/lib/sms-pdu.awk
HARNESS=$REPO/tools/sms/rpcd-harness.uc

for f in "$PLUGIN" "$JOB" "$SMS" "$AWK" "$HARNESS"; do
    [ -e "$f" ] || { echo "missing $f" >&2; exit 2; }
done
[ -e "$WORK/sim" ] || { echo "missing $WORK/sim (test-rpcd.sh makes it)" >&2; exit 2; }

tmp=$WORK/t
rm -rf "$tmp"
mkdir -p "$tmp/bin" "$tmp/atdir" "$tmp/smsrun" "$tmp/jobroot" "$tmp/tmpdir"
cp "$WORK/sim" "$tmp/sim"
# The image's /tmp is root-owned and 0755, which a non-root run cannot write in - and the pool CLI makes its
# temporary files there (mktemp), an environment difference that looks like a broken pool. Give it one it owns.
TMPDIR=$tmp/tmpdir; export TMPDIR

fails=0
ok()   { printf 'ok   %s\n' "$1"; }
bad()  { printf 'FAIL %s\n' "$1"; [ $# -gt 1 ] && printf '     %s\n' "$2"; fails=$((fails+1)); }
eq()   { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "got [$2] want [$3]"; fi; }
has()  { case "$2" in *"$3"*) ok "$1" ;; *) bad "$1" "[$2] does not hold [$3]" ;; esac; }
lacks(){ case "$2" in *"$3"*) bad "$1" "[$2] holds [$3]" ;; *) ok "$1" ;; esac; }

# --------------------------------------------------------------------- the modem side
cp "$REPO/tools/sms/fake-at" "$tmp/bin/changxing60-at"
chmod 755 "$tmp/bin/changxing60-at"
# the pool CLI sleeps fractions of a second, and the image's /bin/sleep rejects those
printf '#!/bin/sh\nexec sleep "$@"\n' > "$tmp/bin/changxing60busybox"
chmod 755 "$tmp/bin/changxing60busybox"
# the CLI refuses to sync or send without the daemon's fifo, which is what it tests for
mkfifo "$tmp/atdir/cmd"

PATH="$tmp/bin:$PATH"; export PATH
CHANGXING60_SMS_BIN=$SMS;              export CHANGXING60_SMS_BIN
CHANGXING60_SMS_POOL=$tmp/pool;        export CHANGXING60_SMS_POOL
CHANGXING60_AT_DIR=$tmp/atdir;         export CHANGXING60_AT_DIR
CHANGXING60_SMS_AWK=$AWK;              export CHANGXING60_SMS_AWK
CHANGXING60_SMS_RUN=$tmp/smsrun;       export CHANGXING60_SMS_RUN
CHANGXING60_BUSYBOX=$tmp/bin/changxing60busybox; export CHANGXING60_BUSYBOX
CHANGXING60_SMS_HOOK=$tmp/no-hook;     export CHANGXING60_SMS_HOOK        # not executable: no hook runs
CHANGXING60_SMS_FORWARD=$tmp/no-forward; export CHANGXING60_SMS_FORWARD
CHANGXING60_SMS_JOB_BIN=$JOB;          export CHANGXING60_SMS_JOB_BIN
CHANGXING60_SMS_JOB_DIR=$tmp/jobroot;  export CHANGXING60_SMS_JOB_DIR
FAKE_AT_SIM=$tmp/sim;            export FAKE_AT_SIM
FAKE_AT_SENT=$tmp/sent;          export FAKE_AT_SENT

# call METHOD [JSON]: the plugin's reply, through the harness (the plugin is a module, so it cannot be run on its
# own, and the arguments go to it as an argument, not on stdin - if they are not passed the method sees {})
call() { ucode "$HARNESS" "$PLUGIN" "$1" "${2:-{\}}"; }
# ids_in OUT: the message ids the list reply carries, in the order it carries them
ids_in() { printf '%s' "$1" | sed 's/"id": "/\n/g' | sed -n 's/^\([0-9]\{1,6\}\)".*/\1/p'; }
# peer_of OUT ID: who a listed message is from, out of the listing itself. Telling the two messages apart by
# reading them would mark both read, and whether reading marks a message read is what the next section tests.
peer_of() { printf '%s' "$1" | sed 's/{ "id": "/\n/g' | sed -n "s/^$2\", \"status\": \"[^\"]*\", \"dir\": \"[^\"]*\", \"peer\": \"\([^\"]*\)\".*/\1/p"; }
pool_count() {
    call list '{"args":{"page":1}}' | sed -n 's/.*"total": \([0-9]*\).*/\1/p'
}
# wait_for COUNT [SECONDS]: until the pool holds that many messages (a sync or a send runs detached)
wait_for() {
    _want=$1; _n=0
    while [ "$_n" -lt "${2:-40}" ]; do
        [ "$(pool_count)" = "$_want" ] && return 0
        _n=$((_n + 1)); sleep 1
    done
    return 1
}

# --------------------------------------------------------------------- reading the pool
echo "== nothing has been sent from here yet =="
out=$(call job '{}')
has "a job that never ran says so" "$out" '"none": 1'

echo
echo "== an empty pool is an empty page, not an error =="
out=$(call list '{"args":{"page":1}}')
has "the counts are there" "$out" '"total": 0'
lacks "and nothing else is claimed" "$out" '"error"'

echo
echo "== sync brings the SIM's messages into the pool =="
out=$(call sync '{}')
has "sync reports that it started (it runs detached)" "$out" '"started": 1'
wait_for 2 40 || bad "the pool took the SIM's messages" "$(call list '{"args":{"page":1}}')"

out=$(call list '{"args":{"page":1}}')
has "the plain message is listed (sender)" "$out" '+8613800138000'
has "the plain message is listed (direction)" "$out" '"dir": "mt"'
has "the long one is listed (sender)" "$out" '10086'
has "the long one is previewed" "$out" 'part one of a long message and part two of i'
has "both are unread" "$out" '"unread": 2'

# the two parts arrived in different SIM slots: the pool must hold them as one message with both halves
ids=$(ids_in "$out")
plain=; long=
for i in $ids; do
    case $(peer_of "$out" "$i") in 10086*) long=$i ;; *) plain=$i ;; esac
done
[ -n "$plain" ] || bad "found the plain message in the listing" "$out"
[ -n "$long" ]  || bad "found the long message in the listing" "$out"

echo
echo "== one message, whole =="
out=$(call show "{\"args\":{\"id\":\"$plain\"}}")
has "show prints the body" "$out" 'Hello from the SIM'
has "and says it is a received one" "$out" 'direction:   received'
# reading it is what marks it read, so the count the page draws from is now one less
has "the unread count went down" "$(call list '{"args":{"page":1}}')" '"unread": 1'
out=$(call show "{\"args\":{\"id\":\"$long\"}}")
has "the long message is whole" "$out" 'part one of a long message and part two of it.'

echo
echo "== what the page must not be able to ask for =="
out=$(call show '{"args":{"id":"abc"}}');      has "a non-numeric id is refused" "$out" '"error": "Bad ID"'
out=$(call show '{"args":{"id":"999999"}}');   has "an id that is not there is refused" "$out" '"error": "Read failed"'
out=$(call list '{"args":{"page":"x"}}');      has "a page that is not a number is refused" "$out" '"error": "Invalid page"'
out=$(call delete '{"args":{"id":"0x1"}}');    has "a non-numeric id is refused" "$out" '"error": "Bad ID"'
out=$(call delete '{"args":{"id":"1","sim":"yes"}}'); has "a sim flag that is not a boolean is refused" "$out" '"error"'

echo
echo "== a message is checked before it is anywhere near the modem =="
out=$(call send '{"args":{"num":"12a","text":"x"}}')
has "a number with a letter in it is refused" "$out" 'may only contain digits'
out=$(call send '{"args":{"num":"10086","text":""}}')
has "an empty message is refused" "$out" 'The message is empty'
big=$(printf '%481s' '' | tr ' ' 'x')
out=$(call send "{\"args\":{\"num\":\"10086\",\"text\":\"$big\"}}")
has "a message over the limit is refused" "$out" 'too long'
out=$(call send '{"args":{"num":"10086","text":"a\u0001b"}}')
has "a control character is refused" "$out" 'control character'
lacks "and none of them reached the AT channel" "$(cat "${FAKE_AT_SENT:-/dev/null}" 2>/dev/null)" '0011'

echo
echo "== a send is handed off, not run inside the call =="
# the modem takes its time answering +CMGS; the call must not wait for that (rpcd ends it at 30 s, and a real
# send can outlast that - a slow one used to be killed with the call, its result lost)
FAKE_AT_SEND_DELAY=6; export FAKE_AT_SEND_DELAY
t0=$(date +%s)
out=$(call send '{"args":{"num":"+8613800138000","text":"hello out there"}}')
t1=$(date +%s)
has "the send reports that it started" "$out" '"started": 1'
if [ $((t1 - t0)) -le 4 ]; then
    ok "the call came back without waiting for the modem ($((t1 - t0))s)"
else
    bad "the call came back without waiting for the modem" "it took $((t1 - t0))s, and the modem takes 6"
fi
out=$(call job '{}')
has "the job is running while the modem is" "$out" '"running": 1'
has "and it knows its limit" "$out" '"limit": 200'

# and while it holds the channel, another send is refused rather than queued behind it
out=$(call send '{"args":{"num":"10086","text":"second"}}')
has "a second send at once is refused as busy" "$out" '"busy": 1'

_n=0
while [ "$_n" -lt 40 ]; do
    out=$(call job '{}'); case "$out" in *'"running": 1'*) _n=$((_n+1)); sleep 1 ;; *) break ;; esac
done
has "the job finished" "$out" '"done": 1'
has "and the modem said so" "$out" '"ok": 1'
sent=$(cat "$FAKE_AT_SENT" 2>/dev/null)
has "the modem was handed a PDU" "$sent" '0011000D91683108108300F0'
wait_for 3 20 || bad "the sent message is in the pool" "$(call list '{"args":{"page":1}}')"
has "the sent message is in the pool" "$(call list '{"args":{"page":1}}')" 'hello out there'
has "and it is marked as ours" "$(call list '{"args":{"page":1}}')" '"dir": "mo"'

echo
echo "== a busy AT channel is not a message sent =="
# the AT client says "busy" in its own words when another client holds the channel; that is not the modem's answer
printf 'changxing60-at: busy\n' > "$tmp/jobroot/job/reply"
out=$(call job '{}')
has "the busy line is passed on as busy" "$out" '"busy": 1'
lacks "and not as a send that worked" "$out" '"ok": 1'
# a job that ended with nothing to say is not a success either - whether the message went out is unknown
printf '' > "$tmp/jobroot/job/reply"
out=$(call job '{}')
has "a job that ended without a result is a failure" "$out" 'ended without a result'
lacks "and not a send that worked" "$out" '"ok": 1'

echo
echo "== one send at a time, and the claim is what enforces it =="
rm -rf "$tmp/jobroot/job"
if "$JOB" claim; then ok "the first claim is taken"; else bad "the first claim is taken"; fi
if "$JOB" claim 2>/dev/null; then bad "the second claim must not be taken"; else ok "the second claim is refused"; fi
out=$(call send '{"args":{"num":"10086","text":"while claimed"}}')
has "and a send while it is held is busy" "$out" '"busy": 1'
rm -rf "$tmp/jobroot/job"

echo
echo "== deleting =="
before=$(pool_count)
out=$(call delete "{\"args\":{\"id\":\"$plain\",\"sim\":false}}")
has "one message is deleted" "$out" '"ok": 1'
eq "the pool has one less" "$(pool_count)" "$((before - 1))"
out=$(call delete '{"args":{"id":"all","sim":true}}')
has "all of them are" "$out" '"ok": 1'
eq "and the pool is empty" "$(pool_count)" "0"
eq "and so is the SIM" "$(grep -c . "$FAKE_AT_SIM" 2>/dev/null; true)" "0"

echo
if [ "$fails" = 0 ]; then echo "all passed"; else echo "$fails FAILED"; fi
exit $((fails > 0))
