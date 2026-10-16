#!/bin/bash
# Syntax-check every script in the repository, with the interpreter its own shebang names.
#
# WHY. On 2026-10-16 openwrt/build-rootfs.sh -- the one script that produces the image the whole
# project ships -- had been unrunnable in HEAD, and had been for some time, without anyone noticing.
# The cause was a single apostrophe in a comment: the file hands a long script to docker inside one
# single-quoted string, so an apostrophe in a comment ends that string early and the rest is parsed as
# shell. It fails at line 74 with
#
#     openwrt/build-rootfs.sh: 74: Syntax error: "(" unexpected
#
# which names a line that is a *comment* and gives no hint that quoting is the problem. The file's own
# header already warned about exactly this trap, in prose -- and the warning did not prevent it,
# because nothing ever ran the file. Prose does not fail a build; this does.
#
# The check is deliberately the cheapest possible one: parse, do not execute. No test data, no device,
# no docker. That is enough for the whole class -- an unbalanced quote, a stray paren, a bash-ism in a
# POSIX script -- and it costs a second, so there is no reason not to run it before every build.
#
#   tools/check-scripts.sh          (exit 0 = every script parses)
#
# Files with no shebang are skipped: a .c file, a .py with no shebang, a fragment meant to be sourced
# -- none of them claim an interpreter, so there is nothing to check them against.
#
# Two checks in here are not parse checks, because the failures they catch parse perfectly well and
# were both found in the wild: check_embedded (the single-quoted docker script in build-rootfs.sh
# truncating silently) and check_views (LuCI view JS using dom/ui/... without the 'require' line,
# which is a runtime ReferenceError in the browser). Those catch whole classes the parse check cannot.
set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$here/.." && pwd)"

pass=0
fail=0

# Interpreter for a file, from its shebang: the first word, and for `env X` the word after it. Returns
# non-zero (and prints nothing) when there is no shebang to go on.
interp() {
    head -c 2 "$1" 2>/dev/null | grep -q '#!' || return 1
    set -- $(head -n1 "$1" 2>/dev/null | sed 's/^#!//')
    case ${1:-} in
        */env) shift; printf '%s\n' "${1:-}" ;;
        *)     printf '%s\n' "${1##*/}" ;;
    esac
}

check() {
    local f=$1 rel=${1#"$ROOT"/} i rc
    i=$(interp "$f") || return 0
    case $i in
        sh|dash|ash)  rc=$(sh -n "$f" 2>&1) ;;
        bash)         rc=$(bash -n "$f" 2>&1) ;;
        python3|python) rc=$(python3 -c 'import sys,py_compile; py_compile.compile(sys.argv[1], doraise=True)' "$f" 2>&1) ;;
        # rc.common scripts are sh fragments behind a wrapper; anything else is not ours to judge
        rc.common|*rc.common) rc=$(sh -n "$f" 2>&1) ;;
        *) return 0 ;;
    esac
    if [ -z "$rc" ]; then
        pass=$((pass + 1))
    else
        fail=$((fail + 1))
        echo "FAIL $rel"
        printf '%s\n' "$rc" | sed 's/^/       /'
    fi
}

# build-rootfs.sh hands a long script to docker inside ONE single-quoted string. Any further single
# quote inside that region -- in code, in a comment, anywhere -- ends the string early. The result is
# NOT a syntax error: the file still parses and the sh -n check above passes it. Instead the docker
# command silently receives a different, shorter script, and the build stops partway while still
# exiting 0. That happened twice. Once in a comment, which made the file unrunnable outright. Once in
# a printf format string, which printed everything up to that line, wrote no tarball, and reported
# EXIT=0 -- a build that looked successful and produced nothing. Parsing cannot see either, so the
# region is checked directly here. Use double quotes inside it.
check_embedded() {
    local f=$ROOT/openwrt/build-rootfs.sh open close bad
    [ -f "$f" ] || return 0
    open=$(grep -n "sh -eu -c '" "$f" | head -1 | cut -d: -f1)
    close=$(grep -n 'ls -la /out/' "$f" | tail -1 | cut -d: -f1)
    if [ -z "$open" ] || [ -z "$close" ]; then
        fail=$((fail + 1)); echo "FAIL openwrt/build-rootfs.sh"
        echo "       cannot locate the embedded docker script delimiters"
        return
    fi
    bad=$(awk -v a="$open" -v b="$close" 'NR>a && NR<b' "$f" | grep -c "'")
    if [ "$bad" -eq 0 ]; then
        pass=$((pass + 1))
    else
        fail=$((fail + 1))
        echo "FAIL openwrt/build-rootfs.sh"
        echo "       $bad single quote(s) inside the single-quoted docker script (lines $open-$close)."
        echo "       Each ends that string early. The file still parses, so this is invisible to the"
        echo "       parse check, but the build truncates there. Use double quotes:"
        awk -v a="$open" -v b="$close" 'NR>a && NR<b && /\047/ {printf "       %d: %s\n", NR, $0}' "$f"
    fi
}

# LuCI view JS: every module-level global must be declared with a 'require' line.
#
# WHY. On 2026-10-16 all three shipped panels -- sms.js, voice.js and fwd.js -- called dom.content(...)
# without ever writing 'require dom'. In LuCI client-side JS none of these names is a global: dom, ui,
# view, rpc, poll, request, fs, uci, network, baseclass are separate modules, and the 'require' line is
# the only thing that puts the name into the scope of that file. The page rendered, then threw
#
#     ReferenceError: dom is not defined
#
# the moment the offending line ran -- which is why the user saw a half-drawn page rather than a broken
# one. Nothing caught it: the files are served straight off disk by uhttpd, so no build step reads them,
# and this script used to prune openwrt/overlay/www outright. The classes it hides a bug in are exactly
# the ones that matter here (E and L are real globals from luci.js; the rest are not).
#
# The check is the same cheap shape as the rest: read the require header, look for `name.` at a token
# boundary, and require a match for every name used. Comment lines are skipped, so prose that happens
# to say "the request." does not trip it.
check_views() {
    local dir=$ROOT/openwrt/overlay/www/luci-static/resources/view f rel req miss g
    [ -d "$dir" ] || return 0
    # E and L are deliberately absent: luci.js defines them as genuine globals.
    local mods="dom ui view rpc baseclass poll request fs uci network session tools firewall"
    while IFS= read -r f; do
        rel=${f#"$ROOT"/}
        # tr, not just sed: the case match below tests for the name surrounded by spaces, so the
        # newlines grep emits as separators have to become the same delimiter. Leaving them as
        # newlines makes every name look absent -- the guard reported all four as missing in files
        # that declared all four, which is the failure mode of a guard that cries wolf.
        req=$(grep -o "'require [a-z]*'" "$f" | sed "s/'require //;s/'//" | tr '\n' ' ')
        miss=
        for g in $mods; do
            grep -vE '^[[:space:]]*(//|/\*|\*)' "$f" \
                | grep -qE "(^|[^A-Za-z0-9_.\$])$g\." || continue
            case " $req " in *" $g "*) ;; *) miss="$miss$g " ;; esac
        done
        if [ -z "$miss" ]; then
            pass=$((pass + 1))
        else
            fail=$((fail + 1))
            echo "FAIL $rel"
            echo "       missing require for: $miss"
            echo "       header declares:     $req"
            echo "       These are separate LuCI modules, not globals. Without the require line the page"
            echo "       throws ReferenceError as soon as that line runs. Add the missing lines, e.g."
            for g in $miss; do echo "           'require $g';"; done
            for g in $miss; do
                echo "       $g:"
                grep -nE "(^|[^A-Za-z0-9_.\$])$g\." "$f" \
                    | grep -vE '^[0-9]+:[[:space:]]*(//|/\*|\*)' | head -3 | sed "s/^/         /"
            done
        fi
    done < <(find "$dir" -name '*.js' -print 2>/dev/null | LC_ALL=C sort)
}

# The same pages, actually executed. The check above only knows the module names on its list; this runs
# the file the way luci.js does (required modules become function parameters) under a stand-in for each,
# and calls every method it exposes. A name that does not exist throws in Node for the same reason it
# throws in the browser, so a typo, or a global from a module nobody listed, is caught too. It found a
# bare `muteBtn` in voice.js -- assigned as this.muteBtn and used as muteBtn six lines later -- that the
# static check could not see, because muteBtn is not the name of any LuCI module.
#
# Skipped, loudly, when node is absent: a check that quietly does not run reads exactly like one that
# passed, which is the failure this whole file exists to stop.
check_views_runtime() {
    local dir=$ROOT/openwrt/overlay/www/luci-static/resources/view out nfiles nfail
    [ -d "$dir" ] || return 0
    if ! command -v node >/dev/null 2>&1; then
        echo "note: node not found -- view JS was not executed (static require check only)"
        return 0
    fi
    nfiles=$(find "$dir" -name '*.js' -print 2>/dev/null | wc -l)
    [ "$nfiles" -gt 0 ] || return 0
    # Run from $ROOT with a relative glob so the failures name files the way the rest of this output does.
    out=$(cd "$ROOT" && node tools/luci-view-check.js openwrt/overlay/www/luci-static/resources/view/*/*.js 2>&1)
    nfail=$(printf '%s\n' "$out" | grep -c '^FAIL ' || true)
    if [ "$nfail" -eq 0 ]; then
        pass=$((pass + nfiles))
    else
        fail=$((fail + nfail))
        pass=$((pass + nfiles - nfail))
        echo "$out" | sed 's/^FAIL /FAIL /'
    fi
}

# Everything that could plausibly be a script. git ls-files would miss the working-tree rename that is
# in flight (the whole point is to check what is on disk, not what is committed), so this walks the
# tree -- minus the heavy or foreign parts.
while IFS= read -r f; do
    check "$f"
done < <(find "$ROOT" \
    -path "$ROOT/.git" -prune -o \
    -path "$ROOT/out" -prune -o \
    -path "$ROOT/work" -prune -o \
    -path "$ROOT/dumps" -prune -o \
    -path "$ROOT/upstream" -prune -o \
    -path "$ROOT/android-vendor" -prune -o \
    -path '*/__pycache__' -prune -o \
    -path '*/node_modules' -prune -o \
    -path "$ROOT/openwrt/overlay/www" -prune -o \
    -type f -print 2>/dev/null | LC_ALL=C sort)

check_embedded
check_views
check_views_runtime

echo
echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ] || exit 1
