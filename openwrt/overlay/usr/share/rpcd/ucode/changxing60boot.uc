// Which system the next reboot lands in, as the web page sees it.
//
// One object with three methods, because there are two decisions and one consequence:
//
//   status        {}            which system is armed, straight from the bootloader-control bytes
//   set           { target }    linux | android
//   reboot        {}            hand the device to whatever is armed, now
//
// Nothing here has its own opinion of the boot state: the entire decision lives in
// /opt/changxing60/bin/changxing60-next-boot, which writes the 32 bytes at misc offset 2048, reads
// them back, and exits 1 if the read-back disagrees. This file runs that script and parses its
// `status` output, so the page, the ssh terminal and the changxing60-post --rearm that runs on
// every successful boot can never come to three different conclusions about what is armed. `set`
// likewise refuses unless the read-back agrees, and hands the *new* status to the page rather
// than a success word.
//
// The asymmetry the page must not paper over: `android` is one-way from inside Linux. Once the
// device reboots into Android there is no web server to come back to, and the documented way
// home is tools/changxing60-back-to-openwrt.sh run from a PC over the USB cable (or the manual
// 32-byte recipe in docs/changxing60/reboot-boot-slot.md), not this page. `linux` only re-arms
// slot b with its try counts -- which a successful boot re-arms every boot anyway -- so pressing
// it is never a surprise.
//
// `reboot` is deliberately its own method instead of an argument to `set`: arming must never
// silently reboot a device somebody is looking through, and a reboot must never happen because
// somebody typo'd a target name.

'use strict';

import { popen } from 'fs';

const NEXTBOOT = getenv('CHANGXING60_NEXTBOOT_BIN') || '/opt/changxing60/bin/changxing60-next-boot';

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

// parse(out): the two lines `changxing60-next-boot status` prints, and nothing else. The slot
// bytes are sliced from the hex the script itself prints (its own `${b:24:2}` / `${b:28:2}`),
// so the page shows the device's bytes, not a second decoder that could drift from the first.
function parse(out) {
	let st = {};
	for (let line in split(trim(out ?? ''), "\n")) {
		line = trim(line);
		if (index(line, 'default boot:') == 0)
			st['target'] = trim(substr(line, 13));
		else if (index(line, 'misc bootloader_control:') == 0) {
			// "misc bootloader_control:" is exactly 24 characters; the value starts at 25.
			// (First build sliced at 22 and shipped `bc` as "l: 5f62..." with the slot bytes
			// shifted by 3 -- caught on the device the first time it was actually called.)
			let bc = trim(substr(line, 25));
			if (length(bc) >= 30) {
				st['bc'] = bc;
				st['slot_a'] = '0x' + substr(bc, 24, 2);
				st['slot_b'] = '0x' + substr(bc, 28, 2);
			}
		}
	}
	return st;
}

function status() {
	let r = run(q(NEXTBOOT) + ' status');
	if (r.rc != 0)
		return refuse('Could not read the boot target', last_line(r.out));
	let st = parse(r.out);
	if (st['target'] != 'linux' && st['target'] != 'android')
		return refuse('The boot target is not one this page knows: ' + (st['target'] ?? '(none)'));
	if (st['bc'] == null)
		return refuse('The boot target script answered without a bootloader-control line');
	return { target: st['target'], bc: st['bc'], slot_a: st['slot_a'], slot_b: st['slot_b'] };
}

const methods = {
	status: {
		call: function () {
			return status();
		}
	},

	set: {
		args: { target: '' },
		call: function (req) {
			let t = trim('' + (req.args.target ?? ''));
			if (t != 'linux' && t != 'android')
				return refuse('The target must be linux or android');
			let r = run(q(NEXTBOOT) + ' ' + q(t));
			if (r.rc != 0)
				return refuse('Could not arm the boot target', last_line(r.out));
			let st = status();
			if (st.error)
				return st;
			// Read back rather than assumed: the script verifies its own write, but what the page
			// must show is what the misc bytes say now, not what the command was supposed to do.
			if (st.target != t)
				return refuse('The arming did not take: the device still reports ' + st.target);
			return st;
		}
	},

	reboot: {
		call: function () {
			// Fire with a one-second fuse: /sbin/reboot would tear rpcd down before it could
			// answer, and a page stuck on a spinner cannot tell "rebooting" from "crashed". The
			// background job's output goes to /dev/null so the popen pipe closes when the shell
			// exits, which is what lets this call return first.
			let r = run('( sleep 1; /sbin/reboot ) >/dev/null 2>&1 &');
			if (r.rc != 0)
				return refuse('Could not start the reboot', last_line(r.out));
			return { ok: true };
		}
	}
};

return { changxing60boot: methods };
