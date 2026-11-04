import * as fs from 'fs';
import { sha256 } from 'digest';
import { contract } from 'mihomo-mini-contract';
import * as m from 'mihomo-mini';

let count = 0;
function assert(ok, message) { if (!ok) die('FAIL: ' + message); count++; }
let original = fs.readfile(m.CONFIG), base = sha256(original);
assert(contract(original) == null, 'current YAML accepted');
for (let pair in [
	['tproxy-port: 7893', 'tproxy-port: 9999'],
	['mixed-port: 7890', 'mixed-port: 9999'],
	['external-controller: 192.168.1.1:9090', 'external-controller: 0.0.0.0:9090'],
	['  enable: false', '  enable: true'],
	['  listen: 127.0.0.1:1053', '  listen: 0.0.0.0:53'],
	['tun:\n  enable: false', 'tun: {enable: true}'],
	['tun:\n  enable: false', 'tun:\n  enable: false\n  "enable": true'],
	['tun:\n  enable: false', 'tun:\n  enable: false\n  <<: *unsafe']
]) assert(contract(replace(original, pair[0], pair[1])) != null, 'network contract rejected unsafe change');
assert(contract(original + '\nmixed-port: 7890\n') != null, 'duplicate root rejected');
assert(contract(original + '\nTun:\n  enable: true\n') != null, 'case collision rejected');
assert(contract(original + '\n<<: *other\n') != null, 'root merge rejected');
assert(contract(original + '\n\tbad: true\n') != null, 'tabs rejected');

function wait(id) {
	for (let i = 0; i < 75; i++) {
		let r = m.readjson(m.TMP + '/' + id + '/result.json');
		if (r?.state == 'done' || r?.state == 'error') {
			// Let final journal/lock cleanup complete before the next submission.
			for (let j = 0; j < 10 && fs.access(m.TMP + '/lock'); j++) m.run(['/bin/sleep', '1'], 2000);
			return r;
		}
		m.run(['/bin/sleep', '1'], 2000);
	}
	die('worker timeout');
}
let job = m.enqueue('validate', original, base);
assert(job.ok, 'validation queued');
let r = wait(job.id);
assert(r.state == 'done' && r.hash == base, 'real mihomo validation succeeds');
// A tiny fixture may validate before a second submission reaches the lock.
// Hold the shared exclusion directory explicitly for a deterministic conflict.
assert(fs.mkdir(m.TMP + '/lock', 0o700), 'test exclusion lock acquired');
let parallel = m.enqueue('validate', original, base);
assert(!parallel.ok, 'parallel operations locked');
fs.rmdir(m.TMP + '/lock');

job = m.enqueue('validate', original + '\ninvalid-field: [\n', base);
assert(job.ok, 'invalid YAML job queued');
r = wait(job.id);
assert(r.state == 'error', 'real mihomo rejects broken YAML');
assert(index(r.message, 'secret') < 0 && index(r.message, 'https://') < 0, 'validation error redacted');

job = m.enqueue('apply', original, 'outdated-hash');
r = wait(job.id);
assert(r.state == 'error' && m.hash_config() == base, 'stale editor cannot overwrite config');

job = m.enqueue('apply', original, base);
r = wait(job.id);
assert(r.state == 'done' && m.hash_config() == base, 'no-op apply does not reload or alter service');
assert(!fs.access(m.STORE + '/config.previous.yaml'), 'no-op does not replace backup');
assert(!m.enqueue('bad-action', '', '').ok, 'unknown action rejected');
assert(!m.enqueue('validate', sprintf('%524289s', 'x'), '').ok, 'oversized input rejected');
print('PASS: ', count, ' backend assertions\n');
