'use strict';
'require view';
'require rpc';
'require ui';

// What the USB cable is for. One switch, two states, and the reason each one is what it is.
//
// Everything here goes through the changxing60usb rpcd backend (usr/share/rpcd/ucode/changxing60usb.uc), which runs
// /opt/changxing60/bin/changxing60-usb-mode and reads back what it wrote. The page deliberately cannot set the mode
// itself: the mode is dhcp.lan's options, that script is the only thing that writes them, and a page with its
// own opinion of the current mode is a page that shows "share" while the PC's packets go nowhere.
//
// Both directions are safe to press. 192.168.77.1 stays on-link whatever the mode and whatever state the PC's
// routing table is in, so the cable that just switched the mode is also the way back -- which is exactly why
// this is a page and not a config file somebody edits over ssh.

var callStatus = rpc.declare({ object: 'changxing60usb', method: 'status' });
var callSet = rpc.declare({ object: 'changxing60usb', method: 'set', params: [ 'mode' ] });

// fmtAge(expiry): how long the lease has left, from the absolute expiry dnsmasq writes
function fmtAge(expiry) {
	var s = (expiry || 0) - Math.floor(Date.now() / 1000);
	if (!isFinite(s))
		return '';
	if (s <= 0)
		return _('expired');
	var h = Math.floor(s / 3600), m = Math.floor((s % 3600) / 60);
	return (h > 0 ? h + 'h ' : '') + m + 'm';
}

return view.extend({
	load: function() {
		return L.resolveDefault(callStatus(), { error: _('The USB link service did not answer') });
	},

	// switchTo(mode): the reply *is* the new state, so it is drawn directly instead of re-fetched. A refusal
	// arrives as { error } and is shown as one -- the switch either took or it did not, and saying which is
	// the whole job of this page.
	switchTo: function(mode) {
		var self = this;
		ui.showModal(_('Switching the USB link'), [
			E('p', { 'class': 'spinning' }, _('Restarting the DHCP and IPv6 servers...'))
		]);
		return callSet(mode).then(function(r) {
			ui.hideModal();
			if (r && r.error) {
				ui.addNotification(null, E('p', {}, r.error + (r.detail ? ' (' + r.detail + ')' : '')), 'error');
				return self.refresh();
			}
			self.draw(r);
			ui.addNotification(null, E('p', {}, _('The USB link is now in %s mode').format(r.mode)), 'info');
		}).catch(function(e) {
			ui.hideModal();
			ui.addNotification(null, E('p', {}, e.message || e), 'error');
		});
	},

	refresh: function() {
		var self = this;
		return callStatus().then(function(r) { self.draw(r); });
	},

	// draw(d): repaint the parts that carry state. The buttons are rebuilt too -- which one is pressed is the
	// state, and leaving a stale radio checked would be the page lying about the device.
	draw: function(d) {
		var self = this;
		this.data = d || {};

		if (d && d.error) {
			this.statusBox.replaceChildren(E('div', { 'class': 'alert-message error' }, d.error));
			this.modeBox.replaceChildren();
			return;
		}

		var mode = d.mode;
		var btn = function(m, title, desc) {
			return E('button', {
				'class': 'btn cbi-button ' + (mode === m ? 'cbi-button-action' : 'cbi-button-neutral'),
				'click': ui.createHandlerFn(self, function() { return self.switchTo(m); }),
				'style': 'text-align:left;white-space:normal;margin:0 0 .5em 0;width:100%'
			}, [
				E('strong', {}, title),
				E('br'),
				E('span', { 'class': 'cbi-map-descr' }, desc)
			]);
		};

		this.modeBox.replaceChildren(
			btn('manage', _('Management link (default)'),
				_('The PC gets an address on 192.168.77.0/24 and nothing else — no router, no DNS. It keeps its ' +
				  'own uplink. This is the safe state: on Windows a router advertised here becomes a default ' +
				  'route with a lower metric than the machine\'s real one.')),
			btn('share', _('Share the connection (tethering)'),
				_('The PC is also offered 192.168.77.1 as its router and DNS, and an IPv6 address relayed from ' +
				  'the carrier, so it routes through this device. While this is on, the PC\'s internet ' +
				  'depends on this device\'s cellular WAN.')),
			E('p', { 'class': 'cbi-map-descr' },
				_('The switch cannot push anything to the PC: DHCP has no server-initiated renew that Windows ' +
				  'honours, so the PC keeps its old options until its lease expires. Share mode uses a 5-minute ' +
				  'lease for that reason — it converges within about two minutes on its own. To make it ' +
				  'immediate, run tools/win/usb-share.ps1 (or ipconfig /renew) on the PC.'))
		);

		var rows = [
			[ _('Address on the cable'), d.addr || '—' ],
			[ _('USB link'), d.link || '—' ],
			[ _('DHCP options'), d.dhcp_option || '—' ],
			[ _('IPv6 on the management link'), d.ra + ' / ' + d.dhcpv6 ],
			[ _('Lease time'), d.leasetime || '—' ]
		];

		var clients = d.clients || [];
		var clientBox;
		if (!clients.length)
			clientBox = E('p', { 'class': 'cbi-map-descr' },
				_('No client holds a lease on the management link right now.'));
		else
			clientBox = E('table', { 'class': 'table' }, [
				E('tr', { 'class': 'tr table-titles' }, [
					E('th', { 'class': 'th' }, _('Address')),
					E('th', { 'class': 'th' }, _('MAC')),
					E('th', { 'class': 'th' }, _('Hostname')),
					E('th', { 'class': 'th' }, _('Lease left'))
				])
			].concat(clients.map(function(c) {
				return E('tr', { 'class': 'tr' }, [
					E('td', { 'class': 'td' }, c.ip),
					E('td', { 'class': 'td' }, c.mac),
					E('td', { 'class': 'td' }, c.hostname || '—'),
					E('td', { 'class': 'td' }, fmtAge(c.expires))
				]);
			})));

		this.statusBox.replaceChildren(
			E('table', { 'class': 'table' }, rows.map(function(r) {
				return E('tr', { 'class': 'tr' }, [
					E('td', { 'class': 'td', 'style': 'width:40%' }, r[0]),
					E('td', { 'class': 'td' }, r[1])
				]);
			})),
			E('h3', {}, _('Clients on the cable')),
			clientBox
		);
	},

	render: function() {
		this.modeBox = E('div', {});
		this.statusBox = E('div', {});

		var ret = E('div', { 'class': 'cbi-map' }, [
			E('h2', {}, _('USB link')),
			E('div', { 'class': 'cbi-map-descr' }, _(
				'The USB cable is this device\'s management link. It can also be its uplink: switch it here and ' +
				'the PC on the other end of the cable routes through this device\'s cellular connection. ' +
				'192.168.77.1 stays reachable either way, so this page cannot lock you out.')),
			this.modeBox,
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
