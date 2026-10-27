// Tests the email function (supabase/functions/notify-match/index.ts) with a fake mailer and fake database.
// Run:  npm install && npm test        (from the tests folder)
import { build } from 'esbuild';
import { fileURLToPath, pathToFileURL } from 'node:url';
import path from 'node:path';
import os from 'node:os';
import fs from 'node:fs';

const here = path.dirname(fileURLToPath(import.meta.url));
const entry = process.env.FUNCTION_PATH || path.resolve(here, '../../supabase/functions/notify-match/index.ts');
const outfile = path.join(fs.mkdtempSync(path.join(os.tmpdir(), 'notify-')), 'fn.mjs');

// Replace the Deno-only mail library import with a fake that records what would be sent
await build({
  entryPoints: [entry], bundle: true, format: 'esm', outfile, logLevel: 'error',
  plugins: [{ name: 'fake-mailer', setup(b) {
    b.onResolve({ filter: /^https:\/\/deno\.land/ }, () => ({ path: 'mailer', namespace: 'fake' }));
    b.onLoad({ filter: /.*/, namespace: 'fake' }, () => ({ contents: `
      export class SMTPClient {
        constructor(o) { globalThis.__smtpOpts = o; }
        async send(m) { if (globalThis.__failSend) throw new Error('smtp down'); globalThis.__sent.push(m); }
        async close() {}
      }`, loader: 'js' }));
  } }],
});

let handler; const env={GMAIL_USER:'bot@gmail.com',GMAIL_APP_PASSWORD:'pw',SUPABASE_URL:'http://db',SUPABASE_SERVICE_ROLE_KEY:'srv',SITE_URL:'https://tut.example'};
globalThis.Deno={serve:(h)=>{handler=h}, env:{get:(k)=>env[k]}};
globalThis.__sent=[]; const calls=[]; let rows={};
globalThis.fetch=async(url,opt)=>{ const name=url.split('/rpc/')[1]; const args=JSON.parse(opt.body); calls.push([name,args.p_id,opt.headers.Authorization]);
  let out=null;
  if(name==='claim_notification'){ const r=rows[args.p_id]; if(r&&!r.sent&&!r.claimed){r.claimed=true; out=r.data;} }
  if(name==='finish_notification'){ rows[args.p_id].sent=true; }
  if(name==='release_notification'){ rows[args.p_id].claimed=false; }
  return new Response(out===null?'null':JSON.stringify(out),{status:200}); };
await import(pathToFileURL(outfile).href);
const call=(body,method='POST')=>handler(new Request('http://f',{method,body:body===undefined?undefined:(typeof body==='string'?body:JSON.stringify(body))}));
let fails=0; const ok=(c,m)=>{console.log((c?'PASS ':'FAIL ')+m); if(!c)fails++;};
rows.m1={data:{kind:'matched',recipient_email:'a@student.guc.edu.eg',your_tut:'1',partner_tut:'2',coordinator_needed:true,partner_student_id:'55-2',partner_email:'bob@student.guc.edu.eg',partner_whatsapp:'bob_wa'}};
rows.m0={data:{kind:'matched',recipient_email:'a@student.guc.edu.eg',your_tut:'1',partner_tut:'2',coordinator_needed:false,partner_student_id:'55-9',partner_email:'x@student.guc.edu.eg',partner_whatsapp:null}};
rows.old={data:{kind:'matched',recipient_email:'a@student.guc.edu.eg',your_tut:'1',partner_tut:'2',coordinator_needed:false}};
rows.c1={data:{kind:'cancelled',recipient_email:'a@student.guc.edu.eg',your_tut:'1',rematched:false}};
rows.c2={data:{kind:'cancelled',recipient_email:'a@student.guc.edu.eg',your_tut:'1',rematched:true}};
rows.c3={data:{kind:'cancelled',recipient_email:'a@student.guc.edu.eg',your_tut:'1',partner_tut:'2',partner_student_id:'55-4',partner_email:'dave@student.guc.edu.eg',partner_whatsapp:'dave.w',coordinator_needed:true,rematched:true}};
let r=await call(undefined,'OPTIONS'); ok(r.status===200,'OPTIONS ok');
r=await call('not json'); ok(r.status===400,'bad json 400');
r=await call({to:'victim@x.com'}); ok(r.status===400&&__sent.length===0,'old-style {to} payload rejected, nothing sent');
r=await call({notification_id:'nope'}); ok((await r.json()).skipped&&__sent.length===0,'unknown id sends nothing');
r=await call({notification_id:'m1'}); let j=await r.json(); ok(j.success&&__sent.length===1,'matched sent');
const m=__sent[0]; ok(m.to==='a@student.guc.edu.eg'&&m.from==='bot@gmail.com','recipient from DB');
ok(m.content.includes('https://student.guc.edu.eg/')&&/Log in to your GUC portal/i.test(m.content),'GUC portal login link in email');
ok(m.content.includes('Tut 1 → Tut 2')&&m.content.includes('coordinator')&&m.content.includes('https://tut.example'),'swap, coordinator, site url');
ok(m.content.includes('55-2')&&m.content.includes('bob@student.guc.edu.eg')&&m.content.includes('bob_wa'),'email has partner id, email, whatsapp');
ok(m.content.includes('Scheduling → Change Group')&&m.content.includes('student ID: 55-2')&&m.content.includes('accept your request from their own portal')&&!m.content.includes('Contact your partner first')&&m.content.includes('Go to TutMatching: https://tut.example'),'match email: new steps, partner id, site url');
r=await call({notification_id:'m1'}); ok((await r.json()).skipped&&__sent.length===1,'second call does not resend');
r=await call({notification_id:'c1'}); ok(__sent.length===2&&/cancelled/i.test(__sent[1].subject)&&__sent[1].content.includes('back in the queue')&&__sent[1].content.includes('https://tut.example'),'cancel email (not rematched) with site url');
r=await call({notification_id:'c2'}); ok(__sent[2].content.includes('new match'),'cancel email (rematched, old-style row falls back)');
r=await call({notification_id:'c3'}); const cm=__sent[3]; 
ok(cm.content.includes('55-4')&&cm.content.includes('dave@student.guc.edu.eg')&&cm.content.includes('dave.w')&&cm.content.includes('Scheduling → Change Group')&&cm.content.includes('student ID: 55-4')&&cm.content.includes('https://tut.example')&&cm.content.includes('coordinator'),'rematched cancel email: partner details, steps, site url, coordinator');
globalThis.__shift=1;
await call({notification_id:'m0'}); ok(__sent[4].content.includes('55-9')&&!/whatsapp/i.test(__sent[4].content),'no whatsapp line when none given');
await call({notification_id:'old'}); ok(__sent[5].content.includes('Log back into TutMatching'),'old notification falls back');
rows.f1={data:{kind:'matched',recipient_email:'z@student.guc.edu.eg',your_tut:'3',partner_tut:'4',coordinator_needed:false}};
globalThis.__failSend=true; r=await call({notification_id:'f1'}); ok(r.status===500&&rows.f1.claimed===false&&!rows.f1.sent,'smtp failure -> 500, released for retry'); globalThis.__failSend=false;
r=await call({notification_id:'f1'}); ok(r.status===200&&rows.f1.sent,'retry after failure succeeds');
ok(calls.every(c=>c[2]==='Bearer srv'),'db calls use service key');
console.log(fails?'FAILED':'ALL PASS'); process.exit(fails?1:0);
