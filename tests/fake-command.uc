#!/usr/bin/ucode
// Isolated fault injection: no network or service mutation is permitted here.
import * as fs from 'fs';
const root = '/tmp/mihomo-mini-faults';
let args = ARGV, cmd = args[0];
if (cmd == '/usr/bin/curl') {
	let url = args[length(args)-1];
	if (index(args, '-x') >= 0) exit(index(fs.readfile(root + '/config.yaml') || '', 'log-level: info') >= 0 ? 1 : 0);
	if (index(url, 'http://192.168.1.1:9090/') != 0) die('Test refused external network');
	let output = args[index(args, '-o')+1], method = args[index(args, '-X')+1];
	if (index(url, '/version') >= 0 && index(fs.readfile(root + '/core') || '', 'NEW') >= 0) exit(1);
	if (method == 'PUT' && index(url, '/configs') >= 0) fs.writefile(root + '/selection', 'A');
	if (method == 'PUT' && index(url, '/proxies/') >= 0) fs.writefile(root + '/selection', 'B');
	fs.writefile(output, sprintf('%J', { proxies: { 'тест 🇩🇪': { type: 'Selector', now: fs.readfile(root + '/selection') || 'B', all: ['A','B'] } }, version: 'v9.0.0' }));
	exit(0);
}
if (cmd == '/bin/cp' || cmd == '/bin/rm') {
	for (let i = 1; i < length(args); i++)
		if (substr(args[i],0,1) == '/' && index(args[i], root + '/') != 0) die('Test refused filesystem mutation');
	exit(system(args,20000));
}
if (cmd == '/bin/sleep') exit(0);
if (cmd == '/sbin/ip') exit(1);
if (index(['/sbin/uci','/etc/init.d/mihomo','/usr/sbin/nft'],cmd) >= 0) exit(0);
die('Test refused command: ' + cmd);
