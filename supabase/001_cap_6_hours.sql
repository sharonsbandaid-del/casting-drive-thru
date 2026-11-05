-- 修正：拍攝當天上限由 6.5 小時改為 6 小時。
-- 若已執行過 schema.sql，只要在 SQL Editor 執行本檔一次即可。

create or replace function public.create_booking(
  p_actor text, p_date date, p_hours numeric, p_product text, p_team text,
  p_role text, p_title text, p_place text, p_first date, p_start date,
  p_note text, p_overtime_ok boolean default false
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
  if a.status <> '可接案' then raise exception '% 目前暫停接案', a.name; end if;

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

  insert into bookings (id, shoot_id, cycle_no, actor_id, shoot_date, hours, product, team, role_type, title,
                        place, booked_by_name, first_start, start_date, portrait_months, renew_days, web,
                        second_use, ai_use, comp_ingredient, comp_effect, shoot_fee, overtime_fee, nda, note)
  values (v_id, v_shoot, v_cycle, p_actor, p_date, p_hours, p_product, p_team, p_role, p_title,
          p_place, (select coalesce(display_name, email) from profiles where id = auth.uid()),
          coalesce(p_first, p_start), p_start, a.portrait_months, a.renew_days, a.web,
          a.second_use, a.ai_use, a.comp_ingredient, a.comp_effect,
          coalesce(ex.shoot_fee, a.shoot_fee), coalesce(ex.overtime_fee, a.overtime_fee), a.nda, p_note)
  returning * into r;
  perform log_status(r.id, null, '待確認');
  return r;
end $$;

create or replace function public.set_booking_cancelled(p_id text, p_cancel boolean)
returns public.bookings language plpgsql security definer set search_path = public as $$
declare b bookings; live_shoot text; v_hours numeric; v_koc text;
begin
  if my_role() not in ('agency','admin') then raise exception '只有大廣帳號可以取消或恢復素材'; end if;
  perform pg_advisory_xact_lock(hashtext('casting-booking'));
  select * into b from bookings where id = p_id for update;
  if not found then raise exception '找不到這筆預約'; end if;

  if p_cancel then
    if b.status not in ('待確認','已確認') then raise exception '只有待確認或已確認的素材可以取消'; end if;
    update bookings set status = '已取消' where id = p_id returning * into b;
    perform log_status(p_id, '待確認/已確認', '已取消');
  else
    if b.status <> '已取消' then raise exception '這支素材沒有被取消'; end if;
    v_koc := koc_conflict(b.actor_id, b.product, b.shoot_date, b.id);
    if b.role_type = 'KOC' and v_koc is not null then raise exception '這位演員已綁 % 的 KOC，無法恢復', v_koc; end if;
    select coalesce(sum(hours),0) into v_hours from bookings
     where actor_id = b.actor_id and shoot_date = b.shoot_date and status <> '已取消';
    if v_hours + b.hours > 6 then raise exception '恢復後這場會超過 6 小時，請先和 Casting 確認'; end if;
    select shoot_id into live_shoot from bookings
     where actor_id = b.actor_id and shoot_date = b.shoot_date and status <> '已取消' limit 1;
    if live_shoot is not null then
      update bookings set status = '待確認',
             cycle_no = (select cycle_no from bookings where shoot_id = live_shoot and status <> '已取消' limit 1)
       where id = p_id returning * into b;
    elsif is_invoiced(b.cycle_no) or cycle_count(b.cycle_no) >= 7 then
      update bookings set status = '待確認', cycle_no = open_cycle() where id = p_id returning * into b;
    else
      update bookings set status = '待確認' where id = p_id returning * into b;
    end if;
    perform log_status(p_id, '已取消', '待確認');
  end if;
  return b;
end $$;
