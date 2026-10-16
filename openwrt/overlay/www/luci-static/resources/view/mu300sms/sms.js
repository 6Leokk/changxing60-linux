'use strict';
'require view';
'require rpc';
'require ui';

// The SMS page. Everything it asks for goes to the mu300sms rpcd backend (usr/share/rpcd/ucode/mu300sms.uc),
// which reads the message pool mu300-sms keeps and mu300-smsd fills. Nothing here talks to the modem: the pool is
// what the page shows, "Sync" moves the SIM's messages into it, and a send is handed off and asked after (rpcd
// would end a call long before a slow send is done). The SIM is where a received message is safe until the pool
// has it, so the pool is the right thing to read even when the modem is busy.

var callList = rpc.declare({ object: 'mu300sms', method: 'list', params: [ 'page' ] });
var callShow = rpc.declare({ object: 'mu300sms', method: 'show', params: [ 'id' ] });
var callSend = rpc.declare({ object: 'mu300sms', method: 'send', params: [ 'num', 'text' ] });
var callJob = rpc.declare({ object: 'mu300sms', method: 'job' });
var callSync = rpc.declare({ object: 'mu300sms', method: 'sync' });
var callDelete = rpc.declare({ object: 'mu300sms', method: 'delete', params: [ 'id', 'sim' ] });

// the poll that follows a send. It is the module's, not the view instance's: the view is rebuilt on every visit and
// on every redraw, and an interval kept on the instance would go on asking after a job for a page that is gone.
var jobTimer = null;

return view.extend({
	page: 1,

	// load() is what the dispatch calls before render(); a failure here is a page that says so, not a blank one
	load: function() {
		// a poll left over from a send started before this visit has nothing to say to this page
		if (jobTimer) {
			window.clearInterval(jobTimer);
			jobTimer = null;
		}
		return L.resolveDefault(callList(this.page), { error: _('The SMS service did not answer') });
	},

	render: function(data) {
		this.data = data || {};

		// the compose form is drawn once and left alone: a redraw must not take a half-typed message away
		this.notice = E('div', { 'class': 'alert-message' }, '');
		this.listBox = E('div', {});

		this.draw();

		return E('div', { 'class': 'cbi-map' }, [
			E('h2', {}, _('SMS')),
			E('div', { 'class': 'cbi-map-descr' }, _(
				'Messages are kept in a pool on the device, so this page reads files and never waits for the modem. ' +
				'Sync moves what is on the SIM into the pool; a message is only removed from the SIM once the pool has it.')),
			this.notice,
			this.compose(),
			this.listBox
		]);
	},

	compose: function() {
		var self = this;
		var num = E('input', { 'class': 'cbi-input-text', 'type': 'text', 'placeholder': _('+8613800138000') });
		var text = E('textarea', { 'class': 'cbi-input-textarea', 'rows': 4, 'placeholder': _('Message') });

		return E('div', { 'class': 'cbi-section' }, [
			E('h3', {}, _('Send')),
			E('div', { 'class': 'cbi-value' }, [
				E('label', { 'class': 'cbi-value-title' }, _('Number')),
				E('div', { 'class': 'cbi-value-field' }, num)
			]),
			E('div', { 'class': 'cbi-value' }, [
				E('label', { 'class': 'cbi-value-title' }, _('Message')),
				E('div', { 'class': 'cbi-value-field' }, text)
			]),
			E('div', { 'class': 'cbi-value' }, [
				E('div', { 'class': 'cbi-value-field' }, [
					E('button', {
						'class': 'btn cbi-button cbi-button-action',
						'click': ui.createHandlerFn(this, function() {
							return self.send(num.value, text.value);
						})
					}, _('Send'))
				])
			])
		]);
	},

	send: function(num, text) {
		var self = this;
		this.setNotice('', '');
		return L.resolveDefault(callSend(num, text), { error: _('The SMS service did not answer') }).then(function(r) {
			if (!r || r.error) {
				self.setNotice(r && r.detail ? '%s: %s'.format(r.error, r.detail) : (r && r.error) ||
					_('The message was not sent'), 'alert-message warning');
				return;
			}
			// the send runs detached, so the answer here only means it started: ask after it until it is done
			self.setNotice(_('Sending...'), '');
			self.watchJob();
		});
	},

	// watchJob(): a send holds the AT channel for as long as the modem takes, so the page asks after it once a
	// second rather than waiting on the call. Nothing here sends anything twice: the reply is the modem's.
	watchJob: function() {
		var self = this;
		if (jobTimer)
			return;
		jobTimer = window.setInterval(function() {
			L.resolveDefault(callJob(), null).then(function(r) {
				if (r && r.running) {
					self.setNotice(_('Sending... %ds').format(r.elapsed), '');
					return;
				}
				window.clearInterval(jobTimer);
				jobTimer = null;
				if (!r || r.none) {
					self.setNotice('', '');
					return;
				}
				if (r.ok)
					self.setNotice(_('Sent.'), 'alert-message success');
				else
					self.setNotice(r.detail ? '%s: %s'.format(r.error, r.detail) : r.error,
						'alert-message warning');
				self.reload();
			});
		}, 1000);
	},

	setNotice: function(text, cls) {
		dom.content(this.notice, text || '');
		this.notice.className = cls || 'alert-message';
		this.notice.style.display = text ? '' : 'none';
	},

	reload: function() {
		var self = this;
		return callList(this.page).then(function(r) {
			self.data = r || {};
			self.draw();
		});
	},

	// draw(): the list, and the count above it. The pool is a page of messages, newest first.
	draw: function() {
		var self = this, d = this.data;

		if (d.error) {
			dom.content(this.listBox, E('div', { 'class': 'alert-message warning' },
				d.detail ? '%s: %s'.format(d.error, d.detail) : d.error));
			return;
		}

		var head = E('div', { 'class': 'cbi-section' }, [
			E('h3', {}, _('Messages')),
			E('div', {}, _('%d message(s), %d unread - page %d of %d')
				.format(d.total || 0, d.unread || 0, d.page || 1, d.pages || 1)),
			E('div', { 'class': 'cbi-section-actions' }, [
				E('button', {
					'class': 'btn cbi-button cbi-button-action',
					'click': ui.createHandlerFn(this, function() {
						return self.sync();
					})
				}, _('Sync from SIM')),
				' ',
				E('button', {
					'class': 'btn cbi-button',
					'click': ui.createHandlerFn(this, function() {
						return self.reload();
					})
				}, _('Refresh')),
				' ',
				E('button', {
					'class': 'btn cbi-button cbi-button-remove',
					'click': ui.createHandlerFn(this, function() {
						return self.remove('all', false);
					})
				}, _('Delete all'))
			])
		]);

		var rows = (d.msgs || []).map(function(m) {
			return E('tr', { 'class': 'tr' }, [
				E('td', {}, m.id),
				E('td', {}, m.dir == 'mt' ? _('received') : _('sent')),
				E('td', {}, m.status == 'unread' ? _('unread') : m.status),
				E('td', {}, m.peer || '?'),
				E('td', {}, m.time),
				E('td', { 'class': 'cbi-section-table-cell' }, [
					E('a', {
						'href': '#',
						'click': ui.createHandlerFn(self, function(ev) {
							ev.preventDefault();
							return self.open(m.id);
						})
					}, m.preview || _('(empty)'))
				]),
				E('td', {}, [
					E('button', {
						'class': 'btn cbi-button cbi-button-remove',
						'click': ui.createHandlerFn(self, function() {
							return self.remove(m.id, true);
						})
					}, _('Delete'))
				])
			]);
		});

		var table = E('table', { 'class': 'table' }, [
			E('tr', { 'class': 'tr table-titles' }, [
				E('th', { 'class': 'th' }, _('ID')),
				E('th', { 'class': 'th' }, _('Direction')),
				E('th', { 'class': 'th' }, _('Status')),
				E('th', { 'class': 'th' }, _('Number')),
				E('th', { 'class': 'th' }, _('Time')),
				E('th', { 'class': 'th' }, _('Message')),
				E('th', { 'class': 'th' }, '')
			])
		].concat(rows.length ? rows : [ E('tr', { 'class': 'tr' }, [
			E('td', { 'class': 'td', 'colspan': 7 }, _('No messages.'))
		]) ]));

		var pager = E('div', { 'class': 'cbi-section-actions' }, [
			E('button', {
				'class': 'btn cbi-button',
				'disabled': (d.page || 1) <= 1 ? '' : null,
				'click': ui.createHandlerFn(this, function() { return self.go((d.page || 1) - 1); })
			}, _('Previous')),
			' ',
			E('button', {
				'class': 'btn cbi-button',
				'disabled': (d.page || 1) >= (d.pages || 1) ? '' : null,
				'click': ui.createHandlerFn(this, function() { return self.go((d.page || 1) + 1); })
			}, _('Next'))
		]);

		dom.content(this.listBox, [ head, table, pager ]);
	},

	go: function(page) {
		if (page < 1)
			return Promise.resolve();
		this.page = page;
		return this.reload();
	},

	sync: function() {
		var self = this;
		return L.resolveDefault(callSync(), null).then(function(r) {
			if (!r || r.error) {
				self.setNotice(_('Sync did not start'), 'alert-message warning');
				return;
			}
			// it runs detached (reading the SIM takes as long as it takes), so give it a moment before looking
			self.setNotice(_('Reading the SIM...'), '');
			return new Promise(function(resolve) { window.setTimeout(resolve, 3000); })
				.then(function() {
					self.setNotice('', '');
					return self.reload();
				});
		});
	},

	// open(id): the whole message. Reading it is also what marks a received one read, so the list is redrawn.
	open: function(id) {
		var self = this;
		return L.resolveDefault(callShow(id), null).then(function(r) {
			if (!r || r.error) {
				ui.addNotification(null, E('p', {}, r && r.error ? r.error : _('Read failed')), 'warning');
				return;
			}
			return self.reload().then(function() {
				ui.showModal(_('Message %s').format(id), [
					E('pre', { 'style': 'white-space: pre-wrap; word-break: break-word;' }, r.text || ''),
					E('div', { 'class': 'right' }, [
						E('button', {
							'class': 'btn cbi-button cbi-button-remove',
							'click': ui.createHandlerFn(self, function() {
								ui.hideModal();
								return self.remove(id, true);
							})
						}, _('Delete')),
						' ',
						E('button', { 'class': 'btn', 'click': ui.hideModal }, _('Close'))
					])
				]);
			});
		});
	},

	// remove(id, sim): sim asks for the message to go from the SIM storage too - otherwise the copy left there
	// comes back on the next sync, which is the whole point of keeping it there until the pool has it
	remove: function(id, sim) {
		var self = this;
		return ui.showModal(_('Delete'), [
			E('p', {}, id == 'all'
				? _('Delete every message in the pool?')
				: _('Delete message %s?').format(id)),
			E('div', { 'class': 'right' }, [
				E('button', {
					'class': 'btn cbi-button cbi-button-remove',
					'click': ui.createHandlerFn(this, function() {
						ui.hideModal();
						return L.resolveDefault(callDelete(id, sim), { error: _('Delete failed') })
							.then(function(r) {
								if (r && r.error && !r.ok)
									ui.addNotification(null, E('p', {}, r.detail
										? '%s: %s'.format(r.error, r.detail) : r.error), 'warning');
								return self.reload();
							});
					})
				}, _('Delete')),
				' ',
				E('button', { 'class': 'btn', 'click': ui.hideModal }, _('Cancel'))
			])
		]);
	},

	handleSave: null,
	handleSaveApply: null,
	handleReset: null
});
