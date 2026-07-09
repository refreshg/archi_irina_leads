// Vercel serverless function: GET /api/leads?from=...&to=...&key=...
// Mirrors archi_leads_export.ps1 — finds deals that MOVED INTO the
// "ვერ დავუკავშირდი" stage in the given range and returns them as JSON.
//
// Webhook tokens live ONLY on the server (env vars, with fallback constants).
// Optional access guard: set ACCESS_KEY in Vercel to require ?key=...

const DEAL = process.env.BX_DEAL     || 'https://crm.archi.ge/rest/1/xmbjzulaie03bgxg/';
const STAT = process.env.BX_STATUS   || 'https://crm.archi.ge/rest/1/yp0n11acdy148v1g/';
const TL   = process.env.BX_TIMELINE || 'https://crm.archi.ge/rest/1/nfy7m5s80ado9vi7/';

// Report definitions. `nocontact` is the original report — unchanged.
const REPORTS = {
  nocontact: {
    label: 'ვერ დავუკავშირდი',
    targets: [
      { type: 'Sale', pipeline: '0 (Sale Leads)', categoryId: '0',  stageId: '7' },
      { type: 'Hot',  pipeline: '35 (Hot Leads)', categoryId: '35', stageId: 'C35:FINAL_INVOICE' },
      { type: 'Hot',  pipeline: '35 (Hot Leads)', categoryId: '35', stageId: 'C35:17' }, // ვერშედგა კონტაქტი
    ],
    currentStages: ['7','C35:FINAL_INVOICE','C35:17'],
    keepOnlyCurrent: true,   // only deals STILL sitting in the stage
  },
  interested: {
    label: 'დაინტერესებული',
    targets: [
      { type: 'Sale', pipeline: '0 (Sale Leads)', categoryId: '0',  stageId: '8' },
      { type: 'Hot',  pipeline: '35 (Hot Leads)', categoryId: '35', stageId: 'C35:WON' },
    ],
    currentStages: ['8','C35:WON'],
    keepOnlyCurrent: false,  // everyone who ENTERED the stage, wherever they are now (even JUNK)
  },
};
const STAGE_ENTITIES = ['DEAL_STAGE', 'DEAL_STAGE_35'];
const DEAL_SELECT = ['ID','TITLE','CATEGORY_ID','STAGE_ID','DATE_CREATE','CONTACT_ID','COMPANY_ID','UF_CRM_1700569256804'];

function pad(n){ return String(n).padStart(2,'0'); }
function chunk(a,n){ const o=[]; for(let i=0;i<a.length;i+=n) o.push(a.slice(i,i+n)); return o; }
function qs(p){ return Object.entries(p).map(([k,v]) => `${k}=${encodeURIComponent(v)}`).join('&'); }

async function call(base, method, payload){
  let lastErr;
  for(let i=0;i<3;i++){
    try{
      const r = await fetch(base + method + '.json', {
        method:'POST', headers:{'content-type':'application/json'},
        body: JSON.stringify(payload || {})
      });
      const j = await r.json();
      if(j.error) throw new Error(j.error + ': ' + (j.error_description || ''));
      return j;
    }catch(e){ lastErr=e; await new Promise(s=>setTimeout(s, 400*(i+1))); }
  }
  throw lastErr;
}
async function batch(base, cmds){ const j = await call(base,'batch',{halt:0,cmd:cmds}); return j.result; }

// run `worker` over items with bounded concurrency (avoids hammering Bitrix / timing out)
async function pool(items, limit, worker){
  let i = 0;
  await Promise.all(Array.from({ length: Math.min(limit, items.length) }, async () => {
    while(i < items.length){ const idx = i++; await worker(items[idx]); }
  }));
}

// stagehistory returns result.items (not a plain array) and supports start/total
async function stageHistAll(payload){
  const out=[]; let start=0, total=0;
  do{
    const j = await call(DEAL,'crm.stagehistory.list',{...payload,start});
    const items = (j.result && j.result.items) ? j.result.items : [];
    out.push(...items);
    total = parseInt(j.total || 0, 10);
    start += 50;
  } while(start < total);
  return out;
}
async function listAll(base, method, payload){
  const out=[]; let start=0, total=0;
  do{
    const j = await call(base, method, {...payload, start});
    out.push(...(j.result || []));
    total = parseInt(j.total || 0, 10);
    start += 50;
  } while(start < total);
  return out;
}

function defaultYesterday(){
  // Georgia = UTC+4 (no DST)
  const nowG = new Date(Date.now() + 4*3600*1000);
  const y = new Date(nowG.getTime() - 24*3600*1000);
  return `${y.getUTCFullYear()}-${pad(y.getUTCMonth()+1)}-${pad(y.getUTCDate())}`;
}

module.exports = async (req, res) => {
  try{
    const ACCESS_KEY = process.env.ACCESS_KEY || '3377';
    const key = (req.query && req.query.key) || '';
    if(key !== ACCESS_KEY){
      return res.status(401).json({ error: 'არასწორი PIN კოდი' });
    }
    // lightweight PIN check (used by the login gate) — skip the heavy work
    if(req.query && req.query.check){
      return res.status(200).json({ ok: true });
    }

    const day  = defaultYesterday();
    const from = (req.query && req.query.from) || `${day}T00:00:00`;
    const to   = (req.query && req.query.to)   || `${day}T23:59:59`;

    // which report? default = the original "ვერ დავუკავშირდი" one
    const reportKey = (req.query && req.query.report) || 'nocontact';
    const rep = REPORTS[reportKey];
    if(!rep) return res.status(400).json({ error: 'უცნობი რეპორტი: ' + reportKey });

    // 1) stage-name map (for current-stage resolution) — loaded lazily per entity,
    //    because deals may have moved on into any other pipeline (e.g. JUNK).
    const stageName = {};
    const loadedEnts = new Set();
    const entityOf = (cat) => String(cat) === '0' ? 'DEAL_STAGE' : `DEAL_STAGE_${cat}`;
    async function loadStages(ent){
      if(loadedEnts.has(ent)) return;
      loadedEnts.add(ent);
      const statuses = await listAll(STAT,'crm.status.list',{ filter:{ ENTITY_ID: ent } });
      for(const s of statuses) stageName[`${s.ENTITY_ID}|${s.STATUS_ID}`] = s.NAME;
    }
    for(const ent of STAGE_ENTITIES) await loadStages(ent);
    const resolveStage = (cat, stage) => stageName[`${entityOf(cat)}|${stage}`] || stage;

    // 2a) pre-flight: cheap count first (1 call per stage) so a too-wide range
    //     fails fast with a clear message instead of timing out mid-pagination.
    const MAX_MOVES = 2000;
    let totalMoves = 0;
    for(const t of rep.targets){
      const j = await call(DEAL,'crm.stagehistory.list',{
        entityTypeId: 2,
        filter: { CATEGORY_ID: t.categoryId, STAGE_ID: t.stageId, '>=CREATED_TIME': from, '<=CREATED_TIME': to },
        start: 0
      });
      totalMoves += parseInt(j.total || 0, 10);
    }
    if(totalMoves > MAX_MOVES){
      return res.status(400).json({
        error: `თარიღის დიაპაზონი ძალიან ფართოა (${totalMoves} გადასვლა). შეამცირე დიაპაზონი (მაქსიმუმი ${MAX_MOVES}).`
      });
    }

    // 2b) who entered the target stage in range (date filter basis)
    const moved = {};
    for(const t of rep.targets){
      const items = await stageHistAll({
        entityTypeId: 2,
        filter: { CATEGORY_ID: t.categoryId, STAGE_ID: t.stageId, '>=CREATED_TIME': from, '<=CREATED_TIME': to },
        order: { CREATED_TIME: 'ASC' }
      });
      for(const it of items){
        const id = String(it.OWNER_ID), ct = it.CREATED_TIME;
        if(moved[id]){ moved[id].hits++; if(new Date(ct) > new Date(moved[id].movedTime)) moved[id].movedTime = ct; }
        else moved[id] = { type:t.type, pipeline:t.pipeline, categoryId:t.categoryId, movedTime:ct, hits:1 };
      }
    }
    const dealIds = Object.keys(moved);
    if(dealIds.length === 0){
      return res.status(200).json({ report:reportKey, label:rep.label, from, to, count:0, hot:0, sale:0, rows:[] });
    }
    // guard: too wide a range would exceed the function time limit -> fail with a clear JSON error
    const MAX_DEALS = 1500;
    if(dealIds.length > MAX_DEALS){
      return res.status(400).json({
        error: `ძალიან ბევრი ლიდი (${dealIds.length}) — შეამცირე თარიღის დიაპაზონი (მაქსიმუმი ${MAX_DEALS}).`
      });
    }

    // 3) deal details (current stage / client refs / create date) — batched
    const deals = {};
    for(const grp of chunk(chunk(dealIds,50), 50)){ // grp = up to 50 chunks per batch call
      const cmds = {};
      grp.forEach((ch, i) => {
        const p = {};
        ch.forEach((id,j) => p[`filter[ID][${j}]`] = id);
        DEAL_SELECT.forEach((s,j) => p[`select[${j}]`] = s);
        p['order[ID]'] = 'ASC';
        cmds['d'+i] = 'crm.deal.list?' + qs(p);
      });
      const br = await batch(DEAL, cmds);
      grp.forEach((ch, i) => (br.result['d'+i] || []).forEach(d => deals[String(d.ID)] = d));
    }

    // 4) clients (contacts + companies) — batched
    const contactIds = [...new Set(Object.values(deals).filter(d => d.CONTACT_ID && String(d.CONTACT_ID)!=='0').map(d => String(d.CONTACT_ID)))];
    const companyIds = [...new Set(Object.values(deals).filter(d => d.COMPANY_ID && String(d.COMPANY_ID)!=='0').map(d => String(d.COMPANY_ID)))];
    const contacts = {}, companies = {};

    if(contactIds.length){
      const cc = chunk(contactIds,50), cmds={};
      cc.forEach((ch,i)=>{ const p={}; ch.forEach((id,j)=>p[`filter[ID][${j}]`]=id); ['ID','NAME','LAST_NAME','SECOND_NAME','PHONE'].forEach((s,j)=>p[`select[${j}]`]=s); cmds['c'+i]='crm.contact.list?'+qs(p); });
      const br = await batch(DEAL, cmds);
      cc.forEach((ch,i)=>(br.result['c'+i]||[]).forEach(c=>{
        const name=[c.NAME,c.SECOND_NAME,c.LAST_NAME].filter(x=>x&&String(x).trim()).join(' ').trim();
        const phone=(c.PHONE||[]).map(p=>p.VALUE).filter(Boolean).join(', ');
        contacts[String(c.ID)]={name,phone};
      }));
    }
    if(companyIds.length){
      const cc = chunk(companyIds,50), cmds={};
      cc.forEach((ch,i)=>{ const p={}; ch.forEach((id,j)=>p[`filter[ID][${j}]`]=id); ['ID','TITLE'].forEach((s,j)=>p[`select[${j}]`]=s); cmds['m'+i]='crm.company.list?'+qs(p); });
      const br = await batch(DEAL, cmds);
      cc.forEach((ch,i)=>(br.result['m'+i]||[]).forEach(c=>companies[String(c.ID)]=c.TITLE));
    }

    // 5) last timeline comment per deal — batched, in parallel
    const lastComment = {};
    await pool(chunk(Object.keys(deals),50), 4, async (ch) => {
      const cmds = {};
      ch.forEach(id => cmds['k'+id] = 'crm.timeline.comment.list?' + qs({
        'filter[ENTITY_TYPE]':'deal','filter[ENTITY_ID]':id,'order[CREATED]':'DESC','select[0]':'COMMENT','select[1]':'CREATED'
      }));
      const br = await batch(TL, cmds);
      ch.forEach(id => {
        const arr = br.result['k'+id];
        if(arr && arr.length){
          const c = arr[0];
          const txt = String(c.COMMENT||'').replace(/<[^>]+>/g,' ').replace(/\s+/g,' ').trim();
          lastComment[id] = { text:txt, when:c.CREATED };
        }
      });
    });

    // 5b) deals may now sit in other pipelines — load those stage names too
    for(const ent of new Set(Object.values(deals).map(d => entityOf(d.CATEGORY_ID)))) await loadStages(ent);

    // 6) build rows.
    //    keepOnlyCurrent -> keep only deals STILL in the stage.
    //    otherwise       -> keep everyone who ENTERED the stage in range, wherever they are now.
    const TARGET_STAGES = new Set(rep.currentStages);
    const rows = Object.keys(deals)
      .filter(id => !rep.keepOnlyCurrent || TARGET_STAGES.has(String(deals[id].STAGE_ID)))
      .sort((a,b)=>(+a)-(+b)).map(id => {
      const d = deals[id];
      let client='', phone='';
      if(d.CONTACT_ID && contacts[String(d.CONTACT_ID)]){ client=contacts[String(d.CONTACT_ID)].name; phone=contacts[String(d.CONTACT_ID)].phone; }
      else if(d.COMPANY_ID && companies[String(d.COMPANY_ID)]){ client=companies[String(d.COMPANY_ID)]; }
      if(!client) client = d.TITLE || '';
      const cm = lastComment[id];
      return {
        dealId:id,
        type: moved[id].type,
        client, phone,
        fbName: d.UF_CRM_1700569256804 || '',
        pipeline: moved[id].pipeline,
        created: d.DATE_CREATE || '',
        movedTime: moved[id].movedTime,
        currentStage: resolveStage(String(d.CATEGORY_ID), d.STAGE_ID),
        lastComment: cm ? cm.text : '',
        commentDate: cm ? cm.when : ''
      };
    });

    const hot  = rows.filter(r=>r.type==='Hot').length;
    const sale = rows.filter(r=>r.type==='Sale').length;
    res.setHeader('cache-control','no-store');
    return res.status(200).json({ report:reportKey, label:rep.label, from, to, count:rows.length, hot, sale, rows });
  }catch(e){
    return res.status(500).json({ error: String(e && e.message || e) });
  }
};
