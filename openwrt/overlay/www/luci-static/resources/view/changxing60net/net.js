'use strict';
'require view';
'require rpc';
'require ui';
'require dom';

// The cell status page: one snapshot of the cellular link -- registration, operator, serving cell,
// signal quality, neighbours and the traffic counters -- read through the changxing60net rpcd
// backend (usr/share/rpcd/ucode/changxing60net.uc), which runs the collector
// /opt/changxing60/bin/changxing60-net-status --json and hands its JSON on verbatim as a value.
//
// The page has one rule it cannot break: a field the modem did not answer is UNKNOWN, never 0. The
// collector guarantees null for every unanswered field; the backend hands nulls through; and this
// file's one rendering helper (val below) prints null/absent as an em dash -- never a zero, never an
// empty cell. An RSRP of 0 dBm is 1000x stronger than anything a phone ever sees; printing it for an
// unanswered read is the one lie that makes a status page worse than none. The same rule one level
// up: a whole round that answered nothing arrives as ok:0 with the collector's own error sentence,
// and the page says what the collector said -- it never invents "no signal" out of "no answer".
//
// The page is read-only. Nothing here can write to the modem, and that is a property of the chain
// (the backend has no write method at all), not of a checkbox that could be un-checked.
//
// Two buttons: a full refresh (the whole round, engineering pages and neighbours included) and a
// fast one (the cheap tier: the collector then skips the engineering reads, says so in eng_skip,
// and the page shows "not asked" rather than pretending the modem reported nothing). The fast tier
// exists because the engineering reads take the AT channel longer, and the channel is shared with
// the SMS sender and the call engine.

var callStatus = rpc.declare({ object: 'changxing60net', method: 'status' });
var callFast = rpc.declare({ object: 'changxing60net', method: 'fast' });

var UNKNOWN = '—';

// val(v, unit): one field as it may be shown. null / absent / '' -> the em dash; otherwise the value
// and the unit. This is the ONLY place a field reaches the screen as text, so it is the only place
// the null rule can be kept or broken.
function val(v, unit) {
	if (v == null || v === '')
		return UNKNOWN;
	return unit ? '%s %s'.format(v, unit) : '%s'.format(v);
}

// fmtBytes(n): a byte counter as a human reads it. A null is a null -- the caller decides, and this
// helper is only ever reached with a number.
function fmtBytes(n) {
	if (n == null || !isFinite(n))
		return UNKNOWN;
	if (n < 1024)
		return '%d B'.format(n);
	if (n < 1048576)
		return '%.1f kB'.format(n / 1024);
	if (n < 1073741824)
		return '%.1f MB'.format(n / 1048576);
	return '%.2f GB'.format(n / 1073741824);
}

// statw(stat): a registration state in words (27.007): 1 home, 5 roaming, 10 roaming (no service
// after E-UTRA). Unknown stays unknown; a state this page has no word for is shown as its number,
// never hidden.
function statw(stat) {
	switch (stat) {
	case 1: return _('home');
	case 5: return _('roaming');
	case 10: return _('roaming (no service)');
	case null: case undefined: return UNKNOWN;
	default: return _('state %s').format(val(stat));
	}
}

// actw(act): an access technology in words where this family has a known one. AcT 7 = LTE,
// 11 = NR SA, 13 = EN-DC (the mapping the collector's own header documents); anything else is its
// number -- an unlisted AcT is a fact about the network, not a blank.
function actw(act) {
	switch (act) {
	case 7: return 'LTE';
	case 11: return 'NR (SA)';
	case 13: return 'EN-DC';
	case null: case undefined: return UNKNOWN;
	default: return 'AcT ' + val(act);
	}
}

// engWhy(skip): what eng_skip means in a human sentence. null -> the reads were made (an absent
// serving cell is then the modem's own answer, and the page does NOT say "not asked");
// 'fast' / 'unregistered' -> this page says who decided not to ask, because a "the modem did not
// report" would be a claim about the modem it never got the chance to make.
function engWhy(skip) {
	switch (skip) {
	case 'fast': return _('Not asked (fast refresh)');
	case 'unregistered': return _('Not asked (the modem is not on a cell)');
	default: return _('The modem did not report one');
	}
}

return view.extend({
	// snap: the last snapshot the page drew from ({ ts, time, cfun, reg, reg5, ops, serving, sig,
	// csq, cesq, neighbours, traffic, eng_skip } -- see the collector's header for every field)
	snap: null,
	fastTier: false,

	load: function() {
		return L.resolveDefault(callStatus(), { error: _('The status service did not answer') })
			.then(L.bind(function(r) {
				this.applyReply(r);
				return this.snap;
			}, this));
	},

	// applyReply(r): the three reply shapes onto this.snap / this.fastTier:
	//   ok 1  -> a snapshot (full or fast; eng_skip 'fast' is the only thing that makes the page say
	//            "this is the fast tier" -- 'unregistered' is a different reason, spelled where it
	//            happened, and must not borrow the fast note)
	//   ok 0  -> the collector's own error sentence; the previous snapshot, if any, stays drawn -- a
	//            refused round is not a reason to blank a page the user is looking at
	//   error -> the backend itself could not run the collector; detail is ours to show
	applyReply: function(r) {
		if (r && r.ok == 1 && r.snap) {
			this.snap = r.snap;
			this.fastTier = r.snap.eng_skip == 'fast';
			this.msg = null;
		} else if (r && r.ok == 0) {
			this.msg = { cls: 'alert-message warning', text: r.error || _('The round did not answer') };
		} else {
			this.msg = {
				cls: 'alert-message error',
				text: (r && r.error ? r.error : _('The status service did not answer')) +
				      (r && r.detail ? ' (' + r.detail + ')' : '')
			};
		}
	},

	refresh: function(fast) {
		var self = this;
		return L.resolveDefault(fast ? callFast() : callStatus(), {})
			.then(function(r) {
				// a failed refresh keeps the previous snapshot drawn, so the notice below is the
				// only thing that changes -- but ok 0 on the FIRST load must not draw an empty page
				// with no explanation, hence the reply is applied before the redraw either way
				self.applyReply(r);
				self.draw();
			});
	},

	// rows(pairs): a two-column table, the page's main shape. Every value passes through val().
	rows: function(pairs) {
		return E('table', { 'class': 'table' }, pairs.map(function(p) {
			return E('tr', { 'class': 'tr' }, [
				E('td', { 'class': 'td', 'style': 'width:38%' }, p[0]),
				E('td', { 'class': 'td' }, p[1])
			]);
		}));
	},

	// cellRows(c, rat): the serving cell of one RAT as rows. c is null when the round has no answer
	// for it, and the reason (eng_skip) decides what the page says -- never a bare "none".
	cellRows: function(c, rat, skip) {
		if (!c) {
			return [
				[ rat, E('span', { 'class': 'cbi-map-descr' }, engWhy(skip)) ]
			];
		}
		var freq = (c.arfcn != null)
			? val(c.arfcn, (c.rat == 'nr' ? 'ARFCN' : (c.rat == 'lte' ? 'EARFCN' : '')))
			: val(c.earfcn, 'EARFCN');
		var bw = (c.rat == 'nr') ? val(c.bw_mhz, 'MHz') : val(c.bw);
		return [
			[ _('Band'), val(c.band) ],
			[ _('Channel'), freq ],
			[ _('PCI'), val(c.pci) ],
			[ _('RSRP'), val(c.rsrp, 'dBm') ],
			[ _('RSRQ'), val(c.rsrq, 'dB') ],
			[ _('SINR'), val(c.sinr, 'dB') ],
			[ _('Bandwidth'), bw ],
			[ _('Cell id'), val(c.cid) ],
			[ _('MCS (UL/DL)'), val(c.ul_mcs) + ' / ' + val(c.dl_mcs) ],
			[ _('BLER (UL/DL)'), val(c.ul_bler) + ' / ' + val(c.dl_bler) ]
		];
	},

	// nbTable(list, skip): the neighbour cells of one RAT. null -> not asked / not reported (and
	// the reason says which); [] -> answered, and there were none -- which is a real answer and is
	// shown as one, not as an error and not as a zero.
	nbTable: function(list, skip) {
		var self = this;
		if (list == null)
			return E('p', { 'class': 'cbi-map-descr' }, engWhy(skip));
		if (!list.length)
			return E('p', { 'class': 'cbi-map-descr' },
				_('The modem answered: no neighbour cell on this RAT right now.'));
		return E('table', { 'class': 'table' }, [
			E('tr', { 'class': 'tr table-titles' }, [
				E('th', { 'class': 'th' }, _('RAT')),
				E('th', { 'class': 'th' }, _('Band')),
				E('th', { 'class': 'th' }, _('ARFCN')),
				E('th', { 'class': 'th' }, _('PCI')),
				E('th', { 'class': 'th' }, _('RSRP')),
				E('th', { 'class': 'th' }, _('RSRQ')),
				E('th', { 'class': 'th' }, _('SINR'))
			])
		].concat(list.map(function(c) {
			return E('tr', { 'class': 'tr' }, [
				E('td', { 'class': 'td' }, (c.rat || '').toUpperCase() || UNKNOWN),
				E('td', { 'class': 'td' }, val(c.band)),
				E('td', { 'class': 'td' }, val(c.arfcn)),
				E('td', { 'class': 'td' }, val(c.pci)),
				E('td', { 'class': 'td' }, val(c.rsrp, 'dBm')),
				E('td', { 'class': 'td' }, val(c.rsrq, 'dB')),
				E('td', { 'class': 'td' }, val(c.sinr, 'dB'))
			]);
		})));
	},

	draw: function() {
		var self = this, s = this.snap || {};
		dom.content(this.msgBox, this.msg
			? E('div', { 'class': this.msg.cls }, this.msg.text)
			: '');
		dom.content(this.dataBox, this.drawData(s));
	},

	drawData: function(s) {
		var self = this;
		var skip = s.eng_skip == null ? null : s.eng_skip;

		// -- the radio and the registration
		var reg = s.reg || {}, reg5 = s.reg5 || {}, ops = s.ops || {};
		var radio = this.rows([
			// cfun 1 = on, 0 = off; 0 is a real answer and must not fall into the "on" arm of a
			// truthiness test -- which is why the order here is 1, 0, everything else
			[ _('Radio'), (s.cfun == 1) ? _('on (CFUN 1)') :
			              (s.cfun == 0) ? _('off (CFUN 0)') : UNKNOWN ],
			[ _('LTE registration'), statw(reg.stat) + ' — TAC ' + val(reg.tac) +
				', cell ' + val(reg.cid) + ', ' + actw(reg.act) ],
			[ _('NR registration'), statw(reg5.stat) + ' — TAC ' + val(reg5.tac) +
				', cell ' + val(reg5.cid) + ', ' + actw(reg5.act) ],
			[ _('Operator'), ops.name != null ? val(ops.name) :
			                  (ops.plmn != null ? _('PLMN %s').format(ops.plmn) : UNKNOWN),
			  ' · ' + actw(ops.act) ]
		]);

		// -- signal quality: the summary first (preferred source), then the two raw readings
		var sig = s.sig || {};
		var signal = this.rows([
			[ _('RSRP'), val(sig.rsrp, 'dBm') ],
			[ _('RSRQ'), val(sig.rsrq, 'dB') ],
			[ _('SINR'), val(sig.sinr, 'dB') ],
			[ _('RSSI'), val(sig.rssi, 'dBm') ]
		]);
		var sigSrcNote = (sig.source && sig.source != 'none')
			? _('Source: %s (best tier that answered)').format(sig.source)
			: E('span', { 'class': 'cbi-map-descr' }, _('No signal reading answered.'));

		// -- traffic: present 0 is "no interface" and is said, never zeroed counters
		var t = s.traffic || {};
		var traffic;
		if (t.present == 1) {
			traffic = this.rows([
				[ _('Interface'), val(t.iface) + ' (' + val(t.operstate) + ')' ],
				[ _('Received'), fmtBytes(t.rx_bytes) + ' (' + val(t.rx_packets) + ')' ],
				[ _('Sent'), fmtBytes(t.tx_bytes) + ' (' + val(t.tx_packets) + ')' ]
			]);
		} else {
			traffic = E('p', { 'class': 'cbi-map-descr' },
				_('The data interface %s is not present right now.').format(val(t.iface)));
		}

		return E('div', {}, [
			E('h3', {}, _('Radio and registration')),
			radio,
			E('h3', {}, _('Signal quality')),
			signal,
			E('div', { 'class': 'cbi-map-descr' }, sigSrcNote),
			E('h3', {}, _('Serving cell — LTE')),
			this.rows(this.cellRows(s.serving ? s.serving.lte : null, 'LTE', skip)),
			E('h3', {}, _('Serving cell — NR')),
			this.rows(this.cellRows(s.serving ? s.serving.nr : null, 'NR', skip)),
			E('h3', {}, _('Neighbour cells — LTE')),
			this.nbTable(s.neighbours ? s.neighbours.lte : null, skip),
			E('h3', {}, _('Neighbour cells — NR')),
			this.nbTable(s.neighbours ? s.neighbours.nr : null, skip),
			E('h3', {}, _('Data traffic')),
			traffic,
			E('p', { 'class': 'cbi-map-descr' },
				_('Snapshot taken at %s (UTC). A field shown as %s is one the modem did not answer - not a zero.').format(val(s.time), UNKNOWN) +
				(this.fastTier ? ' ' + _('This is the fast tier: the engineering reads were not asked; a full refresh asks them.') : '')),
		]);
	},

	render: function() {
		var self = this;
		this.msgBox = E('div', {});
		this.dataBox = E('div', {});

		var ret = E('div', { 'class': 'cbi-map' }, [
			E('h2', {}, _('Cell status')),
			E('div', { 'class': 'cbi-map-descr' }, _(
				'One snapshot of the cellular link, read out of the modem through the AT channel. ' +
				'The page is read-only: nothing on it can write to the modem. A full refresh asks the ' +
				'engineering pages (serving and neighbour cells); the fast one reads only the cheap tier ' +
				'and leaves the channel free for a send or a call.')),
			this.msgBox,
			E('div', { 'class': 'cbi-section-actions' }, [
				E('button', {
					'class': 'btn cbi-button cbi-button-apply',
					'click': ui.createHandlerFn(self, function() { return self.refresh(false); })
				}, _('Refresh (full round)')),
				' ',
				E('button', {
					'class': 'btn cbi-button cbi-button-neutral',
					'click': ui.createHandlerFn(self, function() { return self.refresh(true); })
				}, _('Fast refresh'))
			]),
			this.dataBox
		]);

		this.draw();
		return ret;
	},

	handleSaveApply: null,
	handleSave: null,
	handleReset: null
});
