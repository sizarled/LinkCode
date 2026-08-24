-- LinkCode profile follow / unfollow feature
-- Requires: Members, Profiles, Follows, MemberSessions and pgcrypto.
-- Run once in the Supabase SQL Editor.

create extension if not exists pgcrypto with schema extensions;

alter table public."Follows" enable row level security;
alter table public."Profiles" enable row level security;

-- Keep Profiles.number_of_followers equal to the real number of Follows rows.
create or replace function public.sync_profile_follower_count()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_profile_id text;
begin
  v_profile_id := case
    when tg_op = 'DELETE' then old.following_id
    else new.following_id
  end;

  update public."Profiles"
  set number_of_followers = (
    select count(*)
    from public."Follows" f
    where f.following_id = v_profile_id
  )
  where id = v_profile_id;

  if tg_op = 'DELETE' then
    return old;
  end if;
  return new;
end;
$$;

drop trigger if exists follows_sync_profile_count_trigger on public."Follows";
create trigger follows_sync_profile_count_trigger
after insert or delete on public."Follows"
for each row
execute function public.sync_profile_follower_count();

-- Correct counters for follows that existed before the trigger was installed.
update public."Profiles" p
set number_of_followers = (
  select count(*)
  from public."Follows" f
  where f.following_id = p.id
);

-- Follow or unfollow by public username. The follower identity comes only from
-- the verified private session token and is never accepted from the browser.
create or replace function public.public_profile_follow(
  p_session_token text,
  p_username text,
  p_follow boolean
)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_viewer text;
  v_target text;
  v_count bigint;
begin
  if p_session_token is null or p_session_token !~ '^[a-f0-9]{64}$' then
    return jsonb_build_object('success', false, 'reason', 'UNAUTHORIZED');
  end if;

  select s.owner_id into v_viewer
  from public."MemberSessions" s
  join public."Members" m on m.owner_id = s.owner_id
  where s.token_hash = encode(digest(p_session_token, 'sha256'), 'hex')
    and s.expires_at > now()
    and m.account_status = 'Active'
  limit 1;

  if v_viewer is null then
    return jsonb_build_object('success', false, 'reason', 'UNAUTHORIZED');
  end if;

  select p.id into v_target
  from public."Profiles" p
  join public."Members" m on m.owner_id = p.id
  where lower(p.username) = lower(trim(coalesce(p_username, '')))
    and p.profile_status = 'Active'
    and m.account_status = 'Active'
  limit 1;

  if v_target is null then
    return jsonb_build_object('success', false, 'reason', 'PROFILE_NOT_FOUND');
  end if;

  if v_viewer = v_target then
    return jsonb_build_object('success', false, 'reason', 'CANNOT_FOLLOW_SELF');
  end if;

  perform pg_advisory_xact_lock(hashtext('follow:' || v_viewer || ':' || v_target));

  if coalesce(p_follow, false) then
    insert into public."Follows" (follower_id, following_id)
    values (v_viewer, v_target)
    on conflict (follower_id, following_id) do nothing;
  else
    delete from public."Follows"
    where follower_id = v_viewer
      and following_id = v_target;
  end if;

  select count(*) into v_count
  from public."Follows"
  where following_id = v_target;

  return jsonb_build_object(
    'success', true,
    'following', coalesce(p_follow, false),
    'followers', v_count
  );
end;
$$;

revoke all on function public.public_profile_follow(text, text, boolean) from public;
grant execute on function public.public_profile_follow(text, text, boolean) to anon, authenticated;

-- Prevent users from forging follower/following IDs through direct REST calls.
revoke select, insert, update, delete on table public."Follows" from anon, authenticated;
