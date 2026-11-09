-- 002：欄位調整（接案狀態改名、演員下架不刪除、素材管理編號、腳本、OA 日）
-- 已執行過 schema.sql 的資料庫，在 SQL Editor 執行本檔一次即可。全新安裝直接執行 schema.sql，不用跑這個。

alter table public.actors drop constraint if exists actors_status_check;
update public.actors set status = '暫停接案' where status = '暫停';
alter table public.actors add constraint actors_status_check check (status in ('可接案','暫停接案'));
alter table public.actors add column if not exists archived boolean not null default false;

drop policy if exists "Casting 刪除演員" on public.actors;
revoke delete on public.actors from authenticated;

alter table public.bookings add column if not exists material_no text;
alter table public.bookings add column if not exists script text;
comment on column public.bookings.start_date is '本素材合約開始日（OA日）';

drop function if exists public.create_booking(text,date,numeric,text,text,text,text,text,date,date,text,boolean);
create function public.create_booking(
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
    select 'SH-' || v_yymm || '-' || lpad((count(distinct shoot_id) + 1)::text, 2, '0') into v_shoot
      from bookings where shoot_id like 'SH-' || v_yymm || '-%';
  end if;
  select 'BK-' || v_yymm || '-' || lpad((count(*) + 1)::text, 2, '0') into v_id
    from bookings where id like 'BK-' || v_yymm || '-%';

  insert into bookings (id, shoot_id, cycle_no, actor_id, shoot_date, hours, product, team, role_type, material_no, title,
                        place, booked_by_name, first_start, start_date, script, portrait_months, renew_days, web,
                        second_use, ai_use, comp_ingredient, comp_effect, shoot_fee, overtime_fee, nda, note)
  values (v_id, v_shoot, v_cycle, p_actor, p_date, p_hours, p_product, p_team, p_role, p_material_no, p_title,
          p_place, (select coalesce(display_name, email) from profiles where id = auth.uid()),
          coalesce((select min(start_date) from bookings where actor_id = p_actor and product = p_product and status <> '已取消'), p_start),
          p_start, p_script, a.portrait_months, a.renew_days, a.web,
          a.second_use, a.ai_use, a.comp_ingredient, a.comp_effect,
          coalesce(ex.shoot_fee, a.shoot_fee), coalesce(ex.overtime_fee, a.overtime_fee), a.nda, p_note)
  returning * into r;
  perform log_status(r.id, null, '待確認');
  return r;
end $$;

revoke execute on function public.create_booking(text,date,numeric,text,text,text,text,text,text,date,text,text,boolean) from anon, public;
grant execute on function public.create_booking(text,date,numeric,text,text,text,text,text,text,date,text,text,boolean) to authenticated;
