const assert = require('node:assert/strict');
const fs = require('node:fs');
const source = fs.readFileSync(__dirname + '/../htdocs/luci-static/resources/view/mihomo-mini/overview.js', 'utf8');
class Element {
  constructor(tag, attrs, children) {
    this.tag = tag; this.attrs = attrs || {}; this.children = []; this.value = ''; this.textContent = ''; this.hidden = Object.hasOwn(this.attrs, 'hidden');
    for (const x of Array.isArray(children) ? children : [children]) if (x != null) this.appendChild(x);
  }
  appendChild(x) { this.children.push(x); return x; }
  replaceChildren(...children) { this.children = children; }
  setAttribute(k,v) { this.attrs[k] = v; }
  focus() {}
  click() { return this.attrs.click?.({ target: this }); }
}
const E = (tag, attrs, children) => new Element(tag, attrs, children);
const calls = [], queue = {};
let state = { ok:true,running:true,tproxy:true,autostart:false,version:'v1.19.32',config_hash:'hash-a',config_backup:false,core_backup:false,busy:null,latest:null,journal:[],dns:{enabled:true,armed:true,state:'active',mode:'fake-ip',resolvers:['https://1.1.1.1/dns-query'],last_check:null} };
let permission = true, config = 'example: yaml', job = null, poller, jobUnavailable=false;
const rpc = { declare: ({method}) => async (...args) => {
  calls.push([method,...args]);
  if (method === 'status') return {...state};
  if (method === 'germany_squads') return {ok:true,squads:[{name:'🇩🇪 MASTER · s1 v2',exit_ip:'192.0.2.1',country:'DE',ipify_ip:'198.51.100.1',ipify_country:'RU',checked_at:'2026-11-08T14:21:37+00:00'}]};
  if (method === 'finland_squads') return {ok:true,squads:[{name:'🇫🇮 DOG · Finland',exit_ip:'192.0.2.2',country:'FI',ipify_ip:'198.51.100.2',ipify_country:'RU',checked_at:'2026-11-08T14:41:48+00:00'}]};
  if (method === 'config') return {ok:true,content:config,hash:state.config_hash};
  if (method === 'action') { job={state:'running',action:args[0],message:'working'}; return {ok:true,id:'job-abcdef'}; }
  if (method === 'job') return jobUnavailable ? {ok:false,error:'missing'} : {ok:true,result:job};
  if (method === 'direct') return {ok:true,message:'direct'};
} };
const L = {hasViewPermission:()=>permission,resource:p=>'/luci-static/resources/'+p};
const ui = {showModal(){},hideModal(){}};
const window = {confirm:()=>true,addEventListener(){},open(){}};
const app = new Function('view','rpc','ui','poll','E','L','window',source)({extend:x=>x},rpc,ui,{add:fn=>{poller=fn;}},E,L,window);
(async()=>{
  const root = app.render(state);
  assert(root);
  await app.buttons.germanySquads.click();
  await app.buttons.finlandSquads.click();
  const rendered = JSON.stringify(root);
  assert(rendered.includes('IPv4 · Cloudflare'));
  assert(rendered.includes('192.0.2.1 · DE'));
  assert(rendered.includes('198.51.100.1 · RU'));
  assert(rendered.includes('192.0.2.2 · FI'));
  assert(rendered.includes('198.51.100.2 · RU'));
  assert(app.buttons.start.disabled);
  assert.equal(app.dnsStatus.textContent,'Правила защиты включены');
  assert(!app.buttons.dnsEnable.disabled);
  assert(!app.buttons.dnsCheck.disabled);
  assert(!app.buttons.stop.disabled);
  assert(!app.buttons.tproxy.disabled);
  assert(app.buttons.apply.disabled);
  assert.equal(app.loaded,false);
  assert.equal(calls.filter(c=>c[0]==='config').length,0,'secrets not fetched on page load');
  await app.readConfig(false);
  assert.equal(app.editor.value,config);
  assert(app.buttons.apply.disabled);
  await app.act('validate');
  assert(app.buttons.apply.disabled,'pending validation cannot apply');
  job={state:'done',message:'valid'}; await app.refresh();
  assert.equal(app.buttons.apply.disabled,false);
  app.editor.value+='\nchanged: true'; app.editor.attrs.input();
  assert(app.buttons.apply.disabled,'editing invalidates validation');
  app.validated=app.editor.value; state.config_hash='changed-elsewhere'; await app.refresh();
  assert(app.buttons.apply.disabled,'stale base cannot apply');
  assert.equal(app.conflict.hidden,false);
  app.pending=true; app.paint(); assert(app.buttons.dnsEnable.disabled); assert(app.buttons.dnsDisable.disabled); assert(app.buttons.restart.disabled); assert(!app.buttons.direct.disabled,'direct remains available during operation');
  app.pending=false; state.config_hash=app.baseHash; permission=false; app.paint();
  assert(app.buttons.direct.disabled); assert(app.buttons.validate.disabled); assert(app.buttons.dnsEnable.disabled); assert(app.buttons.dnsCheck.disabled); assert(app.editor.readOnly);
  permission=true; app.state={...state,running:false,tproxy:false}; app.paint();
  assert(!app.buttons.start.disabled); assert(app.buttons.tproxy.disabled); assert(app.buttons.dnsEnable.disabled); assert(app.autostart.disabled);
  app.showDiagnostics({direct:true,dns:true,proxy:null,api:null}); assert.equal(app.diagResult.children.length,4);
  assert.equal(calls.filter(c=>c[0]==='action'&&c[1]==='update').length,0,'update never auto-installs');
  app.jobId='job-expired'; app.pending=true; jobUnavailable=true;
  await app.refresh();
  assert.equal(app.pending,false,'expired result does not leave UI locked');
  assert.equal(app.jobId,null);
  console.log('PASS: frontend state, validation, concurrency, permissions and diagnostics');
})().catch(e=>{console.error(e);process.exitCode=1;});
