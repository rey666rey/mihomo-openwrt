// DNS-only guard. Never owns LTE routes, DHCP, the Mihomo service or user rules.
import * as fs from 'fs';
import { sha256 } from 'digest';

export const STORE = '/etc/mihomo-mini';
export const TMP = '/tmp/mihomo-mini';
export const CONFIG = '/etc/mihomo/config.yaml';
export const TABLE = 'mihomo_mini_dns';
export const ENDPOINTS = [ 'https://1.1.1.1/dns-query', 'https://8.8.8.8/dns-query', 'https://9.9.9.9/dns-query' ];

function quote(s) { return "'" + replace('' + s, "'", "'\\''") + "'"; }
export function command(args) { return system(args, 15000) == 0; };
export function capture(cmd) {
	let p = fs.popen(cmd + ' 2>/dev/null', 'r');
	if (!p) return { code: -1, text: '' };
	let text = p.read('all') || ''; return { code: p.close(), text };
};
export function read(path) { try { return json(fs.readfile(path) || 'null'); } catch(e) { return null; } };
export function write(path, value) {
	fs.mkdir(STORE, 0o700); fs.mkdir(TMP, 0o700);
	let f = fs.open(path + '.new', 'w', 0o600);
	if (!f) die('Не удалось подготовить состояние DNS.');
	let text = sprintf('%J', value), n = f.write(text), ok = f.close();
	if (n != length(text) || !ok || !fs.rename(path + '.new', path)) die('Не удалось сохранить состояние DNS.');
};
export function settings() {
	let saved = read(STORE + '/dns.json');
	return saved || { enabled: !!fs.access(STORE + '/dns.json'), group: '', resolvers: [ ENDPOINTS[0], ENDPOINTS[1] ] };
};
export function armed() { return fs.access(TMP + '/dns-armed') && !fs.access(TMP + '/emergency'); };
export function block(text) {
	let lines = split(text || '', '\n'), first = -1, last = length(lines);
	for (let i = 0; i < length(lines); i++) {
		if (match(lines[i], /^dns:\s*(#.*)?$/)) {
			if (first >= 0) die('Повторяющийся раздел dns.');
			first = i;
		} else if (first >= 0 && last == length(lines) && match(lines[i], /^[a-zA-Z][a-zA-Z0-9_-]*:/)) last = i;
	}
	if (first < 0) die('Не найден обычный раздел dns.');
	return { first, last, lines, text: trim(join('\n', slice(lines, first, last))) };
};
export function check_options(o) {
	if (type(o.resolvers) != 'array' || !length(o.resolvers) || length(o.resolvers) > 3) die('Выберите от одного до трёх DNS-серверов.');
	for (let url in o.resolvers) if (index(ENDPOINTS, url) < 0) die('Неподдерживаемый DNS-сервер.');
};
export function dns_block(o) {
	check_options(o);
	let out = [ 'dns:', '  enable: true', '  listen: 127.0.0.1:1053', '  ipv6: false',
		'  enhanced-mode: fake-ip', '  fake-ip-range: 198.18.0.1/16',
		'  fake-ip-filter:', '    - "+.lan"', '    - "+.local"', '    - "+.home.arpa"', '    - "daryno.netcraze.link"', '  use-hosts: true', '  use-system-hosts: true', '  respect-rules: false', '  default-nameserver:' ];
	for (let url in [ ENDPOINTS[0], ENDPOINTS[1] ]) push(out, '    - ' + sprintf('%J', url));
	push(out, '  proxy-server-nameserver:');
	for (let url in [ ENDPOINTS[0], ENDPOINTS[1] ]) push(out, '    - ' + sprintf('%J', url + '#DIRECT'));
	for (let key in ['nameserver', 'direct-nameserver']) {
		push(out, '  ' + key + ':');
		let path = key == 'nameserver' ? '#🌐 Web Stable' : '#DIRECT';
		for (let url in o.resolvers) push(out, '    - ' + sprintf('%J', url + path));
	}
	// Non-address queries (e.g. HTTPS records) also follow the Whoer selector.
	push(out, '  nameserver-policy:', '    "+.whoer.net":');
	for (let url in o.resolvers) push(out, '      - ' + sprintf('%J', url + '#Whoer.net'));
	return join('\n', out);
};
export function candidate(text, o) {
	let b = block(text);
	return join('\n', slice(b.lines, 0, b.first)) + '\n' + dns_block(o) + '\n\n' + join('\n', slice(b.lines, b.last));
};
export function valid_config(text, o) {
	try { return block(text).text == dns_block(o || settings()); } catch(e) { return false; }
};
// Examine every possible branch, not just the currently selected leaf.
export function safe_group(proxies, name, seen) {
	seen = seen || {};
	if (seen[name]) return false;
	let p = proxies?.[name];
	if (!p || index(['direct', 'pass', 'compatible', 'reject', 'rejectdrop', 'dns'], lc(p.type || '')) >= 0) return false;
	if (type(p.all) != 'array') return true;
	if (!length(p.all)) return false;
	let path = { ...seen }; path[name] = true;
	for (let child in p.all) if (!safe_group(proxies, child, path)) return false;
	return true;
};
export function graph() {
	let secret;
	for (let line in split(fs.readfile(CONFIG) || '', '\n')) {
		let m = match(line, /^secret:\s*([a-zA-Z0-9_-]+)\s*$/); if (m) secret = m;
	}
	if (!secret) die('Не удалось прочитать ключ API Mihomo.');
	let dir = fs.mkdtemp(TMP + '/dns-api-XXXXXX');
	if (!dir) die('Не удалось подготовить проверку DNS.');
	fs.chmod(dir, 0o700);
	let result, error;
	try {
		let f = fs.open(dir + '/auth', 'w', 0o600);
		if (!f) die('Нет места для проверки API.');
		f.write('Authorization: Bearer ' + secret[1] + '\n'); f.close();
		if (!command(['/usr/bin/curl', '-fsS', '--noproxy', '*', '--max-time', '8', '--max-filesize', '4194304',
			'-H', '@' + dir + '/auth', '-o', dir + '/proxies', 'http://192.168.1.1:9090/proxies'])) die('API Mihomo не отвечает.');
		result = read(dir + '/proxies')?.proxies || {};
		if (!command(['/usr/bin/curl', '-fsS', '--noproxy', '*', '--max-time', '8', '--max-filesize', '8388608',
			'-H', '@' + dir + '/auth', '-o', dir + '/providers', 'http://192.168.1.1:9090/providers/proxies'])) die('Не удалось проверить узлы провайдеров DNS.');
		for (let id, provider in (read(dir + '/providers')?.providers || {})) {
			for (let node in (provider.proxies || [])) {
				let old = result[node.name];
				// A same-name direct branch must never be hidden by another provider.
				if (!old || index(['direct', 'pass', 'compatible', 'dns'], lc(node.type || '')) >= 0) result[node.name] = node;
			}
		}
	} catch(e) { error = '' + (e.message || e); }
	fs.unlink(dir + '/auth'); fs.unlink(dir + '/proxies'); fs.unlink(dir + '/providers'); fs.rmdir(dir);
	if (error) die(error);
	return result;
};
function verify_default() {
	if (!safe_group(graph(), '🌐 Web Stable')) die('Общая группа DNS должна содержать только прокси.');
}
export function rules(blocked) {
	let port = blocked ? 1054 : 1056;
	return 'table inet ' + TABLE + ` {
 chain clients {
  type nat hook prerouting priority -100; policy accept;
  iifname != "br-lan" return
  ip saddr 192.168.1.111 return
  ip saddr 192.168.1.112 return
  meta l4proto { tcp, udp } th dport 53 counter redirect to :` + port + `
 }
 chain output_guard {
  type filter hook output priority -1; policy accept;
  oifname "lo" return
  meta l4proto { tcp, udp } th dport { 53, 853 } counter reject
 }
 chain forward_guard {
  type filter hook forward priority -1; policy accept;
  iifname != "br-lan" return
  ip saddr 192.168.1.111 return
  ip saddr 192.168.1.112 return
  meta l4proto { tcp, udp } th dport { 53, 853 } counter reject
  ip daddr 198.18.0.0/16 counter reject
  meta nfproto ipv6 ip6 daddr != { fc00::/7, fe80::/10, ff00::/8 } counter reject
 }
};
`;
};
function table_text() { return capture('/usr/sbin/nft -s list table inet ' + TABLE); }
// Standard DNAT must follow mangle for established TCP as well as SYN packets.
// Own exactly one tagged exception in the existing reference TProxy chain.
export function bypass() {
	let r = capture('/usr/sbin/nft -j -a list chain inet mihomo_tproxy_safe prerouting');
	if (r.code != 0) return { present: false, handles: [] };
	let data;
	try { data = json(r.text); } catch(e) { die('Не удалось проверить исключение TProxy для DNS.'); }
	let handles = [];
	for (let item in (data.nftables || [])) {
		let rule = item.rule;
		if (rule?.comment == 'mihomo-mini-dns-owned' && type(rule.handle) == 'int') push(handles, rule.handle);
	}
	return { present: true, handles };
};
function bypass_script(remove) {
	let b = bypass(), lines = [];
	for (let h in b.handles) push(lines, 'delete rule inet mihomo_tproxy_safe prerouting handle ' + h);
	if (b.present && !remove) push(lines, 'insert rule inet mihomo_tproxy_safe prerouting iifname "br-lan" ip saddr != 192.168.1.111 meta l4proto { tcp, udp } th dport 53 return comment "mihomo-mini-dns-owned"');
	return length(lines) ? join('\n', lines) + '\n' : '';
}

export function disarm() {
	fs.unlink(TMP + '/dns-armed');
	let script = (table_text().code == 0 ? 'delete table inet ' + TABLE + '\n' : '') + bypass_script(true);
	if (length(script)) {
		let file = TMP + '/dns-remove.nft';
		fs.writefile(file, script); fs.chmod(file, 0o600);
		if (!command(['/usr/sbin/nft', '-f', file])) die('Не удалось снять правила DNS.');
	}
	fs.unlink(TMP + '/dns-guard.json');
};
export function install_guard(blocked) {
	let file = TMP + '/dns-guard.nft', old = table_text();
	let script = (old.code == 0 ? 'delete table inet ' + TABLE + '\n' : '') + rules(blocked) + bypass_script(false);
	let f = fs.open(file, 'w', 0o600);
	if (!f) die('Нет места для правил DNS.');
	let n = f.write(script), ok = f.close();
	if (n != length(script) || !ok || !command(['/usr/sbin/nft', '-c', '-f', file]) || !command(['/usr/sbin/nft', '-f', file]))
		die('Не удалось применить правила защиты DNS.');
	write(TMP + '/dns-guard.json', { hash: sha256(table_text().text), blocked: !!blocked });
	if (!armed()) disarm();
};
export function arm(blocked) {
	fs.mkdir(TMP, 0o700);
	if (fs.access(TMP + '/emergency')) die('Действие отменено кнопкой прямого интернета.');
	write(TMP + '/dns-armed', { at: time() });
	install_guard(blocked);
};
export function hold() { if (armed()) install_guard(true); };
export function release() {
	if (!armed()) return;
	let o = settings();
	if (!valid_config(fs.readfile(CONFIG), o)) die('Защищённые параметры DNS изменены. Запросы заблокированы.');
	verify_default();
	if (!bypass().present) die('Ожидание TProxy.');
	if (!command(['/bin/sh', '-c', "nslookup -type=a example.org 127.0.0.1:1056 | grep -q '^Address: 198[.]18[.]'"]))
		die('Клиентский DNS ещё не готов.');
	// An emergency request arriving during the API call always takes precedence.
	if (armed()) {
		let guard = read(TMP + '/dns-guard.json');
		let b = bypass();
		if (guard?.blocked || guard?.hash != sha256(table_text().text) || (b.present && length(b.handles) != 1)) install_guard(false);
	}
};
export function disable() {
	let o = settings(); o.enabled = false; write(STORE + '/dns.json', o); disarm();
};
export function failure() {
	if (armed()) { hold(); return 'DNS заблокирован. Для обычного интернета нажмите «Прямой интернет».'; }
	return '';
};
export function summary() {
	let o = settings(), table = table_text(), guard = read(TMP + '/dns-guard.json'), active = !!armed();
	let consistent = valid_config(fs.readfile(CONFIG), o);
	let b = bypass();
	let intact = table.code == 0 && guard?.hash == sha256(table.text) && (!b.present || length(b.handles) == 1);
	let listening = capture("awk '$2 ~ /:041D$/ && $4 == \"07\" { found=1 } END { exit !found }' /proc/net/udp").code == 0;
	let state = !active && table.code == 0 ? 'conflict' : !o.enabled ? 'disabled' : !active ? 'paused' : !consistent || !intact ? 'conflict'
		: guard.blocked || !listening ? 'blocked' : 'active';
	return { enabled: !!o.enabled, armed: active, state, mode: 'fake-ip', resolvers: o.resolvers,
		endpoints: ENDPOINTS,
		guard: intact, config: consistent, last_check: read(TMP + '/dns-check.json'),
		bootstrap: 'encrypted-direct', exceptions: ['openwrt-lte', '192.168.1.111'], ipv6: 'public-forward-blocked' };
};
export function tick() {
	if (!armed()) return;
	let guard = read(TMP + '/dns-guard.json'), table = table_text();
	let b = bypass();
	if (!valid_config(fs.readfile(CONFIG)) || table.code != 0 || guard?.hash != sha256(table.text) || (b.present && length(b.handles) != 1) || (!b.present && !guard?.blocked)) install_guard(true);
};
export function boot() {
	let o = settings();
	if (o.enabled && command(['/etc/init.d/mihomo', 'enabled']) && trim(capture('/sbin/uci -q get mihomo.main.enabled').text) == '1'
		&& trim(capture('/sbin/uci -q get mihomo.main.tproxy_enabled').text) == '1') arm(true);
	else disarm();
};
