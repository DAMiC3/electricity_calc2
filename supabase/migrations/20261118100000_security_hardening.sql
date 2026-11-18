-- Prepaid Watchdog: security hardening (2026-11-18)
--
-- 1. Stop keeping a plain-text copy of every password in app_users.
--    Supabase Auth already stores the real (hashed) password; this column was
--    only a readable duplicate. Old app versions still send it, so instead of
--    dropping the column (which would break their sign-up insert) it becomes
--    nullable and a trigger blanks it on every write.
-- 2. Ordinary users can no longer make themselves admin, change their username
--    row, or create rows for other people's usernames.
-- 3. Remove permissions the app never uses (anonymous access to user data,
--    TRUNCATE/TRIGGER/REFERENCES), and drop duplicated support-chat policies.
--
-- The admin account is the one whose login email is mic@app.local (the same
-- rule the existing admin RLS policies use).

-- ---------------------------------------------------------------------------
-- 1 + 2. app_users guard
-- ---------------------------------------------------------------------------
alter table public.app_users alter column password drop not null;

create or replace function public.app_users_guard()
returns trigger
language plpgsql
set search_path = ''
as $$
declare
  caller_role  text := coalesce(auth.role(), '');
  caller_email text := lower(coalesce(auth.jwt() ->> 'email', ''));
begin
  -- Never keep passwords in this table, whoever writes.
  new.password := null;

  -- Dashboard / SQL editor / migrations (no API caller): no further checks.
  if caller_role not in ('anon', 'authenticated') then
    return new;
  end if;

  -- The admin may manage any row.
  if caller_email = 'mic@app.local' then
    return new;
  end if;

  if tg_op = 'INSERT' then
    -- A user may only create the row for their own username.
    -- Usernames are stored bare ("bob") while the login email is bob@app.local;
    -- accounts registered with a real email store that email as-is.
    if lower(new.email) <> caller_email
       and lower(new.email) || '@app.local' <> caller_email then
      raise exception 'You can only create your own user record'
        using errcode = '42501';
    end if;
    new.is_admin := false;
  else -- UPDATE
    if new.email is distinct from old.email then
      raise exception 'Username cannot be changed'
        using errcode = '42501';
    end if;
    new.is_admin := old.is_admin;
  end if;

  return new;
end;
$$;

drop trigger if exists app_users_guard on public.app_users;
create trigger app_users_guard
  before insert or update on public.app_users
  for each row execute function public.app_users_guard();

-- Wipe the plain-text copies that are already stored.
update public.app_users set password = null where password is not null;

-- ---------------------------------------------------------------------------
-- 3. Tighten table permissions
-- ---------------------------------------------------------------------------
-- The app only touches these tables after sign-in, so the anonymous role
-- needs nothing on them. Row Level Security still applies to signed-in users.
revoke all on table public.app_users, public.transactions,
                    public.transaction_events, public.user_queries
  from anon;

revoke truncate, trigger, references on table
  public.app_users, public.transactions,
  public.transaction_events, public.user_queries
  from authenticated;

-- user_queries had two identical sets of policies (*_own and *_self).
drop policy if exists uq_select_self on public.user_queries;
drop policy if exists uq_insert_self on public.user_queries;
drop policy if exists uq_update_self on public.user_queries;
