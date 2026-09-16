'use strict';
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const cp = require('node:child_process');
const crypto = require('node:crypto');
const http = require('node:http');
const https = require('node:https');
const net = require('node:net');

const repo = __dirname;
const root = path.resolve(repo, '..');
const windows = process.platform === 'win32';
const bash = process.env.TEST_BASH || (windows ? path.join(root, 'tools/git-portable/usr/bin/bash.exe') : 'bash');
const engine = process.env.TEST_SINGBOX || path.join(root, 'tools/singbox-audit/sing-box-1.14.0-windows-amd64/sing-box.exe');
const jqDir = process.env.TEST_JQ_DIR || path.join(root, 'tools/singbox-audit');
const main = fs.readFileSync(path.join(repo, 'install-singbox-yyds.sh'), 'utf8');
const entry = fs.readFileSync(path.join(repo, 'install.sh'), 'utf8');
const temp = fs.mkdtempSync(path.join(os.tmpdir(), 'singbox-regression-'));
const forward = s => s.replaceAll('\\', '/');
const dir = forward(temp);
const env = {...process.env, PATH: jqDir + path.delimiter + path.dirname(bash) + path.delimiter + process.env.PATH};
const children = [];
const servers = [];
let passed = 0;
function assert(value, description) {
  if (!value) throw Error(description);
  console.log('PASS ' + description);
  passed++;
}
function run(text, args = ['-s'], extraEnv = {}) {
  const r = cp.spawnSync(bash, args, {input: text, encoding:'utf8', timeout:25000, env:{...env,...extraEnv}, cwd:temp});
  if (r.error) throw r.error;
  return r;
}
function ok(r, description) { assert(r.status === 0, description + (r.status ? ': ' + r.stderr + r.stdout : '')); }
function block(text, marker) {
  const start = text.indexOf("<<'" + marker + "'");
  if (start < 0) throw Error('Missing heredoc ' + marker);
  const body = text.indexOf('\n', start) + 1;
  return text.slice(body, text.indexOf('\n' + marker, body)) + '\n';
}
function func(text, name) {
  const start = text.indexOf(name + '() {');
  const end = text.indexOf(name === 'create_config' ? '\n}\n\n# 调用配置生成' : '\n}\n', start);
  if (start < 0 || end < 0) throw Error('Missing function ' + name);
  return text.slice(start, end + 3);
}
const manager = block(main, 'SB_SCRIPT');
const relay = block(manager, 'RELAY_EOF');
const helpers = ['validate_port','validate_host','install_upstream'].map(n => func(main,n)).join('\n');
const prelude = 'set -euo pipefail\ninfo(){ :; }\nwarn(){ :; }\nerr(){ echo "$*" >&2; }\n' + helpers + '\n';
const fixtures = {};
async function freePort() {
  const s = net.createServer();
  await new Promise((resolve,reject) => s.once('error',reject).listen(0,'127.0.0.1',resolve));
  const p = s.address().port;
  await new Promise(resolve=>s.close(resolve));
  return p;
}
async function waitPort(port, child) {
  for (let i=0;i<60;i++) {
    if (child.exitCode !== null) throw Error('sing-box exited before listening: ' + child.diagnostic);
    const ready = await new Promise(resolve=>{
      const s=net.connect({host:'127.0.0.1',port});
      s.once('connect',()=>{s.destroy();resolve(true)});
      s.once('error',()=>resolve(false));
    });
    if(ready)return;
    await new Promise(r=>setTimeout(r,100));
  }
  throw Error('listen timeout: ' + child.diagnostic);
}
function startEngine(config, name) {
  const file = path.join(temp, name + '.json');
  fs.writeFileSync(file, JSON.stringify(config));
  const child=cp.spawn(engine,['run','-c',file],{stdio:['ignore','pipe','pipe'],windowsHide:true});
  child.diagnostic='';
  child.stderr.on('data',x=>child.diagnostic+=x.toString());
  child.stdout.on('data',x=>child.diagnostic+=x.toString());
  child.on('error',x=>child.diagnostic+=x.message);
  children.push(child);
  return child;
}
async function stop(child) {
  if(child.exitCode!==null)return;
  child.kill();
  await new Promise(resolve=>{child.once('exit',resolve);setTimeout(resolve,2500)});
}
async function suite() {
  for(const [name,text] of Object.entries({main,entry,manager,relay}))ok(run(text,['-n']),'syntax '+name);
  ok(run('', ['-c',entry,'bootstrap','--version']),'bootstrap works under bash -c');
  assert(!main.includes('. "$CACHE_FILE"') && !manager.includes('. "$PROTOCOL_FILE"'),'no executable shell cache');
  ok(run(prelude+'for p in 1 80 00443 65535; do validate_port "$p"; done\n'),'valid port normalization inputs');
  for(const p of ['0','65536','abc','12;echo INJECTED','-1','1.5','123456']) {
    assert(run(prelude+'validate_port "$TEST_PORT"\n',['-s'],{TEST_PORT:p}).status!==0,'reject port '+p);
  }
  const upstreamFailure=run(prelude+'curl(){ return 22; }\ninstall_upstream\n');
  assert(upstreamFailure.status!==0,'download failure returns failure');
  const fallback=run(prelude+'OS=alpine; SERVICE_NAME=sing-box\nrc-service(){ return 3; }\nsystemctl(){ echo WRONG_PLATFORM; return 127; }\n'+func(manager,'service_status')+'\nservice_status\n');
  assert(fallback.status===3&&!fallback.stdout.includes('WRONG_PLATFORM'),'OpenRC failure does not call systemctl');

  // Local transport stub: test bootstrap checksum, failure and stdin handling without running installation.
  const mock='#!/usr/bin/env bash\nread -r answer\nprintf "INPUT=%s\\n" "$answer"\n';
  const fixture=path.join(temp,'download-fixture.sh');
  fs.writeFileSync(fixture,mock);
  const sum=crypto.createHash('sha256').update(mock).digest('hex');
  const stub=String.raw`curl(){ local target=""; while [ "$#" -gt 0 ]; do if [ "$1" = -o ]; then target="$2"; shift; fi; shift; done; cp "$TEST_FIXTURE" "$target"; }
id(){ echo 0; }
export -f curl id
`;
  const testEntry=entry.replace(/[a-f0-9]{64}|__MAIN_SHA256__/,sum);
  ok(run(stub+'bash -c "$TEST_ENTRY" bootstrap --check\n',['-s'],{TEST_ENTRY:testEntry,TEST_FIXTURE:forward(fixture)}),'bootstrap download/checksum check mode');
  const stdin=run(stub+'bash -c "$TEST_ENTRY" <<< "interactive-ok"\n',['-s'],{TEST_ENTRY:testEntry,TEST_FIXTURE:forward(fixture)});
  assert(stdin.status===0&&stdin.stdout.includes('INPUT=interactive-ok'),'bootstrap preserves interactive stdin');
  const corrupt=run(stub+'bash -c "$TEST_ENTRY" bootstrap --check\n',['-s'],{TEST_ENTRY:testEntry.replace(sum,'0'.repeat(64)),TEST_FIXTURE:forward(fixture)});
  assert(corrupt.status!==0,'bootstrap rejects corrupt download');

  fs.mkdirSync(path.join(temp,'certs'));
  const cert=run('openssl req -x509 -newkey rsa:2048 -nodes -keyout "'+dir+'/certs/privkey.pem" -out "'+dir+'/certs/fullchain.pem" -days 1 -subj /CN=www.bing.com\n',['-s'],{MSYS_NO_PATHCONV:'1'});
  ok(cert,'generate local test TLS certificate');
  const keyResult=cp.spawnSync(engine,['generate','reality-keypair'],{encoding:'utf8'});
  ok(keyResult,'real sing-box Reality key generation');
  const privateKey=keyResult.stdout.match(/PrivateKey:\s*(\S+)/)[1];
  const publicKey=keyResult.stdout.match(/PublicKey:\s*(\S+)/)[1];
  const sid='0123456789abcdef';
  const names=['SS','HY2','TUIC','REALITY','ANYTLS'];
  const ports=await Promise.all(names.map(()=>freePort()));
  const confFunc=func(main,'create_config').replaceAll('/etc/sing-box',dir);
  for(const mask of [1,2,4,8,16,31]) {
    const config=forward(path.join(temp,'config-'+mask+'.json'));
    let setup=prelude+'\nsing-box(){ "'+forward(engine)+'" "$@"; }\n'+confFunc+'\nCONFIG_PATH="'+config+'"\n';
    names.forEach((n,i)=>{setup+='ENABLE_'+n+'='+!!(mask&(1<<i))+'\nPORT_'+n+'='+ports[i]+'\n';});
    // create_config is extracted and called directly, so interactive-only
    // variables must have explicit defaults under bash -u.
    setup+='ENABLE_REALITY_GUARD=false\nREALITY_GUARD_PORT=9443\n';
    setup+='SS_METHOD=2022-blake3-aes-128-gcm\nPSK_SS=AAAAAAAAAAAAAAAAAAAAAA==\nPSK_HY2=test-password\nPSK_TUIC=test-password\nUUID=12345678-1234-4234-8234-123456789abc\nUUID_TUIC=12345678-1234-4234-8234-123456789abc\nANYTLS_USER=test\nANYTLS_PSK=test-password\nCUSTOM_IP=2001:db8::1\nREALITY_SNI=www.bing.com\nREALITY_PK='+privateKey+'\nREALITY_PUB='+publicKey+'\nREALITY_SID='+sid+'\ncreate_config\n';
    ok(run(setup),'real engine validates generated configuration mask='+mask);
    const parsed=JSON.parse(fs.readFileSync(config));
    assert(parsed.inbounds.length===names.filter((_,i)=>mask&(1<<i)).length,'selected protocols retained mask='+mask);
    fixtures[mask]=parsed;
    const cache=JSON.parse(fs.readFileSync(path.join(temp,'.config_cache')));
    assert(cache.REALITY_SNI==='www.bing.com'&&!('SS_PSK' in cache),'safe JSON metadata mask='+mask);
  }
  const target=path.join(temp,'config.json');
  fs.writeFileSync(target,JSON.stringify(fixtures[16]));
  const readFn=func(manager,'read_config').replaceAll('/etc/sing-box',dir);
  fs.writeFileSync(path.join(temp,'.reality_pub'),publicKey);
  const readTest=run(prelude+readFn+'\nCONFIG_PATH="'+forward(target)+'"\nCACHE_FILE="'+dir+'/.config_cache"\nread_config\n[ "$REALITY_SNI" = www.bing.com ]\n[ "$ENABLE_ANYTLS" = true ]\n[ "$CUSTOM_IP" = 2001:db8::1 ]\n');
  ok(readTest,'AnyTLS-only custom SNI and IPv6 survive config reload');
  fs.writeFileSync(path.join(temp,'.config_cache'),'CUSTOM_IP=$(echo CACHE_EXECUTED)\n');
  const legacy=run(prelude+readFn+'\nCONFIG_PATH="'+forward(target)+'"\nCACHE_FILE="'+dir+'/.config_cache"\nread_config\n');
  assert(legacy.status!==0&&!legacy.stdout.includes('CACHE_EXECUTED'),'legacy cache injection rejected without execution');

  // Actual loopback traffic through each protocol, using a local TLS handshake endpoint for Reality.
  const httpServer=http.createServer((req,res)=>res.end('SINGBOX_TRAFFIC_OK'));
  servers.push(httpServer);
  await new Promise(r=>httpServer.listen(0,'127.0.0.1',r));
  const targetPort=httpServer.address().port;
  const tlsServer=https.createServer({key:fs.readFileSync(path.join(temp,'certs/privkey.pem')),cert:fs.readFileSync(path.join(temp,'certs/fullchain.pem')),minVersion:'TLSv1.3'},(req,res)=>res.end('handshake'));
  servers.push(tlsServer);
  await new Promise(r=>tlsServer.listen(0,'127.0.0.1',r));
  const serverConfig=fixtures[31];
  serverConfig.ntp.enabled=false;
  serverConfig.inbounds.forEach(i=>{
    i.listen='127.0.0.1';
    if(i.tls?.reality)i.tls.reality.handshake={server:'127.0.0.1',server_port:tlsServer.address().port};
  });
  const serverChild=startEngine(serverConfig,'server');
  await waitPort(ports[0],serverChild);
  for(const inbound of serverConfig.inbounds) {
    const mixedPort=await freePort();
    const outbound={type:inbound.type,server:'127.0.0.1',server_port:inbound.listen_port,tag:'test'};
    if(inbound.type==='shadowsocks')Object.assign(outbound,{method:inbound.method,password:inbound.password});
    else if(inbound.type==='hysteria2')Object.assign(outbound,{password:inbound.users[0].password,tls:{enabled:true,insecure:true,server_name:'www.bing.com',alpn:['h3']}});
    else if(inbound.type==='tuic')Object.assign(outbound,{uuid:inbound.users[0].uuid,password:inbound.users[0].password,congestion_control:'bbr',tls:{enabled:true,insecure:true,server_name:'www.bing.com',alpn:['h3']}});
    else {
      if(inbound.type==='vless')Object.assign(outbound,{uuid:inbound.users[0].uuid,flow:'xtls-rprx-vision'});
      else outbound.password=inbound.users[0].password;
      outbound.tls={enabled:true,server_name:'www.bing.com',utls:{enabled:true,fingerprint:'chrome'},reality:{enabled:true,public_key:publicKey,short_id:sid}};
    }
    const client=startEngine({inbounds:[{type:'mixed',listen:'127.0.0.1',listen_port:mixedPort}],outbounds:[outbound]},'client-'+inbound.type);
    await waitPort(mixedPort,client);
    const response=await new Promise((resolve,reject)=>{
      const req=http.get({host:'127.0.0.1',port:mixedPort,path:'http://127.0.0.1:'+targetPort+'/',headers:{Host:'127.0.0.1:'+targetPort}},res=>{
        let body='';res.on('data',x=>body+=x);res.on('end',()=>resolve(body));
      });
      req.setTimeout(12000,()=>req.destroy(Error('protocol traffic timeout')));
      req.on('error',reject);
    }).catch(e=>{throw Error(inbound.type+': '+e.message+'\nclient: '+client.diagnostic+'\nserver: '+serverChild.diagnostic)});
    assert(response==='SINGBOX_TRAFFIC_OK','actual loopback traffic '+inbound.type);
    await stop(client);
  }
  console.log('RESULT '+passed+' assertions passed; engine='+engine);
}
suite().catch(e=>{console.error(e.stack);process.exitCode=1}).finally(async()=>{
  for(const child of children)await stop(child);
  for(const server of servers){server.closeAllConnections?.();server.close();}
  // Delete only this test's mkdtemp directory.
  fs.rmSync(temp,{recursive:true,force:true});
});
