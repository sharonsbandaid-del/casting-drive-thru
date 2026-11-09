-- 005：預約可改拍攝日（可整場改期）、契約一覽可個別修改發票日期
-- 已執行過 001–004 的資料庫執行本檔一次即可。全新安裝直接執行 schema.sql，不用跑這個。
alter table public.bookings add column if not exists invoice_date date;
drop function if exists public.update_booking(text,text,text,text,numeric,text,text,date,text,text,boolean);
create function public.update_booking(
  p_id text, p_material_no text, p_title text, p_role text, p_hours numeric, p_place text,
  p_team text, p_start date, p_script text, p_note text,
  p_date date default null, p_move_all boolean default true, p_overtime_ok boolean default false
) returns public.bookings language plpgsql security definer set search_path = public as $$
declare
  b bookings; v_koc text; v_locked boolean; r bookings; v_date date; v_changed boolean;
  v_ids text[]; v_target bookings; v_total numeric; v_shoot text; v_cycle int; v_yymm text; x record;
begin
  if my_role() not in ('agency','admin') then raise exception '只有大廣帳號可以修改預約'; end if;
  perform pg_advisory_xact_lock(hashtext('casting-booking'));
  select * into b from bookings where id = p_id for update;
  if not found then raise exception '找不到這筆預約'; end if;
  if b.status = '已取消' then raise exception '已取消的素材不能修改，請先恢復'; end if;
  if coalesce(trim(p_title),'') = '' then raise exception '請填寫素材篇名'; end if;
  v_date := coalesce(p_date, b.shoot_date);
  v_changed := v_date <> b.shoot_date;
  v_locked := b.status = '已拍攝' or is_invoiced(b.cycle_no);
  if v_locked and (p_role is distinct from b.role_type or p_hours is distinct from b.hours or v_changed) then
    raise exception '已拍攝或已請款的素材，拍攝日期、時數與拍攝需求不能修改';
  end if;

  -- 這次要移動的素材：整場改期＝同場全部；否則只有這一支
  if v_changed and p_move_all then
    select array_agg(id) into v_ids from bookings where shoot_id = b.shoot_id and status <> '已取消';
  else
    v_ids := array[b.id];
  end if;

  -- KOC 檢查（移動的每一支）
  for x in select * from bookings where id = any(v_ids) loop
    if (case when x.id = b.id then p_role else x.role_type end) = 'KOC' then
      select product into v_koc from bookings
       where actor_id = x.actor_id and role_type = 'KOC' and status <> '已取消' and product <> x.product
         and not (id = any(v_ids))
         and (coalesce(start_date, shoot_date) + make_interval(months => portrait_months) - interval '1 day')::date >= v_date
       limit 1;
      if v_koc is not null then raise exception '這位演員已綁 % 的 KOC，不能在這天拍 KOC', v_koc; end if;
    end if;
  end loop;

  -- 時數檢查：目的地那一場
  if v_changed then
    select * into v_target from bookings
     where actor_id = b.actor_id and shoot_date = v_date and status <> '已取消' and not (id = any(v_ids)) limit 1;
    select coalesce(sum(hours),0) into v_total from bookings
     where actor_id = b.actor_id and shoot_date = v_date and status <> '已取消' and not (id = any(v_ids));
    select v_total + coalesce(sum(case when id = b.id then p_hours else hours end),0) into v_total from bookings where id = any(v_ids);
  else
    select coalesce(sum(hours),0) + p_hours into v_total from bookings where shoot_id = b.shoot_id and id <> b.id and status <> '已取消';
  end if;
  if v_total > 6 and not p_overtime_ok then raise exception '這場加總 % 小時，超過當天上限 6 小時', v_total; end if;

  update bookings set material_no = p_material_no, title = p_title, role_type = p_role, hours = p_hours,
         place = p_place, team = p_team, start_date = p_start, script = p_script, note = p_note
   where id = p_id;

  if v_changed then
    if v_target.id is not null then
      v_shoot := v_target.shoot_id; v_cycle := v_target.cycle_no;                 -- 併入那天已有的場次
    elsif p_move_all or not exists(select 1 from bookings where shoot_id = b.shoot_id and status <> '已取消' and id <> b.id) then
      v_shoot := b.shoot_id; v_cycle := b.cycle_no;                               -- 整場改期：編號與期數不變
    else
      v_yymm := to_char(v_date, 'YYMM');                                          -- 從同場拆出：新的一場
      select 'SH-' || v_yymm || '-' || lpad((coalesce(max(substring(shoot_id from '[0-9]+$')::int), 0) + 1)::text, 2, '0') into v_shoot
        from bookings where shoot_id like 'SH-' || v_yymm || '-%';
      v_cycle := case when is_invoiced(b.cycle_no) or cycle_count(b.cycle_no) >= 7 then open_cycle() else b.cycle_no end;
    end if;
    for x in select id, shoot_date from bookings where id = any(v_ids) loop
      update bookings set shoot_date = v_date, shoot_id = v_shoot, cycle_no = v_cycle where id = x.id;
      perform log_status(x.id, '拍攝日 ' || x.shoot_date, '改期 ' || v_date);
    end loop;
    update bookings set status = '待確認' where shoot_id = v_shoot and status = '已確認';
  elsif p_hours is distinct from b.hours then
    update bookings set status = '待確認' where shoot_id = b.shoot_id and status = '已確認';
  end if;
  perform log_status(p_id, '內容', '修改');
  select * into r from bookings where id = p_id;
  return r;
end $$;

create function public.set_invoice_date(p_id text, p_date date)
returns void language plpgsql security definer set search_path = public as $$
declare old date;
begin
  if my_role() not in ('agency','admin') then raise exception '只有大廣帳號可以修改發票日期'; end if;
  select invoice_date into old from bookings where id = p_id;
  if not found then raise exception '找不到這筆預約'; end if;
  update bookings set invoice_date = p_date where id = p_id;
  perform log_status(p_id, '發票日期 ' || coalesce(old::text, '（期數請款日）'), coalesce(p_date::text, '改回期數請款日'));
end $$;

-- 拍攝編號改用「最大號＋1」，改期後場次消失也不會撞號
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
  select 'BK-' || v_yymm || '-' || lpad((count(*) + 1)::text, 2, '0') into v_id
    from bookings where id like 'BK-' || v_yymm || '-%';

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

revoke execute on function public.update_booking(text,text,text,text,numeric,text,text,date,text,text,date,boolean,boolean) from anon, public;
revoke execute on function public.set_invoice_date(text,date) from anon, public;
grant execute on function public.update_booking(text,text,text,text,numeric,text,text,date,text,text,date,boolean,boolean) to authenticated;
grant execute on function public.set_invoice_date(text,date) to authenticated;
