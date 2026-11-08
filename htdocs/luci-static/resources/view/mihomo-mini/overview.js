'use strict';
'require view';
'require rpc';
'require ui';
'require poll';

var statusRPC = rpc.declare({ object: 'mihomo-mini', method: 'status', expect: {} });
var configRPC = rpc.declare({ object: 'mihomo-mini', method: 'config', params: ['previous'], expect: {} });
var jobRPC = rpc.declare({ object: 'mihomo-mini', method: 'job', params: ['id'], expect: {} });
var actionRPC = rpc.declare({ object: 'mihomo-mini', method: 'action', params: ['action', 'content', 'base'], expect: {} });
var directRPC = rpc.declare({ object: 'mihomo-mini', method: 'direct', expect: {} });

return view.extend({
	load: function() { return statusRPC(); },
	stamp: function(t) { return new Date(t * 1000).toLocaleString('ru-RU'); },
	message: function(text, error) {
		this.notice.textContent = text;
		this.notice.hidden = false;
		this.notice.className = 'mm-notice' + (error ? ' mm-error' : '');
	},
	confirm: function(title, text, handler) {
		ui.showModal(title, [ E('p', {}, text), E('div', { 'class': 'right' }, [
			E('button', { 'class': 'btn', 'click': ui.hideModal }, 'Отмена'), ' ',
			E('button', { 'class': 'btn cbi-button-action', 'click': function() { ui.hideModal(); handler(); } }, 'Продолжить')
		]) ]);
	},
	act: function(action) {
		var self = this, content = '', base = '';
		if (self.pending || self.state.busy) return;
		if (action === 'validate' || action === 'apply') { content = self.editor.value; base = self.baseHash || ''; }
		if (action === 'dns_enable') {
			content = JSON.stringify({ resolvers: [self.dnsPrimary.value, self.dnsSecondary.value].filter(function(v, i, all) { return v && all.indexOf(v) === i; }) });
			base = self.state.config_hash;
		}
		if (action === 'apply' && self.validated !== content) return;
		if (action === 'update') base = (self.state.latest || {}).version || '';
		self.pending = true; self.paint(); self.message('Задача запускается…');
		self.submitted = { action: action, content: content };
		return actionRPC(action, content, base).then(function(r) {
			if (!r.ok) throw new Error(r.error || 'Не удалось запустить задачу.');
			self.jobId = r.id;
			return self.refresh();
		}).catch(function(e) { self.pending = false; self.message(e.message, true); self.paint(); });
	},
	refresh: function() {
		var self = this;
		return statusRPC().then(function(s) {
			if (!s.ok) throw new Error(s.error || 'Нет ответа от роутера.');
			self.state = s;
			var id = self.jobId || s.busy;
			if (!id) { self.pending = false; self.paint(); return; }
			self.jobId = id;
			return jobRPC(id).then(function(r) {
				if (!r.ok) {
					if (!s.busy) {
						self.pending = false; self.jobId = null; self.submitted = null;
						self.message('Результат прежней задачи уже недоступен. Состояние обновлено; проверьте журнал перед повторением действия.', true);
						self.paint(); return;
					}
					throw new Error(r.error || 'Задача не найдена.');
				}
				var j = r.result;
				self.message(j.message, j.state === 'error');
				if (j.state === 'done' || j.state === 'error') {
					self.pending = false; self.jobId = null;
					var submission = self.submitted;
					if (j.state === 'done' && submission) {
						if (submission.action === 'validate' && self.editor.value === submission.content) {
							self.validated = submission.content; self.validation.textContent = 'Конфигурация проверена ядром Mihomo.';
						}
						if (submission.action === 'apply') {
						self.original = submission.content; self.baseHash = j.config_hash || s.config_hash;
							self.validation.textContent = 'Изменения сохранены.'; self.validated = null;
						}
					}
					if (j.diagnostics) self.showDiagnostics(j.diagnostics);
					if (j.release) self.state.latest = j.release;
					if (j.dns_groups && self.state.dns) self.state.dns.groups = j.dns_groups;
					if (submission && (submission.action === 'dns_enable' || submission.action === 'dns_disable') && j.state === 'done') self.dnsDirty = false;
					self.submitted = null;
				}
				self.paint();
			});
		}).catch(function(e) { self.message('Не удалось обновить состояние: ' + e.message + ' Проверьте соединение; операцию не повторяйте вслепую.', true); });
	},
	readConfig: function(previous) {
		var self = this;
		if (self.editor.value !== self.original && !window.confirm('Заменить несохранённый текст в редакторе?')) return;
		return configRPC(!!previous).then(function(r) {
			if (!r.ok) throw new Error(r.error);
			self.editor.value = r.content; self.baseHash = r.hash; self.validated = null;
			if (!previous) self.original = r.content;
			self.loaded = true;
			self.validation.textContent = previous ? 'Открыта предыдущая копия. Проверьте её перед применением.' : 'Загружен текущий файл. Изменения ещё не проверены.';
			self.paint();
		}).catch(function(e) { self.message(e.message, true); });
	},
	showDiagnostics: function(d) {
		var names = { direct: 'Прямой выход с роутера', dns: 'DNS роутера', proxy: 'Запрос через Mihomo', api: 'Локальная панель' };
		this.diagResult.replaceChildren();
		Object.keys(names).forEach(function(key) {
			this.diagResult.appendChild(E('div', { 'class': 'mm-row' }, [
				E('span', {}, names[key]), E('strong', {}, d[key] == null ? 'Ядро выключено' : d[key] ? 'Доступен' : 'Ошибка')
			]));
		}, this);
	},
	paint: function() {
		var self = this, s = self.state, busy = !!(self.pending || s.busy), writable = L.hasViewPermission();
		var d = s.dns || { state: 'disabled', groups: [], endpoints: [] };
		var labels = { disabled: 'Выключена', paused: 'Ожидает включения TProxy', active: 'Правила защиты включены', blocked: 'DNS заблокирован — ожидается VPN', conflict: 'Обнаружено расхождение настроек' };
		self.dnsStatus.textContent = labels[d.state] || 'Неизвестное состояние';
		self.dnsStatus.className = 'mm-dns-status mm-dns-' + d.state;
		self.facts.dns.textContent = labels[d.state] || 'Неизвестно';
		if (!self.dnsDirty) { self.dnsPrimary.value = (d.resolvers || [])[0] || 'https://1.1.1.1/dns-query'; self.dnsSecondary.value = (d.resolvers || [])[1] || ''; }
		self.dnsPrimary.disabled = busy || !writable; self.dnsSecondary.disabled = busy || !writable;
		self.buttons.dnsEnable.disabled = busy || !writable || !s.running || !s.tproxy;
		self.buttons.dnsDisable.disabled = busy || !writable || !d.enabled;
		self.buttons.dnsCheck.disabled = busy || !writable || !d.armed;
		var last = d.last_check;
		self.dnsResult.textContent = last ? self.stamp(last.at) + ' · DNS ' + (last.available ? 'отвечает' : 'не отвечает') + ' · запрос через VPN ' + (last.proxy ? 'успешен' : 'не подтверждён') + '. ' + last.note : 'Проверка ещё не выполнялась.';
		self.mode.textContent = s.tproxy ? 'Mihomo + TProxy' : s.running ? 'Только ядро и панель' : 'Прямой интернет';
		self.facts.core.textContent = (s.running ? 'Работает · ' : 'Остановлено · ') + s.version;
		self.facts.tproxy.textContent = s.tproxy ? 'Перехват LAN включён' : 'Перехвата нет';
		self.facts.boot.textContent = s.autostart ? 'Автозапуск включён' : 'Автозапуск выключен';
		self.buttons.start.disabled = busy || s.running || !writable;
		self.buttons.stop.disabled = busy || (!s.running && !s.tproxy) || !writable;
		self.buttons.restart.disabled = busy || !s.running || !writable;
		self.buttons.tproxy.disabled = busy || !s.running || !writable;
		self.buttons.tproxy.textContent = s.tproxy ? 'Выключить TProxy' : 'Включить TProxy';
		self.buttons.direct.disabled = !writable;
		self.buttons.dashboard.disabled = !s.running;
		self.autostart.checked = !!s.autostart; self.autostart.disabled = busy || !writable || (!s.running && !s.autostart);
		self.buttons.load.disabled = busy || !writable;
		self.buttons.previous.disabled = busy || !s.config_backup || !writable;
		self.buttons.validate.disabled = busy || !self.loaded || !writable;
		var conflict = self.loaded && self.baseHash !== s.config_hash;
		self.buttons.apply.disabled = busy || !self.loaded || self.validated !== self.editor.value || conflict || !writable;
		self.editor.readOnly = busy || !writable || !self.loaded;
		self.conflict.hidden = !conflict;
		self.buttons.check.disabled = busy || !writable;
		self.buttons.install.disabled = busy || !s.latest || s.latest.version === s.version || !writable;
		self.buttons.rollback.disabled = busy || !s.core_backup || !writable;
		self.buttons.diagnostics.disabled = busy || !writable;
		self.currentVersion.textContent = s.version + ' · Linux ARM64';
		self.latestVersion.textContent = s.latest ? s.latest.version + ' · проверено ' + self.stamp(s.latest.checked) : 'Обновления ещё не проверялись';
		self.journal.textContent = (s.journal || []).slice().reverse().map(function(row) {
			return self.stamp(row.time) + ' · ' + (row.state === 'error' ? 'Ошибка: ' : '') + row.message;
		}).join('\n') || 'Действий в приложении пока не было.';
	},
	render: function(data) {
		var self = this;
		// LuCI keeps the menu in session storage across normal page reloads.
		// Flush its cache so newly installed entries appear on the next navigation.
		if (ui.menu) ui.menu.flushCache();
		self.state = data; self.buttons = {}; self.facts = {}; self.original = ''; self.loaded = false;
		self.pending = false; self.validated = null;
		function button(key, label, handler, cls) {
			return self.buttons[key] = E('button', { 'class': 'btn ' + (cls || ''), 'type': 'button', 'click': handler }, label);
		}
		function panel(children) { return E('div', { 'class': 'mm-panel' }, children); }
		function heading(title, detail) { return [E('h3', {}, title), E('p', { 'class': 'mm-muted' }, detail)]; }
		function fact(key, label) {
			self.facts[key] = E('strong'); return E('div', {}, [E('span', { 'class': 'mm-muted' }, label), self.facts[key]]);
		}
		self.notice = E('div', { 'class': 'mm-notice', 'role': 'status', 'aria-live': 'polite', 'hidden': '' });
		self.mode = E('h3');
		self.autostart = E('input', { 'type': 'checkbox', 'change': function(ev) {
			var enable = ev.target.checked; ev.target.checked = !!self.state.autostart;
			if (enable) self.confirm('Автозапуск Mihomo', 'После перезагрузки роутер будет запускать Mihomo в текущем режиме' + (self.state.tproxy ? ' с TProxy.' : ' без перехвата.') + ' Включить автозапуск?', function() { self.act('autostart_on'); });
			else self.act('autostart_off');
		} });
		var control = E('section', { 'role': 'tabpanel' }, [
			panel([
				E('div', { 'class': 'mm-row' }, [self.mode, button('dashboard', 'Открыть MetaCubeXD ↗', function() { window.open('http://192.168.1.1:9090/ui/', '_blank', 'noopener,noreferrer'); })]),
				E('div', { 'class': 'mm-facts' }, [fact('core', 'Ядро'), fact('tproxy', 'Основная сеть'), fact('boot', 'После перезагрузки'), fact('dns', 'DNS-защита')]),
				E('div', { 'class': 'mm-actions' }, [
					button('start', 'Запустить ядро', function() { self.act('start'); }, 'cbi-button-action'),
					button('stop', 'Остановить', function() { self.act('stop'); }),
					button('restart', 'Перезапустить', function() { self.confirm('Перезапуск Mihomo', 'Соединения через прокси могут кратковременно прерваться. Прежний режим будет восстановлен после проверки запуска.', function() { self.act('restart'); }); }),
					button('tproxy', 'TProxy', function() {
						if (self.state.tproxy) self.act('tproxy_off');
						else self.confirm('Включение TProxy', 'Основная сеть будет использовать правила Mihomo. Перед включением перехвата роутер проверит выход через прокси.', function() { self.act('tproxy_on'); });
					})
				]),
				E('p', { 'class': 'mm-note' }, 'Ядро можно использовать отдельно от перехвата. LTE работает по своей схеме.'),
				E('label', { 'class': 'mm-row' }, [E('span', {}, 'Запускать Mihomo после перезагрузки'), self.autostart])
			]),
			panel([ E('h3', {}, 'Прямой интернет'), E('p', {}, 'Остановить Mihomo, снять правила TProxy и DNS-защиты, вернуть обычный DNS и отключить автозапуск.'),
				button('direct', 'Переключить на прямой интернет', function() {
					self.message('Отключение Mihomo и перехвата…');
					directRPC().then(function(r) { if (!r.ok) throw new Error(r.error); self.message(r.message); return self.refresh(); })
						.catch(function(e) { self.message(e.message, true); });
				}, 'cbi-button-negative') ])
		]);
		self.validation = E('p', { 'class': 'mm-muted', 'aria-live': 'polite' }, 'Загрузите текущую конфигурацию для редактирования.');
		self.conflict = E('p', { 'class': 'mm-error', 'hidden': '' }, 'Файл на роутере изменился. Скопируйте свои правки и загрузите актуальную версию перед сохранением.');
		self.editor = E('textarea', { 'class': 'mm-editor', 'aria-label': 'Конфигурация Mihomo YAML', 'spellcheck': 'false', 'autocomplete': 'off', 'autocapitalize': 'off',
			'input': function() { self.validated = null; self.validation.textContent = 'Есть непроверенные изменения.'; self.paint(); } });
		var config = E('section', { 'role': 'tabpanel', 'hidden': '' }, [panel([
			E('h3', {}, 'Конфигурация'), E('p', { 'class': 'mm-muted' }, 'Полный YAML содержит пароли и ключи. Доступен администратору. Предыдущая копия открывается без применения.'),
			E('div', { 'class': 'mm-actions' }, [button('load', 'Загрузить текущий файл', function() { self.readConfig(false); }), button('previous', 'Открыть предыдущую копию', function() { self.readConfig(true); })]),
			self.editor, self.validation, self.conflict,
			E('div', { 'class': 'mm-actions' }, [button('validate', 'Проверить', function() { self.act('validate'); }), button('apply', 'Сохранить и применить', function() { self.act('apply'); }, 'cbi-button-action')]),
			E('p', { 'class': 'mm-note' }, 'Проверка Mihomo → резервная копия → применение → проверка выхода. При ошибке приложение восстановит прежний конфиг. Порты и режим TProxy защищены от случайного изменения. Выключенное ядро останется выключенным.')
		])]);
		self.currentVersion = E('strong'); self.latestVersion = E('strong');
		var update = E('section', { 'role': 'tabpanel', 'hidden': '' }, [panel([
			E('h3', {}, 'Обновление ядра'), E('div', { 'class': 'mm-row' }, [E('span', {}, 'Установлено'), self.currentVersion]),
			E('div', { 'class': 'mm-row' }, [E('span', {}, 'Стабильный выпуск'), self.latestVersion]),
			E('div', { 'class': 'mm-actions' }, [button('check', 'Проверить обновления', function() { self.act('check_update'); }),
				button('install', 'Установить обновление', function() { self.confirm('Обновление ядра', 'Приложение загрузит официальный выпуск MetaCubeX для ARM64, сверит SHA-256 и проверит текущий конфиг новым ядром. Работающий Mihomo будет перезапущен; при сбое приложение вернёт прежнее ядро.', function() { self.act('update'); }); }, 'cbi-button-action'),
				button('rollback', 'Вернуть предыдущее ядро', function() { self.confirm('Откат ядра', 'Проверить резервное ядро и заменить им текущее? Работающая служба будет перезапущена.', function() { self.act('rollback_core'); }); })]),
			E('p', { 'class': 'mm-note' }, 'Обновление запускается вручную. Конфиг и текущий режим работы сохраняются. Версии alpha не устанавливаются.'),
			E('a', { 'href': 'https://github.com/MetaCubeX/mihomo/releases', 'target': '_blank', 'rel': 'noopener noreferrer' }, 'Официальные выпуски Mihomo ↗')
		])]);
		self.diagResult = E('div', {}, 'Проверка ещё не выполнялась.'); self.journal = E('pre', { 'class': 'mm-journal' });
		var diag = E('section', { 'role': 'tabpanel', 'hidden': '' }, [
			panel(heading('Подключение', 'Проверки выполняются с роутера. Они не заменяют проверку интернета на телефоне или компьютере.').concat([
				button('diagnostics', 'Проверить подключение', function() { self.act('diagnostics'); }), self.diagResult])),
			panel([E('h3', {}, 'Журнал приложения'), E('p', { 'class': 'mm-muted' }, 'Последние 30 операций. Без содержимого конфига и адресов подписок. Журнал очищается при перезагрузке.'), self.journal])
		]);
		self.dnsStatus = E('strong'); self.dnsResult = E('p', { 'class': 'mm-note', 'aria-live': 'polite' });
		self.dnsDirty = false;
		var dirty = function() { self.dnsDirty = true; self.paint(); };
		var endpoints = [['https://1.1.1.1/dns-query', 'Cloudflare · 1.1.1.1'], ['https://8.8.8.8/dns-query', 'Google · 8.8.8.8'], ['https://9.9.9.9/dns-query', 'Quad9 · 9.9.9.9']];
		self.dnsPrimary = E('select', { 'aria-label': 'Основной DNS', 'change': dirty }, endpoints.map(function(e) { return E('option', { value: e[0] }, e[1]); }));
		self.dnsSecondary = E('select', { 'aria-label': 'Дополнительный DNS', 'change': dirty }, [E('option', { value: '' }, 'Не использовать')].concat(endpoints.map(function(e) { return E('option', { value: e[0] }, e[1]); })));
		var dns = E('section', { 'role': 'tabpanel', 'hidden': '' }, [
			panel([
				E('h3', {}, 'Защищённый DNS домашней сети'), self.dnsStatus,
				E('p', { 'class': 'mm-muted' }, 'Для внешних сайтов устройства получают fake-IP. Выход выбирается в группе сервиса. Имена для прямых соединений и запросы самого роутера разрешаются через DoH.'),
				E('label', { 'class': 'mm-row' }, [E('span', {}, 'Основной DNS · HTTPS'), self.dnsPrimary]),
				E('label', { 'class': 'mm-row' }, [E('span', {}, 'Дополнительный DNS · HTTPS'), self.dnsSecondary]),
				E('div', { 'class': 'mm-actions' }, [button('dnsEnable', 'Включить / применить', function() { self.act('dns_enable'); }, 'cbi-button-action'), button('dnsDisable', 'Выключить защиту', function() { self.act('dns_disable'); })]),
				E('p', { 'class': 'mm-note' }, 'Локальные имена и torrserver.home.arpa обслуживаются роутером. LTE и мониторинг 192.168.1.111 исключены. Внешний IPv6 основной сети блокируется на время защиты.'),
				E('p', { 'class': 'mm-note' }, 'Для запуска VPN адреса его серверов определяются отдельным DNS через HTTPS вне туннеля. Страна DNS не обязана совпадать со страной каждой политики приложения.')
			]),
			panel([E('h3', {}, 'Проверка'), button('dnsCheck', 'Проверить DNS-защиту', function() { self.act('dns_check'); }), self.dnsResult,
				E('p', { 'class': 'mm-muted' }, 'Проверка относится к роутеру. На iPhone и Mac проверьте DNS-профили, Private Relay и Secure DNS браузера. Собственный DoH приложений не контролируется одним перехватом порта 53. Это защита DNS, а не запрет любого прямого трафика.'),
				E('p', { 'class': 'mm-note' }, 'Остановка Mihomo или отключение TProxy возвращает обычный DNS; настройка защиты сохраняется для следующего включения TProxy. Кнопка «Прямой интернет» доступна на вкладке «Управление».')])
		]);
		var tabs = [control, dns, config, update, diag], tabButtons = [];
		var nav = E('nav', { 'class': 'mm-tabs', 'role': 'tablist', 'aria-label': 'Разделы Mihomo' });
		['Управление', 'DNS-защита', 'Конфигурация', 'Обновление', 'Диагностика'].forEach(function(name, i) {
			var b = E('button', { 'type': 'button', 'role': 'tab', 'id': 'mm-tab-' + i, 'aria-controls': 'mm-section-' + i, 'aria-selected': String(i === 0),
				'click': function() { tabs.forEach(function(t, n) { t.hidden = n !== i; tabButtons[n].setAttribute('aria-selected', String(n === i)); }); },
				'keydown': function(ev) { if (ev.key === 'ArrowRight' || ev.key === 'ArrowLeft') { ev.preventDefault(); var n = (i + (ev.key === 'ArrowRight' ? 1 : tabs.length - 1)) % tabs.length; tabButtons[n].click(); tabButtons[n].focus(); } }
			}, name);
			tabs[i].id = 'mm-section-' + i; tabs[i].setAttribute('aria-labelledby', 'mm-tab-' + i);
			tabButtons.push(b); nav.appendChild(b);
		});
		self.beforeUnload = function(ev) { if (self.loaded && self.editor.value !== self.original) { ev.preventDefault(); ev.returnValue = ''; } };
		window.addEventListener('beforeunload', self.beforeUnload);
		poll.add(function() { return self.refresh(); }, 5);
		var root = E('div', { 'id': 'mihomo-mini' }, [
			E('link', { 'rel': 'stylesheet', 'href': L.resource('view/mihomo-mini/style.css') }),
			E('h2', {}, 'Mihomo'), E('p', { 'class': 'mm-muted' }, 'Управление ядром и прозрачным прокси'), nav, self.notice
		].concat(tabs));
		self.paint();
		return root;
	},
	handleSave: null,
	handleSaveApply: null,
	handleReset: null
});
