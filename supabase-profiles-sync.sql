-- Synchronize public."Members" with the supplied public."Profiles" table.
-- Run once in the Supabase SQL Editor. Existing and future members are handled.

alter table public."Profiles" enable row level security;

create or replace function public.sync_member_to_profile()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_profile_status text;
  v_default_username text;
begin
  v_profile_status := case new.account_status
    when 'Active' then 'Active'
    when 'Banned' then 'Banned'
    else 'Inactive'
  end;
  v_default_username := 'member_' || lower(new.owner_id);

  insert into public."Profiles" (
    id,
    username,
    full_name,
    email,
    number_of_followers,
    profile_status,
    joined_date
  ) values (
    new.owner_id,
    v_default_username,
    new.full_name,
    lower(new.email),
    0,
    v_profile_status,
    new.joining_date
  )
  on conflict (id) do update set
    full_name = excluded.full_name,
    email = excluded.email,
    profile_status = excluded.profile_status,
    joined_date = excluded.joined_date;

  return new;
end;
$$;

-- Backfill members that already existed before this migration.
insert into public."Profiles" (
  id,
  username,
  full_name,
  email,
  number_of_followers,
  profile_status,
  joined_date
)
select
  m.owner_id,
  'member_' || lower(m.owner_id),
  m.full_name,
  lower(m.email),
  0,
  case m.account_status
    when 'Active' then 'Active'
    when 'Banned' then 'Banned'
    else 'Inactive'
  end,
  m.joining_date
from public."Members" m
where not exists (
  select 1 from public."Profiles" p where p.id = m.owner_id
)
on conflict do nothing;

-- Refresh account-controlled fields for existing matching profiles while
-- preserving each member's chosen username and follower counter.
update public."Profiles" p
set full_name = m.full_name,
    email = lower(m.email),
    profile_status = case m.account_status
      when 'Active' then 'Active'
      when 'Banned' then 'Banned'
      else 'Inactive'
    end,
    joined_date = m.joining_date
from public."Members" m
where p.id = m.owner_id;

drop trigger if exists members_sync_profile_trigger on public."Members";
create trigger members_sync_profile_trigger
after insert or update of full_name, email, account_status
on public."Members"
for each row
execute function public.sync_member_to_profile();

-- Keep number_of_followers synchronized with the dashboard Follows table.
create or replace function public.sync_profile_follower_count()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_profile_id text;
begin
  v_profile_id := case when tg_op = 'DELETE' then old.following_id else new.following_id end;
  update public."Profiles"
  set number_of_followers = (
    select count(*) from public."Follows" f where f.following_id = v_profile_id
  )
  where id = v_profile_id;
  if tg_op = 'DELETE' then
    return old;
  end if;
  return new;
end;
$$;

do $$
begin
  if to_regclass('public."Follows"') is not null then
    execute 'drop trigger if exists follows_sync_profile_count_trigger on public."Follows"';
    execute 'create trigger follows_sync_profile_count_trigger after insert or delete on public."Follows" for each row execute function public.sync_profile_follower_count()';
    execute 'update public."Profiles" p set number_of_followers = (select count(*) from public."Follows" f where f.following_id = p.id)';
  end if;
end;
$$;

-- Profiles are read and changed through the LinkCode RPC layer.
revoke select, insert, update, delete on table public."Profiles" from anon, authenticated;
