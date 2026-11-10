-- ============================================================
-- 一次建立 AE 帳號（casting-drive-thru 專案專用）
-- 1. 已經存在的 email 會跳過（不會改到密碼，也不會改到名字/組別/身分）
-- 2. 新帳號的臨時密碼一律是 123456，第一次登入時會強制改密碼
-- ============================================================
create extension if not exists pgcrypto with schema extensions;

drop table if exists _seed;
create temp table _seed (email text, name text, team text, role text, temp_password text, uid uuid);

insert into _seed (email, name, team, role) values
  ('ryan.kuo@daiko.tw', 'RYAN', null, 'agency'),
  ('benson@daiko.tw', 'BENSON', null, 'agency'),
  ('grace.chen@daiko.tw', 'GRACE', null, 'agency'),
  ('sofia.hsieh@daiko.tw', 'SOFIA', null, 'agency'),
  ('erikochen@daiko.tw', 'ERIKO', null, 'agency'),
  ('camille@daiko.tw', 'CAMILLE', null, 'agency'),
  ('annie1990@daiko.tw', 'ANNIE', null, 'agency'),
  ('kason.wang@daiko.tw', 'KASON', null, 'agency'),
  ('kikichang@daiko.tw', 'KIKI', null, 'agency'),
  ('emily.yeh@daiko.tw', 'EMILY', null, 'agency'),
  ('joy@daiko.tw', 'JOY (AE)', null, 'agency'),
  ('milka@daiko.tw', 'MILKA', null, 'agency'),
  ('venessali@daiko.tw', 'VENESSA', null, 'agency'),
  ('joe@daiko.tw', 'JOE', null, 'agency'),
  ('rui.hu@daiko.tw', 'RUI', null, 'agency'),
  ('luna.sun@daiko.tw', 'LUNA', null, 'agency'),
  ('angelchen@daiko.tw', 'ANGEL', null, 'agency'),
  ('willy.hung@daiko.tw', 'WILLY', null, 'agency'),
  ('silvia.li@daiko.tw', 'SILVIA', null, 'agency'),
  ('daphne@daiko.tw', 'DAPHNE', null, 'agency'),
  ('sunny@daiko.tw', 'SUNNY', null, 'agency'),
  ('annie.chen@daiko.tw', 'ANNIE CHEN', null, 'agency'),
  ('ashley.shen@daiko.tw', 'ASHLEY', null, 'agency'),
  ('celine.lee@daiko.tw', 'CELINE', null, 'agency'),
  ('haruka@daiko.tw', 'HARUKA', null, 'agency'),
  ('timkwanch@daiko.tw', 'TIM', null, 'agency'),
  ('yujin@daiko.tw', 'YUJIN', null, 'agency'),
  ('thomas@daiko.tw', 'THOMAS', null, 'agency'),
  ('tomi@daiko.tw', 'TOMI', null, 'agency'),
  ('bernard9001@gmail.com', 'BERNARD', null, 'agency');

-- 已經有帳號的人：沿用原本的 id，不產生密碼
update _seed s set uid = u.id from auth.users u where lower(u.email) = lower(s.email);

-- 新帳號：產生 id，臨時密碼 123456
update _seed set uid = gen_random_uuid(), temp_password = '123456' where uid is null;

insert into auth.users (instance_id, id, aud, role, email, encrypted_password, email_confirmed_at,
  raw_app_meta_data, raw_user_meta_data, created_at, updated_at,
  confirmation_token, recovery_token, email_change_token_new, email_change)
select '00000000-0000-0000-0000-000000000000', uid, 'authenticated', 'authenticated', lower(email),
  extensions.crypt(temp_password, extensions.gen_salt('bf')), now(),
  '{"provider":"email","providers":["email"]}'::jsonb, '{"must_change_pw":true}'::jsonb, now(), now(),
  '', '', '', ''
from _seed where temp_password is not null;

insert into auth.identities (id, user_id, provider_id, identity_data, provider, last_sign_in_at, created_at, updated_at)
select gen_random_uuid(), uid, uid::text,
  jsonb_build_object('sub', uid::text, 'email', lower(email), 'email_verified', true),
  'email', now(), now(), now()
from _seed where temp_password is not null;

-- 名字、組別、身分（新帳號的 profile 由觸發器自動建立）
insert into public.profiles (id, email) select uid, lower(email) from _seed on conflict (id) do nothing;
update public.profiles p set display_name = s.name, team = s.team, role = s.role
from _seed s where p.id = s.uid and s.temp_password is not null;

-- 結果：臨時密碼清單（空白 = 原本就有帳號，密碼不變）
select name as 名字, email, coalesce(team, '') as 組別, role as 身分, coalesce(temp_password, '（原本就有帳號）') as 臨時密碼
from _seed order by team nulls first, name;
