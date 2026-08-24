-- Fix legacy Profiles usernames that contain spaces, line breaks, or unsupported characters.
-- Safe to run more than once.

do $$
declare
  r record;
  v_candidate text;
  v_suffix text;
begin
  for r in select id, username from public."Profiles" order by id loop
    v_candidate := regexp_replace(
      btrim(coalesce(r.username, '')),
      '[^A-Za-z0-9_]+',
      '_',
      'g'
    );
    v_candidate := btrim(v_candidate, '_');

    if char_length(v_candidate) < 3 then
      v_candidate := 'member_' || lower(r.id);
    end if;
    v_candidate := left(v_candidate, 30);

    if exists (
      select 1 from public."Profiles" p
      where p.id <> r.id and lower(p.username) = lower(v_candidate)
    ) then
      v_suffix := '_' || lower(r.id);
      v_candidate := left(v_candidate, greatest(3, 30 - char_length(v_suffix))) || v_suffix;
      v_candidate := left(v_candidate, 30);
    end if;

    if exists (
      select 1 from public."Profiles" p
      where p.id <> r.id and lower(p.username) = lower(v_candidate)
    ) then
      v_suffix := '_' || substr(md5(r.id), 1, 8);
      v_candidate := left(v_candidate, greatest(3, 30 - char_length(v_suffix))) || v_suffix;
      v_candidate := left(v_candidate, 30);
    end if;

    update public."Profiles"
    set username = v_candidate
    where id = r.id and username is distinct from v_candidate;
  end loop;
end;
$$;

-- Optional verification: this should return zero rows.
select id, username
from public."Profiles"
where username !~ '^[A-Za-z0-9_]{3,30}$';
