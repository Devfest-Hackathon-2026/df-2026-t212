import {createHash} from 'node:crypto';
import {getFirestore} from 'firebase-admin/firestore';
import {firebaseApp} from './auth.js';
import {ApiError} from './request.js';

export function createDailyQuota(config,{db,env=process.env}={}){
  if(!Number.isInteger(config.dailyRequestLimit)||config.dailyRequestLimit<1||!Number.isInteger(config.userDailyRequestLimit)||config.userDailyRequestLimit<1) throw Error('Positive global and per-user daily AI limits are required.');
  if(env.FIRESTORE_EMULATOR_HOST) throw Error('The production AI service does not use an emulator quota store.');
  const firestore=db??getFirestore(firebaseApp(config));
  return {async reserve(uid,now=Date.now()){
    const day=new Date(now).toISOString().slice(0,10);
    const userHash=createHash('sha256').update(`${day}\0${uid}`).digest('hex');
    const globalRef=firestore.collection('aiDailyQuotas').doc(day);
    const userRef=globalRef.collection('users').doc(userHash);
    try{
      await firestore.runTransaction(async transaction=>{
        const [globalSnapshot,userSnapshot]=await transaction.getAll(globalRef,userRef);
        const count=snapshot=>{
          if(!snapshot.exists)return 0;
          const data=snapshot.data();
          if(data.day!==day||!Number.isSafeInteger(data.count)||data.count<0) throw new ApiError(503,'quota_unavailable','AI limits could not be checked. Please try again.');
          return data.count;
        };
        const globalCount=count(globalSnapshot),userCount=count(userSnapshot);
        if(globalCount>=config.dailyRequestLimit) throw new ApiError(429,'daily_limit_reached','Today’s AI limit has been reached. Please try again tomorrow.');
        if(userCount>=config.userDailyRequestLimit) throw new ApiError(429,'user_daily_limit_reached','Your AI limit for today has been reached. Please try again tomorrow.');
        // Reserve both counters in the same commit before starting paid inference.
        // Failed or cancelled inference still consumes this reservation.
        transaction.set(globalRef,{day,count:globalCount+1});
        transaction.set(userRef,{day,count:userCount+1});
      });
    }catch(error){
      if(error instanceof ApiError)throw error;
      throw new ApiError(503,'quota_unavailable','AI limits could not be checked. Please try again.');
    }
  }};
}
