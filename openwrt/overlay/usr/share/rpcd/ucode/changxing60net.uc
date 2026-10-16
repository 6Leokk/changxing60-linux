// The network page's backend: one snapshot of the cellular link, read out of the one collector that
// owns the AT round. The whole method list is two:
//
//   status { fast }   one snapshot; --fast when fast is true (the cheap tier: no engineering
//                     pages, no neighbours -- a refresh that costs the channel less)
//   fast   {}         status with fast forced, for a page that wants the tier always spelled
//
// There is no third method that writes anything, on purpose. The AT surface behind this has exactly
// one safe direction: AT+SPENGMD=0,1,0 would switch the port into streaming mode and leave the
// channel dead until the next reboot, and the band "locks" are write-shaped commands whose readback
// nothing on this family has verified. The collector (changxing60-net-status) reads; this backend
// reads the collector; the page reads this. Nothing in the chain writes to the modem, so no
// session -- however privileged -- can reach a write through this object.
//
// The collector is run by fixed path, never with page-supplied text: the only argument the page can
// influence is fast, and it selects between two argument lists this file spells out itself.
//
// The null discipline is the reason this backend exists at all. The collector guarantees that a
// field the modem did not answer is null, never a fabricated zero, and that a whole round with no
// answer is a top-level "error" plus exit 1 rather than a table of nulls that reads like a snapshot
// of nothing. Preserving both distinctions across this hop is the one thing a naive "parse the JSON
// and hand it on" would get wrong:
//   * its stdout is parsed with json() -- the reply is rebuilt as a ucode value, so a JSON null
//     becomes a real null and stays one all the way to the page. Nothing here reads a field out by
//     hand, re-types it or fills a default in;
//   * exit 1 (the error case) is *not* passed on as the page's own error: the backend answers with
//     { ok: 0, error } and lets the page show the modem's situation, while a backend that itself
//     failed to run the collector (or read a word that is not its JSON) says so in "detail" -- the
//     page can tell "the modem did not answer" from "the collector is broken" and so can we.
//
// A refused round is kept, never summarized: the collector's error text is the one sentence the
// page's user needs (busy channel, dead daemon, deadline), and replacing it with a generic "failed"
// would hide exactly the difference between them.
//
// Every path can be moved for a test (a host-side run has no /opt): CHANGXING60_NET_BIN is the
// collector. The collector has its own seams for its own internals (CHANGXING60_AT_BIN, the sysfs
// root); those are the collector's business and pass through to it untouched. No method takes a path.

'use strict';

import * as fs from 'fs';
import { popen } from 'fs';

const NET = getenv('CHANGXING60_NET_BIN') || '/opt/changxing60/bin/changxing60-net-status';

// q(s): a shell word. Only the collector's own fixed path goes through this, but the helper is
// shared discipline with the other changxing60 backends.
function q(s) {
	return "'" + replace(s, /'/g, "'\\''") + "'";
}

// run(cmd): what it printed on stdout, its diagnostics separately, and how it exited (popen's close
// is the wait status). stdout and stderr are NOT merged here, on purpose: the collector's contract
// is one JSON line on stdout, and a diagnostic on stderr (the AT client's own "busy"/"dead" lines
// pass through the collector's stderr) is not part of that answer. Merging the two put the
// diagnostic in line 1 and threw a good round away; keeping them apart is what makes "take the
// first stdout line" the collector's line rather than a lottery between the two streams. The
// stderr side lands in a file under TMPDIR (writable for rpcd on the device and for a non-root
// host-side run alike; the image's /tmp is root-only, which the SMS backend's checks already know).
function run(cmd) {
	let errf = (getenv('TMPDIR') ?? '/tmp') + '/changxing60net.err';
	let fd = popen("( " + cmd + " ) 2>" + q(errf));
	if (!fd)
		return { out: '', err: '', rc: -1 };
	let out = fd.read('all') ?? '';
	let rc = fd.close();
	return { out: out, err: (fs.readfile(errf) ?? ''), rc: (rc === true || rc === null) ? 0 : rc };
}

// first_line(out): the first line of stdout. The collector's --json form is exactly one line ("one
// JSON line" is its contract, what the header promises the panel), and stdout is where it prints it
// -- a first line that is not the JSON is a foreign program at the path, refused rather than
// guessed at.
function first_line(out) {
	let lines = split(trim(out ?? ''), "\n");
	return length(lines) ? lines[0] : '';
}

// snapshot(fast): one round, as the page's data contract. Returns either
//   { ok: 1, snap: <the collector's JSON, verbatim as a value> }
// or
//   { ok: 0, error: <the collector's own words>, busy: 1 (only when it said so) }
// or, when the collector itself could not be run or did not answer its contract:
//   { error: '...', detail: '...' }
// The three are distinguishable by the page: ok 0 is the modem's situation, error is ours.
function snapshot(fast) {
	// the argument list is spelled out here, not built from anything a caller said
	let args = fast ? ' --fast --json' : ' --json';
	let r = run(q(NET) + args);
	if (r.out == '' && r.rc == -1)
		return { error: 'Could not run the status collector', detail: 'popen failed' };
	let line = first_line(r.out);
	if (r.rc != 0) {
		// exit 1 is the collector's "nothing answered" answer, and its own error message is in the
		// JSON line it printed anyway -- read it from there, the same way the good round is, so the
		// page gets the collector's words rather than this file's paraphrase of them. If that line is
		// missing or not its JSON, then the failure is ours to report.
		let snap = null;
		if (line != '') {
			try { snap = json(line); } catch (e) { }
		}
		if (snap != null && type(snap) == 'object' && snap.error != null)
			return { ok: 0, error: '' + snap.error, busy: snap.busy == 1 ? 1 : 0 };
		return { error: 'The status collector failed', detail: 'exit ' + r.rc + ': ' + trim(r.out) };
	}
	if (line == '')
		return { error: 'The status collector printed nothing' };
	// the good round is exactly ONE stdout line: a second one is not the collector (the fake or a
	// foreign program at the path), and which line is the JSON must never be a guess
	let lines = split(trim(r.out), "\n");
	if (length(lines) > 1)
		return { error: 'The status collector answered with more than its one line', detail: trim(r.out) };
	let snap;
	try {
		snap = json(line);
	} catch (e) {
		return { error: 'The status collector did not answer its contract', detail: e.message ?? e };
	}
	if (snap == null || type(snap) != 'object')
		return { error: 'The status collector did not answer its contract', detail: line };
	// the good round carries no "error" -- the collector's own header guarantees it, and a round that
	// carries one anyway is a half-invented contract, refused rather than shown next to numbers
	if (snap.error != null)
		return { error: 'The status collector answered with an error on a successful round', detail: '' + snap.error };
	return { ok: 1, snap: snap };
}

const methods = {

	status: {
		args: { fast: true },
		call: function (req) {
			let fast = (req.args.fast == true || req.args.fast == 1);
			return snapshot(fast);
		}
	},

	fast: {
		call: function () {
			return snapshot(true);
		}
	}
};

return { changxing60net: methods };
