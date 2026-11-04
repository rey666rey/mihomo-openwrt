import * as fs from 'fs';
import { sha256 } from 'digest';

export const TMP = '/tmp/mihomo-mini';
export const STORE = '/etc/mihomo-mini';
export const CONFIG = '/etc/mihomo/config.yaml';
export const CORE = '/usr/bin/mihomo';
export const WORKER = '/usr/libexec/mihomo-mini-worker';

export function quote(s) { return "'" + replace('' + s, "'", "'\\''") + "'"; };
export function capture(cmd) {
	let p = fs.popen(cmd + ' 2>/dev/null', 'r');
	if (!p) return { code: -1, text: '' };
	let text = p.read('all') || '';
	return { code: p.close(), text };
};
export function run(args, timeout) { return system(args, timeout || 15000) == 0; };
export function readjson(path) {
	try { return json(fs.readfile(path) || 'null'); } catch (e) { return null; }
};
export function save(path, text) {
	let f = fs.open(path, 'w', 0o600);
	if (!f) die('Не удалось открыть файл для записи.');
	let n = f.write(text), ok = f.close();
	if (n != length(text) || !ok) die('Не удалось полностью записать файл. Проверьте свободное место.');
	fs.chmod(path, 0o600);
};
export function atomic(path, text) {
	save(path + '.new', text);
	if (!fs.rename(path + '.new', path)) die('Не удалось заменить файл.');
};
export function init() {
	fs.mkdir(TMP, 0o700); fs.chmod(TMP, 0o700);
	fs.mkdir(STORE, 0o700); fs.chmod(STORE, 0o700);
};
export function hash_config() { return sha256(fs.readfile(CONFIG) || ''); };
export function stopped_flag() { return fs.access(TMP + '/emergency'); };
// Evaluate the next allocation against *remaining* tmpfs and RAM, not the
// logical sizes of several copies which the update no longer creates.
export function core_memory_ready(bytes, tmp_free, ram_free) {
	return bytes != null && bytes > 0 && bytes <= 134217728
		&& tmp_free != null && ram_free != null
		&& tmp_free >= bytes + 8388608 && ram_free >= bytes + 33554432;
};
export function gzip_uncompressed_size(path) {
	let f = fs.open(path, 'r');
	if (!f) return null;
	let header = f.read(3);
	if (header != '\x1f\x8b\x08' || !f.seek(-4, 2)) { f.close(); return null; }
	let tail = f.read(4); f.close();
	if (length(tail) != 4) return null;
	let size = ord(tail, 0) + ord(tail, 1) * 256 + ord(tail, 2) * 65536 + ord(tail, 3) * 16777216;
	return size > 0 && size <= 134217728 ? size : null;
};
export function cleanup() {
	run(['/usr/sbin/nft', 'delete', 'table', 'inet', 'mihomo_tproxy_safe']);
	// Only this application's mark/table/priority combination; LTE is independent.
	for (let i = 0; i < 8; i++) {
		if (!run(['/sbin/ip', 'rule', 'del', 'priority', '100', 'fwmark', '0x1/0x1', 'lookup', '100'])) break;
	}
	run(['/sbin/ip', 'route', 'del', 'local', 'default', 'dev', 'lo', 'table', '100']);
};
export function direct() {
	init(); save(TMP + '/emergency', '1');
	run(['/etc/init.d/mihomo', 'disable']);
	run(['/sbin/uci', 'set', 'mihomo.main.enabled=0']);
	run(['/sbin/uci', 'set', 'mihomo.main.tproxy_enabled=0']);
	run(['/sbin/uci', 'commit', 'mihomo']);
	cleanup(); run(['/etc/init.d/mihomo', 'stop'], 15000); cleanup();
	let s = status();
	if (s.running || s.tproxy || s.autostart)
		return { ok: false, error: 'Не удалось полностью отключить Mihomo. Проверьте состояние службы по SSH.' };
	return { ok: true, message: 'Mihomo и TProxy выключены. Автозапуск отключён.' };
};
export function status() {
	let service = {};
	try { service = json(capture("ubus call service list '{\"name\":\"mihomo\"}'").text); } catch(e) {}
	let running = false;
	for (let k, v in (service?.mihomo?.instances || {})) if (v.running) running = true;
	let version = match(capture(CORE + ' -v').text, /Mihomo\s+(Meta\s+)?(v[0-9.]+)/);
	let lock = readjson(TMP + '/lock/owner.json');
	if (lock && time() - lock.created > 15 && (!lock.pid || !fs.access('/proc/' + lock.pid))) {
		let j = readjson(TMP + '/' + lock.id + '/result.json');
		if (j?.state == 'running' || j?.state == 'queued')
			atomic(TMP + '/' + lock.id + '/result.json', sprintf('%J', { state: 'error', message: 'Задача прервана. Проверьте состояние службы.', finished: time() }));
		fs.unlink(TMP + '/lock/owner.json'); fs.rmdir(TMP + '/lock'); lock = null;
	}
	return { ok: true, running, tproxy: capture('nft list table inet mihomo_tproxy_safe').code == 0,
		autostart: capture('/etc/init.d/mihomo enabled').code == 0,
		version: version ? version[2] : 'не определена', config_hash: hash_config(),
		config_backup: fs.access(STORE + '/config.previous.yaml'), core_backup: fs.access(STORE + '/core.previous'),
		busy: lock?.id || null, latest: readjson(TMP + '/release.json'),
		journal: readjson(TMP + '/journal.json') || [],
		emergency: stopped_flag() };
};
export function enqueue(action, content, base) {
	init(); status();
	if (index(['start', 'stop', 'restart', 'tproxy_on', 'tproxy_off', 'autostart_on', 'autostart_off',
		'validate', 'apply', 'check_update', 'update', 'rollback_core', 'diagnostics'], action) < 0)
		return { ok: false, error: 'Неизвестное действие.' };
	if (type(content) != 'string' || length(content) > 524288) return { ok: false, error: 'Конфигурация слишком велика.' };
	if (!fs.mkdir(TMP + '/lock', 0o700)) return { ok: false, error: 'Другая задача ещё выполняется.' };
	let dir = fs.mkdtemp(TMP + '/job-XXXXXX');
	if (!dir) { fs.rmdir(TMP + '/lock'); return { ok: false, error: 'Недостаточно места в памяти.' }; }
	fs.chmod(dir, 0o700);
	let id = fs.basename(dir);
	try {
		save(dir + '/request.json', sprintf('%J', { action, content, base }));
		save(dir + '/result.json', sprintf('%J', { state: 'queued', action, message: 'Задача поставлена в очередь.', created: time() }));
		save(TMP + '/lock/owner.json', sprintf('%J', { id, created: time() }));
		if (action != 'stop' && action != 'autostart_off') fs.unlink(TMP + '/emergency');
		let cmd = 'umask 077; setsid ' + WORKER + ' ' + quote(id) + ' </dev/null >' + quote(dir + '/private.log') + ' 2>&1 &';
		if (system(cmd) != 0) die('Не удалось запустить задачу.');
		return { ok: true, id };
	} catch(e) {
		fs.unlink(TMP + '/lock/owner.json'); fs.rmdir(TMP + '/lock');
		return { ok: false, error: 'Не удалось создать задачу.' };
	}
};
