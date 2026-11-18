-- Prepaid Watchdog: one admin, identified by a private list of emails
-- (2026-11-19)
--
-- Before: anyone who signed in as username "mic" (mic@app.local) with its
-- password was admin. Now admin = a signed-in user whose (verified) email is
-- listed in public.app_admin_emails. That table is not readable by the app;
-- add/remove admins in the Supabase dashboard (Table Editor or SQL editor):
--   insert into public.app_admin_emails (email) values ('someone@example.com');
-- The address itself is deliberately NOT in this file (the repo is public).

create table if not exists public.app_admin_emails (
  email      text primary key check (email = lower(email)),
  created_at timestamptz not null default now()
);
alter table public.app_admin_emails enable row level security;
revoke all on table public.app_admin_emails from anon, authenticated;

-- True when the caller is signed in with an email on the admin list.
create or replace function public.is_app_admin()
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1 from public.app_admin_emails a
    where a.email = lower(coalesce(auth.jwt() ->> 'email', ''))
  );
$$;
revoke all on function public.is_app_admin() from public, anon;
grant execute on function public.is_app_admin() to authenticated;

-- Admin policies: from the "mic@app.local" email to the admin list.
drop policy if exists admin_full_access on public.app_users;
create policy admin_full_access on public.app_users
  for all using (public.is_app_admin()) with check (public.is_app_admin());

drop policy if exists tx_admin_full on public.transactions;
create policy tx_admin_full on public.transactions
  for all using (public.is_app_admin()) with check (public.is_app_admin());

drop policy if exists txe_admin_full on public.transaction_events;
create policy txe_admin_full on public.transaction_events
  for all using (public.is_app_admin()) with check (public.is_app_admin());

drop policy if exists uq_admin_full on public.user_queries;
create policy uq_admin_full on public.user_queries
  for all using (public.is_app_admin()) with check (public.is_app_admin());

-- Guard trigger: same rules as before, admin now = admin list.
-- is_admin can no longer be changed through the app by anyone.
create or replace function public.app_users_guard()
returns trigger
language plpgsql
set search_path = ''
as $$
declare
  caller_role  text := coalesce(auth.role(), '');
  caller_email text := lower(coalesce(auth.jwt() ->> 'email', ''));
begin
  new.password := null;

  if caller_role not in ('anon', 'authenticated') then
    return new;                       -- dashboard / SQL editor / migrations
  end if;

  if tg_op = 'INSERT' then
    new.is_admin := false;
    if public.is_app_admin() then
      return new;
    end if;
    if lower(new.email) <> caller_email
       and lower(new.email) || '@app.local' <> caller_email then
      raise exception 'You can only create your own user record'
        using errcode = '42501';
    end if;
  else -- UPDATE
    new.is_admin := old.is_admin;
    if public.is_app_admin() then
      return new;
    end if;
    if new.email is distinct from old.email then
      raise exception 'Username cannot be changed'
        using errcode = '42501';
    end if;
  end if;

  return new;
end;
$$;

-- The old "mic" admin (and anyone else) loses the admin flag that older
-- app versions look at.
update public.app_users set is_admin = false where is_admin;
