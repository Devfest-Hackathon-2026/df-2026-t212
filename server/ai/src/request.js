export class ApiError extends Error {
  constructor(status, code, message) {super(message); Object.assign(this,{status,code});}
}
export const invalid = message => new ApiError(400,'invalid_request',message);
const object = value => value !== null && typeof value === 'object' && !Array.isArray(value);
const name = value => typeof value === 'string' && /^[a-zA-Z_][a-zA-Z0-9_.:-]{0,63}$/.test(value);
function keys(value, allowed, field) {
  if (!object(value) || Object.keys(value).some(key=>!allowed.includes(key))) throw invalid(`Invalid ${field}.`);
}
function base64Size(value) {
  if (typeof value!=='string' || !value.length || value.length>5_592_408 || value.length%4 || /[^A-Za-z0-9+/=]/.test(value)) throw invalid('Use a JPEG, PNG or WebP image of at most 4 MiB.');
  const pad=value.endsWith('==')?2:value.endsWith('=')?1:0, first=value.indexOf('=');
  if(first!==-1 && first!==value.length-pad) throw invalid('Invalid image encoding.');
  const bytes=value.length/4*3-pad;
  if(bytes>4*1024*1024) throw new ApiError(413,'image_too_large','Use an image of at most 4 MiB.');
  return bytes;
}

export function parseRequest(body, config) {
  keys(body,['purpose','contents','systemInstruction','tools','generationConfig'],'request');
  if(!['judge','develop'].includes(body.purpose)) throw invalid('Choose judge or develop.');
  if(!Array.isArray(body.contents)||body.contents.length<1||body.contents.length>128) throw invalid('Provide 1–128 conversation turns.');
  let imageCount=0,imageBytes=0,partCount=0;
  const metadataContents=body.contents.map(content=>{
    // Keep the original content/parts untouched for opaque Gemini signatures.
    if(!object(content)||!['user','model'].includes(content.role)||!Array.isArray(content.parts)||!content.parts.length) throw invalid('Invalid conversation content.');
    const parts=content.parts.map(part=>{
      if(!object(part)||++partCount>512) throw invalid('Too many conversation parts.');
      if(['file_data','inline_data','function_call','function_response','executable_code','code_execution_result'].some(key=>Object.hasOwn(part,key))) throw invalid('Use canonical Gemini content field names.');
      if(part.fileData!==undefined||part.executableCode!==undefined||part.codeExecutionResult!==undefined) throw invalid('Only inline images, text and app function calls are supported.');
      if(part.text!==undefined&&typeof part.text!=='string') throw invalid('Invalid text part.');
      if(part.thoughtSignature!==undefined&&typeof part.thoughtSignature!=='string') throw invalid('Invalid thought signature.');
      for(const key of ['functionCall','functionResponse']) if(part[key]!==undefined&&(!object(part[key])||!name(part[key].name))) throw invalid('Invalid app function part.');
      if(part.functionResponse?.parts!==undefined) throw invalid('Function responses must use JSON; send images as separate inline parts.');
      if(!['text','inlineData','functionCall','functionResponse'].some(key=>part[key]!==undefined)) throw invalid('Unsupported content part.');
      if(part.inlineData!==undefined){
        keys(part.inlineData,['mimeType','data','displayName'],'inline image');
        if(!['image/jpeg','image/png','image/webp'].includes(part.inlineData.mimeType)) throw invalid('Unsupported image type.');
        imageCount++;imageBytes+=base64Size(part.inlineData.data);
        if(imageCount>12||imageBytes>10*1024*1024) throw new ApiError(413,'images_too_large','Use at most twelve images totalling 10 MiB.');
        return {...part,inlineData:{mimeType:part.inlineData.mimeType}};
      }
      return part;
    });
    return {...content,parts};
  });
  if(body.systemInstruction!==undefined){
    const instruction=body.systemInstruction;
    if(!object(instruction)||!Array.isArray(instruction.parts)||!instruction.parts.length||instruction.parts.some(p=>!object(p)||Object.keys(p).some(k=>k!=='text')||typeof p.text!=='string')) throw invalid('System instructions must contain text parts.');
  }
  if(body.tools!==undefined){
    if(!Array.isArray(body.tools)||body.tools.length>8) throw invalid('Invalid app tools.');
    let count=0;
    for(const tool of body.tools){
      keys(tool,['functionDeclarations'],'app tools');
      if(!Array.isArray(tool.functionDeclarations)||!tool.functionDeclarations.length) throw invalid('Provide function declarations.');
      for(const declaration of tool.functionDeclarations){
        if(!object(declaration)||!name(declaration.name)||++count>64) throw invalid('Invalid function declaration.');
        if(declaration.parameters!==undefined&&declaration.parametersJsonSchema!==undefined) throw invalid('Use one parameter schema per function.');
      }
    }
  }
  const requested=body.generationConfig||{};
  keys(requested,['temperature','topP','topK','maxOutputTokens','candidateCount','responseMimeType','responseSchema','responseJsonSchema','stopSequences','seed','thinkingConfig'],'generation configuration');
  for(const [key,min,max] of [['temperature',0,2],['topP',0,1],['topK',1,100]]) if(requested[key]!==undefined&&(typeof requested[key]!=='number'||!Number.isFinite(requested[key])||requested[key]<min||requested[key]>max)) throw invalid(`Invalid ${key}.`);
  if(requested.candidateCount!==undefined&&requested.candidateCount!==1) throw invalid('Only one candidate is supported.');
  const ceiling=body.purpose==='judge'?2048:8192;
  if(requested.maxOutputTokens!==undefined&&(!Number.isInteger(requested.maxOutputTokens)||requested.maxOutputTokens<1)) throw invalid('Invalid output token limit.');
  if(requested.responseMimeType!==undefined&&!['application/json','text/plain'].includes(requested.responseMimeType)) throw invalid('Unsupported response type.');
  if(requested.stopSequences!==undefined&&(!Array.isArray(requested.stopSequences)||requested.stopSequences.length>5||requested.stopSequences.some(s=>typeof s!=='string'||s.length>128))) throw invalid('Invalid stop sequences.');
  if(requested.seed!==undefined&&!Number.isSafeInteger(requested.seed)) throw invalid('Invalid seed.');
  if(requested.thinkingConfig!==undefined){
    keys(requested.thinkingConfig,['thinkingLevel','thinkingBudget','includeThoughts'],'thinking configuration');
    if(requested.thinkingConfig.includeThoughts!==undefined&&typeof requested.thinkingConfig.includeThoughts!=='boolean') throw invalid('Invalid thinking configuration.');
    if(requested.thinkingConfig.thinkingLevel!==undefined&&!['MINIMAL','LOW','MEDIUM','HIGH'].includes(requested.thinkingConfig.thinkingLevel)) throw invalid('Invalid thinking level.');
    if(requested.thinkingConfig.thinkingBudget!==undefined&&(!Number.isInteger(requested.thinkingConfig.thinkingBudget)||requested.thinkingConfig.thinkingBudget<0||requested.thinkingConfig.thinkingBudget>4096)) throw invalid('Invalid thinking budget.');
    if(requested.thinkingConfig.thinkingLevel!==undefined&&requested.thinkingConfig.thinkingBudget!==undefined) throw invalid('Choose a thinking level or budget.');
  }
  if(Buffer.byteLength(JSON.stringify({...body,contents:metadataContents}))>512*1024) throw new ApiError(413,'context_too_large','The conversation is too large. Start another edit.');
  const model=config.models[body.purpose];
  const thinkingDefault=model.startsWith('gemini-2.5')?{thinkingBudget:body.purpose==='judge'?0:1024}:{thinkingLevel:body.purpose==='judge'&&model.endsWith('flash-lite')?'MINIMAL':'LOW'};
  const payload={contents:body.contents,...(body.systemInstruction?{systemInstruction:body.systemInstruction}:{}),...(body.tools?{tools:body.tools}:{}),generationConfig:{...requested,candidateCount:1,maxOutputTokens:Math.min(requested.maxOutputTokens??ceiling,ceiling),thinkingConfig:requested.thinkingConfig??thinkingDefault}};
  return {purpose:body.purpose,model,payload};
}
