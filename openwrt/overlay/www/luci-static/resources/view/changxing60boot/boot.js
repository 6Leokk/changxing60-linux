'use strict';
'require view';
'require rpc';
'require ui';

// What the next reboot boots. This device carries two systems: the OpenWrt Linux installed in the
// spare flash area (bootloader slot b) and the stock Android (slot a), and exactly 32 bytes of the
// misc partition decide which one a reboot lands in. This page is the web front for
// changxing60-next-boot, the one tool that writes those bytes: it never keeps a state of its own,
// and every number shown was read back from the device after the write.
//
// Arming is not rebooting, and they are separate buttons on purpose: a device somebody is looking
// at must never restart on its own, and arming Android is one-way from inside Linux -- once the
// device boots Android, there is no web page, no ssh, no Linux at all. The way back from there is
// a PC over the USB cable (tools/changxing60-back-to-openwrt.sh), not this page, and the page says
// so before letting anybody through that door and again on the modal that follows a reboot.
//
// The safe direction stays safe: slot b is armed with retry counts and a successful Linux boot
// re-arms it every boot (changxing60-post), so a future Linux that fails to come up twice in a row
// falls back to Android by itself. Nothing on this page can touch boot_a or the partition table.

var callStatus = rpc.declare({ object: 'changxing60boot', method: 'status' });
var callSet = rpc.declare({ object: 'changxing60boot', method: 'set', params: [ 'target' ] });
var callReboot = rpc.declare({ object: 'changxing60boot', method: 'reboot' });

// name(t): a target the way a human reads it. The page would print any other word verbatim rather
// than guess at a third system.
function name(t) {
	if (t === 'linux')
		return _('OpenWrt (Linux)');
	if (t === 'android')
		return _('Android');
	return t || '—';
}

return view.extend({
	load: function() {
		return L.resolveDefault(callStatus(), { error: _('The boot target service did not answer') });
	},

	// arm(target): the reply IS the new state -- the backend re-reads the misc bytes after
	// writing them -- so it is drawn directly instead of re-fetched. A refusal arrives as { error }
	// and is shown as one: the bytes either say what was asked or the page says they do not.
	arm: function(target) {
		var self = this;
		ui.showModal(_('Applying the boot target'), [
			E('p', { 'class': 'spinning' }, _('Writing the bootloader control bytes...'))
		]);
		return callSet(target).then(function(r) {
			ui.hideModal();
			if (r && r.error) {
				ui.addNotification(null, E('p', {}, r.error + (r.detail ? ' (' + r.detail + ')' : '')), 'error');
				return self.refresh();
			}
			self.draw(r);
			ui.addNotification(null, E('p', {},
				_('The boot target is now %s. It takes effect on the next reboot.').format(name(r.target))), 'info');
		}).catch(function(e) {
			ui.hideModal();
			ui.addNotification(null, E('p', {}, e.message || e), 'error');
		});
	},

	// askAndroid: the one-way door asks first, and the question carries the whole way back in it,
	// because this dialog is the last place inside Linux where that sentence can be read.
	askAndroid: function() {
		var self = this;
		var buttons = [
			E('button', { 'class': 'btn cbi-button-neutral', 'click': ui.hideModal }, _('Cancel')),
			E('button', {
				'class': 'btn cbi-button-reset',
				'click': ui.createHandlerFn(self, function() {
					ui.hideModal();
					return self.arm('android');
				})
			}, _('Switch to Android'))
		];
		ui.showModal(_('Boot Android on the next reboot?'), [
			E('p', {}, _('Android is the device\'s own system: once a reboot lands there, this page -- and Linux as a whole -- is gone, and no click from inside it can bring Linux back. The way back is the USB cable to a PC: run tools/changxing60-back-to-openwrt.sh from the changxing60-linux repository and it re-arms slot b and reboots; the manual 32-byte recipe is in docs/changxing60/reboot-boot-slot.md. If a Linux boot ever fails twice in a row, the bootloader also falls back to Android by itself.')),
			E('div', { 'class': 'right' }, buttons)
		]);
	},

	// rebootNow: the consequence, kept separate from the arming. On success the modal stays open
	// and changes its message, because the page is about to stop existing and the reader has ~40 s
	// of uptime left to learn which of the two futures is loading.
	rebootNow: function() {
		var self = this;
		ui.showModal(_('Rebooting the device'), [
			E('p', { 'class': 'spinning' }, _('The device is going down...'))
		]);
		return callReboot().then(function(r) {
			if (r && r.error) {
				ui.hideModal();
				ui.addNotification(null, E('p', {}, r.error + (r.detail ? ' (' + r.detail + ')' : '')), 'error');
				return self.refresh();
			}
			ui.showModal(_('The device is rebooting'), [
				E('p', { 'class': 'spinning' }, _('OpenWrt answers on 192.168.77.1 again in about four minutes. If the boot target was Android, this page will not come back: run tools/changxing60-back-to-openwrt.sh from a PC over the USB cable to arm Linux again.'))
			]);
		}).catch(function(e) {
			ui.hideModal();
			ui.addNotification(null, E('p', {}, e.message || e), 'error');
		});
	},

	refresh: function() {
		var self = this;
		return callStatus().then(function(r) { self.draw(r); });
	},

	// draw(d): repaint the state box and rebuild the buttons -- which one is the current target is
	// the state, and leaving a stale one highlighted would be the page lying about the device.
	draw: function(d) {
		var self = this;
		this.data = d || {};

		if (d && d.error) {
			this.statusBox.replaceChildren(E('div', { 'class': 'alert-message error' }, d.error));
			this.applyBox.replaceChildren();
			return;
		}

		var target = d.target;
		var btn = function(t, title, desc, cls) {
			return E('button', {
				'class': 'btn cbi-button ' + cls + (target === t ? ' cbi-button-action' : ' cbi-button-neutral'),
				'click': ui.createHandlerFn(self, function() {
					if (t === 'android')
						return self.askAndroid();
					return self.arm(t);
				}),
				'style': 'text-align:left;white-space:normal;margin:0 0 .5em 0;width:100%'
			}, [
				E('strong', {}, title),
				E('br'),
				E('span', { 'class': 'cbi-map-descr' }, desc)
			]);
		};

		this.applyBox.replaceChildren(
			btn('linux', _('Boot OpenWrt (slot b, safe default)'), _('Armed with retry counts, and every successful Linux boot re-arms it: if a future boot ever fails twice in a row, the bootloader falls back to Android by itself. This is the normal state.'), ''),
			btn('android', _('Boot Android (its own system)'), _('The next reboot -- and later ones -- land in stock Android, where there is no Linux and no web page. Bringing OpenWrt back takes a PC with the USB cable: tools/changxing60-back-to-openwrt.sh.'), ' cbi-button-reset'),
			E('button', {
				'class': 'btn cbi-button cbi-button-neutral',
				'click': ui.createHandlerFn(self, function() { return self.rebootNow(); }),
				'style': 'margin:0 0 .5em 0'
			}, _('Reboot now'))
		);

		var rows = [
			[ _('Running right now'), _('OpenWrt (Linux)') ],
			[ _('Default boot'), name(target) ],
			[ _('Bootloader control (misc)'), d.bc || '—' ],
			[ _('Slot a info'), d.slot_a || '—' ],
			[ _('Slot b info'), d.slot_b || '—' ]
		];

		this.statusBox.replaceChildren(
			E('table', { 'class': 'table' }, rows.map(function(r) {
				return E('tr', { 'class': 'tr' }, [
					E('td', { 'class': 'td', 'style': 'width:40%' }, r[0]),
					E('td', { 'class': 'td cbi-value', 'style': 'word-break:break-all' }, r[1])
				]);
			}))
		);
	},

	render: function() {
		this.applyBox = E('div', {});
		this.statusBox = E('div', {});

		var ret = E('div', { 'class': 'cbi-map' }, [
			E('h2', {}, _('Boot target')),
			E('div', { 'class': 'cbi-map-descr' }, _(
				'This device boots one of two systems: the OpenWrt Linux installed in the spare flash area ' +
				'(slot b) or the stock Android (slot a). Which one the next reboot lands in is decided by ' +
				'32 bytes of the misc partition; this page writes them through changxing60-next-boot and ' +
				'shows them read back after every write. Arming and rebooting are separate buttons: ' +
				'nothing here restarts anything by itself.')),
			this.applyBox,
			E('h3', {}, _('Current state')),
			this.statusBox
		]);

		this.draw(this.data);
		return ret;
	},

	handleSaveApply: null,
	handleSave: null,
	handleReset: null
});
