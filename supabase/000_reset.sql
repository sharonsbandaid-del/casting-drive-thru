-- 000：清除 Casting Drive-Thru 的資料表與函式（只在「還沒有正式資料」時使用！）
-- 用途：之前跑過舊版或跑到一半出錯時，先執行本檔清乾淨，再執行 schema.sql。
-- ⚠️ 會刪除演員、預約、請款等所有資料；登入帳號（auth.users）和已上傳的照片檔不會被刪。
drop trigger if exists on_auth_user_created on auth.users;
drop table if exists public.status_log, public.deleted_bookings, public.bookings, public.cycles, public.actors, public.profiles cascade;
drop sequence if exists public.actor_seq;
do $$
declare r record;
begin
  for r in select p.oid::regprocedure as f from pg_proc p
           where p.pronamespace = 'public'::regnamespace
             and p.proname = any (array['handle_new_user','my_role','today_tw','touch_updated_at','is_invoiced','cycle_count',
               'open_cycle','koc_conflict','log_status','create_booking','update_booking','set_oa_date','set_invoice_date',
               'set_booking_note','delete_booking','set_booking_cancelled','set_shoot_status','invoice_cycle','uninvoice_cycle'])
  loop
    execute 'drop function ' || r.f || ' cascade';
  end loop;
end $$;
