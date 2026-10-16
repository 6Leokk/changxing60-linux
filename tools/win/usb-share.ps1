# Make the PC on the far end of the USB cable pick up a mode change now instead of when its lease expires.
#
#   powershell -NoProfile -ExecutionPolicy Bypass -Command - < tools/win/usb-share.ps1
#   ... | powershell ... -Renew     renew the USB adapter's lease (what a mode switch needs)
#   ... | powershell ... -Test      prove where the PC's traffic is actually going
#
# Why this has to exist at all. The mode lives in this device's dhcp.lan options (see
# /opt/changxing60/bin/changxing60-usb-mode), and DHCP has no server-initiated renew that Windows honours --
# RFC 3203's FORCE_RENEW is ignored unless the message is authenticated. So switching the mode on the device
# changes what the *next* lease will say and nothing about the one in force. Share mode uses a 5-minute lease
# so both directions converge within about two minutes by themselves; this is for when that is too slow.
#
# The two things worth looking at, in order:
#
#   * Which adapter holds the PC's default route. In manage mode it must NOT be the USB one. If it is, the
#     PC's traffic is being routed into this phone -- measured 2026-10-13, the UsbNcm route (metric 25)
#     outranked the machine's real Wi-Fi uplink (metric 30), and nothing else showed it.
#   * The USB adapter's own metric. Windows gives every adapter a metric by default (25 for a 100 Mbps-class
#     link); a lower one wins. `-Test` asks the device itself which way the packet went.

# Switches are read out of $args rather than declared with param(), because the wrapper on the WSL side feeds
# this file to powershell.exe through -EncodedCommand, where a param() block cannot be first in the stream.
# `powershell -File usb-share.ps1 -Renew` sets $args the same way, so both ways in work.
$Renew = ($args -contains '-Renew') -or ($args -contains '--renew')
$Test  = ($args -contains '-Test')  -or ($args -contains '--test')

$ErrorActionPreference = 'SilentlyContinue'
# The adapter names on this machine are Chinese ("以太网 54"), and the console codepage under -EncodedCommand is
# GBK: without this, every name and every message comes back as mojibake in the WSL terminal. Progress records
# go to stderr as CLIXML when PowerShell is driven this way, which is noise rather than output.
$ProgressPreference = 'SilentlyContinue'
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch {}
$LAN = '192.168.77.'

# The USB gadget is a composite Linux Foundation device; its network function comes up as an NCM adapter whose
# description carries the device's product string ("changxing60 Linux USB Ethernet"). Matching on the address
# it holds is the reliable half: no other adapter of this machine is on the management subnet.
function Get-UsbAdapter {
    $a = Get-NetAdapter | Where-Object { $_.InterfaceDescription -match 'NCM|CDC|RNDIS|changxing60' }
    if ($a) { return $a }
    $ip = Get-NetIPAddress -AddressFamily IPv4 | Where-Object { $_.IPAddress -like "$LAN*" }
    if ($ip) { return Get-NetAdapter -InterfaceIndex $ip[0].InterfaceIndex }
    return $null
}

function Show-State {
    $usb = Get-UsbAdapter

    "=== the USB adapter ==="
    if (-not $usb) {
        "  none: no adapter is on $LAN" + "0/24 -- is the cable in, and is the device in OpenWrt?"
    } else {
        $usb | Select-Object Name, InterfaceDescription, Status, LinkSpeed, ifIndex, MacAddress |
            Format-Table -AutoSize | Out-String -Width 200
        Get-NetIPAddress -AddressFamily IPv4 -InterfaceIndex $usb.ifIndex |
            Select-Object IPAddress, PrefixLength, PrefixOrigin, SuffixOrigin |
            Format-Table -AutoSize | Out-String -Width 200
    }

    "=== IPv4 default routes, lowest metric first (the top one is where traffic goes) ==="
    Get-NetRoute -DestinationPrefix '0.0.0.0/0' |
        Sort-Object RouteMetric, ifIndex |
        Select-Object ifIndex, InterfaceAlias, NextHop, RouteMetric,
            @{n='IsUSB';e={ if ($usb -and $_.ifIndex -eq $usb.ifIndex) { 'YES' } else { '' } }} |
        Format-Table -AutoSize | Out-String -Width 200

    $usbDefault = $null
    if ($usb) {
        $usbDefault = Get-NetRoute -DestinationPrefix '0.0.0.0/0' -InterfaceIndex $usb.ifIndex
    }
    if ($usbDefault) {
        "  -> the USB link HOLDS a default route: this PC is routing through the device (share mode)"
    } elseif ($usb) {
        "  -> the USB link holds no default route: this PC keeps its own uplink (manage mode)"
    }

    "=== is the management link itself reachable ==="
    # A TCP connect, not an HTTP GET: LuCI answers a request with no session with 403, and 403 is a *success*
    # here -- it proves the device's web server is listening on the address. What is being tested is the cable,
    # not the login.
    foreach ($port in 22, 80) {
        $c = New-Object System.Net.Sockets.TcpClient
        $ok = $false
        try {
            $t = $c.BeginConnect('192.168.77.1', $port, $null, $null)
            $ok = $t.AsyncWaitHandle.WaitOne(2000) -and $c.Connected
        } catch {}
        $c.Close()
        if ($ok) { "  192.168.77.1:$port  open" } else { "  192.168.77.1:$port  no answer" }
    }
}

function Renew-Usb {
    $usb = Get-UsbAdapter
    if (-not $usb) { "no USB adapter to renew"; return }

    # release + renew, NOT renew alone. Measured on this machine 2026-10-16: after switching the device back
    # to manage, a plain `ipconfig /renew` left the adapter's default route in place -- Windows keeps a
    # gateway it already has, and an empty option 3 in a renewal does not take it away. The switch *to* share
    # mode is the easy direction (a renewal adds the gateway fine); going back is the one that needs this.
    # release drops the lease and with it the route, and the renew re-acquires the address -- the same
    # 192.168.77.199 in the measurement.
    #
    # The address is checked afterwards rather than assumed: with no address there is no route to
    # 192.168.77.0/24 either, so the management link -- and ssh to the device -- would be gone until the
    # cable is re-plugged. That has never happened here, but it is the one outcome worth saying out loud.
    "=== ipconfig /release + /renew `"$($usb.Name)`" ==="
    & ipconfig.exe /release $usb.Name | Out-Null
    Start-Sleep -Seconds 2
    & ipconfig.exe /renew $usb.Name | Out-Null
    Start-Sleep -Seconds 3

    $back = Get-NetIPAddress -AddressFamily IPv4 -InterfaceIndex $usb.ifIndex |
        Where-Object { $_.IPAddress -like "$LAN*" }
    if (-not $back) {
        "  !! the USB adapter came back with no $LAN" + "x address."
        "     The device is fine; this PC just has no lease. Re-plug the cable, or run the renew again."
    }
}

if ($Renew) { Renew-Usb }
Show-State

if ($Test) {
    "=== where does a packet actually go? ==="
    # tracert's first hop is the answer: 192.168.77.1 means the PC is routing through the device.
    $t = & tracert.exe -d -h 1 -w 1000 223.5.5.5 2>&1
    $t | Select-Object -First 6
    "=== can this PC reach the internet at all ==="
    $ok = Test-NetConnection 223.5.5.5 -InformationLevel Quiet
    if ($ok) { "  yes: 223.5.5.5 answers" } else { "  no: 223.5.5.5 does not answer" }
}
