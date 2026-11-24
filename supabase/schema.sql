-- =====================================================================
-- Casting Drive-Thru：資料庫結構
-- 在 Supabase → SQL Editor 貼上全部內容，按 Run 執行一次即可。
-- =====================================================================

-- ---------- 帳號與角色 ----------
-- casting：Casting 公司｜agency：大廣創意、業務｜admin：Casting 管理者
create table public.profiles (
  id           uuid primary key references auth.users on delete cascade,
  email        text,
  display_name text,
  role         text not null default 'agency' check (role in ('casting','agency','admin')),
  team         text,
  created_at   timestamptz not null default now()
);

-- 新帳號建立時，自動建立 profile（預設角色 agency）
create function public.handle_new_user() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  insert into public.profiles (id, email, display_name)
  values (new.id, new.email, split_part(new.email, '@', 1));
  return new;
end $$;
create trigger on_auth_user_created after insert on auth.users
  for each row execute function public.handle_new_user();
-- 執行這份語法之前就已經建立的帳號，也補上 profile
insert into public.profiles (id, email, display_name)
select id, email, split_part(email, '@', 1) from auth.users
on conflict (id) do nothing;

create function public.my_role() returns text
language sql stable security definer set search_path = public as $$
  select role from public.profiles where id = auth.uid()
$$;

create function public.today_tw() returns date
language sql stable as $$ select (now() at time zone 'Asia/Taipei')::date $$;

-- ---------- 演員庫（Casting 維護） ----------
create sequence public.actor_seq;
create table public.actors (
  id              text primary key default 'AC' || lpad(nextval('public.actor_seq')::text, 3, '0'),
  name            text not null,
  gender          text check (gender in ('女','男')),
  birth_ym        text,                       -- 出生年月，例如 2017-05
  height          int,
  size            text,
  status          text not null default '可接案' check (status in ('可接案','暫停接案')),
  archived        boolean not null default false,  -- 下架：不顯示、不能預約，但編號與資料永久保留
  avail_time      text,
  tags            text[] not null default '{}',
  note            text,
  photo_path      text,                       -- Storage：actor-photos 裡的檔名
  video_links     text,                       -- 影片連結，一行一個
  -- 合約與肖像授權條件（預約時快照帶入）
  portrait_months int  not null check (portrait_months in (3,6,12,24)),
  renew_days      int  not null default 30,
  web             text[] not null default '{}',
  second_use      text not null default '○' check (second_use in ('○','X')),
  ai_use          text not null default 'X' check (ai_use in ('○','X')),
  comp_ingredient text not null default 'X' check (comp_ingredient in ('○','X')),
  comp_effect     text not null default 'X' check (comp_effect in ('○','X')),
  shoot_fee       int,                        -- 每人次拍攝費
  overtime_fee    int,                        -- 每小時超時費
  nda             text not null default '已簽' check (nda in ('已簽','未簽')),
  created_at      timestamptz not null default now(),
  updated_at      timestamptz not null default now()
);

create function public.touch_updated_at() returns trigger language plpgsql as $$
begin new.updated_at := now(); return new; end $$;
create trigger actors_touch before update on public.actors
  for each row execute function public.touch_updated_at();

-- ---------- 請款期數（集點卡） ----------
create table public.cycles (
  no           int primary key,
  invoice_date date,
  invoiced_by  uuid references public.profiles,
  invoiced_at  timestamptz
);

-- ---------- 預約（每一列＝一支素材） ----------
create table public.bookings (
  id              text primary key,             -- BK-2611-07
  shoot_id        text not null,                -- SH-2611-05：同演員同一天＝同一場＝1 人次
  cycle_no        int  not null,
  actor_id        text not null references public.actors,
  shoot_date      date not null,
  hours           numeric(3,1) not null check (hours > 0),
  product         text not null,
  team            text,
  role_type       text not null,                -- 情境演員 / KOC / ...
  title           text not null,                -- 素材篇名
  material_no     text,                         -- 素材管理編號
  script          text,                         -- 腳本連結或說明
  place           text,
  booked_by       uuid references public.profiles default auth.uid(),
  booked_by_name  text,
  first_start     date,
  start_date      date,                         -- 本素材合約開始日（OA日），未定可先留空
  -- 合約條件快照
  portrait_months int not null,
  renew_days      int not null,
  web             text[] not null default '{}',
  second_use      text, ai_use text, comp_ingredient text, comp_effect text,
  shoot_fee       int, overtime_fee int, nda text,
  note            text,
  invoice_date    date,                         -- 個別發票日期（空白＝沿用期數的請款日）
  status          text not null default '待確認' check (status in ('待確認','已確認','已拍攝','已取消')),
  created_at      timestamptz not null default now()
);
create index on public.bookings (actor_id, shoot_date);
create index on public.bookings (cycle_no);
create index on public.bookings (shoot_id);

-- 刪除的預約：從 bookings 移到這裡保存（含刪除原因與當時的狀態紀錄），不影響人次與契約一覽
create table public.deleted_bookings (
  id              text primary key,
  data            jsonb not null,
  reason          text not null,
  deleted_by      uuid default auth.uid(),
  deleted_by_name text,
  deleted_at      timestamptz not null default now()
);

create table public.status_log (
  id          bigserial primary key,
  booking_id  text not null references public.bookings,
  from_status text, to_status text not null,
  by_user     uuid default auth.uid(),
  by_name     text,
  at          timestamptz not null default now()
);

-- ---------- 規則用的小工具 ----------
create function public.is_invoiced(p_no int) returns boolean
language sql stable security definer set search_path = public as $$
  select exists(select 1 from cycles where no = p_no and invoice_date is not null)
$$;

create function public.cycle_count(p_no int) returns int
language sql stable security definer set search_path = public as $$
  select count(distinct shoot_id)::int from bookings where cycle_no = p_no and status <> '已取消'
$$;

-- 第一個「未滿 7 人次、未請款」的期數
create function public.open_cycle() returns int
language plpgsql stable security definer set search_path = public as $$
declare n int := 1;
begin
  loop
    if not is_invoiced(n) and cycle_count(n) < 7 then return n; end if;
    n := n + 1;
  end loop;
end $$;

-- 同一位演員只能幫一個商品拍 KOC（在該 KOC 合約有效期間內）
create function public.koc_conflict(p_actor text, p_product text, p_date date, p_exclude text default null)
returns text language sql stable security definer set search_path = public as $$
  select product from bookings
   where actor_id = p_actor and role_type = 'KOC' and status <> '已取消'
     and product <> p_product and id is distinct from p_exclude
     and (coalesce(start_date, shoot_date) + make_interval(months => portrait_months) - interval '1 day')::date >= p_date
   limit 1
$$;

create function public.log_status(p_id text, p_from text, p_to text)
returns void language sql security definer set search_path = public as $$
  insert into status_log (booking_id, from_status, to_status, by_name)
  values (p_id, p_from, p_to, (select coalesce(display_name, email) from profiles where id = auth.uid()))
$$;

-- ---------- 預約（大廣） ----------
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

-- ---------- 修改預約內容（大廣）：演員、商品不能改；拍攝日可以改（可整場改期） ----------
create function public.update_booking(
  p_id text, p_material_no text, p_title text, p_role text, p_hours numeric, p_place text,
  p_team text, p_start date, p_script text, p_note text,
  p_date date default null, p_move_all boolean default false, p_overtime_ok boolean default false
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

-- ---------- 設定 OA 日（大廣，預約總表直接點選） ----------
create function public.set_oa_date(p_id text, p_date date)
returns public.bookings language plpgsql security definer set search_path = public as $$
declare old date; r bookings;
begin
  if my_role() not in ('agency','admin') then raise exception '只有大廣帳號可以設定 OA 日'; end if;
  select start_date into old from bookings where id = p_id and status <> '已取消';
  if not found then raise exception '找不到這筆預約，或已取消'; end if;
  update bookings set start_date = p_date where id = p_id returning * into r;
  perform log_status(p_id, 'OA日 ' || coalesce(old::text, '未定'), coalesce(p_date::text, '清除'));
  return r;
end $$;

-- ---------- 備考（大廣，契約一覽直接編輯） ----------
create function public.set_booking_note(p_id text, p_note text)
returns void language plpgsql security definer set search_path = public as $$
begin
  if my_role() not in ('agency','admin') then raise exception '只有大廣帳號可以編輯備考'; end if;
  update bookings set note = nullif(trim(p_note), '') where id = p_id;
  if not found then raise exception '找不到這筆預約'; end if;
  perform log_status(p_id, '備考', '修改');
end $$;

-- ---------- 發票日期（大廣行政） ----------
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

-- ---------- 取消／恢復素材（大廣） ----------
create function public.set_booking_cancelled(p_id text, p_cancel boolean)
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

-- ---------- 確認檔期／已拍攝（Casting，以整場為單位） ----------
create function public.set_shoot_status(p_shoot text, p_to text)
returns void language plpgsql security definer set search_path = public as $$
declare cur text; d date; cyc int; r record;
begin
  if my_role() not in ('casting','admin') then raise exception '只有 Casting 帳號可以變更檔期狀態'; end if;
  select min(shoot_date), min(cycle_no) into d, cyc from bookings where shoot_id = p_shoot and status <> '已取消';
  if d is null then raise exception '找不到這場拍攝'; end if;
  select case when bool_or(status = '待確認') then '待確認'
              when bool_and(status = '已拍攝') then '已拍攝' else '已確認' end
    into cur from bookings where shoot_id = p_shoot and status <> '已取消';

  if not ((cur = '待確認' and p_to = '已確認') or (cur = '已確認' and p_to in ('已拍攝','待確認'))
          or (cur = '已拍攝' and p_to = '已確認')) then
    raise exception '無法從「%」改成「%」', cur, p_to;
  end if;
  if p_to = '已拍攝' and d > today_tw() then raise exception '拍攝日當天之後才能標記已拍攝'; end if;
  if cur = '已拍攝' and is_invoiced(cyc) then raise exception '這一期已請款，需先由管理者撤銷請款'; end if;

  for r in select id, status from bookings where shoot_id = p_shoot and status <> '已取消' and status <> p_to loop
    update bookings set status = p_to where id = r.id;
    perform log_status(r.id, r.status, p_to);
  end loop;
end $$;

-- ---------- 請款（Casting）／撤銷請款（管理者） ----------
create function public.invoice_cycle(p_no int, p_date date)
returns void language plpgsql security definer set search_path = public as $$
begin
  if my_role() not in ('casting','admin') then raise exception '只有 Casting 帳號可以請款'; end if;
  if is_invoiced(p_no) then raise exception '這一期已經請過款了'; end if;
  if cycle_count(p_no) < 7 then raise exception '這一期還沒集滿 7 人次'; end if;
  if exists(select 1 from bookings where cycle_no = p_no and status in ('待確認','已確認')) then
    raise exception '這一期還有場次沒有標記已拍攝';
  end if;
  insert into cycles (no, invoice_date, invoiced_by, invoiced_at) values (p_no, p_date, auth.uid(), now())
  on conflict (no) do update set invoice_date = excluded.invoice_date, invoiced_by = excluded.invoiced_by, invoiced_at = now();
end $$;

create function public.uninvoice_cycle(p_no int)
returns void language plpgsql security definer set search_path = public as $$
begin
  if my_role() <> 'admin' then raise exception '只有管理者可以撤銷請款'; end if;
  update cycles set invoice_date = null, invoiced_by = null, invoiced_at = null where no = p_no;
end $$;

-- ---------- 資料列權限（RLS） ----------
alter table public.profiles   enable row level security;
alter table public.actors     enable row level security;
alter table public.cycles     enable row level security;
alter table public.bookings   enable row level security;
alter table public.status_log enable row level security;
alter table public.deleted_bookings enable row level security;

create policy "只看自己（管理者看全部）" on public.profiles for select to authenticated using (id = auth.uid() or my_role() = 'admin');
create policy "管理者可改角色"     on public.profiles   for update to authenticated using (my_role() = 'admin') with check (my_role() = 'admin');
create policy "登入者可看演員庫"   on public.actors     for select to authenticated using (true);
create policy "Casting 新增演員"   on public.actors     for insert to authenticated with check (my_role() in ('casting','admin'));
create policy "Casting 編輯演員"   on public.actors     for update to authenticated using (my_role() in ('casting','admin')) with check (my_role() in ('casting','admin'));
-- 一般只能下架（archived）；管理者可刪除沒有預約紀錄的演員（例如重複建立）。編號由 sequence 產生，刪除後也不會重複使用
create policy "管理者刪除演員" on public.actors for delete to authenticated using (my_role() = 'admin');
create policy "登入者可看期數"     on public.cycles     for select to authenticated using (true);
create policy "登入者可看預約"     on public.bookings   for select to authenticated using (true);
create policy "登入者可看紀錄"     on public.status_log for select to authenticated using (true);
create policy "登入者可看已刪除"   on public.deleted_bookings for select to authenticated using (true);
-- bookings / cycles / status_log 沒有寫入權限：只能透過上面的函式改，規則才不會被繞過

-- 未自動開放的資料表，手動授權給「已登入」的人；未登入（anon）什麼都看不到
grant usage on schema public to authenticated;
grant select on public.profiles, public.actors, public.cycles, public.bookings, public.status_log, public.deleted_bookings to authenticated;
grant update (role, team, display_name) on public.profiles to authenticated;
grant insert, update, delete on public.actors to authenticated;
grant usage on sequence public.actor_seq to authenticated;
revoke all on all tables in schema public from anon;
revoke execute on all functions in schema public from anon, public;
grant execute on function public.my_role(), public.today_tw(), public.open_cycle(),
  public.create_booking(text,date,numeric,text,text,text,text,text,text,date,text,text,boolean),
  public.set_booking_cancelled(text,boolean),
  public.update_booking(text,text,text,text,numeric,text,text,date,text,text,date,boolean,boolean),
  public.set_invoice_date(text,date), public.set_oa_date(text,date), public.delete_booking(text,text), public.set_booking_note(text,text), public.set_shoot_status(text,text),
  public.invoice_cycle(int,date), public.uninvoice_cycle(int) to authenticated;

-- ---------- 演員照片（私有，只有登入者看得到） ----------
insert into storage.buckets (id, name, public) values ('actor-photos', 'actor-photos', false)
on conflict (id) do nothing;
drop policy if exists "登入者可看演員照片" on storage.objects;
drop policy if exists "Casting 上傳照片"   on storage.objects;
drop policy if exists "Casting 更新照片"   on storage.objects;
drop policy if exists "Casting 刪除照片"   on storage.objects;
create policy "登入者可看演員照片" on storage.objects for select to authenticated using (bucket_id = 'actor-photos');
create policy "Casting 上傳照片"   on storage.objects for insert to authenticated with check (bucket_id = 'actor-photos' and public.my_role() in ('casting','admin'));
create policy "Casting 更新照片"   on storage.objects for update to authenticated using (bucket_id = 'actor-photos' and public.my_role() in ('casting','admin'));
create policy "Casting 刪除照片"   on storage.objects for delete to authenticated using (bucket_id = 'actor-photos' and public.my_role() in ('casting','admin'));

-- ============================================================
-- 以下為 011 版更新（候選日期・鎖定・工作天），全新安裝時一併建立
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
