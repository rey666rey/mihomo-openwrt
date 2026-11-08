// The test runner rewrites all paths and system boundaries into a private fixture.
import * as fs from 'fs';
import * as d from 'mihomo-mini-dns';
import { contract } from 'mihomo-mini-contract';

let count = 0;
function assert(ok, text) { if (!ok) die('FAIL: ' + text); count++; }
function throws(fn, text) { let caught = false; try { fn(); } catch(e) { caught = true; } assert(caught, text); }
fs.mkdir(d.STORE, 0o700); fs.mkdir(d.TMP, 0o700);
let original = fs.readfile(d.CONFIG);
let o = { enabled: true, resolvers: [d.ENDPOINTS[0], d.ENDPOINTS[1]] };
let graph = {
 '🌐 Web Stable': { type: 'Fallback', all: ['Leaf'] }, Leaf: { type: 'VLESS' },
 DIRECT: { type: 'Direct' }, Unsafe: { type: 'Selector', all: ['🌐 Web Stable', 'DIRECT'] },
 Cycle: { type: 'Selector', all: ['Cycle'] }, Missing: { type: 'Selector', all: ['Gone'] }
};
d.write(d.TMP + '/graph.json', graph);
assert(d.safe_group(graph, '🌐 Web Stable'), 'all safe branches accepted');
for (let name in ['Unsafe', 'Cycle', 'Missing', 'DIRECT', 'Gone']) assert(!d.safe_group(graph, name), 'unsafe graph rejected: ' + name);
throws(() => d.check_options({ resolvers: ['https://example.invalid/dns-query'] }), 'unapproved DNS endpoint rejected');
let text = d.candidate(original, o);
assert(index(text, 'enhanced-mode: fake-ip') >= 0, 'fake IP responses selected');
assert(index(text, 'https://1.1.1.1/dns-query#🌐 Web Stable') >= 0, 'user queries explicitly detoured');
assert(index(text, 'https://1.1.1.1/dns-query#DIRECT') >= 0, 'bootstrap encrypted and explicit');
assert(index(text, 'rules:\n  - MATCH,DIRECT') >= 0, 'traffic policy preserved byte for byte');
assert(d.valid_config(text, o), 'managed DNS recognized');
assert(!d.valid_config(replace(text, '#🌐 Web Stable', '#DIRECT'), o), 'edited DNS detour rejected');
throws(() => d.block(original + '\ndns:\n  enable: false\n'), 'duplicate DNS root rejected');
d.write(d.STORE + '/dns.json', o);
assert(contract(text) == null, 'protected config accepted by network contract');
assert(contract(replace(text, '#🌐 Web Stable', '#DIRECT')) != null, 'editor cannot silently disable protection');
assert(contract(replace(text, 'log-level: warning', 'log-level: info')) == null, 'ordinary editor changes remain allowed');
fs.writefile(d.CONFIG, text);
d.arm(true);
assert(d.armed() && d.summary().state == 'blocked', 'armed guard starts closed');
d.release();
assert(d.summary().state == 'active', 'verified graph opens only the protected DNS path');
fs.writefile(d.TMP + '/client-down', '1'); d.hold();
throws(() => d.release(), 'unavailable client forwarder prevents release');
assert(d.summary().state == 'blocked', 'guard stays closed until client DNS is ready');
fs.unlink(d.TMP + '/client-down'); d.release();
let rules = d.rules(false);
assert(index(rules, 'redirect to :1056') >= 0 && index(d.rules(true), 'redirect to :1054') >= 0, 'client DNS switches between listener and blocked port');
assert(index(rules, 'ip daddr 198.18.0.0/16 counter reject') >= 0, 'fake IPs cannot escape via forwarding');
assert(index(rules, 'priority -100') >= 0, 'DNS uses standard DNAT priority for established TCP');
assert(index(rules, 'iifname != "br-lan" return') >= 0 && index(rules, 'ip saddr 192.168.1.111 return') >= 0, 'LTE and monitoring are excluded');
assert(index(rules, 'th dport { 53, 853 }') >= 0 && index(rules, 'meta nfproto ipv6') >= 0, 'classic DNS, DoT/DoQ and public IPv6 guarded');
// A failed/crashed core never invokes an implicit direct-mode operation.
fs.writefile(d.TMP + '/listener-down', '1');
assert(d.summary().state == 'blocked', 'core listener loss reports blocked');
assert(length(d.failure()) > 0 && d.armed(), 'failure keeps the independent guard armed');
fs.unlink(d.TMP + '/listener-down'); d.release();
fs.writefile(d.TMP + '/table', 'foreign-edited-table'); d.tick();
assert(d.summary().state == 'blocked', 'firewall drift restores a closed guard');
d.release();
fs.writefile(d.CONFIG, replace(text, '#🌐 Web Stable', '#DIRECT')); d.tick();
assert(d.summary().state == 'conflict', 'config drift is visible');
throws(() => d.release(), 'changed DNS cannot be reopened');
fs.writefile(d.CONFIG, text); d.release();
graph['🌐 Web Stable'].all = ['DIRECT']; d.write(d.TMP + '/graph.json', graph);
throws(() => d.release(), 'new unsafe provider/group branch rejected');
graph['🌐 Web Stable'].all = ['Leaf']; d.write(d.TMP + '/graph.json', graph);
fs.writefile(d.TMP + '/emergency', '1'); d.disarm();
throws(() => d.arm(false), 'emergency cancellation dominates queued work');
assert(!fs.access(d.TMP + '/table'), 'emergency removes only owned table');
fs.unlink(d.TMP + '/emergency');
fs.writefile(d.TMP + '/fail-apply', '1');
throws(() => d.arm(false), 'kernel rule failure propagated');
fs.unlink(d.TMP + '/fail-apply'); d.arm(true); d.release();
d.disable();
assert(!d.armed() && !fs.access(d.TMP + '/table') && !d.settings().enabled, 'explicit disable returns baseline DNS');
o.enabled = true; d.write(d.STORE + '/dns.json', o);
d.boot(); assert(!d.armed(), 'core autostart disabled means unarmed DNS after boot');
fs.writefile(d.TMP + '/autostart', '1'); d.boot();
assert(d.armed() && d.summary().state == 'blocked', 'boot protection precedes core readiness');
d.release();
// Simulate an emergency arriving after nft applied but before its caller returns.
d.disarm(); fs.writefile(d.TMP + '/race-emergency', '1'); d.arm(false);
assert(!d.armed() && !fs.access(d.TMP + '/table'), 'late transaction cannot resurrect guard after emergency');
print('PASS: ', count, ' isolated DNS safety assertions\n');
