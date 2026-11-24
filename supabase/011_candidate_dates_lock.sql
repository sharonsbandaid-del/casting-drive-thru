-- ============================================================
-- 011：候選日期（最多 3 個）＋ 鎖定日期 ＋ 10 個工作天規則
--   • 預約時填 1～3 個候選日，狀態「待確認」＝尚未鎖定
--   • 大廣或 Casting 從候選日中「鎖定」一天 → 狀態「已確認」
--   • 同一演員、相同候選日的未鎖定預約＝同一場（先佔 1 人次）
--   • 鎖定時才判斷：併入那天已鎖定的場次、6 小時上限、KOC 衝突
--   • 候選日最早只能選 10 個工作天後（管理者不受限）
-- 可以重複執行
-- ============================================================

-- ---------- 欄位 ----------
alter table public.bookings add column if not exists cand_dates     date[];
alter table public.bookings add column if not exists locked_at      timestamptz;
alter table public.bookings add column if not exists locked_by_name text;
update public.bookings set cand_dates = array[shoot_date] where cand_dates is null;
update public.bookings set locked_at = created_at where status in ('已確認','已拍攝') and locked_at is null;
alter table public.bookings alter column cand_dates set not null;

-- ---------- 國定假日（週末以外的放假日）----------
create table if not exists public.tw_offdays (d date primary key, label text not null);
insert into public.tw_offdays (d, label) values
  ('2026-01-01','元旦'),('2026-02-16','春節'),('2026-02-17','春節'),('2026-02-18','春節'),('2026-02-19','春節'),('2026-02-20','春節'),
  ('2026-02-27','和平紀念日補假'),('2026-04-03','兒童節補假'),('2026-04-06','清明節補假'),('2026-05-01','勞動節'),
  ('2026-06-19','端午節'),('2026-09-25','中秋節'),('2026-09-28','教師節'),('2026-10-09','國慶日補假'),
  ('2026-10-26','光復節補假'),('2026-12-25','行憲紀念日'),
  ('2027-01-01','元旦'),('2027-02-04','春節'),('2027-02-05','春節'),('2027-02-08','春節'),('2027-02-09','春節'),('2027-02-10','春節'),
  ('2027-03-01','和平紀念日補假'),('2027-04-05','清明節'),('2027-04-06','兒童節補假'),('2027-04-30','勞動節補假'),
  ('2027-06-09','端午節'),('2027-09-15','中秋節'),('2027-09-28','教師節'),('2027-10-11','國慶日補假'),
  ('2027-10-25','光復節'),('2027-12-24','行憲紀念日補假'),('2027-12-31','元旦補假')
on conflict (d) do nothing;
alter table public.tw_offdays enable row level security;
drop policy if exists "登入者可看假日" on public.tw_offdays;
create policy "登入者可看假日" on public.tw_offdays for select to authenticated using (true);
grant select on public.tw_offdays to authenticated;

create or replace function public.is_workday(p date) returns boolean
language sql stable security definer set search_path = public as $$
  select extract(isodow from p) < 6 and not exists(select 1 from tw_offdays where d = p)
$$;

-- p 之後第 n 個工作天
create or replace function public.add_workdays(p date, n int) returns date
language plpgsql stable security definer set search_path = public as $$
declare d date := p; k int := 0;
begin
  while k < n loop d := d + 1; if is_workday(d) then k := k + 1; end if; end loop;
  return d;
end $$;

-- 小工具：整理候選日（去重、排序、去掉空白）
create or replace function public.norm_dates(p date[]) returns date[]
language sql immutable as $$
  select array_agg(distinct x order by x) from unnest(p) x where x is not null
$$;

create or replace function public.check_cand_dates(v date[]) returns void
language plpgsql stable security definer set search_path = public as $$
declare v_min date := add_workdays(today_tw(), 10);
begin
  if v is null or coalesce(array_length(v,1),0) = 0 then raise exception '請至少選 1 個拍攝日期'; end if;
  if array_length(v,1) > 3 then raise exception '候選日期最多 3 個'; end if;
  if my_role() <> 'admin' and v[1] < v_min then
    raise exception '拍攝日期最早只能選 %（10 個工作天後），才來得及辦理保險', to_char(v_min, 'YYYY/MM/DD');
  end if;
end $$;

-- ---------- 預約（大廣）：候選日期 ----------
drop function if exists public.create_booking(text,date,numeric,text,text,text,text,text,text,date,text,text,boolean);
create or replace function public.create_booking(
  p_actor text, p_dates date[], p_hours numeric, p_product text, p_team text,
  p_role text, p_material_no text, p_title text, p_place text, p_start date,
  p_script text, p_note text, p_overtime_ok boolean default false
) returns public.bookings
language plpgsql security definer set search_path = public as $$
declare
  a actors; ex bookings; v_dates date[]; v_shoot text; v_cycle int; v_id text; v_yymm text;
  v_hours numeric := 0; d date; n_ok int := 0; r bookings;
begin
  if my_role() not in ('agency','admin') then raise exception '只有大廣帳號可以預約'; end if;
  perform pg_advisory_xact_lock(hashtext('casting-booking'));
  v_dates := norm_dates(p_dates);
  perform check_cand_dates(v_dates);

  select * into a from actors where id = p_actor;
  if not found then raise exception '找不到這位演員'; end if;
  if a.status <> '可接案' or a.archived then raise exception '% 目前暫停接案', a.name; end if;

  if p_role = 'KOC' then
    foreach d in array v_dates loop if koc_conflict(p_actor, p_product, d) is null then n_ok := n_ok + 1; end if; end loop;
    if n_ok = 0 then
      raise exception '% 已幫 % 拍 KOC，合約期間內不能再幫 % 拍 KOC，可以改成情境演員', a.name, koc_conflict(p_actor, p_product, v_dates[1]), p_product;
    end if;
  end if;

  -- 同一位演員、相同候選日、還沒鎖定 → 同一場
  select * into ex from bookings where actor_id = p_actor and status = '待確認' and cand_dates = v_dates limit 1;
  if ex.id is not null then
    select coalesce(sum(hours),0) into v_hours from bookings where shoot_id = ex.shoot_id and status <> '已取消';
    if exists(select 1 from bookings where shoot_id = ex.shoot_id and status <> '已取消' and product = p_product and title = p_title) then
      raise exception '同一場拍攝已登記過「%」', p_title;
    end if;
  end if;
  if v_hours + p_hours > 6 and not p_overtime_ok then
    raise exception '這場加總 % 小時，超過當天上限 6 小時，請縮短時數或先和 Casting 確認超時', v_hours + p_hours;
  end if;

  v_yymm := to_char(v_dates[1], 'YYMM');
  if ex.id is not null then
    v_shoot := ex.shoot_id; v_cycle := ex.cycle_no;
  else
    v_cycle := open_cycle();
    select 'SH-' || v_yymm || '-' || lpad((coalesce(max(substring(shoot_id from '[0-9]+$')::int), 0) + 1)::text, 2, '0') into v_shoot
      from bookings where shoot_id like 'SH-' || v_yymm || '-%';
  end if;
  select 'BK-' || v_yymm || '-' || lpad((coalesce(max(substring(x from '[0-9]+$')::int), 0) + 1)::text, 2, '0') into v_id
    from (select id as x from bookings union all select id from deleted_bookings) ids
   where x like 'BK-' || v_yymm || '-%';

  insert into bookings (id, shoot_id, cycle_no, actor_id, shoot_date, cand_dates, hours, product, team, role_type, material_no, title,
                        place, booked_by_name, first_start, start_date, script, portrait_months, renew_days, web,
                        second_use, ai_use, comp_ingredient, comp_effect, shoot_fee, overtime_fee, nda, note)
  values (v_id, v_shoot, v_cycle, p_actor, v_dates[1], v_dates, p_hours, p_product, p_team, p_role, p_material_no, p_title,
          p_place, (select coalesce(display_name, email) from profiles where id = auth.uid()),
          coalesce((select min(start_date) from bookings where actor_id = p_actor and product = p_product and status <> '已取消' and start_date is not null), p_start),
          p_start, p_script, a.portrait_months, a.renew_days, a.web,
          a.second_use, a.ai_use, a.comp_ingredient, a.comp_effect,
          coalesce(ex.shoot_fee, a.shoot_fee), coalesce(ex.overtime_fee, a.overtime_fee), a.nda, p_note)
  returning * into r;
  perform log_status(r.id, null, '待確認');
  return r;
end $$;

-- ---------- 鎖定日期（大廣或 Casting，以整場為單位） ----------
create or replace function public.lock_shoot(p_shoot text, p_date date, p_overtime_ok boolean default false)
returns void language plpgsql security definer set search_path = public as $$
declare v_actor text; v_cands date[]; v_target bookings; v_total numeric; v_koc text; x record; v_name text;
begin
  if my_role() not in ('agency','casting','admin') then raise exception '沒有權限鎖定日期'; end if;
  perform pg_advisory_xact_lock(hashtext('casting-booking'));
  if exists(select 1 from bookings where shoot_id = p_shoot and status in ('已確認','已拍攝')) then raise exception '這場已經鎖定了'; end if;
  select min(actor_id) into v_actor from bookings where shoot_id = p_shoot and status = '待確認';
  if v_actor is null then raise exception '找不到這場拍攝'; end if;
  select array_agg(distinct c order by c) into v_cands from bookings, unnest(cand_dates) c where shoot_id = p_shoot and status = '待確認';
  if not (p_date = any(v_cands)) then raise exception '請從候選日期中選一天；要改成其他日期，請先「改期」'; end if;

  for x in select * from bookings where shoot_id = p_shoot and status = '待確認' and role_type = 'KOC' loop
    v_koc := koc_conflict(x.actor_id, x.product, p_date, x.id);
    if v_koc is not null then raise exception '這位演員在 % 已綁 % 的 KOC，請選其他候選日', to_char(p_date,'MM/DD'), v_koc; end if;
  end loop;

  select * into v_target from bookings
   where actor_id = v_actor and shoot_date = p_date and status in ('已確認','已拍攝') and shoot_id <> p_shoot limit 1;
  if v_target.status = '已拍攝' then raise exception '這位演員 % 那場已拍攝完成，請選其他候選日', to_char(p_date,'MM/DD'); end if;

  select coalesce(sum(hours),0) into v_total from bookings
   where status <> '已取消' and (shoot_id = p_shoot or shoot_id = v_target.shoot_id);
  if v_total > 6 and not p_overtime_ok then
    raise exception '% 這天加總 % 小時，超過上限 6 小時，請先和 Casting 確認超時', to_char(p_date,'MM/DD'), v_total;
  end if;

  v_name := (select coalesce(display_name, email) from profiles where id = auth.uid());
  for x in select id from bookings where shoot_id = p_shoot and status = '待確認' loop
    update bookings set shoot_date = p_date, status = '已確認', locked_at = now(), locked_by_name = v_name,
           shoot_id = coalesce(v_target.shoot_id, p_shoot), cycle_no = coalesce(v_target.cycle_no, cycle_no)
     where id = x.id;
    perform log_status(x.id, '待確認', '已確認（鎖定 ' || to_char(p_date,'MM/DD') || '）');
  end loop;
end $$;

-- ---------- 改期（大廣）：重新給候選日，解除鎖定 ----------
create or replace function public.set_candidates(p_ids text[], p_dates date[], p_overtime_ok boolean default false)
returns void language plpgsql security definer set search_path = public as $$
declare
  v_dates date[]; v_actor text; v_n int; v_nact int; v_src text; v_nsrc int; v_srccyc int;
  ex bookings; v_shoot text; v_cycle int; v_total numeric; v_yymm text; x record; n_ok int; d date;
begin
  if my_role() not in ('agency','admin') then raise exception '只有大廣帳號可以改期'; end if;
  perform pg_advisory_xact_lock(hashtext('casting-booking'));
  v_dates := norm_dates(p_dates);
  perform check_cand_dates(v_dates);

  select count(*), count(distinct actor_id), min(actor_id), count(distinct shoot_id), min(shoot_id), min(cycle_no)
    into v_n, v_nact, v_actor, v_nsrc, v_src, v_srccyc from bookings where id = any(p_ids);
  if v_n = 0 or v_n <> coalesce(array_length(p_ids,1),0) then raise exception '找不到要改期的預約'; end if;
  if v_nact > 1 then raise exception '一次只能改同一位演員的預約'; end if;
  if exists(select 1 from bookings where id = any(p_ids) and (status not in ('待確認','已確認') or is_invoiced(cycle_no))) then
    raise exception '已拍攝、已取消或已請款的素材不能改期';
  end if;

  for x in select * from bookings where id = any(p_ids) and role_type = 'KOC' loop
    n_ok := 0;
    foreach d in array v_dates loop if koc_conflict(x.actor_id, x.product, d, x.id) is null then n_ok := n_ok + 1; end if; end loop;
    if n_ok = 0 then raise exception '「%」是 KOC，這些日期這位演員都已綁其他商品的 KOC', x.title; end if;
  end loop;

  select * into ex from bookings
   where actor_id = v_actor and status = '待確認' and cand_dates = v_dates and not (id = any(p_ids)) limit 1;
  if ex.id is not null then
    v_shoot := ex.shoot_id; v_cycle := ex.cycle_no;                          -- 併入相同候選日的那一場
  elsif v_nsrc = 1 and not exists(select 1 from bookings where shoot_id = v_src and status <> '已取消' and not (id = any(p_ids))) then
    v_shoot := v_src; v_cycle := v_srccyc;                                   -- 整場改期：編號與期數不變
  else
    v_yymm := to_char(v_dates[1], 'YYMM');                                   -- 拆出來自成一場
    select 'SH-' || v_yymm || '-' || lpad((coalesce(max(substring(shoot_id from '[0-9]+$')::int), 0) + 1)::text, 2, '0') into v_shoot
      from bookings where shoot_id like 'SH-' || v_yymm || '-%';
    v_cycle := case when is_invoiced(v_srccyc) or cycle_count(v_srccyc) >= 7 then open_cycle() else v_srccyc end;
  end if;

  select coalesce(sum(hours),0) into v_total from bookings
   where status <> '已取消' and (id = any(p_ids) or (ex.id is not null and shoot_id = ex.shoot_id));
  if v_total > 6 and not p_overtime_ok then raise exception '這場加總 % 小時，超過當天上限 6 小時', v_total; end if;

  for x in select id, status from bookings where id = any(p_ids) loop
    update bookings set cand_dates = v_dates, shoot_date = v_dates[1], status = '待確認', shoot_id = v_shoot, cycle_no = v_cycle,
           locked_at = null, locked_by_name = null
     where id = x.id;
    perform log_status(x.id, x.status, '改期・候選 ' || array_to_string(array(select to_char(z,'MM/DD') from unnest(v_dates) z), '/'));
  end loop;
end $$;

-- ---------- 修改預約內容：拍攝日改用「改期」 ----------
create or replace function public.update_booking(
  p_id text, p_material_no text, p_title text, p_role text, p_hours numeric, p_place text,
  p_team text, p_start date, p_script text, p_note text,
  p_date date default null, p_move_all boolean default false, p_overtime_ok boolean default false
) returns public.bookings language plpgsql security definer set search_path = public as $$
declare b bookings; v_koc text; v_total numeric; r bookings;
begin
  if my_role() not in ('agency','admin') then raise exception '只有大廣帳號可以修改預約'; end if;
  perform pg_advisory_xact_lock(hashtext('casting-booking'));
  select * into b from bookings where id = p_id for update;
  if not found then raise exception '找不到這筆預約'; end if;
  if b.status = '已取消' then raise exception '已取消的素材不能修改，請先恢復'; end if;
  if coalesce(trim(p_title),'') = '' then raise exception '請填寫素材篇名'; end if;
  if p_date is not null and p_date <> b.shoot_date then raise exception '拍攝日期請用「改期」修改'; end if;
  if (b.status = '已拍攝' or is_invoiced(b.cycle_no)) and (p_role is distinct from b.role_type or p_hours is distinct from b.hours) then
    raise exception '已拍攝或已請款的素材，時數與拍攝需求不能修改';
  end if;
  if p_role = 'KOC' and b.role_type <> 'KOC' then
    v_koc := koc_conflict(b.actor_id, b.product, b.shoot_date, b.id);
    if v_koc is not null then raise exception '這位演員已綁 % 的 KOC，不能改成 KOC', v_koc; end if;
  end if;
  select coalesce(sum(hours),0) + p_hours into v_total from bookings where shoot_id = b.shoot_id and id <> b.id and status <> '已取消';
  if v_total > 6 and not p_overtime_ok then raise exception '這場加總 % 小時，超過當天上限 6 小時', v_total; end if;

  update bookings set material_no = p_material_no, title = p_title, role_type = p_role, hours = p_hours,
         place = p_place, team = p_team, start_date = p_start, script = p_script, note = p_note
   where id = p_id returning * into r;
  perform log_status(p_id, '內容', '修改');
  return r;
end $$;

-- ---------- 取消／恢復素材 ----------
create or replace function public.set_booking_cancelled(p_id text, p_cancel boolean)
returns public.bookings language plpgsql security definer set search_path = public as $$
declare b bookings; v_koc text; v_target bookings; v_hours numeric; v_shoot text; v_cycle int; v_yymm text;
begin
  if my_role() not in ('agency','admin') then raise exception '只有大廣帳號可以取消或恢復素材'; end if;
  perform pg_advisory_xact_lock(hashtext('casting-booking'));
  select * into b from bookings where id = p_id for update;
  if not found then raise exception '找不到這筆預約'; end if;

  if p_cancel then
    if b.status not in ('待確認','已確認') then raise exception '只有待確認或已確認的素材可以取消'; end if;
    update bookings set status = '已取消' where id = p_id returning * into b;
    perform log_status(p_id, '待確認/已確認', '已取消');
    return b;
  end if;

  if b.status <> '已取消' then raise exception '這支素材沒有被取消'; end if;
  v_koc := koc_conflict(b.actor_id, b.product, b.shoot_date, b.id);
  if b.role_type = 'KOC' and v_koc is not null then raise exception '這位演員已綁 % 的 KOC，無法恢復', v_koc; end if;

  -- 取消前已鎖定：回到那天已鎖定的場次
  if b.locked_at is not null then
    select * into v_target from bookings where actor_id = b.actor_id and shoot_date = b.shoot_date and status = '已確認' limit 1;
  end if;
  if v_target.id is not null then
    select coalesce(sum(hours),0) into v_hours from bookings where shoot_id = v_target.shoot_id and status <> '已取消';
    if v_hours + b.hours > 6 then raise exception '恢復後這場會超過 6 小時，請先和 Casting 確認'; end if;
    update bookings set status = '已確認', shoot_id = v_target.shoot_id, cycle_no = v_target.cycle_no where id = p_id returning * into b;
    perform log_status(p_id, '已取消', '已確認');
    return b;
  end if;

  -- 其他情況：回到「待確認」，和相同候選日的未鎖定場次合併，否則自成一場（需重新鎖定）
  select * into v_target from bookings where actor_id = b.actor_id and status = '待確認' and cand_dates = b.cand_dates limit 1;
  if v_target.id is not null then
    v_shoot := v_target.shoot_id; v_cycle := v_target.cycle_no;
    select coalesce(sum(hours),0) into v_hours from bookings where shoot_id = v_shoot and status <> '已取消';
    if v_hours + b.hours > 6 then raise exception '恢復後這場會超過 6 小時，請先和 Casting 確認'; end if;
  elsif not exists(select 1 from bookings where shoot_id = b.shoot_id and status <> '已取消') then
    v_shoot := b.shoot_id;
    v_cycle := case when is_invoiced(b.cycle_no) or cycle_count(b.cycle_no) >= 7 then open_cycle() else b.cycle_no end;
  else
    v_yymm := to_char(b.shoot_date, 'YYMM');
    select 'SH-' || v_yymm || '-' || lpad((coalesce(max(substring(shoot_id from '[0-9]+$')::int), 0) + 1)::text, 2, '0') into v_shoot
      from bookings where shoot_id like 'SH-' || v_yymm || '-%';
    v_cycle := case when is_invoiced(b.cycle_no) or cycle_count(b.cycle_no) >= 7 then open_cycle() else b.cycle_no end;
  end if;
  update bookings set status = '待確認', shoot_id = v_shoot, cycle_no = v_cycle, locked_at = null, locked_by_name = null
   where id = p_id returning * into b;
  perform log_status(p_id, '已取消', '待確認');
  return b;
end $$;

-- ---------- 檔期狀態（以整場為單位）：鎖定改用 lock_shoot ----------
create or replace function public.set_shoot_status(p_shoot text, p_to text)
returns void language plpgsql security definer set search_path = public as $$
declare cur text; d date; cyc int; r record;
begin
  if my_role() not in ('casting','admin') and not (my_role() = 'agency' and p_to = '待確認') then
    raise exception '只有 Casting 帳號可以變更檔期狀態';
  end if;
  select min(shoot_date), min(cycle_no) into d, cyc from bookings where shoot_id = p_shoot and status <> '已取消';
  if d is null then raise exception '找不到這場拍攝'; end if;
  select case when bool_or(status = '待確認') then '待確認'
              when bool_and(status = '已拍攝') then '已拍攝' else '已確認' end
    into cur from bookings where shoot_id = p_shoot and status <> '已取消';

  if not ((cur = '已確認' and p_to in ('已拍攝','待確認')) or (cur = '已拍攝' and p_to = '已確認')) then
    raise exception '無法從「%」改成「%」', cur, p_to;
  end if;
  if p_to = '已拍攝' and d > today_tw() then raise exception '拍攝日當天之後才能標記已拍攝'; end if;
  if cur = '已拍攝' and is_invoiced(cyc) then raise exception '這一期已請款，需先由管理者撤銷請款'; end if;

  for r in select id, status from bookings where shoot_id = p_shoot and status <> '已取消' and status <> p_to loop
    if p_to = '待確認' then
      update bookings set status = p_to, locked_at = null, locked_by_name = null where id = r.id;   -- 解除鎖定，候選日保留
    else
      update bookings set status = p_to where id = r.id;
    end if;
    perform log_status(r.id, r.status, p_to);
  end loop;
end $$;

-- ---------- 權限 ----------
revoke execute on function public.is_workday(date), public.add_workdays(date,int), public.norm_dates(date[]), public.check_cand_dates(date[]) from anon, public;
revoke execute on function public.create_booking(text,date[],numeric,text,text,text,text,text,text,date,text,text,boolean),
  public.lock_shoot(text,date,boolean), public.set_candidates(text[],date[],boolean) from anon, public;
grant execute on function
  public.create_booking(text,date[],numeric,text,text,text,text,text,text,date,text,text,boolean),
  public.lock_shoot(text,date,boolean), public.set_candidates(text[],date[],boolean),
  public.is_workday(date), public.add_workdays(date,int) to authenticated;
