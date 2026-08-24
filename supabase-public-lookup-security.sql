-- LinkCode public lookup hardening for Supabase
-- Run this in the Supabase SQL Editor before production.
-- It allows the Unlock page to read only the fields required for verification.
-- destination_link, owner_id, earnings, reports, and other private fields remain unavailable to anon users.

alter table public."Links" enable row level security;

-- Replace this policy name if you already created an equivalent public lookup policy.
drop policy if exists "Public can verify LinkCodes" on public."Links";

create policy "Public can verify LinkCodes"
on public."Links"
for select
to anon
using (true);

-- Remove broad anonymous table access, then grant only the four lookup columns.
revoke select on table public."Links" from anon;
grant select (
  code,
  code_status,
  link_level,
  link_expiration_date
) on table public."Links" to anon;

-- Important production recommendation:
-- Place public code verification behind a rate-limited Supabase Edge Function
-- if you need stronger protection against automated six-digit code enumeration.
