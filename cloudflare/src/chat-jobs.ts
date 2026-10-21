import { AppError } from './domain';

export interface ChatRunMessage { kind: 'chat'; userId: string; jobId: string }
export interface ChatJobEnv {
  DB: D1Database;
  CHAT_QUEUE?: Queue<ChatRunMessage>;
  CHAT_USER_ID?: string;
  DEEPSEEK_API_KEY: string;
  DEEPSEEK_BASE_URL?: string;
}
interface ChatRow {
  user_id: string; id: string; conversation_id: string; user_message_id: string; assistant_message_id: string;
  request_hash: string; request_json: string | null; status: string; content: string; reasoning: string;
  error_code: string | null; usage_json: string | null; created_at: number; started_at: number | null;
  updated_at: number; expires_at: number;
}
const uuid = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const encoder = new TextEncoder();
const reply = (value: unknown, status = 200) => new Response(JSON.stringify(value), {
  status, headers: { 'content-type': 'application/json', 'cache-control': 'no-store' }
});
type WireRequest = {
  model: string; messages: {role: string; content: string}[]; thinking: {type: string};
  reasoning_effort: string; stream: true; stream_options: {include_usage: true}; max_tokens?: number;
};
export function validateChatSubmission(value: unknown): {
  id: string; conversationID: string; userMessageID: string; assistantMessageID: string; request: WireRequest
} {
  const x = value as Record<string, unknown>;
  if (!x || typeof x !== 'object' || Object.keys(x).some(k => !['id','conversationID','userMessageID','assistantMessageID','request'].includes(k))) throw new AppError('invalid_chat', 'Invalid chat job');
  for (const key of ['id','conversationID','userMessageID','assistantMessageID']) {
    if (typeof x[key] !== 'string' || !uuid.test(x[key] as string)) throw new AppError('invalid_chat', 'Invalid message identifier');
  }
  if (x.id !== x.assistantMessageID || x.userMessageID === x.assistantMessageID) throw new AppError('invalid_chat', 'Job must match assistant identifier');
  const r = x.request as WireRequest;
  if (!r || typeof r !== 'object' || Object.keys(r).some(k => !['model','messages','thinking','reasoning_effort','stream','stream_options','max_tokens'].includes(k))) throw new AppError('unsupported_chat', 'Only text chat without tools is durable in V1');
  if (!['deepseek-flash','deepseek-v4-pro'].includes(r.model) || r.stream !== true ||
      !r.thinking || Object.keys(r.thinking).some(k => k !== 'type') || !['enabled','disabled'].includes(r.thinking.type) ||
      !['low','high','max'].includes(r.reasoning_effort) || !r.stream_options ||
      Object.keys(r.stream_options).some(k => k !== 'include_usage') || r.stream_options.include_usage !== true ||
      (r.max_tokens !== undefined && (!Number.isInteger(r.max_tokens) || r.max_tokens < 1 || r.max_tokens > 32768))) throw new AppError('invalid_chat', 'Invalid model configuration');
  if (!Array.isArray(r.messages) || r.messages.length < 1 || r.messages.length > 200 ||
      r.messages.some(m => !m || !['system','user','assistant'].includes(m.role) || typeof m.content !== 'string' || Object.keys(m).some(k => !['role','content'].includes(k))) ||
      r.messages.at(-1)?.role !== 'user') throw new AppError('unsupported_chat', 'Only text messages without native tool transcripts are supported');
  if (encoder.encode(JSON.stringify(r)).length > 900_000) throw new AppError('chat_too_large', 'Chat snapshot exceeds 900 KB', 413);
  return x as ReturnType<typeof validateChatSubmission>;
}
function configured(env: ChatJobEnv, userId: string) {
  if (!env.CHAT_QUEUE || !env.CHAT_USER_ID || !env.DEEPSEEK_API_KEY) throw new AppError('chat_not_configured', 'Cloud chat continuation is not deployed/configured', 503);
  if (userId !== env.CHAT_USER_ID) throw new AppError('chat_forbidden', 'Cloud chat owner does not match', 403);
}
async function row(env: ChatJobEnv, userId: string, id: string) {
  return env.DB.prepare('SELECT * FROM chat_jobs WHERE user_id=? AND id=?').bind(userId,id).first<ChatRow>();
}
function snapshot(r: ChatRow) {
  return { id:r.id, conversationID:r.conversation_id, userMessageID:r.user_message_id, assistantMessageID:r.assistant_message_id,
    status:r.status, content:r.content, reasoning:r.reasoning, errorCode:r.error_code, expiresAt:r.expires_at };
}
async function hash(text: string) {
  return [...new Uint8Array(await crypto.subtle.digest('SHA-256',encoder.encode(text)))].map(x=>x.toString(16).padStart(2,'0')).join('');
}
export async function chatRoutes(req: Request, env: ChatJobEnv, userId: string): Promise<Response | undefined> {
  const path = new URL(req.url).pathname;
  if (!path.startsWith('/v1/chat-jobs')) return;
  configured(env,userId); // Existing worker bearer authentication runs before this owner pin.
  if (req.method === 'GET' && path === '/v1/chat-jobs/capabilities') return reply({enabled:true,textOnly:true,serverKey:true,retentionDays:7});
  if (req.method === 'POST' && path === '/v1/chat-jobs') {
    await env.DB.prepare("UPDATE chat_jobs SET status='failed',request_json=NULL,error_code='execution_interrupted',updated_at=? WHERE user_id=? AND ((status='running' AND started_at<?) OR (status='queued' AND created_at<?))")
      .bind(Date.now(),userId,Date.now()-12*60000,Date.now()-15*60000).run();
    // Bounded read, regardless of a missing/lying Content-Length.
    const reader = req.body?.getReader(); const pieces: Uint8Array[] = []; let bytes=0;
    if (!reader) throw new AppError('invalid_chat','Missing job');
    try { while (true) { const next=await reader.read(); if(next.done)break; bytes+=next.value.length;
      if(bytes>1_000_000)throw new AppError('chat_too_large','Chat submission exceeds 1 MB',413); pieces.push(next.value); }
    } finally { await reader.cancel(); }
    const joined=new Uint8Array(bytes);let offset=0;for(const piece of pieces){joined.set(piece,offset);offset+=piece.length;}
    let raw: unknown;try{raw=JSON.parse(new TextDecoder().decode(joined));}catch{throw new AppError('invalid_chat','Invalid JSON');}
    const body=validateChatSubmission(raw), requestJSON=JSON.stringify(body.request);
    const fingerprint=await hash(JSON.stringify(body)), now=Date.now();
    let existing=await row(env,userId,body.id);
    if (!existing) {
      // Single SQL statement gives an atomic per-owner admission check, including concurrent posts.
      await env.DB.prepare(`INSERT OR IGNORE INTO chat_jobs(user_id,id,conversation_id,user_message_id,assistant_message_id,request_hash,request_json,status,created_at,updated_at,expires_at)
        SELECT ?,?,?,?,?,?,?,'queued',?,?,? WHERE
        (SELECT COUNT(*) FROM chat_jobs WHERE user_id=? AND created_at>=?)<24 AND
        (SELECT COUNT(*) FROM chat_jobs WHERE user_id=? AND status IN ('queued','running'))<2`)
        .bind(userId,body.id,body.conversationID,body.userMessageID,body.assistantMessageID,fingerprint,requestJSON,now,now,now+7*86400000,userId,now-86400000,userId).run();
      existing=await row(env,userId,body.id);
      if(!existing)throw new AppError('chat_quota','At most 2 pending and 24 submitted chats per 24 hours',429);
    }
    if(existing.request_hash!==fingerprint)throw new AppError('chat_conflict','Identifier already has a different frozen request',409);
    if(existing.expires_at<=now)throw new AppError('chat_expired','Cloud result expired',410);
    // Re-enqueue after a lost submit acknowledgement is safe: the consumer claims once.
    if(existing.status==='queued')await env.CHAT_QUEUE!.send({kind:'chat',userId,jobId:body.id});
    return reply(snapshot(existing),202);
  }
  const match=path.match(/^\/v1\/chat-jobs\/([0-9a-f-]+)$/i);
  if(!match || !uuid.test(match[1]!))throw new AppError('not_found','Chat job not found',404);
  let result=await row(env,userId,match[1]!);if(!result)throw new AppError('not_found','Chat job not found',404);
  const now=Date.now();
  if(result.expires_at<=now)throw new AppError('chat_expired','Cloud result expired',410);
  if(req.method==='DELETE') {
    await env.DB.prepare("UPDATE chat_jobs SET status='cancelled',request_json=NULL,error_code='cancelled',updated_at=? WHERE user_id=? AND id=? AND status IN ('queued','running')").bind(now,userId,result.id).run();
  } else if(req.method==='GET') {
    // Do not silently re-execute an ambiguous provider request after a worker crash.
    await env.DB.prepare("UPDATE chat_jobs SET status='failed',request_json=NULL,error_code='execution_interrupted',updated_at=? WHERE user_id=? AND id=? AND ((status='running' AND started_at<?) OR (status='queued' AND created_at<?))")
      .bind(now,userId,result.id,now-12*60000,now-15*60000).run();
  } else throw new AppError('method_not_allowed','Method not allowed',405);
  result=(await row(env,userId,result.id))!;return reply(snapshot(result));
}

/** Bounded SSE decoder: keep-alive comments/empty lines are not EOF; completion requires stop + DONE. */
export class ChatStreamAccumulator {
  content=''; reasoning=''; stopped=false; done=false; usage: unknown;
  private pending=''; private data: string[]=[];
  feed(text: string) {
    this.pending+=text;
    if(this.pending.length>262144)throw new AppError('invalid_stream','SSE line too large');
    while(true){const end=this.pending.indexOf('\n');if(end<0)break;const line=this.pending.slice(0,end).replace(/\r$/,'');this.pending=this.pending.slice(end+1);
      if(!line){this.event();}else if(line.startsWith('data:')){this.data.push(line.slice(5).replace(/^ /,''));}
      // Comments and other SSE fields are ignored.
    }
  }
  private event() {
    if(!this.data.length)return;const text=this.data.join('\n');this.data=[];
    if(text==='[DONE]'){this.done=true;return;}
    if(this.done)throw new AppError('invalid_stream','Unexpected event after DONE');
    const frame=JSON.parse(text) as any;
    if(frame.error)throw new AppError('provider_error','Provider rejected generation');
    if(frame.usage)this.usage=frame.usage;
    for(const choice of frame.choices??[]){
      if(choice.index!==undefined&&choice.index!==0)throw new AppError('invalid_stream','Multiple choices unsupported');
      if(choice.delta?.tool_calls)throw new AppError('unsupported_chat','Unexpected tool call');
      for(const key of ['content','reasoning_content']){
        const value=choice.delta?.[key];if(value!==undefined&&value!==null&&typeof value!=='string')throw new AppError('invalid_stream','Invalid delta');
        if(typeof value==='string'){if(key==='content')this.content+=value;else this.reasoning+=value;}
      }
      if(choice.finish_reason){if(choice.finish_reason!=='stop')throw new AppError('incomplete_output','Generation did not finish normally');this.stopped=true;}
    }
    if(this.content.length+this.reasoning.length>200000)throw new AppError('output_limit','Cloud response exceeds limit');
  }
  finish() {
    this.feed('\n\n');
    if(!this.done||!this.stopped||!this.content.trim())throw new AppError('incomplete_output','Stream ended without a completed answer');
  }
}
export async function consumeChat(env: ChatJobEnv, msg: Message<ChatRunMessage>, provider: typeof fetch = fetch) {
  const {userId,jobId}=msg.body;
  if(!env.CHAT_USER_ID||userId!==env.CHAT_USER_ID){msg.ack();return;}
  const started=Date.now();
  const claim=await env.DB.prepare("UPDATE chat_jobs SET status='running',started_at=?,updated_at=? WHERE user_id=? AND id=? AND status='queued' AND expires_at>?").bind(started,started,userId,jobId,started).run();
  if(!claim.meta.changes){msg.ack();return;}
  const stream=new ChatStreamAccumulator();const controller=new AbortController();
  const timeout=setTimeout(()=>controller.abort(),11*60000);
  let checkingCancellation=false;
  const cancellationPoll=setInterval(()=>{
    if(checkingCancellation)return;checkingCancellation=true;
    void env.DB.prepare('SELECT status FROM chat_jobs WHERE user_id=? AND id=?').bind(userId,jobId).first<{status:string}>()
      .then(value=>{if(value?.status!=='running')controller.abort();})
      .catch(()=>controller.abort()).finally(()=>{checkingCancellation=false;});
  },5000);
  let lastSave=started;
  try {
    const job=await row(env,userId,jobId);if(job?.status!=='running')throw new AppError('cancelled','Generation cancelled');
    if(!job?.request_json)throw new AppError('invalid_chat','Missing frozen request');
    const base=new URL(env.DEEPSEEK_BASE_URL??'https://api.deepseek.com');
    if(base.protocol!=='https:'||base.hostname!=='api.deepseek.com'||base.username||base.password||base.port||!['','/'].includes(base.pathname))throw new AppError('invalid_provider','Invalid official provider endpoint');
    const request=JSON.parse(job.request_json);
    let response: Response | undefined;
    for(let attempt=0;attempt<3;attempt++){
      response=await provider('https://api.deepseek.com/chat/completions',{method:'POST',redirect:'manual',headers:{authorization:`Bearer ${env.DEEPSEEK_API_KEY}`,'content-type':'application/json'},body:JSON.stringify({...request,max_tokens:request.max_tokens??32768,user_id:userId}),signal:controller.signal});
      if(response.status!==429||attempt===2)break;
      await response.body?.cancel();await new Promise(resolve=>setTimeout(resolve,Math.min(8000,500*2**attempt)));
    }
    if(!response?.ok||!response.body)throw new AppError('provider_http','Provider request failed');
    const reader=response.body.getReader(), decoder=new TextDecoder();let bytes=0;
    try{
      while(true){const part=await reader.read();if(part.done)break;bytes+=part.value.length;
        if(bytes>8*1024*1024)throw new AppError('output_limit','SSE response exceeds byte limit');
        stream.feed(decoder.decode(part.value,{stream:true}));
        if(Date.now()-lastSave>=1000){
          const saved=await env.DB.prepare("UPDATE chat_jobs SET content=?,reasoning=?,updated_at=? WHERE user_id=? AND id=? AND status='running'").bind(stream.content,stream.reasoning,Date.now(),userId,jobId).run();
          if(!saved.meta.changes)throw new AppError('cancelled','Generation cancelled');lastSave=Date.now();
        }
      }
      stream.feed(decoder.decode());stream.finish();
    }finally{await reader.cancel();}
    await env.DB.prepare("UPDATE chat_jobs SET status='succeeded',content=?,reasoning=?,usage_json=?,request_json=NULL,updated_at=? WHERE user_id=? AND id=? AND status='running'")
      .bind(stream.content,stream.reasoning,JSON.stringify(stream.usage??{}),Date.now(),userId,jobId).run();
  }catch(error){
    controller.abort();
    const code=error instanceof AppError?error.code:'generation_interrupted';
    await env.DB.prepare("UPDATE chat_jobs SET status='failed',content=?,reasoning=?,error_code=?,request_json=NULL,updated_at=? WHERE user_id=? AND id=? AND status='running'")
      .bind(stream.content,stream.reasoning,code,Date.now(),userId,jobId).run();
  }finally{clearTimeout(timeout);clearInterval(cancellationPoll);}
  msg.ack(); // No automatic model retry on ambiguous network/consumer failure.
}

export async function purgeChatJobs(env: ChatJobEnv) {
  await env.DB.prepare('DELETE FROM chat_jobs WHERE expires_at<?').bind(Date.now()).run();
}
