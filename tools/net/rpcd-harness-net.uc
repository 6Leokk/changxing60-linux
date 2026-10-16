// Drive the changxing60net rpcd backend against a stubbed collector and assert the page's data
// contract, from inside the OpenWrt image (where ucode lives). tools/net/test-rpcd.sh runs this.
//
// The backend under test is openwrt/overlay/usr/share/rpcd/ucode/changxing60net.uc; the collector
// it runs is a stub (tools/net/fake-net-status), answering from JSON files the test writes -- a good
// snapshot, the error case (exit 1 + top-level error), and the hostile ones (not JSON, two lines,
// nothing printed) -- exactly the seams tools/net/test-status.sh uses for the collector itself,
// one level up.
//
// The assertions are the page's data contract:
//   * a good round passes the collector's JSON through VERBATIM as a value -- every field, every
//     null a null (the one rule the page cannot break: an unanswered field must not arrive as 0),
//     nothing re-typed or defaulted;
//   * the error round (exit 1) arrives as { ok: 0, error } with the collector's own sentence, and
//     busy only when the collector said so -- never as an invented snapshot and never as the page's
//     own error;
//   * a broken collector (no JSON, two lines, silence) is OUR error, with detail -- a different
//     shape from the modem's, so the page can tell the two apart;
//   * fast selects the fast tier (the stub records the argument it was given).
'use strict';

import * as fs from 'fs';
import { popen } from 'fs';

const REPO = '/repo';
const HARNESS = REPO + '/tools/sms/rpcd-harness.uc';
const PLUGIN = REPO + '/openwrt/overlay/usr/share/rpcd/ucode/changxing60net.uc';
const STUB = '/work/bin/changxing60-net-status';
// the reply files the stub serves, one per case, written by this test as it goes
const CASE = '/work/case.json';
// the stub records the argument list it was handed, so fast is proven, not assumed
const DIALED = '/work/dialed';

let fails = 0;
function ok(name) { print('ok   ' + name + '\n'); }
function bad(name, detail) {
	print('FAIL ' + name + '\n');
	if (detail != null)
		print('     ' + detail + '\n');
	fails++;
}
function eq(name, got, want) {
	if (got === want)
		ok(name);
	else
		bad(name, 'got [' + got + '] want [' + want + ']');
}
// jdeep(name, got, want): deep equality with the strictness the page's data contract needs: a null
// is a null and only a null (null != 0, null != ""), types compared as they are (the number 1 is
// not the string "1"), arrays item for item, objects key for key (an added key is a difference, a
// dropped key too -- the snapshot must be verbatim). ucode's fs has no equal(), so it is written
// here against the exact rule it must enforce.
function same(a, b) {
	if (a == null || b == null)
		return (a == null && b == null);
	let ta = type(a), tb = type(b);
	if (ta != tb)
		return false;
	if (ta == 'array') {
		if (length(a) != length(b))
			return false;
		for (let i = 0; i < length(a); i++)
			if (!same(a[i], b[i]))
				return false;
		return true;
	}
	if (ta == 'object') {
		let ka = sort(keys(a)), kb = sort(keys(b));
		if (length(ka) != length(kb))
			return false;
		for (let i = 0; i < length(ka); i++)
			if (ka[i] != kb[i] || !same(a[ka[i]], b[kb[i]]))
				return false;
		return true;
	}
	return a === b;
}
function jdeep(name, got, want) {
	if (same(got, want))
		ok(name);
	else
		bad(name, 'got ' + sprintf('%J', got) + ' want ' + sprintf('%J', want));
}

// q(s): a shell word. ucode does not hoist function declarations, so this and has() sit above
// every use site.
function q(s) { return "'" + replace('' + s, /'/g, "'\\''") + "'"; }
// has(what, part): a local needle test for the detail line (index, so no regex quoting surprises)
function has(hay, needle) {
	return index(hay ?? '', needle) >= 0;
}

// call METHOD ARGS: the backend's reply, through the same harness rpcd itself loads plugins with.
// popen'd so this file stays a plain runner; the harness prints one JSON line.
function call(method, args) {
	let fd = popen('ucode ' + q(HARNESS) + ' ' + q(PLUGIN) + ' ' + method + ' ' + q(args));
	let out = fd.read('all') ?? '';
	fd.close();
	let line = split(trim(out), '\n')[0] ?? '';
	try {
		return json(line);
	} catch (e) {
		bad('the harness answered JSON (' + method + ')', line);
		return null;
	}
}

// stage(text, rc): write the stub's reply and its exit code for the next case.
function stage(text, rc) {
	fs.writefile(CASE, '' + text + '\n');
	fs.writefile('/work/case.rc', '' + rc + '\n');
	fs.writefile(DIALED, '');
}

// The good snapshot: the real device's 2026-10-16 round, as the collector's --json actually printed
// it (tools/net/test-status.sh pins the same values from the fake AT one level down). Every field
// that was answered carries its value; the unanswered ones (csq.rssi on NR, sig.rssi, the LTE
// serving cell on this round) are null -- that is what must survive the backend.
const GOOD = {
	ts: 1760000000, time: '2026-10-16T12:00:00Z', cfun: 1,
	reg: { stat: 1, tac: '400460', cid: '011A7000', act: 11 },
	reg5: { stat: 1, tac: '400460', cid: '5011A7000', act: 11 },
	ops: { name: null, plmn: '46000', act: 11 },
	eng_skip: null,
	serving: {
		lte: null,
		nr: { rat: 'nr', band: 41, arfcn: 504990, pci: 274, rsrp: -88.5, rsrq: -9.6,
		      sinr: 8.0, bw_mhz: 20, gnb: '123456', cid: '5011A7000',
		      ul_mcs: null, dl_mcs: null, ul_bler: null, dl_bler: null }
	},
	sig: { source: 'nr', rsrp: -88.5, rsrq: -9.6, sinr: 8.0, rssi: null },
	csq: { rssi: null, ber: null },
	cesq: { rsrp: -88.5, rsrq: -9.6 },
	neighbours: {
		lte: [],
		nr: [ { rat: 'nr', band: 41, arfcn: 504990, pci: 100, rsrp: -100.2, rsrq: null, sinr: null } ]
	},
	traffic: { iface: 'sipa_eth0', present: 1, operstate: 'up',
	           rx_bytes: 257131423, tx_bytes: 26584089, rx_packets: 288588, tx_packets: 143608 }
};

print('== a good round passes verbatim ==\n');
stage(sprintf('%J', GOOD), 0);
let r = call('status', '{}');
eq('a good round answers ok 1', r?.ok, 1);
jdeep('and the snapshot is the collector\'s JSON, field for field and null for null',
      r?.snap, GOOD);
// the null rule, named: these three were unanswered on the real round, and must still be null on
// the far side of the backend -- never 0, never "", never dropped from the reply
eq('an unanswered RSRP is still null (not 0)', r?.snap?.sig?.rssi, null);
eq('an unanswered csq.rssi is still null', r?.snap?.csq?.rssi, null);
eq('an unanswered serving.lte is still null', r?.snap?.serving?.lte, null);
eq('the neighbour whose rsrq it did not answer keeps null', r?.snap?.neighbours?.nr?.[0]?.rsrq, null);
// and the values that were answered are the numbers, not re-typed strings
eq('rsrp stays the number it was', r?.snap?.sig?.rsrp, -88.5);
eq('the cell id stays the exact string (36 bits)', r?.snap?.reg5?.cid, '5011A7000');
// the full argument list the stub was handed: --json, and nothing else
eq('the collector was asked --json', trim(fs.readfile(DIALED) ?? ''), '--json');

print('\n== the fast method selects the fast tier ==\n');
stage(sprintf('%J', GOOD), 0);
r = call('fast', '{}');
eq('fast answers ok 1', r?.ok, 1);
eq('the collector was asked --fast --json', trim(fs.readfile(DIALED) ?? ''), '--fast --json');
r = call('status', '{"args":{"fast":true}}');
eq('status with fast:true asks the fast tier', trim(fs.readfile(DIALED) ?? ''), '--fast --json');
stage(sprintf('%J', GOOD), 0);
r = call('status', '{"args":{"fast":false}}');
eq('status without fast asks the full round', trim(fs.readfile(DIALED) ?? ''), '--json');

print('\n== the error round: the collector\'s own words, and a busy bit ==\n');
// exit 1 + a top-level error, with busy: nothing answered because another client held the channel
stage('{"ts":1760000000,"time":"2026-10-16T12:00:00Z","busy":1,"error":"AT channel was busy the whole round (another client holds it)"}', 1);
r = call('status', '{}');
eq('the error round answers ok 0', r?.ok, 0);
eq('with the collector\'s own sentence', r?.error, 'AT channel was busy the whole round (another client holds it)');
eq('and the busy bit came through', r?.busy, 1);
eq('and no snapshot was invented', r?.snap, null);
// the same round without busy
stage('{"ts":1760000000,"time":"2026-10-16T12:00:00Z","error":"changxing60-atd is not running (nothing reads the AT channel)"}', 1);
r = call('status', '{}');
eq('a dead daemon is the collector\'s words too', r?.error, 'changxing60-atd is not running (nothing reads the AT channel)');
eq('and busy is 0, not invented', r?.busy, 0);

print('\n== a broken collector is OUR error, not the modem\'s ==\n');
// exit 1 but no JSON error line at all: the page must not read this as the modem saying something
stage('', 1);
r = call('status', '{}');
if (r?.error != null && r?.ok == null) {
	ok('a silent broken collector is the backend\'s error');
	has(r.detail, 'exit 1') && ok('the detail says what happened');
} else {
	bad('a silent broken collector is the backend\'s error', printf('%J', r));
}
// stdout that is not the collector's one JSON line
stage('hello there', 0);
r = call('status', '{}');
if (r?.error != null && r?.ok == null)
	ok('a non-JSON answer is refused, not guessed at');
else
	bad('a non-JSON answer is refused, not guessed at', printf('%J', r));
// two lines where the contract is exactly one
stage('{"ts":1,"time":"x"}\n{"ts":2}', 0);
r = call('status', '{}');
if (r?.error != null && r?.ok == null)
	ok('a two-line answer is refused (the contract is one line)');
else
	bad('a two-line answer is refused (the contract is one line)', printf('%J', r));
// a JSON object that is not a snapshot: has an error but exited 0 -- a half-invented contract
stage('{"error":"no answer"}', 0);
r = call('status', '{}');
if (r?.error != null && r?.ok == null)
	ok('an error on a successful exit is refused');
else
	bad('an error on a successful exit is refused', printf('%J', r));
// a JSON scalar, not an object
stage('42', 0);
r = call('status', '{}');
if (r?.error != null && r?.ok == null)
	ok('a JSON scalar is refused');
else
	bad('a JSON scalar is refused', printf('%J', r));

print('\n== all nulls survive a hostile snapshot verbatim ==\n');
// a round where the modem answered but every derived field is null: still ok 1, and the nulls must
// reach the page as nulls -- this is the shape --fast gives for the engineering section
const ALLNULL = {
	ts: 1760000001, time: '2026-10-16T12:00:01Z', cfun: null,
	reg: { stat: null, tac: null, cid: null, act: null },
	reg5: { stat: null, tac: null, cid: null, act: null },
	ops: { name: null, plmn: null, act: null },
	eng_skip: 'fast',
	serving: { lte: null, nr: null },
	sig: { source: 'none', rsrp: null, rsrq: null, sinr: null, rssi: null },
	csq: { rssi: null, ber: null },
	cesq: { rsrp: null, rsrq: null },
	neighbours: { lte: null, nr: null },
	traffic: { iface: 'sipa_eth0', present: 0, operstate: null,
	           rx_bytes: null, tx_bytes: null, rx_packets: null, tx_packets: null }
};
stage(sprintf('%J', ALLNULL), 0);
r = call('status', '{"args":{"fast":true}}');
eq('an all-null round is still ok 1 (the modem did answer)', r?.ok, 1);
jdeep('and every null is still null on the far side', r?.snap, ALLNULL);
eq('cfun null did not become 0', r?.snap?.cfun, null);
eq('traffic counters null on a missing iface did not become 0', r?.snap?.traffic?.rx_bytes, null);
eq('and present is the 0 it was (a real answer about the interface)', r?.snap?.traffic?.present, 0);
eq('the fast tier was asked for', trim(fs.readfile(DIALED) ?? ''), '--fast --json');

print('\n');
if (fails == 0)
	print('all passed\n');
else
	print(fails + ' FAILED\n');
exit(fails > 0 ? 1 : 0);
