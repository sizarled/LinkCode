-- LinkCode secure member registration for Register.html
-- Run this file once in the Supabase SQL Editor after creating public."Members".
-- Passwords are stored as bcrypt hashes in Members.password — never as plain text.

create extension if not exists pgcrypto with schema extensions;

alter table public."Members" enable row level security;

-- Public profile row created automatically with every new member.
create table if not exists public."Profiles" (
  id text primary key,
  username text not null unique,
  full_name text not null,
  email text not null unique,
  number_of_followers bigint not null default 0,
  profile_status text not null default 'Active',
  joined_date timestamp with time zone not null default now(),
  avatar_url text null,
  bio character varying(190) null,
  updated_at timestamp with time zone not null default now(),
  constraint profiles_followers_non_negative check (number_of_followers >= 0),
  constraint profiles_id_format check (id ~ '^ID[0-9]+$'),
  constraint profiles_status_valid check (profile_status in ('Active','Inactive','Banned'))
);

alter table public."Profiles" add column if not exists avatar_url text null;
alter table public."Profiles" add column if not exists bio character varying(190) null;
alter table public."Profiles" add column if not exists updated_at timestamp with time zone not null default now();

-- Registration always creates a real authenticated session before redirecting.
create table if not exists public."MemberSessions" (
  session_id uuid primary key default gen_random_uuid(),
  owner_id text not null references public."Members" (owner_id) on delete cascade,
  token_hash text not null unique,
  remember_me boolean not null default false,
  created_at timestamp with time zone not null default now(),
  expires_at timestamp with time zone not null,
  last_seen_at timestamp with time zone not null default now()
);

create index if not exists member_sessions_owner_idx
on public."MemberSessions" (owner_id, expires_at desc);

alter table public."Profiles" enable row level security;
alter table public."MemberSessions" enable row level security;
revoke all on table public."Profiles" from anon, authenticated;
revoke all on table public."MemberSessions" from anon, authenticated;

-- Normalize uniqueness so Test@Example.com and test@example.com cannot register twice.
create unique index if not exists members_email_lower_key
on public."Members" (lower(email));

-- A sequence produces IDs that satisfy ^ID[0-9]+$ safely under concurrent registration.
create sequence if not exists public.members_owner_id_seq;

do $$
declare
  v_max_id bigint;
begin
  select greatest(
    coalesce(max(substring(owner_id from 3)::bigint), 0),
    1000
  ) into v_max_id
  from public."Members";

  perform setval('public.members_owner_id_seq', v_max_id, true);
end;
$$;

create or replace function public.register_member(
  p_full_name text,
  p_email text,
  p_password text,
  p_terms_accepted boolean
)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_full_name text := trim(regexp_replace(coalesce(p_full_name, ''), '\s+', ' ', 'g'));
  v_email text := lower(trim(coalesce(p_email, '')));
  v_owner_id text;
  v_joining_date timestamp with time zone;
  v_session_token text;
  v_session_expires timestamp with time zone;
begin
  if char_length(v_full_name) < 2 or char_length(v_full_name) > 100 then
    return jsonb_build_object('success', false, 'reason', 'INVALID_NAME');
  end if;

  if char_length(v_email) > 254
     or v_email !~* '^[A-Z0-9._%+\-]+@[A-Z0-9.\-]+\.[A-Z]{2,}$' then
    return jsonb_build_object('success', false, 'reason', 'INVALID_EMAIL');
  end if;

  -- bcrypt processes at most 72 bytes; the page enforces the same practical limit.
  if p_password is null or char_length(p_password) < 8 or octet_length(p_password) > 72 then
    return jsonb_build_object('success', false, 'reason', 'INVALID_PASSWORD');
  end if;

  if p_terms_accepted is distinct from true then
    return jsonb_build_object('success', false, 'reason', 'TERMS_REQUIRED');
  end if;

  -- Serialize registrations for the same normalized email.
  perform pg_advisory_xact_lock(hashtext('member-email:' || v_email));

  if exists (select 1 from public."Members" where lower(email) = v_email) then
    return jsonb_build_object('success', false, 'reason', 'MEMBER_EXISTS');
  end if;

  v_owner_id := 'ID' || nextval('public.members_owner_id_seq')::text;

  insert into public."Members" (
    owner_id,
    full_name,
    email,
    password,
    account_status,
    account_earnings,
    account_payments
  ) values (
    v_owner_id,
    v_full_name,
    v_email,
    crypt(p_password, gen_salt('bf', 12)),
    'Active',
    0.00,
    0.00
  )
  returning joining_date into v_joining_date;

  -- Create the matching public profile before returning registration success.
  insert into public."Profiles" (
    id,
    username,
    full_name,
    email,
    number_of_followers,
    profile_status,
    joined_date
  ) values (
    v_owner_id,
    'member_' || lower(v_owner_id),
    v_full_name,
    v_email,
    0,
    'Active',
    v_joining_date
  )
  on conflict (id) do update set
    full_name = excluded.full_name,
    email = excluded.email,
    profile_status = 'Active',
    joined_date = excluded.joined_date;

  -- Create a real 12-hour session so Register.html can open Dashboard directly.
  v_session_token := encode(gen_random_bytes(32), 'hex');
  v_session_expires := now() + interval '12 hours';
  insert into public."MemberSessions" (
    owner_id,
    token_hash,
    remember_me,
    expires_at
  ) values (
    v_owner_id,
    encode(digest(v_session_token, 'sha256'), 'hex'),
    false,
    v_session_expires
  );

  return jsonb_build_object(
    'success', true,
    'owner_id', v_owner_id,
    'full_name', v_full_name,
    'email', v_email,
    'account_status', 'Active',
    'joining_date', v_joining_date,
    'session_token', v_session_token,
    'session_expires_at', v_session_expires
  );
exception
  when unique_violation then
    -- Handles a concurrent duplicate safely without exposing database details.
    if exists (select 1 from public."Members" where lower(email) = v_email) then
      return jsonb_build_object('success', false, 'reason', 'MEMBER_EXISTS');
    end if;
    raise;
end;
$$;

revoke all on function public.register_member(text, text, text, boolean) from public;
grant execute on function public.register_member(text, text, text, boolean) to anon, authenticated;

-- Registration must only occur through register_member.
revoke insert, update, delete, select on table public."Members" from anon;

-- For a future Login.html page, use Supabase Auth or a rate-limited Edge Function.
-- Do not expose password hashes or an unrestricted password-checking RPC.
