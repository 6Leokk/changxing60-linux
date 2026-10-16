#!/bin/bash
# Host-side test for mobile-data's AT dispatch: which channel it asks, and when it refuses to open one itself.
#
# Why this is worth a test: the attach is the one path whose failure takes the whole box off the network, and it
# just changed shape -- mobile-data no longer opens /dev/stty_nr1 for itself, it asks the changxing60-atd daemon that
# init.d/changxing60-at starts. None of that can be exercised on the device (offline), and the interesting cases are
# exactly the ones an eyeball misses: a daemon that holds the channel while its command fifo is gone, and a
# service that never came up at all.
#
# What it pins down:
#   * a running daemon is preferred over the direct open, and DATA (nr2, mobile-data's own) over MAIN (nr1)
#   * the daemon is chosen through CHANGXING60_AT_DIR, and its reply is passed through unchanged
#   * with no fifo but a live owner on the directory, at refuses instead of becoming a second reader
#   * with neither, at falls back to the old direct open -- and never lets the redirection create a regular
#     file in /dev (the comment on that line is the whole reason it is written the way it is)
#   * at_state() answers "not asked" (2, which vetoes the reboot) rather than opening a channel of its own
#
# It sources mobile-data with the final dispatch case stripped, points the paths at a scratch directory and
# replaces changxing60-at with a stub: no device, no /dev/stty_nr1, no daemon, no reboot.
set -uo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
SRC=$HERE/../../rootfs/overlay/opt/changxing60/bin/mobile-data
T=$(mktemp -d)
trap 'rm -rf "$T"; kill $(jobs -p) 2>/dev/null' EXIT

LIB=$T/lib.sh
sed '/^case "${1:-status}" in/,$d' "$SRC" > "$LIB" || exit 1
[ -s "$LIB" ] || { echo "could not extract the function library from $SRC"; exit 1; }

# --- the world mobile-data talks to ---------------------------------------------------------------
mkdir -p "$T/at" "$T/at2"
cat > "$T/fake-changxing60-at" <<'EOS'
#!/bin/bash
# Stand-in for /opt/changxing60/bin/changxing60-at. Records what it was asked, answers from the environment. FAKE_AT_FAIL
# makes it behave like a daemon that did not answer: changxing60-at exits non-zero and prints nothing.
set -u
T=; [ "${1:-}" = -t ] && { T=$2; shift 2; }
{ printf 'dir=%s\n' "${CHANGXING60_AT_DIR:-}"; printf 'timeout=%s\n' "$T"; printf 'cmd=%s\n' "${1:-}"; } >> "$FAKE_AT_LOG"
[ -z "${FAKE_AT_FAIL:-}" ] || exit 1
printf '%s\n' "${FAKE_AT_REPLY:-OK}"
EOS
chmod +x "$T/fake-changxing60-at"

export CHANGXING60_AT_DIR="$T/at" CHANGXING60_AT_DATA_DIR="$T/at2" CHANGXING60_AT_BIN="$T/fake-changxing60-at" \
       CHANGXING60_AT_DEV="$T/stty_nr1" FAKE_AT_LOG="$T/log"
: > "$FAKE_AT_LOG"

# shellcheck disable=SC1090
. "$LIB"
set +e    # the assertions below deliberately drive the failing paths

# --- harness -------------------------------------------------------------------------------------
pass=0; fail=0
ok() { pass=$((pass + 1)); printf 'ok   %s\n' "$1"; }
no() { fail=$((fail + 1)); printf 'FAIL %s\n' "$1"; }
is() { [ "$2" = "$3" ] && ok "$1" || no "$1 -- got [$2], wanted [$3]"; }
# asked DIR CMD: did the stub see this command against this directory?
asked() { grep -qx "dir=$1" "$FAKE_AT_LOG" && grep -qx "cmd=$2" "$FAKE_AT_LOG"; }
reset_log() { : > "$FAKE_AT_LOG"; }

# --- 1. no daemon at all: the direct open, and nothing created under /dev ------------------------
reset_log; rm -f "$T/at/cmd" "$T/at2/cmd"
out=$(at 'AT+CPIN?' 2>/dev/null); rc=$?
is "no daemon: at says nothing" "$out" ""
is "no daemon: at reports no channel (1)" "$rc" 1
[ -e "$T/stty_nr1" ] && no "no daemon: the redirection created a regular file" || ok "no daemon: nothing created"

# --- 2. main daemon (nr1) only -------------------------------------------------------------------
mkfifo "$T/at/cmd"; reset_log
out=$(at 'AT+CEREG?' 2>/dev/null); rc=$?
is "main daemon: reply passed through" "$out" "OK"
is "main daemon: at returns 0" "$rc" 0
asked "$T/at" 'AT+CEREG?' && ok "main daemon: asked nr1's directory" || no "main daemon: wrong directory"
grep -qx 'timeout=5' "$FAKE_AT_LOG" && ok "main daemon: default timeout is 5 s" || no "main daemon: wrong timeout"
reset_log; at 'AT+CGACT=1,1' 20 >/dev/null 2>&1
grep -qx 'timeout=20' "$FAKE_AT_LOG" && ok "main daemon: an explicit timeout is passed on" || no "main daemon: timeout dropped"

# --- 3. the /etc/changxing60/at-split daemon (nr2) wins when it exists ---------------------------------
mkfifo "$T/at2/cmd"; reset_log
out=$(at 'AT+CGDATA="M-ETHER",1' 45 2>/dev/null); rc=$?
is "split on: reply passed through" "$out" "OK"
asked "$T/at2" 'AT+CGDATA="M-ETHER",1' && ok "split on: the data call is asked on nr2" || no "split on: asked the wrong channel"
rm -f "$T/at2/cmd"

# --- 4. a live owner with no command fifo: refuse, do not become a second reader -----------------
rm -f "$T/at/cmd"; mkdir -p "$T/at/owner"
bash -c 'exec -a changxing60-atd sleep 30' & OWNER=$!
echo "$OWNER" > "$T/at/owner/pid"
sleep 0.2
reset_log
out=$(at 'AT' 2>/dev/null); rc=$?
is "live owner, no fifo: at refuses (1)" "$rc" 1
[ -s "$FAKE_AT_LOG" ] && no "live owner, no fifo: the client was called anyway" || ok "live owner, no fifo: no client call"
kill "$OWNER" 2>/dev/null; wait "$OWNER" 2>/dev/null
rm -rf "$T/at/owner"
[ -e "$T/stty_nr1" ] && no "live owner: the redirection created a regular file" || ok "live owner: nothing created"

# --- 5. at_state: "not asked" is the honest answer when there is nobody to ask -------------------
# link_up returns 0 when the interface still holds an address -- the common wedged case -- and that alone
# vetoes the probe, because with the switch off the data call and the AT channel are one port. 1 = no
# address, which is the only state in which asking is allowed at all.
link_up() { return "${STUB_LINK_UP:-0}"; }   # the real one reads /sys/class/net
rm -f "$T/at/cmd"
STUB_LINK_UP=0 at_state; is "at_state: the call has an address -> 2 (never ask)" "$?" 2
STUB_LINK_UP=1 at_state; is "at_state: no address and no daemon -> 2 (not asked)" "$?" 2
mkfifo "$T/at/cmd"
STUB_LINK_UP=1 FAKE_AT_FAIL=  at_state; is "at_state: an answering daemon -> 0" "$?" 0
STUB_LINK_UP=1 FAKE_AT_FAIL=1 at_state; is "at_state: a silent daemon -> 1" "$?" 1
STUB_LINK_UP=0 FAKE_AT_FAIL=1 at_state; is "at_state: the address vetoes even a silent modem" "$?" 2
rm -f "$T/at/cmd"

# --- 6. own_tty: the termios is ours only while nobody holds the channel -------------------------
own_tty && ok "own_tty: true with no daemon" || no "own_tty: false with no daemon"
mkfifo "$T/at/cmd";  own_tty && no "own_tty: true with the main daemon up" || ok "own_tty: false with the main daemon up"
mkfifo "$T/at2/cmd"; own_tty && no "own_tty: true with the data daemon up" || ok "own_tty: false with the data daemon up"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
