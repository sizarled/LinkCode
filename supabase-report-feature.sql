-- LinkCode report feature for Redirect.html
-- Run this file once in the Supabase SQL Editor after creating public."Reports".
-- It inserts the report and increments Links.number_of_reports atomically.

alter table public."Reports" enable row level security;
alter table public."Reports" add column if not exists destination_link text null;

-- Preserve the destination associated with existing reports when possible.
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
