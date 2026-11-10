-- 演員卡新增「影片連結」欄位（一行一個網址）
alter table public.actors add column if not exists video_links text;
