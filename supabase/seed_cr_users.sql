-- ============================================================
-- 一次建立 CR 成員帳號（casting-drive-thru 專案專用）
-- 1. 已經存在的 email 會跳過（不會改到密碼）
-- 2. 新帳號的臨時密碼一律是 123456，第一次登入時會強制改密碼
-- ============================================================
create extension if not exists pgcrypto with schema extensions;

drop table if exists _seed;
create temp table _seed (email text, name text, team text, role text, temp_password text, uid uuid);

insert into _seed (email, name, team, role) values
  ('chocokou@daiko.tw',     'CHOCO',    null,     'admin'),
  ('howard.chang@daiko.tw', 'HOWARD',   null,     'agency'),
  ('yihualin@daiko.tw',     'IKA',      '花花組', 'agency'),
  ('hungling@daiko.tw',     'HUNGLING', '花花組', 'agency'),
  ('andy.chen@daiko.tw',    'ANDY',     '花花組', 'agency'),
  ('sherry.chen@daiko.tw',  'SHERRY',   '花花組', 'agency'),
  ('wenhsu0924@daiko.tw',   'WEN',      '花花組', 'agency'),
  ('kuan.kuan@daiko.tw',    'KUAN',     '花花組', 'agency'),
  ('i-cho@daiko.tw',        'WEIYU',    '泡泡組', 'agency'),
  ('sana0709@daiko.tw',     'SANA',     '泡泡組', 'agency'),
  ('emery.lin@daiko.tw',    'EMERY',    '泡泡組', 'agency'),
  ('neko@daiko.tw',         'NEKO',     '泡泡組', 'agency'),
  ('jika@daiko.tw',         'JIKA',     '泡泡組', 'agency'),
  ('yayahung@daiko.tw',     'YAYA',     '泡泡組', 'agency'),
  ('rishona.lin@daiko.tw',  'RISHONA',  '泡泡組', 'agency'),
  ('emmachen0701@daiko.tw', 'EMMA',     '啾啾組', 'agency'),
  ('kazuki@daiko.tw',       'MAE',      '啾啾組', 'agency'),
  ('dalora.hsu@daiko.tw',   'DALORA',   '啾啾組', 'agency'),
  ('ichigo@daiko.tw',       'ICHIGO',   '啾啾組', 'agency'),
  ('bernie@daiko.tw',       'BERNIE',   '毛毛組', 'agency'),
  ('ivan0830@daiko.tw',     'IVAN',     '毛毛組', 'agency'),
  ('joy.tsai@daiko.tw',     'JOY',      '毛毛組', 'agency'),
  ('tz.yang@daiko.tw',      'TZ',       '毛毛組', 'agency'),
  ('zoe.hsu@daiko.tw',      'ZOE',      '毛毛組', 'agency');

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
from _seed s where p.id = s.uid;

-- 結果：臨時密碼清單（空白 = 原本就有帳號，密碼不變）
select name as 名字, email, coalesce(team, '') as 組別, role as 身分, coalesce(temp_password, '（原本就有帳號）') as 臨時密碼
from _seed order by team nulls first, name;
