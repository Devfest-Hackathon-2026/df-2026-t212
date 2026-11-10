import {initializeApp,applicationDefault,getApps} from 'firebase-admin/app';
import {getAuth} from 'firebase-admin/auth';
import {ApiError} from './request.js';

export function firebaseApp(config){
  return getApps().find(app=>app.name==='after-hue-ai')??initializeApp({projectId:config.project,credential:applicationDefault()},'after-hue-ai');
}

export function createFirebaseVerifier(config,{authClient,env=process.env}={}){
  if(!config.project) throw Error('Firebase project configuration is required.');
  if(env.FIREBASE_AUTH_EMULATOR_HOST) throw Error('The production AI service does not accept Firebase emulator tokens.');
  const auth=authClient??getAuth(firebaseApp(config));
  return async token=>{
    // The Admin SDK verifies the Google signature, issuer, audience and expiry.
    // checkRevoked=false avoids a user lookup for every agent tool turn.
    const decoded=await auth.verifyIdToken(token,false);
    if(!decoded||typeof decoded.uid!=='string'||!decoded.uid||decoded.uid.length>128||decoded.sub!==decoded.uid||
       decoded.aud!==config.project||decoded.iss!==`https://securetoken.google.com/${config.project}`||
       !Number.isInteger(decoded.exp)||decoded.exp*1000<=Date.now()){
      throw new ApiError(401,'unauthorized','Sign in again to use AI.');
    }
    return {uid:decoded.uid};
  };
}
