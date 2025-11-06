-- Blueprint4 Kernel Definitions
-- This file seeds the database with all core kernels from Blueprint4 specification
-- These are the foundational execution kernels that power LogLineOS

-- ============================================================================
-- 1. run_code_kernel (ID: 00000000-0000-4000-8000-000000000001, seq: 2)
-- Core execution kernel with advisory locks, quotas, and signature verification
-- ============================================================================

INSERT INTO ledger.universal_registry  
(id,seq,entity_type,who,did,"this",at,status,name,code,language,runtime,owner_id,tenant_id,visibility)  
VALUES  
('00000000-0000-4000-8000-000000000001',2,'function','daniel','defined','function',now(),'active',  
'run_code_kernel', $$
globalThis.default = async function main(ctx){
  const { sql, insertSpan, now, crypto, env } = ctx;

  async function latestManifest(){
    const { rows } = await sql`SELECT * FROM ledger.visible_timeline WHERE entity_type='manifest' ORDER BY "when" DESC LIMIT 1`;
    return rows[0] || { metadata:{} };
  }
  
  async function sign(span){
    const clone = structuredClone(span); delete clone.signature; delete clone.curr_hash;
    const msg = new TextEncoder().encode(JSON.stringify(clone, Object.keys(clone).sort()));
    const h = crypto.hex(crypto.blake3(msg)); span.curr_hash = h;
    if (env.SIGNING_KEY_HEX){
      const priv = crypto.toU8(env.SIGNING_KEY_HEX);
      const pub = await crypto.ed25519.getPublicKey(priv);
      span.signature = crypto.hex(await crypto.ed25519.sign(crypto.toU8(h), priv));
      span.public_key = crypto.hex(pub);
    }
  }
  
  async function tryLock(id){ const r = await sql`SELECT pg_try_advisory_lock(hashtext(${id}::text)) ok`; return !!r.rows?.[0]?.ok; }
  async function unlock(id){ await sql`SELECT pg_advisory_unlock(hashtext(${id}::text))`; }

  const SPAN_ID = globalThis.SPAN_ID || Deno?.env?.get?.("SPAN_ID");
  if (!SPAN_ID) throw new Error("SPAN_ID required");
  if (!env.APP_USER_ID) throw new Error("APP_USER_ID required");

  const manifest = await latestManifest();
  const throttleLimit = Number(manifest.metadata?.throttle?.per_tenant_daily_exec_limit || 100);
  const slowMs = Number(manifest.metadata?.policy?.slow_ms || 5000);
  const allowed = (manifest.metadata?.allowed_boot_ids||[]);
  if (!allowed.includes(manifest.metadata?.kernels?.run_code)) throw new Error("run_code not allowed by manifest");

  const { rows: fnRows } = await sql`SELECT * FROM ledger.visible_timeline WHERE id=${SPAN_ID} ORDER BY "when" DESC, seq DESC LIMIT 1`;
  const fnSpan = fnRows[0]; if (!fnSpan) throw new Error("target function not found");
  if (fnSpan.entity_type !== 'function') throw new Error("run_code only executes entity_type=function");
  if (env.APP_TENANT_ID && String(fnSpan.tenant_id) !== String(env.APP_TENANT_ID)) throw new Error("tenant mismatch");

  // Tenant-level lock prevents throttle race condition
  const tenantLockKey = `throttle:${fnSpan.tenant_id}`;
  const tenantLocked = await tryLock(tenantLockKey);
  if (!tenantLocked) { await new Promise(r=>setTimeout(r,100)); return; }
  
  try {
    const { rows: usedR } = await sql`
      SELECT count(*)::int c FROM ledger.visible_timeline
      WHERE entity_type='execution' AND tenant_id IS NOT DISTINCT FROM ${fnSpan.tenant_id} AND "when"::date = now()::date`;
    const used = usedR[0]?.c || 0;
    if (used >= throttleLimit && !((fnSpan.metadata?.force) && fnSpan.public_key && fnSpan.public_key.toLowerCase() === (manifest.metadata?.override_pubkey_hex||'').toLowerCase())){
      await insertSpan({
        id: crypto.randomUUID(), seq:0, entity_type:'policy_violation',
        who:'edge:run_code', did:'blocked', this:'quota.exec.per_tenant.daily',
        at: now(), status:'error',
        owner_id: fnSpan.owner_id, tenant_id: fnSpan.tenant_id, visibility: fnSpan.visibility ?? 'private',
        related_to:[fnSpan.id],
        metadata:{ limit: throttleLimit, today: used }
      });
      await unlock(tenantLockKey);
      return;
    }
  } finally {
    await unlock(tenantLockKey);
  }

  if (!(await tryLock(fnSpan.id))) return;
  const timeoutMs = slowMs;
  const start = performance.now();
  let output=null, error=null, trace = fnSpan.trace_id || crypto.randomUUID();

  function execSandbox(code, input){
    const workerCode = `
      self.onmessage = async (e)=>{
        const { code, input } = e.data;
        let fn; try { fn = new Function('input', code); }
        catch (err){ self.postMessage({e:'compile', d:String(err)}); return; }
        try { const r = await fn(input); self.postMessage({ok:true, r}); }
        catch (err){ self.postMessage({e:'runtime', d:String(err)}); }
      };
    `;
    const blob = new Blob([workerCode], { type: "text/javascript" });
    const url = URL.createObjectURL(blob);
    const w = new Worker(url, { type:"module" });
    return new Promise((resolve,reject)=>{
      const cleanup = () => { try{w.terminate();}catch{}; try{URL.revokeObjectURL(url);}catch{} };
      const to = setTimeout(()=>{ cleanup(); reject(new Error('timeout')); }, timeoutMs);
      w.onmessage = (e)=>{ clearTimeout(to); cleanup(); const d=e.data; if (d?.ok) resolve(d.r); else reject(new Error(`${d?.e}:${d?.d}`)); };
      w.onerror = (e)=>{ clearTimeout(to); cleanup(); reject(e.error ?? new Error('worker_error')); };
      w.postMessage({ code, input });
    });
  }

  try { output = await execSandbox(String(fnSpan.code||''), fnSpan.input ?? null); }
  catch (e){ error = { message:String(e) }; }
  finally {
    const dur = Math.round(performance.now()-start);
    const execSpan = {
      id: crypto.randomUUID(), seq:0, parent_id: fnSpan.id, entity_type:'execution',
      who:'edge:run_code', did:'executed', this:'run_code',
      at: now(), status: error? 'error' : 'complete',
      input: fnSpan.input ?? null, output: error? null: output, error,
      duration_ms: dur, trace_id: trace,
      owner_id: fnSpan.owner_id, tenant_id: fnSpan.tenant_id, visibility: fnSpan.visibility ?? 'private',
      related_to:[fnSpan.id]
    };
    if (!error && dur > slowMs) {
      execSpan.status = 'complete';
      await insertSpan({
        id: crypto.randomUUID(), seq:0, entity_type:'status_patch',
        who:'edge:run_code', did:'labeled', this:'status=slow',
        at: now(), status:'complete',
        parent_id: execSpan.id, related_to:[execSpan.id],
        owner_id: fnSpan.owner_id, tenant_id: fnSpan.tenant_id, visibility: fnSpan.visibility ?? 'private',
        metadata:{ status:'slow', duration_ms: dur }
      });
    }
    await sign(execSpan);
    await insertSpan(execSpan);
    await unlock(fnSpan.id);
  }
};
$$,'javascript','deno@1.x','daniel','voulezvous','tenant')
ON CONFLICT (id, seq) DO UPDATE SET code = EXCLUDED.code, at = now();

-- ============================================================================
-- 2. observer_bot_kernel (ID: 00000000-0000-4000-8000-000000000002, seq: 2)
-- Monitors timeline and schedules function executions with idempotency
-- ============================================================================

INSERT INTO ledger.universal_registry  
(id,seq,entity_type,who,did,"this",at,status,name,code,language,runtime,owner_id,tenant_id,visibility)  
VALUES  
('00000000-0000-4000-8000-000000000002',2,'function','daniel','defined','function',now(),'active',  
'observer_bot_kernel', $$
globalThis.default = async function main(ctx){
  const { sql, now } = ctx;

  async function tryLock(id){ const r = await sql`SELECT pg_try_advisory_lock(hashtext(${id}::text)) ok`; return !!r.rows?.[0]?.ok; }
  async function unlock(id){ await sql`SELECT pg_advisory_unlock(hashtext(${id}::text))`; }
  
  async function limitForTenant(tid){
    const { rows } = await sql`SELECT (metadata->'throttle'->>'per_tenant_daily_exec_limit')::int lim
      FROM ledger.visible_timeline WHERE entity_type='manifest' ORDER BY "when" DESC LIMIT 1`;
    return rows[0]?.lim ?? 100;
  }
  
  async function todayExecs(tid){
    const { rows } = await sql`SELECT count(*)::int c FROM ledger.visible_timeline
      WHERE entity_type='execution' AND tenant_id IS NOT DISTINCT FROM ${tid} AND "when"::date=now()::date`;
    return rows[0]?.c || 0;
  }

  const { rows } = await sql`
    SELECT id, owner_id, tenant_id, visibility
    FROM ledger.visible_timeline
    WHERE entity_type='function' AND status='scheduled'
    ORDER BY "when" ASC LIMIT 16`;

  for (const s of rows){
    if (!(await tryLock(s.id))) continue;
    try {
      const lim = await limitForTenant(s.tenant_id);
      const used = await todayExecs(s.tenant_id);
      if (used >= lim) {
        await sql`
          INSERT INTO ledger.universal_registry
          (id,seq,who,did,"this",at,entity_type,status,parent_id,related_to,owner_id,tenant_id,visibility,metadata)
          VALUES
          (gen_random_uuid(),0,'edge:observer','blocked','quota.exec.per_tenant.daily',${now()},'policy_violation','error',
           ${s.id}, ARRAY[${s.id}]::uuid[], ${s.owner_id}, ${s.tenant_id}, ${s.visibility}, jsonb_build_object('limit',${lim},'today',${used}))`;
        continue;
      }

      await sql`
        INSERT INTO ledger.universal_registry
        (id,seq,who,did,"this",at,entity_type,status,parent_id,related_to,owner_id,tenant_id,visibility,trace_id)
        VALUES
        (gen_random_uuid(),0,'edge:observer','scheduled','run_code',${now()},'request','scheduled',
         ${s.id}, ARRAY[${s.id}]::uuid[], ${s.owner_id}, ${s.tenant_id}, ${s.visibility}, gen_random_uuid()::text)
        ON CONFLICT DO NOTHING`;
    } finally { await unlock(s.id); }
  }
};
$$,'javascript','deno@1.x','daniel','voulezvous','tenant')
ON CONFLICT (id, seq) DO UPDATE SET code = EXCLUDED.code, at = now();

-- ============================================================================
-- 3. request_worker_kernel (ID: 00000000-0000-4000-8000-000000000003, seq: 2)
-- Processes scheduled request spans by executing target kernels
-- ============================================================================

INSERT INTO ledger.universal_registry  
(id,seq,entity_type,who,did,"this",at,status,name,code,language,runtime,owner_id,tenant_id,visibility)  
VALUES  
('00000000-0000-4000-8000-000000000003',2,'function','daniel','defined','function',now(),'active',  
'request_worker_kernel', $$
globalThis.default = async function main(ctx){
  const { sql } = ctx;
  const RUN_CODE_KERNEL_ID = globalThis.RUN_CODE_KERNEL_ID || Deno?.env?.get?.("RUN_CODE_KERNEL_ID") || "00000000-0000-4000-8000-000000000001";

  async function latestKernel(id){
    const { rows } = await sql`SELECT * FROM ledger.visible_timeline WHERE id=${id} AND entity_type='function' ORDER BY "when" DESC, seq DESC LIMIT 1`;
    return rows[0] || null;
  }
  
  async function tryLock(id){ const r = await sql`SELECT pg_try_advisory_lock(hashtext(${id}::text)) ok`; return !!r.rows?.[0]?.ok; }
  async function unlock(id){ await sql`SELECT pg_advisory_unlock(hashtext(${id}::text))`; }

  const { rows: reqs } = await sql`
    SELECT id, parent_id FROM ledger.visible_timeline
    WHERE entity_type='request' AND status='scheduled'
    ORDER BY "when" ASC LIMIT 8`;
  if (!reqs.length) return;

  const runKernel = await latestKernel(RUN_CODE_KERNEL_ID);
  if (!runKernel?.code) throw new Error("run_code_kernel not found");

  for (const r of reqs){
    if (!(await tryLock(r.parent_id))) continue;
    try {
      globalThis.SPAN_ID = r.parent_id;
      const factory = new Function("ctx", `"use strict";\n${String(runKernel.code)}\n;return (typeof default!=='undefined'?default:globalThis.main);`);
      const main = factory(ctx); if (typeof main !== "function") throw new Error("run_code module invalid");
      await main(ctx);
    } finally { await unlock(r.parent_id); }
  }
};
$$,'javascript','deno@1.x','daniel','voulezvous','tenant')
ON CONFLICT (id, seq) DO UPDATE SET code = EXCLUDED.code, at = now();

-- ============================================================================
-- 4. policy_agent_kernel (ID: 00000000-0000-4000-8000-000000000004, seq: 1)
-- Executes policy spans against timeline events with sandboxed evaluation
-- ============================================================================

INSERT INTO ledger.universal_registry  
(id,seq,entity_type,who,did,"this",at,status,name,code,language,runtime,owner_id,tenant_id,visibility)  
VALUES  
('00000000-0000-4000-8000-000000000004',1,'function','daniel','defined','function',now(),'active',  
'policy_agent_kernel', $$
globalThis.default = async function main(ctx){
  const { sql, insertSpan, now, crypto } = ctx;

  function sandboxEval(code, span){
    const wcode = `
      self.onmessage = (e)=>{
        const { code, span } = e.data;
        try {
          const fn = new Function('span', code + '\\n;return (typeof default!=="undefined"?default:on)||on;')();
          const out = fn? fn(span):[];
          self.postMessage({ ok:true, actions: out||[] });
        } catch (err){ self.postMessage({ ok:false, error:String(err) }); }
      };
    `;
    const blob = new Blob([wcode], { type:"text/javascript" });
    const url = URL.createObjectURL(blob);
    const w = new Worker(url, { type:"module" });
    return new Promise((resolve,reject)=>{
      const to = setTimeout(()=>{ try{w.terminate();}catch{}; reject(new Error("timeout")); }, 3000);
      w.onmessage = (e)=>{ clearTimeout(to); try{w.terminate();}catch{}; const d=e.data; d?.ok? resolve(d.actions): reject(new Error(d?.error||"policy error")); };
      w.onerror = (e)=>{ clearTimeout(to); try{w.terminate();}catch{}; reject(e.error??new Error("worker error")); };
      w.postMessage({ code, span });
    });
  }
  
  async function sign(span){
    const clone = structuredClone(span); delete clone.signature; delete clone.curr_hash;
    const msg = new TextEncoder().encode(JSON.stringify(clone, Object.keys(clone).sort()));
    const h = crypto.hex(crypto.blake3(msg)); span.curr_hash = h;
  }
  
  async function latestCursor(policyId){
    const { rows } = await sql`SELECT max("when") AS at FROM ledger.visible_timeline WHERE entity_type='policy_cursor' AND related_to @> ARRAY[${policyId}]::uuid[]`;
    return rows[0]?.at || null;
  }

  const { rows: policies } = await sql`
    SELECT * FROM ledger.visible_timeline WHERE entity_type='policy' AND status='active' ORDER BY "when" ASC`;

  for (const p of policies){
    const since = await latestCursor(p.id);
    const { rows: candidates } = await sql`
      SELECT * FROM ledger.visible_timeline
      WHERE "when" > COALESCE(${since}, to_timestamp(0))
        AND tenant_id IS NOT DISTINCT FROM ${p.tenant_id}
      ORDER BY "when" ASC LIMIT 500`;
    let lastAt = since;
    for (const s of candidates){
      const actions = await sandboxEval(String(p.code||""), s).catch(async (err)=>{
        await insertSpan({
          id: crypto.randomUUID(), seq:0, entity_type:'policy_error',
          who:'edge:policy_agent', did:'failed', this:'policy.eval',
          at: now(), status:'error',
          error: { message: String(err), policy_id: p.id, target_span: s.id },
          owner_id:p.owner_id, tenant_id:p.tenant_id, visibility:p.visibility||'private',
          related_to:[p.id, s.id]
        });
        return [];
      });
      for (const a of actions){
        if (a?.run === "run_code" && a?.span_id){
          const req = {
            id: crypto.randomUUID(), seq:0, entity_type:'request', who:'edge:policy_agent', did:'triggered', this:'run_code',
            at: now(), status:'scheduled', parent_id: a.span_id, related_to:[p.id, a.span_id],
            owner_id:p.owner_id, tenant_id:p.tenant_id, visibility:p.visibility||'private',
            metadata: { policy_id: p.id, trigger_span: s.id }
          };
          await sign(req); await insertSpan(req);
        } else if (a?.emit_span){
          const e = a.emit_span;
          e.id ||= crypto.randomUUID(); e.seq ??= 0; e.at ||= now();
          e.owner_id ??= p.owner_id; e.tenant_id ??= p.tenant_id; e.visibility ??= p.visibility||'private';
          await sign(e); await insertSpan(e);
        }
      }
      lastAt = s["when"] || lastAt;
    }
    if (lastAt){
      const cursor = {
        id: crypto.randomUUID(), seq:0, entity_type:'policy_cursor', who:'edge:policy_agent', did:'advanced', this:'cursor',
        at: now(), status:'complete', related_to:[p.id],
        owner_id:p.owner_id, tenant_id:p.tenant_id, visibility:p.visibility||'private',
        metadata:{ last_at:lastAt }
      };
      await sign(cursor); await insertSpan(cursor);
    }
  }
};
$$,'javascript','deno@1.x','daniel','voulezvous','tenant')
ON CONFLICT (id, seq) DO UPDATE SET code = EXCLUDED.code, at = now();

-- ============================================================================
-- 5. provider_exec_kernel (ID: 00000000-0000-4000-8000-000000000005, seq: 1)
-- Executes external provider calls (OpenAI, Ollama, etc.)
-- ============================================================================

INSERT INTO ledger.universal_registry  
(id,seq,entity_type,who,did,"this",at,status,name,code,language,runtime,owner_id,tenant_id,visibility)  
VALUES  
('00000000-0000-4000-8000-000000000005',1,'function','daniel','defined','function',now(),'active',  
'provider_exec_kernel', $$
globalThis.default = async function main(ctx){
  const { sql, insertSpan, now, crypto, env } = ctx;

  async function loadProvider(id){
    const { rows } = await sql`SELECT * FROM ledger.visible_timeline WHERE id=${id} AND entity_type='provider' ORDER BY "when" DESC, seq DESC LIMIT 1`;
    return rows[0] || null;
  }
  
  async function sign(span){
    const clone = structuredClone(span); delete clone.signature; delete clone.curr_hash;
    const msg = new TextEncoder().encode(JSON.stringify(clone, Object.keys(clone).sort()));
    const h = crypto.hex(crypto.blake3(msg)); span.curr_hash = h;
  }

  const PROVIDER_ID = globalThis.PROVIDER_ID || Deno?.env?.get?.("PROVIDER_ID");
  const PAYLOAD = JSON.parse(globalThis.PROVIDER_PAYLOAD || Deno?.env?.get?.("PROVIDER_PAYLOAD") || "{}");
  const prov = await loadProvider(PROVIDER_ID);
  if (!prov) throw new Error("provider not found");

  const meta = prov.metadata || {};
  let out=null, error=null;

  try {
    if (meta.base_url?.includes("openai.com")) {
      const r = await fetch(`${meta.base_url}/chat/completions`, {
        method: "POST",
        headers: { "content-type":"application/json", "authorization": `Bearer ${env.OPENAI_API_KEY || ""}` },
        body: JSON.stringify({ model: meta.model, messages: PAYLOAD.messages, temperature: PAYLOAD.temperature ?? 0.2 })
      });
      out = await r.json();
    } else if ((meta.base_url||"").includes("localhost:11434")) {
      const r = await fetch(`${meta.base_url}/api/chat`, {
        method: "POST", headers: { "content-type":"application/json" },
        body: JSON.stringify({ model: meta.model || "llama3", messages: PAYLOAD.messages })
      });
      out = await r.json();
    } else { throw new Error("unsupported provider"); }
  } catch(e){ error = { message: String(e) }; }

  const execSpan = {
    id: crypto.randomUUID(), seq:0, entity_type:'provider_execution',
    who:'edge:provider_exec', did:'called', this:'provider.exec',
    at: now(), status: error? 'error':'complete',
    input: PAYLOAD, output: error? null: out, error,
    owner_id: prov.owner_id, tenant_id: prov.tenant_id, visibility: prov.visibility ?? 'private',
    related_to: [prov.id]
  };
  await sign(execSpan); await insertSpan(execSpan);
};
$$,'javascript','deno@1.x','daniel','voulezvous','tenant')
ON CONFLICT (id, seq) DO UPDATE SET code = EXCLUDED.code, at = now();

-- ============================================================================
-- 6. Manifest - Kernel Governance and Configuration
-- ============================================================================

INSERT INTO ledger.universal_registry  
(id,seq,entity_type,who,did,"this",at,status,name,metadata,owner_id,tenant_id,visibility)  
VALUES  
('00000000-0000-4000-8000-0000000000aa',2,'manifest','daniel','defined','manifest',now(),'active',  
'kernel_manifest',  
jsonb_build_object(  
  'kernels', jsonb_build_object(  
    'run_code','00000000-0000-4000-8000-000000000001',  
    'observer','00000000-0000-4000-8000-000000000002',  
    'request_worker','00000000-0000-4000-8000-000000000003',  
    'policy_agent','00000000-0000-4000-8000-000000000004',  
    'provider_exec','00000000-0000-4000-8000-000000000005',  
    'stage0_loader','00000000-0000-4000-8000-0000000000ff'  
  ),  
  'allowed_boot_ids', jsonb_build_array(  
    '00000000-0000-4000-8000-000000000001',  
    '00000000-0000-4000-8000-000000000002',  
    '00000000-0000-4000-8000-000000000003',  
    '00000000-0000-4000-8000-000000000004',  
    '00000000-0000-4000-8000-000000000005',  
    '00000000-0000-4000-8000-0000000000ff'  
  ),  
  'throttle', jsonb_build_object('per_tenant_daily_exec_limit', 100),  
  'policy', jsonb_build_object('slow_ms', 5000),  
  'override_pubkey_hex', 'ADMIN_PUBKEY_PLACEHOLDER'  
),  
'daniel','voulezvous','tenant')
ON CONFLICT (id, seq) DO UPDATE SET metadata = EXCLUDED.metadata, at = now();
