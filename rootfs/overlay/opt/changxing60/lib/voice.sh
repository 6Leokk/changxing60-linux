# Shared pieces of the voice control plane: the state file, the call log and the contact book.
#
# Sourced by changxing60-voice (the CLI a person or a page drives) and changxing60-voiced (the daemon that follows the
# modem). Both need the same answer to "what is a call doing", and the screen and the rpcd backend need to read
# it too, so it is one file with one writer rather than three programs each keeping their own idea.
#
#   /run/changxing60-voice/state     what the call is doing right now. Written by changxing60-voiced ALONE.
#   /etc/changxing60/call-log        one line per finished call. Append-only, trimmed in place.
#   /etc/changxing60/contacts        "number|name", one per line, hand-editable.
#
# /run is tmpfs and this device recovers by rebooting, so nothing that has to outlive a boot may live there.
# The state is exactly the opposite: it describes a call that cannot survive a reboot either, and a stale
# "ringing" left in /etc after one would have the panel showing a caller from last week.

VDIR=${CHANGXING60_VOICE_DIR:-/run/changxing60-voice}
VSTATE=$VDIR/state
VNUDGE=$VDIR/nudge            # touched by the CLI: "look now", so a dial shows up without waiting for the poll
VREJECT=$VDIR/rejected        # touched by the CLI when it ends a call that was still ringing (see finalize)
VLOG=${CHANGXING60_VOICE_LOG:-/etc/changxing60/call-log}
VCONTACTS=${CHANGXING60_VOICE_CONTACTS:-/etc/changxing60/contacts}
VLOGMAX=${CHANGXING60_VOICE_LOG_MAX:-500}
ATDIR=${CHANGXING60_AT_DIR:-/run/changxing60-at}
VURCDIR=${CHANGXING60_AT_URC_DIR:-$ATDIR/urc}

# The digits of a number, and nothing else. Every comparison below is on this form: the modem hands back
# "+8613800138000" for a call and "13800138000" for the same contact, and neither is the other.
digits() { printf '%s' "$1" | tr -cd '0-9'; }

# A number as it goes into a log line: every run of five or more digits keeps the two after a + and its last
# two, the rest becomes * (+905321234540 -> +90********40). The panel and the call log keep the real number --
# they exist to show who called -- but syslog does not, and neither does anything this prints.
mask() {
    awk '{
        out = ""
        while (match($0, /\+?[0-9][0-9][0-9][0-9][0-9]+/)) {
            n = substr($0, RSTART, RLENGTH); keep = (substr(n, 1, 1) == "+") ? 3 : 0
            m = substr(n, 1, keep)
            for (i = keep + 1; i <= length(n) - 2; i++) m = m "*"
            out = out substr($0, 1, RSTART - 1) m substr(n, length(n) - 1)
            $0 = substr($0, RSTART + RLENGTH)
        }
        print out $0
    }'
}

# contact_name NUMBER: what the contact book calls it, or nothing.
#
# The exact form is tried first. After that a stored number and the caller are allowed to differ by a country
# code, which is the one difference that is not a different person -- but only when the shorter of the two is
# seven digits or more, because below that "matches" starts meaning "shares an area code".
contact_name() {
    [ -s "$VCONTACTS" ] || return 0
    _q=$(digits "${1:-}")
    [ -n "$_q" ] || return 0
    awk -F'|' -v q="$_q" '
        {
            n = $1; gsub(/[^0-9]/, "", n)
            if (n == "") next
            if (n == q) { print $2; exit }
            if (length(n) >= 7 && length(q) >= 7) {
                if (length(n) > length(q)) {
                    if (substr(n, length(n) - length(q) + 1) == q) { print $2; exit }
                } else if (substr(q, length(q) - length(n) + 1) == n) { print $2; exit }
            }
        }' "$VCONTACTS"
}

# state_read KEY: one field of the state file. Absent file, absent key and empty value all read as empty,
# which is what every caller wants: "no call" is not an error, it is the ordinary case.
state_read() {
    [ -r "$VSTATE" ] || return 0
    sed -n "s/^$1=//p" "$VSTATE" 2>/dev/null | head -1
}

# state_write STATE DIR NUMBER NAME IDX [SINCE] [TALK]
#
# SINCE is when the call appeared (it does not move while the call lasts); TALK is when it was answered, and
# is empty until it is. The two are separate because they answer different questions -- how long it has been
# ringing, and how long the two of you have been talking -- and a call that is held and taken again must not
# restart the second one.
#
# Written to a temporary and renamed, so that a reader -- the panel repaints every two seconds, and the page
# polls -- never sees half a state. The panel is the reason this matters: a torn read there is a caller with
# no number, on a screen whose whole job at that moment is the number.
state_write() {
    mkdir -p "$VDIR" 2>/dev/null
    _tmp=$VSTATE.$$
    {
        printf 'state=%s\n' "$1"
        printf 'dir=%s\n' "$2"
        printf 'number=%s\n' "$3"
        printf 'name=%s\n' "$4"
        printf 'idx=%s\n' "$5"
        printf 'since=%s\n' "${6:-$(date +%s)}"
        printf 'talk=%s\n' "${7:-}"
        printf 'updated=%s\n' "$(date +%s)"
    } > "$_tmp" 2>/dev/null && mv "$_tmp" "$VSTATE" 2>/dev/null
}

# log_append DIR STATUS NUMBER NAME DURATION
#
# DIR is in|out, STATUS is answered|missed|rejected|failed. A call that was never answered still gets a line:
# "who called and I did not pick up" is the question a call log is read to answer.
log_append() {
    mkdir -p "$(dirname "$VLOG")" 2>/dev/null
    printf '%s|%s|%s|%s|%s|%s\n' "$(date +%s)" "$1" "$2" "$3" "$4" "${5:-0}" >> "$VLOG" 2>/dev/null
    # Trim in place, and only once it has grown well past the cap: /etc is on the same flash as everything
    # else, and rewriting the whole file on every single call would be a write amplification nobody asked for.
    _n=$(wc -l < "$VLOG" 2>/dev/null || echo 0)
    if [ "$_n" -gt $((VLOGMAX + 50)) ]; then
        tail -n "$VLOGMAX" "$VLOG" > "$VLOG.tmp" 2>/dev/null && mv "$VLOG.tmp" "$VLOG" 2>/dev/null
    fi
}

# log_lines: the log, newest first, as "<epoch> <dir> <status> <number> <name> <duration>" - the order the
# page and the screen both want, and the only place the field order is decided.
#
# Reversed with awk rather than tac: the rootfs is busybox, and whether this build carries tac is not something
# a call log should depend on. The whole file is a few hundred lines at most (VLOGMAX).
log_lines() {
    [ -s "$VLOG" ] || return 0
    awk -F'|' 'NF >= 5 { printf "%s %s %s %s %s %s\n", $1, $2, $3, $4, $5, $6 }' "$VLOG" |
        awk '{ a[NR] = $0 } END { for (i = NR; i > 0; i--) print a[i] }'
}
