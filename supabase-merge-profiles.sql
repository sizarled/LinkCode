-- Merge LinkCodeProfiles into Profiles without losing usernames, avatars, or bios.
-- Run this migration before the updated supabase-dashboard.sql.

alter table public."Profiles" add column if not exists avatar_url text null;
alter table public."Profiles" add column if not exists bio character varying(190) null;
alter table public."Profiles" add column if not exists updated_at timestamp with time zone not null default now();

-- Clean legacy usernames before any update triggers the format constraint.
do $$
declare
  r record;
  v_candidate text;
  v_suffix text;
begin
  for r in select id, username from public."Profiles" order by id loop
    v_candidate := regexp_replace(btrim(coalesce(r.username, '')), '[^A-Za-z0-9_]+', '_', 'g');
    v_candidate := btrim(v_candidate, '_');
    if char_length(v_candidate) < 3 then v_candidate := 'member_' || lower(r.id); end if;
    v_candidate := left(v_candidate, 30);
    if exists (select 1 from public."Profiles" p where p.id <> r.id and lower(p.username) = lower(v_candidate)) then
      v_suffix := '_' || lower(r.id);
      v_candidate := left(v_candidate, greatest(3, 30 - char_length(v_suffix))) || v_suffix;
      v_candidate := left(v_candidate, 30);
    end if;
    update public."Profiles" set username = v_candidate
    where id = r.id and username is distinct from v_candidate;
  end loop;
end;
$$;

-- Copy the extended fields from the legacy table when it still exists.
do $$
begin
  if to_regclass('public."LinkCodeProfiles"') is not null then
    execute '
      update public."Profiles" p
      set avatar_url = coalesce(l.avatar_url, p.avatar_url),
          bio = coalesce(l.bio, p.bio),
          updated_at = greatest(p.updated_at, l.updated_at)
      from public."LinkCodeProfiles" l
      where p.id = l.owner_id';

    -- Preserve a customized LinkCodeProfiles username when Profiles still has
    -- the automatically generated default and no other profile owns that name.
    execute '
      update public."Profiles" p
      set username = btrim(l.username),
          updated_at = greatest(p.updated_at, l.updated_at)
      from public."LinkCodeProfiles" l
      where p.id = l.owner_id
        and lower(p.username) = lower(''member_'' || p.id)
        and btrim(l.username) ~ ''^[A-Za-z0-9_]{3,30}$''
        and not exists (
          select 1 from public."Profiles" other
          where lower(other.username) = lower(btrim(l.username)) and other.id <> p.id
        )';
  end if;
end;
$$;

-- Add profiles that exist only in Members.
insert into public."Profiles" (
  id, username, full_name, email, number_of_followers,
  profile_status, joined_date, avatar_url, bio, updated_at
)
select
  m.owner_id,
  'member_' || lower(m.owner_id),
  m.full_name,
  lower(m.email),
  0,
  case m.account_status when 'Active' then 'Active' when 'Banned' then 'Banned' else 'Inactive' end,
  m.joining_date,
  null,
  null,
  now()
from public."Members" m
where not exists (select 1 from public."Profiles" p where p.id = m.owner_id)
on conflict do nothing;

create unique index if not exists profiles_username_lower_key
on public."Profiles" (lower(username));

-- Do not drop LinkCodeProfiles in this migration yet: existing RPC functions
-- may still depend on it. The updated supabase-dashboard.sql replaces those
-- functions and safely drops the legacy table at its very end.
