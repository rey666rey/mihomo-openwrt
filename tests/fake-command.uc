#!/usr/bin/ucode
// Isolated fault injection: no network or service mutation is permitted here.
import * as fs from 'fs';
const root = '/tmp/mihomo-mini-faults';
let args = ARGV, cmd = args[0];
if (cmd == '/usr/bin/curl') {
	let url = args[length(args)-1];
	if (index(args, '-x') >= 0) exit(index(fs.readfile(root + '/config.yaml') || '', 'log-level: info') >= 0 ? 1 : 0);
	if (url == 'https://api.github.com/repos/MetaCubeX/mihomo/releases/latest'
		|| url == 'https://github.com/MetaCubeX/mihomo/releases/download/v9.0.1/mihomo-linux-arm64-v9.0.1.gz') {
		let output = args[index(args, '-o')+1];
		if (index(output, root + '/jobs/') != 0) die('Test refused external file write');
		fs.writefile(output, fs.readfile(root + (index(url, 'api.github.com') >= 0 ? '/fixture-release.json' : '/fixture-core.gz')));
		exit(0);
	}
	if (index(url, 'http://192.168.1.1:9090/') != 0) die('Test refused external network');
	let output = args[index(args, '-o')+1], method = args[index(args, '-X')+1];
	if (index(url, '/version') >= 0 && index(fs.readfile(root + '/core') || '', 'NEW') >= 0 && !fs.access(root + '/allow-new')) exit(1);
	if (method == 'PUT' && index(url, '/configs') >= 0) fs.writefile(root + '/selection', 'A');
	if (method == 'PUT' && index(url, '/proxies/') >= 0) fs.writefile(root + '/selection', 'B');
	fs.writefile(output, sprintf('%J', { proxies: { 'тест 🇩🇪': { type: 'Selector', now: fs.readfile(root + '/selection') || 'B', all: ['A','B'] } }, version: 'v9.0.0' }));
	exit(0);
}
if (cmd == '/bin/cp' || cmd == '/bin/rm' || cmd == '/bin/ln') {
	for (let i = 1; i < length(args); i++)
		if (substr(args[i],0,1) == '/' && index(args[i], root + '/') != 0) die('Test refused filesystem mutation');
	if (cmd == '/bin/ln' && fs.access(root + '/no-hardlinks')) exit(1);
	if (cmd == '/bin/cp' && args[length(args)-1] == root + '/core.mini-new' && fs.access(root + '/fail-copy')) {
		fs.writefile(root + '/core.mini-new', 'partial-write'); exit(1);
	}
	exit(system(args,20000));
}
if (cmd == '/bin/sync') {
	if (fs.access(root + '/drop-space')) fs.writefile(root + '/free-kib', '2048');
	exit(0);
}
if (cmd == '/bin/sleep') exit(0);
if (cmd == '/sbin/ip') exit(1);
if (cmd == '/etc/init.d/mihomo') {
	let f = fs.open(root + '/service-actions', 'a'); f.write(join(' ', args) + '\n'); f.close(); exit(0);
}
if (index(['/sbin/uci','/usr/sbin/nft'],cmd) >= 0) exit(0);
die('Test refused command: ' + cmd);
