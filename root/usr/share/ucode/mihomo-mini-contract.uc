// Deliberately conservative YAML guard for this router's fixed network contract.
// Full YAML parsing and provider validation are performed by mihomo -t afterwards.
export function contract(text) {
	if (type(text) != 'string' || length(text) < 20 || length(text) > 524288)
		return 'Конфигурация должна занимать от 20 байт до 512 КиБ.';
	if (index(text, '\u0000') >= 0 || index(text, '\t') >= 0)
		return 'Используйте пробелы для отступов; табуляция и нулевые байты запрещены.';
	let roots = {}, children = {}, section = '', seen = {};
	for (let line in split(text, '\n')) {
		if (match(line, /^\s*(#.*)?$/)) continue;
		let top = match(line, /^([a-zA-Z][a-zA-Z0-9_-]*):\s*(.*?)\s*$/);
		if (top) {
			section = top[1];
			if (lc(section) != section) return 'Имена разделов верхнего уровня должны быть в нижнем регистре.';
			if (seen[section]) return 'Повторяющийся раздел: ' + section;
			seen[section] = true;
			roots[section] = trim(replace(top[2], /\s+#.*$/, ''));
			continue;
		}
		if (match(line, /^- /) && index(['proxy-groups', 'rules', 'proxies'], section) >= 0) continue;
		if (match(line, /^\S/)) return 'Используйте обычные имена разделов YAML без кавычек и слияний на верхнем уровне.';
		if (section == 'tun' || section == 'dns') {
			let child = match(line, /^  ([a-zA-Z][a-zA-Z0-9_-]*):\s*(.*?)\s*$/);
			if (match(line, /^  \S/) && !child) return 'В разделах tun и dns используйте обычные имена параметров без кавычек и слияний.';
			if (section == 'tun' && !match(line, /^  enable:\s*false\s*(#.*)?$/))
				return 'В этой схеме раздел tun должен содержать только enable: false.';
			if (child) {
				if (lc(child[1]) != child[1]) return 'Имена параметров tun и dns должны быть в нижнем регистре.';
				let key = section + '.' + child[1];
				if (children[key] != null) return 'Повторяющийся параметр: ' + key;
				children[key] = trim(replace(child[2], /\s+#.*$/, ''));
			}
		}
	}
	let required = { 'mixed-port': '7890', 'tproxy-port': '7893', ipv6: 'false',
		'external-controller': '192.168.1.1:9090', 'external-ui': 'ui', tun: '', dns: '' };
	for (let k, v in required)
		if (roots[k] != v) return 'Для текущей схемы требуется ' + k + ': ' + v;
	for (let k, v in { 'tun.enable': 'false', 'dns.enable': 'true', 'dns.listen': '127.0.0.1:1053',
		'dns.enhanced-mode': 'fake-ip', 'dns.fake-ip-range': '198.18.0.1/16' })
		if (children[k] != v) return 'Сохраните параметр ' + k + ': ' + v + ' (отступ — два пробела).';
	if (!roots.secret || !match(roots.secret, /^[a-zA-Z0-9_-]{16,128}$/))
		return 'Поле secret должно содержать 16–128 букв, цифр, знаков _ или - без кавычек.';
	for (let k in ['external-controller-tls', 'external-controller-unix', 'external-controller-pipe'])
		if (roots[k] != null) return 'Дополнительные контроллеры требуют отдельной настройки: ' + k;
	return null;
};
