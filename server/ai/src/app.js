import express from 'express';
import {ApiError,parseRequest} from './request.js';

export function createApp({config,generate,verifyAuth,quota,now=Date.now,limits={}}){
  limits={ipRate:180,uidRate:120,globalRate:240,ipConcurrent:6,uidConcurrent:4,globalConcurrent:8,...limits};
  if(typeof quota?.reserve!=='function') throw Error('A durable daily AI quota store is required.');
  if(!config?.project||typeof verifyAuth!=='function') throw Error('Firebase authentication configuration is required.');
  const app=express(),ips=new Map(),users=new Map();
  const globalWindow={until:0,count:0,active:0};
  const windowFor=(map,key,time)=>{
    if(map.size>4096) for(const [id,item] of map) if(item.until<=time&&item.active===0) map.delete(id);
    let item=map.get(key);
    if(!item){if(map.size>=8192) throw new ApiError(429,'rate_limited','Please wait before trying again.');item={until:time+60000,count:0,active:0};map.set(key,item);}
    if(item.until<=time){item.until=time+60000;item.count=0;}
    return item;
  };
  app.disable('x-powered-by');app.set('trust proxy',1);
  app.use((_req,res,next)=>{res.set({'Cache-Control':'no-store','X-Content-Type-Options':'nosniff'});next();});
  app.get('/health',(_req,res)=>res.json({ok:true}));
  app.post('/v1/generate',async(req,res,next)=>{
    const ip=windowFor(ips,req.ip||'unknown',now());
    if(++ip.count>limits.ipRate) throw new ApiError(429,'rate_limited','Please wait before trying again.');
    const match=/^Bearer ([A-Za-z0-9_.-]{32,8192})$/.exec(req.get('authorization')||'');
    if(!match) throw new ApiError(401,'unauthorized','Sign in again to use AI.');
    let identity;
    try{identity=await verifyAuth(match[1]);}catch(error){
      if(error instanceof ApiError&&error.status===503)throw error;
      throw new ApiError(401,'unauthorized','Sign in again to use AI.');
    }
    if(!identity||typeof identity.uid!=='string'||identity.uid.length<1||identity.uid.length>128) throw new ApiError(401,'unauthorized','Sign in again to use AI.');
    if(req.aborted||res.destroyed)return;
    const time=now(),user=windowFor(users,identity.uid,time);
    if(++user.count>limits.uidRate) throw new ApiError(429,'rate_limited','Please wait before trying again.');
    if(globalWindow.until<=time){globalWindow.until=time+60000;globalWindow.count=0;}
    if(++globalWindow.count>limits.globalRate) throw new ApiError(429,'rate_limited','Please wait before trying again.');
    if(ip.active>=limits.ipConcurrent||user.active>=limits.uidConcurrent||globalWindow.active>=limits.globalConcurrent) throw new ApiError(429,'ai_busy','AI is processing other photos. Please try again shortly.');
    ip.active++;user.active++;globalWindow.active++;
    const controller=new AbortController();let released=false,timedOut=false;
    const timeout=setTimeout(()=>{timedOut=true;controller.abort();},config.timeoutMs);timeout.unref();
    const release=()=>{if(released)return;released=true;ip.active--;user.active--;globalWindow.active--;clearTimeout(timeout);};
    req.once('aborted',()=>{controller.abort();release();});
    res.once('close',()=>{if(!res.writableEnded)controller.abort();release();});
    res.once('finish',release);
    req.ai={controller,uid:identity.uid,isTimedOut:()=>timedOut};next();
  },express.json({limit:'16mb',strict:true}),async(req,res)=>{
    const request=parseRequest(req.body,config);
    try{
      req.ai.controller.signal.throwIfAborted();
      await quota.reserve(req.ai.uid,now());
      req.ai.controller.signal.throwIfAborted();
      const result=await generate({...request,signal:req.ai.controller.signal});
      if(!res.destroyed) res.json(result);
    }catch(error){
      if(req.ai.isTimedOut()) throw new ApiError(504,'ai_timeout','AI took too long. Please try again.');
      throw error;
    }
  });
  app.use((_req,_res,next)=>next(new ApiError(404,'not_found','Not found.')));
  app.use((error,_req,res,_next)=>{
    if(res.destroyed||res.headersSent)return;
    const known=error instanceof ApiError;
    const status=known?error.status:error.type==='entity.too.large'?413:error.type==='entity.parse.failed'?400:503;
    if(status===429)res.set('Retry-After',['daily_limit_reached','user_daily_limit_reached'].includes(error.code)?String(Math.ceil((86400000-now()%86400000)/1000)):'5');
    // Never serialize upstream messages, headers, request bodies or credentials.
    res.status(status).json({error:{code:known?error.code:status===413?'request_too_large':status===400?'invalid_request':'ai_unavailable',message:known?error.message:status===413?'This request is too large.':status===400?'Invalid request.':'AI is temporarily unavailable. Please try again.'}});
  });
  return app;
}
