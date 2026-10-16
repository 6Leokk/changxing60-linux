#!/bin/bash
# Run tools/win/usb-share.ps1 on the Windows side, from here.
#
#   tools/win/usb-share.sh            show where the PC's traffic goes
#   tools/win/usb-share.sh --renew    renew the USB adapter's lease first
#   tools/win/usb-share.sh --test     and prove the path with a tracert
#
# The .ps1 cannot be run by path: it lives in the WSL filesystem, and Windows PowerShell is a Windows process.
# It is *read* and handed over, not copied, so there is no second copy to go stale.
#
# -EncodedCommand, not `-Command -`. Two reasons, both measured:
#   * `-Command -` does not accept arguments after it at all ("-Command 后面不能跟任何参数"), and it runs the
#     stream line by line -- so a variable assigned on one line is gone by the next, which is how the switch
#     flags reach the script.
#   * -EncodedCommand takes the whole text as one base64 UTF-16LE string, i.e. as a single script block. That
#     also sidesteps every quoting question a path with a space in it would raise.
set -euo pipefail
here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
PS=/mnt/c/Windows/System32/WindowsPowerShell/v1.0/powershell.exe

[ -x "$PS" ] || { echo "no Windows PowerShell at $PS -- is /mnt/c mounted?" >&2; exit 1; }

sw=()
for a in "$@"; do
	case "$a" in
	--renew|-Renew) sw+=('-Renew') ;;
	--test|-Test)   sw+=('-Test') ;;
	*) echo "usage: usb-share.sh [--renew] [--test]" >&2; exit 2 ;;
	esac
done

# A PowerShell array literal for the preamble, e.g. '-Renew','-Test'
list=
for s in ${sw[@]+"${sw[@]}"}; do list="$list'$s',"; done
list=${list%,}

tmp=$(mktemp)
trap 'rm -f "$tmp"' EXIT
{
	printf '$args = @($args) + @(%s)\n' "$list"
	cat "$here/usb-share.ps1"
} > "$tmp"

exec "$PS" -NoProfile -ExecutionPolicy Bypass -EncodedCommand \
	"$(iconv -f UTF-8 -t UTF-16LE < "$tmp" | base64 -w0)"
