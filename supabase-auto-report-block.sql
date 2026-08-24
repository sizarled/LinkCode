-- Automatically block links after enough VALID reports with the same reason.
-- Thresholds: LV0=1, LV1=10, LV2=100, LV3=1,000, LV4=10,000, LV5=100,000.
-- Run after Links, Find, Reports, and the report submission RPC are installed.

alter table public."Reports" add column if not exists destination_link text null;
update public."Reports" r set destination_link=l.destination_link from public."Links" l
where r.owner_id=l.owner_id and trim(r.code)=trim(l.code) and r.destination_link is null;

alter table public."Links" add column if not exists report_auto_blocked boolean not null default false;
alter table public."Links" add column if not exists report_auto_blocked_at timestamp with time zone null;
alter table public."Links" add column if not exists report_auto_block_subject text null;
alter table public."Links" add column if not exists report_auto_block_count bigint not null default 0;
alter table public."Links" add column if not exists report_previous_code_status text null;
alter table public."Links" add column if not exists report_previous_visibility text null;
alter table public."Links" add column if not exists report_previous_find_status text null;

create index if not exists reports_auto_block_lookup_idx
on public."Reports" (owner_id, code, report_status, report_subject, destination_link);

create or replace function public.report_threshold_for_level(p_level text)
returns bigint
language sql
immutable
as $$
  select case p_level
    when 'LV0' then 1::bigint
    when 'LV1' then 10::bigint
    when 'LV2' then 100::bigint
    when 'LV3' then 1000::bigint
    when 'LV4' then 10000::bigint
    when 'LV5' then 100000::bigint
    else 100000::bigint
  end;
$$;

create or replace function public.evaluate_link_report_block(
  p_owner_id text,
  p_code text
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_link public."Links"%rowtype;
  v_threshold bigint;
  v_subject text;
  v_destination text;
  v_valid_count bigint := 0;
  v_find_visibility text;
  v_find_status text;
  v_admin_blocked boolean := false;
begin
  perform pg_advisory_xact_lock(hashtext('auto-report-block:' || p_owner_id || ':' || p_code));

  select * into v_link
  from public."Links"
  where owner_id = p_owner_id and trim(code) = trim(p_code)
  for update;

  if not found then
    return jsonb_build_object('success', false, 'reason', 'LINK_NOT_FOUND');
  end if;

  v_threshold := public.report_threshold_for_level(v_link.link_level);
  v_admin_blocked := coalesce((to_jsonb(v_link)->>'admin_publication_blocked')::boolean, false);

  select r.report_subject, coalesce(r.destination_link, v_link.destination_link), count(*)::bigint
  into v_subject, v_destination, v_valid_count
  from public."Reports" r
  where r.owner_id = p_owner_id
    and trim(r.code) = trim(p_code)
    and r.report_status = 'Valid'
  group by r.report_subject, coalesce(r.destination_link, v_link.destination_link)
  having count(*) >= v_threshold
  order by count(*) desc, r.report_subject
  limit 1;

  if v_subject is not null then
    select f.visibility, f.link_status into v_find_visibility, v_find_status
    from public."Find" f
    where f.owner_id = p_owner_id and trim(f.code) = trim(p_code)
    limit 1;

    update public."Links"
    set report_auto_blocked = true,
        report_auto_blocked_at = coalesce(report_auto_blocked_at, now()),
        report_auto_block_subject = v_subject,
        report_auto_block_count = v_valid_count,
        report_previous_code_status = case when report_auto_blocked then report_previous_code_status else code_status end,
        report_previous_visibility = case when report_auto_blocked then report_previous_visibility else coalesce(v_find_visibility, 'Private') end,
        report_previous_find_status = case when report_auto_blocked then report_previous_find_status else coalesce(v_find_status, 'Disabled') end,
        code_status = 'Blocked'
    where id = v_link.id;

    update public."Find"
    set visibility = 'Private', link_status = 'Blocked'
    where owner_id = p_owner_id and trim(code) = trim(p_code);

    if not v_link.report_auto_blocked and to_regclass('public."Notifications"') is not null then
      execute 'insert into public."Notifications"(recipient_id,notification_scope,notification_category,notification_title,notification_body,reference_type,reference_id)
        values($1,''Member'',''Reports'',''Link automatically blocked'',$2,''Link'',$3)'
      using p_owner_id, 'Code '||trim(p_code)||' reached '||v_threshold||' valid "'||v_subject||'" reports.', v_link.id::text;
    end if;

    return jsonb_build_object(
      'success', true,
      'blocked', true,
      'subject', v_subject,
      'valid_reports', v_valid_count,
      'threshold', v_threshold
    );
  end if;

  -- If administrators expire enough reports to move below every threshold,
  -- restore only links that were blocked by this automatic system.
  if v_link.report_auto_blocked then
    update public."Links"
    set report_auto_blocked = false,
        report_auto_blocked_at = null,
        report_auto_block_subject = null,
        report_auto_block_count = 0,
        code_status = coalesce(report_previous_code_status, 'Active'),
        report_previous_code_status = null
    where id = v_link.id;

    if not v_admin_blocked then
      update public."Find"
      set visibility = coalesce(v_link.report_previous_visibility, 'Private'),
          link_status = coalesce(v_link.report_previous_find_status, 'Disabled')
      where owner_id = p_owner_id and trim(code) = trim(p_code);
    end if;

    update public."Links"
    set report_previous_visibility = null,
        report_previous_find_status = null
    where id = v_link.id;

    return jsonb_build_object('success', true, 'blocked', false, 'threshold', v_threshold);
  end if;

  return jsonb_build_object('success', true, 'blocked', false, 'threshold', v_threshold);
end;
$$;

revoke all on function public.evaluate_link_report_block(text, text) from public;
grant execute on function public.evaluate_link_report_block(text, text) to anon, authenticated;

create or replace function public.reports_auto_block_after_insert()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  perform public.evaluate_link_report_block(new.owner_id, trim(new.code));
  return new;
end;
$$;

drop trigger if exists reports_auto_block_after_insert_trigger on public."Reports";
create trigger reports_auto_block_after_insert_trigger
after insert on public."Reports"
for each row execute function public.reports_auto_block_after_insert();

-- Evaluate reports that already existed before this feature was installed.
do $$
declare
  item record;
begin
  for item in select distinct owner_id, trim(code) as code from public."Reports" loop
    perform public.evaluate_link_report_block(item.owner_id, item.code);
  end loop;
end;
$$;
