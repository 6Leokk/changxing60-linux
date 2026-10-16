// Drive one method of an rpcd ucode plugin from the shell, the way rpcd does: load the plugin file, look the
// method up by its name, call it with { args: ... }, and print what it returned as JSON.
//
// The plugin files are modules: rpcd loads one and registers the object it returns, and the file itself prints
// nothing and knows nothing about being called. That makes them awkward to try out - a plugin cannot simply be
// run. This is the missing half, and it is what the SMS backend's checks use (tools/sms/test-rpcd.sh), against
// the fake AT in tools/sms/fake-at instead of a modem. It works for any plugin of this shape, not just ours.
//
//   ucode rpcd-harness.uc PLUGIN.uc METHOD [JSON]
//
// The JSON is the method's arguments, as the page would send them: {"args":{"page":2}}. The object name (the
// first key the plugin returns) is read out of the file, so it does not have to be given here twice.
'use strict';

import * as fs from 'fs';

let plugin = ARGV[0];
let method = ARGV[1];
let args = ARGV[2];

if (!plugin || !method) {
	printerr("usage: rpcd-harness.uc PLUGIN.uc METHOD [JSON]\n");
	exit(2);
}

let src = fs.readfile(plugin);
if (src == null) {
	printerr("cannot read ", plugin, ": ", fs.error(), "\n");
	exit(2);
}

// compiled as the file it is, so that its own path is what an error in it names
let chunk = loadstring(src, plugin);
if (type(chunk) != 'function') {
	printerr("cannot load ", plugin, ": ", fs.error(), "\n");
	exit(2);
}

let mod = chunk();
let objects = keys(mod ?? {});
if (length(objects) == 0) {
	printerr(plugin, " returned no object\n");
	exit(2);
}

let methods = mod[objects[0]];
let m = methods?.[method];
if (type(m?.call) != 'function') {
	printerr(objects[0], " has no method ", method, " (it has: ", join(", ", sort(keys(methods))), ")\n");
	exit(2);
}

let request = { args: {} };
if (args) {
	try {
		let parsed = json(args);
		if (type(parsed) == 'object')
			request = parsed;
	} catch (e) {
		printerr("the arguments are not JSON: ", args, "\n");
		exit(2);
	}
}
if (request.args == null)
	request.args = {};

print(sprintf("%J\n", m.call(request) ?? null));
