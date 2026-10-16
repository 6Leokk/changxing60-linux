'use strict';
'require view';
'require rpc';
'require ui';
'require dom';

// The forwarding half of the SMS settings. Everything here talks to the changxing60fwd rpcd backend
// (usr/share/rpcd/ucode/changxing60fwd.uc), which owns /etc/changxing60/sms-forward.conf -- the file the
// delivery engine (rootfs/overlay/opt/changxing60/bin/changxing60-sms-forward) reads before it sends a
// pooled message on to a webhook, a Telegram chat, an e-mail address or another phone.
//
// What this page never sees: the actual secrets. The backend answers forward_get with the placeholder
// "(kept)" wherever the stored configuration holds a token, a URL, a header value or a password, and
// forward_set treats a field that still says "(kept)" as "keep what is stored". So a read-only session can
// look at everything the page shows -- and still never learn a secret -- and saving an untouched form
// changes nothing. Clearing a field and saving is how a secret is removed.
//
// Like sms.js this is deliberately self-contained: no upstream mu300/common.js, no shared helpers, plain
// DOM through the same E()/dom pieces the core view machinery provides. The form is drawn once per visit
// and left alone; a reload after a save or a test replaces only the log, so a half-edited form is never
// taken away.

var callGet = rpc.declare({ object: 'changxing60fwd', method: 'forward_get' });
var callSet = rpc.declare({ object: 'changxing60fwd', method: 'forward_set', params: [ 'cfg' ] });
var callTest = rpc.declare({ object: 'changxing60fwd', method: 'forward_test' });
var callGate = rpc.declare({ object: 'changxing60fwd', method: 'forward_gate' });
var callLog = rpc.declare({ object: 'changxing60fwd', method: 'forward_log' });
var callLogClear = rpc.declare({ object: 'changxing60fwd', method: 'forward_log_clear' });
var callStatus = rpc.declare({ object: 'changxing60fwd', method: 'forward_status' });

var KEPT = '(kept)';

// the engine's default template, as forward_get reports it when nothing is stored
var TEMPLATE_DEFAULT = '{text}\n-- {sender}, {time} ({device})';

return view.extend({
	// the form state, filled by load(): one object with the fields forward_get reports
	cfg: {},
	logRows: [],
	status: {},

	load: function() {
		return Promise.all([
			L.resolveDefault(callGet(), { error: _('The forwarding service did not answer') }),
			L.resolveDefault(callLog(), { rows: [] }),
			L.resolveDefault(callStatus(), { queued: 0, running: 0, email: 0 })
		]).then(L.bind(function(data) {
			var g = data[0] || {};
			this.cfg = g.cfg || { error: _('The forwarding service did not answer') };
			this.logRows = (data[1] && data[1].rows) ? data[1].rows : [];
			this.status = data[2] || {};
			return this.cfg;
		}, this));
	},

	render: function() {
		// The form is built once and kept: the reloads below only replace the status line and the log.
		this.notice = E('div', { 'class': 'alert-message', 'style': 'display:none' }, '');
		this.statusBox = E('div', {});
		this.formBox = E('div', {});
		this.logBox = E('div', {});

		this.drawForm();
		this.drawStatus();
		this.drawLog();

		return E('div', { 'class': 'cbi-map' }, [
			E('h2', {}, _('SMS forwarding')),
			E('div', { 'class': 'cbi-map-descr' }, _(
				'Every message that lands in the SMS pool can be sent on to a webhook, a Telegram chat, ' +
				'an e-mail address or another phone. A delivery that fails is tried again with a growing ' +
				'wait; the attempts are in the log below. Secrets are never shown: a field that says "%s" ' +
				'holds a stored value, and saving keeps it.').format(KEPT)),
			this.notice,
			this.statusBox,
			this.formBox,
			this.logBox
		]);
	},

	setNotice: function(text, cls) {
		dom.content(this.notice, text || '');
		this.notice.className = cls || 'alert-message';
		this.notice.style.display = text ? '' : 'none';
	},

	// f(name): the input for one configuration field, found by the data-name this form tags every editable
	// element with. The form is plain DOM, so this is the whole "read the form back" story.
	f: function(name) {
		return this.formBox.querySelector('[data-name="' + name + '"]');
	},

	// checkboxes: an on/off field. Checked is the stored true, never the placeholder.
	toggle: function(name) {
		var el = this.f(name);
		return el ? el.checked : false;
	},

	// text(name): what the field now says, trimmed at both ends. A field left as "(kept)" is not sent at
	// all (the backend reads its absence as "no change"); a field cleared to '' clears the stored value.
	text: function(name) {
		var el = this.f(name);
		return el ? el.value.replace(/^\s+|\s+$/g, '') : '';
	},

	// row(label, control): one line of the form, in the same cbi-value shape the SMS page uses
	row: function(label, control) {
		return E('div', { 'class': 'cbi-value' }, [
			E('label', { 'class': 'cbi-value-title' }, label),
			E('div', { 'class': 'cbi-value-field' }, control)
		]);
	},

	drawStatus: function() {
		var s = this.status;
		var bits = [];
		if (s.queued)
			bits.push(_('%d message(s) waiting to be delivered').format(s.queued));
		if (s.running)
			bits.push(_('a delivery is running'));
		if (!s.email)
			bits.push(_('e-mail delivery is unavailable (msmtp is not installed)'));
		dom.content(this.statusBox, bits.length
			? E('div', { 'class': 'alert-message' }, bits.join(' · '))
			: '');
	},

	drawForm: function() {
		var self = this, c = this.cfg;

		if (c && c.error) {
			dom.content(this.formBox, E('div', { 'class': 'alert-message warning' }, c.error));
			return;
		}

		var en = E('input', { 'type': 'checkbox', 'data-name': 'enabled' });
		en.checked = !!c.enabled;
		var wh = E('input', { 'type': 'checkbox', 'data-name': 'webhook' });
		wh.checked = !!c.webhook;
		var tg = E('input', { 'type': 'checkbox', 'data-name': 'telegram' });
		tg.checked = !!c.telegram;
		var em = E('input', { 'type': 'checkbox', 'data-name': 'email' });
		em.checked = !!c.email;
		var sm = E('input', { 'type': 'checkbox', 'data-name': 'sms' });
		sm.checked = !!c.sms;

		var tpl = E('textarea', { 'class': 'cbi-input-textarea', 'rows': 3, 'data-name': 'template' });
		tpl.value = c.template || TEMPLATE_DEFAULT;
		var allow = E('textarea', { 'class': 'cbi-input-textarea', 'rows': 2, 'data-name': 'allow',
			'placeholder': _('one sender per line; * matches the rest of a number') });
		allow.value = (c.allow || []).join('\n');
		var deny = E('textarea', { 'class': 'cbi-input-textarea', 'rows': 2, 'data-name': 'deny',
			'placeholder': _('one sender per line; * matches the rest of a number') });
		deny.value = (c.deny || []).join('\n');
		var kw = E('textarea', { 'class': 'cbi-input-textarea', 'rows': 2, 'data-name': 'keyword',
			'placeholder': _('one word per line; leave empty to forward everything') });
		kw.value = (c.keyword || []).join('\n');

		var whUrl = E('input', { 'class': 'cbi-input-text', 'type': 'text', 'data-name': 'webhook_url',
			'placeholder': KEPT, 'autocomplete': 'off' });
		whUrl.value = c.webhook_url || '';
		var whFmt = E('select', { 'class': 'cbi-input-select', 'data-name': 'webhook_format' }, [
			E('option', { 'value': 'json' }, _('JSON')),
			E('option', { 'value': 'form' }, _('Form (urlencoded)')),
			E('option', { 'value': 'text' }, _('Plain text'))
		]);
		whFmt.value = c.webhook_format || 'json';
		var whHdr = E('textarea', { 'class': 'cbi-input-textarea', 'rows': 2, 'data-name': 'webhook_header',
			'placeholder': _('One header per line, "Name: value"') });
		whHdr.value = c.webhook_header || '';
		var whBody = E('textarea', { 'class': 'cbi-input-textarea', 'rows': 3, 'data-name': 'webhook_body',
			'placeholder': _('leave empty for the standard body of the format chosen above') });
		whBody.value = c.webhook_body || '';
		var whExpect = E('input', { 'class': 'cbi-input-text', 'type': 'text', 'data-name': 'webhook_expect',
			'placeholder': _('e.g. ok=true; empty means any 2xx is a delivery') });
		whExpect.value = c.webhook_expect || '';

		var tgToken = E('input', { 'class': 'cbi-input-text', 'type': 'text', 'data-name': 'telegram_token',
			'placeholder': KEPT, 'autocomplete': 'off' });
		tgToken.value = c.telegram_token || '';
		var tgChat = E('input', { 'class': 'cbi-input-text', 'type': 'text', 'data-name': 'telegram_chat',
			'placeholder': _('@channelname or chat id') });
		tgChat.value = c.telegram_chat || '';

		var emHost = E('input', { 'class': 'cbi-input-text', 'type': 'text', 'data-name': 'email_host',
			'placeholder': _('smtp.example.com') });
		emHost.value = c.email_host || '';
		var emPort = E('input', { 'class': 'cbi-input-text', 'type': 'text', 'data-name': 'email_port' });
		emPort.value = c.email_port || '587';
		var emTls = E('select', { 'class': 'cbi-input-select', 'data-name': 'email_tls' }, [
			E('option', { 'value': 'starttls' }, _('STARTTLS')),
			E('option', { 'value': 'tls' }, _('TLS')),
			E('option', { 'value': 'off' }, _('None'))
		]);
		emTls.value = c.email_tls || 'starttls';
		var emUser = E('input', { 'class': 'cbi-input-text', 'type': 'text', 'data-name': 'email_user',
			'autocomplete': 'off' });
		emUser.value = c.email_user || '';
		var emPass = E('input', { 'class': 'cbi-input-text', 'type': 'text', 'data-name': 'email_password',
			'placeholder': KEPT, 'autocomplete': 'off' });
		emPass.value = c.email_password || '';
		var emFrom = E('input', { 'class': 'cbi-input-text', 'type': 'text', 'data-name': 'email_from' });
		emFrom.value = c.email_from || '';
		var emTo = E('input', { 'class': 'cbi-input-text', 'type': 'text', 'data-name': 'email_to' });
		emTo.value = c.email_to || '';

		var smNum = E('input', { 'class': 'cbi-input-text', 'type': 'text', 'data-name': 'sms_number' });
		smNum.value = c.sms_number || '';

		var box = function(title, check, ctl) {
			return E('div', { 'class': 'cbi-section' }, [
				E('h3', {}, [ check, ' ', title ]),
				ctl
			]);
		};

		this.formBox.appendChild(E('div', {}, [
			E('div', { 'class': 'cbi-section' }, [
				E('h3', {}, _('Forwarding')),
				this.row(_('Enable forwarding'), en),
				this.row(_('Message template'), tpl),
				E('div', { 'class': 'cbi-value-description' }, _(
					'Placeholders: {text} {sender} {time} {device} {message}.')),
				this.row(_('Only these senders'), allow),
				this.row(_('Never these senders'), deny),
				this.row(_('Only messages containing'), kw)
			]),
			box(_('Webhook'), wh, E('div', {}, [
				this.row(_('URL'), whUrl),
				this.row(_('Format'), whFmt),
				this.row(_('Headers'), whHdr),
				this.row(_('Body template'), whBody),
				this.row(_('Check the answer'), whExpect)
			])),
			box(_('Telegram'), tg, E('div', {}, [
				this.row(_('Bot token'), tgToken),
				this.row(_('Chat'), tgChat)
			])),
			box(_('E-mail'), em, E('div', {}, [
				this.row(_('Server'), emHost),
				this.row(_('Port'), emPort),
				this.row(_('Encryption'), emTls),
				this.row(_('User'), emUser),
				this.row(_('Password'), emPass),
				this.row(_('From'), emFrom),
				this.row(_('To'), emTo)
			])),
			box(_('Forward to another phone'), sm, E('div', {}, [
				this.row(_('Number'), smNum)
			])),
			E('div', { 'class': 'cbi-section' }, [
				E('div', { 'class': 'cbi-section-actions' }, [
					E('button', {
						'class': 'btn cbi-button cbi-button-apply',
						'click': ui.createHandlerFn(self, function() { return self.save(); })
					}, _('Save')),
					' ',
					E('button', {
						'class': 'btn cbi-button cbi-button-action',
						'click': ui.createHandlerFn(self, function() { return self.test(); })
					}, _('Send test message'))
				])
			])
		]));
	},

	// collect(): the form into the object forward_set takes. The rules:
	//   - a checkbox is always sent: on and off are both meaningful
	//   - a text field is sent only when it differs from what forward_get reported, so a field left as
	//     "(kept)" is absent and the backend keeps the stored value
	//   - the filter lists go as arrays of lines
	collect: function() {
		var self = this, c = this.cfg, out = {};

		out.enabled = self.toggle('enabled');
		out.webhook = self.toggle('webhook');
		out.telegram = self.toggle('telegram');
		out.email = self.toggle('email');
		out.sms = self.toggle('sms');

		var tpl = self.text('template');
		if (tpl !== ((c.template || TEMPLATE_DEFAULT).replace(/^\s+|\s+$/g, '')))
			out.template = tpl;

		var linesOf = function(name) {
			var v = self.f(name).value.split(/\n/);
			var r = [];
			for (var i = 0; i < v.length; i++) {
				var s = v[i].replace(/^\s+|\s+$/g, '');
				if (s !== '')
					r.push(s);
			}
			return r;
		};
		['allow', 'deny', 'keyword'].forEach(function(k) {
			var v = linesOf(k);
			if (v.join('\n') !== (c[k] || []).join('\n'))
				out[k] = v;
		});

		// simple(name, current): send when the field changed; "current" is what forward_get reported
		var simple = function(name, current) {
			var v = self.text(name);
			if (v !== (current || ''))
				out[name] = v;
		};

		simple('webhook_url', c.webhook_url);
		var fmt = self.f('webhook_format').value;
		if (fmt !== (c.webhook_format || 'json'))
			out.webhook_format = fmt;
		// the headers keep their newlines: the backend splits them into lines itself, and a "(kept)" value
		// in one line keeps the stored value of that one header
		var hdr = self.f('webhook_header').value.replace(/\s+$/, '');
		if (hdr !== (c.webhook_header || ''))
			out.webhook_header = hdr;
		var body = self.f('webhook_body').value.replace(/^\s+|\s+$/g, '');
		if (body !== (c.webhook_body || ''))
			out.webhook_body = body;
		simple('webhook_expect', c.webhook_expect);

		simple('telegram_token', c.telegram_token);
		simple('telegram_chat', c.telegram_chat);

		simple('email_host', c.email_host);
		var port = self.text('email_port');
		if (port !== (c.email_port || '587'))
			out.email_port = port;
		var tls = self.f('email_tls').value;
		if (tls !== (c.email_tls || 'starttls'))
			out.email_tls = tls;
		simple('email_user', c.email_user);
		simple('email_password', c.email_password);
		simple('email_from', c.email_from);
		simple('email_to', c.email_to);

		simple('sms_number', c.sms_number);

		return out;
	},

	save: function() {
		var self = this;
		var cfg = this.collect();
		this.setNotice(_('Saving...'), '');
		return L.resolveDefault(callSet(cfg), { error: _('The forwarding service did not answer') })
			.then(function(r) {
				if (!r || r.error) {
					self.setNotice(r && r.detail ? '%s: %s'.format(r.error, r.detail) : (r && r.error) ||
						_('The configuration was not saved'), 'alert-message warning');
					return;
				}
				self.setNotice(_('Saved. The engine picks the configuration up with the next message.'),
					'alert-message success');
				// the effective configuration may differ from what was typed (defaults filled in, a
				// "(kept)" placeholder back in place): redraw from what the backend now reports
				return L.resolveDefault(callGet(), {}).then(function(g) {
					if (g && g.cfg) {
						self.cfg = g.cfg;
						dom.content(self.formBox, '');
						self.drawForm();
					}
					self.refresh();
				});
			});
	},

	test: function() {
		var self = this;
		this.setNotice('', '');
		// the engine throttles the tests it is started for (each one is a request at will to whatever the
		// webhook now points at); the page asks first, so a refused test is a message and not a silence
		return L.resolveDefault(callGate(), null).then(function(g) {
			if (!g || !g.ok) {
				self.setNotice(g && g.error ? g.error : _('A test was started recently; wait a few seconds'),
					'alert-message warning');
				return;
			}
			return L.resolveDefault(callTest(), { error: _('The test did not start') }).then(function(r) {
				if (!r || r.error) {
					self.setNotice(r && r.error ? r.error : _('The test did not start'), 'alert-message warning');
					return;
				}
				self.setNotice(_('Test started. The result appears in the log below.'), '');
				// one delivery can wait up to a timeout per target, more than one refresh away; ask once
				// now and let the user refresh, rather than poll while the engine is still delivering
				window.setTimeout(function() { self.refresh(); }, 3000);
			});
		});
	},

	refresh: function() {
		var self = this;
		return L.resolveDefault(callLog(), { rows: [] }).then(function(r) {
			self.logRows = (r && r.rows) ? r.rows : [];
			self.drawLog();
			return L.resolveDefault(callStatus(), {}).then(function(s) {
				self.status = s || {};
				self.drawStatus();
			});
		});
	},

	clearLog: function() {
		var self = this;
		return ui.showModal(_('Clear the log'), [
			E('p', {}, _('Remove every entry from the delivery log?')),
			E('div', { 'class': 'right' }, [
				E('button', {
					'class': 'btn cbi-button cbi-button-remove',
					'click': ui.createHandlerFn(this, function() {
						ui.hideModal();
						return L.resolveDefault(callLogClear(), { error: _('Could not clear the log') })
							.then(function(r) {
								if (r && r.error)
									self.setNotice(r.error, 'alert-message warning');
								return self.refresh();
							});
					})
				}, _('Clear')),
				' ',
				E('button', { 'class': 'btn', 'click': ui.hideModal }, _('Cancel'))
			])
		]);
	},

	drawLog: function() {
		var self = this;
		var rows = this.logRows.map(function(row) {
			return E('tr', { 'class': 'tr' }, [
				E('td', {}, row.id == '-' ? '' : row.id),
				E('td', {}, row.target == '-' ? '' : row.target),
				E('td', {}, row.result),
				E('td', { 'class': 'cbi-section-table-cell' }, row.detail || '')
			]);
		});

		var table = E('table', { 'class': 'table' }, [
			E('tr', { 'class': 'tr table-titles' }, [
				E('th', { 'class': 'th' }, _('Message')),
				E('th', { 'class': 'th' }, _('Target')),
				E('th', { 'class': 'th' }, _('Result')),
				E('th', { 'class': 'th' }, _('Detail'))
			])
		].concat(rows.length ? rows : [ E('tr', { 'class': 'tr' }, [
			E('td', { 'class': 'td', 'colspan': 4 }, _('Nothing delivered yet.'))
		]) ]));

		dom.content(this.logBox, [
			E('div', { 'class': 'cbi-section' }, [
				E('h3', {}, _('Delivery log')),
				E('div', {}, _('Newest first. It says which message went where and how it ended - never the message or a secret.')),
				table,
				E('div', { 'class': 'cbi-section-actions' }, [
					E('button', {
						'class': 'btn cbi-button',
						'click': ui.createHandlerFn(self, function() { return self.refresh(); })
					}, _('Refresh')),
					' ',
					E('button', {
						'class': 'btn cbi-button cbi-button-remove',
						'click': ui.createHandlerFn(self, function() { return self.clearLog(); })
					}, _('Clear log'))
				])
			])
		]);
	},

	handleSave: null,
	handleSaveApply: null,
	handleReset: null
});
