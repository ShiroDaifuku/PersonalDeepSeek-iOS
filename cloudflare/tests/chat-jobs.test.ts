import { describe, expect, it } from 'vitest';
import { ChatStreamAccumulator, chatRoutes, consumeChat, validateChatSubmission, type ChatJobEnv, type ChatRunMessage } from '../src/chat-jobs';

const id='11111111-1111-4111-8111-111111111111';
const submission=()=>({id,assistantMessageID:id,conversationID:'22222222-2222-4222-8222-222222222222',userMessageID:'33333333-3333-4333-8333-333333333333',request:{
  model:'deepseek-flash',messages:[{role:'system',content:'fixed prefix'},{role:'user',content:'question'}],
  thinking:{type:'enabled'},reasoning_effort:'high',stream:true,stream_options:{include_usage:true}
}});
const frame=(value:unknown)=>`data: ${JSON.stringify(value)}\n\n`;
const goodStream=()=>': keepalive\n\n'+frame({choices:[{index:0,delta:{reasoning_content:'核验条件'}}]})+
  frame({choices:[{index:0,delta:{content:'答案 $2x$'}}]})+frame({choices:[{index:0,delta:{},finish_reason:'stop'}]})+'data: [DONE]\n\n';

describe('durable cloud chat contract',()=>{
  it('keeps exactly the original text prefix and accepts only supported text requests',()=>{
    const raw=submission();expect(validateChatSubmission(raw)).toEqual(raw);
    for(const patch of [{tools:[]},{model:'arbitrary'},{max_tokens:32769},{messages:[{role:'tool',content:'injected'}]},
      {messages:[{role:'user',content:[{type:'image_url',image_url:{url:'https://example.com'}}]}]}]) {
      expect(()=>validateChatSubmission({...raw,request:{...raw.request,...patch}})).toThrow();
    }
    expect(()=>validateChatSubmission({...raw,id:'bad'})).toThrow();
    expect(()=>validateChatSubmission({...raw,assistantMessageID:raw.userMessageID})).toThrow();
    expect(()=>validateChatSubmission({...raw,request:{...raw.request,messages:[{role:'user',content:'x'.repeat(900001)}]}})).toThrow();
  });
  it('parses fragmented SSE, CRLF and keep-alives without losing reasoning or completion',()=>{
    const stream=new ChatStreamAccumulator();
    for(const character of goodStream().replaceAll('\n','\r\n'))stream.feed(character);
    stream.finish();expect(stream.content).toBe('答案 $2x$');expect(stream.reasoning).toBe('核验条件');
  });
  it('rejects truncated, tool, over-budget and non-stop output as incomplete',()=>{
    for(const input of [frame({choices:[{delta:{content:'partial'}}]}),': heartbeat\n\n',
      frame({choices:[{delta:{content:'partial'},finish_reason:'length'}]}),
      frame({choices:[{delta:{tool_calls:[{id:'call'}]}}]}),
      frame({choices:[{delta:{content:'x'.repeat(200001)}}]})]) {
      expect(()=>{const stream=new ChatStreamAccumulator();stream.feed(input);stream.finish();}).toThrow();
    }
  });
  it('fails closed when cloud ownership or infrastructure is missing',async()=>{
    const env={DB:{} as D1Database,DEEPSEEK_API_KEY:'test-fixture',CHAT_QUEUE:{} as Queue<ChatRunMessage>,CHAT_USER_ID:'owner'};
    await expect(chatRoutes(new Request('https://worker/v1/chat-jobs/capabilities'),env,'other')).rejects.toMatchObject({status:403});
    await expect(chatRoutes(new Request('https://worker/v1/chat-jobs/capabilities'),{...env,CHAT_USER_ID:undefined},'owner')).rejects.toMatchObject({status:503});
    const result=await chatRoutes(new Request('https://worker/v1/chat-jobs/capabilities'),env,'owner');
    expect(await result!.json()).toMatchObject({enabled:true,textOnly:true,serverKey:true});
    expect(await chatRoutes(new Request('https://worker/v1/tasks'),env,'other')).toBeUndefined();
  });
});

// A deterministic consumer fixture, not a substitute for a deployed D1/Queues smoke test.
function fixture(){
  const row:any={user_id:'owner',id,request_json:JSON.stringify(submission().request),status:'queued',content:'',reasoning:'',expires_at:Date.now()+86400000};
  const sqls:string[]=[];
  const db={prepare(sql:string){sqls.push(sql);let args:any[]=[];return {bind(...values:any[]){args=values;return this;},async first(){return row;},async run(){
    let changes=0;
    if(sql.includes("SET status='running'")&&row.status==='queued'){row.status='running';changes=1;}
    else if(sql.includes("SET status='succeeded'")&&row.status==='running'){row.status='succeeded';row.content=args[0];row.reasoning=args[1];row.request_json=null;changes=1;}
    else if(sql.includes("SET status='failed'")&&row.status==='running'){row.status='failed';row.error_code=args[2];row.request_json=null;changes=1;}
    return {meta:{changes}};
  }}}};
  const env:ChatJobEnv={DB:db as unknown as D1Database,DEEPSEEK_API_KEY:'unit-test-secret',CHAT_USER_ID:'owner'};
  let acknowledgements=0;
  const message={body:{kind:'chat',userId:'owner',jobId:id},ack(){acknowledgements++;}} as Message<ChatRunMessage>;
  return {row,env,message,sqls,acks:()=>acknowledgements};
}
describe('durable consumer one-attempt boundary',()=>{
  it('persists result, erases frozen prompt, isolates owner and claims duplicate delivery only once',async()=>{
    const f=fixture();let calls=0;
    const provider=(async(_url:any,input:any)=>{calls++;const body=JSON.parse(input.body);expect(body.user_id).toBe('owner');expect(body.messages).toEqual(submission().request.messages);return new Response(goodStream());}) as typeof fetch;
    await consumeChat(f.env,f.message,provider);await consumeChat(f.env,f.message,provider);
    expect(calls).toBe(1);expect(f.acks()).toBe(2);expect(f.row.status).toBe('succeeded');
    expect(f.row.content).toBe('答案 $2x$');expect(f.row.request_json).toBeNull();
    expect(f.sqls.join('\n')).not.toContain('unit-test-secret');
    const stranger=fixture();stranger.message.body.userId='other';await consumeChat(stranger.env,stranger.message,provider);expect(calls).toBe(1);
  });
  it('does not repeat an ambiguous network request or mark partial output successful',async()=>{
    const f=fixture();let calls=0;
    const provider=(async()=>{calls++;throw new Error('network');}) as typeof fetch;
    await consumeChat(f.env,f.message,provider);await consumeChat(f.env,f.message,provider);
    expect(calls).toBe(1);expect(f.row.status).toBe('failed');expect(f.row.request_json).toBeNull();
    const partial=fixture();await consumeChat(partial.env,partial.message,(async()=>new Response(frame({choices:[{delta:{content:'partial'}}]}))) as typeof fetch);
    expect(partial.row.status).toBe('failed');
  });
  it('a cancellation that wins during generation cannot be overwritten by success',async()=>{
    const f=fixture();
    await consumeChat(f.env,f.message,(async()=>{f.row.status='cancelled';return new Response(goodStream());}) as typeof fetch);
    expect(f.row.status).toBe('cancelled');expect(f.acks()).toBe(1);
  });
});
