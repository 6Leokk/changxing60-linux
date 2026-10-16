#!/bin/bash
# Host-side smoke test for the SMS pool CLI (rootfs/overlay/opt/mu300/bin/mu300-sms).
#
# The CLI is what the panel reads and what the forwarder is driven by, and most of it never touches a modem:
# it decodes the SIM listing, dedupes by fingerprint, joins the parts of a long message, writes one file per
# message, and runs the hook. All of that runs here against tools/sms/fake-at instead of a tty, so the parts
# that would otherwise only be exercised by sending real SMS can be checked before the device is touched.
#
#   usage: tools/sms/test-cli.sh          (exit 0 = all passed)
set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$here/../.."
SMS_BIN="$ROOT/rootfs/overlay/opt/mu300/bin/mu300-sms"
SMSD_BIN="$ROOT/rootfs/overlay/opt/mu300/bin/mu300-smsd"
FORWARD_BIN="$ROOT/rootfs/overlay/opt/mu300/bin/mu300-sms-forward"
[ -f "$SMS_BIN" ] || { echo "missing $SMS_BIN" >&2; exit 2; }

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
fails=0
ok()  { printf 'ok   %s\n' "$1"; }
bad() { printf 'FAIL %s\n' "$1"; [ $# -gt 1 ] && printf '     %s\n' "$2"; fails=$((fails+1)); }
eq()  { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "got [$2] want [$3]"; fi; }
has() { case "$2" in *"$3"*) ok "$1" ;; *) bad "$1" "[$2] does not hold [$3]" ;; esac; }

# A name on PATH that the CLI calls as mu300-at, plus a busybox shim so its fractional sleeps work on the host
mkdir -p "$tmp/bin"
cp "$here/fake-at" "$tmp/bin/mu300-at"
chmod 755 "$tmp/bin/mu300-at"
printf '#!/bin/sh\nexec sleep "$@"\n' > "$tmp/bin/mu300busybox"
chmod 755 "$tmp/bin/mu300busybox"

export PATH="$tmp/bin:$PATH"
export FAKE_AT_SIM="$tmp/sim" FAKE_AT_SENT="$tmp/sent"
export MU300_SMS_POOL="$tmp/pool"
export MU300_AT_DIR="$tmp/atdir"
export MU300_SMS_AWK="$ROOT/rootfs/overlay/opt/mu300/lib/sms-pdu.awk"
export MU300_SMS_RUN="$tmp/run"
export MU300_SMS_HOOK="$tmp/sms-hook"
export MU300_SMS_FORWARD="$tmp/forward-disabled"
export MU300_BUSYBOX="$tmp/bin/mu300busybox"
mkdir -p "$tmp/atdir" "$tmp/run"
# the CLI insists the daemon is there before it syncs or sends; the fifo is what it tests for
mkfifo "$tmp/atdir/cmd"

sms() { "$SMS_BIN" "$@"; }

# ---------------------------------------------------------------------------
echo "== the pool takes what the SIM holds =="
# one plain message, and a long one whose two parts must be joined back together
p1=$(python3 "$here/deliver.py" "+8613800138000" "Hello from the SIM" )
p2=$(python3 "$here/deliver.py" "10086"           "part one of a long message " 42 2 1)
p3=$(python3 "$here/deliver.py" "10086"           "and part two of it." 42 2 2)
printf '1\t0\t%s\n2\t0\t%s\n3\t0\t%s\n' "$p1" "$p2" "$p3" > "$FAKE_AT_SIM"

sms sync 2>"$tmp/sync.err" || bad "sync" "$(cat "$tmp/sync.err")"
n=$(ls -1 "$MU300_SMS_POOL/msg" 2>/dev/null | grep -cE '^[0-9]+$')
eq "two messages pooled (a two-part one counts once)" "$n" "2"

list=$(sms list)
has "the plain message is listed (sender)" "$list" "+8613800138000"
has "the plain message is listed (text)"   "$list" "Hello from the SIM"
has "the long one is listed (sender)"      "$list" "10086"
# the listing carries a preview, cut to 44 bytes; the whole text is what show is for
has "the long one is previewed"            "$list" "part one of a long message and part two of i"

echo
echo "== reading one back =="
id=$(printf '%s\n' "$list" | sed -n '1s/^\([0-9]*\).*/\1/p')
[ -n "$id" ] || id=1
show=$(sms show "$id")
has "show prints the message body" "$show" "Hello from the SIM"
# the two parts arrived in different SIM slots: the pool must hold them as one message with both halves
mid=$(printf '%s\n' "$list" | sed -n '/10086/p' | sed -n '1s/^\([0-9]*\).*/\1/p')
[ -n "$mid" ] || bad "found the long message in the listing"
showlong=$(sms show "$mid")
has "the long message is whole" "$showlong" "part one of a long message and part two of it."

echo
echo "== a sync that changes nothing writes nothing =="
before=$(find "$MU300_SMS_POOL" -type f -newermt '1970-01-01' -printf '%p %T@\n' | sort)
sleep 1
sms sync 2>/dev/null
after=$(find "$MU300_SMS_POOL" -type f -newermt '1970-01-01' -printf '%p %T@\n' | sort)
eq "no file was rewritten by an unchanged sync" "$after" "$before"

echo
echo "== the SIM is where a message is safe until the pool has it =="
left=$(grep -c . "$FAKE_AT_SIM")
eq "the pooled messages were removed from the SIM" "$left" "0"

echo
echo "== a directly delivered message (+CMT) is pooled, and the hook runs =="
cat > "$MU300_SMS_HOOK" <<'EOF'
#!/bin/sh
printf '%s|%s|%s\n' "$SMS_FROM" "$SMS_ID" "$SMS_TEXT" >> "$SMS_HOOK_LOG"
EOF
chmod 755 "$MU300_SMS_HOOK"
export SMS_HOOK_LOG="$tmp/hook.log"
p4=$(python3 "$here/deliver.py" "+447700900123" "delivered straight to us")
printf '%s\n' "$p4" > "$tmp/cmt.ready"
sms import-pdu "$tmp/cmt.ready" || bad "import-pdu" "$(sms import-pdu "$tmp/cmt.ready" 2>&1)"
list=$(sms list)
has "the direct message is in the pool" "$list" "delivered straight to us"
# the hook is the documented way to react to a message (forwarding to a phone, a webhook, bark); it runs in the
# background, so give it a moment
for _ in 1 2 3 4 5 6 7 8 9 10; do [ -s "${SMS_HOOK_LOG:-/nonexistent}" ] && break; sleep 0.3; done
hook=$(cat "${SMS_HOOK_LOG:-/dev/null}" 2>/dev/null)
has "the hook was run (sender)" "$hook" "+447700900123"
has "the hook was given the text" "$hook" "delivered straight to us"

echo
echo "== sending =="
sms send +8613800138000 "hello out there" >"$tmp/send.out" 2>"$tmp/send.err" || bad "send" "$(cat "$tmp/send.err")"
has "send reports a reference" "$(cat "$tmp/send.out")" "sent (reference 1)"
sent=$(cat "$FAKE_AT_SENT" 2>/dev/null)
has "the modem was handed a PDU" "$sent" "0011000D91683108108300F0"
# and the sent message is kept in the pool, marked as ours
list=$(sms list)
has "the sent message is in the pool" "$list" "hello out there"

echo
if [ "$fails" = 0 ]; then echo "all passed"; else echo "$fails FAILED"; fi
exit $((fails > 0))
