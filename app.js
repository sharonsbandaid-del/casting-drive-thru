/* Casting Drive-Thru 演員預約平台｜大廣 × 三根木
   資料存在 Supabase；所有規則（同場合併、6 小時上限、KOC、7 人次一期、權限）也都寫在資料庫函式裡。 */
(function(){

const QUOTA = 7;
const COLORS = ["#D7261E","#141414","#E8A800","#A81B15","#2b2827","#C98A00","#B83A2F","#4a4544"];
const today = new Date();
const pad = n => String(n).padStart(2,"0");
const ym = d => d.getFullYear()+"-"+pad(d.getMonth()+1);

const PRODUCTS = {"EX":"毛毛組","RJ":"花花組","DHA":"啾啾組","SAB":"毛毛組","MACA":"啾啾組","FANCL":"花花組","西松屋":"啾啾組","YT":"泡泡組","HK":"泡泡組","其他":"CRM組"};
const PORDER = Object.keys(PRODUCTS);
let actors=[], bookings=[], cycleInv={}, profile=null, profiles=[], isAdmin=false;
const nextShootNo = yymm => Math.max(0,...bookings.filter(x=>x.shoot&&x.shoot.startsWith("SH-"+yymm)).map(x=>Number(x.shoot.split("-")[2])||0))+1;
const save = ()=>{};  /* 正式版：資料都存在 Supabase，不再存本機 */

let role = "agency", tab = "pool";
const $ = id => document.getElementById(id);
const esc = s => String(s??"").replace(/[&<>"]/g,c=>({"&":"&amp;","<":"&lt;",">":"&gt;",'"':"&quot;"}[c]));
const parseBirth = b => { const t=String(b||"").trim(); if(!t) return null;
  let m=t.match(/^(\d{4})(?:\s*[-\/.年]\s*(\d{1,2}))?/); if(m) return {y:+m[1], m:m[2]?+m[2]:null};
  m=t.match(/^(?:民國)?\s*(\d{2,3})(?:\s*[-\/.年]\s*(\d{1,2}))?/); if(m) return {y:+m[1]+1911, m:m[2]?+m[2]:null};
  return null; };
const age = b => { const p=parseBirth(b); if(!p||p.y<1900||p.y>today.getFullYear()) return "—"; let a=today.getFullYear()-p.y; if(p.m&&today.getMonth()+1<p.m) a--; return a; };
const actorById = id => actors.find(a=>a.id===id);
const counts = b => b.status!=="已取消" && b.status!=="已刪除";
const cycBk = () => bookings.filter(b=>b.cycle===cyc);
/* 拍攝人次：同一演員＋同一天＝1 人次，可包含多支素材 */
function shootsIn(list){
  const m=new Map();
  list.forEach(b=>{ const k=b.shoot; if(!m.has(k)) m.set(k,{key:k,id:b.shoot,actor:b.actor,date:b.date,items:[]}); m.get(k).items.push(b); });
  return [...m.values()].map(sh=>{ const live=sh.items.filter(counts); sh.live=live; sh.active=live.length>0;
    sh.date=(live[0]||sh.items[0]).date; sh.cands=[...new Set((live.length?live:sh.items).flatMap(b=>b.cands||[b.date]))].sort();
    sh.status = !sh.active ? "已取消" : live.some(b=>b.status==="待確認") ? "待確認" : live.every(b=>b.status==="已拍攝") ? "已拍攝" : "已確認";
    sh.locked = sh.status==="已確認"||sh.status==="已拍攝";
    sh.hours = live.reduce((t,b)=>t+Number(b.hours||0),0); sh.fee = (live[0]||sh.items[0]).fee; sh.ot = (live[0]||sh.items[0]).ot; return sh; }).sort((a,b)=>a.date.localeCompare(b.date)||a.id.localeCompare(b.id));
}
const CAP = 6;
/* KOC 規則：同一位演員只能幫一個商品拍 KOC（該 KOC 合約有效期間內）；情境可跨商品 */
function kocLock(actor, product, role, date, exclude){
  if(role!=="KOC") return null;
  return bookings.filter(b=>b.actor===actor && b.role==="KOC" && counts(b) && b.product!==product && b.id!==exclude && kocEnd(b)>=date)
    .sort((x,y)=>x.date.localeCompare(y.date))[0] || null;
}
const kocEnd = b => endOf(b.start||b.date, b.length);
const kocOf = actor => { const l=bookings.filter(b=>b.actor===actor&&b.role==="KOC"&&counts(b)&&kocEnd(b)>=fmt(today)); return l.length? {product:l[0].product, end:l.map(kocEnd).sort().pop()} : null; };
const activeShoots = (prefix) => shootsIn(bookings.filter(b=>b.date.startsWith(prefix))).filter(s=>s.active);
/* 請款期數：每 7 個拍攝人次為一期，依預約順序排入第一個未滿、未請款的期數 */
const shootCycle = sh => (sh.live[0]||sh.items[0]).cycle;
const cycleShoots = n => shootsIn(bookings.filter(b=>b.cycle===n)).filter(s=>s.active);
const isInvoiced = n => !!(cycleInv||{})[n];
function openCycle(){ for(let n=1;;n++){ if(!isInvoiced(n) && cycleShoots(n).length<QUOTA) return n; } }
const maxCycle = () => Math.max(openCycle(), ...bookings.map(b=>b.cycle||1));
let cyc = 1;
const statusCls = {"待確認":"s-warn","已確認":"s-info","已拍攝":"s-ok","已取消":"s-mute","已刪除":"s-bad","可接案":"s-ok","暫停接案":"s-bad"};
const toD = s => { const [y,m,d]=s.split("-").map(Number); return new Date(y,m-1,d); };
const fmt = d => d.getFullYear()+"-"+pad(d.getMonth()+1)+"-"+pad(d.getDate());
const slash = s => s ? s.replace(/-/g,"/") : "";
/* 工作天（週末與國定假日不算）：候選日最早 10 個工作天後；鎖定日＝D1，拍攝日需在 D10 以後才來得及辦保險 */
let offdays = new Set();
const isWorkday = s => { const w=toD(s).getDay(); return w!==0 && w!==6 && !offdays.has(s); };
function addWorkdays(s,n){ const d=toD(s); let k=0; while(k<n){ d.setDate(d.getDate()+1); if(isWorkday(fmt(d))) k++; } return fmt(d); }
function subWorkdays(s,n){ const d=toD(s); let k=0; while(k<n){ d.setDate(d.getDate()-1); if(isWorkday(fmt(d))) k++; } return fmt(d); }
function workdaysBetween(a,b){ if(b<=a) return 0; const d=toD(a); let n=0; while(fmt(d)<b){ d.setDate(d.getDate()+1); if(isWorkday(fmt(d))) n++; } return n; }
const MIN_WD = 10, LOCK_WD = 9;
const minShootDate = () => addWorkdays(fmt(today), MIN_WD);
const lockOK = d => d >= addWorkdays(fmt(today), LOCK_WD);
const lockBy = d => subWorkdays(d, LOCK_WD);
const shortD = s => s ? s.slice(5).replace("-","/") : "";
const shortW = s => s ? shortD(s)+"（"+"日一二三四五六"[toD(s).getDay()]+"）" : "";
const stLabel = s => s==="待確認" ? "待敲定" : s;
const lockedShootOn = (actor,date,exclude) => shootsIn(bookings.filter(b=>b.actor===actor&&b.date===date&&(b.status==="已確認"||b.status==="已拍攝")&&b.shoot!==exclude)).find(sh=>sh.active)||null;
const pendingGroup = (actor,cands,excludeIds) => shootsIn(bookings.filter(b=>b.actor===actor&&b.status==="待確認"&&b.cands.join()===cands.join()&&!(excludeIds||[]).includes(b.id))).find(sh=>sh.active)||null;
const shootById = id => shootsIn(bookings.filter(b=>b.shoot===id)).find(Boolean)||null;
function endOf(start,months){ if(!start) return ""; const d=toD(start); const e=new Date(d.getFullYear(),d.getMonth()+Number(months),d.getDate()); e.setDate(e.getDate()-1); return fmt(e); }
function renewOf(start,months,days){ const e=endOf(start,months); if(!e) return ""; const d=toD(e); d.setDate(d.getDate()-Number(days)); return fmt(d); }
const lenLabel = n => Number(n)%12===0 ? (Number(n)/12)+"年" : n+"個月";
const typeOf = (title,actorId,date) => { const a=actorById(actorId); return [title, a?a.name:"", date?date.slice(0,4):""].filter(Boolean).join("＋"); };
const termsLine = t => [lenLabel(t.length), (t.web||[]).join("/"), "二次利用 "+t.second, "AI "+t.ai, "綁競品 成分 "+t.ci+"・功効 "+t.ce].join("・");
const money = n => n===""||n==null ? "" : "NT$"+Number(n).toLocaleString("en-US");

function renderQuota(){
  const used = cycleShoots(cyc); const inv = (cycleInv||{})[cyc];
  $("m-label").textContent = "第 "+cyc+" 期";
  $("m-prev").disabled = cyc<=1; $("m-next").disabled = cyc>=maxCycle();
  $("q-used").textContent = used.length;
  const left = QUOTA-used.length, allShot = used.length===QUOTA && used.every(sh=>sh.status==="已拍攝");
  $("q-left").textContent = inv ? "（"+slash(inv)+" 已請款）" : left>0 ? "再 "+left+" 點集滿" : allShot ? "集滿！可兌換請款" : "已排滿，待全數拍攝";
  $("q-left").className = "sub "+(inv?"s-ok":left===0?"s-warn":"");
  $("slots").innerHTML = Array.from({length:QUOTA},(_,i)=>{
    const sh = used[i]; if(!sh) return '<div class="slot"><span class="n">'+(i+1)+'</span></div>';
    const a = actorById(sh.actor); const n=sh.live.length;
    const repeat = used.filter(x=>x.actor===sh.actor).length>1; /* 同一期同一演員出動多天，各算 1 人次 */
    const tip = esc(sh.id+" "+sh.date+" "+(a?a.name:"")+"："+sh.live.map(b=>b.product+" "+b.title).join("、")+"・"+sh.hours+"/"+CAP+"h・"+sh.status);
    const rp = repeat?'<b class="rep">第'+(used.filter(x=>x.actor===sh.actor).indexOf(sh)+1)+'次</b>':'';
    if(sh.status==="已拍攝") return '<div class="slot used done" title="'+tip+'"><span class="st">已拍</span><span class="sd">'+esc(sh.date.slice(5).replace("-","/"))+'</span><span class="sn">'+esc(a?a.name:"")+'</span>'+rp+'</div>';
    return '<div class="slot used" title="'+esc(sh.id+" "+sh.date+" "+(a?a.name:"")+"："+sh.live.map(b=>b.product+" "+b.title).join("、")+"・"+sh.hours+"/"+CAP+"h・"+sh.status)+'"><span class="d">'+(sh.status==="待確認"?'待敲定':esc(sh.date.slice(5).replace("-","/")))+'</span><span class="nm">'+esc(a?a.name:"")+'</span>'+(n>1?'<b class="x">×'+n+'支</b>':'')+(repeat?'<b class="rep">第'+(used.filter(x=>x.actor===sh.actor).indexOf(sh)+1)+'次</b>':'')+'</div>';
  }).join("");
  let act='';
  if(role==="casting"){
    if(inv) act='<span class="sub">本期已請款，相關場次已鎖定</span>'+(isAdmin?'<button class="btn sm ghost" id="cyc-uninv">撤銷請款（管理者）</button>':'');
    else if(allShot) act='<label class="sub" for="cyc-date">發票日期</label><input type="date" id="cyc-date" value="'+fmt(today)+'"><button class="btn sm primary" id="cyc-inv">本期請款</button>';
    else if(left===0) act='<span class="sub">7 人次已排滿，全部標記已拍攝後即可請款</span>';
  } else if(left===0 && !inv) act='<span class="sub">本期已排滿，新的預約會自動排入第 '+openCycle()+' 期</span>';
  $("q-act").innerHTML = act; $("q-act").classList.toggle("hidden",!act);
  if($("cyc-inv")) $("cyc-inv").onclick=async()=>{ const d=$("cyc-date").value; if(!d) return toast("請先填發票日期",null);
    if(await call("invoice_cycle",{p_no:cyc,p_date:d})) toast("第 "+cyc+" 期已請款（發票 "+slash(d)+"）",null); };
  if($("cyc-uninv")) $("cyc-uninv").onclick=async()=>{ if(await call("uninvoice_cycle",{p_no:cyc})) toast("已撤銷第 "+cyc+" 期請款",null); };
}
function renderPool(){
  const q=$("f-q").value.trim(), g=$("f-gender").value, ag=$("f-age").value, st=$("f-status").value;
  const list = actors.filter(a=>{
    if(a.archived) return false;
    if(q && !(a.name+a.id+a.tags.join()).includes(q)) return false;
    if(g && a.gender!==g) return false;
    if(st && a.status!==st) return false;
    if(ag){const [lo,hi]=ag.split("-").map(Number); const x=age(a.birth); if(x<lo||x>hi) return false;}
    return true;
  });
  const ms = cycleShoots(cyc);
  const usedThisMonth = id => { const l=ms.filter(s=>s.actor===id); return l.length+" 次"+(l.length?"（"+l.reduce((t,s)=>t+s.live.length,0)+" 支素材）":""); };
  $("pool").innerHTML = list.map(a=>{
    const c = COLORS[actors.indexOf(a)%COLORS.length]; const n = usedThisMonth(a.id);
    const active = bookings.filter(b=>b.actor===a.id&&counts(b)&&endOf(b.start,b.length)>=fmt(today)).map(b=>b.product);
    const hist = actorHistory(a.id);
    const koc = kocOf(a.id);
    return '<article class="card v2 '+(list.indexOf(a)%2?'red':'dark')+(a.status==="暫停接案"?" off":"")+'">'+
      '<div class="c-head" data-view-actor="'+a.id+'" role="button" tabindex="0" title="查看演員細節"><span class="c-no">'+esc(a.id.replace(/\D/g,"").padStart(3,"0").slice(-3))+'</span><span class="c-name">'+esc(a.name)+'</span></div>'+
      '<div class="ph" data-view-actor="'+a.id+'" role="button" tabindex="0" aria-label="查看 '+esc(a.name)+' 的細節"'+(a.photo?' style="background-image:url(&quot;'+a.photo+'&quot;)"':'')+'>'+(a.photo?'':'<b>'+esc(a.name.slice(-1))+'</b>')+'<span class="st-pill'+(a.status==="暫停接案"?" off":"")+'">'+esc(a.status)+'</span></div>'+
      '<div class="c-meta">'+esc([a.gender, a.birth?age(a.birth)+' 歲':'', a.height!==''&&a.height!=null?a.height+' cm':'', a.size?'衣 '+a.size:''].filter(Boolean).join('・'))+'</div>'+
      '<div class="chips c-tags">'+a.tags.map(t=>'<span class="chip">'+esc(t)+'</span>').join("")+'</div>'+
      '<div class="c-info">可拍攝日：'+esc(a.time||"—")+'<br>拍攝歷：'+esc(hist.line||"—")+(koc?'<br><span class="chip koc">KOC</span> 已綁 '+esc(koc.product)+'（至 '+esc(slash(koc.end))+'）':'')+(a.note?'<br>備註：'+esc(a.note):'')+((a.videos||[]).filter(v=>/^https?:\/\//.test(v)).length?'<br><a class="c-video" href="'+esc(a.videos.find(v=>/^https?:\/\//.test(v)))+'" target="_blank" rel="noopener">▶ 看影片'+(a.videos.length>1?'（'+a.videos.length+' 支）':'')+'</a>':'')+'</div>'+
      '<div class="c-act"><button class="btn sm c-view" data-view-actor="'+a.id+'">檢視</button>'+(role==="casting" ? '<button class="btn sm c-btn" data-edit="'+a.id+'">編輯</button>' :
        '<button class="btn sm c-btn" data-book="'+a.id+'"'+(a.status==="暫停接案"?" disabled":"")+'>'+(a.status==="暫停接案"?"暫停供應":"點這位")+'</button>')+
      '</div></article>';
  }).join("") || '<p class="note">沒有符合條件的演員。</p>';
  $("pool-count").textContent = "共 "+actors.length+" 位演員，可接案 "+actors.filter(a=>a.status==="可接案").length+" 位。顯示 "+list.length+" 位。";
}
const CNUM = ["零","一","二","三","四","五","六","七","八","九","十"];
const cn = n => n<=10 ? CNUM[n] : (n<20 ? "十"+(n%10?CNUM[n%10]:"") : String(n));
function actorHistory(id){
  const l = bookings.filter(b=>b.actor===id && counts(b));
  const by = {}; l.forEach(b=>{ (by[b.cycle]=by[b.cycle]||[]).push(b); });
  const line = Object.keys(by).sort((x,y)=>x-y).map(c=>"第"+cn(Number(c))+"期"+by[c].length+"支("+[...new Set(by[c].map(b=>b.product))].join("、")+")").join("/");
  return { products:[...new Set(l.map(b=>b.product))].join("、"), line };
}
function renderSelects(){
  const cur=$("b-actor").value;
  $("b-actor").innerHTML = actors.filter(a=>a.status==="可接案"&&!a.archived).map(a=>'<option value="'+a.id+'">'+esc(a.id+"　"+a.name+"（"+a.gender+"・"+age(a.birth)+"歲）")+'</option>').join("");
  if(cur) $("b-actor").value=cur;
  if(!$("b-product").options.length) $("b-product").innerHTML = PORDER.map(p=>'<option>'+p+'</option>').join("");
}
function hoursBar(h){ const pct=Math.min(100,h/CAP*100); const over=h>CAP;
  return '<span class="hbar'+(over?' over':'')+'"><span style="width:'+pct+'%"></span></span><span class="hnum'+(over?' s-bad':'')+'">'+h+' / '+CAP+' 小時'+(over?'（超時 '+(h-CAP)+'）':'')+'</span>'; }
function histText(b){ return (b.log||[]).map(l=>l.at+" "+l.who+"："+l.from+" → "+l.to).join("\n") || "尚無變更紀錄"; }
function stamp(){ const d=new Date(); return (d.getMonth()+1)+"/"+d.getDate()+" "+pad(d.getHours())+":"+pad(d.getMinutes()); }
async function setShootStatus(shootId,to,from){
  if(await call("set_shoot_status",{p_shoot:shootId,p_to:to}))
    toast("已改為「"+to+"」", from ? async()=>{ if(await call("set_shoot_status",{p_shoot:shootId,p_to:from})) toast("已復原",null); } : null);
}
async function setCancelled(id,cancel){
  const b0=bookings.find(x=>x.id===id); const wasLocked = cancel && b0 && b0.status==="已確認" ? {...b0} : null;
  const ok = await call("set_booking_cancelled",{p_id:id,p_cancel:cancel});
  if(ok && wasLocked && role!=="casting") showCancelNotice(wasLocked);
  if(ok)
    toast(cancel?"已取消這支素材":"已恢復這支素材", async()=>{ if(await call("set_booking_cancelled",{p_id:id,p_cancel:!cancel})) toast("已復原",null); });
}
let toastTimer=null;
function toast(text, undo){
  const t=$("toast"); t.innerHTML='<span>'+esc(text)+'</span>'+(undo?'<button class="btn sm" id="toast-undo">復原</button>':'');
  t.classList.remove("hidden"); clearTimeout(toastTimer); toastTimer=setTimeout(()=>t.classList.add("hidden"), undo?10000:3000);
  if(undo) $("toast-undo").onclick=()=>{ clearTimeout(toastTimer); t.classList.add("hidden"); undo(); };
}
function oaCell(b){
  const can = role!=="casting" && counts(b);
  const inner = b.start ? esc(slash(b.start))+'<div class="meta">至 '+esc(slash(endOf(b.start,b.length)))+'</div>' : '<span class="oa-empty">'+(can?'點擊設定':'')+'</span>';
  return can ? '<button type="button" class="oa-cell" data-oa="'+b.id+'" title="點擊設定 OA 日">'+inner+'</button>' : inner;
}
function renderDeleted(list){
  $("l-hint").textContent="已刪除的預約不會出現在集點卡、預約總表與契約一覽，只保留紀錄";
  $("rows").innerHTML = list.sort((x,y)=>x.id.localeCompare(y.id)).map(b=>{ const a=actorById(b.actor)||{name:b.actor};
    return '<tr class="item gone-del"><td class="mno">'+esc(bkName(b))+'</td><td class="num">'+esc(b.date)+'</td><td>'+esc(a.name)+'<div class="meta">'+esc(b.actor)+'</div></td><td>'+esc(b.product)+'</td><td>'+esc(b.role)+'</td><td colspan="4"><strong>'+esc(b.title)+'</strong><div class="del-reason">刪除原因：'+esc(b.delReason||"—")+'</div><div class="meta">'+esc(b.delBy||"")+'・'+esc(b.delAt||"")+'</div></td><td><span class="pill s-bad">已刪除</span></td><td><button class="btn sm ghost" data-view="'+b.id+'">檢視</button></td></tr>'; }).join("")
    || '<tr><td colspan="11" class="note">沒有已刪除的預約。</td></tr>';
}
/* 人次標示：第 N 期・第 k 人次（依集點卡順序） */
function shootLabel(sh){
  if(!sh.active) return "已取消";
  const c=shootCycle(sh); const k=cycleShoots(c).findIndex(x=>x.id===sh.id)+1;
  return "第"+c+"期・第"+k+"人次";
}
const bkName = b => b.mno || b.id;   /* 對使用者顯示素材管理編號；沒填才用系統編號 */
function renderRows(){
  const st=$("l-status").value;
  const srcAll = ($("l-scope").value==="all" ? bookings : cycBk());
  if(st==="已刪除"){ renderDeleted(srcAll.filter(b=>b.status==="已刪除")); return; }
  const shoots = shootsIn(srcAll.filter(b=>b.status!=="已刪除")).filter(sh=>!st||sh.status===st||sh.items.some(b=>b.status===st));
  $("l-hint").textContent = role==="casting" ? "Casting 身分：從候選日中鎖定拍攝日、標記已拍攝" : "大廣身分：從候選日鎖定日期後，可寄通告單給 Mia；同場素材全部取消才會釋出人次";
  $("rows").innerHTML = shoots.map(sh=>{
    const a = actorById(sh.actor); let act="";
    const canLock = sh.active && sh.status==="待確認";
    const btnLock = canLock ? '<button class="btn sm primary" data-lock="'+sh.id+'">🔒 鎖定日期</button>' : '';
    if(role==="casting"){
      const future = sh.date > fmt(today);
      const invoiced = isInvoiced(shootCycle(sh));
      if(canLock) act=btnLock;
      else if(sh.status==="已確認") act='<div class="acts"><button class="btn sm" data-shoot="'+sh.id+'" data-from="'+sh.status+'" data-to="已拍攝"'+(future?' disabled title="拍攝日當天之後才能標記"':'')+'>'+(future?'拍攝日後可標記':'標記已拍攝')+'</button><button class="btn sm ghost" data-shoot="'+sh.id+'" data-from="'+sh.status+'" data-to="待確認">解除鎖定</button></div>';
      else if(sh.status==="已拍攝") act='<button class="btn sm ghost" data-shoot="'+sh.id+'" data-from="'+sh.status+'" data-to="已確認"'+(invoiced?' disabled title="本期已請款，需先撤銷請款"':'')+'>'+(invoiced?'已請款・鎖定':'撤銷已拍攝')+'</button>';
    } else if(sh.status==="已拍攝"){ act='<div class="acts"><button class="btn sm ghost" data-notice="'+sh.id+'">📋 通告單</button></div><span class="meta">誤標請通知三根木撤銷</span>'; }
    else if(canLock) act='<div class="acts">'+btnLock+'<button class="btn sm" data-notice="'+sh.id+'" title="敲通告：寄給阿森、複製文字或存成圖片">📋 通告單</button><button class="btn sm ghost" data-resched="'+sh.id+'">改期</button></div>';
    else if(sh.status==="已確認") act='<div class="acts"><button class="btn sm" data-notice="'+sh.id+'">📋 通告單</button><button class="btn sm ghost" data-resched="'+sh.id+'">改期</button></div>';
    const dateCell = !sh.active ? esc(sh.date)
      : sh.locked ? '<span class="lockd">🔒 '+esc(slash(sh.date))+'</span>'+((sh.live[0]||{}).lockedBy?'<div class="meta">'+esc(sh.live[0].lockedBy)+' 鎖定</div>':'')
      : '<div class="cand-list">'+sh.cands.map(d=>'<span class="cand'+(lockOK(d)?'':' late')+'" title="'+(lockOK(d)?'':'來不及辦保險')+'">'+esc(shortW(d))+'</span>').join("")+'</div>'
        + (sh.cands.some(lockOK) ? '<div class="meta">請於 '+esc(shortD(lockBy(sh.cands.find(lockOK))))+' 前鎖定</div>' : '<div class="meta s-bad">候選日都來不及辦保險</div>');
    const n=sh.live.length;
    const head='<tr class="shoot"><td class="num"><strong>'+esc(shootLabel(sh))+'</strong></td><td class="num">'+dateCell+'</td><td><strong>'+esc(a?a.name:sh.actor)+'</strong><div class="meta">'+esc(sh.actor)+'</div></td>'+
      '<td colspan="6">'+(sh.active ? '算 <strong>1 人次</strong>・共 '+n+' 支素材'+(n>1?'<span class="chip merge">合併拍攝</span>':'')+hoursBar(sh.hours) : '<span class="s-mute">已全部取消，不計人次</span>')+'</td>'+
      '<td><span class="pill '+statusCls[sh.status]+'">'+esc(stLabel(sh.status))+'</span></td><td>'+act+'</td></tr>';
    const items=sh.items.map(b=>{
      const view = '<button class="btn sm ghost" data-view="'+b.id+'">檢視</button>'+(role!=="casting"&&counts(b)?'<button class="btn sm" data-edit-bk="'+b.id+'">編輯</button>':'');
      const c = view + (role==="casting" ? '' : (b.status==="待確認"||b.status==="已確認") ? '<button class="btn sm" data-act="已取消" data-id="'+b.id+'">取消此素材</button>'
        : b.status==="已取消" ? '<button class="btn sm ghost" data-act="待確認" data-id="'+b.id+'">恢復此素材</button>' : '')
        + (role!=="casting" && b.status!=="已拍攝" && !isInvoiced(b.cycle) ? '<button class="btn sm danger" data-del="'+b.id+'">刪除</button>' : '');
      return '<tr class="item'+(counts(b)?'':' gone')+'"><td class="mno">'+(b.mno?esc(b.mno):'<span class="meta">未填</span>')+'</td><td></td><td></td><td><strong>'+esc(b.product)+'</strong><div class="meta">'+esc(b.team)+'</div></td><td>'+(b.role==="KOC"?'<span class="chip koc">KOC</span>':esc(b.role))+'</td><td>'+esc(b.title)+(b.note?'<div class="meta">'+esc(b.note)+'</div>':'')+'</td><td class="num">'+oaCell(b)+'</td><td class="num">'+esc(b.hours)+' 小時</td><td>'+esc(b.by)+'</td><td><span class="pill '+statusCls[b.status]+'" title="'+esc(histText(b))+'">'+esc(stLabel(b.status))+'</span>'+((b.log||[]).length?'<div class="meta">已變更 '+b.log.length+' 次</div>':'')+'</td><td>'+c+'</td></tr>';
    }).join("");
    return head+items;
  }).join("") || '<tr><td colspan="11" class="note">第 '+cyc+' 期尚無預約。</td></tr>';
}

/* 契約者一覽表 */
const XCOLS = [["商品",8],["演員編號",10],["姓名",10],["照片",8],["拍攝需求",12],["素材管理編號",14],["素材篇名",18],["拍攝日期",12],["本素材合約開始日\n(OA日)",14],["合約截止日",12],["肖像權期間",10],["合約更新提醒日",14],["WEB平台",20],["二次利用",8],["AI修圖/\n影片生成",10],["綁競品\n(成分)",8],["綁競品\n(功効)",8],["保密合約",8],["拍攝費",12],["腳本",24],["負責組別",10],["登記人",10],["備考",30,1]];
const XHEAD = XCOLS.map(c=>c[0]);
const X_FEE = XHEAD.indexOf("拍攝費"), X_PHOTO = XHEAD.indexOf("照片");
const invOf = b => b.inv || (cycleInv||{})[b.cycle] || "";
function exportRows(){
  const scope=$("x-scope").value, sort=$("x-sort").value, td=fmt(today);
  const feeOwner={}; [...bookings].filter(counts).sort((x,y)=>x.date.localeCompare(y.date)||x.id.localeCompare(y.id)).forEach(b=>{ if(!feeOwner[b.shoot]) feeOwner[b.shoot]=b.id; });
  const isExp = b => { const e=endOf(b.start,b.length); return !!e && e<td; };
  const endKey = b => endOf(b.start,b.length) || "9999";
  return bookings.filter(b=>counts(b)&&(scope==="all"||(scope==="expired"&&isExp(b))||(scope==="active"&&!isExp(b))||(scope.startsWith("c")&&b.cycle===Number(scope.slice(1)))))
    .sort((a,b)=> sort==="cycle" ? (a.cycle-b.cycle||a.date.localeCompare(b.date)||a.id.localeCompare(b.id))
      : sort==="start" ? ((a.start||"9999").localeCompare(b.start||"9999")||a.date.localeCompare(b.date))
      : sort==="end" ? (endKey(a).localeCompare(endKey(b))||a.date.localeCompare(b.date))
      : (PORDER.indexOf(a.product)-PORDER.indexOf(b.product)||a.date.localeCompare(b.date)))
    .map(b=>{
      const a=actorById(b.actor)||{name:b.actor};
      const sib=bookings.filter(x=>x.shoot===b.shoot&&counts(x)); const hrs=sib.reduce((t,x)=>t+Number(x.hours||0),0);
      const auto=["第"+b.cycle+"期"]; if(sib.length>1) auto.push("同日同場（共"+sib.length+"支，算1人次，"+hrs+"h）"); if(hrs>CAP) auto.push("超時 "+(hrs-CAP)+"h × "+money(b.ot));
      const extra=[...auto]; if(b.note) extra.push(b.note);
      const end=endOf(b.start,b.length), renewDate=renewOf(b.start,b.length,b.renew);
      return {b, auto: auto.join("；"), feeHere: feeOwner[b.shoot]===b.id, due: renewDate && renewDate<=td && end>=td, expired: !!end && end<td,
        cells:[b.product,b.actor,a.name,b.actor,b.role,b.mno||"",b.title,slash(b.date),b.start?slash(b.start):"OA未定",slash(end),lenLabel(b.length),renewDate?slash(renewDate)+"（"+b.renew+"天前）":"",(b.web||[]).join("、"),b.second,b.ai,b.ci,b.ce,b.nda||"",(feeOwner[b.shoot]===b.id?money(b.fee):"同場已計"),b.script||"",b.team||"",b.by||"",extra.join("；")]};
    });
}
function renderXScope(){
  const sel=$("x-scope"), cur=sel.value||"all", mc=maxCycle();
  let o='<option value="all">全部合約（不含取消）</option><option value="expired">合約已到期</option><option value="active">合約未到期</option><optgroup label="期數">';
  for(let c=1;c<=mc;c++) o+='<option value="c'+c+'">第 '+c+' 期'+(c===cyc?'（目前）':'')+'</option>';
  sel.innerHTML=o+'</optgroup>'; sel.value=[...sel.options].some(x=>x.value===cur)?cur:"all";
}
function renderExport(){
  renderXScope();
  const rows=exportRows(); const canEdit = role!=="casting"; const byProd = $("x-sort").value==="product";
  $("x-head").innerHTML = XCOLS.map(c=>'<th'+(c[2]?' class="red"':'')+'>'+esc(c[0]).replace("\n","<br>")+'</th>').join("");
  $("x-hint").textContent = "共 "+rows.length+" 筆"+(rows.some(r=>r.expired)?"・灰色＝合約已到期":"");
  let html="", i=0;
  while(i<rows.length){
    let j=i+1; if(byProd) while(j<rows.length && rows[j].b.product===rows[i].b.product) j++;
    for(let k=i;k<j;k++){
      const r=rows[k], c=r.cells, a=actorById(r.b.actor);
      const col = a? COLORS[actors.indexOf(a)%COLORS.length] : "#888";
      html+='<tr'+(r.expired?' class="expired"':r.due?' class="due"':'')+'>'+(k===i?'<td class="prod" rowspan="'+(j-i)+'">'+esc(c[0])+'</td>':'')+
        c.slice(1).map((v,n)=>{ const idx=n+1;
          if(idx===X_PHOTO) return '<td>'+(a&&a.photo?'<span class="thumb" style="background:#ccc url(&quot;'+a.photo+'&quot;) center/cover"></span>':'<span class="thumb" style="background:'+col+'">'+esc(a?a.name.slice(-1):"")+'</span>')+'</td>';
          if(XHEAD[idx]==="腳本" && /^https?:\/\//.test(v)) return '<td><a href="'+esc(v)+'" target="_blank" rel="noopener">開啟</a></td>';
          if(XHEAD[idx]==="備考"){ const inner='<div class="meta">'+esc(r.auto)+'</div>'+(r.b.note?'<div class="x-note">'+esc(r.b.note)+'</div>':(canEdit?'<div class="oa-empty">點擊填寫備考</div>':''));
            return '<td class="rem">'+(canEdit?'<button type="button" class="x-cell" data-xnote="'+r.b.id+'">'+inner+'</button>':inner)+'</td>'; }
          return '<td>'+esc(v)+'</td>'; }).join("")+
        '</tr>';
    }
    i=j;
  }
  $("xrows").innerHTML = html || '<tr><td colspan="'+(XCOLS.length+1)+'" class="note">沒有可匯出的合約。</td></tr>';
}
function renderAll(){ if(!profile) return; renderQuota(); renderPool(); renderSelects(); renderRows(); renderExport(); }

function setRole(r){ role=r; document.querySelectorAll(".role button").forEach(b=>b.classList.toggle("on",b.dataset.role===r));
  $("add-actor").classList.toggle("hidden", r!=="casting"); renderAll(); }
function setTab(t){ tab=t; document.querySelectorAll(".tabs button").forEach(b=>b.classList.toggle("on",b.dataset.tab===t));
  ["pool","book","list","export","rules","admin"].forEach(k=>$("tab-"+k).classList.toggle("hidden",k!==t)); if(t==="admin") renderAdmin(); }

document.querySelectorAll(".role button").forEach(b=>b.addEventListener("click",()=>setRole(b.dataset.role)));
document.querySelectorAll("[data-tab]").forEach(b=>b.addEventListener("click",()=>setTab(b.dataset.tab)));
$("m-prev").onclick=()=>{ if(cyc>1){cyc--;renderAll();} };
$("m-next").onclick=()=>{ if(cyc<maxCycle()){cyc++;renderAll();} };
["f-q","f-gender","f-age","f-status"].forEach(id=>$(id).addEventListener("input",renderPool));
$("l-status").onchange=renderRows;
$("l-scope").onchange=renderRows;
$("x-scope").onchange=renderExport;
$("x-sort").onchange=renderExport;
$("xrows").addEventListener("click",e=>{
  const who=()=>role==="casting"?"Casting":"大廣";
  const xi=e.target.closest("[data-xinv]");
  if(xi){ const b=bookings.find(x=>x.id===xi.dataset.xinv); const td=xi.parentElement; const cur=b.inv||(cycleInv||{})[b.cycle]||"";
    td.innerHTML='<div class="oa-edit"><input type="date" value="'+cur+'" aria-label="發票日期"><div class="oa-btns"><button type="button" class="btn sm primary" data-xinv-save="'+b.id+'">儲存</button><button type="button" class="btn sm ghost" data-x-cancel>取消</button></div>'+((cycleInv||{})[b.cycle]?'<button type="button" class="linkbtn" data-xinv-reset="'+b.id+'">改回期數請款日</button>':'')+'</div>';
    td.querySelector("input").focus(); return; }
  const xs=e.target.closest("[data-xinv-save]");
  if(xs){ const b=bookings.find(x=>x.id===xs.dataset.xinvSave); const v=xs.closest(".oa-edit").querySelector("input").value; const cy=(cycleInv||{})[b.cycle]||"";
    const nv = (v===cy) ? "" : v; const before=b.inv||"";
    if(nv===before){ renderExport(); return; }
    (async()=>{ if(await call("set_invoice_date",{p_id:b.id,p_date:nv||null})) toast(bkName(b)+" 的發票日期已更新",null); })(); return; }
  const xr=e.target.closest("[data-xinv-reset]");
  if(xr){ const b=bookings.find(x=>x.id===xr.dataset.xinvReset); if(!b.inv){ renderExport(); return; }
    (async()=>{ if(await call("set_invoice_date",{p_id:b.id,p_date:null})) toast(bkName(b)+" 的發票日期已改回期數請款日",null); })(); return; }
  const xn=e.target.closest("[data-xnote]");
  if(xn){ const b=bookings.find(x=>x.id===xn.dataset.xnote); const td=xn.parentElement;
    td.innerHTML='<div class="oa-edit note-edit"><textarea rows="3" aria-label="備考">'+esc(b.note||"")+'</textarea><div class="oa-btns"><button type="button" class="btn sm primary" data-xnote-save="'+b.id+'">儲存</button><button type="button" class="btn sm ghost" data-x-cancel>取消</button></div></div>';
    const ta=td.querySelector("textarea"); ta.focus(); ta.setSelectionRange(ta.value.length,ta.value.length); return; }
  const ns=e.target.closest("[data-xnote-save]");
  if(ns){ const b=bookings.find(x=>x.id===ns.dataset.xnoteSave); const v=ns.closest(".oa-edit").querySelector("textarea").value.trim();
    if(v===(b.note||"")){ renderExport(); return; }
    (async()=>{ if(await call("set_booking_note",{p_id:b.id,p_note:v})) toast(bkName(b)+" 的備考已更新",null); })(); return; }
  if(e.target.closest("[data-x-cancel]")){ renderExport(); return; }
});

function bookActor(id){ setTab("book"); $("b-actor").value=id; if(!$("b-date").value){ $("b-date").value = minShootDate(); } syncForm("date"); $("b-title").focus(); }
/* MENU：演員細節 */
function openActorView(id){
  const a=actorById(id); if(!a) return; const t=a.terms||{};
  const koc=kocOf(a.id);
  const list=bookings.filter(b=>b.actor===a.id&&b.status!=="已刪除").sort((x,y)=>y.date.localeCompare(x.date));
  const shoots=new Set(list.filter(counts).map(b=>b.shoot)).size;
  const sec=(ti,rows)=>'<section class="d-sec"><h4>'+esc(ti)+'</h4><dl>'+rows.map(r=>'<div><dt>'+esc(r[0])+'</dt><dd>'+esc((r[1]===""||r[1]==null)?"—":String(r[1]))+'</dd></div>').join("")+'</dl></section>';
  const money=v=>(v===""||v==null)?"—":Number(v).toLocaleString()+" 元";
  $("av-title").innerHTML='<span class="av-no">'+esc(a.id.replace(/\D/g,"").padStart(3,"0").slice(-3))+'</span> '+esc(a.name)+' <span class="pill '+(a.status==="暫停接案"?"s-bad":"s-ok")+'">'+esc(a.status)+'</span>';
  $("av-body").innerHTML=
    '<div class="av-top"><div class="av-ph"'+(a.photo?' style="background-image:url(&quot;'+a.photo+'&quot;)"':'')+'>'+(a.photo?'':'<b>'+esc(a.name.slice(-1))+'</b>')+'</div>'+
    '<div class="av-info">'+sec("基本資料",[["演員編號",a.id],["性別",a.gender],["年齡",a.birth?age(a.birth)+" 歲（"+a.birth.replace("-","/")+"）":""],["身高",a.height!==""?a.height+" cm":""],["衣服尺寸",a.size],["可拍攝日",a.time],["最後更新",a.updated?slash(a.updated):""]])+
    (a.tags.length?'<div class="chips" style="margin-top:8px">'+a.tags.map(x=>'<span class="chip">'+esc(x)+'</span>').join("")+'</div>':'')+
    (a.note?'<p class="meta" style="margin-top:8px">備註：'+esc(a.note)+'</p>':'')+'</div></div>'+
    '<section class="d-sec"><h4>影片連結</h4>'+((a.videos||[]).length?'<ul class="av-links">'+a.videos.map((v,i)=>'<li>'+(/^https?:\/\//.test(v)?'<a href="'+esc(v)+'" target="_blank" rel="noopener">▶ 影片 '+(i+1)+'</a> <span class="meta">'+esc(v)+'</span>':esc(v))+'</li>').join("")+'</ul>':'<p class="meta">尚未提供</p>')+'</section>'+
    sec("合約與肖像授權",[["肖像權期間",t.length?lenLabel(t.length):""],["合約更新提醒",t.renew?"到期前 "+t.renew+" 天":""],["WEB平台",(t.web||[]).join("、")],["二次利用",t.second],["AI 修圖 / 影片生成",t.ai],["綁競品（成分 / 功效）",(t.ci||"—")+" / "+(t.ce||"—")],["拍攝費（每人次）",money(t.fee)],["超時費",money(t.ot)],["保密合約",t.nda]])+
    '<section class="d-sec"><h4>拍攝紀錄</h4>'+
      '<p class="meta" style="margin:0 0 6px">共 '+shoots+' 人次・'+list.filter(counts).length+' 支素材'+(koc?'　｜　<span class="chip koc">KOC</span> 已綁 '+esc(koc.product)+'（至 '+esc(slash(koc.end))+'）':'')+'</p>'+
      (list.length?'<div class="tbl-wrap"><table class="av-tbl"><thead><tr><th>拍攝日期</th><th>商品</th><th>素材管理編號</th><th>素材篇名</th><th>拍攝需求</th><th>狀態</th></tr></thead><tbody>'+
        list.map(b=>'<tr><td>'+esc(slash(b.date))+'</td><td>'+esc(b.product)+'</td><td>'+esc(b.mno||"—")+'</td><td>'+esc(b.title||"—")+'</td><td>'+esc(b.role)+'</td><td><span class="pill '+(statusCls[b.status]||"")+'">'+esc(b.status)+'</span></td></tr>').join("")+
      '</tbody></table></div>':'<p class="meta">還沒有拍攝紀錄</p>')+
    '</section>';
  const isCasting = role==="casting";
  $("av-book").classList.toggle("hidden", isCasting); $("av-book").disabled = a.status==="暫停接案" || a.archived;
  $("av-book").textContent = a.status==="暫停接案" ? "暫停供應" : "點這位";
  $("av-edit").classList.toggle("hidden", !isCasting);
  $("actor-view").dataset.id=a.id; $("actor-view").showModal();
}
$("av-x").onclick=()=>$("actor-view").close();
$("actor-view").addEventListener("click",e=>{ if(e.target===$("actor-view")) $("actor-view").close(); });
$("av-book").onclick=()=>{ const id=$("actor-view").dataset.id; $("actor-view").close(); bookActor(id); };
$("av-edit").onclick=()=>{ const id=$("actor-view").dataset.id; $("actor-view").close(); openActor(id); };
$("pool").addEventListener("keydown",e=>{ const v=e.target.closest("[data-view-actor]"); if(v&&(e.key==="Enter"||e.key===" ")){ e.preventDefault(); openActorView(v.dataset.viewActor); } });
$("pool").addEventListener("click",e=>{
  const ed=e.target.closest("[data-edit]"), bk=e.target.closest("[data-book]"), vw=e.target.closest("[data-view-actor]");
  if(vw){ openActorView(vw.dataset.viewActor); return; }
  if(ed) openActor(ed.dataset.edit);
  if(bk){ bookActor(bk.dataset.book); return; }
});
/* 預約總表：寄信通知 Casting 敲通告 */
function notifyMailto(sh){
  const to=(window.CASTING_CONFIG||{}).CASTING_NOTIFY_EMAIL||"";
  const a=actorById(sh.actor)||{name:sh.actor};
  const live=sh.live.slice().sort((x,y)=>x.id.localeCompare(y.id));
  const hrs=live.reduce((t,b)=>t+Number(b.hours||0),0);
  const subj="【敲通告】"+a.name+"（"+sh.actor+"）候選 "+sh.cands.map(shortD).join("、")+(live.length>1?"・共"+live.length+"支":"・"+(live[0]?bkName(live[0]):""));
  const okC=sh.cands.filter(lockOK);
  const lines=["阿森您好：","","麻煩協助確認以下通告的檔期，並在平台上從候選日中鎖定一天，謝謝！"+(okC.length?"（請於 "+slashW(lockBy(okC[0]))+" 前鎖定，才來得及辦保險）":""),"",
    "演員："+a.name+"（"+sh.actor+"）",
    "候選日："+sh.cands.map(slashW).join("、"),
    "預估總時數："+hrs+" 小時"+(hrs>CAP?"（超過 "+CAP+" 小時，含超時）":""),
    "素材數："+live.length+" 支"+(live.length>1?"（同日同場，算 1 人次）":""),""];
  live.forEach((b,i)=>{ lines.push((i+1)+". "+bkName(b)+"｜"+b.product+"・"+b.team+"｜"+b.role+"｜"+(b.title||"")+"｜"+b.hours+" 小時"+(b.place?"｜地點："+b.place:"")); if(b.note) lines.push("   備考："+b.note); });
  lines.push("","目前狀態："+sh.status,"登記人："+(live[0]&&live[0].by||myName()),"","平台連結："+location.origin+location.pathname);
  return "mailto:"+encodeURIComponent(to)+"?subject="+encodeURIComponent(subj)+"&body="+encodeURIComponent(lines.join("\n"));
}
$("rows").addEventListener("click",e=>{
  const oa=e.target.closest("[data-oa]");
  if(oa){ const b=bookings.find(x=>x.id===oa.dataset.oa); const td=oa.parentElement;
    td.innerHTML='<div class="oa-edit"><input type="date" value="'+(b.start||"")+'" aria-label="本素材合約開始日（OA日）"><div class="oa-btns"><button type="button" class="btn sm primary" data-oa-save="'+b.id+'">儲存</button><button type="button" class="btn sm ghost" data-oa-cancel>取消</button></div></div>';
    td.querySelector("input").focus(); return; }
  const os=e.target.closest("[data-oa-save]");
  if(os){ const b=bookings.find(x=>x.id===os.dataset.oaSave); const v=os.closest(".oa-edit").querySelector("input").value; const before=b.start||"";
    if(v===before){ renderRows(); return; }
    (async()=>{ if(await call("set_oa_date",{p_id:b.id,p_date:v||null})) toast(bkName(b)+" 的 OA 日已設為 "+(v?slash(v):"未定")+(v?"，合約至 "+slash(endOf(v,b.length)):""),null); })(); return; }
  if(e.target.closest("[data-oa-cancel]")){ renderRows(); return; }
  const db=e.target.closest("[data-del]"); if(db){ openDel(db.dataset.del); return; }
  const vb=e.target.closest("[data-view]"); if(vb){ openDetail(vb.dataset.view); return; }
  const eb=e.target.closest("[data-edit-bk]"); if(eb){ openEditBk(eb.dataset.editBk); return; }
  const sb=e.target.closest("[data-shoot]");
  if(sb){ setShootStatus(sb.dataset.shoot, sb.dataset.to, sb.dataset.from); return; }
  const lk=e.target.closest("[data-lock]"); if(lk){ openLock(lk.dataset.lock); return; }
  const rs=e.target.closest("[data-resched]"); if(rs){ const sh=shootById(rs.dataset.resched); if(sh) openResched(sh.live.map(b=>b.id)); return; }
  const nt=e.target.closest("[data-notice]"); if(nt){ openNotice(nt.dataset.notice); return; }
  const btn=e.target.closest("[data-act]"); if(!btn) return;
  const b=bookings.find(x=>x.id===btn.dataset.id);
  if(btn.dataset.act==="待確認"){ /* 恢復：先在畫面上檢查，資料庫也會再檢查一次 */
    const sh = b.lockedAt ? (lockedShootOn(b.actor,b.date)||pendingGroup(b.actor,b.cands)) : pendingGroup(b.actor,b.cands);
    const kl=kocLock(b.actor,b.product,b.role,b.date,b.id); if(kl) return toast("這位演員已綁 "+kl.product+" 的 KOC，無法恢復這支 KOC。",null);
    if((sh?sh.hours:0)+Number(b.hours||0)>CAP) return toast("恢復後這場會超過 "+CAP+" 小時，請先和 Casting 確認。",null);
  }
  setCancelled(b.id, btn.dataset.act==="已取消");
});

/* 表單自動帶入 */
let firstTouched=false;
function syncForm(src){
  if(src==="product") $("b-team").value = PRODUCTS[$("b-product").value]||"CRM組";
  const firstOA = bookings.filter(b=>b.actor===$("b-actor").value&&b.product===$("b-product").value&&counts(b)).map(b=>b.start).sort()[0];
  const act=actorById($("b-actor").value), t=(act&&act.terms)||{length:6,renew:30,web:[]};
  const rows=[["合約長度",lenLabel(t.length)],["合約更新確認",t.renew+"天前"],["WEB平台",(t.web||[]).join("、")||"—"],["二次利用",t.second],["AI 修圖 / 影片生成",t.ai],["綁競品（成分）",t.ci],["綁競品（功効）",t.ce],["拍攝費",money(t.fee)+" / 人次"],["超時費",money(t.ot)+" / 小時"],["保密合約",t.nda]];
  $("b-terms").innerHTML = act ? '<div class="tsrc">'+esc(act.id+" "+act.name)+' 的演員卡條件・Casting 更新於 '+esc(slash(act.updated))+'</div><dl>'+rows.map(r=>'<div><dt>'+esc(r[0])+'</dt><dd>'+esc(r[1])+'</dd></div>').join("")+'</dl>' : "";
  const r = renewOf($("b-start").value,t.length,t.renew);
  $("b-renew-date").value = r ? slash(r) : "";
  $("b-renew-hint").textContent = $("b-start").value ? "合約至 "+slash(endOf($("b-start").value,t.length))+"，到期前 "+t.renew+" 天提醒" : "填入 OA 日後自動計算";
  const dates = formDates(), minD = minShootDate();
  ["b-date","b-date2","b-date3"].forEach(id=>{ $(id).min = isAdmin ? "" : minD; });
  $("b-date-hint").textContent = "最早可選 "+slashW(minD)+"（10 個工作天後，才來得及辦保險）。Casting 或大廣會從候選日中鎖定一天。";
  const ex = dates.length ? pendingGroup($("b-actor").value, dates) : null;
  const box=$("b-merge");
  const kl = dates.length && dates.every(d=>kocLock($("b-actor").value,$("b-product").value,$("b-role").value,d)) ? kocLock($("b-actor").value,$("b-product").value,$("b-role").value,dates[0]) : (dates.length?null:kocLock($("b-actor").value,$("b-product").value,$("b-role").value,fmt(today)));
  const early = !isAdmin && dates.find(d=>d<minD);
  const addH = Number($("b-hours").value), totH = (ex?ex.hours:0)+addH, over = totH>CAP;
  $("b-otok-wrap").classList.toggle("hidden",!over||!!kl);
  if(early){ box.className="msg err"; box.textContent="候選日 "+slash(early)+" 太早了：最早只能選 "+slashW(minD)+"（10 個工作天後）。"; }
  else if(isAdmin && dates.find(d=>d<minD)){ box.className="msg err"; box.textContent="管理員可略過規則：候選日 "+slash(dates.find(d=>d<minD))+" 不到 10 個工作天，保險可能來不及辦，鎖定後通告單會標示【急件】。"; }
  else if(kl){ box.className="msg err"; box.innerHTML='這位演員已幫 <strong>'+esc(kl.product)+'</strong> 拍 KOC（'+esc(kl.title)+'，合約至 '+esc(slash(kocEnd(kl)))+'），不能再幫 '+esc($("b-product").value)+' 拍 KOC。可以改成情境演員，或換其他演員。'; }
  else if(ex){ box.className="msg "+(over?"err":"info"); box.innerHTML='這位演員已有相同候選日（'+esc(ex.cands.map(shortD).join("、"))+'）的待敲定拍攝 <strong>'+esc(ex.id)+'</strong>（第 '+shootCycle(ex)+' 期，已登記 '+ex.live.length+' 支：'+esc(ex.live.map(b=>b.product+"「"+b.title+"」"+b.hours+"h").join("、"))+'）。這筆會<strong>合併為同一拍攝人次，不另佔額度、不另計拍攝費</strong>。<br>加上這支共 <strong>'+totH+' / '+CAP+' 小時</strong>'+(over?'，超過當天上限 '+(totH-CAP)+' 小時。':'，還剩 '+(CAP-totH)+' 小時。'); }
  else if(dates.length){ const oc=openCycle(), k=cycleShoots(oc).length+1; box.className="msg plain"; box.textContent = (over?"單支就超過 "+CAP+" 小時上限。":"")+"這筆會先佔第 "+oc+" 期的第 "+k+" / 7 人次（待敲定）"+(k===QUOTA?"，排滿後本期即可請款":"")+"。鎖定日期時，如果那天這位演員已有拍攝，會自動合併成 1 人次並釋出這一點；當天上限 "+CAP+" 小時。"; }
  else { box.className="hidden"; }
}
$("b-product").addEventListener("change",()=>{firstTouched=false;syncForm("product");});
$("b-actor").addEventListener("change",()=>{firstTouched=false;syncForm();});
$("b-date").addEventListener("change",()=>syncForm("date"));
$("b-date2").addEventListener("change",()=>syncForm("date"));
$("b-date3").addEventListener("change",()=>syncForm("date"));
function formDates(){ return [...new Set(["b-date","b-date2","b-date3"].map(id=>$(id).value).filter(Boolean))].sort(); }
$("b-hours").addEventListener("change",()=>syncForm());
$("b-role").addEventListener("change",()=>syncForm());
$("b-start").addEventListener("change",()=>syncForm());

$("b-title").addEventListener("input",()=>syncForm());

$("book-form").addEventListener("submit",async e=>{
  e.preventDefault();
  const msg=(t,ok)=>{$("b-msg").innerHTML='<div class="msg '+(ok?"ok":"err")+'">'+esc(t)+'</div>';};
  const dates=formDates(), actor=$("b-actor").value, title=$("b-title").value.trim(), start=$("b-start").value;
  if(!dates.length||!actor||!title||!$("b-mno").value.trim()) return msg("請填寫演員、素材管理編號、素材篇名，並至少選 1 個拍攝日期。");
  const minD=minShootDate(); const early=!isAdmin && dates.find(d=>d<minD);
  if(early) return msg("候選日 "+slash(early)+" 太早了：最早只能選 "+slash(minD)+"（10 個工作天後），才來得及辦保險。");
  const ex=pendingGroup(actor,dates);
  const cycle = ex ? shootCycle(ex) : openCycle();
  const kl = dates.every(d=>kocLock(actor,$("b-product").value,$("b-role").value,d)) ? kocLock(actor,$("b-product").value,$("b-role").value,dates[0]) : null;
  if(kl) return msg("這位演員已幫 "+kl.product+" 拍 KOC（合約至 "+slash(kocEnd(kl))+"），不能再幫 "+$("b-product").value+" 拍 KOC。請改成情境演員，或換其他演員。");
  const totH=(ex?ex.hours:0)+Number($("b-hours").value);
  if(totH>CAP && !$("b-otok").checked) return msg("這場加總 "+totH+" 小時，超過當天上限 "+CAP+" 小時。請縮短時數，或勾選「已和 Casting 公司確認超時」。");
  if(ex && ex.live.some(b=>b.product===$("b-product").value&&b.title===title)) return msg("同一場拍攝已登記過「"+title+"」，請確認是否重複。");
  const btnS=e.submitter||$("book-form").querySelector("button[type=submit]"); btnS.disabled=true;
  const res = await call("create_booking",{p_actor:actor,p_dates:dates,p_hours:Number($("b-hours").value),p_product:$("b-product").value,p_team:$("b-team").value,
    p_role:$("b-role").value,p_material_no:$("b-mno").value.trim(),p_title:title,p_place:$("b-place").value.trim()||null,p_start:start||null,
    p_script:$("b-script").value.trim()||null,p_note:$("b-note").value.trim()||null,p_overtime_ok:$("b-otok").checked},{quiet:true});
  btnS.disabled=false;
  if(res.error) return msg(res.error);
  const nb = bookings.find(x=>x.id===res.data.id) || res.data;
  const nc = nb.cycle||cycle; cyc=nc; renderAll(); const left=QUOTA-cycleShoots(nc).length;
  msg(ex ? "已送出 "+$("b-mno").value.trim()+"，和相同候選日的預約併為同一場（共 "+(ex.live.length+1)+" 支素材、"+totH+" 小時，算 1 人次）。等待鎖定日期。第 "+nc+" 期剩餘 "+left+" 人次。"
         : "已送出 "+$("b-mno").value.trim()+"（第 "+nc+" 期），候選日 "+dates.map(shortW).join("、")+"，等待鎖定日期。"+(left>0?"本期剩餘 "+left+" 人次。":"本期 7 人次已排滿，全數拍攝完成後 Casting 即可請款。"),true);
  openReceipt(nb, !!ex, nc);
  $("b-title").value=""; $("b-mno").value=""; $("b-script").value=""; $("b-note").value=""; $("b-otok").checked=false; $("b-start").value=""; syncForm();
});

$("copy-tsv").addEventListener("click",async()=>{
  const lines=[XHEAD.map(h=>h.replace("\n","")).join("\t"),...exportRows().map(r=>r.cells.map(v=>String(v).replace(/[\t\n]/g," ")).join("\t"))];
  const btn=$("copy-tsv");
  try{ await navigator.clipboard.writeText(lines.join("\n")); btn.textContent="已複製"; }catch(err){ btn.textContent="無法複製"; }
  setTimeout(()=>btn.textContent="複製表格（貼到 Excel）",1500);
});

let downloads=null;
/* 下載檔案：在 Claude 裡用平台的下載功能；其他地方（Chrome 直接開、GitHub Pages）用一般的瀏覽器下載 */
async function saveFile(name, blob){
  if(downloads){ await downloads.save({filename:name,data:blob}); return "saved"; }
  const url=URL.createObjectURL(blob); const a=document.createElement("a"); a.href=url; a.download=name;
  document.body.appendChild(a); a.click(); a.remove(); setTimeout(()=>URL.revokeObjectURL(url),4000);
  return "fallback";
}
function showXlsxButtons(){ if(window.ExcelJS){ $("dl-xlsx").classList.remove("hidden"); $("l-xlsx").classList.remove("hidden"); } }
$("dl-xlsx").classList.add("hidden");
if(window.ExcelJS) showXlsxButtons(); else window.addEventListener("load",showXlsxButtons);
$("dl-xlsx").addEventListener("click",async()=>{
  const btn=$("dl-xlsx"); const rows=exportRows();
  const wb=new ExcelJS.Workbook(); const ws=wb.addWorksheet("契約者一覽表");
  ws.getCell("B2").value="契約者一覽表"; ws.getCell("B2").font={bold:true,underline:true,size:12};
  XCOLS.forEach((c,i)=>ws.getColumn(i+2).width=c[1]);
  const border={top:{style:"thin"},left:{style:"thin"},bottom:{style:"thin"},right:{style:"thin"}};
  const hr=ws.getRow(4); hr.height=34;
  XHEAD.forEach((h,i)=>{ const c=hr.getCell(i+2); c.value=h; c.font={bold:true,color:{argb:(XCOLS[i][2]?"FFC0392B":"FF000000")}};
    c.fill={type:"pattern",pattern:"solid",fgColor:{argb:"FFDCE6F1"}}; c.alignment={horizontal:"center",vertical:"middle",wrapText:true}; c.border=border; });
  let r=5, start=5, prevProd=null;
  rows.forEach((row,idx)=>{
    const xr=ws.getRow(r); xr.height=40;
    row.cells.forEach((v,i)=>{ const c=xr.getCell(i+2); c.value = (i===X_FEE && row.feeHere && row.b.fee!=="") ? Number(row.b.fee) : v;
      if(i===X_FEE) c.numFmt='"NT$"#,##0'; c.alignment={horizontal:"center",vertical:"middle",wrapText:true}; c.border=border;
      if(row.expired){ c.fill={type:"pattern",pattern:"solid",fgColor:{argb:"FFEFEFEF"}}; c.font={color:{argb:"FF888888"}}; }
      else if(row.due) c.fill={type:"pattern",pattern:"solid",fgColor:{argb:"FFFCE8CC"}}; });
    const next=rows[idx+1];
    if(!next || next.b.product!==row.b.product){ if(r>start) ws.mergeCells(start,2,r,2); start=r+1; }
    r++;
  });
  ws.views=[{state:"frozen",ySplit:4,xSplit:4}];
  ws.autoFilter={from:{row:4,column:2},to:{row:4,column:XCOLS.length+1}};
  const buf=await wb.xlsx.writeBuffer();
  try{ await saveFile("契約者一覽表_"+fmt(today).replace(/-/g,"")+".xlsx", new Blob([buf])); btn.textContent="已匯出"; }
  catch(err){ btn.textContent = err && err.code==="declined" ? "已取消" : "無法匯出"; }
  setTimeout(()=>btn.textContent="匯出 Excel",1500);
});

const WD="日一二三四五六";
const slashW = d => d ? slash(d)+"（"+WD[new Date(d+"T00:00:00").getDay()]+"）" : "";
function receiptInfo(b){
  const a=actorById(b.actor)||{name:b.actor}; const cycle=b.cycle; const shots=cycleShoots(cycle);
  const sib=bookings.filter(x=>x.shoot===b.shoot&&counts(x)).sort((x,y)=>x.id.localeCompare(y.id));
  const ex = sib.length>0 && sib[0].id!==b.id; const k=shots.findIndex(sh=>sh.id===b.shoot)+1;
  return { a, ex, point: ex?"併入同場，不另計點":(k>0?"第 "+cycle+" 期 第 "+k+" / 7 點":"第 "+cycle+" 期") };
}
let receiptBk=null;
function openReceipt(b, ex, cycle){
  receiptBk=b; const info=receiptInfo(b); const a=info.a;
  const point = (ex!==undefined && cycle!==undefined) ? (ex?"併入同場，不另計點":"第 "+cycle+" 期 第 "+(cycleShoots(cycle).findIndex(sh=>sh.id===b.shoot)+1)+" / 7 點") : info.point;
  const st = b.status==="待確認"||!b.status ? "待鎖定拍攝日期" : b.status;
  const row=(l,v)=>'<div class="r-row"><span>'+esc(l)+'</span><span>'+esc(v)+'</span></div>';
  $("r-body").innerHTML='<div class="r-shop" id="r-title">Casting Drive-Thru</div><div class="r-sub">演員預約平台・點餐單</div><div class="r-cut"></div>'+
    '<div class="r-lbl">素材管理編號</div><div class="r-no">'+esc(bkName(b))+'</div><div class="r-cut"></div>'+
    row("演員",a.name+"（"+b.actor+"）")+row("商品",b.product+"・"+b.team)+row("拍攝需求",b.role)+row("素材",b.title)+(b.status==="待確認"||!b.status ? row("候選日",(b.cands||[b.date]).map(shortW).join("、")) : row("拍攝日","🔒 "+slashW(b.date)))+row("預估時數",b.hours+" 小時")+(b.place?row("拍攝地點",b.place):"")+
    '<div class="r-cut"></div>'+row("集點",point)+row("登記人",b.by||myName())+
    '<div class="r-cut"></div><div class="r-status">狀態：'+esc(st)+'</div><div class="r-bar" aria-hidden="true"></div><div class="r-thanks">THANK YOU ・ 請等候叫號</div>';
  $("r-msg").textContent="";
  $("receipt").showModal();
}
function receiptText(b){
  const info=receiptInfo(b); const a=info.a;
  const st = b.status==="待確認"||!b.status ? "待鎖定拍攝日期" : b.status;
  return ["【Casting Drive-Thru 預約】",
    "素材管理編號："+bkName(b),
    "演員："+a.name+"（"+b.actor+"）",
    "商品："+b.product+"・"+b.team,
    "拍攝需求："+b.role,
    "素材："+b.title,
    (b.status==="待確認"||!b.status ? "候選日："+(b.cands||[b.date]).map(slashW).join("、") : "拍攝日（已鎖定）："+slashW(b.date)),
    "預估時數："+b.hours+" 小時",
    b.place?"拍攝地點："+b.place:null,
    "集點："+info.point,
    "登記人："+(b.by||myName()),
    "狀態："+st].filter(Boolean).join("\n");
}
async function copyText(t){
  try{ await navigator.clipboard.writeText(t); return true; }
  catch(e){ const ta=document.createElement("textarea"); ta.value=t; ta.style.position="fixed"; ta.style.opacity="0"; document.body.appendChild(ta); ta.select();
    let ok=false; try{ ok=document.execCommand("copy"); }catch(_){} ta.remove(); return ok; }
}
let h2cP=null;
function loadH2C(){ if(window.html2canvas) return Promise.resolve(); if(h2cP) return h2cP;
  h2cP=new Promise((res,rej)=>{ const sc=document.createElement("script"); sc.src="https://cdn.jsdelivr.net/npm/html2canvas@1.4.1/dist/html2canvas.min.js"; sc.onload=res; sc.onerror=()=>{ h2cP=null; rej(new Error("load")); }; document.head.appendChild(sc); });
  return h2cP; }
async function saveNodeImage(el, name, msg){
  msg.textContent="產生圖片中…";
  try{
    await loadH2C();
    el.classList.add("r-snap");
    const canvas=await window.html2canvas(el,{scale:2,backgroundColor:"#fffdf7",useCORS:true});
    el.classList.remove("r-snap");
    name=name.replace(/[\\/:*?"<>|\s]+/g,"_")+".png";
    const blob=await new Promise(r=>canvas.toBlob(r,"image/png"));
    const file=new File([blob],name,{type:"image/png"});
    if(navigator.canShare && navigator.canShare({files:[file]}) && /Mobi|Android|iPhone|iPad/.test(navigator.userAgent)){
      try{ await navigator.share({files:[file],title:name}); msg.textContent=""; return; }catch(e){ if(e&&e.name==="AbortError"){ msg.textContent=""; return; } }
    }
    const url=URL.createObjectURL(blob); const link=document.createElement("a"); link.href=url; link.download=name; document.body.appendChild(link); link.click(); link.remove();
    setTimeout(()=>URL.revokeObjectURL(url),2000);
    msg.textContent="已下載圖片：「"+name+"」";
  }catch(e){ el.classList.remove("r-snap"); msg.textContent="圖片產生失敗，請改用「複製文字」或截圖"; }
}
async function saveReceiptImage(){ const b=receiptBk; if(!b) return; await saveNodeImage($("r-body"), bkName(b)+"_"+((actorById(b.actor)||{}).name||b.actor), $("r-msg")); }
$("r-img").onclick=saveReceiptImage;
$("r-copy").onclick=async()=>{ if(!receiptBk) return; $("r-msg").textContent = await copyText(receiptText(receiptBk)) ? "已複製，到 LINE 貼上就可以了" : "複製失敗，請手動選取文字"; };
/* 預約總表：內容檢視 */
function openDetail(id){
  const b=bookings.find(x=>x.id===id); if(!b) return; const a=actorById(b.actor)||{name:b.actor};
  const sib=bookings.filter(x=>x.shoot===b.shoot&&counts(x)); const hrs=sib.reduce((t,x)=>t+Number(x.hours||0),0);
  const end=endOf(b.start,b.length), renew=renewOf(b.start,b.length,b.renew);
  const isUrl=/^https?:\/\//.test(b.script||"");
  const sec=(t,rows)=>'<section class="d-sec"><h4>'+esc(t)+'</h4><dl>'+rows.filter(r=>r).map(r=>'<div><dt>'+esc(r[0])+'</dt><dd>'+(r[2]?r[1]:esc(r[1]||"—"))+'</dd></div>').join("")+'</dl></section>';
  $("d-title").innerHTML=esc(bkName(b))+' <span class="pill '+statusCls[b.status]+'">'+esc(b.status)+'</span>';
  $("d-body").innerHTML=
    sec("拍攝資訊",[["演員",a.name+"（"+b.actor+"）"],["商品",b.product],["素材管理編號",b.mno],["素材篇名",b.title],["拍攝需求",b.role],[b.status==="待確認"?"候選日期":"拍攝日期", b.status==="待確認" ? (b.cands||[b.date]).map(slash).join("、") : "🔒 "+slash(b.date)],["預估時數",b.hours+" 小時"],["拍攝地點",b.place],["負責組別",b.team],["登記人",b.by]])+
    sec("同場與集點",[["同場素材",sib.length+" 支・共 "+hrs+" / "+CAP+" 小時"],["請款期數","第 "+b.cycle+" 期"+((cycleInv||{})[b.cycle]?"（"+slash(cycleInv[b.cycle])+" 已請款）":"")]])+
    sec("合約與肖像授權",[["本素材合約開始日（OA）",b.start?slash(b.start):"未定"],["合約至",b.start?slash(end)+"（"+lenLabel(b.length)+"）":"填入 OA 日後計算（"+lenLabel(b.length)+"）"],["合約更新提醒日",b.start?slash(renew):"—"],["WEB平台",(b.web||[]).join("、")],["二次利用",b.second],["AI 修圖 / 影片生成",b.ai],["綁競品（成分 / 功効）",b.ci+" / "+b.ce],["保密合約",b.nda]])+
    sec("腳本與備考",[["腳本",b.script?(isUrl?'<a href="'+esc(b.script)+'" target="_blank" rel="noopener">開啟腳本連結</a><div class="meta">'+esc(b.script)+'</div>':esc(b.script)):"—",true],["備考",b.note]])+
    '<section class="d-sec"><h4>狀態紀錄</h4>'+((b.log||[]).length?'<ul class="d-log">'+b.log.map(l=>'<li>'+esc(l.at)+'・'+esc(l.who)+'：'+esc(l.from)+' → '+esc(l.to)+'</li>').join("")+'</ul>':'<p class="meta">尚無變更紀錄</p>')+'</section>';
  if(b.status==="已刪除") $("d-body").insertAdjacentHTML("afterbegin",'<div class="msg err" style="margin-bottom:8px">已刪除・原因：'+esc(b.delReason||"—")+'（'+esc(b.delBy||"")+' '+esc(b.delAt||"")+'）</div>');
  $("d-edit").classList.toggle("hidden", role==="casting" || !counts(b)); $("d-edit").dataset.id=b.id; $("d-out").classList.toggle("hidden", b.status==="已刪除"); $("d-out").dataset.id=b.id; $("d-copy").classList.toggle("hidden", b.status==="已刪除"); $("d-copy").dataset.id=b.id; $("d-msg").textContent="";
  $("detail").showModal();
}
$("d-x").onclick=()=>$("detail").close();
$("detail").addEventListener("click",e=>{ if(e.target===$("detail")) $("detail").close(); });

/* 預約總表：編輯 */
let editingBk=null;
function openEditBk(id){
  const b=bookings.find(x=>x.id===id); if(!b) return; editingBk=b;
  const a=actorById(b.actor)||{name:b.actor}; const locked = b.status==="已拍攝" || isInvoiced(b.cycle);
  $("e-title").textContent="編輯 "+bkName(b);
  const sibN=bookings.filter(x=>x.shoot===b.shoot&&x.id!==b.id&&counts(x)).length;
  $("e-fixed").textContent=a.name+"（"+b.actor+"）・"+b.product+"　｜　演員和商品不能修改，要換請取消後重新預約。"+(locked?"　已拍攝或已請款：拍攝日期、時數與拍攝需求已鎖定。":"");
  $("e-date-show").textContent = b.status==="待確認" ? "候選："+(b.cands||[b.date]).map(shortW).join("、") : "🔒 "+slashW(b.date);
  $("e-resched").classList.toggle("hidden", locked || !(b.status==="待確認"||b.status==="已確認"));
  $("e-date-hint").textContent = sibN ? "同場還有 "+sibN+" 支素材；「改期」只改這一支" : "";

  $("e-hours").innerHTML=$("b-hours").innerHTML;
  $("e-mno").value=b.mno||""; $("e-title-in").value=b.title; $("e-role").value=b.role; $("e-hours").value=String(b.hours);
  $("e-place").value=b.place||""; $("e-team").value=b.team||"毛毛組"; $("e-start").value=b.start||"";
  $("e-script").value=b.script||""; $("e-note").value=b.note||""; $("e-otok").checked=false; $("e-otok-wrap").classList.add("hidden"); $("e-msg").innerHTML="";
  $("e-role").disabled=locked; $("e-hours").disabled=locked;
  if($("detail").open) $("detail").close();
  $("editbk").returnValue=""; $("editbk").showModal();
}
$("d-edit").onclick=()=>openEditBk($("d-edit").dataset.id);
$("d-out").onclick=()=>{ const b=bookings.find(x=>x.id===$("d-out").dataset.id); if(!b) return; $("detail").close(); openReceipt(b); };
$("d-copy").onclick=async()=>{ const b=bookings.find(x=>x.id===$("d-copy").dataset.id); if(!b) return; $("d-msg").textContent = await copyText(receiptText(b)) ? "已複製，到 LINE 貼上就可以了" : "複製失敗"; };
$("e-resched").onclick=()=>{ const b=editingBk; if(!b) return; $("editbk").close("cancel"); openResched([b.id]); };
$("editbk").addEventListener("click",e=>{ if(e.target===$("editbk")) $("editbk").close("cancel"); });
$("e-save").onclick=async()=>{
  const b=editingBk; const err=t=>{$("e-msg").innerHTML='<div class="msg err">'+esc(t)+'</div>';};
  const title=$("e-title-in").value.trim(); if(!title) return err("請填寫素材篇名。"); if(!$("e-mno").value.trim()) return err("請填寫素材管理編號。");
  const role=$("e-role").value, hours=Number($("e-hours").value);
  const sibs = bookings.filter(x=>x.shoot===b.shoot&&x.id!==b.id&&counts(x));
  const kl=kocLock(b.actor,b.product,role,b.date,b.id); if(kl && role!==b.role) return err("這位演員已幫 "+kl.product+" 拍 KOC，不能改成 KOC。");
  const total = sibs.reduce((t,x)=>t+Number(x.hours||0),0) + hours;
  if(total>CAP && !$("e-otok").checked){ $("e-otok-wrap").classList.remove("hidden"); return err("這場加總 "+total+" 小時，超過上限 "+CAP+" 小時。請縮短時數，或勾選已確認超時。"); }
  const names={mno:"素材管理編號",title:"素材篇名",role:"拍攝需求",hours:"時數",place:"地點",team:"組別",start:"OA日",script:"腳本",note:"備考"};
  const next={mno:$("e-mno").value.trim(),title,role,hours,place:$("e-place").value.trim(),team:$("e-team").value,start:$("e-start").value,script:$("e-script").value.trim(),note:$("e-note").value.trim()};
  const changed=Object.keys(next).filter(k=>String(b[k]??"")!==String(next[k]??""));
  if(!changed.length){ $("editbk").close(); return; }
  $("e-save").disabled=true;
  const res = await call("update_booking",{p_id:b.id,p_material_no:next.mno,p_title:title,p_role:role,p_hours:hours,p_place:next.place||null,p_team:next.team,
    p_start:next.start||null,p_script:next.script||null,p_note:next.note||null,p_overtime_ok:$("e-otok").checked},{quiet:true});
  $("e-save").disabled=false;
  if(res.error) return err(res.error);
  $("editbk").close();
  toast("已更新 "+bkName(next)+(changed.length?"（"+changed.map(k=>names[k]).join("、")+"）":""), null);
};

/* 預約總表：鎖定日期（大廣或 Casting） */
let lockingShoot=null;
function openLock(id){
  const sh=shootById(id); if(!sh) return; lockingShoot=sh;
  const a=actorById(sh.actor)||{name:sh.actor}, td=fmt(today);
  $("lk-info").textContent=a.name+"（"+sh.actor+"）・"+sh.live.length+" 支素材・"+sh.hours+" 小時："+sh.live.map(b=>b.product+"「"+b.title+"」").join("、");
  $("lk-opts").innerHTML=sh.cands.map(d=>{
    const wd=workdaysBetween(td,d), other=lockedShootOn(sh.actor,d,sh.id), tot=sh.hours+(other?other.hours:0);
    const koc=sh.live.filter(b=>b.role==="KOC").map(b=>kocLock(b.actor,b.product,"KOC",d,b.id)).find(Boolean);
    const bad = d<=td ? "已經過了" : (other&&other.status==="已拍攝") ? "那天已拍攝完成" : koc ? "已綁 "+koc.product+" 的 KOC" : "";
    const notes = bad ? [bad] : [lockOK(d) ? "✅ 還有 "+wd+" 個工作天" : "⚠ 只剩 "+wd+" 個工作天，保險時程不足"];
    if(!bad && other) notes.push("會和同日已鎖定的拍攝合併，共 "+tot+" 小時"+(tot>CAP?"（超過 "+CAP+" 小時）":""));
    return '<label class="lk-opt'+(bad?' dis':lockOK(d)?'':' late')+'"><input type="radio" name="lk-d" value="'+d+'" data-tot="'+tot+'" data-merge="'+(other?1:0)+'"'+(bad?' disabled':'')+'><span class="lk-d">'+esc(slashW(d))+'</span><span class="lk-n">'+esc(notes.join("・"))+'</span></label>';
  }).join("");
  $("lk-warn").innerHTML=""; $("lk-msg").innerHTML=""; $("lk-otok").checked=false; $("lk-otok-wrap").classList.add("hidden"); $("lk-ok").disabled=true;
  $("lockdlg").showModal();
}
$("lk-opts").addEventListener("change",e=>{ const r=e.target.closest("input[name=lk-d]"); if(!r) return; const d=r.value;
  $("lk-ok").disabled=false; $("lk-otok-wrap").classList.toggle("hidden", Number(r.dataset.tot)<=CAP); $("lk-msg").innerHTML="";
  $("lk-warn").innerHTML = lockOK(d) ? "" : '<div class="msg err">離拍攝只剩 '+workdaysBetween(fmt(today),d)+' 個工作天，Mia 辦保險需要 10 個工作天（鎖定當天算第 1 天）。仍可鎖定，通告單會標示【急件】。</div>'; });
$("lk-x").onclick=$("lk-cancel").onclick=()=>$("lockdlg").close();
$("lockdlg").addEventListener("click",e=>{ if(e.target===$("lockdlg")) $("lockdlg").close(); });
$("lk-ok").onclick=async()=>{
  const r=$("lk-opts").querySelector("input[name=lk-d]:checked"); if(!r) return; const d=r.value, sh=lockingShoot, merged=r.dataset.merge==="1";
  if(Number(r.dataset.tot)>CAP && !$("lk-otok").checked){ $("lk-msg").innerHTML='<div class="msg err">這天加總超過 '+CAP+' 小時，請勾選「已和 Casting 公司確認超時」，或選其他日期。</div>'; return; }
  $("lk-ok").disabled=true;
  const res=await call("lock_shoot",{p_shoot:sh.id,p_date:d,p_overtime_ok:$("lk-otok").checked},{quiet:true});
  $("lk-ok").disabled=false;
  if(res.error){ $("lk-msg").innerHTML='<div class="msg err">'+esc(res.error)+'</div>'; return; }
  $("lockdlg").close();
  const nb=bookings.find(b=>b.id===sh.live[0].id); const newShoot=(nb&&nb.shoot)||sh.id;
  toast("已鎖定 "+slashW(d)+(merged?"，併入同日拍攝":"")+(lockOK(d)?"":"（保險時程不足）"), merged ? null : async()=>{ if(await call("set_shoot_status",{p_shoot:newShoot,p_to:"待確認"})) toast("已解除鎖定",null); });
  if(role!=="casting") openNotice(newShoot);
};

/* 預約總表：改期（重新給候選日，解除鎖定） */
let reschIds=[];
function openResched(ids){
  const items=bookings.filter(b=>ids.includes(b.id)&&counts(b)); if(!items.length) return; reschIds=items.map(b=>b.id);
  const a=actorById(items[0].actor)||{name:items[0].actor}; const wasLocked=items.some(b=>b.status==="已確認");
  $("rs-info").textContent=a.name+"（"+items[0].actor+"）・"+items.length+" 支素材："+items.map(b=>b.product+"「"+b.title+"」").join("、")
    +"　｜　目前："+(wasLocked?"🔒 "+slashW(items[0].date):"候選 "+items[0].cands.map(shortD).join("、"));
  const minD=minShootDate();
  ["rs-d1","rs-d2","rs-d3"].forEach(id=>{ $(id).value=""; $(id).min=isAdmin?"":minD; });
  $("rs-hint").textContent="最早可選 "+slashW(minD)+"。改期後會解除鎖定，需重新鎖定日期"+(wasLocked?"；送出後會提醒你通知 Mia 暫停辦理保險":"")+"。";
  $("rs-msg").innerHTML=""; $("rs-otok").checked=false; $("rs-otok-wrap").classList.add("hidden");
  $("rsdlg").showModal();
}
$("rs-x").onclick=$("rs-cancel").onclick=()=>$("rsdlg").close();
$("rsdlg").addEventListener("click",e=>{ if(e.target===$("rsdlg")) $("rsdlg").close(); });
$("rs-ok").onclick=async()=>{
  const err=t=>{$("rs-msg").innerHTML='<div class="msg err">'+esc(t)+'</div>';};
  const dates=[...new Set(["rs-d1","rs-d2","rs-d3"].map(id=>$(id).value).filter(Boolean))].sort();
  if(!dates.length) return err("請至少選 1 個新的候選日。");
  const minD=minShootDate(), early=!isAdmin&&dates.find(d=>d<minD); if(early) return err("候選日 "+slash(early)+" 太早了：最早只能選 "+slash(minD)+"（10 個工作天後）。");
  const items=bookings.filter(b=>reschIds.includes(b.id)); const before=items.map(b=>({...b})); const wasLocked=items.some(b=>b.status==="已確認");
  const grp=pendingGroup(items[0].actor,dates,reschIds); const tot=items.reduce((t,b)=>t+Number(b.hours||0),0)+(grp?grp.hours:0);
  if(tot>CAP && !$("rs-otok").checked){ $("rs-otok-wrap").classList.remove("hidden"); return err("這場加總 "+tot+" 小時，超過上限 "+CAP+" 小時。請勾選已確認超時，或換其他日期。"); }
  $("rs-ok").disabled=true;
  const res=await call("set_candidates",{p_ids:reschIds,p_dates:dates,p_overtime_ok:$("rs-otok").checked},{quiet:true});
  $("rs-ok").disabled=false;
  if(res.error) return err(res.error);
  $("rsdlg").close();
  toast("已改期，新的候選日："+dates.map(shortD).join("、")+"，請重新鎖定日期",null);
  if(wasLocked && role!=="casting") showReschedNotice(before, dates);
};

/* 通告單（寄給 Mia：保險與合約） */
const MIA = () => (window.CASTING_CONFIG||{}).MIA_EMAIL || "";
const mailto = (to,subj,body) => "mailto:"+encodeURIComponent(to)+"?subject="+encodeURIComponent(subj)+"&body="+encodeURIComponent(body);
const localDay = iso => iso ? fmt(new Date(iso)) : fmt(today);
let noticeCur=null;
function showNotice(n){
  noticeCur=n;
  const row=(l,v)=>'<div class="r-row"><span>'+esc(l)+'</span><span>'+esc(v)+'</span></div>';
  $("n-body").innerHTML='<div class="r-shop" id="n-title">'+esc(n.heading)+'</div><div class="r-sub">'+esc(n.sub)+'</div><div class="r-cut"></div>'+
    (n.urgent?'<div class="n-urgent">'+esc(n.urgent)+'</div>':'')+n.rows.map(r=>r==="cut"?'<div class="r-cut"></div>':r[0]==="#"?'<div class="r-lbl">'+esc(r.slice(1))+'</div>':row(r[0],r[1])).join("")+
    '<div class="r-cut"></div><div class="r-thanks">CASTING DRIVE-THRU</div>';
  $("n-mail").href=mailto(n.to||MIA(),n.subject,n.text); $("n-mail").textContent="✉ 寄給"+(n.toName||"Mia"); $("n-mail").classList.toggle("hidden", n.noMail===true); $("n-msg").textContent="";
  $("notice").showModal();
}
function termsRows(b){ return [["肖像權期間",lenLabel(b.length)+"（依各素材 OA 日起算）"],["合約更新提醒","到期前 "+b.renew+" 天"],["WEB 平台",(b.web||[]).join("、")||"—"],["二次利用",b.second||"—"],["AI 修圖 / 影片生成",b.ai||"—"],["綁競品（成分 / 功效）",(b.ci||"—")+" / "+(b.ce||"—")],["保密合約",b.nda||"—"],["拍攝費",(money(b.fee)||"—")+" / 人次"],["超時費",(money(b.ot)||"—")+" / 小時"]]; }
function openNotice(shootId){
  const sh=shootById(shootId); if(!sh||!sh.active) return;
  if(sh.status==="待確認") return openCallSheet(sh);
  const a=actorById(sh.actor)||{name:sh.actor}; const live=sh.live.slice().sort((x,y)=>x.id.localeCompare(y.id)); const b0=live[0];
  const lockDay=localDay(b0.lockedAt), wd=workdaysBetween(lockDay,sh.date), urgent=sh.date<addWorkdays(lockDay,LOCK_WD);
  const due=subWorkdays(sh.date,1), places=[...new Set(live.map(b=>b.place).filter(Boolean))].join("、")||"未填";
  const items=live.map((b,i)=>(i+1)+". "+bkName(b)+"｜"+b.product+"・"+b.team+"｜"+b.role+"｜"+b.title+"｜"+b.hours+" 小時");
  const terms=termsRows(b0);
  const text=["Mia 您好：","","以下演員的拍攝日期已鎖定，麻煩協助辦理保險與合約，謝謝！",
    urgent?"【急件】鎖定日到拍攝日只有 "+wd+" 個工作天，保險時程不足，請協助趕件或回覆是否可行。":null,"",
    "■ 拍攝日："+slashW(sh.date)+"（已鎖定）","■ 保險需完成："+slashW(due)+" 前","■ 演員："+a.name+"（"+sh.actor+"）","■ 拍攝地點："+places,"■ 預估總時數："+sh.hours+" 小時","",
    "■ 拍攝內容（共 "+live.length+" 支"+(live.length>1?"，同日同場算 1 人次":"")+"）",...items,"",
    "■ 合約條件",...terms.map(t=>t[0]+"："+t[1]),"",
    "登記人："+[...new Set(live.map(b=>b.by))].join("、")+"　鎖定："+(b0.lockedBy||"")+" "+shortD(lockDay),
    "平台連結："+location.origin+location.pathname,"","※ 演員本名、身分證字號等保險所需個資，請向 Casting 公司（阿森）索取。"].filter(x=>x!==null).join("\n");
  showNotice({heading:"通告單", sub:"保險・合約用（寄給 Mia）", urgent: urgent?"【急件】鎖定到拍攝只有 "+wd+" 個工作天":"",
    subject:(urgent?"【急件】":"")+"【通告】"+a.name+" "+slashW(sh.date)+"（"+live.length+" 支素材）", text,
    file:"通告單_"+a.name+"_"+sh.date,
    rows:[["拍攝日","🔒 "+slashW(sh.date)],["保險需完成",slashW(due)+" 前"],["演員",a.name+"（"+sh.actor+"）"],["拍攝地點",places],["預估總時數",sh.hours+" 小時"],"cut","#拍攝內容（共 "+live.length+" 支）",
      ...live.map(b=>[bkName(b),b.product+"・"+b.role+"・"+b.title+"・"+b.hours+"h"]),"cut","#合約條件",...terms,"cut",["登記人",[...new Set(live.map(b=>b.by))].join("、")],["鎖定",(b0.lockedBy||"")+" "+shortD(lockDay)]]});
}
/* 未鎖定：敲通告單（寄給阿森，請他確認檔期並在平台鎖定） */
function openCallSheet(sh){
  const a=actorById(sh.actor)||{name:sh.actor}; const live=sh.live.slice().sort((x,y)=>x.id.localeCompare(y.id));
  const okC=sh.cands.filter(lockOK), places=[...new Set(live.map(b=>b.place).filter(Boolean))].join("、")||"未填";
  const u=new URL(notifyMailto(sh));
  showNotice({heading:"敲通告", sub:"日期鎖定後，才會產生寄給 Mia 的通告單", noMail:true, urgent: okC.length?"":"候選日都不到 10 個工作天，保險可能來不及辦",
    to:(window.CASTING_CONFIG||{}).CASTING_NOTIFY_EMAIL||"", toName:"阿森",
    subject:u.searchParams.get("subject")||"", text:u.searchParams.get("body")||"", file:"敲通告_"+a.name+"_"+sh.cands[0],
    rows:[["演員",a.name+"（"+sh.actor+"）"],["候選日",sh.cands.map(shortW).join("、")],["請於",okC.length?shortW(lockBy(okC[0]))+" 前鎖定":"盡快"],["拍攝地點",places],["預估總時數",sh.hours+" 小時"],"cut","#拍攝內容（共 "+live.length+" 支）",
      ...live.map(b=>[bkName(b),b.product+"・"+b.role+"・"+b.title+"・"+b.hours+"h"]),...live.filter(b=>b.note).map(b=>["備考 "+bkName(b),b.note]),"cut",["登記人",[...new Set(live.map(b=>b.by))].join("、")]]});
}
function showCancelNotice(b){
  const a=actorById(b.actor)||{name:b.actor}; const left=bookings.filter(x=>x.shoot===b.shoot&&x.id!==b.id&&counts(x));
  const text=["Mia 您好：","","以下素材已取消，若已開始辦理保險或合約，請先暫停，謝謝！","",
    "■ 演員："+a.name+"（"+b.actor+"）","■ 原拍攝日："+slashW(b.date),"■ 取消素材："+bkName(b)+"｜"+b.product+"・"+b.role+"｜"+b.title,"",
    left.length?"同場其他 "+left.length+" 支素材照常拍攝："+left.map(x=>bkName(x)+" "+x.title).join("、"):"這位演員當天的拍攝已全部取消。",
    "","平台連結："+location.origin+location.pathname].join("\n");
  showNotice({heading:"取消通知", sub:"已鎖定的素材被取消，請通知 Mia", urgent:"", subject:"【取消】"+a.name+" "+slashW(b.date)+" "+bkName(b), text, file:"取消通知_"+a.name+"_"+b.date,
    rows:[["演員",a.name+"（"+b.actor+"）"],["原拍攝日",slashW(b.date)],["取消素材",bkName(b)+" "+b.title],["同場其他素材",left.length?left.length+" 支照常拍攝":"全部取消"]]});
}
function showReschedNotice(items, dates){
  const b=items[0], a=actorById(b.actor)||{name:b.actor};
  const text=["Mia 您好：","","以下通告已改期，原日期的保險與合約請先暫停；新日期鎖定後會再寄通告單，謝謝！","",
    "■ 演員："+a.name+"（"+b.actor+"）","■ 原拍攝日："+slashW(b.date)+"（已解除鎖定）","■ 新的候選日："+dates.map(slashW).join("、"),
    "■ 素材："+items.map(x=>bkName(x)+" "+x.title).join("、"),"","平台連結："+location.origin+location.pathname].join("\n");
  showNotice({heading:"改期通知", sub:"已鎖定的通告改期，請通知 Mia", urgent:"", subject:"【改期】"+a.name+" 原 "+slashW(b.date)+"（"+items.length+" 支素材）", text, file:"改期通知_"+a.name+"_"+b.date,
    rows:[["演員",a.name+"（"+b.actor+"）"],["原拍攝日",slashW(b.date)],["新的候選日",dates.map(shortW).join("、")],["素材",items.length+" 支"]]});
}
$("n-copy").onclick=async()=>{ if(!noticeCur) return; $("n-msg").textContent = await copyText(noticeCur.text) ? "已複製，可以貼到 LINE 或 email" : "複製失敗"; };
$("n-img").onclick=()=>{ if(noticeCur) saveNodeImage($("n-body"), noticeCur.file, $("n-msg")); };
$("notice").addEventListener("click",e=>{ if(e.target===$("notice")) $("notice").close(); });

/* 預約總表：刪除（需填原因） */
let deletingBk=null;
function openDel(id){
  const b=bookings.find(x=>x.id===id); if(!b) return; deletingBk=b; const a=actorById(b.actor)||{name:b.actor};
  const sib=bookings.filter(x=>x.shoot===b.shoot&&x.id!==b.id&&counts(x)).length;
  $("del-info").textContent=bkName(b)+"・"+a.name+"・"+b.product+"「"+b.title+"」・"+slash(b.date)+(counts(b)&&!sib?"　｜　這是當天唯一的素材，刪除後會釋出 1 個人次。":"");
  $("del-reason").value=""; $("del-msg").innerHTML=""; $("deldlg").showModal(); $("del-reason").focus();
}
$("del-ok").onclick=async()=>{
  const r=$("del-reason").value.trim(); if(r.length<2){ $("del-msg").innerHTML='<div class="msg err">請填寫刪除原因。</div>'; $("del-reason").focus(); return; }
  const b=deletingBk; $("del-ok").disabled=true;
  const res=await call("delete_booking",{p_id:b.id,p_reason:r},{quiet:true}); $("del-ok").disabled=false;
  if(res.error){ $("del-msg").innerHTML='<div class="msg err">'+esc(res.error)+'</div>'; return; }
  $("deldlg").close(); toast("已刪除 "+bkName(b)+"。在狀態篩選選「已刪除」可以查看紀錄。",null);
};
$("deldlg").addEventListener("click",e=>{ if(e.target===$("deldlg")) $("deldlg").close(); });

/* 契約一覽：編輯發票日期 */
let editingInv=null;
function openInv(id){
  const b=bookings.find(x=>x.id===id); if(!b) return; editingInv=b;
  const a=actorById(b.actor)||{name:b.actor}; const cyInv=(cycleInv||{})[b.cycle]||"";
  $("i-title").textContent="發票日期・"+bkName(b);
  $("i-info").textContent=a.name+"・"+b.product+"・"+b.title+"　｜　第 "+b.cycle+" 期請款日："+(cyInv?slash(cyInv):"尚未請款");
  $("i-date").value=b.inv||cyInv||""; $("i-msg").innerHTML="";
  $("invdlg").showModal();
}
$("i-save").onclick=async()=>{ const b=editingInv; const v=$("i-date").value;
  if(await call("set_invoice_date",{p_id:b.id,p_date:v||null})){ $("invdlg").close(); toast("已更新 "+bkName(b)+" 的發票日期",null); } };
$("i-reset").onclick=()=>{ $("i-date").value=""; };
$("invdlg").addEventListener("click",e=>{ if(e.target===$("invdlg")) $("invdlg").close(); });

/* 預約總表：匯出 */
const LHEAD=["期數・人次","拍攝日期","演員編號","演員","商品","負責組別","拍攝需求","素材管理編號","素材篇名","預估時數","拍攝地點","OA日","合約至","登記人","狀態","腳本","備考"];
function listRows(){
  const src = $("l-scope").value==="all" ? bookings : cycBk(); const st=$("l-status").value;
  return src.filter(b=>st ? b.status===st : b.status!=="已刪除").sort((x,y)=>x.date.localeCompare(y.date)||x.shoot.localeCompare(y.shoot)||x.id.localeCompare(y.id))
    .map(b=>[(()=>{ const sh=shootsIn(bookings.filter(x=>x.shoot===b.shoot)).find(Boolean); return sh?shootLabel(sh):""; })(),(b.status==="待確認"?"候選 "+(b.cands||[b.date]).map(slash).join("、"):slash(b.date)),b.actor,(actorById(b.actor)||{}).name||"",b.product,b.team,b.role,b.mno||"",b.title,Number(b.hours),b.place||"",slash(b.start),slash(endOf(b.start,b.length)),b.by,stLabel(b.status),b.script||"",b.note||""]);
}
$("l-copy").addEventListener("click",async()=>{
  const btn=$("l-copy"); const text=[LHEAD.join("\t"),...listRows().map(r=>r.map(v=>String(v).replace(/[\t\n]/g," ")).join("\t"))].join("\n");
  try{ await navigator.clipboard.writeText(text); btn.textContent="已複製"; }catch(err){ btn.textContent="無法複製"; }
  setTimeout(()=>btn.textContent="複製表格",1500);
});
$("l-xlsx").addEventListener("click",async()=>{
  const btn=$("l-xlsx"); const rows=listRows();
  const wb=new ExcelJS.Workbook(); const ws=wb.addWorksheet("預約總表");
  ws.addRow(LHEAD); rows.forEach(r=>ws.addRow(r));
  const border={top:{style:"thin"},left:{style:"thin"},bottom:{style:"thin"},right:{style:"thin"}};
  ws.getRow(1).eachCell(c=>{ c.font={bold:true}; c.fill={type:"pattern",pattern:"solid",fgColor:{argb:"FFFECA1F"}}; c.alignment={horizontal:"center",vertical:"middle"}; });
  ws.eachRow(r=>r.eachCell(c=>{ c.border=border; }));
  [16,12,10,10,10,10,12,16,18,8,16,12,12,10,8,30,30].forEach((w,i)=>ws.getColumn(i+1).width=w);
  ws.views=[{state:"frozen",ySplit:1}]; ws.autoFilter={from:{row:1,column:1},to:{row:1,column:LHEAD.length}};
  const buf=await wb.xlsx.writeBuffer();
  const scope=$("l-scope").value==="all"?"全部":"第"+cyc+"期";
  try{ await saveFile("預約總表_"+scope+"_"+fmt(today).replace(/-/g,"")+".xlsx", new Blob([buf])); btn.textContent="已匯出"; }
  catch(err){ btn.textContent = err && err.code==="declined" ? "已取消" : "無法匯出"; }
  setTimeout(()=>btn.textContent="匯出 Excel",1500);
});
let editing=null;
function openActor(id){
  editing=id; const a=id?actorById(id):null;
  $("dlg-title").textContent = a?"編輯演員":"新增演員";
  $("a-id").value = a?a.id:"";
  $("a-name").value=a?a.name:""; $("a-gender").value=a?a.gender:"女"; $("a-birth").value=a?a.birth:"";
  $("a-height").value=a?a.height:""; $("a-size").value=a?a.size:""; $("a-status").value=a?a.status:"可接案";
  $("a-time").value=a?a.time:""; $("a-tags").value=a?a.tags.join(", "):""; $("a-note").value=a?a.note:""; $("a-video").value=a?(a.videos||[]).join("\n"):"";
  const t=(a&&a.terms)||{length:"",renew:30,web:["IG","FB"],second:"○",ai:"X",ci:"X",ce:"X",fee:"",ot:"",nda:"已簽"};
  $("t-length").value=t.length; $("t-renew").value=t.renew; $("t-fee").value=t.fee; $("t-ot").value=t.ot;
  $("t-second").value=t.second; $("t-ai").value=t.ai; $("t-ci").value=t.ci; $("t-ce").value=t.ce; $("t-nda").value=t.nda;
  document.querySelectorAll('input[name="tweb"]').forEach(x=>x.checked=(t.web||[]).includes(x.value));
  $("a-del").classList.toggle("hidden",!a); $("a-purge").classList.toggle("hidden",!a||!isAdmin); $("a-err").innerHTML="";
  $("a-purge").textContent="刪除（管理員）"; purgeArmed=false;
  pendingPhoto = a&&a.photo ? a.photo : null; photoChanged=false; showPhoto();
  $("actor-dlg").returnValue="";
  $("actor-dlg").showModal();
}
$("add-actor").onclick=()=>openActor(null);
let pendingPhoto=null, purgeArmed=false, photoChanged=false;
function showPhoto(){ const el=$("a-photo-prev"); el.style.backgroundImage = pendingPhoto?'url("'+pendingPhoto+'")':""; el.classList.toggle("has",!!pendingPhoto); $("a-photo-rm").classList.toggle("hidden",!pendingPhoto); }
$("a-photo").addEventListener("change",e=>{
  const f=e.target.files[0]; if(!f) return;
  const img=new Image(), url=URL.createObjectURL(f);
  img.onload=()=>{ const k=Math.min(1,800/Math.max(img.width,img.height)); const c=document.createElement("canvas"); c.width=Math.round(img.width*k); c.height=Math.round(img.height*k);
    c.getContext("2d").drawImage(img,0,0,c.width,c.height); pendingPhoto=c.toDataURL("image/jpeg",0.82); photoChanged=true; URL.revokeObjectURL(url); showPhoto(); };
  img.onerror=()=>{ $("a-err").innerHTML='<div class="msg err">這個檔案無法讀取，請改用 JPG 或 PNG。</div>'; };
  img.src=url; e.target.value="";
});
$("a-photo-rm").onclick=()=>{ pendingPhoto=null; photoChanged=true; showPhoto(); };
$("a-purge").onclick=()=>{
  if(bookings.some(b=>b.actor===editing)){ $("a-err").innerHTML='<div class="msg err">這位演員有預約紀錄，刪除會讓契約一覽對不上，請改用「下架演員」。</div>'; return; }
  if(!purgeArmed){ purgeArmed=true; $("a-purge").textContent="再按一次確認刪除"; return; }
  $("actor-dlg").close("purge");
};
$("actor-dlg").addEventListener("click",e=>{ if(e.target===$("actor-dlg")) $("actor-dlg").close("cancel"); });
$("a-save").addEventListener("click",e=>{
  const miss=[]; if(!$("a-name").value.trim()) miss.push("藝名"); if(!$("t-length").value) miss.push("肖像權期間");
  if(miss.length){ e.preventDefault(); $("a-err").innerHTML='<div class="msg err">請填寫：'+esc(miss.join("、"))+'</div>'; (miss[0]==="藝名"?$("a-name"):$("t-length")).focus(); }
});
$("actor-dlg").addEventListener("close",async()=>{
  const v=$("actor-dlg").returnValue;
  if(v==="save" && $("a-name").value.trim()){
    const row={name:$("a-name").value.trim(),gender:$("a-gender").value,birth_ym:$("a-birth").value.trim()||null,
      height:$("a-height").value?Number($("a-height").value):null,size:$("a-size").value.trim()||null,status:$("a-status").value,avail_time:$("a-time").value.trim()||null,
      tags:$("a-tags").value.split(/[,，]/).map(s=>s.trim()).filter(Boolean),note:$("a-note").value.trim()||null,video_links:$("a-video").value.split(/\n/).map(x=>x.trim()).filter(Boolean).join("\n")||null,
      portrait_months:Number($("t-length").value),renew_days:Number($("t-renew").value),web:[...document.querySelectorAll('input[name="tweb"]:checked')].map(x=>x.value),
      second_use:$("t-second").value,ai_use:$("t-ai").value,comp_ingredient:$("t-ci").value,comp_effect:$("t-ce").value,
      shoot_fee:$("t-fee").value?Number($("t-fee").value):null,overtime_fee:$("t-ot").value?Number($("t-ot").value):null,nda:$("t-nda").value};
    busy(true);
    let id=editing, error=null;
    if(editing){ ({error}=await sb.from("actors").update(row).eq("id",editing)); }
    else { const r=await sb.from("actors").insert(row).select("id").single(); error=r.error; id=r.data&&r.data.id; }
    if(!error && photoChanged){
      if(pendingPhoto){ const blob=await (await fetch(pendingPhoto)).blob(); const path=id+"/"+Date.now()+".jpg";
        const up=await sb.storage.from("actor-photos").upload(path,blob,{contentType:"image/jpeg",upsert:false});
        if(up.error) error=up.error; else ({error}=await sb.from("actors").update({photo_path:path}).eq("id",id)); }
      else ({error}=await sb.from("actors").update({photo_path:null}).eq("id",id));
    }
    busy(false);
    if(error) return toast("儲存失敗："+errText(error),null);
    toast((editing?"已更新 ":"已新增 ")+id+" "+row.name,null); await reload();
  }
  if(v==="purge" && editing){ const {error}=await sb.from("actors").delete().eq("id",editing);
    if(error) return toast("刪除失敗："+errText(error),null); toast("已刪除 "+editing+"（編號不會再被使用）",null); await reload(); }
  if(v==="del" && editing){ const {error}=await sb.from("actors").update({archived:true}).eq("id",editing);
    if(error) return toast("下架失敗："+errText(error),null); toast("已下架 "+editing+"，資料與編號都會保留",null); await reload(); }
});



/* ================= Supabase：連線、載入、寫入 ================= */
const cfg = window.CASTING_CONFIG || {};
const sb = window.supabase.createClient(cfg.SUPABASE_URL, cfg.SUPABASE_KEY, { auth:{ persistSession:true, autoRefreshToken:true, detectSessionInUrl:true } });
const ROLE_LABEL = { casting:"三根木", agency:"大廣", admin:"管理者" };
const myName = () => profile ? (profile.display_name || profile.email) : "";
function busy(on){ $("loading").classList.toggle("hidden",!on); }
function errText(e){ if(!e) return ""; const m=e.message||String(e); return m.replace(/^.*?:\s*(?=[一-鿿])/,""); }

/* 呼叫資料庫函式；成功後重新載入。opts.quiet：錯誤不跳提示、改由呼叫端處理 */
async function call(fn, args, opts){
  opts=opts||{}; busy(true);
  const { data, error } = await sb.rpc(fn, args);
  if(error){ busy(false); const m=errText(error); if(!opts.quiet) toast(m,null); return opts.quiet ? { error:m } : false; }
  await reload(true); busy(false);
  return opts.quiet ? { data: data ? mapBooking(data,{}) : data } : true;
}

const fmtStamp = iso => { const d=new Date(iso); return (d.getMonth()+1)+"/"+d.getDate()+" "+pad(d.getHours())+":"+pad(d.getMinutes()); };
function mapBooking(r, logs){
  return { id:r.id, shoot:r.shoot_id, cycle:r.cycle_no, date:r.shoot_date, hours:Number(r.hours), actor:r.actor_id, product:r.product, team:r.team||"",
    role:r.role_type, mno:r.material_no||"", title:r.title, place:r.place||"", by:r.booked_by_name||"—", start:r.start_date||"", script:r.script||"",
    note:r.note||"", inv:r.invoice_date||"", status:r.status, length:r.portrait_months, renew:r.renew_days, web:r.web||[], second:r.second_use,
    ai:r.ai_use, ci:r.comp_ingredient, ce:r.comp_effect, fee:r.shoot_fee??"", ot:r.overtime_fee??"", nda:r.nda||"", log:(logs&&logs[r.id])||[],
    cands:(r.cand_dates&&r.cand_dates.length?r.cand_dates.slice():[r.shoot_date]).sort(), lockedAt:r.locked_at||"", lockedBy:r.locked_by_name||"" };
}
function mapLog(l){ return { at:fmtStamp(l.at), who:l.by_name||"", from:l.from_status||"建立", to:l.to_status }; }

async function reload(silent){
  if(!silent) busy(true);
  const [A,B,C,L,D,H] = await Promise.all([
    sb.from("actors").select("*").order("id"),
    sb.from("bookings").select("*").order("id"),
    sb.from("cycles").select("*"),
    sb.from("status_log").select("*").order("at"),
    sb.from("deleted_bookings").select("*").order("deleted_at"),
    sb.from("tw_offdays").select("d")
  ]);
  offdays = new Set(((H&&H.data)||[]).map(x=>x.d));
  const err = A.error||B.error||C.error||L.error||D.error;
  if(err){ if(!silent) busy(false); toast("資料載入失敗："+errText(err),null); return; }
  const logs={}; (L.data||[]).forEach(l=>{ (logs[l.booking_id]=logs[l.booking_id]||[]).push(mapLog(l)); });
  const paths=(A.data||[]).map(a=>a.photo_path).filter(Boolean); let urls={};
  if(paths.length){ const s=await sb.storage.from("actor-photos").createSignedUrls(paths, 60*60*6); (s.data||[]).forEach(x=>{ if(x.signedUrl) urls[x.path]=x.signedUrl; }); }
  actors=(A.data||[]).map(r=>({ id:r.id, name:r.name, gender:r.gender||"", birth:r.birth_ym||"", height:r.height??"", size:r.size||"", status:r.status,
    time:r.avail_time||"", tags:r.tags||[], note:r.note||"", videos:(r.video_links||"").split(/\n/).map(x=>x.trim()).filter(Boolean), archived:!!r.archived, photo:r.photo_path?urls[r.photo_path]||null:null, photo_path:r.photo_path,
    updated:(r.updated_at||"").slice(0,10), terms:{ length:r.portrait_months, renew:r.renew_days, web:r.web||[], second:r.second_use, ai:r.ai_use,
    ci:r.comp_ingredient, ce:r.comp_effect, fee:r.shoot_fee??"", ot:r.overtime_fee??"", nda:r.nda } }));
  bookings=(B.data||[]).map(r=>mapBooking(r,logs));
  (D.data||[]).forEach(d=>{ const r=d.data||{}; const b=mapBooking(r,{}); b.status="已刪除"; b.delReason=d.reason; b.delBy=d.deleted_by_name||""; b.delAt=fmtStamp(d.deleted_at);
    b.log=(r.status_log||[]).map(mapLog); bookings.push(b); });
  cycleInv={}; (C.data||[]).forEach(c=>{ if(c.invoice_date) cycleInv[c.no]=c.invoice_date; });
  if(cyc>maxCycle()) cyc=openCycle();
  if(!silent) busy(false);
  renderAll(); syncForm();
}

/* ================= 登入 ================= */
function showAuth(which){
  $("auth").classList.remove("hidden"); $("app").classList.add("hidden");
  $("login-form").classList.toggle("hidden", which!=="login"); $("pw-form").classList.toggle("hidden", which!=="pw");
}
async function enterApp(){
  const { data:{ user } } = await sb.auth.getUser();
  if(!user){ showAuth("login"); return; }
  const { data:p, error } = await sb.from("profiles").select("*").eq("id",user.id).single();
  if(error||!p){ showAuth("login"); $("l-msg").innerHTML='<div class="msg err">這個帳號還沒有開通，請聯絡管理者。</div>'; await sb.auth.signOut(); return; }
  if(user.user_metadata && user.user_metadata.must_change_pw){ forcePw=true; openPw(); return; }
  profile=p; isAdmin = p.role==="admin";
  role = p.role==="casting" ? "casting" : "agency";
  $("viewswitch").classList.toggle("hidden", !isAdmin);
  $("tab-admin-btn").classList.toggle("hidden", !isAdmin);
  $("who").innerHTML = '<b>'+esc(myName())+'</b>・'+esc(ROLE_LABEL[p.role]||p.role);
  $("auth").classList.add("hidden"); $("app").classList.remove("hidden");
  setRole(role);
  await reload();
  cyc = openCycle(); syncForm("product"); renderAll();
}
let pwMode = /type=(recovery|invite)/.test(location.hash);
let forcePw = false;
function openPw(){
  $("pw-1").value=""; $("pw-2").value=""; $("pw-msg").innerHTML="";
  $("pw-title").textContent = forcePw ? "第一次登入，請設定你自己的密碼" : "設定新密碼";
  $("pw-cancel").classList.toggle("hidden", forcePw || pwMode);
  showAuth("pw");
}
async function boot(){
  sb.auth.onAuthStateChange((ev)=>{ if(ev==="PASSWORD_RECOVERY"){ pwMode=true; openPw(); } if(ev==="SIGNED_OUT"){ profile=null; showAuth("login"); } });
  const { data:{ session } } = await sb.auth.getSession();
  if(session && pwMode){ openPw(); return; }
  if(session) enterApp(); else showAuth("login");
}
$("login-form").addEventListener("submit", async e=>{
  e.preventDefault(); const email=$("l-email").value.trim(), password=$("l-pass").value;
  if(!email||!password){ $("l-msg").innerHTML='<div class="msg err">請輸入 Email 和密碼。</div>'; return; }
  $("l-btn").disabled=true; $("l-msg").innerHTML="";
  const { error } = await sb.auth.signInWithPassword({ email, password }); $("l-btn").disabled=false;
  if(error){ $("l-msg").innerHTML='<div class="msg err">登入失敗：Email 或密碼不正確。</div>'; return; }
  enterApp();
});
$("l-forgot").onclick = async ()=>{
  const email=$("l-email").value.trim(); if(!email){ $("l-msg").innerHTML='<div class="msg err">請先在上面輸入你的 Email。</div>'; return; }
  const { error } = await sb.auth.resetPasswordForEmail(email, { redirectTo: location.origin+location.pathname });
  $("l-msg").innerHTML = error ? '<div class="msg err">寄送失敗：'+esc(errText(error))+'</div>' : '<div class="msg ok">已寄出重設密碼信，請到信箱點連結。</div>';
};
$("pw-form").addEventListener("submit", async e=>{
  e.preventDefault(); const a=$("pw-1").value, b=$("pw-2").value;
  if(a.length<8){ $("pw-msg").innerHTML='<div class="msg err">密碼至少 8 碼。</div>'; return; }
  if(a!==b){ $("pw-msg").innerHTML='<div class="msg err">兩次輸入的密碼不一樣。</div>'; return; }
  const { error } = await sb.auth.updateUser({ password:a, data:{ must_change_pw:false } });
  if(error){ $("pw-msg").innerHTML='<div class="msg err">設定失敗：'+esc(errText(error))+'</div>'; return; }
  pwMode=false; forcePw=false; history.replaceState(null,"",location.pathname); enterApp();
});
$("pw-cancel").onclick = ()=>{ $("auth").classList.add("hidden"); $("app").classList.remove("hidden"); };
$("chpw").onclick = ()=>{ forcePw=false; openPw(); };
$("logout").onclick = async ()=>{ await sb.auth.signOut(); profile=null; actors=[]; bookings=[]; $("l-pass").value=""; $("l-msg").innerHTML=""; showAuth("login"); };
window.addEventListener("focus", ()=>{ if(profile && !document.querySelector("dialog[open]") && !document.querySelector(".oa-edit")) reload(true); });

/* ================= 帳號管理（管理者） ================= */
async function renderAdmin(){
  if(!isAdmin) return;
  const { data, error } = await sb.from("profiles").select("*").order("created_at");
  if(error) return toast("讀取帳號失敗："+errText(error),null);
  profiles=data||[];
  const TEAMS=["","花花組","泡泡組","啾啾組","毛毛組","CRM組","三根木"];
  $("admin-rows").innerHTML = profiles.map(p=>'<tr><td>'+esc(p.email||"")+'</td>'+
    '<td><input type="text" value="'+esc(p.display_name||"")+'" data-f="display_name" data-id="'+p.id+'"></td>'+
    '<td><select data-f="role" data-id="'+p.id+'">'+["agency","casting","admin"].map(r=>'<option value="'+r+'"'+(p.role===r?" selected":"")+'>'+ROLE_LABEL[r]+'</option>').join("")+'</select></td>'+
    '<td><select data-f="team" data-id="'+p.id+'">'+TEAMS.map(t=>'<option'+((p.team||"")===t?" selected":"")+'>'+t+'</option>').join("")+'</select></td>'+
    '<td><button class="btn sm primary" data-save-p="'+p.id+'">儲存</button></td></tr>').join("") || '<tr><td colspan="5" class="note">還沒有帳號。</td></tr>';
}
$("admin-rows").addEventListener("click", async e=>{
  const b=e.target.closest("[data-save-p]"); if(!b) return; const id=b.dataset.saveP; const row={};
  document.querySelectorAll('#admin-rows [data-id="'+id+'"]').forEach(el=>{ row[el.dataset.f]=el.value||null; });
  if(id===profile.id && row.role!=="admin" && !confirmSelfDemote()) return;
  const { error } = await sb.from("profiles").update(row).eq("id",id);
  toast(error?"儲存失敗："+errText(error):"已更新帳號設定",null);
  if(!error && id===profile.id){ enterApp(); } else renderAdmin();
});
function confirmSelfDemote(){ toast("不能把自己的管理者權限拿掉，請請另一位管理者操作。",null); return false; }

/* 啟動：等登入完成後才載入資料 */
boot();

})();
