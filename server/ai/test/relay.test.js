import test from 'node:test';
import assert from 'node:assert/strict';
import http from 'node:http';
import {createApp} from '../src/app.js';
import {parseRequest,ApiError} from '../src/request.js';
import {loadConfig,vertexUrl,createVertex} from '../src/vertex.js';
import {createFirebaseVerifier} from '../src/auth.js';
import {createDailyQuota} from '../src/quota.js';
import {TransactionStore} from './quota-store.js';

const token='firebase-test-header.firebase-test-alice.firebase-test-signature';
const otherToken='firebase-test-header.firebase-test-bob.firebase-test-signature';
const verifyAuth=async value=>{if(value===token)return {uid:'alice'};if(value===otherToken)return {uid:'bob'};throw Error('Invalid test ID token');};
const config=loadConfig({GOOGLE_CLOUD_PROJECT:'after-hue-pdhaku0'});
const requestBody=(extra={})=>({purpose:'develop',contents:[{role:'user',parts:[{text:'Keep the pink flowers.'}]}],...extra});
const result={candidates:[{content:{role:'model',parts:[{functionCall:{name:'render',args:{mood:.2}},thoughtSignature:'opaque-signature==',thought:true,extraMetadata:'preserved'}]},finishReason:'STOP'}],usageMetadata:{totalTokenCount:10}};
async function start(t,{generate=async()=>result,limits,settings=config,verify=verifyAuth,now,quota}={}){
  const app=createApp({config:settings,generate,verifyAuth:verify,quota:quota??createDailyQuota(settings,{db:new TransactionStore(),env:{}}),...(limits?{limits}:{}),...(now?{now}:{})});
  const server=app.listen(0,'127.0.0.1');await new Promise(r=>server.once('listening',r));
  t.after(()=>new Promise(r=>{server.closeAllConnections();server.close(r);}));
  const root=`http://127.0.0.1:${server.address().port}`;
  return {root,async send(body=requestBody(),auth=token){
    const response=await fetch(`${root}/v1/generate`,{method:'POST',headers:{'Content-Type':'application/json',...(auth?{Authorization:`Bearer ${auth}`}:{})},body:JSON.stringify(body)});
    return {status:response.status,data:await response.json()};
  }};
}

test('startup fails closed for missing project/auth verification and unapproved models or endpoints',()=>{
  assert.throws(()=>loadConfig({}),/project/i);
  assert.throws(()=>createApp({config,generate:async()=>result,quota:{reserve:async()=>{}}}),/authentication/i);
  assert.throws(()=>loadConfig({GOOGLE_CLOUD_PROJECT:'after-hue-pdhaku0',AI_DAILY_REQUEST_LIMIT:'0'}),/daily/i);
  assert.throws(()=>createApp({config,generate:async()=>result,verifyAuth}),/durable/i);
  assert.throws(()=>loadConfig({GOOGLE_CLOUD_PROJECT:'after-hue-pdhaku0',VERTEX_DEVELOP_MODEL:'https://attacker.test'}),/model/i);
  assert.throws(()=>loadConfig({GOOGLE_CLOUD_PROJECT:'after-hue-pdhaku0',VERTEX_LOCATION:'global.attacker.test'}),/location/i);
  assert.equal(vertexUrl(config,config.models.develop),'https://aiplatform.googleapis.com/v1/projects/after-hue-pdhaku0/locations/global/publishers/google/models/gemini-3.8-flash:generateContent');
});

test('HTTP authentication happens before paid work; responses preserve complete Google parts',async t=>{
  let calls=0,received;const api=await start(t,{generate:async req=>{calls++;received=req;return result;}});
  assert.equal((await api.send(requestBody(),null)).status,401);
  assert.equal((await api.send(requestBody(),'wrong-token-00000000000000000000000000000')).status,401);
  assert.equal(calls,0);
  const history=[...requestBody().contents,result.candidates[0].content,{role:'user',parts:[{functionResponse:{name:'render',response:{ok:true},id:'call1'}}]}];
  const body=requestBody({contents:history,tools:[{functionDeclarations:[{name:'render',parametersJsonSchema:{type:'object',properties:{mood:{type:'number'}}}}]}]});
  const response=await api.send(body);assert.equal(response.status,200);assert.deepEqual(response.data,result);
  assert.deepEqual(received.payload.contents,history);
  assert.deepEqual(received.payload.tools,body.tools);
  assert.equal(received.model,'gemini-3.8-flash');assert.equal(received.payload.generationConfig.maxOutputTokens,8192);
});

test('server chooses each purpose model and clamps paid output volume',()=>{
  const judge=parseRequest(requestBody({purpose:'judge',generationConfig:{maxOutputTokens:100000,responseMimeType:'application/json',responseSchema:{type:'OBJECT',properties:{keep:{type:'BOOLEAN'}}}}}),config);
  assert.equal(judge.model,'gemini-3.5-flash-lite');assert.equal(judge.payload.generationConfig.maxOutputTokens,2048);
  assert.deepEqual(judge.payload.generationConfig.thinkingConfig,{thinkingLevel:'MINIMAL'});
  for(const extra of [{model:'gemini-ultra'},{project:'someone-else'},{endpoint:'https://attacker.test'},{generationConfig:{candidateCount:20}},{tools:[{googleSearch:{}}]}]) assert.throws(()=>parseRequest(requestBody(extra),config),{status:400});
});

test('bounded inline images allow full render history and forbid remote reads',()=>{
  const part={inlineData:{mimeType:'image/jpeg',data:Buffer.from('fake image').toString('base64')}};
  assert.equal(parseRequest(requestBody({contents:[{role:'user',parts:Array.from({length:12},()=>part)}]}),config).payload.contents[0].parts.length,12);
  assert.throws(()=>parseRequest(requestBody({contents:[{role:'user',parts:Array.from({length:13},()=>part)}]}),config),{status:413});
  assert.throws(()=>parseRequest(requestBody({contents:[{role:'user',parts:[{fileData:{fileUri:'gs://private/secrets'}}]}]}),config),{status:400});
  assert.throws(()=>parseRequest(requestBody({contents:[{role:'user',parts:[{text:'x'.repeat(512*1024)}]}]}),config),{status:413});
  const maxImage={inlineData:{mimeType:'image/png',data:Buffer.alloc(4*1024*1024).toString('base64')}};
  assert.doesNotThrow(()=>parseRequest(requestBody({contents:[{role:'user',parts:[maxImage]}]}),config));
  assert.throws(()=>parseRequest(requestBody({contents:[{role:'user',parts:[maxImage,maxImage,maxImage]}]}),config),{status:413});
});

test('concurrency rejects excess work and releases the slot on completion',async t=>{
  let release,entered;const gate=new Promise(r=>release=r),started=new Promise(r=>entered=r);
  let calls=0;const api=await start(t,{limits:{ipRate:20,globalRate:20,ipConcurrent:1,globalConcurrent:1},generate:async()=>{calls++;entered();await gate;return result;}});
  const first=api.send();await started;
  assert.equal((await api.send()).status,429);assert.equal(calls,1);
  release();assert.equal((await first).status,200);assert.equal((await api.send()).status,200);
});

test('client disconnect aborts upstream and frees concurrency for the next image',async t=>{
  let enter,aborted;const started=new Promise(r=>enter=r),cancelled=new Promise(r=>aborted=r);let calls=0;
  const api=await start(t,{limits:{ipRate:20,globalRate:20,ipConcurrent:1,globalConcurrent:1},generate:async({signal})=>{
    if(++calls>1)return result;
    enter();return new Promise((resolve,reject)=>signal.addEventListener('abort',()=>{aborted();reject(signal.reason);},{once:true}));
  }});
  const outgoing=http.request(`${api.root}/v1/generate`,{method:'POST',headers:{Authorization:`Bearer ${token}`,'Content-Type':'application/json'}});
  outgoing.on('error',()=>{});outgoing.end(JSON.stringify(requestBody()));await started;outgoing.destroy();await cancelled;
  assert.equal((await api.send()).status,200);assert.equal(calls,2);
});

test('timeout returns a clean error and releases the slot',async t=>{
  let calls=0;const api=await start(t,{settings:{...config,timeoutMs:20},limits:{ipRate:20,globalRate:20,ipConcurrent:1,globalConcurrent:1},generate:async({signal})=>{
    if(++calls>1)return result;
    return new Promise((resolve,reject)=>signal.addEventListener('abort',()=>reject(signal.reason),{once:true}));
  }});
  const timeout=await api.send();assert.equal(timeout.status,504);assert.equal(timeout.data.error.code,'ai_timeout');
  assert.equal((await api.send()).status,200);
});

test('IP and global request budgets independently stop further cloud calls',async t=>{
  for(const limits of [{ipRate:2,globalRate:10,ipConcurrent:2,globalConcurrent:2},{ipRate:10,globalRate:2,ipConcurrent:2,globalConcurrent:2}]){
    let calls=0;const api=await start(t,{limits,generate:async()=>{calls++;return result;}});
    assert.equal((await api.send()).status,200);assert.equal((await api.send()).status,200);assert.equal((await api.send()).status,429);assert.equal(calls,2);
  }
});

test('errors never include credentials, submitted content or upstream error details',async t=>{
  const secret='VERY-PRIVATE-PROMPT-AND-TOKEN';
  const api=await start(t,{generate:async()=>{throw Error(secret);}});
  const error=await api.send();assert.equal(error.status,503);assert.equal(JSON.stringify(error.data).includes(secret),false);assert.equal(JSON.stringify(error.data).includes(token),false);
});

test('Vertex transport uses ADC only, fixed endpoint and unchanged payload',async()=>{
  let request;
  const auth={async getClient(){return {async getAccessToken(){return {token:'google-adc-test'};}};}};
  const generate=createVertex(config,{auth,fetchImpl:async(url,options)=>{request={url,options};return Response.json(result);}});
  const parsed=parseRequest(requestBody(),config),signal=new AbortController().signal;
  assert.deepEqual(await generate({...parsed,signal}),result);
  assert.equal(request.options.headers.Authorization,'Bearer google-adc-test');
  assert.equal(request.options.signal,signal);assert.deepEqual(JSON.parse(request.options.body),parsed.payload);
  assert.equal(request.url,vertexUrl(config,config.models.develop));
});

test('Vertex failures are sanitized and cancellation before auth completion never sends a paid request',async()=>{
  const auth={async getClient(){return {async getAccessToken(){return {token:'test-adc'};}};}};
  for(const [status,expected] of [[400,400],[401,503],[403,503],[429,429],[500,503]]){
    const generate=createVertex(config,{auth,fetchImpl:async()=>Response.json({error:{message:'private details'}},{status})});
    await assert.rejects(()=>generate({...parseRequest(requestBody(),config),signal:new AbortController().signal}),error=>error instanceof ApiError&&error.status===expected&&!error.message.includes('private'));
  }
  let release;const credential=new Promise(r=>release=r),controller=new AbortController();let fetches=0;
  const generate=createVertex(config,{auth:{async getClient(){return {getAccessToken:()=>credential};}},fetchImpl:async()=>{fetches++;return Response.json(result);}});
  const pending=generate({...parseRequest(requestBody(),config),signal:controller.signal});controller.abort();release({token:'test-adc'});
  await assert.rejects(pending,{name:'AbortError'});assert.equal(fetches,0);
});


test('cancellation while ADC is still pending does not wait for the credential network request',async()=>{
  let entered;const started=new Promise(r=>entered=r),controller=new AbortController();
  const generate=createVertex(config,{auth:{async getClient(){return {getAccessToken(){entered();return new Promise(()=>{});}};}},fetchImpl:async()=>{throw Error('Must not call Vertex');}});
  const pending=generate({...parseRequest(requestBody(),config),signal:controller.signal});await started;controller.abort();
  await assert.rejects(pending,{name:'AbortError'});
});


test('Firebase verifier requires the configured audience/issuer and never checks a shared secret',async()=>{
  const claims={uid:'alice',sub:'alice',aud:config.project,iss:`https://securetoken.google.com/${config.project}`,exp:Math.floor(Date.now()/1000)+3600};
  let argument;
  const verify=createFirebaseVerifier(config,{env:{},authClient:{async verifyIdToken(value,checkRevoked){argument={value,checkRevoked};return claims;}}});
  assert.deepEqual(await verify(token),{uid:'alice'});
  assert.deepEqual(argument,{value:token,checkRevoked:false});
  for(const patch of [{aud:'different-project'},{iss:'https://securetoken.google.com/different-project'},{sub:'bob'},{exp:0}]){
    const invalid=createFirebaseVerifier(config,{env:{},authClient:{async verifyIdToken(){return {...claims,...patch};}}});
    await assert.rejects(()=>invalid(token),{status:401});
  }
  const rejected=createFirebaseVerifier(config,{env:{},authClient:{async verifyIdToken(){throw Error('Firebase signature verification failed');}}});
  await assert.rejects(()=>rejected('previous-shared-secret'),/verification failed/);
  assert.throws(()=>createFirebaseVerifier(config,{env:{FIREBASE_AUTH_EMULATOR_HOST:'127.0.0.1:9099'}}),/emulator/);
});

test('per-UID rate limit does not block another signed-in person behind the same IP',async t=>{
  let calls=0;const api=await start(t,{limits:{uidRate:2},generate:async()=>{calls++;return result;}});
  assert.equal((await api.send()).status,200);assert.equal((await api.send()).status,200);
  assert.equal((await api.send()).status,429);
  assert.equal((await api.send(requestBody(),otherToken)).status,200);assert.equal(calls,3);
});

test('per-UID concurrency leaves another user able to start and releases on completion',async t=>{
  let release,entered;const gate=new Promise(r=>release=r),started=new Promise(r=>entered=r);let calls=0;
  const api=await start(t,{limits:{uidConcurrent:1},generate:async()=>{if(++calls>1)return result;entered();await gate;return result;}});
  const first=api.send();await started;
  assert.equal((await api.send()).status,429);
  assert.equal((await api.send(requestBody(),otherToken)).status,200);
  release();assert.equal((await first).status,200);assert.equal((await api.send()).status,200);
});

test('daily cap is shared across users, counts valid cloud attempts and resets at UTC midnight',async t=>{
  let calls=0,time=Date.UTC(2026,10,10,23,59,0);
  const api=await start(t,{settings:{...config,dailyRequestLimit:2},now:()=>time,generate:async()=>{calls++;return result;}});
  assert.equal((await api.send({purpose:'invalid'})).status,400);
  assert.equal((await api.send()).status,200);
  assert.equal((await api.send(requestBody(),otherToken)).status,200);
  const limited=await api.send();assert.equal(limited.status,429);assert.equal(limited.data.error.code,'daily_limit_reached');assert.equal(calls,2);
  time=Date.UTC(2026,10,11,0,0,0);
  assert.equal((await api.send()).status,200);assert.equal(calls,3);
});


test('quota-store outage fails closed before calling Vertex and does not expose storage errors',async t=>{
  let calls=0;
  const quota=createDailyQuota(config,{env:{},db:{collection:()=>({doc:()=>({collection:()=>({doc:()=>({})})})}),async runTransaction(){throw Error('internal-database-credential-details');}}});
  const api=await start(t,{quota,generate:async()=>{calls++;return result;}});
  const response=await api.send();assert.equal(response.status,503);assert.equal(response.data.error.code,'quota_unavailable');
  assert.equal(calls,0);assert.equal(JSON.stringify(response.data).includes('credential-details'),false);
});

test('two HTTP instances share a durable quota and a restarted instance cannot reset it',async t=>{
  const db=new TransactionStore(),settings={...config,dailyRequestLimit:2};let calls=0;
  const options={settings,quota:createDailyQuota(settings,{db,env:{}}),generate:async()=>{calls++;return result;}};
  const first=await start(t,options),second=await start(t,options);
  const responses=await Promise.all([first.send(),second.send(requestBody(),otherToken),first.send(requestBody(),otherToken),second.send()]);
  assert.equal(responses.filter(response=>response.status===200).length,2);assert.equal(responses.filter(response=>response.status===429).length,2);assert.equal(calls,2);
  const restarted=await start(t,{...options,quota:createDailyQuota(settings,{db,env:{}})});
  assert.equal((await restarted.send()).data.error.code,'daily_limit_reached');assert.equal(calls,2);
});


test('multimodal function responses cannot bypass remote-file and image limits',()=>{
  for(const parts of [[{fileData:{mimeType:'image/png',fileUri:'gs://review-fixture/not-accessed.png'}}],[{inlineData:{mimeType:'image/png',data:'AAAA'}}]]){
    const body=requestBody({contents:[{role:'user',parts:[{functionResponse:{name:'render',response:{ok:true},parts}}]}]});
    assert.throws(()=>parseRequest(body,config),{status:400});
  }
});


test('protobuf snake-case aliases cannot replace a validated part during upstream parsing',()=>{
  for(const [field,value] of [['file_data',{fileUri:'gs://review-fixture/not-accessed.png'}],['inline_data',{mimeType:'image/png',data:'AAAA'}],['function_response',{name:'render',parts:[{fileData:{fileUri:'gs://review-fixture/not-accessed.png'}}]}],['executable_code',{language:'PYTHON',code:'print(1)'}]]){
    const part={functionResponse:{name:'render',response:{ok:true}},[field]:value};
    assert.throws(()=>parseRequest(requestBody({contents:[{role:'user',parts:[part]}]}),config),{status:400});
  }
});


test('public health uses a Cloud Run compatible path and never calls authentication, quota or AI',async t=>{
  const unexpected=async()=>{throw Error('Health must not call cloud dependencies');};
  const api=await start(t,{verify:unexpected,quota:{reserve:unexpected},generate:unexpected});
  const response=await fetch(`${api.root}/health`);
  assert.equal(response.status,200);assert.deepEqual(await response.json(),{ok:true});
  assert.equal((await fetch(`${api.root}/healthz`)).status,404);
});
