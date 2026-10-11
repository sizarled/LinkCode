-- ============================================================================
-- LINKCODE — ANALYTICS DATE-RANGE FILTER
-- ----------------------------------------------------------------------------
-- RPC: dashboard_analytics_range(p_session_token, p_period)
--
--   p_period := 'today' | 'week' | 'month' | 'year' | 'all'  (default 'all')
--
-- Returns the signed-in member's analytics scoped to the chosen period:
--   • total_visits / visit_earnings / reports ... filtered by visit/report date
--   • visits_by_link ............................ visits per code in the period
--   • visit_sources ............................. member vs guest split (period)
--   • countries ................................. country analytics (period)
--   • total_impressions / total_clicks ......... all-time counters (the Find
--     table has no per-event timestamp, so those cannot be date-scoped)
--
-- Depends on public.dashboard_session_owner (defined in supabase-dashboard.sql).
-- Run this file AFTER supabase-dashboard.sql, or re-run the full dashboard SQL.
-- ============================================================================

create or replace function public.dashboard_analytics_range(
  p_session_token text,
  p_period text default 'all'
)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_owner text := public.dashboard_session_owner(p_session_token);
  v_from timestamptz;
begin
  if v_owner is null then
    return jsonb_build_object('success', false, 'reason', 'UNAUTHORIZED');
  end if;

  -- Period start boundary (inclusive). 'all' keeps v_from NULL => no filter.
  v_from := case p_period
    when 'today' then date_trunc('day', now())
    when 'week'  then date_trunc('week', now())
    when 'month' then date_trunc('month', now())
    when 'year'  then date_trunc('year', now())
    else null
  end;

  return jsonb_build_object(
    'success', true,
    'period', coalesce(p_period, 'all'),
    'from_date', v_from,
    'total_visits', coalesce((
      select count(*) from public."Visits" v
      where v.owner_id = v_owner and (v_from is null or v.link_visit_date >= v_from)
    ), 0),
    'total_reports', coalesce((
      select count(*) from public."Reports" r
      where r.owner_id = v_owner and (v_from is null or r.report_date >= v_from)
    ), 0),
    'total_impressions', coalesce((
      select sum(f.images) from public."Find" f where f.owner_id = v_owner
    ), 0),
    'total_clicks', coalesce((
      select sum(f.clicks) from public."Find" f where f.owner_id = v_owner
    ), 0),
    'visit_earnings', coalesce((
      select sum(v.visit_earnings) from public."Visits" v
      where v.owner_id = v_owner and (v_from is null or v.link_visit_date >= v_from)
    ), 0),
    'visits_by_link', coalesce((
      select jsonb_agg(jsonb_build_object(
        'code', trim(x.code),
        'link_level', x.link_level,
        'visits', x.visits
      ) order by x.visits desc)
      from (
        select trim(v.code) as code, max(v.link_level) as link_level, count(*)::bigint as visits
        from public."Visits" v
        where v.owner_id = v_owner and (v_from is null or v.link_visit_date >= v_from)
        group by trim(v.code)
      ) x
    ), '[]'::jsonb),
    'visit_sources', jsonb_build_object(
      'member_visits', coalesce((
        select count(*) from public."Visits" v
        where v.owner_id = v_owner and v.visitor_id ~ '^ID[0-9]+$'
          and (v_from is null or v.link_visit_date >= v_from)
      ), 0),
      'visitor_visits', coalesce((
        select count(*) from public."Visits" v
        where v.owner_id = v_owner and v.visitor_id ~ '^V[0-9]+$'
          and (v_from is null or v.link_visit_date >= v_from)
      ), 0),
      'unique_members', coalesce((
        select count(distinct v.visitor_id) from public."Visits" v
        where v.owner_id = v_owner and v.visitor_id ~ '^ID[0-9]+$'
          and (v_from is null or v.link_visit_date >= v_from)
      ), 0),
      'unique_guests', coalesce((
        select count(distinct v.visitor_id) from public."Visits" v
        where v.owner_id = v_owner and v.visitor_id ~ '^V[0-9]+$'
          and (v_from is null or v.link_visit_date >= v_from)
      ), 0),
      'member_earnings', coalesce((
        select sum(v.visit_earnings) from public."Visits" v
        where v.owner_id = v_owner and v.visitor_id ~ '^ID[0-9]+$'
          and (v_from is null or v.link_visit_date >= v_from)
      ), 0),
      'visitor_earnings', coalesce((
        select sum(v.visit_earnings) from public."Visits" v
        where v.owner_id = v_owner and v.visitor_id ~ '^V[0-9]+$'
          and (v_from is null or v.link_visit_date >= v_from)
      ), 0)
    ),
    'countries', coalesce((
      select jsonb_agg(jsonb_build_object(
        'country', c.country,
        'visits', c.visits,
        'member_visits', c.member_visits,
        'visitor_visits', c.visitor_visits,
        'unique_visitors', c.unique_visitors,
        'unique_members', c.unique_members,
        'unique_guests', c.unique_guests,
        'links_visited', c.links_visited,
        'earnings', c.earnings,
        'last_visit', c.last_visit
      ) order by c.visits desc, c.country asc)
      from (
        select
          coalesce(nullif(trim(v.visitor_country), ''), 'Unknown') as country,
          count(*)::bigint as visits,
          count(*) filter (where v.visitor_id ~ '^ID[0-9]+$')::bigint as member_visits,
          count(*) filter (where v.visitor_id ~ '^V[0-9]+$')::bigint as visitor_visits,
          count(distinct v.visitor_id)::bigint as unique_visitors,
          count(distinct v.visitor_id) filter (where v.visitor_id ~ '^ID[0-9]+$')::bigint as unique_members,
          count(distinct v.visitor_id) filter (where v.visitor_id ~ '^V[0-9]+$')::bigint as unique_guests,
          count(distinct trim(v.code))::bigint as links_visited,
          coalesce(sum(v.visit_earnings), 0)::numeric as earnings,
          max(v.link_visit_date) as last_visit
        from public."Visits" v
        where v.owner_id = v_owner and (v_from is null or v.link_visit_date >= v_from)
        group by coalesce(nullif(trim(v.visitor_country), ''), 'Unknown')
      ) c
    ), '[]'::jsonb)
  );
end;
$$;

revoke all on function public.dashboard_analytics_range(text, text) from public;
grant execute on function public.dashboard_analytics_range(text, text) to anon, authenticated;
