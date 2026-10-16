// The SMS forwarding page's backend: the half of the SMS settings that turns delivery on and aims it.
//
// A separate object (changxing60fwd) from the pool backend (changxing60sms), on purpose: that one's whole
// world is the message pool, which any number of readers may share, while this one owns a file only root
// may read -- /etc/changxing60/sms-forward.conf holds the Telegram bot token, the webhook URL and its
// headers and the mail password. One object per world keeps that boundary visible, and keeps the pool
// backend's six methods untouched by anything written here.
//
//   forward_get       {}                the configuration as the page edits it
//   forward_set       { cfg }           replace it (all of it validated before anything is written)
//   forward_test      {}                start one delivery of a test message, detached
//   forward_gate      {}                ask whether a test may start now (the engine's own throttle)
//   forward_log       {}                the delivery log, newest first
//   forward_log_clear {}                 empty the delivery log
//   forward_status    {}                queued / running / whether msmtp exists
//
// Secrets are never read back by anyone, not even by a write-capable session -- not because the ACL could
// not tell the two apart, but because forward_get cannot know what a session may do (the ACL is rpcd's
// knowledge, not the call's), and because a masked read is simpler than a conditional one and cannot be
// gotten wrong later. Every secret field comes back either empty ("nothing stored") or as the sentinel
// "(kept)" ("something is stored, this is not it"), and forward_set treats "(kept)" as "keep what is
// stored". So the page shows "(kept)" in the field, and saving an untouched form saves nothing new; the
// only ways to see an actual secret are the root shell and the log-free engine itself. A cleared field
// (empty string) clears the stored value. The same sentinel names a header's stored value per line
// ("Authorization: (kept)"), so one header can be edited without retyping the others.
//
// The configuration is never rewritten in place and never through a shell: it is built in memory from the
// stored file plus what the call provides, every provided field is validated before anything happens, and
// the result is written to a random file inside a random directory of the configuration's own directory and
// renamed over the target. A rename is atomic, so a reader -- the engine reads the file on every delivery
// -- sees either the whole old file or the whole new one, never a half. The file is chmod 600 before the
// rename and its holding directory is 700, so no window leaves it readable by anyone but root.
//
// forward_test is detached, like a send: one delivery can wait up to 15 s for a server that answers slowly
// (the helper's timeout), four targets in a row are more than rpcd allows a call, and the result the page
// wants is in the delivery log anyway, which it refreshes. The engine refuses a second test while one
// runs; its words are lost to a detached start, so the page is told only that a test started, and reads
// the log to see how it went.
//
// Nothing here passes page-supplied text to a shell: the engine is invoked by fixed commands, the
// configuration is written with the filesystem calls below, and every value that goes into the file has
// been matched against a pattern first. What the engine itself does with the file is its own discipline
// (its header documents it): values reach its awk helpers through the environment, and no secret is ever
// put on a command line or in the log.
//
// Every path can be moved for a test (a host-side run has no /etc and no engine at those paths):
// CHANGXING60_FWD_BIN is the engine, CHANGXING60_FWD_CONF / CHANGXING60_FWD_STATE / CHANGXING60_FWD_RUN
// the engine's own three. No method takes a path.

'use strict';

import * as fs from 'fs';
import { popen } from 'fs';

const FWD   = getenv('CHANGXING60_FWD_BIN')   || '/opt/changxing60/bin/changxing60-sms-forward';
const CONF  = getenv('CHANGXING60_FWD_CONF')  || '/etc/changxing60/sms-forward.conf';

// "(kept)": the sentinel a stored secret is masked with, and the only value that means "keep the stored
// one". Chosen so no real token, URL or password can collide with it by accident; a user who genuinely
// wants that exact string as a secret can still set it by hand in the file.
const KEPT = '(kept)';

// The engine's default template, in the form the page edits (real newlines) and in the form the file
// stores (a newline as \n, a backslash as \\). An empty stored template means this default, so
// forward_get reports the effective template, and forward_set writes nothing for an empty one.
const TEMPLATE_DEFAULT_STORED = '{text}\\n-- {sender}, {time} ({device})';

// The limits, all in bytes (the engine also works in bytes): tighter than what breaks, loose enough for
// every real use. The template and the body cap matches the engine's own comment ("the panel takes a body
// template of 2000 bytes at most"); the rest bound how much of the file one call can grow.
const MAX_TEMPLATE = 2000;
const MAX_BODY     = 2000;
const MAX_URL      = 512;
const MAX_TOKEN    = 64;
const MAX_CHAT     = 64;
const MAX_HOST     = 255;
const MAX_USER     = 128;
const MAX_PASS     = 128;
const MAX_ADDR     = 254;
const MAX_NUMBER   = 20;
const MAX_EXPECT   = 64;
const MAX_ENTRY    = 64;         // one filter entry
const MAX_ENTRIES  = 64;         // entries per filter list
const MAX_HEADERS  = 16;         // header lines
const MAX_HEADER   = 512;        // bytes per header line

// The engine's default for the fields it defaults: forward_get reports the effective values, so the page
// shows what the engine will do rather than a blank that means two things.
const PORT_DEFAULT = '587';
const TLS_DEFAULT  = 'starttls';
const FMT_DEFAULT  = 'json';

// A shell word: single-quoted, with any single quote in it closed, escaped and reopened. Only the engine's
// own fixed path goes through this -- no field value is ever on a command line -- but the helper is shared
// discipline with the pool backend.
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

// detach(cmd): start it and do not wait. setsid takes it out of rpcd's process group, and its output is
// thrown away -- the pipe has to go, or reading it would wait for the child (the whole point is not to).
function detach(cmd) {
	let fd = popen('setsid ' + cmd + ' >/dev/null 2>&1 &');
	if (fd) {
		fd.read('all');
		fd.close();
	}
}

function refuse(msg, detail) {
	return (detail == null || detail == '') ? { error: msg } : { error: msg, detail: '' + detail };
}

// text_ok(s): nothing but printable text, a tab and a newline -- the same rule the pool backend applies to
// a message. A control character is not something a page can mean to store.
function text_ok(s) {
	return length(replace(s, /[\t\n\x20-\x7e\x80-\xff]+/g, '')) == 0;
}

// line_ok(s): one printable line -- no tab, no control character. Everything that lands in the
// configuration as a single line (a URL, a token, an address) is checked with this: a newline in a value
// would be the beginning of a different line in the file, and of a different line in the helper's request.
function line_ok(s) {
	return length(replace(s, /[\x20-\x7e\x80-\xff]+/g, '')) == 0;
}

// escape(s) / unescape(s): between what the page edits (real newlines) and what the file stores (a newline
// as \n, a backslash as \\). unescape mirrors the engine's fill() exactly -- \n is a newline, \X for any
// other X is X alone, a trailing backslash vanishes -- so what the page shows is what the engine will send.
function escape(s) {
	return replace(replace(s, /\\/g, '\\\\'), /\n/g, '\\n');
}

function unescape(s) {
	let out = '';
	while (length(s)) {
		let i = index(s, '\\');            // 0-based position of the next backslash; -1: none left
		if (i < 0) {
			out += s;
			break;
		}
		out += substr(s, 0, i);
		let c = substr(s, i + 1, 1);       // the character the escape names
		out += (c == 'n') ? '\n' : c;
		s = substr(s, i + 2);
	}
	return out;
}

// parse_conf(text): the stored file into a configuration object. Lists are one entry per line, so a
// repeated key accumulates; a line with no '=' is not a key and is dropped (a torn or foreign file reads as
// its defaults, not as garbage keys). Stored template and body stay escaped here; forward_get unescapes.
function parse_conf(text) {
	let c = {
		enabled: 0,
		template: '',
		allow: [], deny: [], keyword: [],
		webhook: 0, webhook_url: '', webhook_format: '', webhook_body: '', webhook_expect: '', webhook_header: [],
		telegram: 0, telegram_token: '', telegram_chat: '',
		email: 0, email_host: '', email_port: '', email_tls: '', email_user: '', email_password: '',
		email_from: '', email_to: '',
		sms: 0, sms_number: ''
	};
	if (text == null)
		return c;
	for (let line in split(text, '\n')) {
		// index() is 0-based here and -1 when the character is absent: a line whose first byte is '=' has
		// an empty key and is dropped with the rest
		let i = index(line, '=');
		if (i < 1)
			continue;
		let k = substr(line, 0, i);
		let v = substr(line, i + 1);
		if (k == 'allow' || k == 'deny' || k == 'keyword') {
			if (v != '')
				push(c[k], v);
		} else if (k == 'webhook_header') {
			if (v != '')
				push(c.webhook_header, v);
		} else if (k in c)
			c[k] = v;
	}
	return c;
}

// mask_header(line): one stored "Name: value" line as the page may see it. A line that is not a header
// line is dropped: the helper ignores those too, so nothing the page cannot display is lost.
function mask_header(line) {
	let m = match(line, /^([A-Za-z0-9-]+):[ \t]*(.*)$/);
	return m ? (m[1] + ': ' + KEPT) : null;
}

// The configuration as the page edits it: lists as arrays, template and body with real newlines, every
// secret as "" (nothing stored) or KEPT (stored, not shown), and the engine's defaults filled in so the
// page displays what the engine will do. The one thing a caller can learn about a stored secret is that
// there is one.
function effective(c) {
	let headers = [];
	for (let h in c.webhook_header) {
		let m = mask_header(h);
		if (m != null)
			push(headers, m);
	}
	return {
		enabled: c.enabled == 1,
		template: c.template == '' ? unescape(TEMPLATE_DEFAULT_STORED) : unescape(c.template),
		allow: c.allow, deny: c.deny, keyword: c.keyword,
		webhook: c.webhook == 1,
		webhook_url: c.webhook_url == '' ? '' : KEPT,
		webhook_format: c.webhook_format == '' ? FMT_DEFAULT : c.webhook_format,
		webhook_body: unescape(c.webhook_body),
		webhook_expect: c.webhook_expect,
		webhook_header: join('\n', headers),
		telegram: c.telegram == 1,
		telegram_token: c.telegram_token == '' ? '' : KEPT,
		telegram_chat: c.telegram_chat,
		email: c.email == 1,
		email_host: c.email_host,
		email_port: c.email_port == '' ? PORT_DEFAULT : c.email_port,
		email_tls: c.email_tls == '' ? TLS_DEFAULT : c.email_tls,
		email_user: c.email_user,
		email_password: c.email_password == '' ? '' : KEPT,
		email_from: c.email_from,
		email_to: c.email_to,
		sms: c.sms == 1,
		sms_number: c.sms_number,
		// which targets are on and have what they need -- the engine's own targets() rule, so the page can
		// warn about a target that is on but cannot deliver. Only names: nothing secret in a readiness bit.
		// Built with push: ucode's arrays have no concat.
		ready: (function () {
			let r = [];
			if (c.webhook == 1 && c.webhook_url != '')
				push(r, 'webhook');
			if (c.telegram == 1 && c.telegram_token != '' && c.telegram_chat != '')
				push(r, 'telegram');
			if (c.email == 1 && c.email_host != '' && c.email_to != '' && c.email_from != '')
				push(r, 'email');
			if (c.sms == 1 && c.sms_number != '')
				push(r, 'sms');
			return r;
		})()
	};
}

// entries_ok(a, what, errs): a filter list. Each entry becomes one line of the file, so it may not hold a
// newline or a tab; it may hold a space (the engine normalizes spaces away when it compares) and a
// trailing * (which is what matches "everything from this sender").
function entries_ok(a, what, errs) {
	if (type(a) != 'array')
		return refuse('The ' + what + ' list must be a list of senders');
	if (length(a) > MAX_ENTRIES)
		return refuse(sprintf('The %s list is too long (over %d entries)', what, MAX_ENTRIES));
	for (let e in a) {
		if (type(e) != 'string')
			return refuse('The ' + what + ' list must be a list of senders');
		let s = trim(e);
		if (s == '')
			return refuse('The ' + what + ' list holds an empty entry');
		if (length(s) > MAX_ENTRY)
			return refuse(sprintf('The %s list holds an entry over %d bytes', what, MAX_ENTRY));
		if (!text_ok(s))
			return refuse('The ' + what + ' list holds a control character');
		if (match(s, /[\t\r]/))
			return refuse('The ' + what + ' list holds an entry with a tab');
	}
	return null;
}

// expect_ok(v): the webhook's answer check, exactly the rule the engine delivers by (its expect_ok): KEY a
// name up to 32 characters, VALUE a whole number of at most 16 digits or up to 16 lowercase letters. A
// looser rule here would let a caller ask the helper to hand over more of an answer than the engine is
// willing to reason about.
function expect_ok(v) {
	let m = match(v, /^([A-Za-z_][A-Za-z0-9_]{0,31})=(.+)$/);
	if (!m)
		return false;
	return match(m[2], /^-?[0-9]{1,16}$/) != null || match(m[2], /^[a-z]{1,16}$/) != null;
}

// build(conf, cfg): the stored configuration with the call's fields laid over it. Returns either the
// merged configuration or a refusal; nothing is written until a merged configuration has validated whole.
// Kept secrets are not re-validated -- they are already in the file, and nothing this call does makes them
// worse; the engine reports what does not deliver in its own log.
function build(c, cfg) {
	let errs;

	if ('enabled' in cfg) {
		if (type(cfg.enabled) != 'bool')
			return refuse('The enabled flag must be true or false');
		c.enabled = cfg.enabled ? 1 : 0;
	}
	for (let t in [ 'webhook', 'telegram', 'email', 'sms' ]) {
		let k = t;
		if (k in cfg) {
			if (type(cfg[k]) != 'bool')
				return refuse('The ' + k + ' flag must be true or false');
			c[k] = cfg[k] ? 1 : 0;
		}
	}

	if ('template' in cfg) {
		if (type(cfg.template) != 'string')
			return refuse('The template must be text');
		let s = '' + cfg.template;
		if (length(escape(s)) > MAX_TEMPLATE)
			return refuse(sprintf('The template is too long (over %d bytes)', MAX_TEMPLATE));
		if (!text_ok(s))
			return refuse('The template contains a control character');
		c.template = (trim(s) == '') ? '' : escape(s);
	}

	for (let k in [ 'allow', 'deny', 'keyword' ]) {
		let key = k;
		if (key in cfg) {
			errs = entries_ok(cfg[key], key, errs);
			if (errs) return errs;
			let r = [];
			for (let e in cfg[key])
				push(r, trim(e));
			c[key] = r;
		}
	}

	if ('webhook_url' in cfg) {
		if (type(cfg.webhook_url) != 'string')
			return refuse('The webhook URL must be text');
		let s = trim(cfg.webhook_url);
		if (s == KEPT) {
			// keep
		} else if (s == '') {
			c.webhook_url = '';
		} else {
			if (length(s) > MAX_URL)
				return refuse(sprintf('The webhook URL is too long (over %d bytes)', MAX_URL));
			if (!line_ok(s) || match(s, /\s/))
				return refuse('The webhook URL contains whitespace or a control character');
			if (substr(s, 0, 7) != 'http://' && substr(s, 0, 8) != 'https://')
				return refuse('The webhook URL must start with http:// or https://');
			c.webhook_url = s;
		}
	}

	if ('webhook_format' in cfg) {
		if (type(cfg.webhook_format) != 'string')
			return refuse('The webhook format must be text');
		let s = trim(cfg.webhook_format);
		if (s != '' && s != 'json' && s != 'form' && s != 'text')
			return refuse('The webhook format must be json, form or text');
		c.webhook_format = s;
	}

	if ('webhook_body' in cfg) {
		if (type(cfg.webhook_body) != 'string')
			return refuse('The webhook body must be text');
		let s = '' + cfg.webhook_body;
		if (length(escape(s)) > MAX_BODY)
			return refuse(sprintf('The webhook body is too long (over %d bytes)', MAX_BODY));
		if (!text_ok(s))
			return refuse('The webhook body contains a control character');
		c.webhook_body = (trim(s) == '') ? '' : escape(s);
	}

	if ('webhook_expect' in cfg) {
		if (type(cfg.webhook_expect) != 'string')
			return refuse('The answer check must be text');
		let s = trim(cfg.webhook_expect);
		if (s != '' && !expect_ok(s))
			return refuse('The answer check must be KEY=VALUE, KEY a name and VALUE a number or a lowercase word');
		if (length(s) > MAX_EXPECT)
			return refuse(sprintf('The answer check is too long (over %d bytes)', MAX_EXPECT));
		c.webhook_expect = s;
	}

	if ('webhook_header' in cfg) {
		if (type(cfg.webhook_header) != 'string')
			return refuse('The webhook headers must be text');
		// The page's lines are real-newline separated; "(kept)" in the value of a line means "the stored
		// value of that same header name" -- which is the only way to edit one header without retyping the
		// values of the others, since the values are exactly what this page may not show.
		let out = [];
		let lines = split(cfg.webhook_header, '\n');
		if (length(lines) > MAX_HEADERS)
			return refuse(sprintf('Too many header lines (over %d)', MAX_HEADERS));
		for (let l in lines) {
			let line = trim(l);
			if (line == '')
				continue;
			if (length(line) > MAX_HEADER)
				return refuse(sprintf('A header line is too long (over %d bytes)', MAX_HEADER));
			let m = match(line, /^([A-Za-z0-9-]+):[ \t]*(.*)$/);
			if (!m)
				return refuse('A header line is not "Name: value"');
			if (!line_ok(line))
				return refuse('A header line contains a control character');
			if (m[2] == KEPT) {
				let stored = null;
				for (let h in c.webhook_header) {
					let sm = match(h, /^([A-Za-z0-9-]+):[ \t]*(.*)$/);
					if (sm && sm[1] == m[1])
						stored = h;
				}
				if (stored == null)
					return refuse('A header is left as (kept) but no value for ' + m[1] + ' is stored');
				push(out, stored);
			} else {
				push(out, m[1] + ': ' + m[2]);
			}
		}
		c.webhook_header = out;
	}

	if ('telegram_token' in cfg) {
		if (type(cfg.telegram_token) != 'string')
			return refuse('The Telegram token must be text');
		let s = trim(cfg.telegram_token);
		// No whitespace or control character, and no slash: the token is composed into a URL path
		// (https://api.telegram.org/bot<token>/sendMessage) and goes to the helper as one line of a
		// request -- a newline here would be the beginning of a different request.
		if (s != KEPT && s != '') {
			if (length(s) > MAX_TOKEN)
				return refuse(sprintf('The Telegram token is too long (over %d bytes)', MAX_TOKEN));
			if (!match(s, /^[A-Za-z0-9_:-]+$/))
				return refuse('The Telegram token may only contain letters, digits, _, : and -');
		}
		if (s != KEPT)
			c.telegram_token = s;
	}

	if ('telegram_chat' in cfg) {
		if (type(cfg.telegram_chat) != 'string')
			return refuse('The Telegram chat must be text');
		let s = trim(cfg.telegram_chat);
		if (s != '') {
			if (length(s) > MAX_CHAT)
				return refuse(sprintf('The Telegram chat is too long (over %d bytes)', MAX_CHAT));
			// a chat id is a number (possibly negative) or an @channelname
			if (!match(s, /^[A-Za-z0-9_@-]+$/))
				return refuse('The Telegram chat must be a chat id or an @channelname');
		}
		c.telegram_chat = s;
	}

	if ('email_host' in cfg) {
		if (type(cfg.email_host) != 'string')
			return refuse('The mail server must be text');
		let s = trim(cfg.email_host);
		if (s != '') {
			if (length(s) > MAX_HOST)
				return refuse(sprintf('The mail server is too long (over %d bytes)', MAX_HOST));
			if (!line_ok(s) || match(s, /\s/))
				return refuse('The mail server contains whitespace or a control character');
		}
		c.email_host = s;
	}

	if ('email_port' in cfg) {
		if (type(cfg.email_port) != 'string')
			return refuse('The mail port must be a number');
		let s = trim(cfg.email_port);
		if (s != '') {
			if (!match(s, /^[0-9]{1,5}$/))
				return refuse('The mail port must be a number');
			let n = +s;
			if (n < 1 || n > 65535)
				return refuse('The mail port must be between 1 and 65535');
		}
		c.email_port = s;
	}

	if ('email_tls' in cfg) {
		if (type(cfg.email_tls) != 'string')
			return refuse('The mail encryption must be text');
		let s = trim(cfg.email_tls);
		if (s != '' && s != 'starttls' && s != 'tls' && s != 'off')
			return refuse('The mail encryption must be starttls, tls or off');
		c.email_tls = s;
	}

	if ('email_user' in cfg) {
		if (type(cfg.email_user) != 'string')
			return refuse('The mail user must be text');
		let s = trim(cfg.email_user);
		// the user and the password become lines of msmtp's configuration file, so a control character in
		// either would be the beginning of a different line there
		if (s != '' && !line_ok(s))
			return refuse('The mail user contains a control character');
		if (length(s) > MAX_USER)
			return refuse(sprintf('The mail user is too long (over %d bytes)', MAX_USER));
		c.email_user = s;
	}

	if ('email_password' in cfg) {
		if (type(cfg.email_password) != 'string')
			return refuse('The mail password must be text');
		let s = '' + cfg.email_password;
		if (s != KEPT) {
			if (length(s) > MAX_PASS)
				return refuse(sprintf('The mail password is too long (over %d bytes)', MAX_PASS));
			if (s != '' && !line_ok(s))
				return refuse('The mail password contains a control character');
			c.email_password = s;
		}
	}

	for (let k in [ 'email_from', 'email_to' ]) {
		let key = k;
		if (key in cfg) {
			if (type(cfg[key]) != 'string')
				return refuse('The mail address must be text');
			let s = trim(cfg[key]);
			// both become header lines of the mail itself (From: / To:), so a newline in either would not
			// be a broken address but a header the caller chose
			if (s != '') {
				if (length(s) > MAX_ADDR)
					return refuse(sprintf('The mail address is too long (over %d bytes)', MAX_ADDR));
				if (!line_ok(s))
					return refuse('The mail address contains a control character');
				if (!match(s, /@/))
					return refuse('The mail address must contain an @');
			}
			c[key] = s;
		}
	}

	if ('sms_number' in cfg) {
		if (type(cfg.sms_number) != 'string')
			return refuse('The forwarding number must be text');
		let s = trim(cfg.sms_number);
		if (s != '' && !match(s, /^\+?[0-9]{1,20}$/))
			return refuse('The forwarding number may only contain digits (and a leading +)');
		c.sms_number = s;
	}

	return c;
}

// render(c): the merged configuration as the file's lines. Booleans always (0 is meaningful), everything
// else only when it has a value -- the file is replaced whole, so omitting a key is exactly clearing it,
// and the engine's own defaults (template, port, tls, format) apply to what is absent.
function render(c) {
	let out = 'enabled=' + c.enabled +
		'\nwebhook=' + c.webhook +
		'\ntelegram=' + c.telegram +
		'\nemail=' + c.email +
		'\nsms=' + c.sms;
	if (c.template != '')
		out += '\ntemplate=' + c.template;
	for (let e in c.allow)
		out += '\nallow=' + e;
	for (let e in c.deny)
		out += '\ndeny=' + e;
	for (let e in c.keyword)
		out += '\nkeyword=' + e;
	if (c.webhook_url != '')
		out += '\nwebhook_url=' + c.webhook_url;
	if (c.webhook_format != '')
		out += '\nwebhook_format=' + c.webhook_format;
	if (c.webhook_body != '')
		out += '\nwebhook_body=' + c.webhook_body;
	if (c.webhook_expect != '')
		out += '\nwebhook_expect=' + c.webhook_expect;
	for (let h in c.webhook_header)
		out += '\nwebhook_header=' + h;
	if (c.telegram_token != '')
		out += '\ntelegram_token=' + c.telegram_token;
	if (c.telegram_chat != '')
		out += '\ntelegram_chat=' + c.telegram_chat;
	if (c.email_host != '')
		out += '\nemail_host=' + c.email_host;
	if (c.email_port != '')
		out += '\nemail_port=' + c.email_port;
	if (c.email_tls != '')
		out += '\nemail_tls=' + c.email_tls;
	if (c.email_user != '')
		out += '\nemail_user=' + c.email_user;
	if (c.email_password != '')
		out += '\nemail_password=' + c.email_password;
	if (c.email_from != '')
		out += '\nemail_from=' + c.email_from;
	if (c.email_to != '')
		out += '\nemail_to=' + c.email_to;
	if (c.sms_number != '')
		out += '\nsms_number=' + c.sms_number;
	return out + '\n';
}

// write_conf(text): the atomic half. A random directory in the configuration's own directory (so the
// rename cannot cross a filesystem), the file in it closed and chmod 600 before the rename, the directory
// removed afterwards. mkdtemp is the only creator of the name, so two saves never collide; a rename
// replaces the target whole, so the engine reading concurrently sees one file or the other, never a mix.
function write_conf(text) {
	let dir = fs.dirname(CONF);
	let tmp = fs.mkdtemp(dir + '/.sms-fwd-XXXXXX');
	if (tmp == null) {
		// the engine's own state_init creates the parent directory as a side effect of its state
		// directory; a configuration written before any engine run is the one case the parent misses
		fs.mkdir(dir);
		tmp = fs.mkdtemp(dir + '/.sms-fwd-XXXXXX');
		if (tmp == null)
			return refuse('Could not write the configuration', fs.error());
	}
	let path = tmp + '/conf';
	let f = fs.open(path, 'w');
	if (f == null || f.write(text) == null) {
		if (f) f.close();
		fs.rmdir(tmp);
		return refuse('Could not write the configuration', fs.error());
	}
	f.close();
	// before the rename, not after: the mode travels with the file, and this is what keeps every instant
	// of its life root-only
	fs.chmod(path, 0o600);
	if (!fs.rename(path, CONF)) {
		fs.unlink(path);
		fs.rmdir(tmp);
		return refuse('Could not replace the configuration', fs.error());
	}
	fs.rmdir(tmp);
	return null;
}

// log_rows(text): the delivery log as the page shows it, newest first. A row is
// epoch \t id \t target \t result \t detail; the detail is the remainder of the line (it is the only
// field that could hold a tab). A malformed line costs its row, not the page.
function log_rows(text) {
	let rows = [];
	if (text == null)
		return rows;
	for (let line in split(trim(text), '\n')) {
		if (line == '')
			continue;
		let f = split(line, '\t', 5);
		if (length(f) < 5)
			continue;
		let ts = +(f[0]);
		push(rows, {
			ts: (type(ts) == 'int' && ts == ts) ? ts : 0,
			id: f[1],
			target: f[2],
			result: f[3],
			detail: f[4]
		});
	}
	let out = [];
	for (let i = length(rows) - 1; i >= 0; i--)
		push(out, rows[i]);
	return out;
}

const methods = {

	forward_get: {
		call: function () {
			return { cfg: effective(parse_conf(fs.readfile(CONF))) };
		}
	},

	forward_set: {
		args: { cfg: {} },
		call: function (req) {
			let cfg = req.args.cfg;
			if (cfg == null || type(cfg) != 'object')
				return refuse('No configuration given');
			// the stored file is parsed for what the call keeps (the kept secrets), laid over, validated
			// whole, and only then written: a call that fails validation leaves the stored file untouched
			let c = build(parse_conf(fs.readfile(CONF)), cfg);
			if (c.error != null)
				return c;
			let w = write_conf(render(c));
			if (w != null)
				return w;
			return { ok: 1 };
		}
	},

	forward_test: {
		call: function () {
			detach(q(FWD) + ' test');
			return { ok: 1, started: 1 };
		}
	},

	forward_gate: {
		call: function () {
			// the engine's own throttle: it refuses while a test it started less than CHANGXING60_FWD_TEST_GAP
			// seconds ago is still young, and it consumes the slot on success -- so the page asks this first
			// and only starts a test when it says yes
			let r = run(q(FWD) + ' test-gate');
			if (r.rc != 0)
				return { ok: 0, wait: 1, error: 'A test was started less than a moment ago; wait a few seconds' };
			return { ok: 1 };
		}
	},

	forward_log: {
		call: function () {
			// through the engine, not by path: where the log lives is the engine's business (it moves to
			// /tmp when /run does not exist), and it is the engine that guarantees nothing secret lands in it
			let r = run(q(FWD) + ' log');
			return { rows: log_rows(r.out) };
		}
	},

	forward_log_clear: {
		call: function () {
			let r = run(q(FWD) + ' log-clear');
			if (r.rc != 0)
				return refuse('Could not clear the log', r.out);
			return { ok: 1 };
		}
	},

	forward_status: {
		call: function () {
			let r = run(q(FWD) + ' status');
			let qd = match(r.out, /(^|\n)queued ([0-9]+)/);
			let rn = match(r.out, /(^|\n)running ([0-9]+)/);
			let em = match(r.out, /(^|\n)email ([0-9]+)/);
			return {
				queued: qd ? +(qd[2]) : 0,
				running: rn ? +(rn[2]) : 0,
				// 1 = msmtp is installed, so an e-mail target can actually deliver
				email: em ? +(em[2]) : 0
			};
		}
	}
};

return { changxing60fwd: methods };
