'use strict';
'require view';
'require form';
'require uci';
'require fs';
'require ui';

/*
 * LuCI 界面 for dnswatchd
 *
 * 设计要点：
 *  - 常规设置用 NamedSection 绑定 dnswatchd.main
 *  - 上游列表用 GridSection 绑定 dnswatchd.upstream（可增删、可排序）
 *  - 运行状态通过 `dnswatchd status` 异步读取，用 modal 展示
 *    （不用 DummyValue：fs.exec 是异步的，DummyValue.cfgvalue 需要同步返回值）
 */

return view.extend({
	/* ------------------------------------------------------------------ */
	/* 加载                                                                */
	/* ------------------------------------------------------------------ */

	load: function() {
		return uci.load('dnswatchd');
	},

	/* ------------------------------------------------------------------ */
	/* 运行「立即检测」                                                     */
	/* ------------------------------------------------------------------ */

	handleRunOnce: function() {
		ui.showModal(_('立即检测'), [
			E('p', { 'class': 'spinning' }, _('正在探测各上游，请稍候…'))
		]);

		return fs.exec('/usr/sbin/dnswatchd', [ 'once' ]).then(function(res) {
			var out = (res.stdout || '') + (res.stderr || '');
			ui.hideModal();
			return ui.showModal(_('检测完成'), [
				E('pre', {
					'style': 'white-space:pre-wrap;font-size:12px;max-height:60vh;overflow:auto'
				}, out || _('（无输出）')),
				E('div', { 'class': 'right' }, [
					E('button', {
						'class': 'btn',
						'click': ui.hideModal
					}, _('关闭'))
				])
			]);
		}).catch(function(err) {
			ui.hideModal();
			ui.addNotification(null, E('p', {}, _('执行失败：') + err), 'error');
		});
	},

	/* ------------------------------------------------------------------ */
	/* 查看状态                                                             */
	/* ------------------------------------------------------------------ */

	handleShowStatus: function() {
		ui.showModal(_('运行状态'), [
			E('p', { 'class': 'spinning' }, _('读取中…'))
		]);

		return fs.exec('/usr/sbin/dnswatchd', [ 'status' ]).then(function(res) {
			var out = (res.stdout || '') + (res.stderr || '');
			ui.hideModal();
			return ui.showModal(_('运行状态'), [
				E('pre', {
					'style': 'white-space:pre-wrap;font-size:12px;max-height:60vh;overflow:auto'
				}, out || _('（无输出）')),
				E('div', { 'class': 'right' }, [
					E('button', {
						'class': 'btn',
						'click': ui.hideModal
					}, _('关闭'))
				])
			]);
		}).catch(function(err) {
			ui.hideModal();
			ui.addNotification(null, E('p', {}, _('执行失败：') + err), 'error');
		});
	},

	/* ------------------------------------------------------------------ */
	/* 渲染                                                                */
	/* ------------------------------------------------------------------ */

	render: function() {
		var m, s, o;

		m = new form.Map('dnswatchd', _('DNS Watchdog'),
			_('持续探测 dnsmasq 的上游 DNS，校验应答内容是否落在预期网段内；' +
			  '上游失联或返回错误答案时自动切换到备用上游，恢复后自动切回。'));

		/* ---------------------------------------------------------- */
		/* 常规设置                                                    */
		/* ---------------------------------------------------------- */

		s = m.section(form.NamedSection, 'main', 'dnswatchd', _('常规设置'));
		s.addremove = false;
		s.anonymous = true;

		o = s.option(form.Flag, 'enabled', _('启用'));
		o.rmempty = false;
		o.default = '0';
		o.description = _('总开关。首次部署建议先不启用，等 dry-run 观察一天再打开。');

		o = s.option(form.Flag, 'dry_run', _('仅记录（dry-run）'));
		o.rmempty = false;
		o.default = '0';
		o.description = _('只把判定结果写进日志，不实际改写 servers-file。');

		o = s.option(form.Value, 'interval', _('探测间隔'), _('秒。最小 5，建议 30。'));
		o.datatype = 'range(5,3600)';
		o.placeholder = '30';
		o.default = '30';

		o = s.option(form.Value, 'timeout', _('单次探测超时'), _('秒。建议 1。'));
		o.datatype = 'range(1,30)';
		o.placeholder = '1';
		o.default = '1';

		o = s.option(form.Value, 'fail_threshold', _('连续失败几次判定 DOWN'));
		o.datatype = 'range(1,60)';
		o.placeholder = '2';
		o.default = '2';
		o.description = _('太小会在网络抖动时误切换，建议 2。');

		o = s.option(form.Value, 'recover_threshold', _('连续成功几次判定 UP'));
		o.datatype = 'range(1,60)';
		o.placeholder = '2';
		o.default = '2';
		o.description = _('回切需要连续成功这么多次，避免抖动。建议 2。');

		o = s.option(form.Value, 'servers_file', _('dnsmasq servers-file'),
			_('dnsmasq 的 --servers-file 路径。必须与 网络 → DHCP/DNS → 常规设置 → servers-file 一致。'));
		o.placeholder = '/tmp/dnsmasq.servers';
		o.default = '/tmp/dnsmasq.servers';
		o.rmempty = false;

		/* ---------- 选择策略 ---------- */

		o = s.option(form.ListValue, 'selection', _('选择策略'));
		o.value('priority', _('按优先级（可预测，默认）'));
		o.value('latency', _('按延迟（ping RTT 最快的）'));
		o.default = 'priority';
		o.rmempty = false;
		o.description = _('按优先级：按每个上游的「优先级」升序，第一个健康的胜出。' +
			'按延迟：先探测所有健康的上游，再对它们测 ping RTT，选最快的；' +
			'要求上游响应 ICMP，不响应的会被排在最后。');

		o = s.option(form.Value, 'latency_samples', _('延迟采样次数'),
			_('仅「按延迟」时生效。ping 几次取平均，1-10。'));
		o.datatype = 'range(1,10)';
		o.placeholder = '3';
		o.default = '3';
		o.depends('selection', 'latency');

		o = s.option(form.Value, 'latency_margin', _('切换阈值（%）'),
			_('仅「按延迟」时生效。新候选要比当前快这么多百分比才考虑切换，' +
			  '避免 1ms 的波动就把上游切来切去。0 = 只要更快就切。'));
		o.datatype = 'range(0,90)';
		o.placeholder = '20';
		o.default = '20';
		o.depends('selection', 'latency');

		o = s.option(form.Value, 'latency_switch_after', _('连续胜出几轮才切'),
			_('仅「按延迟」时生效。新候选要连续赢这么多次才真的切换。1 = 立刻切（容易抖）。'));
		o.datatype = 'range(1,10)';
		o.placeholder = '2';
		o.default = '2';
		o.depends('selection', 'latency');

		o = s.option(form.Flag, 'syslog', _('写入系统日志'));
		o.rmempty = false;
		o.default = '1';

		o = s.option(form.Flag, 'verbose', _('详细模式'));
		o.rmempty = false;
		o.default = '0';
		o.description = _('额外把「稳定在某上游」这类信息也写进日志。');

		/* 操作按钮必须挂在真实存在的 section 上（main），
		   用虚构的 section 名 LuCI 不会渲染任何东西。 */

		o = s.option(form.Button, '_runonce', _('立即检测一次'));
		o.inputtitle = _('运行');
		o.inputstyle = 'action';
		o.onclick = ui.createHandlerFn(this, 'handleRunOnce');
		o.description = _('只跑一轮探测并把结果写进日志（会实际切换，除非 dry-run 打开）。');

		o = s.option(form.Button, '_status', _('查看运行状态'));
		o.inputtitle = _('显示');
		o.inputstyle = 'action';
		o.onclick = ui.createHandlerFn(this, 'handleShowStatus');
		o.description = _('显示当前激活的上游、servers-file 内容，以及每个上游的失败/成功计数。');

		/* ---------------------------------------------------------- */
		/* 上游列表                                                    */
		/* ---------------------------------------------------------- */

		s = m.section(form.GridSection, 'upstream', _('上游 DNS'),
			_('按优先级升序逐个探测，第一个健康的会被写入 servers-file。' +
			  '注意：servers-file 里永远只会有一个 server 行 —— ' +
			  '并列多个上游会让 dnsmasq 并发查询，破坏 fake-ip。'));
		s.anonymous = true;
		s.addremove = true;
		s.sortable = true;

		o = s.option(form.Value, 'address', _('地址'));
		o.datatype = 'ip4addr';
		o.rmempty = false;

		o = s.option(form.Value, 'port', _('端口'));
		o.datatype = 'port';
		o.placeholder = '53';
		o.default = '53';

		o = s.option(form.ListValue, 'type', _('类型'));
		o.value('proxy', _('代理型（fake-ip）'));
		o.value('direct', _('直连型（真实 IP）'));
		o.default = 'direct';
		o.description = _('仅作标记，实际判定由下面的「期望网段」和「判定方式」决定。');

		o = s.option(form.Value, 'probe_domain', _('探针域名'));
		o.placeholder = 'www.baidu.com';
		o.rmempty = false;
		o.description = _('对这个域名做 A 记录查询来判定上游是否健康。' +
			'代理型上游建议用 www.google.com（走代理才能拿到 fake-ip），' +
			'直连型建议 www.baidu.com。');

		o = s.option(form.Value, 'expect_cidr', _('期望网段（CIDR）'));
		o.placeholder = '198.18.0.0/16';
		o.description = _('留空则只要求能解析出 A 记录，不校验内容。' +
			'填了之后会按下面的「判定方式」检查应答是否落在网段内。');

		o = s.option(form.ListValue, 'expect_mode', _('判定方式'));
		o.value('in', _('应答必须在网段内'));
		o.value('not-in', _('应答必须在网段外'));
		o.default = 'in';

		o = s.option(form.Value, 'priority', _('优先级'));
		o.datatype = 'range(1,999)';
		o.placeholder = '10';
		o.default = '10';
		o.description = _('数字越小越优先。');

		o = s.option(form.Flag, 'enabled', _('启用'));
		o.rmempty = false;
		o.default = '1';

		/* ---------------------------------------------------------- */

		return m.render();
	}
});
