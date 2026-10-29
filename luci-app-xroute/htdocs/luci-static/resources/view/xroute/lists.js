'use strict';
'require view';
'require form';
'require fs';
'require ui';
'require uci';

// id → [title, hint]; ids must match catalog.sh
const COMMUNITY = [
	[ 'telegram',      'Telegram',                       'домены и подсети; блокируется по IP, zapret не поможет' ],
	[ 'meta',          'WhatsApp, Instagram, Facebook',  'домены и подсети Meta; блокировка по IP' ],
	[ 'viber',         'Viber',                          'домены и подсети Viber; звонки идут не через порт 443, zapret их не вытянет' ],
	[ 'ukraine',       'Украина',                        'все сайты .ua и .укр и украинские сервисы вне .ua: банки, Дія, Пенсійний фонд, Нова пошта, Укрпошта, магазины, операторы, новости' ],
	[ 'geoblock',      'Сервисы с блокировкой по стране', 'ChatGPT, Claude, Spotify, Netflix, Notion и т.д. — сами не пускают из РФ' ],
	[ 'google_ai',     'Google AI (Gemini)',             '' ],
	[ 'twitter',       'X (Twitter)',                    'часто открывается и через zapret' ],
	[ 'tiktok',        'TikTok',                         '' ],
	[ 'roblox',        'Roblox',                         '' ],
	[ 'hdrezka',       'HDRezka',                        '' ],
	[ 'news',          'Заблокированные новостные сайты', '' ],
	[ 'block',         'Прочие заблокированные сайты',   '' ],
	[ 'russia_inside', 'Всё заблокированное в РФ',        'большой общий список (~1200 доменов); YouTube и Discord из него исключаются ниже' ],
	[ 'discord',       'Discord',                        'у многих провайдеров работает напрямую или через zapret' ]
];

return view.extend({
	load() {
		return uci.load('xroute');
	},

	handleUpdate(ev) {
		const btn = ev.currentTarget;
		btn.disabled = true;
		return fs.exec('/etc/init.d/xroute', [ 'update_lists' ]).then(() => {
			ui.addNotification(null, E('p', _('Обновление списков запущено. Через полминуты результат будет виден на вкладке «Состояние».')), 'info');
		}).catch((e) => {
			ui.addNotification(null, E('p', e.message), 'danger');
		}).finally(() => {
			btn.disabled = false;
		});
	},

	render() {
		const m = new form.Map('xroute', _('Списки для VPN'),
			_('Через VPN идут только сайты из отмеченных списков и ваших доменов/подсетей. Списки берутся из проекта ' +
			  '<a href="https://github.com/itdoginfo/allow-domains" target="_blank" rel="noreferrer">itdoginfo/allow-domains</a> ' +
			  '(«Украина» и «Viber» — из <a href="https://github.com/Rozsario/luci-app-xroute" target="_blank" rel="noreferrer">luci-app-xroute</a>), ' +
			  'хранятся в оперативной памяти и обновляются 1-го и 15-го числа. Устройства должны использовать DNS роутера: ' +
			  'выключите «Частный DNS» на Android и «Безопасный DNS» в браузерах, иначе маршрутизация по доменам не сработает.'));

		const s = m.section(form.NamedSection, 'lists', 'lists');

		let o = s.option(form.Flag, 'google_vpn', _('YouTube и Google Play через VPN'),
			_('<b>Выключено:</b> YouTube и Google Play идут через zapret. Видео обычно быстрее, но у многих провайдеров ' +
			  'загрузки из Google Play зависают или обрываются.<br>' +
			  '<b>Включено:</b> все домены YouTube и Google Play идут через VPN. Загрузки из Play работают, ' +
			  'а видео идёт со скоростью вашего VPN-сервера.<br>' +
			  'Видео YouTube и загрузки Play Google отдаёт с одних и тех же серверов, поэтому они переключаются вместе. ' +
			  'Отдельных подсетей у YouTube и Play нет: их адреса общие со всем Google, а кеш-серверы стоят у провайдеров, ' +
			  'поэтому маршрутизация идёт по доменам. Настройки zapret менять не нужно: трафик, который роутер отправляет ' +
			  'в VPN, до zapret не доходит, а если выключить переключатель или VPN, YouTube снова подхватит zapret. ' +
			  'Проверено с zapret2 от remittor (remittor/zapret-openwrt); с другими сборками zapret не проверялось.'));
		o.rmempty = false;

		o = s.option(form.MultiValue, 'community', _('Готовые списки'));
		o.widget = 'checkbox';
		o.display_size = 20;
		for (const [ id, title, hint ] of COMMUNITY)
			o.value(id, hint ? '%s — %s'.format(title, _(hint)) : title);

		o = s.option(form.DynamicList, 'domain', _('Свои домены'),
			_('Домен вместе со всеми поддоменами, например <code>example.com</code>; зона целиком — <code>ua</code>.'));
		o.datatype = 'hostname';

		o = s.option(form.DynamicList, 'subnet', _('Свои подсети'),
			_('IPv4-адрес или подсеть, например <code>203.0.113.0/24</code>.'));
		o.datatype = 'ipaddr';

		o = s.option(form.DynamicList, 'exclude', _('Никогда не через VPN'),
			_('Домены (с поддоменами), которые убираются из всех списков. По умолчанию здесь YouTube и Discord — их открывает zapret. ' +
			  'Исключения YouTube не действуют, пока включено «YouTube и Google Play через VPN».'));
		o.datatype = 'hostname';

		o = s.option(form.Button, '_update', _('Обновить списки сейчас'));
		o.inputtitle = _('Скачать заново');
		o.inputstyle = 'apply';
		o.onclick = ui.createHandlerFn(this, 'handleUpdate');

		return m.render();
	}
});
