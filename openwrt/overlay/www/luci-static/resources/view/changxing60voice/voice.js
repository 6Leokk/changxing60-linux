'use strict';
'require view';
'require rpc';
'require ui';
'require dom';

// The call page. Everything it asks for goes to the changxing60voice rpcd backend
// (usr/share/rpcd/uc/changxing60voice.uc), which reads the state file /run/changxing60-voice/state and talks to
// changxing60-voice. Nothing here opens the modem: the state is what changxing60-voiced heard from it (AT+CLCC),
// a dial is handed off and asked after (rpcd would end the request long before the AT channel answers), and the
// other commands are fired and judged by the state they produce -- so the page can show a refused dial as a
// failure instead of a spinner, because dialjob carries the modem's own answer back.
//
// What this page does NOT do is carry audio. A call connects, the banner says who is on it, the buttons answer,
// mute and hang up -- and neither side hears anything until the AGDSP driver stack exists
// (docs/changxing/telephony.md).

var callState = rpc.declare({ object: 'changxing60voice', method: 'state' });
var callDial = rpc.declare({ object: 'changxing60voice', method: 'dial', params: [ 'num' ] });
var callDialjob = rpc.declare({ object: 'changxing60voice', method: 'dialjob' });
var callAnswer = rpc.declare({ object: 'changxing60voice', method: 'answer' });
var callHangup = rpc.declare({ object: 'changxing60voice', method: 'hangup' });
var callDtmf = rpc.declare({ object: 'changxing60voice', method: 'dtmf', params: [ 'digits' ] });
var callMute = rpc.declare({ object: 'changxing60voice', method: 'mute', params: [ 'on' ] });
var callLog = rpc.declare({ object: 'changxing60voice', method: 'log', params: [ 'limit' ] });
var callLogclear = rpc.declare({ object: 'changxing60voice', method: 'logclear' });
var callContacts = rpc.declare({ object: 'changxing60voice', method: 'contacts' });
var callContactAdd = rpc.declare({ object: 'changxing60voice', method: 'contact_add', params: [ 'num', 'name' ] });
var callContactDel = rpc.declare({ object: 'changxing60voice', method: 'contact_del', params: [ 'num' ] });

// Both poll timers are the module's, not the view instance's: the view is rebuilt on every visit and on every
// redraw, and an interval kept on the instance would go on asking a modem about a page that is gone.
var stateTimer = null;
var jobTimer = null;

var DTMF_KEYS = [ '1', '2', '3', '4', '5', '6', '7', '8', '9', '*', '0', '#', 'A', 'B', 'C', 'D' ];

// fmtDur(s): seconds as h:mm:ss, the way a call's length is read
function fmtDur(s) {
	s = s || 0;
	var h = Math.floor(s / 3600), m = Math.floor((s % 3600) / 60), sec = s % 60;
	var p = function(n) { return (n < 10 ? '0' : '') + n; };
	return (h > 0 ? h + ':' : '') + p(m) + ':' + p(sec);
}

return view.extend({
	page: 1,
	muted: false,

	// load() is what the dispatch calls before render(); a failure here is a page that says so, not a blank one
	load: function() {
		// polls left over from a previous visit have nothing to say to this page
		if (stateTimer) {
			window.clearInterval(stateTimer);
			stateTimer = null;
		}
		if (jobTimer) {
			window.clearInterval(jobTimer);
			jobTimer = null;
		}
		var none = { error: _('The call service did not answer') };
		return Promise.all([
			L.resolveDefault(callState(), none),
			L.resolveDefault(callLog(10), none),
			L.resolveDefault(callContacts(), none)
		]).then(function(r) {
			return { status: r[0], log: r[1], contacts: r[2] };
		});
	},

	render: function(data) {
		var self = this;
		this.data = data || {};

		// the dialpad is drawn once and left alone: a redraw must not take a half-typed number away
		this.notice = E('div', { 'class': 'alert-message', 'style': 'display:none' }, '');
		this.banner = E('div', { 'class': 'alert-message', 'style': 'display:none' }, '');
		this.ringBox = E('div', { 'style': 'display:none' }, []);
		this.activeBox = E('div', { 'style': 'display:none' }, []);
		this.listBox = E('div', {});

		this.drawDialpad();
		this.drawIncall();
		this.startPoll();
		this.draw();

		return E('div', { 'class': 'cbi-map' }, [
			E('h2', {}, _('Calls')),
			E('div', { 'class': 'cbi-map-descr' }, _(
				'Place a call from here. The call state comes from the modem itself, once a second; a dial that ' +
				'the network or the modem refused is reported as a failure, not left spinning. Calls carry no ' +
				'audio yet: the driver stack for that does not exist on this build.')),
			this.notice,
			this.banner,
			this.ringBox,
			this.activeBox,
			this.dialBox,
			this.listBox
		]);
	},

	// --- polling -------------------------------------------------------------------------------------------

	startPoll: function() {
		var self = this;
		if (stateTimer)
			return;
		stateTimer = window.setInterval(function() {
			L.resolveDefault(callState(), null).then(function(s) {
				if (!s)
					return;                     // one silent answer is not a reason to blank the banner
				self.status = s;
				self.drawStatus();
			});
		}, 1000);
	},

	// watchDialjob(): a dial holds the AT channel for as long as the lock and the modem take, so the page asks
	// after it once a second rather than waiting on the request. The result is the modem's own word via the job,
	// never this page's hope; whether a call is actually up stays the state banner's business.
	watchDialjob: function() {
		var self = this;
		if (jobTimer)
			return;
		jobTimer = window.setInterval(function() {
			L.resolveDefault(callDialjob(), null).then(function(r) {
				if (r && r.running) {
					self.setNotice(_('Dialing... %ds').format(r.elapsed), '');
					return;
				}
				window.clearInterval(jobTimer);
				jobTimer = null;
				if (!r || r.none) {
					self.setNotice('', '');
					return;
				}
				if (r.ok)
					self.setNotice(_('Call placed. Waiting for the other side to answer.'), 'alert-message success');
				else if (r.busy)
					self.setNotice(_('The AT channel is busy; the call was not placed. Try again.'), 'alert-message warning');
				else
					self.setNotice(r.detail ? '%s: %s'.format(r.error, r.detail) : (r.error || _('The call was not placed')),
						'alert-message warning');
			});
		}, 1000);
	},

	// --- the state banner and the in-call controls ----------------------------------------------------------

	drawStatus: function() {
		var s = this.status || {};

		// the banner: only when there is something to say. The classes match the moment -- a ringing phone is
		// a warning you should look at, a connected call is a success.
		if (s.error) {
			this.showBanner('%s: %s'.format(s.error, s.detail || ''), 'alert-message warning');
		} else if (s.ringing) {
			this.showBanner(_('Incoming call from %s (%s)').format(s.name || _('unknown'), s.number || '?'),
				'alert-message warning');
		} else if (s.state == 'active' || s.state == 'held') {
			this.showBanner(_('In call with %s (%s) - %s').format(s.name || _('unknown'), s.number || '?', fmtDur(s.talking)),
				'alert-message success');
		} else if (s.state == 'dialing' || s.state == 'alerting') {
			this.showBanner(_('Calling %s (%s)...').format(s.name || _('unknown'), s.number || '?'), 'alert-message');
		} else {
			this.banner.style.display = 'none';
		}

		// the ringing pair: answer or refuse. Prominent, because a phone you did not hear ring is the failure
		// this page exists to prevent.
		this.ringBox.style.display = s.ringing ? '' : 'none';

		// the connected-call controls. The DTMF pad only works on an active call (the backend refuses anything
		// else), so its buttons are disabled outside one; the timer keeps running through held.
		var up = (s.state == 'active' || s.state == 'held');
		this.activeBox.style.display = up ? '' : 'none';
		this.timerEl.textContent = fmtDur(s.talking);
		for (var i = 0; i < this.dtmfBtns.length; i++)
			this.dtmfBtns[i].disabled = (s.state != 'active');
	},

	showBanner: function(text, cls) {
		this.banner.textContent = text;
		this.banner.className = cls || 'alert-message';
		this.banner.style.display = '';
	},

	drawIncall: function() {
		var self = this;

		this.timerEl = E('span', { 'style': 'font-weight:bold' }, '00:00');

		this.dtmfBtns = DTMF_KEYS.map(function(k) {
			return E('button', {
				'class': 'btn cbi-button',
				'style': 'min-width:3em',
				'click': ui.createHandlerFn(self, function() { return self.sendDtmf(k); })
			}, k);
		});

		this.muteBtn = E('button', {
			'class': 'btn cbi-button',
			'click': ui.createHandlerFn(self, function() { return self.toggleMute(); })
		}, _('Mute'));

		this.ringBox = E('div', { 'class': 'cbi-section', 'style': 'display:none' }, [
			E('div', { 'class': 'cbi-value' }, [
				E('div', { 'class': 'cbi-value-field' }, [
					E('button', {
						'class': 'btn cbi-button cbi-button-action important',
						'style': 'font-size:120%; padding:10px 24px',
						'click': ui.createHandlerFn(self, function() { return self.answer(); })
					}, _('Answer')),
					' ',
					E('button', {
						'class': 'btn cbi-button cbi-button-remove important',
						'style': 'font-size:120%; padding:10px 24px',
						'click': ui.createHandlerFn(self, function() { return self.hangup(); })
					}, _('Hang up'))
				])
			])
		]);

		this.activeBox = E('div', { 'class': 'cbi-section', 'style': 'display:none' }, [
			E('div', { 'class': 'cbi-value' }, [
				E('label', { 'class': 'cbi-value-title' }, _('Duration')),
				E('div', { 'class': 'cbi-value-field' }, this.timerEl)
			]),
			E('div', { 'class': 'cbi-value' }, [
				E('label', { 'class': 'cbi-value-title' }, _('Dial tones')),
				E('div', { 'class': 'cbi-value-field' },
					E('div', { 'style': 'display:grid; grid-template-columns:repeat(6,3.2em); gap:4px' }, this.dtmfBtns))
			]),
			E('div', { 'class': 'cbi-value' }, [
				E('label', { 'class': 'cbi-value-title' }, _('Microphone')),
				E('div', { 'class': 'cbi-value-field' }, [
					this.muteBtn,
					E('span', { 'style': 'margin-left:1em; color:#888' },
						_('The modem does not report its mute state; this reflects what you last asked for.'))
				])
			]),
			E('div', { 'class': 'cbi-value' }, [
				E('div', { 'class': 'cbi-value-field' }, [
					E('button', {
						'class': 'btn cbi-button cbi-button-remove important',
						'style': 'font-size:120%; padding:10px 24px',
						'click': ui.createHandlerFn(self, function() { return self.hangup(); })
					}, _('Hang up'))
				])
			])
		]);
	},

	// --- commands ------------------------------------------------------------------------------------------

	answer: function() {
		var self = this;
		this.setNotice('', '');
		return L.resolveDefault(callAnswer(), { error: _('The call service did not answer') }).then(function(r) {
			if (r && r.error)
				self.setNotice(r.detail ? '%s: %s'.format(r.error, r.detail) : r.error, 'alert-message warning');
			else
				self.setNotice(_('Answering...'), '');
		});
	},

	hangup: function() {
		var self = this;
		this.setNotice('', '');
		return L.resolveDefault(callHangup(), { error: _('The call service did not answer') }).then(function(r) {
			if (r && r.error)
				self.setNotice(r.detail ? '%s: %s'.format(r.error, r.detail) : r.error, 'alert-message warning');
			else
				self.setNotice(_('Hanging up...'), '');
		});
	},

	sendDtmf: function(k) {
		var self = this;
		return L.resolveDefault(callDtmf(k), { error: _('The call service did not answer') }).then(function(r) {
			if (r && r.error)
				self.setNotice(r.detail ? '%s: %s'.format(r.error, r.detail) : r.error, 'alert-message warning');
		});
	},

	toggleMute: function() {
		var self = this;
		var want = !this.muted;
		return L.resolveDefault(callMute(want), { error: _('The call service did not answer') }).then(function(r) {
			if (r && r.error) {
				self.setNotice(r.detail ? '%s: %s'.format(r.error, r.detail) : r.error, 'alert-message warning');
				return;
			}
			self.muted = want;
			self.muteBtn.textContent = want ? _('Unmute') : _('Mute');
		});
	},

	setNotice: function(text, cls) {
		this.notice.textContent = text;
		this.notice.className = cls || 'alert-message';
		this.notice.style.display = text ? '' : 'none';
	},

	// --- the dialpad -----------------------------------------------------------------------------------------

	drawDialpad: function() {
		var self = this;

		this.numInput = E('input', {
			'class': 'cbi-input-text',
			'type': 'text',
			'style': 'font-size:120%; max-width:16em',
			'placeholder': _('+8613800138000 or *100#')
		});

		// the keyboard path: type the number, press Enter. The page is this phone's only keypad -- its own
		// touchscreen is dead -- so the field has to work without the mouse too.
		this.numInput.addEventListener('keydown', function(ev) {
			if (ev.key == 'Enter') {
				ev.preventDefault();
				self.dial();
			}
		});

		// the keyboard path: type the number, press Enter. The page is this phone's only keypad -- its own
		// touchscreen is dead -- so the field has to work without the mouse too.
		this.numInput.addEventListener('keydown', function(ev) {
			if (ev.key == 'Enter') {
				ev.preventDefault();
				self.dial();
			}
		});

		this.callBtn = E('button', {
			'class': 'btn cbi-button cbi-button-action important',
			'style': 'font-size:120%; padding:10px 24px',
			'click': ui.createHandlerFn(self, function() { return self.dial(); })
		}, _('Call'));

		this.dialBox = E('div', { 'class': 'cbi-section' }, [
			E('h3', {}, _('Dial')),
			E('div', { 'class': 'cbi-value' }, [
				E('label', { 'class': 'cbi-value-title' }, _('Number')),
				E('div', { 'class': 'cbi-value-field' }, [
					this.numInput,
					' ',
					E('button', {
						'class': 'btn cbi-button',
						'title': _('Delete the last character'),
						'click': ui.createHandlerFn(self, function() { self.pressKey('backspace'); })
					}, '⌫'),
					' ',
					this.callBtn
				])
			]),
			E('div', { 'class': 'cbi-value' }, [
				E('label', { 'class': 'cbi-value-title' }, _('Keypad')),
				E('div', { 'class': 'cbi-value-field' }, this.padGrid())
			])
		]);
	},

	// padGrid(): the twelve keys. Long-pressing 0 inserts a +, the way phones spell a country code; a plain tap
	// inserts the 0. The long-press is wired with plain listeners (not ui.createHandlerFn) because it does not
	// return a promise for anything to catch.
	padGrid: function() {
		var self = this;
		var keys = [ '1', '2', '3', '4', '5', '6', '7', '8', '9', '*', '0', '#' ];
		var cells = keys.map(function(k) {
			var b = E('button', {
				'class': 'btn cbi-button',
				'style': 'min-width:3.2em; min-height:2.6em; font-size:110%',
				'click': function() {
					// a long-press has already inserted its "+" before this click arrives; without this the
					// release would append a 0 behind it
					if (k == '0' && self.longZero) {
						self.longZero = false;
						return;
					}
					self.pressKey(k);
				}
			}, k);
			if (k == '0') {
				var t = null;
				var start = function() {
					t = window.setTimeout(function() { self.longZero = true; self.pressKey('+'); }, 550);
				};
				var stop = function() { if (t) { window.clearTimeout(t); t = null; } };
				b.addEventListener('mousedown', start);
				b.addEventListener('mouseup', stop);
				b.addEventListener('mouseleave', stop);
				b.addEventListener('touchstart', start);
				b.addEventListener('touchend', stop);
			}
			return b;
		});
		return E('div', { 'style': 'display:grid; grid-template-columns:repeat(3,3.2em); gap:4px' }, cells);
	},

	pressKey: function(k) {
		if (k == 'backspace') {
			this.numInput.value = this.numInput.value.slice(0, -1);
			return;
		}
		if (k == '+') {
			// a + only makes sense at the front, and only once
			if (this.numInput.value.charAt(0) != '+')
				this.numInput.value = '+' + this.numInput.value.replace(/^\+/, '');
			return;
		}
		this.numInput.value += k;
	},

	dial: function() {
		var self = this;
		var num = (this.numInput.value || '').replace(/\s/g, '');
		if (num == '') {
			this.setNotice(_('Enter a number first.'), 'alert-message warning');
			return Promise.resolve();
		}
		this.setNotice('', '');
		return L.resolveDefault(callDial(num), { error: _('The call service did not answer') }).then(function(r) {
			if (!r || r.error) {
				self.setNotice(r && r.detail ? '%s: %s'.format(r.error, r.detail) : (r && r.error) ||
					_('The call was not placed'), 'alert-message warning');
				return;
			}
			if (r.busy) {
				self.setNotice(_('The AT channel is busy; the call was not placed. Try again.'), 'alert-message warning');
				return;
			}
			// the dial runs detached, so this only means it started: ask after it until the modem has spoken
			self.setNotice(_('Dialing...'), '');
			self.watchDialjob();
		});
	},

	// --- history and contacts -------------------------------------------------------------------------------

	draw: function() {
		var self = this, d = this.data;

		var head = E('div', { 'class': 'cbi-section' }, [
			E('h3', {}, _('Recent calls')),
			E('div', { 'class': 'cbi-section-actions' }, [
				E('button', {
					'class': 'btn cbi-button',
					'click': ui.createHandlerFn(this, function() { return self.reload(); })
				}, _('Refresh')),
				' ',
				E('button', {
					'class': 'btn cbi-button cbi-button-remove',
					'click': ui.createHandlerFn(this, function() { return self.clearLog(); })
				}, _('Clear'))
			])
		]);

		var rows = (d.log.calls || []).map(function(c) {
			var when = c.epoch > 0 ? new Date(c.epoch * 1000).toLocaleString() : '?';
			var dur = (c.status == 'answered' && c.duration > 0) ? fmtDur(c.duration) : '-';
			return E('tr', { 'class': 'tr' }, [
				E('td', {}, when),
				E('td', {}, c.dir == 'in' ? _('incoming') : _('outgoing')),
				E('td', {}, c.status),
				E('td', {}, [
					E('a', {
						'href': '#',
						'title': _('Put this number in the dial field'),
						'click': ui.createHandlerFn(self, function(ev) {
							ev.preventDefault();
							self.numInput.value = c.number;
							self.setNotice('', '');
						})
					}, c.name || c.number || '?')
				]),
				E('td', {}, dur)
			]);
		});

		var logTable = E('table', { 'class': 'table' }, [
			E('tr', { 'class': 'tr table-titles' }, [
				E('th', { 'class': 'th' }, _('When')),
				E('th', { 'class': 'th' }, _('Direction')),
				E('th', { 'class': 'th' }, _('Status')),
				E('th', { 'class': 'th' }, _('Number')),
				E('th', { 'class': 'th' }, _('Duration'))
			])
		].concat(rows.length ? rows : [ E('tr', { 'class': 'tr' }, [
			E('td', { 'class': 'td', 'colspan': 5 }, _('No calls yet.'))
		]) ]));

		var contactRows = (d.contacts.contacts || []).map(function(c) {
			return E('tr', { 'class': 'tr' }, [
				E('td', {}, [
					E('a', {
						'href': '#',
						'title': _('Put this number in the dial field'),
						'click': ui.createHandlerFn(self, function(ev) {
							ev.preventDefault();
							self.numInput.value = c.number;
							self.setNotice('', '');
						})
					}, c.number)
				]),
				E('td', {}, c.name),
				E('td', {}, [
					E('button', {
						'class': 'btn cbi-button cbi-button-remove',
						'click': ui.createHandlerFn(self, function() { return self.delContact(c.number, c.name); })
					}, _('Delete'))
				])
			]);
		});

		var contactTable = E('table', { 'class': 'table' }, [
			E('tr', { 'class': 'tr table-titles' }, [
				E('th', { 'class': 'th' }, _('Number')),
				E('th', { 'class': 'th' }, _('Name')),
				E('th', { 'class': 'th' }, '')
			])
		].concat(contactRows.length ? contactRows : [ E('tr', { 'class': 'tr' }, [
			E('td', { 'class': 'td', 'colspan': 3 }, _('No contacts.'))
		]) ]));

		this.nameInput = this.nameInput || E('input', { 'class': 'cbi-input-text', 'type': 'text', 'placeholder': _('Name') });

		var contactsSection = E('div', { 'class': 'cbi-section' }, [
			E('h3', {}, _('Contacts')),
			contactTable,
			E('div', { 'class': 'cbi-value' }, [
				E('label', { 'class': 'cbi-value-title' }, _('Save the number above')),
				E('div', { 'class': 'cbi-value-field' }, [
					this.nameInput,
					' ',
					E('button', {
						'class': 'btn cbi-button cbi-button-action',
						'click': ui.createHandlerFn(this, function() { return self.saveContact(); })
					}, _('Save'))
				])
			])
		]);

		dom.content(this.listBox, [
			head, logTable,
			E('div', { 'style': 'height:1.5em' }),
			contactsSection
		]);
	},

	reload: function() {
		var self = this;
		return Promise.all([
			L.resolveDefault(callLog(10), { calls: [] }),
			L.resolveDefault(callContacts(), { contacts: [] })
		]).then(function(r) {
			self.data.log = r[0];
			self.data.contacts = r[1];
			self.draw();
		});
	},

	clearLog: function() {
		var self = this;
		return L.resolveDefault(callLogclear(), { error: _('The call service did not answer') }).then(function(r) {
			if (r && r.error)
				self.setNotice(r.detail ? '%s: %s'.format(r.error, r.detail) : r.error, 'alert-message warning');
			return self.reload();
		});
	},

	saveContact: function() {
		var self = this;
		var num = (this.numInput.value || '').replace(/\s/g, '');
		var name = (this.nameInput.value || '').trim();
		if (num == '') {
			this.setNotice(_('Put a number in the dial field first, then name it here.'), 'alert-message warning');
			return Promise.resolve();
		}
		if (name == '') {
			this.setNotice(_('Enter a name for the number.'), 'alert-message warning');
			return Promise.resolve();
		}
		return L.resolveDefault(callContactAdd(num, name), { error: _('The call service did not answer') }).then(function(r) {
			if (r && r.error) {
				self.setNotice(r.detail ? '%s: %s'.format(r.error, r.detail) : r.error, 'alert-message warning');
				return;
			}
			self.setNotice(_('Contact saved.'), 'alert-message success');
			self.nameInput.value = '';
			return self.reload();
		});
	},

	delContact: function(num, name) {
		var self = this;
		return ui.showModal(_('Delete contact'), [
			E('p', {}, _('Delete %s (%s) from the contacts?').format(name || '', num)),
			E('div', { 'class': 'right' }, [
				E('button', {
					'class': 'btn cbi-button cbi-button-remove',
					'click': ui.createHandlerFn(this, function() {
						ui.hideModal();
						return L.resolveDefault(callContactDel(num), { error: _('The call service did not answer') })
							.then(function(r) {
								if (r && r.error)
									self.setNotice(r.detail ? '%s: %s'.format(r.error, r.detail) : r.error, 'alert-message warning');
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
