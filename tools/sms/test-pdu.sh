#!/bin/bash
# Host-side checks for the SMS PDU codec (rootfs/overlay/opt/mu300/lib/sms-pdu.awk).
#
# This is the one piece of the SMS stack that can be pinned down without the device, and it is the one
# worth pinning down: a codec that is subtly wrong produces plausible text (the wrong letter, a long
# message with a missing part), and nothing on the device would ever tell us. Incoming messages decode
# on the host against PDUs from tools/sms/deliver.py, which implements the packing independently; the
# outgoing encoder is checked against PDUs spelled out by hand.
#
#   usage: tools/sms/test-pdu.sh          (exit 0 = all passed)
set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AWK_FILE="$here/../../rootfs/overlay/opt/mu300/lib/sms-pdu.awk"
[ -f "$AWK_FILE" ] || { echo "missing $AWK_FILE" >&2; exit 2; }
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
fails=0

ok()   { printf 'ok   %s\n' "$1"; }
bad()  { printf 'FAIL %s\n' "$1"; [ $# -gt 1 ] && printf '     %s\n' "$2"; fails=$((fails+1)); }

# eq WHAT GOT WANT
eq() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "got [$2] want [$3]"; fi; }

# decode PDU [index] -> "sender<TAB>text" (or the full 7-field record with -v full=1)
decode() {
    printf '%s\t%s\n' "${2:-1}" "$1" | awk -v mode=decode -f "$AWK_FILE"
}
field() {  # RECORD N
    printf '%s\n' "$1" | cut -f"$2"
}

echo "== decoding, against tools/sms/deliver.py =="
case_decode() {  # WHAT NUMBER TEXT [ref total part]
    local what=$1 num=$2 txt=$3
    local pdu rec
    if [ $# -ge 6 ]; then
        pdu=$(python3 "$here/deliver.py" "$num" "$txt" "$4" "$5" "$6")
    else
        pdu=$(python3 "$here/deliver.py" "$num" "$txt")
    fi
    [ -n "$pdu" ] || { bad "$what" "deliver.py produced nothing"; return; }
    rec=$(decode "$pdu")
    [ -n "$rec" ] || { bad "$what" "nothing decoded from $pdu"; return; }
    eq "$what (sender)" "$(field "$rec" 2)" "$num"
    eq "$what (text)"   "$(field "$rec" 7)" "$txt"
}

case_decode "ascii"    "+8613800138000" "Hello MU300"
case_decode "digits"   "10086"          "balance: 12.50"
case_decode "punct"    "+15551234567"   'a-b_c.d/e?f!g@h'
case_decode "ext chars" "+8613800138000" 'a euro: € braces: {x}  euro'
case_decode "national" "+8613800138000" 'chars: £¥¤§¿¡ÄÖÑÜäöñü'
case_decode "chinese"  "10690000"       "你好，世界"
case_decode "chinese long" "10690000"   "您的验证码是 123456，五分钟内有效，请勿泄露给他人。"
case_decode "mixed"    "+8613800138000" "order 订单 #42 shipped 已发货"
case_decode "empty"    "+8613800138000" ""
case_decode "one char" "10086"          "x"

echo
echo "== decoding, canonical vectors (independent of both implementations) =="
# 3GPP TS 23.040 Annex: an SMS-DELIVER from +27381000015 reading "hellohello"
rec=$(decode '07917283010010F5040B917283010010F50000426051921420000AE8329BFD4697D9EC37')
eq "spec: sender" "$(field "$rec" 2)" "+27381000015"
eq "spec: text"   "$(field "$rec" 7)" "hellohello"
# a message of its own: no reference, one part
eq "spec: ref"    "$(field "$rec" 4)" ""
eq "spec: total"  "$(field "$rec" 5)" "1"
eq "spec: part"   "$(field "$rec" 6)" "1"

echo
echo "== long messages: the concatenation header =="
p1=$(python3 "$here/deliver.py" "+8613800138000" "first half of the message " 42 2 1)
p2=$(python3 "$here/deliver.py" "+8613800138000" "and the second half here." 42 2 2)
rec1=$(decode "$p1"); rec2=$(decode "$p2")
eq "part 1 (text)" "$(field "$rec1" 7)" "first half of the message "
eq "part 1 (ref/total/part)" "$(field "$rec1" 4)/$(field "$rec1" 5)/$(field "$rec1" 6)" "42/2/1"
eq "part 2 (text)" "$(field "$rec2" 7)" "and the second half here."
eq "part 2 (ref/total/part)" "$(field "$rec2" 4)/$(field "$rec2" 5)/$(field "$rec2" 6)" "42/2/2"

# group mode: the two parts of one message must come back under one key, and a message with no header
# must get a key of its own ("single:N") rather than being joined to anything
g=$( { printf '%s\n' "$rec1"; printf '%s\n' "$rec2"; } | awk -v mode=group -f "$AWK_FILE")
k1=$(field "$g" 8 | sed -n 1p)
k2=$(field "$g" 8 | sed -n 2p)
if [ -n "$k1" ] && [ "$k1" = "$k2" ]; then ok "two parts share one key ($k1)"; else bad "two parts share one key" "[$k1] vs [$k2]"; fi
case "$k1" in multi:*) ok "the key is a multi key" ;; *) bad "the key is a multi key" "$k1" ;; esac

single=$(decode "$(python3 "$here/deliver.py" "10086" "on its own")")
ks=$( { printf '%s\n' "$single"; } | awk -v mode=group -f "$AWK_FILE" | cut -f8)
case "$ks" in single:1) ok "a message of its own gets single:1" ;; *) bad "a message of its own gets single:1" "$ks" ;; esac

# the same reference from one sender, ten minutes apart, is a different message (the window)
p3=$(python3 "$here/deliver.py" "+8613800138000" "later message part one " 42 2 1)
# deliver.py stamps everything at one time; the window is exercised by comparing stamps directly
if awk -v mode=near -v a="2026-10-13 09:41:07" -v b="2026-10-13 09:47:07" -f "$AWK_FILE"; then
    ok "ts_near: within ten minutes"
else
    bad "ts_near: within ten minutes"
fi
if awk -v mode=near -v a="2026-10-13 09:41:07" -v b="2026-10-13 10:05:00" -f "$AWK_FILE"; then
    bad "ts_near: over ten minutes apart"
else
    ok "ts_near: over ten minutes apart"
fi

echo
echo "== encoding (hand-checked PDUs) =="
enc() { awk -v mode=encode -v number="$1" -v text="$2" -f "$AWK_FILE"; }
# SMS-SUBMIT, no service centre (00), 00 for the destination: +8613800138000, GSM alphabet, 4-day validity,
# 11 septets. Spelled out in TS 23.040 9.2.3.
eq "encode ASCII" "$(enc +8613800138000 'Hello MU300')" \
   "25 0011000D91683108108300F00000AA0BC8329BFD0635AB33180C"
# UCS2 is chosen as soon as one character is outside the alphabet; 5 characters, 10 octets
eq "encode chinese" "$(enc 10086 '你好，世界')" \
   "21 00110005810180F60008AA0A4F60597DFF0C4E16754C"
# the extension table: euro, { and } are two septets each (1B first), so 7 characters take 10 septets
eq "encode ext chars" "$(enc 10086 'a€b{c}d')" \
   "20 00110005810180F60000AA0AE14D59BC418D372932"

echo
echo "== USSD (+CUSD, which is characters hex-dumped, not a PDU) =="
# "hello" in the GSM alphabet, one byte per character
eq "ussd gsm7" "$(awk -v mode=ussd -v hex=68656C6C6F -v dcs=0 -f "$AWK_FILE")" "hello"
# 你好 in UCS2 -- dcs bits 3-2 == 10
eq "ussd ucs2" "$(awk -v mode=ussd -v hex=4F60597D -v dcs=8 -f "$AWK_FILE")" "你好"

echo
if [ "$fails" = 0 ]; then echo "all passed"; else echo "$fails FAILED"; fi
exit $((fails > 0))
