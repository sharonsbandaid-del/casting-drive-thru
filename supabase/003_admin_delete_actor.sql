-- 003：管理者可以刪除演員（只限沒有任何預約紀錄的演員；有紀錄的會被資料庫擋下，請改用下架）
-- 已執行過 002 的資料庫執行本檔一次即可。全新安裝直接執行 schema.sql，不用跑這個。
drop policy if exists "管理者刪除演員" on public.actors;
create policy "管理者刪除演員" on public.actors for delete to authenticated using (public.my_role() = 'admin');
grant delete on public.actors to authenticated;
