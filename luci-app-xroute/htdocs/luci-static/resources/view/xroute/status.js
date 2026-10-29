'use strict';
'require view';
'require fs';
'require poll';
'require ui';

const STATUS = '/usr/share/xroute/status.uc';
const REPO = 'https://github.com/Rozsario/luci-app-xroute';
const XRAY = 'https://github.com/XTLS/Xray-core';

function link(url) {
	return E('a', { 'href': url, 'target': '_blank', 'rel': 'noreferrer' }, url);
}

function fmtBytes(n) {
	const u = [ 'Б', 'КБ', 'МБ', 'ГБ', 'ТБ' ];
	let i = 0;
	while (n >= 1024 && i < u.length - 1) {
		n /= 1024;
		i++;
	}
	return '%.1f %s'.format(n, u[i]);
}

function fmtTest(t) {
	if (!t)
		return '—';
	return t.ok ? E('span', { 'style': 'color:#3a3' }, _('работает, %d мс').format(t.ms))
	            : E('span', { 'style': 'color:#c33' }, _('не отвечает'));
}

function row(title, value) {
	return E('tr', { 'class': 'tr' }, [
		E('td', { 'class': 'td left', 'width': '40%' }, title),
		E('td', { 'class': 'td left' }, value)
	]);
}

return view.extend({
	load() {
		return this.fetch(false);
	},

	fetch(test) {
		return fs.exec_direct(STATUS, test ? [ 'test' ] : [], 'json').catch(() => null);
	},

	renderStatus(st) {
		if (!st)
			return E('p', _('Не удалось получить состояние.'));

		let state;
		if (!st.enabled)
			state = E('span', _('выключено'));
		else if (st.running && st.redirect)
			state = E('span', { 'style': 'color:#3a3' }, _('работает'));
		else if (st.running)
			state = E('span', { 'style': 'color:#c90' }, _('Xray работает, перенаправление выключено'));
		else
			state = E('span', { 'style': 'color:#c33' }, _('Xray не запущен — сайты из списков идут напрямую'));

		const updated = st.lists.updated ? new Date(st.lists.updated * 1000).toLocaleString() : '—';
		const rows = [
			row(_('Состояние'), state),
			row(_('Режим'), this.modeText(st)),
			row(_('Через VPN прошло'), _('%s (%d пакетов)').format(fmtBytes(st.bytes), st.packets)),
			row(_('Адресов из доменных списков'), String(st.dst_dns)),
			row(_('Подсетей'), String(st.dst_net)),
			row(_('Списки'), _('%d доменов, %d подсетей; собраны %s%s').format(st.lists.domains || 0, st.lists.subnets || 0, updated,
				st.lists.missing ? _(' (часть списков пока не скачалась — используются встроенные копии, повтор каждые 30 с)') : ''))
		];

		if (st.auto)
			rows.push(row(_('Автоматический выбор'), fmtTest(st.auto)));

		for (const s of st.servers)
			rows.push(row('%s%s (%s, %s)'.format(s.source && s.source != 'manual' ? '⟳ ' : '', s.label,
				s.proto == 'hysteria' ? 'Hysteria2' : 'VLESS', s.host), fmtTest(s.test)));

		for (const s of st.skipped || [])
			rows.push(row('%s%s'.format(s.source && s.source != 'manual' ? '⟳ ' : '', s.label),
				E('span', { 'style': 'color:#c90' }, _('пропущен: %s').format(s.reason))));

		for (const sub of st.subs || [])
			rows.push(row(_('Подписка «%s»').format(sub.title || sub.label || sub.name), this.renderSub(sub)));

		return E('table', { 'class': 'table' }, rows);
	},

	modeText(st) {
		if (st.mode == 'auto')
			return _('автоматический выбор сервера');
		const m = /^sub:[^:]+:(.*)$/.exec(st.mode);
		const srv = m ? null : (st.servers || []).find((s) => s.name == st.mode);
		return _('только «%s»').format(m ? m[1] : (srv ? srv.label : st.mode));
	},

	renderSub(sub) {
		if (!sub.enabled)
			return _('выключена');

		const parts = [];
		parts.push(_('серверов: %d').format(sub.stored || 0));
		if (sub.fetched)
			parts.push(_('скачана %s').format(new Date(sub.fetched * 1000).toLocaleString()));
		else
			parts.push(_('ещё не скачивалась после загрузки роутера'));
		if (sub.total)
			parts.push(_('трафик %s из %s').format(fmtBytes((sub.upload || 0) + (sub.download || 0)), fmtBytes(sub.total)));
		else if (sub.upload || sub.download)
			parts.push(_('трафик %s (без лимита)').format(fmtBytes((sub.upload || 0) + (sub.download || 0))));
		if (sub.expire)
			parts.push(_('действует до %s').format(new Date(sub.expire * 1000).toLocaleDateString()));

		const out = [ E('span', parts.join(' · ')) ];
		if (sub.error) {
			const when = sub.attempt ? new Date(sub.attempt * 1000).toLocaleString() : '';
			if (sub.stored)
				out.push(E('br'), E('span', { 'style': 'color:#c90' },
					_('последнее обновление %s не удалось, используется сохранённая подписка: %s').format(when, sub.error)));
			else
				out.push(E('br'), E('span', { 'style': 'color:#c33' }, _('ошибка (%s): %s').format(when, sub.error)));
		}
		return E('span', out);
	},

	handleSubs(ev) {
		const btn = ev.currentTarget;
		btn.disabled = true;
		// runs in the background on the router; the regular refresh picks up the result
		return fs.exec('/etc/init.d/xroute', [ 'update_subs' ]).then(() => {
			ui.addNotification(null, E('p', _('Обновление подписок запущено, результат появится здесь через несколько секунд. ' +
				'Если параметры серверов изменились, служба перезапустится и соединения через VPN переподключатся.')), 'info');
			return new Promise((resolve) => setTimeout(resolve, 4000));
		}).then(() => this.refresh()).catch((e) => {
			ui.addNotification(null, E('p', e.message), 'danger');
		}).finally(() => {
			btn.disabled = false;
		});
	},

	// test results are kept between the periodic refreshes, which do not re-test the servers
	handleTest(ev) {
		const btn = ev.currentTarget;
		btn.disabled = true;
		return this.fetch(true).then((st) => {
			this.tested = {};
			for (const s of (st && st.servers) || [])
				this.tested[s.name] = s.test;
			this.testedAuto = st && st.auto;
			this.show(st);
		}).finally(() => {
			btn.disabled = false;
		});
	},

	show(st) {
		if (st) {
			for (const s of st.servers || [])
				if (!s.test && this.tested)
					s.test = this.tested[s.name];
			if (!st.auto && this.testedAuto)
				st.auto = this.testedAuto;
		}
		const box = document.getElementById('xroute-status');
		if (box)
			box.replaceChildren(this.renderStatus(st));
	},

	refresh() {
		return this.fetch(false).then((st) => this.show(st));
	},

	handleRestart(ev) {
		const btn = ev.currentTarget;
		btn.disabled = true;
		return fs.exec('/etc/init.d/xroute', [ 'restart' ]).then(() => {
			this.tested = null;
			this.testedAuto = null;
			ui.addNotification(null, E('p', _('Служба перезапущена.')), 'info');
			return this.refresh();
		}).catch((e) => {
			ui.addNotification(null, E('p', e.message), 'danger');
		}).finally(() => {
			btn.disabled = false;
		});
	},

	render(st) {
		poll.add(() => this.refresh(), 10);

		return E([], [
			E('h2', [ 'luci-app-xroute', st && st.version ? E('span', { 'style': 'margin-left:.6em;font-weight:normal' }, 'v' + st.version) : '' ]),
			E('div', { 'class': 'cbi-map-descr' }, [
				_('VPN-маршрутизация через Xray. Автор — Rozsario.'), E('br'),
				link(REPO), E('br'),
				link(XRAY)
			]),
			E('div', { 'class': 'cbi-section' }, [
				E('div', { 'id': 'xroute-status' }, this.renderStatus(st)),
				E('div', { 'class': 'right' }, [
					E('button', { 'class': 'btn cbi-button cbi-button-action', 'click': ui.createHandlerFn(this, 'handleTest') },
						_('Проверить серверы')),
					' ',
					E('button', { 'class': 'btn cbi-button cbi-button-action', 'click': ui.createHandlerFn(this, 'handleSubs') },
						_('Обновить подписки')),
					' ',
					E('button', { 'class': 'btn cbi-button cbi-button-reset', 'click': ui.createHandlerFn(this, 'handleRestart') },
						_('Перезапустить'))
				])
			])
		]);
	},

	handleSave: null,
	handleSaveApply: null,
	handleReset: null
});
