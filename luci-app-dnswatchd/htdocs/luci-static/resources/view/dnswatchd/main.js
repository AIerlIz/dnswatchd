'use strict';
'require view';
'require form';
'require uci';
'require rpc';
'require ui';

/*
 * LuCI front end for dnswatchd.
 *
 * Everything that needs privilege goes through the `dnswatchd` rpcd object. The
 * 0.1.x front end exec'd /bin/sh with a hand-built command line, which required
 * an ACL grant on the shell and managed to insert every quick-add entry twice.
 * Neither of those paths exists any more.
 */

var callStatus = rpc.declare({
	object: 'dnswatchd',
	method: 'status',
	expect: { '': {} }
});

var callOnce = rpc.declare({
	object: 'dnswatchd',
	method: 'once',
	expect: { '': {} }
});

var callTakeover = rpc.declare({
	object: 'dnswatchd',
	method: 'takeover',
	expect: { '': {} }
});

var callRollback = rpc.declare({
	object: 'dnswatchd',
	method: 'rollback',
	expect: { '': {} }
});

var callApply = rpc.declare({
	object: 'dnswatchd',
	method: 'apply',
	expect: { '': {} }
});

var callSwitch = rpc.declare({
	object: 'dnswatchd',
	method: 'switch',
	params: [ 'section' ],
	expect: { '': {} }
});

/* Measured 2026-11 from a single vantage point (Guangdong, China Telecom). The
 * numbers are a starting point for ordering, not a promise about your line. */
var PRESETS = [
	[ 'baidu',      '180.76.76.76',    'www.baidu.com', 'Baidu · ~23 ms · answers ICMP' ],
	[ 'yamucloud',  '1.1.8.8',         'www.baidu.com', 'Yamu · ~25 ms' ],
	[ 'volcengine', '180.184.1.1',     'www.baidu.com', 'Volcengine · ~28 ms' ],
	[ 'tencent',    '119.29.29.29',    'www.baidu.com', 'Tencent DNSPod · ~29 ms' ],
	[ 'tencent2',   '182.254.116.116', 'www.baidu.com', 'Tencent DNSPod backup · ~29 ms' ],
	[ 'huawei',     '122.112.208.1',   'www.baidu.com', 'Huawei Cloud · ~32 ms' ],
	[ 'dnsjia',     '101.226.4.6',     'www.baidu.com', 'DNSjia · ~32 ms' ],
	[ 'aliyun',     '223.5.5.5',       'www.baidu.com', 'Alibaba · ~49 ms' ],
	[ 'aliyun2',    '223.6.6.6',       'www.baidu.com', 'Alibaba backup · ~47 ms' ],
	[ 'onefour',    '114.114.114.114', 'www.baidu.com', '114DNS · no ICMP reply' ],
	[ 'onedns',     '117.50.11.11',    'www.baidu.com', 'OneDNS · no ICMP reply' ],
	[ 'cloudflare', '1.1.1.1',         'www.baidu.com', 'Cloudflare · poisoned from CN without a proxy' ],
	[ 'google',     '8.8.8.8',         'www.baidu.com', 'Google · poisoned from CN without a proxy' ]
];

function statusCell(value, strong) {
	return E('td', { 'class': strong ? 'th' : 'td' }, value === undefined || value === '' ? '—' : String(value));
}

function renderStatus(st) {
	var rows = [];

	rows.push(E('tr', { 'class': 'tr table-titles' }, [
		E('th', { 'class': 'th' }, _('Upstream')),
		E('th', { 'class': 'th' }, _('Address')),
		E('th', { 'class': 'th' }, _('Priority')),
		E('th', { 'class': 'th' }, _('State')),
		E('th', { 'class': 'th' }, _('Fails')),
		E('th', { 'class': 'th' }, _('Oks')),
		E('th', { 'class': 'th' }, _('RTT'))
	]));

	(st.upstreams || []).forEach(function(u) {
		rows.push(E('tr', { 'class': 'tr' }, [
			statusCell(u.section, true),
			statusCell(u.address + ':' + u.port),
			statusCell(u.priority),
			statusCell(u.status),
			statusCell(u.fails),
			statusCell(u.oks),
			statusCell(u.rtt ? u.rtt + ' ms' : '')
		]));
	});

	if (!(st.upstreams || []).length)
		rows.push(E('tr', { 'class': 'tr' }, [
			E('td', { 'class': 'td', 'colspan': 7 }, _('No upstream configured yet.'))
		]));

	var active = st.active || {};
	var dhcp = st.dhcp || {};

	var facts = [
		[ _('Watchdog'), st.enabled ? _('enabled') : _('disabled') ],
		[ _('Managing dnsmasq'), st.managed ? _('yes') : _('no') ],
		[ _('Active upstream'), active.section ? (active.section + ' (' + active.address + ')') : _('none') ],
		[ _('servers-file'), (st.servers_file || '') + ' → ' + ((dhcp.serversfile === st.servers_file) ? _('in use') : _('not used by dnsmasq')) ],
		[ _('dnsmasq upstreams'), (dhcp.servers || []).length ? (dhcp.servers || []).join(', ') : _('none') ],
		[ _('resolv.conf ignored'), dhcp.noresolv === '1' ? _('yes') : _('no') ]
	];

	return E('div', {}, [
		E('table', { 'class': 'table' }, rows),
		E('br'),
		E('table', { 'class': 'table' }, facts.map(function(f) {
			return E('tr', { 'class': 'tr' }, [
				E('td', { 'class': 'th' }, f[0]),
				E('td', { 'class': 'td' }, f[1])
			]);
		}))
	]);
}

return view.extend({
	load: function() {
		return Promise.all([
			uci.load('dnswatchd'),
			callStatus()
		]);
	},

	handleRunOnce: function() {
		ui.showModal(_('Probing'), [
			E('p', { 'class': 'spinning' }, _('Running one round against every upstream…'))
		]);

		return callOnce().then(function(res) {
			ui.hideModal();

			if (res && res.error) {
				ui.addNotification(null, E('p', {}, _('Round skipped: %s').format(res.error)), 'warning');
				return;
			}

			ui.addNotification(null, E('p', {}, _('Round finished. Reloading the page to show the new state.')), 'info');
			window.setTimeout(function() { window.location.reload(); }, 800);
		}).catch(function(err) {
			ui.hideModal();
			ui.addNotification(null, E('p', {}, _('Round failed: %s').format(err.message || err)), 'danger');
		});
	},

	handleTakeover: function() {
		var st = this.status || {};
		var dhcp = st.dhcp || {};

		var lines = [
			E('p', {}, _('This rewrites dnsmasq settings so that dnswatchd owns the upstream:')),
			E('ul', {}, [
				E('li', {}, _('Current dnsmasq upstreams (%s) are backed up, then removed.').format((dhcp.servers || []).length ? dhcp.servers.join(', ') : _('none'))),
				E('li', {}, _('servers-file is set to %s and keeps exactly one server line.').format(st.servers_file || '')),
				E('li', {}, _('resolv.conf is ignored by dnsmasq (noresolv=1), so the ISP resolvers cannot answer behind your back.')),
				E('li', {}, _('The ISP resolvers come back as an explicit, lowest-priority upstream instead.'))
			]),
			E('p', { 'class': 'alert-message warning' }, _('`dnswatchd rollback` undoes all of it.')),
			E('div', { 'class': 'right' }, [
				E('button', { 'class': 'btn', 'click': ui.hideModal }, _('Cancel')),
				' ',
				E('button', {
					'class': 'btn cbi-button-action important',
					'click': ui.createHandlerFn(this, function() {
						ui.hideModal();
						return callTakeover().then(function(res) {
							ui.addNotification(null, E('p', {}, (res && res.message) || _('Done')), res && res.ok ? 'info' : 'danger');
							window.setTimeout(function() { window.location.reload(); }, 800);
						}).catch(function(err) {
							ui.addNotification(null, E('p', {}, String(err)), 'danger');
						});
					})
				}, _('Take over'))
			])
		];

		ui.showModal(_('Take over DNS management'), lines);
	},

	handleRollback: function() {
		ui.showModal(_('Give DNS back'), [
			E('p', {}, _('Restores the dnsmasq upstreams saved by the last takeover and disables the watchdog.')),
			E('div', { 'class': 'right' }, [
				E('button', { 'class': 'btn', 'click': ui.hideModal }, _('Cancel')),
				' ',
				E('button', {
					'class': 'btn cbi-button-negative important',
					'click': ui.createHandlerFn(this, function() {
						ui.hideModal();
						return callRollback().then(function(res) {
							ui.addNotification(null, E('p', {}, (res && res.message) || _('Done')), res && res.ok ? 'info' : 'danger');
							window.setTimeout(function() { window.location.reload(); }, 800);
						}).catch(function(err) {
							ui.addNotification(null, E('p', {}, String(err)), 'danger');
						});
					})
				}, _('Roll back'))
			])
		]);
	},

	handleForceSwitch: function(section_id) {
		return callSwitch(section_id).then(function(res) {
			ui.addNotification(null, E('p', {}, res && res.ok
				? _('Now using %s.').format(section_id)
				: _('Switch failed: %s').format((res && res.error) || '')), res && res.ok ? 'info' : 'danger');
		});
	},

	handleQuickAdd: function() {
		var key = this.presetValue || '';
		var preset = null;

		PRESETS.forEach(function(p) { if (p[0] === key) preset = p; });

		if (!preset) {
			ui.addNotification(null, E('p', {}, _('Pick a preset first.')), 'warning');
			return;
		}

		var address = preset[1];
		var domain = preset[2];
		var exists = false;
		var maxPri = 0;

		uci.sections('dnswatchd', 'upstream').forEach(function(s) {
			if (uci.get('dnswatchd', s['.name'], 'address') === address)
				exists = true;

			var v = parseInt(uci.get('dnswatchd', s['.name'], 'priority') || '0', 10);
			if (v > maxPri) maxPri = v;
		});

		if (exists) {
			ui.addNotification(null, E('p', {}, _('%s is already in the list.').format(address)), 'warning');
			return;
		}

		var sid = uci.add('dnswatchd', 'upstream');

		uci.set('dnswatchd', sid, 'enabled', '1');
		uci.set('dnswatchd', sid, 'source', 'static');
		uci.set('dnswatchd', sid, 'address', address);
		uci.set('dnswatchd', sid, 'port', '53');
		uci.set('dnswatchd', sid, 'probe_domain', domain);
		uci.set('dnswatchd', sid, 'expect_mode', 'any');
		uci.set('dnswatchd', sid, 'priority', String(maxPri + 10));

		return uci.save()
			.then(function() { return callApply(); })
			.then(function(res) {
				if (res && res.ok === false) {
					ui.addNotification(null, E('p', {}, (res && res.message) || _('Apply failed')), 'danger');
					return;
				}
				window.location.reload();
			})
			.catch(function(err) {
				ui.addNotification(null, E('p', {}, _('Add failed: %s').format(err.message || err)), 'danger');
			});
	},

	render: function(data) {
		var m, s, o, self = this;

		this.status = data[1] || {};

		m = new form.Map('dnswatchd', _('DNS Watchdog'),
			_('Probes the upstream resolvers dnsmasq uses, checks that the answers land in the expected range, and switches to the next candidate when they do not.'));

		/* ---------------------------------------------------------- status */

		s = m.section(form.NamedSection, 'main', 'dnswatchd', _('Status'));
		s.anonymous = true;
		s.addremove = false;

		o = s.option(form.DummyValue, '_status_block');
		o.rawhtml = true;
		o.cfgvalue = function() { return renderStatus(self.status); };

		o = s.option(form.Button, '_runonce');
		o.inputtitle = _('Run one round');
		o.inputstyle = 'action';
		o.onclick = ui.createHandlerFn(this, 'handleRunOnce');
		o.description = _('Probes every upstream once and applies the result. Honours “dry run”.');

		o = s.option(form.Button, '_takeover');
		o.inputtitle = _('Take over DNS');
		o.inputstyle = 'action';
		o.onclick = ui.createHandlerFn(this, 'handleTakeover');
		o.description = _('Point dnsmasq at the servers-file and stop it from using resolv.conf.');

		o = s.option(form.Button, '_rollback');
		o.inputtitle = _('Give DNS back');
		o.inputstyle = 'negative';
		o.onclick = ui.createHandlerFn(this, 'handleRollback');
		o.description = _('Undo the last takeover and disable the watchdog.');

		/* ---------------------------------------------------------- settings */

		s = m.section(form.NamedSection, 'main', 'dnswatchd', _('Settings'));
		s.anonymous = true;
		s.addremove = false;

		o = s.option(form.Flag, 'enabled', _('Enable'));
		o.rmempty = false;
		o.default = '0';
		o.description = _('Master switch. Takeover turns this on for you.');

		o = s.option(form.Flag, 'dry_run', _('Dry run'));
		o.rmempty = false;
		o.default = '0';
		o.description = _('Log the decisions but never rewrite the servers-file.');

		o = s.option(form.Value, 'interval', _('Interval'), _('Seconds between rounds. Minimum 5.'));
		o.datatype = 'range(5,3600)';
		o.default = '30';
		o.placeholder = '30';

		o = s.option(form.Value, 'probe_deadline', _('Probe deadline'),
			_('Milliseconds per DNS query. A dead upstream costs at most this much per round.'));
		o.datatype = 'range(100,60000)';
		o.default = '2000';
		o.placeholder = '2000';

		o = s.option(form.Value, 'fail_threshold', _('Failures before DOWN'));
		o.datatype = 'range(1,60)';
		o.default = '2';
		o.description = _('Consecutive failures before an upstream is considered down.');

		o = s.option(form.Value, 'recover_threshold', _('Successes before UP'));
		o.datatype = 'range(1,60)';
		o.default = '2';
		o.description = _('Consecutive successes before a downed upstream is trusted again.');

		o = s.option(form.Value, 'servers_file', _('dnsmasq servers-file'),
			_('Must match the servers-file configured for dnsmasq. Takeover sets both.'));
		o.default = '/etc/dnswatchd/servers';
		o.rmempty = false;

		o = s.option(form.ListValue, 'selection', _('Selection'));
		o.value('priority', _('By priority (predictable)'));
		o.value('latency', _('By measured round-trip'));
		o.default = 'priority';
		o.rmempty = false;
		o.description = _('Priority: the lowest priority number that is up wins. Latency: the fastest DNS round-trip wins, if it beats the incumbent by the margin.');

		o = s.option(form.Value, 'latency_margin', _('Switch margin'), _('Percent. Only used by the latency selection.'));
		o.datatype = 'range(0,90)';
		o.default = '20';
		o.depends('selection', 'latency');

		o = s.option(form.Value, 'latency_switch_after', _('Rounds to win'),
			_('Only used by the latency selection. How many rounds in a row a challenger must win.'));
		o.datatype = 'range(1,10)';
		o.default = '2';
		o.depends('selection', 'latency');

		o = s.option(form.Value, 'round_budget', _('Round budget'),
			_('Percent of the interval a round may spend probing before it gives up on the rest.'));
		o.datatype = 'range(20,100)';
		o.default = '80';

		o = s.option(form.Flag, 'syslog', _('Write to syslog'));
		o.rmempty = false;
		o.default = '1';

		o = s.option(form.Flag, 'verbose', _('Verbose'));
		o.rmempty = false;
		o.default = '0';
		o.description = _('Also log the uneventful rounds.');

		/* ---------------------------------------------------------- presets */

		o = s.option(form.ListValue, '_preset', _('Add a known public resolver'),
			_('Adds an upstream entry with expect_mode=any. Edit it afterwards to match your setup.'));
		o.value('', _('— choose —'));
		PRESETS.slice().sort(function(a, b) {
			return a[1].localeCompare(b[1]);
		}).forEach(function(p) {
			o.value(p[0], p[1] + '  ' + p[3]);
		});
		o.write = function() { };
		o.onchange = function(ev, section_id, value) {
			self.presetValue = value;
		};

		o = s.option(form.Button, '_add_preset');
		o.inputtitle = _('Add');
		o.inputstyle = 'apply';
		o.onclick = ui.createHandlerFn(this, 'handleQuickAdd');

		/* ---------------------------------------------------------- upstreams */

		s = m.section(form.GridSection, 'upstream', _('Upstream resolvers'),
			_('Every enabled upstream is probed each round. Exactly one of them ends up in the servers-file — dnsmasq picks between upstreams by itself, so a second one would mean losing control of which resolver answers.'));
		s.anonymous = true;
		s.addremove = true;

		o = s.option(form.Value, 'address', _('Address'));
		o.datatype = 'ip4addr';
		o.rmempty = false;
		o.depends('source', 'static');

		o = s.option(form.Value, 'port', _('Port'));
		o.datatype = 'port';
		o.default = '53';
		o.placeholder = '53';
		o.depends('source', 'static');

		o = s.option(form.ListValue, 'source', _('Source'));
		o.value('static', _('Fixed address'));
		o.value('resolv', _('From resolv.conf.auto'));
		o.default = 'static';
		o.rmempty = false;
		o.description = _('“From resolv.conf.auto” picks up the ISP resolvers netifd hands out, one upstream per address.');

		o = s.option(form.Value, 'probe_domain', _('Probe domain'));
		o.default = 'www.baidu.com';
		o.rmempty = false;
		o.description = _('Queried as an A record. For a fake-ip proxy upstream use a name only the proxy can answer.');

		o = s.option(form.ListValue, 'expect_mode', _('Expectation'));
		o.value('in', _('Every answer inside the range'));
		o.value('not-in', _('Every answer outside the range'));
		o.value('any', _('Any answer at all'));
		o.default = 'any';
		o.rmempty = false;

		o = s.option(form.Value, 'expect_cidr', _('Expected range'),
			_('CIDR, e.g. 198.18.0.0/16 for a Clash fake-ip pool. Ignored when the expectation is “any answer”.'));
		o.placeholder = '198.18.0.0/16';
		o.depends('expect_mode', 'in');
		o.depends('expect_mode', 'not-in');

		o = s.option(form.Value, 'priority', _('Priority'), _('Lower wins.'));
		o.datatype = 'range(1,999)';
		o.default = '10';
		o.rmempty = false;

		o = s.option(form.Flag, 'enabled', _('Enabled'));
		o.rmempty = false;
		o.default = '1';

		o = s.option(form.Button, '_force');
		o.inputtitle = _('Use now');
		o.inputstyle = 'action';
		o.onclick = function(ev, section_id) {
			return self.handleForceSwitch(section_id);
		};
		o.description = _('Force this upstream into the servers-file, bypassing the selection.');

		return m.render();
	}
});
