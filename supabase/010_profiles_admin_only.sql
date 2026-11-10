-- 帳號名單只有管理者看得到：一般使用者只能讀自己的資料
drop policy if exists "登入者可看所有人名" on public.profiles;
drop policy if exists "只看自己（管理者看全部）" on public.profiles;
create policy "只看自己（管理者看全部）" on public.profiles for select to authenticated
  using (id = auth.uid() or my_role() = 'admin');
