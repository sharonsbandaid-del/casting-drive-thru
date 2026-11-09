-- 008：契約一覽可以直接編輯備考
-- 已執行過 001–007 的資料庫執行本檔一次即可。全新安裝直接執行 schema.sql，不用跑這個。
-- ---------- 備考（大廣，契約一覽直接編輯） ----------
create function public.set_booking_note(p_id text, p_note text)
returns void language plpgsql security definer set search_path = public as $$
begin
  if my_role() not in ('agency','admin') then raise exception '只有大廣帳號可以編輯備考'; end if;
  update bookings set note = nullif(trim(p_note), '') where id = p_id;
  if not found then raise exception '找不到這筆預約'; end if;
  perform log_status(p_id, '備考', '修改');
end $$;

revoke execute on function public.set_booking_note(text,text) from anon, public;
grant execute on function public.set_booking_note(text,text) to authenticated;
