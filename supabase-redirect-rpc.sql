-- LinkCode secure redirect helpers for Supabase
-- Run this entire file in the Supabase SQL Editor before using Redirect.html.
-- The browser never receives destination_link until the final button is clicked.

create extension if not exists pgcrypto with schema extensions;

alter table public."Links" enable row level security;
alter table public."Visits" enable row level security;

-- Public, read-only redirect configuration. This intentionally omits destination_link and owner_id.
create or replace function public.get_redirect_link_info(p_code text)
returns table (
  code text,
  code_status text,
  waiting_time integer,
  link_level text,
  publisher_bonus_status text,
  publisher_bonus_percentage numeric,
  link_expiration_date timestamp with time zone
)
language sql
stable
security definer
set search_path = public
as $$
  select
    trim(l.code)::text,
    l.code_status,
    l.waiting_time,
    l.link_level,
    l.publisher_bonus_status,
    l.publisher_bonus_percentage,
    l.link_expiration_date
  from public."Links" as l
  where trim(l.code) = p_code
  limit 1;
$$;

revoke all on function public.get_redirect_link_info(text) from public;
grant execute on function public.get_redirect_link_info(text) to anon, authenticated;

-- Records one valid visit per IP/code in 24 hours, updates Links counters,
-- and returns the private destination only after the final user action.
drop function if exists public.record_visit_and_get_destination(text, text, text, text);

create or replace function public.record_visit_and_get_destination(
  p_code text,
  p_level text,
  p_visitor_id text,
  p_country_hint text default null,
  p_session_token text default null
)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_link public."Links"%rowtype;
  v_headers jsonb := coalesce(nullif(current_setting('request.headers', true), '')::jsonb, '{}'::jsonb);
  v_forwarded text;
  v_ip inet;
  v_country text;
  v_visitor_id text;
  v_authenticated_visit boolean := false;
  v_duplicate boolean := false;
  v_recorded boolean := false;
begin
  if p_code !~ '^[0-9]{6}$' then
    raise exception 'INVALID_CODE';
  end if;

  if p_level is null or p_level not in ('LV0', 'LV1', 'LV2', 'LV3', 'LV4', 'LV5') then
    raise exception 'INVALID_LEVEL';
  end if;

  -- A signed-in member ID is derived from the private session token, never
  -- trusted from a browser-supplied visitor_id value.
  if p_session_token is not null
     and p_session_token ~ '^[a-f0-9]{64}$'
     and to_regclass('public."MemberSessions"') is not null then
    execute '
      select s.owner_id
      from public."MemberSessions" s
      join public."Members" m on m.owner_id = s.owner_id
      where s.token_hash = encode(extensions.digest($1, ''sha256''), ''hex'')
        and s.expires_at > now()
        and m.account_status = ''Active''
      limit 1'
    into v_visitor_id
    using p_session_token;

    v_authenticated_visit := v_visitor_id is not null;
  end if;

  if v_visitor_id is null then
    if p_visitor_id is null or p_visitor_id !~ '^V[0-9]+$' then
      raise exception 'INVALID_VISITOR_ID';
    end if;
    v_visitor_id := p_visitor_id;
  end if;

  select * into v_link
  from public."Links"
  where trim(code) = p_code
  limit 1;

  if not found then
    raise exception 'CODE_NOT_FOUND';
  end if;

  if v_link.code_status <> 'Active' then
    raise exception 'CODE_NOT_ACTIVE';
  end if;

  if v_link.link_expiration_date is not null and v_link.link_expiration_date <= now() then
    raise exception 'CODE_EXPIRED';
  end if;

  if v_link.link_level <> p_level then
    raise exception 'LEVEL_MISMATCH:%', v_link.link_level;
  end if;

  -- Supabase passes the originating address through request headers.
  v_forwarded := split_part(coalesce(v_headers->>'x-forwarded-for', v_headers->>'x-real-ip', ''), ',', 1);
  begin
    v_ip := nullif(trim(v_forwarded), '')::inet;
  exception when others then
    v_ip := null;
  end;

  v_country := nullif(trim(coalesce(
    v_headers->>'cf-ipcountry',
    v_headers->>'x-country-code',
    v_headers->>'cloudfront-viewer-country',
    p_country_hint,
    ''
  )), '');

  -- Serialize checks for the same visitor/code to reduce duplicate race conditions.
  perform pg_advisory_xact_lock(hashtext(p_code || ':' || coalesce(host(v_ip), v_visitor_id)));

  if v_ip is not null then
    select exists (
      select 1 from public."Visits" v
      where trim(v.code) = p_code
        and v.visitor_ip_address = v_ip
        and v.link_visit_date >= now() - interval '24 hours'
    ) into v_duplicate;
  else
    select exists (
      select 1 from public."Visits" v
      where trim(v.code) = p_code
        and v.visitor_id = v_visitor_id
        and v.link_visit_date >= now() - interval '24 hours'
    ) into v_duplicate;
  end if;

  -- If the same IP first visited anonymously and then signs in within 24 hours,
  -- keep one valid visit but attach the verified member ID to that visit.
  if v_duplicate and v_authenticated_visit and v_ip is not null then
    update public."Visits"
    set visitor_id = v_visitor_id
    where id = (
      select v.id from public."Visits" v
      where trim(v.code) = p_code
        and v.visitor_ip_address = v_ip
        and v.visitor_id ~ '^V[0-9]+$'
        and v.link_visit_date >= now() - interval '24 hours'
      order by v.link_visit_date desc
      limit 1
    );
  end if;

  if not v_duplicate then
    insert into public."Visits" (
      owner_id,
      code,
      link_level,
      publisher_bonus_status,
      publisher_bonus_percentage,
      visitor_ip_address,
      visitor_country,
      visitor_id
    ) values (
      v_link.owner_id,
      trim(v_link.code),
      v_link.link_level,
      v_link.publisher_bonus_status,
      v_link.publisher_bonus_percentage,
      v_ip,
      v_country,
      v_visitor_id
    );

    update public."Links"
    set number_of_visits = number_of_visits + 1,
        link_last_visit_date = now()
    where id = v_link.id;

    -- Keep public discovery analytics synchronized when the dashboard schema is installed.
    if to_regclass('public."Find"') is not null then
      execute 'update public."Find" set visits = visits + 1, destination = destination + 1 where trim(code) = $1'
      using p_code;
    end if;

    v_recorded := true;
  end if;

  return jsonb_build_object(
    'destination_link', v_link.destination_link,
    'visit_recorded', v_recorded,
    'duplicate_within_24h', v_duplicate,
    'visitor_country', v_country,
    'visitor_id', v_visitor_id,
    'authenticated_visit', v_authenticated_visit
  );
end;
$$;

revoke all on function public.record_visit_and_get_destination(text, text, text, text, text) from public;
grant execute on function public.record_visit_and_get_destination(text, text, text, text, text) to anon, authenticated;

-- The public must not bypass the function and write arbitrary visit rows.
revoke insert, update, delete on table public."Visits" from anon;

-- Optional but recommended: keep private link fields unavailable to anonymous REST queries.
revoke select on table public."Links" from anon;
grant select (
  code,
  code_status,
  link_level,
  link_expiration_date
) on table public."Links" to anon;

-- Production note:
-- The waiting timer and AdBlueMedia browser lead check are client-side gates.
-- For tamper-resistant CPA enforcement, configure an AdBlueMedia server postback
-- to a Supabase Edge Function and issue a short-lived unlock token before calling
-- record_visit_and_get_destination.

-- LinkCode report feature for Redirect.html
-- Run this file once in the Supabase SQL Editor after creating public."Reports".
-- It inserts the report and increments Links.number_of_reports atomically.

alter table public."Reports" enable row level security;
alter table public."Reports" add column if not exists destination_link text null;

update public."Reports" r
set destination_link = l.destination_link
from public."Links" l
where trim(l.code) = trim(r.code)
  and r.owner_id = l.owner_id
  and r.destination_link is null;

create or replace function public.submit_link_report(
  p_code text,
  p_level text,
  p_subject text
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_link_id bigint;
  v_owner_id text;
  v_actual_level text;
  v_destination_link text;
  v_report_id bigint;
begin
  if p_code is null or p_code !~ '^[0-9]{6}$' then
    raise exception 'INVALID_CODE';
  end if;

  if p_level is null or p_level not in ('LV0', 'LV1', 'LV2', 'LV3', 'LV4', 'LV5') then
    raise exception 'INVALID_LEVEL';
  end if;

  if p_subject is null or p_subject not in (
    'Copyright violation',
    'Virus or malware',
    'Adult content',
    'Misleading content'
  ) then
    raise exception 'INVALID_REPORT_SUBJECT';
  end if;

  select id, owner_id, link_level, destination_link
  into v_link_id, v_owner_id, v_actual_level, v_destination_link
  from public."Links"
  where trim(code) = p_code
  limit 1;

  if not found then
    raise exception 'CODE_NOT_FOUND';
  end if;

  if v_actual_level <> p_level then
    raise exception 'LEVEL_MISMATCH:%', v_actual_level;
  end if;

  -- Keep the report insert and counter update serialized for this link.
  perform pg_advisory_xact_lock(hashtext('report:' || p_code));

  insert into public."Reports" (
    owner_id,
    code,
    link_level,
    report_subject,
    report_status,
    destination_link
  ) values (
    v_owner_id,
    p_code,
    v_actual_level,
    p_subject,
    'Valid',
    v_destination_link
  )
  returning id into v_report_id;

  update public."Links"
  set number_of_reports = number_of_reports + 1
  where id = v_link_id;

  return jsonb_build_object(
    'success', true,
    'report_id', v_report_id,
    'code', p_code,
    'report_subject', p_subject
  );
end;
$$;

revoke all on function public.submit_link_report(text, text, text) from public;
grant execute on function public.submit_link_report(text, text, text) to anon, authenticated;

-- Reports must only be inserted through submit_link_report.
revoke insert, update, delete on table public."Reports" from anon;

