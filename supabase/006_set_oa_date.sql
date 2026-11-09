-- 006：預約總表可以直接點選設定 OA 日
-- 已執行過 001–005 的資料庫執行本檔一次即可。全新安裝直接執行 schema.sql，不用跑這個。
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

revoke execute on function public.set_oa_date(text,date) from anon, public;
grant execute on function public.set_oa_date(text,date) to authenticated;
