// The USB link's mode switch, as the web page sees it.
//
// One object with two methods, because there is one decision to make and one thing to look at:
//
//   status        {}          which mode is in force, what the link is doing, who is on it
//   set           { mode }    manage | share
//
// The mode itself is not stored anywhere of this script's own: it lives in dhcp.lan's options, which is what
// actually decides the behaviour, and changxing60-usb-mode is the one thing that reads and writes it. This file
// runs that script and parses its `state` output rather than touching uci directly, so the page, the terminal
// and the running dnsmasq can never come to three different conclusions about which mode is in force. The whole
// reason the switch is safe in both directions is documented in the script; the short version is that
// 192.168.77.1 stays on-link either way, so nothing here can lock anybody out of the device.
//
// `set` waits. It restarts dnsmasq and odhcpd, which takes a couple of seconds -- far inside rpcd's 30 s call
// limit, and unlike the call page's dials there is no modem to wait 90 s for. A failure is reported as a
// failure: the reply is the state *after* the attempt, read back from the same place the page's status comes
// from, so a page that shows "share" after a refused switch would be showing the device's own answer.

'use strict';

import { popen, readfile } from 'fs';

const USB      = getenv('CHANGXING60_USB_MODE_BIN') || '/opt/changxing60/bin/changxing60-usb-mode';
const LEASES   = getenv('CHANGXING60_USB_LEASES')   || '/tmp/dhcp.leases';
const LAN_PFX  = '192.168.77.';

function q(s) {
	return "'" + replace(s, /'/g, "'\\''") + "'";
}

function run(cmd) {
	let fd = popen("( " + cmd + " ) 2>&1");
	if (!fd)
		return { out: '', rc: -1 };
	let out = fd.read('all') ?? '';
	let rc = fd.close();
	return { out: out, rc: (rc === true || rc === null) ? 0 : rc };
}

function last_line(out) {
	let lines = split(trim(out ?? ''), "\n");
	return length(lines) ? lines[length(lines) - 1] : '';
}

function refuse(msg, detail) {
	return (detail == null || detail == '') ? { error: msg } : { error: msg, detail: '' + detail };
}

// key=value lines, as `changxing60-usb-mode state` prints them. A line with no '=' is dropped: a torn or foreign
// file should read as "not there", not as a field with a strange name.
function fields(text) {
	let r = {};
	for (let line in split(text ?? '', "\n")) {
		let i = index(line, '=');
		if (i <= 0)
			continue;
		r[substr(line, 0, i)] = substr(line, i + 1);
	}
	return r;
}

// The USB link's own clients, out of dnsmasq's lease file: "<expiry> <mac> <ip> <hostname> <clientid>". Only
// the management subnet is listed -- the hotspot's clients are not what this page is about, and a page that
// mixed them would make "who is on the cable" unanswerable at a glance.
function clients() {
	let out = [];
	for (let line in split(readfile(LEASES) ?? '', "\n")) {
		let f = split(trim(line), ' ');
		if (length(f) < 4)
			continue;
		if (substr(f[2], 0, length(LAN_PFX)) != LAN_PFX)
			continue;
		let host = (f[3] == '*' || f[3] == '') ? '' : f[3];
		push(out, { ip: f[2], mac: f[1], hostname: host, expires: +(f[0] ?? 0) });
	}
	return out;
}

function status() {
	let r = run(q(USB) + ' state');
	if (r.rc != 0)
		return refuse('Could not read the USB link state', last_line(r.out));
	let f = fields(r.out);
	let mode = f.mode ?? '';
	if (mode != 'manage' && mode != 'share')
		return refuse('The device is in a mode this page does not know: ' + (mode == '' ? '(none)' : mode));
	return {
		mode:       mode,
		lan_ip:     f.lan_ip ?? '',
		link:       f.link ?? '',
		addr:       f.addr ?? '',
		ra:         f.ra ?? '',
		dhcpv6:     f.dhcpv6 ?? '',
		leasetime:  f.leasetime ?? '',
		dhcp_option: f.dhcp_option ?? '',
		clients:    clients()
	};
}

const methods = {
	status: {
		call: function () {
			return status();
		}
	},

	set: {
		args: { mode: '' },
		call: function (req) {
			let mode = trim('' + (req.args.mode ?? ''));
			if (mode != 'manage' && mode != 'share')
				return refuse('The mode must be manage or share');
			let r = run(q(USB) + ' ' + q(mode));
			if (r.rc != 0)
				return refuse('Could not switch the USB link', last_line(r.out));
			let st = status();
			if (st.error)
				return st;
			// Read back rather than assumed: the script exits 0 after writing uci, and what decides the
			// behaviour is whether dnsmasq and odhcpd came up with it.
			if (st.mode != mode)
				return refuse('The switch did not take: the device still reports ' + st.mode);
			return st;
		}
	}
};

return { changxing60usb: methods };
