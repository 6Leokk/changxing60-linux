#!/bin/bash
# Host-side test for changxing60-net-status (rootfs/overlay/opt/changxing60/bin/changxing60-net-status), the
# cell-status snapshot the network panel reads. No modem: the AT channel is tools/net/fake-at, answering from a
# reply script of captured-looking blocks, and the kernel counters come from a staged sysfs tree.
#
# Why this is worth a test. The tool's whole job is to print what the modem said, and the failures that matter
# here are the ones that look like an answer:
#   * a field parsed off the wrong part of an answer (the 2026-10-16 bug: ops.act read off the last quoted
#     group, so the device's own "+COPS: 0,2,\"46000\",11" reported act 46000 -- the PLMN -- instead of 11);
#   * a "not answered" that invents a 0, or a "--fast" that claims "the modem did not report" when the tool
#     never asked (the same bug one level up: a claim about the modem, not about us);
#   * the dash-format SPENGMD decode, whose sign restore and centi-unit division are the parts that turn
#     plausible garbage into plausible numbers.
# Each is pinned by an assertion here, against answers the real device gave (or, for the SPENGMD lines, the
# format the mu collector verified against a live network).
#
#   usage: tools/net/test-status.sh          (exit 0 = all passed)
set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$here/../.."
NET_BIN="$ROOT/rootfs/overlay/opt/changxing60/bin/changxing60-net-status"
[ -f "$NET_BIN" ] || { echo "missing $NET_BIN" >&2; exit 2; }
command -v jq >/dev/null || { echo "jq is needed: the assertions read the tool's JSON" >&2; exit 2; }

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/bin" "$tmp/sys"
fails=0
ok()   { printf 'ok   %s\n' "$1"; }
bad()  { printf 'FAIL %s\n' "$1"; [ $# -gt 1 ] && printf '     %s\n' "$2"; fails=$((fails+1)); }
eq()   { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "got [$2] want [$3]"; fi; }
has()  { case "$2" in *"$3"*) ok "$1" ;; *) bad "$1" "[$2] does not hold [$3]" ;; esac; }
lacks(){ case "$2" in *"$3"*) bad "$1" "[$2] holds [$3]" ;; *) ok "$1" ;; esac; }

# The fake AT client, on PATH and wired through the tool's own seam (CHANGXING60_AT_BIN). Both: the tool
# only looks at the env var, and naming it changxing60-at keeps a human reading the test honest.
cp "$here/fake-at" "$tmp/bin/changxing60-at"
chmod 755 "$tmp/bin/changxing60-at"
export PATH="$tmp/bin:$PATH"
export CHANGXING60_AT_BIN="$tmp/bin/changxing60-at"

# run [ARGS...]: one snapshot. stdout in $out, exit code in $rc. The per-test script is $tmp/script and the
# dialed log $tmp/dialed, both set by the caller before calling.
out=
rc=0
run() {
    out_file=$tmp/out
    "$NET_BIN" "$@" >"$out_file" 2>"$tmp/err"
    rc=$?
    out=$(cat "$out_file")
}
# jget JQPATH: the value at JQPATH of the last snapshot, as text ("null" when null -- which is the
# distinction most of these assertions are about)
jget() { printf '%s' "$out" | jq -r "$1"; }
# jcmp JQPATH EXPECTED_JQ_EXPR: true when the value equals EXPECTED (a jq expression, so strings can be
# written as literals and null as null)
jcmp() { printf '%s' "$out" | jq -e "$1 == ($2)" >/dev/null; }

# write_script: install the reply script the fake reads (content on stdin).
#
# It REPLACES THE BLOCKS IT NAMES, not the whole script. Every caller uses it as "same round, but this
# one command answers differently", and the round's other answers -- above all the registration one --
# have to survive: the tool skips the whole engineering page when it cannot read a registered modem
# (changxing60-net-status:483, REGISTERED comes from +CEREG *or* +C5GREG at 471-473), so a section that
# overrides one SPENGMD block and silences AT+CEREG? on purpose -- to pin the C5GREG fallback -- loses
# its subject the moment the C5GREG block goes away with it. That is what this used to do (plain
# `cat >`), and it made the canonical decode read null for every field: the tool had quietly decided
# the modem was unregistered and never asked. fake-at resolves a repeated "===<cmd>" last-wins, so the
# new blocks are appended and take effect; the old ones are dropped rather than left to grow the file.
write_script() {
    new=$tmp/script.new
    cat > "$new"
    if [ ! -s "$tmp/script" ]; then
        mv "$new" "$tmp/script"
        return 0
    fi
    awk '
        NR == FNR { if ($0 ~ /^===/) drop[substr($0, 4)] = 1; next }
        /^===/    { on = (substr($0, 4) in drop) ? 0 : 1 }
        on
    ' "$new" "$tmp/script" > "$tmp/script.keep"
    cat "$tmp/script.keep" "$new" > "$tmp/script"
    rm -f "$tmp/script.keep" "$new"
}
new_round() { : > "$tmp/dialed"; }

# sys_iface NAME RX TX RXP TXP OPER: stage one interface in the sysfs tree (the tool's
# CHANGXING60_NET_STATUS_SYS root)
sys_iface() {
    d="$tmp/sys/$1"
    mkdir -p "$d/statistics"
    printf '%s\n' "$6" > "$d/operstate"
    for pair in rx_bytes:$2 tx_bytes:$3 rx_packets:$4 tx_packets:$5; do
        printf '%s\n' "${pair#*:}" > "$d/statistics/${pair%%:*}"
    done
}

# --------------------------------------------------------------------- the reply script
# One block per command, headed by the exact command line, in the words the real device answered. The
# SPENGMD lines follow the dash format the mu collector verified against a live network; the values are
# chosen so every derived field has a distinct, non-default number.
registered_script() {
    cat <<'EOF'
===AT+CFUN?
+CFUN: 1
OK
===AT+CEREG?
+CEREG: 2,1,"01F0","0A15D70",7
OK
===AT+C5GREG?
+C5GREG: 2,1,"00A6","C0FFEE123",11
OK
===AT+COPS?
+COPS: 0,2,"46000",11
OK
===AT+CSQ
+CSQ: 25,99
OK
===AT+CESQ
+CESQ: 24,99,55,255,36,98
OK
===AT+SPENGMD=0,6,0
1-361250-211--17832--624-50-3-3-0-0-0-10795375-48764920-DL_CA-0-0-0-0-0-0-0-0-0-0-0-0-0-0-16455
OK
===AT+SPENGMD=0,0,6
0-0-250-0,0,5,2-0,0,1,9-100-20-0
OK
===AT+SPENGMD=0,14,1
78-633984-211--17232--534-0-0-20--10795375--48764920-0-0-0-0-0--250-12-24-120-30
OK
===AT+SPENGMD=0,6,6
1650-112--11520--890-0-0-0-0-0-0-0-0-40350-113--11840--1020-0-0-0-0-0-0-0-0
OK
===AT+SPQ5GNCELLEX
+SPQ5GNCELLEX: 1,633984,211,17232,-534,50,3,20,1,634000,112,-16800,-800,55,0,0,0,0
OK
EOF
}
# The traffic interface the base round reports on.
sys_iface sipa_eth0 1234567890 98765432 50000 40000 up
export CHANGXING60_NET_STATUS_SYS="$tmp/sys"

registered_round() {
    new_round
    registered_script > "$tmp/script"
    export FAKE_AT_SCRIPT="$tmp/script" FAKE_AT_DIALED="$tmp/dialed"
}

# --------------------------------------------------------------------- the full registered round
echo "== a registered round: every command answered =="
registered_round
run --json
eq "the round exits 0" "$rc" "0"
lacks "and reports no error" "$out" '"error"'

# --- the regression: ops.act was read off the last quoted group, so this device's own answer
# ("+COPS: 0,2,\"46000\",11") reported 46000 -- the PLMN -- as the access technology
eq "ops.act is the access technology, not the PLMN (2026-10-16 regression)" "$(jget .ops.act)" "11"
eq "ops.plmn carries the PLMN" "$(jget .ops.plmn)" "46000"
eq "ops.name stays null (a PLMN is not a name)" "$(jget .ops.name)" "null"
eq "reg.stat is home" "$(jget .reg.stat)" "1"
eq "reg.tac keeps its leading zeros as a string" "$(jget .reg.tac)" "01F0"
eq "reg.cid is the 28-bit cell id as a string" "$(jget .reg.cid)" "0A15D70"
eq "reg.act is LTE" "$(jget .reg.act)" "7"
eq "reg5.stat is home" "$(jget .reg5.stat)" "1"
eq "reg5.cid keeps the 36-bit id exact" "$(jget .reg5.cid)" "C0FFEE123"
eq "reg5.act is NR" "$(jget .reg5.act)" "11"
eq "cfun is the radio on" "$(jget .cfun)" "1"

# the engineering reads really were made: the dialed log has them, and eng_skip is null
for c in 'AT+SPENGMD=0,6,0' 'AT+SPENGMD=0,0,6' 'AT+SPENGMD=0,14,1' 'AT+SPENGMD=0,6,6' 'AT+SPQ5GNCELLEX'; do
    has "the round asked $c" "$(cat "$tmp/dialed")" "$c"
done
eq "eng_skip is null when the reads were made" "$(jget .eng_skip)" "null"

# --- the serving cells, from the dash format. Every value here is distinct on purpose: a decode that
# mixed two positions up still produces a plausible-looking number, and only distinct ones tell them apart.
eq "serving.lte.band" "$(jget .serving.lte.band)" "1"
eq "serving.lte.earfcn" "$(jget .serving.lte.earfcn)" "361250"
eq "serving.lte.pci" "$(jget .serving.lte.pci)" "211"
eq "serving.lte.rsrp is centi-units divided by 100" "$(jget .serving.lte.rsrp)" "-178.3"
eq "serving.lte.rsrq" "$(jget .serving.lte.rsrq)" "-6.2"
eq "serving.lte.bw from the bandwidth code 3" "$(jget .serving.lte.bw)" "10M"
eq "serving.lte.enb" "$(jget .serving.lte.enb)" "10795375"
eq "serving.lte.cid" "$(jget .serving.lte.cid)" "48764920"
eq "serving.lte.tac is the fallback field, in hex" "$(jget .serving.lte.tac)" "4047"
eq "serving.lte.bw from the bandwidth code 3" "$(jget .serving.lte.bw)" "10M"
eq "serving.lte.enb" "$(jget .serving.lte.enb)" "10795375"
eq "serving.lte.cid" "$(jget .serving.lte.cid)" "48764920"
eq "serving.lte.tac is the fallback field, in hex" "$(jget .serving.lte.tac)" "4047"
eq "serving.lte.ca" "$(jget .serving.lte.ca)" "DL_CA"
eq "serving.lte.sinr comes from the PHY line" "$(jget .serving.lte.sinr)" "2.5"
eq "serving.lte.ul_mcs is the PHY histogram's peak index" "$(jget .serving.lte.ul_mcs)" "2"
eq "serving.lte.dl_mcs is the other histogram's" "$(jget .serving.lte.dl_mcs)" "3"
eq "serving.lte.ul_bler" "$(jget .serving.lte.ul_bler)" "1.0"
eq "serving.lte.dl_bler" "$(jget .serving.lte.dl_bler)" "0.2"
eq "serving.nr.band" "$(jget .serving.nr.band)" "78"
eq "serving.nr.arfcn" "$(jget .serving.nr.arfcn)" "633984"
eq "serving.nr.pci" "$(jget .serving.nr.pci)" "211"
eq "serving.nr.rsrp" "$(jget .serving.nr.rsrp)" "-172.3"
eq "serving.nr.rsrq" "$(jget .serving.nr.rsrq)" "-5.3"
eq "serving.nr.bw_mhz" "$(jget .serving.nr.bw_mhz)" "20"
eq "serving.nr.sinr" "$(jget .serving.nr.sinr)" "-2.5"
eq "serving.nr.cid is the 2's-complement restored id" "$(jget .serving.nr.cid)" "4246202376"
eq "serving.nr.gnb likewise" "$(jget .serving.nr.gnb)" "4284171921"
eq "serving.nr.ul_mcs" "$(jget .serving.nr.ul_mcs)" "12"
eq "serving.nr.dl_mcs" "$(jget .serving.nr.dl_mcs)" "24"
eq "serving.nr.ul_bler" "$(jget .serving.nr.ul_bler)" "1.2"
eq "serving.nr.dl_bler" "$(jget .serving.nr.dl_bler)" "0.3"

# the quality summary prefers the SPENGMD serving cell
eq "sig.source prefers the NR serving cell" "$(jget .sig.source)" "nr"
eq "sig.rsrp is the NR one" "$(jget .sig.rsrp)" "-172.3"

# --- neighbours: answered with entries
eq "neighbours.lte has both" "$(printf '%s' "$out" | jq '.neighbours.lte | length')" "2"
eq "neighbours.lte[0] pci" "$(jget '.neighbours.lte[0].pci')" "112"
eq "neighbours.lte[0] band comes from the earfcn" "$(jget '.neighbours.lte[0].band')" "3"
eq "neighbours.lte[0] rsrp" "$(jget '.neighbours.lte[0].rsrp')" "-115.2"
eq "neighbours.lte[1] band comes from the other earfcn" "$(jget '.neighbours.lte[1].band')" "41"
eq "neighbours.lte[1] rsrp is a negative restore" "$(jget '.neighbours.lte[1].rsrp')" "-118.4"
eq "neighbours.lte[1] rsrq" "$(jget '.neighbours.lte[1].rsrq')" "-10.2"
eq "neighbours.nr has one" "$(printf '%s' "$out" | jq '.neighbours.nr | length')" "1"
eq "neighbours.nr[0] rsrq is a negative restore" "$(jget '.neighbours.nr[0].rsrq')" "-8.0"
eq "neighbours.nr[0] band" "$(jget '.neighbours.nr[0].band')" "78"
eq "neighbours.nr[0] sinr" "$(jget '.neighbours.nr[0].sinr')" "0.6"

# --- traffic: the kernel counters, read through CHANGXING60_NET_STATUS_SYS
eq "traffic reads the staged sysfs tree" "$(jget .traffic.rx_bytes)" "1234567890"
eq "traffic.tx_bytes" "$(jget .traffic.tx_bytes)" "98765432"
eq "traffic.rx_packets" "$(jget .traffic.rx_packets)" "50000"
eq "traffic.tx_packets" "$(jget .traffic.tx_packets)" "40000"
eq "traffic.present" "$(jget .traffic.present)" "1"
eq "traffic.operstate" "$(jget .traffic.operstate)" "up"
eq "traffic.iface is the default" "$(jget .traffic.iface)" "sipa_eth0"

# ===================================================================== variants

# --------------------------------------------------------------------- the operator answer
echo
echo "== what +COPS may look like, and what each must never become =="
# the name form (format 0): a name and an act
registered_round
write_script <<'EOF'
===AT+COPS?
+COPS: 0,0,"China Mobile",7
OK
EOF
run --json
eq "the name form gives the name" "$(jget .ops.name)" "China Mobile"
eq "the name form gives act 7" "$(jget .ops.act)" "7"
lacks "the name form has no plmn" "$(printf '%s' "$out" | jq '.ops.plmn')" "46000"

# a name that itself carries a comma: the act must still be the field after the quoted run
write_script <<'EOF'
===AT+COPS?
+COPS: 0,0,"China Mobile, Ltd",7
OK
EOF
run --json
eq "a comma inside the quoted name" "$(jget .ops.name)" "China Mobile, Ltd"
eq "... still leaves act 7" "$(jget .ops.act)" "7"

# the numeric form without an act: the PLMN is there, the act is not, and act must stay null --
# it used to hand back the PLMN, which reads as access technology 46000
write_script <<'EOF'
===AT+COPS?
+COPS: 0,2,46000
OK
EOF
run --json
eq "numeric without act: plmn" "$(jget .ops.plmn)" "46000"
eq "numeric without act: act is null, never the PLMN" "$(jget .ops.act)" "null"
eq "numeric without act: name is null" "$(jget .ops.name)" "null"

# the bare form: only the mode. Nothing after it may be invented.
write_script <<'EOF'
===AT+COPS?
+COPS: 0
OK
EOF
run --json
eq "bare form: act is null, never the mode" "$(jget .ops.act)" "null"
eq "bare form: plmn is null" "$(jget .ops.plmn)" "null"
eq "bare form: name is null" "$(jget .ops.name)" "null"

# a nonsense answer: parsed as far as its shape is trusted, which is not far
write_script <<'EOF'
===AT+COPS?
+COPS: what
OK
EOF
run --json
eq "a malformed COPS is nulls" "$(printf '%s' "$out" | jq -c '.ops')" '{"name":null,"plmn":null,"act":null}'

# an unquoted numeric name (format 2, no quotes around the PLMN)
write_script <<'EOF'
===AT+COPS?
+COPS: 0,2,46000,11
OK
EOF
run --json
eq "unquoted numeric form: plmn" "$(jget .ops.plmn)" "46000"
eq "unquoted numeric form: act" "$(jget .ops.act)" "11"

# --------------------------------------------------------------------- a command the modem ignores
echo
echo "== a command the modem does not answer is null, never 0 =="
# The fake can silence a listed command too (FAKE_AT_SILENT_CMDS): the round then shows what one
# unanswered command costs -- nulls for its fields, never zeros, and a summary that falls through
# the tiers the missing readings leave open. The SPENGMD pages are silenced along with CSQ so the
# summary actually reaches the CESQ tier (with serving cells present it never would).
registered_round
FAKE_AT_SILENT_CMDS="AT+CSQ,AT+SPENGMD=0,6,0,AT+SPENGMD=0,0,6,AT+SPENGMD=0,14,1" \
    run --json
eq "the round still succeeds (the modem answered the rest)" "$rc" "0"
lacks "and no error" "$out" '"error"'
eq "csq.rssi is null" "$(jget .csq.rssi)" "null"
eq "csq.ber is null" "$(jget .csq.ber)" "null"
eq "the silenced serving cells are null" "$(jget .serving.nr)" "null"
eq "sig still comes from CESQ, not from a fabricated 0" "$(jget .sig.source)" "cesq"

# CESQ silent instead: its two fields are nulls, and the summary falls to CSQ, the last tier
registered_round
FAKE_AT_SILENT_CMDS="AT+CESQ,AT+SPENGMD=0,6,0,AT+SPENGMD=0,0,6,AT+SPENGMD=0,14,1" \
    run --json
eq "cesq.rsrp is null" "$(jget .cesq.rsrp)" "null"
eq "cesq.rsrq is null" "$(jget .cesq.rsrq)" "null"
eq "sig falls through to CSQ" "$(jget .sig.source)" "csq"
eq "sig.rssi is the CSQ one, not a 0" "$(jget .sig.rssi)" "-63"

# --------------------------------------------------------------------- the operator answer
echo
echo "== what +COPS may look like, and what each must never become =="
# the name form (format 0): a name and an act
registered_round
write_script <<'EOF'
===AT+COPS?
+COPS: 0,0,"China Mobile",7
OK
EOF
run --json
eq "the name form gives the name" "$(jget .ops.name)" "China Mobile"
eq "the name form gives act 7" "$(jget .ops.act)" "7"
lacks "the name form has no plmn" "$(printf '%s' "$out" | jq '.ops.plmn')" "46000"

# a name that itself carries a comma: the act must still be the field after the quoted run
write_script <<'EOF'
===AT+COPS?
+COPS: 0,0,"China Mobile, Ltd",7
OK
EOF
run --json
eq "a comma inside the quoted name" "$(jget .ops.name)" "China Mobile, Ltd"
eq "... still leaves act 7" "$(jget .ops.act)" "7"

# the numeric form without an act: the PLMN is there, the act is not, and act must stay null --
# it used to hand back the PLMN, which reads as access technology 46000
write_script <<'EOF'
===AT+COPS?
+COPS: 0,2,46000
OK
EOF
run --json
eq "numeric without act: plmn" "$(jget .ops.plmn)" "46000"
eq "numeric without act: act is null, never the PLMN" "$(jget .ops.act)" "null"
eq "numeric without act: name is null" "$(jget .ops.name)" "null"

# the bare form: only the mode. Nothing after it may be invented.
write_script <<'EOF'
===AT+COPS?
+COPS: 0
OK
EOF
run --json
eq "bare form: act is null, never the mode" "$(jget .ops.act)" "null"
eq "bare form: plmn is null" "$(jget .ops.plmn)" "null"
eq "bare form: name is null" "$(jget .ops.name)" "null"

# a nonsense answer: parsed as far as its shape is trusted, which is not far
write_script <<'EOF'
===AT+COPS?
+COPS: what
OK
EOF
run --json
eq "a malformed COPS is nulls" "$(printf '%s' "$out" | jq -c '.ops')" '{"name":null,"plmn":null,"act":null}'

# an unquoted numeric name (format 2, no quotes around the PLMN)
write_script <<'EOF'
===AT+COPS?
+COPS: 0,2,46000,11
OK
EOF
run --json
eq "unquoted numeric form: plmn" "$(jget .ops.plmn)" "46000"
eq "unquoted numeric form: act" "$(jget .ops.act)" "11"


# --------------------------------------------------------------------- the fast tier
echo
echo "== --fast does not ask, and says so (2026-10-16 regression) =="
# The old bug: --fast printed "the modem did not report an NR serving cell" when the tool had never
# asked the modem. A claim about the modem, not about us. The JSON must carry eng_skip "fast", and
# the human form must say "not asked".
registered_round
run --fast --json
eq "--fast exits 0" "$rc" "0"
eq "--fast: eng_skip is fast" "$(jget .eng_skip)" "fast"
eq "--fast: serving.lte is null" "$(jget .serving.lte)" "null"
eq "--fast: serving.nr is null" "$(jget .serving.nr)" "null"
eq "--fast: neighbours.lte is null" "$(jget .neighbours.lte)" "null"
eq "--fast: neighbours.nr is null" "$(jget .neighbours.nr)" "null"
# the cheap tier still works: the registration, operator and traffic are all there
eq "--fast: reg still answered" "$(jget .reg.stat)" "1"
eq "--fast: ops.act still answered" "$(jget .ops.act)" "11"
eq "--fast: traffic still answered" "$(jget .traffic.rx_bytes)" "1234567890"
# and the proof that it did not ask: the dialed log has no engineering command at all
if grep -q "SPENGMD" "$tmp/dialed" || grep -q "SPQ5GNCELLEX" "$tmp/dialed"; then
    bad "--fast: no engineering command was sent" "$(grep -E "SP" "$tmp/dialed")"
else
    ok "--fast: no engineering command was sent"
fi
has "--fast: the cheap tier asked the registration" "$(cat "$tmp/dialed")" "AT+CEREG?"

run --fast
has "--fast human: says not asked" "$out" "not asked (--fast)"
lacks "--fast human: does NOT claim the modem reported nothing" "$out" "the modem did not report"

# --------------------------------------------------------------------- not registered
echo
echo "== an unregistered modem: the engineering reads are skipped, and said to be =="
# stat 2 (searching): registered=false, so the engineering reads would be a chain of timeouts.
# Same rule as --fast, different reason -- and eng_skip must name the reason, not imply a modem claim.
registered_round
write_script <<'EOF'
===AT+CFUN?
+CFUN: 1
OK
===AT+CEREG?
+CEREG: 2,2,"0000","00000000"
OK
===AT+C5GREG?
+C5GREG: 2,0
OK
===AT+COPS?
+COPS: 0
OK
===AT+CSQ
+CSQ: 19,99
OK
===AT+CESQ
+CESQ: 0,0,55,255,0,0
OK
EOF
run --json
eq "searching: the round still exits 0" "$rc" "0"
eq "searching: reg.stat is 2" "$(jget .reg.stat)" "2"
eq "searching: eng_skip is unregistered" "$(jget .eng_skip)" "unregistered"
eq "searching: serving.lte is null" "$(jget .serving.lte)" "null"
if grep -q "SPENGMD" "$tmp/dialed"; then
    bad "searching: no engineering command was sent" "$(grep SPENGMD "$tmp/dialed")"
else
    ok "searching: no engineering command was sent"
fi
run
has "searching human: says not asked (not registered)" "$out" "not asked (not registered)"
lacks "searching human: does NOT claim the modem reported nothing" "$out" "the modem did not report"

# stat 0 (not registered, not searching): same skip, same reason
write_script <<'EOF'
===AT+CFUN?
+CFUN: 0
OK
===AT+CEREG?
+CEREG: 2,0
OK
===AT+C5GREG?
+C5GREG: 2,0
OK
===AT+COPS?
+COPS: 0
OK
===AT+CSQ
+CSQ: 99,99
OK
===AT+CESQ
+CESQ: 0,0,55,255,0,0
OK
EOF
run --json
eq "radio off: eng_skip is unregistered" "$(jget .eng_skip)" "unregistered"
eq "radio off: cfun is 0" "$(jget .cfun)" "0"

# --------------------------------------------------------------------- the fast tier
echo
echo "== --fast does not ask, and says so (2026-10-16 regression) =="
# The old bug: --fast printed "the modem did not report an NR serving cell" when the tool had never
# asked the modem. A claim about the modem, not about us. The JSON must carry eng_skip "fast", and
# the human form must say "not asked".
registered_round
run --fast --json
eq "--fast exits 0" "$rc" "0"
eq "--fast: eng_skip is fast" "$(jget .eng_skip)" "fast"
eq "--fast: serving.lte is null" "$(jget .serving.lte)" "null"
eq "--fast: serving.nr is null" "$(jget .serving.nr)" "null"
eq "--fast: neighbours.lte is null" "$(jget .neighbours.lte)" "null"
eq "--fast: neighbours.nr is null" "$(jget .neighbours.nr)" "null"
# the cheap tier still works: the registration, operator and traffic are all there
eq "--fast: reg still answered" "$(jget .reg.stat)" "1"
eq "--fast: ops.act still answered" "$(jget .ops.act)" "11"
eq "--fast: traffic still answered" "$(jget .traffic.rx_bytes)" "1234567890"
# and the proof that it did not ask: the dialed log has no engineering command at all
if grep -q "SPENGMD" "$tmp/dialed" || grep -q "SPQ5GNCELLEX" "$tmp/dialed"; then
    bad "--fast: no engineering command was sent" "$(grep -E "SP" "$tmp/dialed")"
else
    ok "--fast: no engineering command was sent"
fi
has "--fast: the cheap tier asked the registration" "$(cat "$tmp/dialed")" "AT+CEREG?"

run --fast
has "--fast human: says not asked" "$out" "not asked (--fast)"
lacks "--fast human: does NOT claim the modem reported nothing" "$out" "the modem did not report"

# --------------------------------------------------------------------- not registered
echo
echo "== an unregistered modem: the engineering reads are skipped, and said to be =="
# stat 2 (searching): registered=false, so the engineering reads would be a chain of timeouts.
# Same rule as --fast, different reason -- and eng_skip must name the reason, not imply a modem claim.
registered_round
write_script <<'EOF'
===AT+CFUN?
+CFUN: 1
OK
===AT+CEREG?
+CEREG: 2,2,"0000","00000000"
OK
===AT+C5GREG?
+C5GREG: 2,0
OK
===AT+COPS?
+COPS: 0
OK
===AT+CSQ
+CSQ: 19,99
OK
===AT+CESQ
+CESQ: 0,0,55,255,0,0
OK
EOF
run --json
eq "searching: the round still exits 0" "$rc" "0"
eq "searching: reg.stat is 2" "$(jget .reg.stat)" "2"
eq "searching: eng_skip is unregistered" "$(jget .eng_skip)" "unregistered"
eq "searching: serving.lte is null" "$(jget .serving.lte)" "null"
if grep -q "SPENGMD" "$tmp/dialed"; then
    bad "searching: no engineering command was sent" "$(grep SPENGMD "$tmp/dialed")"
else
    ok "searching: no engineering command was sent"
fi
run
has "searching human: says not asked (not registered)" "$out" "not asked (not registered)"
lacks "searching human: does NOT claim the modem reported nothing" "$out" "the modem did not report"

# stat 0 (not registered, not searching): same skip, same reason
write_script <<'EOF'
===AT+CFUN?
+CFUN: 0
OK
===AT+CEREG?
+CEREG: 2,0
OK
===AT+C5GREG?
+C5GREG: 2,0
OK
===AT+COPS?
+COPS: 0
OK
===AT+CSQ
+CSQ: 99,99
OK
===AT+CESQ
+CESQ: 0,0,55,255,0,0
OK
EOF
run --json
eq "radio off: eng_skip is unregistered" "$(jget .eng_skip)" "unregistered"
eq "radio off: cfun is 0" "$(jget .cfun)" "0"

# --------------------------------------------------------------------- nothing answers
echo
echo "== when nothing answers: an error, exit 1, and no invented values =="
# The whole modem is silent: the tool's own rule is a top-level error, never a table of nulls that
# reads like a snapshot of nothing.
registered_round
: > "$tmp/script"
# FAKE_AT_DEFAULT=silent governs the unlisted commands; the script itself is empty so everything is
# unlisted. (An env-prefix assignment on a shell function call would leak into every later test --
# bash keeps the value after the function returns -- so it is exported and unset explicitly.)
FAKE_AT_DEFAULT=silent
export FAKE_AT_DEFAULT
run --json
eq "silent modem: exit 1" "$rc" "1"
eq "silent modem: an error is reported" "$(jget .error)" "AT backend did not answer (radio off, modem restarting, or adapter unavailable)"
eq "silent modem: ts is still a number" "$(printf '%s' "$out" | jq -r '.ts | type')" "number"
: > "$tmp/script"
run
eq "silent modem (human): exit 1" "$rc" "1"
has "silent modem (human): says no answer" "$out" "modem: no answer"
unset FAKE_AT_DEFAULT

# dead daemon: the client's own words say the daemon is not reading commands
registered_round
FAKE_AT_DEAD=1 run --json
eq "dead daemon: exit 1" "$rc" "1"
has "dead daemon: the error says so" "$(jget .error)" "changxing60-atd is not running"

# busy channel: another client holds it the whole round
registered_round
FAKE_AT_BUSY=1 run --json
eq "busy channel: exit 1" "$rc" "1"
has "busy channel: the error names the holder" "$(jget .error)" "busy"
eq "busy channel: the JSON carries busy" "$(jget .busy)" "1"

# a short deadline makes an unanswered modem cost the deadline, not 11 timeouts. The script is
# emptied again -- FAKE_AT_DEFAULT=silent only governs commands the script does not list, and the
# registered script lists them all.
registered_round
: > "$tmp/script"
# FAKE_AT_HANG makes the fake hold every command past the tool's -t: the round can then only end
# at its deadline, which is the branch being tested.
start=$(date +%s)
FAKE_AT_DEFAULT=silent
FAKE_AT_HANG=3
export FAKE_AT_DEFAULT FAKE_AT_HANG
CHANGXING60_NET_STATUS_DEADLINE=2
export CHANGXING60_NET_STATUS_DEADLINE
run --json
unset FAKE_AT_DEFAULT FAKE_AT_HANG CHANGXING60_NET_STATUS_DEADLINE
took=$(( $(date +%s) - start ))
eq "the deadline bounds a silent round (exit 1)" "$rc" "1"
if [ "$took" -le 4 ]; then ok "the round took ${took}s, not 11 timeouts"; else bad "the round took ${took}s"; fi
has "and the error says the deadline" "$(jget .error)" "within the round"

# back to a working modem for the sections below
registered_round
run --json
eq "the registered round answers again" "$rc" "0"

# --------------------------------------------------------------------- unknown arguments
echo
echo "== argument handling =="
registered_round
run --bogus >/dev/null 2>&1
eq "an unknown argument is a usage error (2)" "$rc" "2"
run --json --fast
eq "the flags combine" "$rc" "0"
eq "combined: still fast" "$(jget .eng_skip)" "fast"


# --------------------------------------------------------------------- the canonical decode
echo
echo "== the canonical SPENGMD decode, in the words of the task =="
# "1-300-211--11747--654" = band 1, EARFCN 300, PCI 211, RSRP -117.47, RSRQ -6.54. The minimal line
# the format allows: everything after the fifth field absent. The tool must still decode the five.
registered_round
write_script <<'EOF'
===AT+SPENGMD=0,6,0
1-300-211--11747--654
OK
EOF
# (An env-prefix assignment on a shell function call persists after the call, so the commands to
# silence are exported and unset explicitly -- the same gotcha the other sections already hit.)
FAKE_AT_SILENT_CMDS='AT+SPENGMD=0,14,1,AT+SPENGMD=0,6,6,AT+SPQ5GNCELLEX,AT+CEREG?'
export FAKE_AT_SILENT_CMDS
run --json
unset FAKE_AT_SILENT_CMDS
eq "canonical: band 1" "$(jget .serving.lte.band)" "1"
eq "canonical: EARFCN 300" "$(jget .serving.lte.earfcn)" "300"
eq "canonical: PCI 211" "$(jget .serving.lte.pci)" "211"
eq "canonical: RSRP -117.47 -> -117.5" "$(jget .serving.lte.rsrp)" "-117.5"
eq "canonical: RSRQ -6.54 -> -6.5" "$(jget .serving.lte.rsrq)" "-6.5"

# a negative RSRQ written as --654: the tool normalizes ",-" and "--" before it splits, and the
# sign comes back out of the centi-unit division. (Already asserted above via -6.5; this one pins
# the LTE negative-only RSRQ path.)
registered_round
write_script <<'EOF'
===AT+SPENGMD=0,14,1
78-633984-211--17232--534
OK
EOF
run --json
eq "negative value: NR RSRP from --17232" "$(jget .serving.nr.rsrp)" "-172.3"
eq "negative value: NR RSRQ from --534" "$(jget .serving.nr.rsrq)" "-5.3"

# --------------------------------------------------------------------- traffic edge cases
echo
echo "== traffic edge cases =="
# a different interface name through the seam
registered_round
CHANGXING60_NET_STATUS_IFACE=wwan0 run --json
eq "a missing interface is present 0, not zeroed counters" "$(jget .traffic.present)" "0"
eq "and every counter stays null" "$(jget .traffic.rx_bytes)" "null"

# the sysfs root moved to nothing at all
registered_round
CHANGXING60_NET_STATUS_SYS=/nonexistent run --json
eq "no sysfs at all is the same answer" "$(jget .traffic.present)" "0"
lacks "and still no error" "$out" '"error"'
