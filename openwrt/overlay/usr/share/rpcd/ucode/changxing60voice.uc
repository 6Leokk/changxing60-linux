// The call page's backend: every method the page calls, and nothing else.
//
// Same shape as changxing60sms.uc, and for the same reasons. What is different is where the state comes from: the SMS
// page reads a pool the daemon keeps, and this one reads /run/changxing60-voice/state, which changxing60-voiced writes from
// what the modem says (AT+CLCC). So "state" here is not this page's opinion of the call -- it is the modem's,
// and the page cannot set it. That is deliberate: a page that believes a call connected because it asked for one
// shows a lie the moment the network refuses.
//
//   state        {}                  what the call is doing, and how long it has been doing it
//   dial         { num }             place a call, detached (see below); the page asks dialjob for how it went
//   dialjob      {}                  that dial: running, or what changxing60-voice said about it
//   answer       {}                  answer the ringing call, detached
//   hangup       {}                  end it, or refuse it while it is still ringing, detached
//   dtmf         { digits }          send tones into an active call, detached
//   mute         { on }              mute the uplink, detached
//   log          { limit }           call history, newest first
//   logclear     {}                  empty it
//   contacts     {}                  the contact book
//   contact_add  { num, name }
//   contact_del  { num }
//
// Nothing that touches the modem can be answered inside one call. rpcd ends a call at 30 s, and changxing60-at's wait
// for the AT channel's lock alone is up to 90 s (a data attach holds it for 10-20 s at a time), so a dial
// answered here would be killed with the call still in flight and the page would report a failure for a call
// that was placed. Every one of them is handed to setsid and the page polls state, which is the modem's own
// account and therefore the only thing worth reporting anyway.
//
// dial goes one step further than the others, through /opt/changxing60/bin/changxing60-voice-job, because its
// failure is the one that state cannot show. A dial the modem refuses leaves the state file honestly idle -- which
// is exactly what it looked like before the button was pressed -- so a page that only watched state would show
// "dialing" for ever, or nothing at all. The job captures what changxing60-voice printed (the modem's ERROR and
// the lock timeouts among them) and dialjob hands it to the page; the state file stays the only authority on
// whether a call is up. answer, hangup, dtmf and mute do not get this treatment: each of them changes something
// state can see (ringing -> active, busy -> idle), so "still ringing" after a failed answer is the truth and the
// page says so, rather than a second file pretending to be a second opinion.
//
// Every path can be moved for a test (a host-side run has no modem, no /run and no /etc/changxing60). No method takes
// a path, and nothing outside the state file, the call log, the contact book and the dial job's runtime directory
// is read or written.

'use strict';

import { popen, readfile } from 'fs';

const VOICE    = getenv('CHANGXING60_VOICE_BIN') || '/opt/changxing60/bin/changxing60-voice';
const JOBRUN   = getenv('CHANGXING60_VOICE_JOB_BIN') || '/opt/changxing60/bin/changxing60-voice-job';
const JOBROOT  = getenv('CHANGXING60_VOICE_JOB_DIR') || '/var/run/changxing60voice';
const JOBDIR   = JOBROOT + '/job';
const STATE    = getenv('CHANGXING60_VOICE_STATE') || '/run/changxing60-voice/state';
const LOG      = getenv('CHANGXING60_VOICE_LOG') || '/etc/changxing60/call-log';
const CONTACTS = getenv('CHANGXING60_VOICE_CONTACTS') || '/etc/changxing60/contacts';

const NUM_RE   = /^\+?[0-9]{1,20}$/;                 // a phone number
const MMI_RE   = /^[0-9*#]{1,20}$/;                  // a feature code
const NUM_MAX  = 20;                                 // digits, not counting a leading +

// check_number(num): the reason a number will not do, or null when it will. Both regexes above cap
// the length as well as the characters, and reporting "only digits and +" for a number that is
// merely one digit too long sends the user looking for a stray letter that is not there. E.164
// stops at 15 digits; 20 is already generous, and it is the modem's ATD that has the last word.
function check_number(num) {
	let plus = match(num, /^\+/);
	if (length(num) > NUM_MAX + (plus ? 1 : 0))
		return 'A number may be at most ' + NUM_MAX + ' digits (a leading + does not count)';
	if (!match(num, NUM_RE) && !match(num, MMI_RE))
		return 'The number may only contain digits, an optional leading +, and * or #';
	return null;
}
const DTMF_RE  = /^[0-9*#ABCDabcd]{1,32}$/;          // the tones a keypad can send
const MAXNAME  = 64;
const MAXLIMIT = 200;

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

function last_line(out) {
	let lines = split(trim(out ?? ''), "\n");
	return length(lines) ? lines[length(lines) - 1] : '';
}

// num(s, fallback): a number from the strings a reply is split into, or the fallback when it is not one
function num(s, fallback) {
	let n = +(s ?? '');
	return (type(n) == 'int' && n == n) ? n : fallback;
}

const AT_BUSY = /(changxing60|unisoc)-at: busy/;

// refuse(msg, detail): the shape every refusal takes. Declared before its first caller -- ucode does not hoist
// function declarations, and a call to a function declared later in the file compiles as a lookup in the global
// scope, where this file's functions do not live.
function refuse(msg, detail) {
	return (detail == null || detail == '') ? { error: msg } : { error: msg, detail: '' + detail };
}

// dial_verdict(out): how changxing60-voice's reply reads. A busy channel is the AT client's own line, not the
// modem's word. Unlike the SMS backend's match this one is not anchored to a line start, let alone the reply's
// end: changxing60-voice wraps the AT client's errors in a line of its own ("the call was not placed:
// changxing60-at: busy"), so the busy text is embedded mid-line. What matters is that it is there at all.
// Success is its stderr line saying the dial was accepted ("dialling ..."), which is an acceptance of the
// request by the modem, never a connected call.
function dial_verdict(out) {
	if (match(out, AT_BUSY))
		return { ok: 0, busy: 1, error: 'The AT channel is busy; the call was not placed, try again' };
	if (match(out, /(^|\n)dialling /))
		return { ok: 1, reply: trim(out) };
	return refuse('Dial failed', last_line(out));
}

// fields(text): a key=value file as an object. A line with no '=' is not one and is dropped rather than
// becoming a key of its own - the state file is written by a daemon and read here, and a torn or foreign file
// should read as "not there", not as a state with a strange name.
function fields(text) {
	let r = {};
	if (text == null)
		return r;
	for (let line in split(text, "\n")) {
		let i = index(line, '=');
		if (i <= 0)
			continue;
		r[substr(line, 0, i)] = substr(line, i + 1);
	}
	return r;
}

// state(): the state file, with the two derived things every caller would otherwise compute for itself.
function read_state() {
	let f = fields(readfile(STATE));
	let s = f.state ?? '';
	if (s == '')
		s = 'idle';
	let now = +(run('date +%s').out ?? 0);
	let since = +(f.since ?? 0);
	let talk = +(f.talk ?? 0);
	return {
		state: s,
		dir: f.dir ?? '',
		number: f.number ?? '',
		name: f.name ?? '',
		// busy is what the page uses to decide whether to draw the in-call controls at all, and it is the same
		// set the panel's two volume keys turn into answer and hang up on. One definition, in one place.
		busy: (s != 'idle') ? 1 : 0,
		ringing: (s == 'ringing') ? 1 : 0,
		elapsed: (since > 0 && now > since) ? (now - since) : 0,
		// talking is the time since the call was ANSWERED, which is not the same number and is the one a person
		// reads off the screen once the call is up.
		talking: (talk > 0 && now > talk) ? (now - talk) : 0,
		updated: +(f.updated ?? 0)
	};
}

// call_log(text, limit): the call log, newest first. A malformed line is dropped: the file is written by a
// daemon, and one bad line should cost one row, not the whole page.
function call_log(text, limit) {
	let rows = [];
	if (text == null)
		return rows;
	for (let line in split(trim(text), "\n")) {
		if (line == '')
			continue;
		let f = split(line, '|');
		if (length(f) < 6)
			continue;
		let dur = +(f[5] ?? 0);
		push(rows, {
			epoch: +(f[0] ?? 0),
			dir: f[1] ?? '',
			status: f[2] ?? '',
			number: f[3] ?? '',
			name: f[4] ?? '',
			duration: (dur == dur && dur >= 0) ? dur : 0
		});
	}
	// newest first: the file is append-only, so its order is oldest first
	let out = [];
	for (let i = length(rows) - 1; i >= 0 && length(out) < limit; i--)
		push(out, rows[i]);
	return out;
}

function contact_book(text) {
	let rows = [];
	if (text == null)
		return rows;
	for (let line in split(trim(text), "\n")) {
		if (line == '')
			continue;
		let i = index(line, '|');
		if (i <= 0)
			continue;
		push(rows, { number: substr(line, 0, i), name: substr(line, i + 1) });
	}
	return rows;
}

// The AT commands, all detached. Each returns only that it started; whether it worked is read back from state.
function fire(args, what) {
	detach(q(VOICE) + ' ' + args);
	return { ok: 1, started: 1, what: what };
}

const methods = {
	state: {
		call: function () {
			return read_state();
		}
	},

	dial: {
		args: { num: '' },
		call: function (req) {
			let num = trim('' + (req.args.num ?? ''));
			// A number or a feature code, never both shapes at one and never anything else: this string ends up
			// in ATD<num>; and a stray quote or comma would make it a different command.
			let bad = check_number(num);
			if (bad != null)
				return refuse(bad);
			// the claim first, so that two dials at once cannot both reach the modem, and nothing is written
			// down before we hold it
			let c = run(q(JOBRUN) + ' claim');
			if (c.rc != 0) {
				// "busy" is the claim being held by another dial. A claim can also fail because the job's
				// runtime directory cannot be made or owned - a broken install, not a busy modem - and that
				// must not be told to the user as a busy channel. The job prints one line when it refuses a
				// directory ("refusing the runtime directory"), and that is how the two are told apart.
				if (match(c.out ?? '', /refusing the runtime directory/))
					return refuse('Could not start the dial', last_line(c.out));
				return { ok: 0, busy: 1, dial: 1, error: 'The AT channel is busy; the call was not placed, try again' };
			}
			// start writes the number itself, and it is the number that must be a single line in a file
			let s = run(q(JOBRUN) + ' start ' + q(num));
			if (s.rc != 0) {
				run('rm -rf ' + q(JOBDIR));   // nothing is left claimed by a dial that never started
				return refuse('Could not start the dial', last_line(s.out));
			}
			return { ok: 1, started: 1, dial: 1 };
		}
	},

	// dialjob: how the detached dial went, in the four shapes the page reads:
	//   none      nothing has been dialed from here yet
	//   running   the dial holds the AT channel; elapsed and limit are in seconds
	//   done+ok   the modem accepted the dial ("dialling ..." from changxing60-voice) - which means placed,
	//             never connected: whether a call is up is state's answer, and only state's
	//   done+busy the AT client's own "busy" line, not the modem's word
	// and a job that ended with nothing to say is a failure - whether the call was placed is unknown, and
	// nothing dials again by itself.
	dialjob: {
		call: function () {
			let st = run(q(JOBRUN) + ' state');
			let f = split(trim(st.out), ' ');
			if (f[0] == 'none')
				return { none: 1 };
			if (f[0] == 'running')
				return { running: 1, elapsed: num(f[1], 0), limit: num(f[2], 0) };
			let r = run(q(JOBRUN) + ' reply');
			let v = (r.rc == 0 && trim(r.out) != '')
				? dial_verdict(r.out)
				: refuse('Dial failed', 'the dial ended without a result; check the state before dialing again');
			v.done = 1; v.running = 0; v.elapsed = num(f[1], 0); v.ended = num(f[2], 0);
			return v;
		}
	},

	answer: {
		call: function () {
			if (read_state().ringing != 1)
				return refuse('There is no call to answer');
			return fire('answer', 'answer');
		}
	},

	hangup: {
		call: function () {
			if (read_state().busy != 1)
				return refuse('There is no call to end');
			return fire('hangup', 'hangup');
		}
	},

	dtmf: {
		args: { digits: '' },
		call: function (req) {
			let d = trim('' + (req.args.digits ?? ''));
			if (!match(d, DTMF_RE))
				return refuse('Tones may only be 0-9, * , # and A-D');
			if (read_state().state != 'active')
				return refuse('There is no call up to send tones into');
			return fire('dtmf ' + q(d), 'dtmf');
		}
	},

	mute: {
		args: { on: false },
		call: function (req) {
			let on = req.args.on ?? false;
			if (type(on) != 'bool')
				return refuse('The on parameter must be true or false');
			if (read_state().busy != 1)
				return refuse('There is no call to mute');
			return fire('mute ' + (on ? 'on' : 'off'), 'mute');
		}
	},

	log: {
		args: { limit: 0 },
		call: function (req) {
			let n = +(req.args.limit ?? 0);
			if (type(n) != 'int' || n != n || n <= 0)
				n = 50;
			if (n > MAXLIMIT)
				n = MAXLIMIT;
			return { calls: call_log(readfile(LOG), n) };
		}
	},

	logclear: {
		call: function () {
			let r = run(q(VOICE) + ' log clear');
			if (r.rc != 0)
				return refuse('Could not clear the call log', last_line(r.out));
			return { ok: 1 };
		}
	},

	contacts: {
		call: function () {
			return { contacts: contact_book(readfile(CONTACTS)) };
		}
	},

	contact_add: {
		args: { num: '', name: '' },
		call: function (req) {
			let num = trim('' + (req.args.num ?? ''));
			let name = '' + (req.args.name ?? '');
			if (!match(num, NUM_RE))
				return refuse('A contact number may only contain digits and an optional leading +'
					+ (length(num) > NUM_MAX + 1 ? sprintf(' (at most %d of them)', NUM_MAX) : ''));
			if (trim(name) == '')
				return refuse('The name is empty');
			if (length(name) > MAXNAME)
				return refuse(sprintf('The name is too long (over %d characters)', MAXNAME));
			// The name goes into a file with one record per line and '|' as the separator, so it may contain
			// neither. Checked here as well as in changxing60-voice: a page is not a place to find out.
			if (match(name, /[|\n\r\t]/))
				return refuse('A name may not contain | or a control character');
			let r = run(q(VOICE) + ' contacts add ' + q(num) + ' ' + q(name));
			if (r.rc != 0)
				return refuse('Could not save the contact', last_line(r.out));
			return { ok: 1 };
		}
	},

	contact_del: {
		args: { num: '' },
		call: function (req) {
			let num = trim('' + (req.args.num ?? ''));
			if (!match(num, NUM_RE))
				return refuse('Bad number');
			let r = run(q(VOICE) + ' contacts del ' + q(num));
			if (r.rc != 0)
				return refuse('No contact for that number', last_line(r.out));
			return { ok: 1 };
		}
	}
};

return { changxing60voice: methods };
