#!/usr/bin/env node
// Run a LuCI view file the way luci.js runs it, and report any ReferenceError.
//
// WHY. On 2026-10-16 the user reported "后台会出现ReferenceError dom is not defined". Three of the four
// shipped panels called dom.content(...) without ever writing 'require dom'. The static guard in
// tools/check-scripts.sh catches exactly that (a module-level global used without its require), but it
// only knows the names on its list: a typo, a name from a LuCI module nobody thought of, or a global
// that does not exist at all would still get through. This runs the file instead of reading it.
//
// The trick is that LuCI's loader compiles a view with its required modules as *function parameters*:
//     function(view, rpc, ui) { 'use strict'; ... }
// so a name that was never required is not in scope, resolves against the global object, and throws.
// Reproducing that here needs no browser: build the same parameter list from the file's own require
// lines, pass a permissive stand-in for each module, and call what the file returns.
//
// The stand-ins are deliberately mindless -- a callable object that yields another one for any property
// -- so that anything the page tries to do (dom.content, ui.showModal, rpc.declare, _.format) gets
// something plausible back and execution keeps going. Errors of other kinds are then *ignored*, because
// a shim that is not a real DOM is expected to break in a hundred ways that are not our business. A
// ReferenceError is never one of them: it means a name does not exist, which is true in the browser too.
//
//   tools/luci-view-check.js FILE...     (exit 1 if any file raises ReferenceError)
'use strict';

const fs = require('fs');

// A page method that returns a promise (most of them do) can raise the ReferenceError from a .then, long
// after the try/catch around the call has returned -- as an unhandled rejection, which would take Node
// down with a stack trace instead of a verdict. Those are still ours to report, so they are collected and
// blamed on the file being checked; everything else is the stand-ins misbehaving and is dropped.
const asyncRefs = [];
process.on('unhandledRejection', (e) => {
	if (e instanceof ReferenceError) asyncRefs.push(e.message);
});

// A callable, constructible stand-in that answers every property with another one. Every symbol is left
// undefined: Array.concat checks Symbol.isConcatSpreadable on its arguments, and a stand-in that answers
// it with something truthy makes concat try to spread a fake array and die with "Cannot convert object
// to primitive value" -- a harness crash that looks like a page bug. `then` is undefined for the same
// class of reason: an object with a then function is a thenable, and render() results get awaited, which
// would hang forever on a stand-in that never settles.
function any(name) {
	const target = function () {};
	const handler = {
		get(t, prop) {
			if (typeof prop === 'symbol') return undefined;
			if (prop === 'then' || prop === 'toString') return undefined;
			return any(`${name}.${String(prop)}`);
		},
		apply() { return any(`${name}()`); },
		construct() { return any(`new ${name}`); },
	};
	return new Proxy(target, handler);
}

// luci.js globals that are real globals rather than modules: E() builds an element, _() translates.
// window/document/navigator are here because they genuinely exist in the browser and using them is not
// a bug -- leaving them out turns every timer and every hash read into a false ReferenceError, and a
// guard that cries wolf is one nobody reads.
const GLOBALS = {
	E: () => any('E()'),
	_: Object.assign(() => any('_()'), { format: () => '' }),
	L: any('L'),
	window: any('window'), document: any('document'), navigator: any('navigator'),
	// Timers are no-ops, not Node's real ones: a page that sets an interval would keep the event loop
	// alive and this script would never exit -- a harness that hangs looks exactly like a check that is
	// still working. Nothing here needs a timer to fire; the point is only to reach the offending line.
	setTimeout: () => 0, clearTimeout: () => {}, setInterval: () => 0, clearInterval: () => {},
	console, Promise, JSON, Math, Date, Object, Array, String, Number, Boolean, RegExp, Error, Symbol, Map, Set,
};

// view.extend is the one shim that must NOT be a stand-in: it returns the page object, and that object
// is the only way to reach the methods the bug lives in. Handing back a stand-in there swallows the
// literal whole and every method goes uncalled -- the harness then passes everything, including a file
// with the ReferenceError in it. Measured: with a stand-in here, the known-bad sms.js reported clean.
function shim(name) {
	if (name === 'view') return { extend: (obj) => obj };
	return any(name);
}

function check(file) {
	const source = fs.readFileSync(file, 'utf8');
	const mods = [...source.matchAll(/'require ([a-z0-9_]+)'/g)].map(m => m[1]);

	const names = [...mods, ...Object.keys(GLOBALS)];
	const values = [...mods.map(shim), ...Object.values(GLOBALS)];

	// 'use strict' inside the body is what the file itself declares; keeping it means an assignment to
	// an undeclared name throws too, which is the same behaviour the browser gives.
	let entry;
	try {
		entry = new Function(...names, source)(...values);
	} catch (e) {
		return e instanceof ReferenceError && !/^(document|window|navigator)$/.test(e.message.split(' ')[0])
			? `evaluating the file: ${e.message}`
			: null;   // any other top-level failure is the stand-ins, not the file
	}

	// The file returns view.extend({...}). Walk everything it exposes and call it: the offending line is
	// inside a method (dom.content in render()), so merely loading the file is not enough to reach it.
	const seen = new Set();
	const found = [];
	const walk = (obj, depth) => {
		if (depth > 3 || obj == null || seen.has(obj)) return;
		seen.add(obj);
		for (const key of Object.keys(obj)) {
			let v;
			try { v = obj[key]; } catch { continue; }
			if (typeof v !== 'function') { if (v && typeof v === 'object') walk(v, depth + 1); continue; }
			try {
				v.call(obj);
			} catch (e) {
				if (e instanceof ReferenceError) found.push(`${key}(): ${e.message}`);
			}
		}
	};
	walk(entry, 0);
	// The object literal returned by view.extend may itself be a class; the loader instantiates it.
	try { walk(new entry(), 0); } catch { /* not a constructor -- fine */ }

	return found.length ? found.join('; ') : null;
}

(async () => {
	let fail = 0;
	for (const file of process.argv.slice(2)) {
		asyncRefs.length = 0;
		let err;
		try { err = check(file); } catch (e) { err = `harness error: ${e.message}`; }
		// Let the page's own promises settle before reading the verdict, so an async ReferenceError is
		// seen. (Not top-level await: this file is CommonJS, and mixing the two makes Node refuse to pick
		// a module format at all -- "both require and top-level await are present".)
		await new Promise((r) => setImmediate(r));
		if (asyncRefs.length) err = [err, ...asyncRefs].filter(Boolean).join('; ');
		if (err) { fail++; console.log(`FAIL ${file}\n       ${err}`); }
	}
	if (fail) { console.log(`\n${fail} file(s) raise ReferenceError`); process.exit(1); }
	// Exit explicitly rather than falling off the end: a page is free to leave something pending, and a
	// script that hangs instead of printing its verdict is indistinguishable from one still thinking.
	process.exit(0);
})();
