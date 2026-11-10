import test from 'node:test';
import assert from 'node:assert/strict';
import {createDailyQuota} from '../src/quota.js';
import {TransactionStore} from './quota-store.js';
const config={dailyRequestLimit:10,userDailyRequestLimit:3};
const now=Date.UTC(2026,10,10,10);

test('atomic global quota allows exactly the configured count under concurrent service instances',async()=>{
  const db=new TransactionStore();
  const instances=Array.from({length:4},()=>createDailyQuota(config,{db,env:{}}));
  const results=await Promise.allSettled(Array.from({length:40},(_,i)=>instances[i%4].reserve(`person-${i}`,now)));
  assert.equal(results.filter(result=>result.status==='fulfilled').length,10);
  for(const result of results.filter(result=>result.status==='rejected'))assert.equal(result.reason.code,'daily_limit_reached');
  assert.equal(db.data.get('aiDailyQuotas/2026-11-10').count,10);
});

test('UID quota is atomic, does not consume global quota on rejection and reveals no UID',async()=>{
  const db=new TransactionStore(),quota=createDailyQuota(config,{db,env:{}});
  const results=await Promise.allSettled(Array.from({length:8},()=>quota.reserve('private-firebase-uid',now)));
  assert.equal(results.filter(result=>result.status==='fulfilled').length,3);
  for(const result of results.filter(result=>result.status==='rejected'))assert.equal(result.reason.code,'user_daily_limit_reached');
  assert.equal(db.data.get('aiDailyQuotas/2026-11-10').count,3);
  await quota.reserve('another-person',now);assert.equal(db.data.get('aiDailyQuotas/2026-11-10').count,4);
  for(const [path,data] of db.data){assert.equal(path.includes('private-firebase-uid'),false);assert.deepEqual(Object.keys(data).sort(),['count','day']);}
});

test('a new UTC day has its own counters while previous reservations remain durable',async()=>{
  const db=new TransactionStore(),quota=createDailyQuota({...config,dailyRequestLimit:1},{db,env:{}});
  await quota.reserve('person',now);
  const restarted=createDailyQuota({...config,dailyRequestLimit:1},{db,env:{}});
  await assert.rejects(()=>restarted.reserve('person',now),{code:'daily_limit_reached'});
  await restarted.reserve('person',now+86400000);
  assert.equal(db.data.get('aiDailyQuotas/2026-11-10').count,1);assert.equal(db.data.get('aiDailyQuotas/2026-11-11').count,1);
});

test('corrupt quota data or an emulator configuration cannot silently reset the budget',async()=>{
  const db=new TransactionStore();db.data.set('aiDailyQuotas/2026-11-10',{day:'2026-11-10',count:'wrong'});
  await assert.rejects(()=>createDailyQuota(config,{db,env:{}}).reserve('person',now),{code:'quota_unavailable'});
  assert.throws(()=>createDailyQuota(config,{db,env:{FIRESTORE_EMULATOR_HOST:'localhost:8080'}}),/emulator/);
});
