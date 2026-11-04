import * as fs from 'fs';
import * as m from 'mihomo-mini';
const root = '/tmp/mihomo-mini-faults';
function assert(ok, text) { if (!ok) die('FAIL: ' + text); }
function execute(action, content, base) {
	let job = m.enqueue(action, content || '', base || '');
	assert(job.ok,'queued');
	for (let i = 0; i < 20; i++) {
		let r = m.readjson(m.TMP + '/' + job.id + '/result.json');
		if (r?.state == 'done' || r?.state == 'error') {
			while (fs.access(m.TMP + '/lock')) system(['/bin/sleep','1']);
			return r;
		}
		system(['/bin/sleep','1']);
	}
	die('test timeout');
}
let original = fs.readfile(m.CONFIG), hash = m.hash_config();
let changed = replace(original, 'log-level: warning', 'log-level: info');
assert(changed != original,'fixture differs');
let r = execute('apply', changed, hash);
assert(r.state == 'error','failed network check produces error');
assert(m.hash_config() == hash,'config restored after post-reload failure');
assert(fs.readfile(root+'/selection') == 'B','selector restored after rollback');
assert(fs.readfile(m.STORE+'/config.previous.yaml') == original,'backup survives rollback');
print('PASS: configuration failure rolls back file and selectors\n');

m.init();
fs.writefile(m.CORE, '#!/bin/sh\n# OLD\necho "Mihomo Meta v9.0.0 linux arm64"\nexit 0\n'); fs.chmod(m.CORE,0o755);
fs.writefile(m.STORE+'/core.previous', '#!/bin/sh\n# NEW\necho "Mihomo Meta v9.0.1 linux arm64"\nexit 0\n'); fs.chmod(m.STORE+'/core.previous',0o755);
let oldCore = fs.readfile(m.CORE);
r = execute('rollback_core');
assert(r.state == 'error','failed candidate readiness produces error');
assert(fs.readfile(m.CORE) == oldCore,'old core restored atomically');
assert(fs.readfile(root+'/selection') == 'B','selector restored after core rollback');
print('PASS: core readiness failure restores previous binary and selectors\n');
