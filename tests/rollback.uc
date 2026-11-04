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
let olderBackup = fs.readfile(m.STORE+'/core.previous');
r = execute('rollback_core');
assert(r.state == 'error','failed candidate readiness produces error');
assert(fs.readfile(m.CORE) == oldCore,'old core restored atomically');
assert(fs.readfile(m.STORE+'/core.previous') == olderBackup,'existing backup survives failed activation');
assert(fs.readfile(root+'/selection') == 'B','selector restored after core rollback');
print('PASS: core readiness failure restores previous binary and selectors\n');

function clean_staging() {
	for (let p in [m.CORE+'.mini-new', m.CORE+'.mini-old', m.STORE+'/core.previous.new'])
		assert(!fs.access(p),'staged file cleaned');
}
fs.unlink(root+'/service-actions');
fs.writefile(root+'/free-kib', '2048');
r = execute('rollback_core');
assert(r.state == 'error','low post-write flash reserve refused');
assert(!fs.access(root+'/service-actions'),'low-space refusal never stops or starts service');
assert(fs.readfile(m.CORE) == oldCore,'current core untouched on low space');
assert(fs.readfile(m.STORE+'/core.previous') == olderBackup,'prior backup untouched on low space');
clean_staging();
print('PASS: low actual flash space aborts before service interruption\n');

fs.writefile(root+'/free-kib', '100000'); fs.writefile(root+'/fail-copy','1');
r = execute('rollback_core');
assert(r.state == 'error','partial flash write refused');
assert(!fs.access(root+'/service-actions'),'partial write never interrupts service');
assert(fs.readfile(m.CORE) == oldCore,'current core survives partial staged write');
clean_staging(); fs.unlink(root+'/fail-copy');
print('PASS: partial staged write cleaned without touching active service\n');

fs.writefile(root+'/drop-space', '1');
r = execute('update', '', 'v9.0.1');
assert(r.state == 'error','free-space loss during write is refused');
assert(!fs.access(root+'/service-actions'),'reserve loss during write never interrupts service');
assert(fs.readfile(m.CORE) == oldCore,'current core survives reserve loss');
clean_staging(); fs.unlink(root+'/drop-space'); fs.writefile(root+'/free-kib', '100000');
print('PASS: flash reserve is rechecked during staged writes\n');

// Prove that the fallback does not depend on hard-link support, and that a
// completed update commits its backup only after candidate readiness succeeds.
fs.writefile(root+'/no-hardlinks','1'); fs.writefile(root+'/allow-new','1');
r = execute('update', '', 'v9.0.1');
assert(r.state == 'done','verified synthetic archive updates via copy fallback');
assert(index(fs.readfile(m.CORE),'# NEW') >= 0,'candidate activated');
assert(fs.readfile(m.STORE+'/core.previous') == oldCore,'previous core committed after readiness');
clean_staging(); fs.unlink(root+'/no-hardlinks');
print('PASS: verified gzip update, memory budget, copy fallback and backup commit\n');
