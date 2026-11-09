-- 007：刪除預約（必填原因），刪除的預約另存在 deleted_bookings
-- 已執行過 001–006 的資料庫執行本檔一次即可。全新安裝直接執行 schema.sql，不用跑這個。

-- 刪除的預約：從 bookings 移到這裡保存（含刪除原因與當時的狀態紀錄），不影響人次與契約一覽
create table public.deleted_bookings (
  id              text primary key,
  data            jsonb not null,
  reason          text not null,
  deleted_by      uuid default auth.uid(),
  deleted_by_name text,
  deleted_at      timestamptz not null default now()
);
alter table public.deleted_bookings enable row level security;
create policy "登入者可看已刪除" on public.deleted_bookings for select to authenticated using (true);
grant select on public.deleted_bookings to authenticated;

-- ---------- 刪除預約（大廣，必填原因；已拍攝或已請款不能刪） ----------
create function public.delete_booking(p_id text, p_reason text)
returns void language plpgsql security definer set search_path = public as $$
declare b bookings; v_log jsonb;
begin
  if my_role() not in ('agency','admin') then raise exception '只有大廣帳號可以刪除預約'; end if;
  if coalesce(length(trim(p_reason)),0) < 2 then raise exception '請填寫刪除原因'; end if;
  perform pg_advisory_xact_lock(hashtext('casting-booking'));
  select * into b from bookings where id = p_id for update;
  if not found then raise exception '找不到這筆預約'; end if;
  if b.status = '已拍攝' or is_invoiced(b.cycle_no) then raise exception '已拍攝或已請款的素材不能刪除'; end if;
  select coalesce(jsonb_agg(to_jsonb(l) order by l.at), '[]'::jsonb) into v_log from status_log l where l.booking_id = p_id;
  insert into deleted_bookings (id, data, reason, deleted_by_name)
  values (p_id, to_jsonb(b) || jsonb_build_object('status_log', v_log), trim(p_reason),
          (select coalesce(display_name, email) from profiles where id = auth.uid()));
  delete from status_log where booking_id = p_id;
  delete from bookings where id = p_id;
end $$;

-- 預約編號改用「最大號＋1」，刪除過的號碼不會重複使用
create or replace function public.create_booking(
  p_actor text, p_date date, p_hours numeric, p_product text, p_team text,
  p_role text, p_material_no text, p_title text, p_place text, p_start date,
  p_script text, p_note text, p_overtime_ok boolean default false
) returns public.bookings
language plpgsql security definer set search_path = public as $$
declare
  a actors; ex bookings; v_shoot text; v_cycle int; v_id text; v_yymm text;
  v_hours numeric; v_koc text; r bookings;
begin
  if my_role() not in ('agency','admin') then raise exception '只有大廣帳號可以預約'; end if;
  perform pg_advisory_xact_lock(hashtext('casting-booking'));   -- 避免兩人同時預約搶到同一號碼

  select * into a from actors where id = p_actor;
  if not found then raise exception '找不到這位演員'; end if;
  if a.status <> '可接案' or a.archived then raise exception '% 目前暫停接案', a.name; end if;

  v_koc := koc_conflict(p_actor, p_product, p_date);
  if p_role = 'KOC' and v_koc is not null then
    raise exception '% 已幫 % 拍 KOC，合約期間內不能再幫 % 拍 KOC，可以改成情境演員', a.name, v_koc, p_product;
  end if;

  select * into ex from bookings
   where actor_id = p_actor and shoot_date = p_date and status <> '已取消' limit 1;

  select coalesce(sum(hours),0) into v_hours from bookings
   where actor_id = p_actor and shoot_date = p_date and status <> '已取消';
  if v_hours + p_hours > 6 and not p_overtime_ok then
    raise exception '這場加總 % 小時，超過當天上限 6 小時，請縮短時數或先和 Casting 確認超時', v_hours + p_hours;
  end if;

  if ex.id is not null and exists(select 1 from bookings where shoot_id = ex.shoot_id and status <> '已取消'
                                    and product = p_product and title = p_title) then
    raise exception '同一場拍攝已登記過「%」', p_title;
  end if;

  v_yymm := to_char(p_date, 'YYMM');
  if ex.id is not null then
    v_shoot := ex.shoot_id; v_cycle := ex.cycle_no;
    -- 已確認的場次加了新素材，要請 Casting 重新確認時數
    update bookings set status = '待確認' where shoot_id = v_shoot and status = '已確認';
  else
    v_cycle := open_cycle();
    select 'SH-' || v_yymm || '-' || lpad((coalesce(max(substring(shoot_id from '[0-9]+$')::int), 0) + 1)::text, 2, '0') into v_shoot
      from bookings where shoot_id like 'SH-' || v_yymm || '-%';
  end if;
  select 'BK-' || v_yymm || '-' || lpad((coalesce(max(substring(x from '[0-9]+$')::int), 0) + 1)::text, 2, '0') into v_id
    from (select id as x from bookings union all select id from deleted_bookings) ids
   where x like 'BK-' || v_yymm || '-%';             -- 最大號＋1：刪除過的編號也不會重複使用

  insert into bookings (id, shoot_id, cycle_no, actor_id, shoot_date, hours, product, team, role_type, material_no, title,
                        place, booked_by_name, first_start, start_date, script, portrait_months, renew_days, web,
                        second_use, ai_use, comp_ingredient, comp_effect, shoot_fee, overtime_fee, nda, note)
  values (v_id, v_shoot, v_cycle, p_actor, p_date, p_hours, p_product, p_team, p_role, p_material_no, p_title,
          p_place, (select coalesce(display_name, email) from profiles where id = auth.uid()),
          coalesce((select min(start_date) from bookings where actor_id = p_actor and product = p_product and status <> '已取消' and start_date is not null), p_start),
          p_start, p_script, a.portrait_months, a.renew_days, a.web,
          a.second_use, a.ai_use, a.comp_ingredient, a.comp_effect,
          coalesce(ex.shoot_fee, a.shoot_fee), coalesce(ex.overtime_fee, a.overtime_fee), a.nda, p_note)
  returning * into r;
  perform log_status(r.id, null, '待確認');
  return r;
end $$;

revoke execute on function public.delete_booking(text,text) from anon, public;
grant execute on function public.delete_booking(text,text) to authenticated;
