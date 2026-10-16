// The SMS page's backend: every method the page calls, and nothing else.
//
// It is not upstream's mu300dash. That one is 40+ methods over the whole box (signal, traffic, VPN, terminal, the
// operations log), it needs its own lib.sh for JSON escaping and allow-lists, and it prints its replies a whole
// page at a time; we have no dashboard to drive, so the page here talks to this instead. What the two share is
// the pool: mu300-sms owns it, mu300-smsd fills it, and this only reads and asks it to send.
//
//   list    { page }         one page of the pool, newest first
//   show    { id }           the whole message (a received one is marked read)
//   send    { num, text }    submit one, detached (see below); the page asks job for how it went
//   job     {}               that send: running, or what mu300-sms said
//   sync    {}               move the SIM's messages into the pool, detached (CMGL walks the SIM)
//   delete  { id, sim }      delete one, or all
//
// A send cannot be answered inside one call. mu300-sms waits for the modem's +CMGS and its whole transaction can
// take longer than rpcd allows a call (rpcd ends a call at 30 s; mu300-at's lock wait alone is 90 s), so the
// send is handed to /opt/mu300/bin/mu300-sms-job, which runs it detached and writes how it went into a runtime
// directory; job reads that. Without this a slow send was killed with the call, its result lost, and the message
// had gone out - or not - behind the page's back.
//
// Every path below can be moved for a test (a host-side run has no modem): MU300_SMS_BIN is the pool CLI,
// MU300_SMS_JOB_BIN the detached sender, MU300_SMS_JOB_DIR the runtime directory the two of us share. Note that
// MU300_SMS_RUN is not one of them: that one is mu300-sms's own runtime directory, and taking its name here
// would mean two different things by it. Nothing outside the pool and that directory is touched, and no method
// takes a path.

'use strict';

import { popen, writefile } from 'fs';

const SMS     = getenv('MU300_SMS_BIN') || '/opt/mu300/bin/mu300-sms';
const JOBRUN  = getenv('MU300_SMS_JOB_BIN') || '/opt/mu300/bin/mu300-sms-job';
const ROOT    = getenv('MU300_SMS_JOB_DIR') || '/var/run/mu300sms';
const JOBDIR  = ROOT + '/job';
const MAXCH   = 480;                 // the text the page may submit, in characters
const ID_RE   = /^[0-9]{1,6}$/;      // mu300-sms numbers a message 1..999999
const AT_BUSY = /(^|\n)(mu300|unisoc)-at: busy\n?$/s;

// A shell word: single-quoted, with any single quote in it closed, escaped and reopened. Every value that
// reaches a command line goes through this, and the ones that matter are checked against a pattern first.
function q(s) {
	return "'" + replace(s, /'/g, "'\\''") + "'";
}

// run(cmd): everything it printed, its errors mixed in, and how it exited (popen's close is the wait status).
function run(cmd) {
	let fd = popen("( " + cmd + " ) 2>&1");
	if (!fd)
		return { out: '', rc: -1 };
	let out = fd.read('all') ?? '';
	let rc = fd.close();
	return { out: out, rc: (rc === true || rc === null) ? 0 : rc };
}

// detach(cmd): start it and do not wait. setsid takes it out of rpcd's process group, and its output is thrown
// away - the pipe has to go, or reading it would wait for the child (the whole point is not to wait).
function detach(cmd) {
	let fd = popen('setsid ' + cmd + ' >/dev/null 2>&1 &');
	if (fd) {
		fd.read('all');
		fd.close();
	}
}

// last_line(out): the line an error is reported from - mu300-sms and mu300-at say what went wrong last
function last_line(out) {
	let lines = split(trim(out ?? ''), "\n");
	return length(lines) ? lines[length(lines) - 1] : '';
}

// num(s, fallback): a number from the strings a reply is split into, or the fallback when it is not one
function num(s, fallback) {
	let n = +(s ?? '');
	return (type(n) == 'int' && n == n) ? n : fallback;
}

function refuse(msg, detail) {
	return (detail == null || detail == '') ? { error: msg } : { error: msg, detail: '' + detail };
}

// chars(s): its length in characters - a UTF-8 continuation byte is not one (a Chinese message is 3 bytes a
// character, and the limit is the user's characters, not the modem's bytes)
function chars(s) {
	return length(replace(s, /[\x80-\xbf]+/g, ''));
}

// text_ok(s): nothing but printable text, a tab and a newline. A control character is not something a page can
// mean to send, and the modem reads some of them as the end of the message.
function text_ok(s) {
	return length(replace(s, /[\t\n\x20-\x7e\x80-\xff]+/g, '')) == 0;
}

// verdict(out): how mu300-sms's reply reads. A busy channel is the AT client's own line, not the modem's word;
// success is its last line saying so ("sent ...", or a bare OK), never those words somewhere in a refusal.
function verdict(out) {
	if (match(out, AT_BUSY))
		return { ok: 0, busy: 1, error: 'The AT channel is busy; the command was not sent, try again' };
	let last = last_line(out);
	if (last == 'sent' || match(last, /^sent /) || last == 'OK')
		return { ok: 1, reply: trim(out) };
	return refuse('Sending failed', last);
}

// pool_page(out, page): what mu300-sms list printed. Its first line is the count, then one fixed-width row per
// message (see its cmd_list): id, status, direction, peer, time, preview - seven, seven, three, eighteen,
// twenty-one columns, one space between each, the preview taking the rest of the line.
function pool_page(out, page) {
	let r = { total: 0, unread: 0, page: page, pages: 1, msgs: [] };
	for (let line in split(trim(out), "\n")) {
		if (line == '')
			continue;
		let m = match(line, /^pool: ([0-9]+) message\(s\), ([0-9]+) unread - page ([0-9]+)\/([0-9]+) /);
		if (m) {
			r.total = +m[1]; r.unread = +m[2]; r.page = +m[3]; r.pages = +m[4];
			continue;
		}
		// a row whose id does not read as one is not a row (a wrapped preview would land here, and be dropped)
		let id = trim(substr(line, 0, 7));
		if (!match(id, ID_RE))
			continue;
		push(r.msgs, {
			id: id,
			status: trim(substr(line, 8, 7)),
			dir: trim(substr(line, 16, 3)),
			peer: trim(substr(line, 20, 18)),
			time: trim(substr(line, 39, 21)),
			preview: substr(line, 61)
		});
	}
	return r;
}

const methods = {
	list: {
		args: { page: 0 },
		call: function (req) {
			let page = trim('' + (req.args.page ?? 1));
			if (!match(page, /^[0-9]{1,6}$/))
				return refuse('Invalid page');
			let r = run(q(SMS) + ' list ' + page);
			if (trim(r.out) == '')
				return refuse('mu300-sms is not available (the SMS service is not installed or not running)');
			return pool_page(r.out, +page);
		}
	},

	show: {
		args: { id: '' },
		call: function (req) {
			let id = trim('' + (req.args.id ?? ''));
			if (!match(id, ID_RE))
				return refuse('Bad ID');
			// this is also what marks a received message read - the pool file is the state, there is no flag to set
			let r = run(q(SMS) + ' show ' + q(id));
			if (r.rc != 0 || trim(r.out) == '')
				return refuse('Read failed', last_line(r.out));
			return { ok: 1, text: r.out };
		}
	},

	send: {
		args: { num: '', text: '' },
		call: function (req) {
			let num = trim('' + (req.args.num ?? ''));
			let text = '' + (req.args.text ?? '');
			if (!match(num, /^\+?[0-9]{1,20}$/))
				return refuse('The number may only contain digits (and a leading +)');
			if (text == '')
				return refuse('The message is empty');
			if (chars(text) > MAXCH)
				return refuse(sprintf('The message is too long (over %d characters)', MAXCH));
			if (!text_ok(text))
				return refuse('The message contains a control character');
			// the claim first, so that two sends at once cannot write into one job directory, and nothing is
			// written down before we hold it
			let c = run(q(JOBRUN) + ' claim');
			if (c.rc != 0)
				return { ok: 0, busy: 1, job: 1, error: 'The AT channel is busy; the command was not sent, try again' };
			// no mode argument: writefile's third is a byte limit, not a permission (0o600 would cut the text to
			// 384 bytes, and a 480-character message would go out truncated). The job directory is 0700, which is
			// what keeps the message private - nothing but root can enter it, whatever the file's own mode is.
			if (writefile(JOBDIR + '/text', text) == null) {
				run('rm -rf ' + q(JOBDIR));       // let the next caller take the claim we cannot use
				return refuse('Could not queue the message');
			}
			// start writes the number itself, and it is the number that must be a single line in a file
			let s = run(q(JOBRUN) + ' start ' + q(num));
			if (s.rc != 0) {
				run('rm -rf ' + q(JOBDIR));   // as above: nothing is left claimed by a send that never started
				return refuse('Could not start the send', last_line(s.out));
			}
			return { ok: 1, started: 1, job: 1 };
		}
	},

	job: {
		call: function () {
			let st = run(q(JOBRUN) + ' state');
			let f = split(trim(st.out), ' ');
			if (f[0] == 'none')
				return { none: 1 };
			if (f[0] == 'running')
				return { running: 1, elapsed: num(f[1], 0), limit: num(f[2], 0) };
			let r = run(q(JOBRUN) + ' reply');
			// ended with no result: the job died under the send (a restart, say). Whether the message went out
			// is not known, and nothing sends it again by itself
			let v = (r.rc == 0 && trim(r.out) != '')
				? verdict(r.out)
				: refuse('Sending failed', 'the send ended without a result; check the conversation before sending again');
			v.done = 1; v.running = 0; v.elapsed = num(f[1], 0); v.ended = num(f[2], 0);
			return v;
		}
	},

	sync: {
		call: function () {
			// detached, like a send: CMGL walks the whole SIM, and the answer the page wants is only that it
			// started - the list it reloads afterwards shows whether the messages arrived
			detach(q(SMS) + ' sync');
			return { ok: 1, started: 1 };
		}
	},

	delete: {
		args: { id: '', sim: false },
		call: function (req) {
			let id = trim('' + (req.args.id ?? ''));
			if (!match(id, ID_RE) && id != 'all')
				return refuse('Bad ID');
			let sim = req.args.sim ?? false;
			if (type(sim) != 'bool')
				return refuse('The sim parameter must be true or false');
			// --sim also removes the matching message from the SIM storage; without it the copy left there
			// would come back on the next sync
			let r = run(q(SMS) + ' delete ' + q(id) + (sim ? ' --sim' : ''));
			if (r.rc != 0)
				return refuse('Delete failed', last_line(r.out));
			return { ok: 1 };
		}
	}
};

return { mu300sms: methods };
