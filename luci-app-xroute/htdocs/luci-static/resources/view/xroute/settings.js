'use strict';
'require view';
'require form';
'require fs';
'require uci';

const SUBDIR = '/etc/xroute/subs';
// kept as a constant: jsmin (LuCI build) breaks regex literals that directly follow "=>"
const LINK_RE = /^(vless|hy2|hysteria2):\/\//;

// Server name from the #fragment of a share link.
function linkName(link) {
	const i = link.indexOf('#');
	if (i < 0)
		return '';
	try {
		return decodeURIComponent(link.substring(i + 1));
	}
	catch (e) {
		return link.substring(i + 1);
	}
}

// Short human-readable summary of a share link, shown instead of the link itself.
function linkInfo(link) {
	const m = /^([a-z0-9]+):\/\/[^@]*@([^/?#]+)\/?(\?[^#]*)?/.exec(link || '');
	if (!m)
		return '—';

	const q = new URLSearchParams(m[3] || '');
	if (m[1] == 'vless')
		return 'VLESS · %s · %s · %s'.format(q.get('type') || 'tcp', q.get('security') || 'none', m[2]);
	if (m[1] == 'hy2' || m[1] == 'hysteria2')
		return 'Hysteria2 · %s%s'.format(m[2], q.get('obfs') ? ' · obfs' : '');

	return _('не поддерживается');
}

return view.extend({
	// Servers currently stored for each subscription: { section: [ { name, info } ] }
	loadSubServers() {
		return L.resolveDefault(fs.list(SUBDIR), []).then((files) => Promise.all(
			files.filter((f) => f.name.endsWith('.links')).map((f) =>
				L.resolveDefault(fs.read(SUBDIR + '/' + f.name), '').then((text) => [ f.name.replace(/\.links$/, ''), text ]))
		)).then((pairs) => {
			const res = {};
			for (const [ sec, text ] of pairs)
				res[sec] = text.split('\n').filter((l) => LINK_RE.test(l))
					.map((l, i) => ({ name: linkName(l) || '#%d'.format(i + 1), info: linkInfo(l) }));
			return res;
		});
	},

	load() {
		return Promise.all([ uci.load('xroute'), this.loadSubServers() ]).then((r) => {
			this.subServers = r[1];
		});
	},

	render() {
		const m = new form.Map('xroute', _('VPN-маршрутизация (Xray)'),
			_('Трафик к сайтам и сервисам из выбранных списков идёт через ваш VPN-сервер, всё остальное — напрямую ' +
			  '(заблокированное по имени сайта по-прежнему открывает zapret). Если Xray перестанет работать, ' +
			  'эти сайты автоматически пойдут напрямую.'));

		let s = m.section(form.NamedSection, 'main', 'main', _('Основные настройки'));

		let o = s.option(form.Flag, 'enabled', _('Включить'));
		o.rmempty = false;

		o = s.option(form.ListValue, 'mode', _('Какой сервер использовать'),
			_('В автоматическом режиме Xray раз в интервал проверки замеряет задержку до каждого сервера и ' +
			  'использует самый быстрый из работающих. Если не работает ни один — трафик идёт напрямую.'));
		o.value('auto', _('Автоматически: самый быстрый из работающих'));
		for (const sec of uci.sections('xroute', 'server'))
			o.value(sec['.name'], _('Только «%s»').format(sec.label || linkInfo(sec.link)));
		for (const sub of uci.sections('xroute', 'subscription')) {
			const title = sub.label || sub['.name'];
			for (const srv of this.subServers[sub['.name']] || [])
				o.value('sub:%s:%s'.format(sub['.name'], srv.name), _('Только «%s» (подписка «%s»)').format(srv.name, title));
		}

		o = s.option(form.Flag, 'fragment', _('Нарезать TLS-приветствие'),
			_('Обход ТСПУ: многие провайдеры обрывают новые соединения с зарубежными серверами на первом пакете ' +
			  '(ClientHello). Нарезанный на мелкие части, он проходит. Действует на VLESS с REALITY или TLS; ' +
			  'если в ссылке уже есть свой параметр fm, используется он.'));
		o.default = '1';
		o.rmempty = false;

		o = s.option(form.ListValue, 'probe_interval', _('Интервал проверки серверов'));
		o.value('30s', _('30 секунд'));
		o.value('1m', _('1 минута'));
		o.value('2m', _('2 минуты'));
		o.value('5m', _('5 минут'));
		o.default = '1m';

		o = s.option(form.Value, 'probe_url', _('Адрес для проверки'),
			_('Должен отвечать быстро и с кодом 204/200 через VPN-сервер.'));
		o.placeholder = 'https://www.gstatic.com/generate_204';

		o = s.option(form.ListValue, 'loglevel', _('Подробность журнала Xray'),
			_('Журнал хранится только в оперативной памяти: «Статус → Системный журнал».'));
		o.value('none', _('выключен'));
		o.value('error', _('только ошибки'));
		o.value('warning', _('предупреждения'));
		o.value('info', _('подробно'));
		o.default = 'warning';

		s = m.section(form.GridSection, 'server', _('Серверы'),
			_('Вставьте ссылку из панели 3x-ui или клиента: <code>vless://</code> (raw/XHTTP/WS/gRPC, Reality или TLS) ' +
			  'или <code>hy2://</code> / <code>hysteria2://</code>. Ссылка хранится в /etc/config/xroute на роутере.'));
		s.anonymous = true;
		s.addremove = true;
		s.sortable = true;
		s.addbtntitle = _('Добавить сервер');
		s.modaltitle = _('Сервер');

		o = s.option(form.Flag, 'enabled', _('Вкл.'));
		o.default = '1';
		o.editable = true;
		o.rmempty = false;

		o = s.option(form.Value, 'label', _('Название'));
		o.placeholder = _('например, VLESS XHTTP');

		o = s.option(form.DummyValue, '_info', _('Подключение'));
		o.modalonly = false;
		o.cfgvalue = (sid) => linkInfo(uci.get('xroute', sid, 'link'));

		o = s.option(form.Value, 'link', _('Ссылка'));
		o.modalonly = true;
		o.password = true;
		o.rmempty = false;
		o.validate = function(sid, value) {
			if (!value)
				return _('Укажите ссылку');
			if (!/^(vless|hy2|hysteria2):\/\/[^@]+@[^/?#]+/.test(value))
				return _('Нужна ссылка вида vless://…, hy2://… или hysteria2://…');
			return true;
		};

		s = m.section(form.GridSection, 'subscription', _('Подписки'),
			_('Ссылка на подписку из 3x-ui («Клиенты» → значок подписки, адрес вида <code>https://домен:порт/путь/ID</code>). ' +
			  'Из неё берутся серверы vless:// и hy2://; они участвуют в автоматическом выборе вместе с серверами выше. ' +
			  'Последняя удачная подписка хранится на роутере и перезаписывается только при изменении. ' +
			  'Трафик и срок действия — на вкладке «Состояние».'));
		s.anonymous = true;
		s.addremove = true;
		s.addbtntitle = _('Добавить подписку');
		s.modaltitle = _('Подписка');

		o = s.option(form.Flag, 'enabled', _('Вкл.'));
		o.default = '1';
		o.editable = true;
		o.rmempty = false;

		o = s.option(form.Value, 'label', _('Название'));
		o.placeholder = _('например, 3x-ui');

		o = s.option(form.DummyValue, '_servers', _('Серверы в подписке'));
		o.modalonly = false;
		o.rawhtml = true;
		o.cfgvalue = (sid) => {
			const list = this.subServers[sid];
			if (!list)
				return _('ещё не скачана — нажмите «Сохранить и применить» и откройте страницу заново');
			if (!list.length)
				return _('нет серверов vless:// или hy2://');
			return list.map((srv) => '%h <small>(%h)</small>'.format(srv.name, srv.info)).join('<br>');
		};

		o = s.option(form.Value, 'url', _('Ссылка на подписку'));
		o.modalonly = true;
		o.password = true;
		o.rmempty = false;
		o.validate = function(sid, value) {
			if (!value)
				return _('Укажите ссылку');
			if (!/^https?:\/\/[^/]+\/.+/.test(value))
				return _('Нужна ссылка вида https://домен:порт/путь/ID');
			return true;
		};

		o = s.option(form.ListValue, 'interval', _('Обновлять'));
		o.value('0', _('как советует панель (иначе раз в 12 ч)'));
		o.value('1', _('каждый час'));
		o.value('3', _('раз в 3 часа'));
		o.value('6', _('раз в 6 часов'));
		o.value('12', _('раз в 12 часов'));
		o.value('24', _('раз в сутки'));
		o.default = '0';

		o = s.option(form.Value, 'filter', _('Фильтр по названию'),
			_('Необязательно. Берутся только серверы, в названии которых есть совпадение (регулярное выражение, без учёта регистра), ' +
			  'например <code>NL|DE</code>.'));
		o.modalonly = true;

		return m.render();
	}
});
