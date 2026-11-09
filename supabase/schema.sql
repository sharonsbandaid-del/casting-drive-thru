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

-- ---------- 修改預約內容（大廣）：演員、商品不能改；拍攝日可以改（可整場改期） ----------
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

create policy "登入者可看所有人名" on public.profiles   for select to authenticated using (true);
create policy "管理者可改角色"     on public.profiles   for update to authenticated using (my_role() = 'admin') with check (my_role() = 'admin');
create policy "登入者可看演員庫"   on public.actors     for select to authenticated using (true);
create policy "Casting 新增演員"   on public.actors     for insert to authenticated with check (my_role() in ('casting','admin'));
create policy "Casting 編輯演員"   on public.actors     for update to authenticated using (my_role() in ('casting','admin')) with check (my_role() in ('casting','admin'));
-- 一般只能下架（archived）；管理者可刪除沒有預約紀錄的演員（例如重複建立）。編號由 sequence 產生，刪除後也不會重複使用
create policy "管理者刪除演員" on public.actors for delete to authenticated using (my_role() = 'admin');
create policy "登入者可看期數"     on public.cycles     for select to authenticated using (true);
create policy "登入者可看預約"     on public.bookings   for select to authenticated using (true);
create policy "登入者可看紀錄"     on public.status_log for select to authenticated using (true);
-- bookings / cycles / status_log 沒有寫入權限：只能透過上面的函式改，規則才不會被繞過

-- 未自動開放的資料表，手動授權給「已登入」的人；未登入（anon）什麼都看不到
grant usage on schema public to authenticated;
grant select on public.profiles, public.actors, public.cycles, public.bookings, public.status_log to authenticated;
grant update (role, team, display_name) on public.profiles to authenticated;
grant insert, update, delete on public.actors to authenticated;
grant usage on sequence public.actor_seq to authenticated;
revoke all on all tables in schema public from anon;
revoke execute on all functions in schema public from anon, public;
grant execute on function public.my_role(), public.today_tw(), public.open_cycle(),
  public.create_booking(text,date,numeric,text,text,text,text,text,text,date,text,text,boolean),
  public.set_booking_cancelled(text,boolean),
  public.update_booking(text,text,text,text,numeric,text,text,date,text,text,date,boolean,boolean),
  public.set_invoice_date(text,date), public.set_shoot_status(text,text),
  public.invoice_cycle(int,date), public.uninvoice_cycle(int) to authenticated;

-- ---------- 演員照片（私有，只有登入者看得到） ----------
insert into storage.buckets (id, name, public) values ('actor-photos', 'actor-photos', false);
create policy "登入者可看演員照片" on storage.objects for select to authenticated using (bucket_id = 'actor-photos');
create policy "Casting 上傳照片"   on storage.objects for insert to authenticated with check (bucket_id = 'actor-photos' and public.my_role() in ('casting','admin'));
create policy "Casting 更新照片"   on storage.objects for update to authenticated using (bucket_id = 'actor-photos' and public.my_role() in ('casting','admin'));
create policy "Casting 刪除照片"   on storage.objects for delete to authenticated using (bucket_id = 'actor-photos' and public.my_role() in ('casting','admin'));
