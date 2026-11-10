import {GoogleAuth} from 'google-auth-library';
import {ApiError} from './request.js';

const allowedModels=new Set(['gemini-3.8-flash','gemini-3.5-flash','gemini-3.5-flash-lite','gemini-2.5-flash','gemini-2.5-flash-lite']);
export function loadConfig(env=process.env){
  const project=env.GOOGLE_CLOUD_PROJECT,location=env.VERTEX_LOCATION||'global';
  if(!project||!/^[a-z][a-z0-9-]{4,61}[a-z0-9]$/.test(project)) throw Error('A valid GOOGLE_CLOUD_PROJECT is required.');
  if(!['global','asia-northeast1','us-central1'].includes(location)) throw Error('Unsupported VERTEX_LOCATION.');
  const models={develop:env.VERTEX_DEVELOP_MODEL||'gemini-3.8-flash',judge:env.VERTEX_JUDGE_MODEL||'gemini-3.5-flash-lite'};
  if(Object.values(models).some(model=>!allowedModels.has(model))) throw Error('Unsupported Vertex model configuration.');
  const timeoutMs=Number(env.AI_TIMEOUT_MS||90000);
  if(!Number.isInteger(timeoutMs)||timeoutMs<1000||timeoutMs>120000) throw Error('AI_TIMEOUT_MS must be between 1000 and 120000.');
  const dailyRequestLimit=Number(env.AI_DAILY_REQUEST_LIMIT||1000);
  if(!Number.isInteger(dailyRequestLimit)||dailyRequestLimit<1||dailyRequestLimit>100000) throw Error('AI_DAILY_REQUEST_LIMIT must be between 1 and 100000.');
  const userDailyRequestLimit=Number(env.AI_USER_DAILY_REQUEST_LIMIT||300);
  if(!Number.isInteger(userDailyRequestLimit)||userDailyRequestLimit<1||userDailyRequestLimit>100000) throw Error('AI_USER_DAILY_REQUEST_LIMIT must be between 1 and 100000.');
  return {project,location,models,timeoutMs,dailyRequestLimit,userDailyRequestLimit};
}
export function vertexUrl(config,model){
  if(!Object.values(config.models).includes(model)) throw Error('Model is not configured.');
  const host=config.location==='global'?'aiplatform.googleapis.com':`${config.location}-aiplatform.googleapis.com`;
  return `https://${host}/v1/projects/${config.project}/locations/${config.location}/publishers/google/models/${model}:generateContent`;
}
function waitForCredential(operation,signal){
  signal.throwIfAborted();
  return new Promise((resolve,reject)=>{
    const abort=()=>{signal.removeEventListener('abort',abort);reject(signal.reason);};
    signal.addEventListener('abort',abort,{once:true});
    Promise.resolve().then(operation).then(value=>{signal.removeEventListener('abort',abort);resolve(value);},error=>{signal.removeEventListener('abort',abort);reject(error);});
  });
}
export function createVertex(config,{auth=new GoogleAuth({scopes:['https://www.googleapis.com/auth/cloud-platform']}),fetchImpl=fetch}={}){
  let clientPromise;
  return async({model,payload,signal})=>{
    signal.throwIfAborted();
    clientPromise??=auth.getClient().catch(error=>{clientPromise=null;throw error;});
    const client=await waitForCredential(()=>clientPromise,signal);
    const credential=await waitForCredential(()=>client.getAccessToken(),signal);
    signal.throwIfAborted();
    if(!credential.token) throw new ApiError(503,'ai_unavailable','AI is temporarily unavailable.');
    const response=await fetchImpl(vertexUrl(config,model),{method:'POST',signal,headers:{Authorization:`Bearer ${credential.token}`,'Content-Type':'application/json'},body:JSON.stringify(payload)});
    if(!response.ok){
      await response.body?.cancel();
      if(response.status===429) throw new ApiError(429,'ai_busy','AI is busy. Please try again shortly.');
      if(response.status===400) throw new ApiError(400,'invalid_ai_request','The AI request could not be processed.');
      throw new ApiError(503,'ai_unavailable','AI is temporarily unavailable.');
    }
    const chunks=[];let bytes=0;
    for await(const chunk of response.body){
      bytes+=chunk.byteLength;
      if(bytes>4*1024*1024) throw new ApiError(502,'invalid_ai_response','The AI response was too large. Please try again.');
      chunks.push(chunk);
    }
    let result;
    try{result=JSON.parse(Buffer.concat(chunks).toString('utf8'));}catch{throw new ApiError(502,'invalid_ai_response','The AI response could not be read.');}
    if(!result||typeof result!=='object'||Array.isArray(result)) throw new ApiError(502,'invalid_ai_response','The AI response could not be read.');
    return result;
  };
}
