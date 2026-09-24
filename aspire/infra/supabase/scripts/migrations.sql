-- ============================================
-- SUPABASE MIGRATIONS (auto-generated)
-- Generated at: 2026-09-21 19:20:21
-- Source: C:\temp\RunXc.Timing\supabase\migrations
-- ============================================

DO $$
DECLARE
    retry_count integer := 0;
    max_retries integer := 150;  -- ~5 min at 2s/iteration
    auth_ok boolean;
    storage_ok boolean;
BEGIN
    LOOP
        auth_ok := EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema = 'auth' AND table_name = 'users' AND column_name = 'email_confirmed_at');
        storage_ok := EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema = 'storage' AND table_name = 'buckets' AND column_name = 'public');
        EXIT WHEN (auth_ok AND storage_ok) OR retry_count >= max_retries;
        PERFORM pg_sleep(2);
        retry_count := retry_count + 1;
        IF retry_count % 5 = 0 THEN
            RAISE NOTICE '[Migrations] readiness poll: auth=% storage=% (attempt %/%)', auth_ok, storage_ok, retry_count, max_retries;
        END IF;
    END LOOP;
    RAISE NOTICE '[Migrations] readiness poll done: auth=% storage=%', auth_ok, storage_ok;
END;
$$;

-- HARD auth gate: abort LOUDLY if GoTrue never migrated. In publish the whole file runs as one
-- `psql -f` inside a `set -e && ... && echo Completed` chain, so ON_ERROR_STOP makes psql exit
-- non-zero and the init container fail instead of running app migrations + the seed against a
-- half-migrated schema. Locally post_init.sh ignores the exit code (degrade, never brick).
\set ON_ERROR_STOP on
DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema = 'auth' AND table_name = 'users' AND column_name = 'email_confirmed_at') THEN
        RAISE EXCEPTION '[Migrations] ABORT: auth schema not migrated (auth.users.email_confirmed_at missing) after readiness timeout - GoTrue did not finish its startup migrations. Refusing to run migrations against a half-migrated schema.';
    END IF;
END;
$$;
\set ON_ERROR_STOP off

-- Run-once tracking table (mimics supabase_migrations.schema_migrations)
CREATE TABLE IF NOT EXISTS public._aspire_applied_migrations (
    filename   text PRIMARY KEY,
    applied_at timestamptz NOT NULL DEFAULT now()
);

\set ON_ERROR_STOP off

-- Migration: 20260906000001_init.sql
-- ----------------------------------------
SELECT (NOT EXISTS (SELECT 1 FROM public._aspire_applied_migrations WHERE filename = '20260906000001_init.sql'))::text AS _run_mig \gset
\if :_run_mig
BEGIN;
-- timing.runXC.run — initial schema
-- Capability-based access (no auth in v1): race-scoped writes require the X-Race-Code
-- header, meet-management writes require X-Meet-Admin-Code. Both are checked in RLS.

create extension if not exists pgcrypto;

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------

-- Read an HTTP request header forwarded by PostgREST.
create or replace function public.hdr(p_name text)
returns text
language sql
stable
as $$
  select nullif(
    (current_setting('request.headers', true)::jsonb ->> p_name),
    ''
  );
$$;

-- Uppercase, strip non-alphanumerics — canonical form for all codes.
create or replace function public.normalize_code(p_code text)
returns text
language sql
immutable
as $$
  select upper(regexp_replace(coalesce(p_code, ''), '[^A-Za-z0-9]', '', 'g'));
$$;

-- 6-char code from an unambiguous alphabet (no 0/O/1/I/L).
create or replace function public.gen_code(p_table regclass, p_column text)
returns text
language plpgsql
as $$
declare
  v_alphabet text := '23456789ABCDEFGHJKMNPQRSTUVWXYZ';
  v_code text;
  v_exists boolean;
  v_sql text;
begin
  loop
    v_code := '';
    for i in 1..6 loop
      v_code := v_code || substr(v_alphabet, 1 + floor(random() * length(v_alphabet))::int, 1);
    end loop;
    execute format('select exists(select 1 from %s where %I = $1)', p_table, p_column)
      into v_exists using v_code;
    exit when not v_exists;
  end loop;
  return v_code;
end;
$$;

-- ---------------------------------------------------------------------------
-- Tables
-- ---------------------------------------------------------------------------

create table public.meets (
  id uuid primary key default gen_random_uuid(),
  name text not null check (char_length(name) between 1 and 120),
  location text,
  meet_date date,
  admin_code text not null unique,
  created_at timestamptz not null default now()
);

create table public.schools (
  id uuid primary key default gen_random_uuid(),
  meet_id uuid not null references public.meets(id) on delete cascade,
  name text not null check (char_length(name) between 1 and 120),
  unique (meet_id, name)
);

create table public.races (
  id uuid primary key default gen_random_uuid(),
  meet_id uuid not null references public.meets(id) on delete cascade,
  name text not null check (char_length(name) between 1 and 120),
  scheduled_start timestamptz,
  race_code text not null unique,
  status text not null default 'draft'
    check (status in ('draft','registration_open','ready','running','finalized')),
  team_size int not null default 5 check (team_size between 1 and 10),
  tiebreak_depth int not null default 6 check (tiebreak_depth between 1 and 12),
  started_at timestamptz,
  start_device_id text,
  finalized_at timestamptz,
  created_at timestamptz not null default now()
);

-- An athlete row is either an unclaimed pool code (name is null, from CSV import)
-- or a registered athlete. Codes are unique per race.
create table public.athletes (
  id uuid primary key default gen_random_uuid(),
  race_id uuid not null references public.races(id) on delete cascade,
  code text not null,
  name text,
  school_id uuid references public.schools(id) on delete set null,
  grade text,
  source text not null default 'self' check (source in ('self','import','assigned')),
  registered_at timestamptz,
  created_at timestamptz not null default now(),
  unique (race_id, code)
);

create table public.finish_slots (
  id uuid primary key default gen_random_uuid(),
  race_id uuid not null references public.races(id) on delete cascade,
  seq int not null,
  t0_offset_ms bigint not null,
  captured_at timestamptz not null default now(),
  device_id text not null,
  athlete_id uuid references public.athletes(id) on delete set null,
  status text not null default 'open'
    check (status in ('open','matched','dq','dnf')),
  place int,
  updated_at timestamptz not null default now(),
  unique (race_id, seq)
);

create index idx_athletes_race on public.athletes (race_id);
create index idx_slots_race_seq on public.finish_slots (race_id, seq);
create index idx_slots_race_status on public.finish_slots (race_id, status);

-- ---------------------------------------------------------------------------
-- Row level security
-- ---------------------------------------------------------------------------

alter table public.meets enable row level security;
alter table public.schools enable row level security;
alter table public.races enable row level security;
alter table public.athletes enable row level security;
alter table public.finish_slots enable row level security;

-- Meets: anyone may create one (organizer entry point) and read basic info.
create policy meets_select on public.meets for select to anon using (true);
create policy meets_insert on public.meets for insert to anon with check (true);
create policy meets_update on public.meets for update to anon
  using (admin_code = public.hdr('x-meet-admin-code'));
create policy meets_delete on public.meets for delete to anon
  using (admin_code = public.hdr('x-meet-admin-code'));

-- Schools: readable (registration dropdown needs them); writes need admin code.
create policy schools_select on public.schools for select to anon using (true);
create policy schools_insert on public.schools for insert to anon
  with check (exists (
    select 1 from public.meets m
    where m.id = meet_id and m.admin_code = public.hdr('x-meet-admin-code')
  ));
create policy schools_update on public.schools for update to anon
  using (exists (
    select 1 from public.meets m
    where m.id = meet_id and m.admin_code = public.hdr('x-meet-admin-code')
  ));
create policy schools_delete on public.schools for delete to anon
  using (exists (
    select 1 from public.meets m
    where m.id = meet_id and m.admin_code = public.hdr('x-meet-admin-code')
  ));

-- Races: readable (results pages); create needs meet admin; update allowed for
-- meet admin OR race-code holders (the timing console updates status/started_at).
create policy races_select on public.races for select to anon using (true);
create policy races_insert on public.races for insert to anon
  with check (exists (
    select 1 from public.meets m
    where m.id = meet_id and m.admin_code = public.hdr('x-meet-admin-code')
  ));
create policy races_update on public.races for update to anon
  using (
    exists (
      select 1 from public.meets m
      where m.id = meet_id and m.admin_code = public.hdr('x-meet-admin-code')
    )
    or race_code = upper(public.hdr('x-race-code'))
  );
create policy races_delete on public.races for delete to anon
  using (exists (
    select 1 from public.meets m
    where m.id = meet_id and m.admin_code = public.hdr('x-meet-admin-code')
  ));

-- Athletes: roster readable; writes need the race code (registration + console).
create policy athletes_select on public.athletes for select to anon using (true);
create policy athletes_insert on public.athletes for insert to anon
  with check (exists (
    select 1 from public.races r
    where r.id = race_id and r.race_code = upper(public.hdr('x-race-code'))
  ));
create policy athletes_update on public.athletes for update to anon
  using (exists (
    select 1 from public.races r
    where r.id = race_id and r.race_code = upper(public.hdr('x-race-code'))
  ));
create policy athletes_delete on public.athletes for delete to anon
  using (exists (
    select 1 from public.races r
    where r.id = race_id and r.race_code = upper(public.hdr('x-race-code'))
  ));

-- Finish slots: readable (live board); writes need the race code.
create policy slots_select on public.finish_slots for select to anon using (true);
create policy slots_insert on public.finish_slots for insert to anon
  with check (exists (
    select 1 from public.races r
    where r.id = race_id and r.race_code = upper(public.hdr('x-race-code'))
  ));
create policy slots_update on public.finish_slots for update to anon
  using (exists (
    select 1 from public.races r
    where r.id = race_id and r.race_code = upper(public.hdr('x-race-code'))
  ));
create policy slots_delete on public.finish_slots for delete to anon
  using (exists (
    select 1 from public.races r
    where r.id = race_id and r.race_code = upper(public.hdr('x-race-code'))
  ));

grant usage on schema public to anon;
grant select, insert, update, delete on all tables in schema public to anon;
grant execute on all functions in schema public to anon;

-- ---------------------------------------------------------------------------
-- Registration RPC
-- ---------------------------------------------------------------------------

-- Join a race with the race code. If p_code is null/empty the system assigns a
-- fresh code (walk-up). Claims an unclaimed pool code when one matches.
create or replace function public.join_race(
  p_race_code text,
  p_name text,
  p_school_id uuid default null,
  p_grade text default null,
  p_code text default null
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_race public.races%rowtype;
  v_athlete public.athletes%rowtype;
  v_code text;
begin
  select * into v_race from races
   where race_code = public.normalize_code(p_race_code);
  if not found then
    raise exception 'RACE_NOT_FOUND';
  end if;
  if v_race.status not in ('draft','registration_open','ready') then
    raise exception 'REGISTRATION_CLOSED';
  end if;
  if p_name is null or char_length(trim(p_name)) = 0 then
    raise exception 'NAME_REQUIRED';
  end if;

  v_code := public.normalize_code(p_code);

  if v_code is null or v_code = '' then
    -- Assign the next free generated code.
    v_code := public.gen_code('public.athletes'::regclass, 'code');
    -- gen_code only checks global uniqueness; ensure per-race uniqueness too.
    while exists (select 1 from athletes a where a.race_id = v_race.id and a.code = v_code) loop
      v_code := public.gen_code('public.athletes'::regclass, 'code');
    end loop;
  end if;

  if char_length(v_code) <> 6 then
    raise exception 'CODE_LENGTH';
  end if;

  select * into v_athlete from athletes
   where race_id = v_race.id and code = v_code;

  if found and v_athlete.name is not null then
    raise exception 'CODE_TAKEN';
  end if;

  if found then
    update athletes
       set name = trim(p_name),
           school_id = p_school_id,
           grade = nullif(trim(coalesce(p_grade,'')), ''),
           registered_at = now()
     where id = v_athlete.id
     returning * into v_athlete;
  else
    insert into athletes (race_id, code, name, school_id, grade, source, registered_at)
    values (v_race.id, v_code, trim(p_name), p_school_id,
            nullif(trim(coalesce(p_grade,'')), ''),
            case when p_code is null or trim(p_code) = '' then 'assigned' else 'self' end,
            now())
    returning * into v_athlete;
  end if;

  return jsonb_build_object(
    'athlete_id', v_athlete.id,
    'code', v_athlete.code,
    'race_id', v_race.id,
    'race_name', v_race.name
  );
end;
$$;

-- ---------------------------------------------------------------------------
-- Finalize + standings
-- ---------------------------------------------------------------------------

-- Assign finishing places (order of matched taps) and lock the race.
create or replace function public.finalize_race(p_race_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if not (
    exists (select 1 from races r where r.id = p_race_id
            and r.race_code = upper(public.hdr('x-race-code')))
    or exists (select 1 from races r join meets m on m.id = r.meet_id
               where r.id = p_race_id and m.admin_code = public.hdr('x-meet-admin-code'))
  ) then
    raise exception 'NOT_ALLOWED';
  end if;

  with ranked as (
    select s.id, row_number() over (order by s.seq) as rn
      from finish_slots s
     where s.race_id = p_race_id
       and s.status = 'matched'
       and s.athlete_id is not null
  )
  update finish_slots s
     set place = ranked.rn, updated_at = now()
    from ranked where ranked.id = s.id;

  update finish_slots
     set place = null, updated_at = now()
   where race_id = p_race_id
     and (status <> 'matched' or athlete_id is null);

  update races
     set status = 'finalized', finalized_at = now()
   where id = p_race_id;
end;
$$;

-- Team standings: sum of top team_size places; ties broken by the next
-- finisher(s) up to tiebreak_depth, then by fewest runners rule-out (tie).
create or replace function public.get_team_standings(p_race_id uuid)
returns table (
  school_id uuid,
  school_name text,
  score int,
  tiebreak int,
  finishers int,
  rank int
)
language sql
stable
security definer
set search_path = public
as $$
  with scored as (
    select
      a.school_id,
      s.place,
      row_number() over (partition by a.school_id order by s.place) as runner_rank
    from finish_slots s
    join athletes a on a.id = s.athlete_id
    where s.race_id = p_race_id
      and s.status = 'matched'
      and s.place is not null
      and a.school_id is not null
  ),
  teams as (
    select
      school_id,
      sum(case when runner_rank <= (select team_size from races where id = p_race_id)
               then place end)::int as score,
      sum(case when runner_rank > (select team_size from races where id = p_race_id)
                and runner_rank <= (select tiebreak_depth from races where id = p_race_id)
               then place end)::int as tiebreak,
      count(*)::int as finishers
    from scored
    group by school_id
  ),
  tb as (
    select t.school_id, t.score, t.finishers, t.tiebreak
    from teams t
  )
  select
    tb.school_id,
    sc.name as school_name,
    tb.score,
    tb.tiebreak,
    tb.finishers,
    -- Standard XC: complete teams (team_size finishers) rank ahead of
    -- incomplete teams; within a tier, low score wins, then tiebreak.
    rank() over (
      order by
        (tb.finishers >= (select team_size from races where id = p_race_id)) desc nulls last,
        tb.score asc nulls last,
        tb.tiebreak asc nulls last
    )::int as rank
  from tb
  join schools sc on sc.id = tb.school_id
  order by rank, sc.name;
$$;

-- ---------------------------------------------------------------------------
-- Realtime
-- ---------------------------------------------------------------------------

do $$
begin
  alter publication supabase_realtime add table public.finish_slots;
  alter publication supabase_realtime add table public.athletes;
exception
  when duplicate_object then null;
end;
$$;


INSERT INTO public._aspire_applied_migrations (filename) VALUES ('20260906000001_init.sql') ON CONFLICT (filename) DO NOTHING;
COMMIT;
\endif

-- Migration: 20260911000001_walkons_and_editable_results.sql
-- ----------------------------------------
SELECT (NOT EXISTS (SELECT 1 FROM public._aspire_applied_migrations WHERE filename = '20260911000001_walkons_and_editable_results.sql'))::text AS _run_mig \gset
\if :_run_mig
BEGIN;
-- timing.runXC.run — walk-on finishers and editable results
--
-- 1. A runner who shows up without registering can be recorded at the finish
--    line against a typed code; the athlete row stays unclaimed ("placeholder")
--    until they register with that same code.
-- 2. A race admin can insert a finisher above or below an existing result.

-- ---------------------------------------------------------------------------
-- Athlete source: allow 'placeholder'
-- ---------------------------------------------------------------------------

do $$
declare
  r record;
begin
  -- Drop whatever check currently guards `source` (name depends on how the
  -- table was created) so this migration is safe on every environment.
  for r in
    select con.conname
      from pg_constraint con
     where con.conrelid = 'public.athletes'::regclass
       and con.contype = 'c'
       and pg_get_constraintdef(con.oid) ilike '%source%'
  loop
    execute format('alter table public.athletes drop constraint %I', r.conname);
  end loop;
end;
$$;

alter table public.athletes
  add constraint athletes_source_check
  check (source in ('self', 'import', 'assigned', 'placeholder'));

-- ---------------------------------------------------------------------------
-- join_race: allow claiming a placeholder code after registration closes
-- ---------------------------------------------------------------------------

create or replace function public.join_race(
  p_race_code text,
  p_name text,
  p_school_id uuid default null,
  p_grade text default null,
  p_code text default null
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_race public.races%rowtype;
  v_athlete public.athletes%rowtype;
  v_code text;
  v_open boolean;
begin
  select * into v_race from races
   where race_code = public.normalize_code(p_race_code);
  if not found then
    raise exception 'RACE_NOT_FOUND';
  end if;
  if p_name is null or char_length(trim(p_name)) = 0 then
    raise exception 'NAME_REQUIRED';
  end if;

  v_open := v_race.status in ('draft', 'registration_open', 'ready');
  v_code := public.normalize_code(p_code);

  if v_code = '' then
    if not v_open then
      raise exception 'REGISTRATION_CLOSED';
    end if;
    -- Assign the next free generated code (gen_code checks globally only).
    v_code := public.gen_code('public.athletes'::regclass, 'code');
    while exists (select 1 from athletes a where a.race_id = v_race.id and a.code = v_code) loop
      v_code := public.gen_code('public.athletes'::regclass, 'code');
    end loop;
  else
    -- A code left unclaimed at the finish line stays claimable for ever, so a
    -- walk-on can attach their name (and school, for team scoring) afterwards.
    if not v_open and not exists (
      select 1 from athletes a
       where a.race_id = v_race.id and a.code = v_code and a.name is null
    ) then
      raise exception 'REGISTRATION_CLOSED';
    end if;
  end if;

  if char_length(v_code) <> 6 then
    raise exception 'CODE_LENGTH';
  end if;

  select * into v_athlete from athletes
   where race_id = v_race.id and code = v_code;

  if found and v_athlete.name is not null then
    raise exception 'CODE_TAKEN';
  end if;

  if found then
    update athletes
       set name = trim(p_name),
           school_id = p_school_id,
           grade = nullif(trim(coalesce(p_grade, '')), ''),
           registered_at = now()
     where id = v_athlete.id
     returning * into v_athlete;
  else
    insert into athletes (race_id, code, name, school_id, grade, source, registered_at)
    values (v_race.id, v_code, trim(p_name), p_school_id,
            nullif(trim(coalesce(p_grade, '')), ''),
            case when p_code is null or trim(p_code) = '' then 'assigned' else 'self' end,
            now())
    returning * into v_athlete;
  end if;

  return jsonb_build_object(
    'athlete_id', v_athlete.id,
    'code', v_athlete.code,
    'race_id', v_race.id,
    'race_name', v_race.name
  );
end;
$$;

-- ---------------------------------------------------------------------------
-- insert_slot_relative: add a finisher above or below an existing result
-- ---------------------------------------------------------------------------

-- p_anchor_slot_id null appends to the end of the order. p_code may name an
-- existing athlete or a brand new (unregistered) code; omit it to create an
-- open slot to match later. Places are recomputed when the race is finalized.
create or replace function public.insert_slot_relative(
  p_race_id uuid,
  p_anchor_slot_id uuid default null,
  p_side text default 'before',
  p_code text default null,
  p_device_id text default 'admin-edit'
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_race public.races%rowtype;
  v_anchor public.finish_slots%rowtype;
  v_athlete public.athletes%rowtype;
  v_slot public.finish_slots%rowtype;
  v_target int;
  v_max int;
  v_prev bigint;
  v_next bigint;
  v_offset bigint;
  v_code text;
begin
  select * into v_race from races where id = p_race_id;
  if not found then
    raise exception 'RACE_NOT_FOUND';
  end if;

  if not (
    exists (select 1 from races r where r.id = p_race_id
            and r.race_code = upper(public.hdr('x-race-code')))
    or exists (select 1 from races r join meets m on m.id = r.meet_id
               where r.id = p_race_id and m.admin_code = public.hdr('x-meet-admin-code'))
  ) then
    raise exception 'NOT_ALLOWED';
  end if;

  if p_anchor_slot_id is null then
    select coalesce(max(seq), 0) into v_max from finish_slots where race_id = p_race_id;
    v_target := v_max + 1;
  else
    select * into v_anchor from finish_slots
     where id = p_anchor_slot_id and race_id = p_race_id;
    if not found then
      raise exception 'SLOT_NOT_FOUND';
    end if;
    if p_side not in ('before', 'after') then
      raise exception 'BAD_SIDE';
    end if;
    v_target := v_anchor.seq + case when p_side = 'after' then 1 else 0 end;
  end if;

  -- Make room. Two passes through negative seq so the unique (race_id, seq)
  -- index is never violated mid-statement.
  update finish_slots set seq = -seq
   where race_id = p_race_id and seq >= v_target;
  update finish_slots set seq = -seq + 1
   where race_id = p_race_id and seq <= -v_target;

  -- No stopwatch time exists for a runner added after the fact: interpolate
  -- between the new neighbours so the results sheet stays sensible.
  select max(t0_offset_ms) into v_prev from finish_slots
   where race_id = p_race_id and seq < v_target;
  select min(t0_offset_ms) into v_next from finish_slots
   where race_id = p_race_id and seq > v_target;
  v_offset := case
    when v_prev is not null and v_next is not null then (v_prev + v_next) / 2
    when v_next is not null then greatest(v_next - 1000, 0)
    when v_prev is not null then v_prev + 1000
    else 0
  end;

  v_code := nullif(public.normalize_code(p_code), '');
  if v_code is not null then
    select * into v_athlete from athletes
     where race_id = p_race_id and code = v_code;
    if not found then
      insert into athletes (race_id, code, source)
        values (p_race_id, v_code, 'placeholder')
        returning * into v_athlete;
    end if;
  end if;

  insert into finish_slots (race_id, seq, t0_offset_ms, device_id, athlete_id, status)
  values (p_race_id, v_target, v_offset, coalesce(nullif(p_device_id, ''), 'admin-edit'),
          v_athlete.id,
          case when v_athlete.id is null then 'open' else 'matched' end)
  returning * into v_slot;

  if v_race.status = 'finalized' then
    with ranked as (
      select id, row_number() over (order by seq) as rn
        from finish_slots
       where race_id = p_race_id
         and status = 'matched'
         and athlete_id is not null
    )
    update finish_slots s
       set place = ranked.rn, updated_at = now()
      from ranked where ranked.id = s.id;
    select * into v_slot from finish_slots where id = v_slot.id;
  end if;

  return jsonb_build_object(
    'slot_id', v_slot.id,
    'seq', v_slot.seq,
    'place', v_slot.place,
    'athlete_id', v_slot.athlete_id,
    'code', v_athlete.code,
    'status', v_slot.status
  );
end;
$$;

grant execute on function public.join_race(text, text, uuid, text, text) to anon;
grant execute on function public.insert_slot_relative(uuid, uuid, text, text, text) to anon;


INSERT INTO public._aspire_applied_migrations (filename) VALUES ('20260911000001_walkons_and_editable_results.sql') ON CONFLICT (filename) DO NOTHING;
COMMIT;
\endif

-- Migration: 20260912000001_meet_admins.sql
-- ----------------------------------------
SELECT (NOT EXISTS (SELECT 1 FROM public._aspire_applied_migrations WHERE filename = '20260912000001_meet_admins.sql'))::text AS _run_mig \gset
\if :_run_mig
BEGIN;
-- timing.runXC.run — registered meet/race admins
--
-- Organizers now register (name + email) when they create a meet, and can
-- delegate administration to other people. Each admin gets their own 6-char
-- credential, presented in the same X-Meet-Admin-Code header the owner code
-- uses, so any of them can create races, manage schools and edit results.
-- Emails are never publicly readable: meet_admins has no anonymous select.

-- ---------------------------------------------------------------------------
-- Table
-- ---------------------------------------------------------------------------

create table public.meet_admins (
  id uuid primary key default gen_random_uuid(),
  meet_id uuid not null references public.meets (id) on delete cascade,
  email text not null,
  name text,
  code text not null unique,
  role text not null default 'admin' check (role in ('owner', 'admin')),
  created_at timestamptz not null default now(),
  unique (meet_id, email)
);

create index meet_admins_meet_id_idx on public.meet_admins (meet_id);

alter table public.meet_admins enable row level security;

-- ---------------------------------------------------------------------------
-- Credential check: owner code or any delegated admin code
-- ---------------------------------------------------------------------------

create or replace function public.meet_auth_ok(p_meet_id uuid)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (
    select 1
      from meets m
     where m.id = p_meet_id
       and (
         m.admin_code = upper(public.hdr('x-meet-admin-code'))
         or exists (
           select 1 from meet_admins a
            where a.meet_id = m.id
              and a.code = upper(public.hdr('x-meet-admin-code'))
         )
       )
  );
$$;

-- Meet management policies now accept delegated admins too.
drop policy meets_update on public.meets;
create policy meets_update on public.meets for update to anon
  using (public.meet_auth_ok(id));
drop policy meets_delete on public.meets;
create policy meets_delete on public.meets for delete to anon
  using (public.meet_auth_ok(id));

drop policy schools_insert on public.schools;
create policy schools_insert on public.schools for insert to anon
  with check (public.meet_auth_ok(meet_id));
drop policy schools_update on public.schools;
create policy schools_update on public.schools for update to anon
  using (public.meet_auth_ok(meet_id));
drop policy schools_delete on public.schools;
create policy schools_delete on public.schools for delete to anon
  using (public.meet_auth_ok(meet_id));

drop policy races_insert on public.races;
create policy races_insert on public.races for insert to anon
  with check (public.meet_auth_ok(meet_id));
drop policy races_update on public.races;
create policy races_update on public.races for update to anon
  using (public.meet_auth_ok(meet_id) or race_code = upper(public.hdr('x-race-code')));
drop policy races_delete on public.races;
create policy races_delete on public.races for delete to anon
  using (public.meet_auth_ok(meet_id));

-- Admin list: visible and editable only to people who already hold a
-- credential for that meet. The owner row cannot be removed.
create policy meet_admins_select on public.meet_admins for select to anon
  using (public.meet_auth_ok(meet_id));
create policy meet_admins_delete on public.meet_admins for delete to anon
  using (public.meet_auth_ok(meet_id) and role <> 'owner');
-- No insert policy: rows are created by add_meet_admin() (security definer).

-- ---------------------------------------------------------------------------
-- add_meet_admin / remove_meet_admin
-- ---------------------------------------------------------------------------

create or replace function public.add_meet_admin(
  p_meet_id uuid,
  p_email text,
  p_name text default null,
  p_role text default 'admin'
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_email text := lower(trim(coalesce(p_email, '')));
  v_admin public.meet_admins%rowtype;
  v_code text;
begin
  if not public.meet_auth_ok(p_meet_id) then
    raise exception 'NOT_ALLOWED';
  end if;
  if v_email = '' or position('@' in v_email) = 0 then
    raise exception 'EMAIL_REQUIRED';
  end if;
  if p_role not in ('owner', 'admin') then
    raise exception 'BAD_ROLE';
  end if;
  if exists (select 1 from meet_admins a where a.meet_id = p_meet_id and a.email = v_email) then
    raise exception 'ADMIN_EXISTS';
  end if;

  v_code := public.gen_code('public.meet_admins'::regclass, 'code');

  insert into meet_admins (meet_id, email, name, code, role)
    values (p_meet_id, v_email, nullif(trim(coalesce(p_name, '')), ''), v_code, p_role)
    returning * into v_admin;

  return jsonb_build_object(
    'id', v_admin.id, 'email', v_admin.email, 'name', v_admin.name,
    'role', v_admin.role, 'code', v_admin.code
  );
end;
$$;

create or replace function public.remove_meet_admin(p_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_admin public.meet_admins%rowtype;
begin
  select * into v_admin from meet_admins where id = p_id;
  if not found then
    raise exception 'ADMIN_NOT_FOUND';
  end if;
  if not public.meet_auth_ok(v_admin.meet_id) then
    raise exception 'NOT_ALLOWED';
  end if;
  if v_admin.role = 'owner' then
    raise exception 'OWNER_IMMUTABLE';
  end if;
  delete from meet_admins where id = p_id;
end;
$$;

-- Delegated admins count as meet authority inside the RPCs too.
create or replace function public.finalize_race(p_race_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if not (
    exists (select 1 from races r where r.id = p_race_id
            and r.race_code = upper(public.hdr('x-race-code')))
    or public.meet_auth_ok((select meet_id from races where id = p_race_id))
  ) then
    raise exception 'NOT_ALLOWED';
  end if;

  with ranked as (
    select s.id, row_number() over (order by s.seq) as rn
      from finish_slots s
     where s.race_id = p_race_id
       and s.status = 'matched'
       and s.athlete_id is not null
  )
  update finish_slots s
     set place = ranked.rn, updated_at = now()
    from ranked where ranked.id = s.id;

  update finish_slots
     set place = null, updated_at = now()
   where race_id = p_race_id
     and (status <> 'matched' or athlete_id is null);

  update races
     set status = 'finalized', finalized_at = now()
   where id = p_race_id;
end;
$$;

create or replace function public.insert_slot_relative(
  p_race_id uuid,
  p_anchor_slot_id uuid default null,
  p_side text default 'before',
  p_code text default null,
  p_device_id text default 'admin-edit'
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_race public.races%rowtype;
  v_anchor public.finish_slots%rowtype;
  v_athlete public.athletes%rowtype;
  v_slot public.finish_slots%rowtype;
  v_target int;
  v_max int;
  v_prev bigint;
  v_next bigint;
  v_offset bigint;
  v_code text;
begin
  select * into v_race from races where id = p_race_id;
  if not found then
    raise exception 'RACE_NOT_FOUND';
  end if;

  if not (
    exists (select 1 from races r where r.id = p_race_id
            and r.race_code = upper(public.hdr('x-race-code')))
    or public.meet_auth_ok(v_race.meet_id)
  ) then
    raise exception 'NOT_ALLOWED';
  end if;

  if p_anchor_slot_id is null then
    select coalesce(max(seq), 0) into v_max from finish_slots where race_id = p_race_id;
    v_target := v_max + 1;
  else
    select * into v_anchor from finish_slots
     where id = p_anchor_slot_id and race_id = p_race_id;
    if not found then
      raise exception 'SLOT_NOT_FOUND';
    end if;
    if p_side not in ('before', 'after') then
      raise exception 'BAD_SIDE';
    end if;
    v_target := v_anchor.seq + case when p_side = 'after' then 1 else 0 end;
  end if;

  -- Make room. Two passes through negative seq so the unique (race_id, seq)
  -- index is never violated mid-statement.
  update finish_slots set seq = -seq
   where race_id = p_race_id and seq >= v_target;
  update finish_slots set seq = -seq + 1
   where race_id = p_race_id and seq <= -v_target;

  -- No stopwatch time exists for a runner added after the fact: interpolate
  -- between the new neighbours so the results sheet stays sensible.
  select max(t0_offset_ms) into v_prev from finish_slots
   where race_id = p_race_id and seq < v_target;
  select min(t0_offset_ms) into v_next from finish_slots
   where race_id = p_race_id and seq > v_target;
  v_offset := case
    when v_prev is not null and v_next is not null then (v_prev + v_next) / 2
    when v_next is not null then greatest(v_next - 1000, 0)
    when v_prev is not null then v_prev + 1000
    else 0
  end;

  v_code := nullif(public.normalize_code(p_code), '');
  if v_code is not null then
    select * into v_athlete from athletes
     where race_id = p_race_id and code = v_code;
    if not found then
      insert into athletes (race_id, code, source)
        values (p_race_id, v_code, 'placeholder')
        returning * into v_athlete;
    end if;
  end if;

  insert into finish_slots (race_id, seq, t0_offset_ms, device_id, athlete_id, status)
  values (p_race_id, v_target, v_offset, coalesce(nullif(p_device_id, ''), 'admin-edit'),
          v_athlete.id,
          case when v_athlete.id is null then 'open' else 'matched' end)
  returning * into v_slot;

  if v_race.status = 'finalized' then
    with ranked as (
      select id, row_number() over (order by seq) as rn
        from finish_slots
       where race_id = p_race_id
         and status = 'matched'
         and athlete_id is not null
    )
    update finish_slots s
       set place = ranked.rn, updated_at = now()
      from ranked where ranked.id = s.id;
    select * into v_slot from finish_slots where id = v_slot.id;
  end if;

  return jsonb_build_object(
    'slot_id', v_slot.id,
    'seq', v_slot.seq,
    'place', v_slot.place,
    'athlete_id', v_slot.athlete_id,
    'code', v_athlete.code,
    'status', v_slot.status
  );
end;
$$;

grant execute on function public.join_race(text, text, uuid, text, text) to anon;
grant execute on function public.insert_slot_relative(uuid, uuid, text, text, text) to anon;
grant execute on function public.add_meet_admin(uuid, text, text, text) to anon;
grant execute on function public.remove_meet_admin(uuid) to anon;
grant execute on function public.finalize_race(uuid) to anon;
grant execute on function public.meet_auth_ok(uuid) to anon;


INSERT INTO public._aspire_applied_migrations (filename) VALUES ('20260912000001_meet_admins.sql') ON CONFLICT (filename) DO NOTHING;
COMMIT;
\endif

-- Migration: 20260918000001_meet_codes_dual_timing.sql
-- ----------------------------------------
SELECT (NOT EXISTS (SELECT 1 FROM public._aspire_applied_migrations WHERE filename = '20260918000001_meet_codes_dual_timing.sql'))::text AS _run_mig \gset
\if :_run_mig
BEGIN;
-- timing.runXC.run — meet-level codes, dual timing, registration until finalize
--
-- 1. Codes move from per-race to per-meet: `signup_code` (athletes register /
--    claim codes, any time until the meet is finalized) and `timer_code`
--    (stopwatch devices: start races and record finishes without being admins).
--    `races.race_code` is dropped. X-Signup-Code / X-Timer-Code headers carry
--    them; the old X-Race-Code header is retired.
-- 2. Primary/backup timing: race_timers records which device started a race
--    first (primary); every other device times it as backup. Backup taps are
--    stored per-device in timer_slots so the finish line can compare the two
--    stopwatches and fix official times afterwards.
-- 3. finalize_meet() stamps every race of a meet and locks registration.
-- 4. Codes are customisable: code_ok() enforces 6 alphanumeric characters and
--    blocks profanity (fuck, shit, cunt); check_code_available() lets the UI
--    validate before saving.

-- ===========================================================================
-- 1. Meet codes
-- ===========================================================================

alter table public.meets
  add column if not exists code text unique,
  add column if not exists signup_code text unique,
  add column if not exists timer_code text unique,
  add column if not exists registration_locked_at timestamptz;

do $$
declare
  m record;
  c text;
begin
  for m in select id, code, signup_code, timer_code from public.meets loop
    if m.code is null then
      loop
        c := public.gen_code('public.meets'::regclass, 'code');
        exit when not exists (select 1 from public.meets x where x.code = c);
      end loop;
      update public.meets set code = c where id = m.id;
    end if;
    if m.signup_code is null then
      loop
        c := public.gen_code('public.meets'::regclass, 'signup_code');
        exit when not exists (select 1 from public.meets x where x.signup_code = c);
      end loop;
      update public.meets set signup_code = c where id = m.id;
    end if;
    if m.timer_code is null then
      loop
        c := public.gen_code('public.meets'::regclass, 'timer_code');
        exit when not exists (select 1 from public.meets x where x.timer_code = c);
      end loop;
      update public.meets set timer_code = c where id = m.id;
    end if;
  end loop;
end;
$$;

-- New meets arriving after this migration get their three codes automatically.
alter table public.meets
  alter column code set default gen_code('public.meets'::regclass, 'code'),
  alter column signup_code set default gen_code('public.meets'::regclass, 'signup_code'),
  alter column timer_code set default gen_code('public.meets'::regclass, 'timer_code');

-- ---------------------------------------------------------------------------
-- Code hygiene: profanity block + shape check
-- ---------------------------------------------------------------------------

create or replace function public.profane(p_text text)
returns boolean
language sql
immutable
as $$
  select coalesce(p_text ~* 'fuck', false)
      or coalesce(p_text ~* 'shit', false)
      or coalesce(p_text ~* 'cunt', false);
$$;

create or replace function public.code_ok(p_code text)
returns boolean
language sql
immutable
as $$
  select p_code ~ '^[A-Z0-9]{6}$' and not public.profane(p_code);
$$;

-- ===========================================================================
-- 2. Dual timing tables
-- ===========================================================================

create table public.race_timers (
  id uuid primary key default gen_random_uuid(),
  race_id uuid not null references public.races (id) on delete cascade,
  device_id text not null,
  role text not null check (role in ('primary', 'backup')),
  started_at timestamptz not null default now(),
  unique (race_id, device_id)
);

create index race_timers_race_id_idx on public.race_timers (race_id);

create table public.timer_slots (
  id uuid primary key default gen_random_uuid(),
  race_timer_id uuid not null references public.race_timers (id) on delete cascade,
  seq int not null,
  t0_offset_ms bigint not null,
  captured_at timestamptz not null default now(),
  device_id text not null,
  unique (race_timer_id, seq)
);

alter table public.race_timers enable row level security;
alter table public.timer_slots enable row level security;

-- ===========================================================================
-- 3. Credential helpers
-- ===========================================================================

create or replace function public.signup_ok(p_meet_id uuid)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (
    select 1 from meets m
     where m.id = p_meet_id
       and m.signup_code = upper(public.hdr('x-signup-code'))
       and m.registration_locked_at is null
  );
$$;

create or replace function public.timer_ok(p_race_id uuid)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (
    select 1 from races r join meets m on m.id = r.meet_id
     where r.id = p_race_id
       and m.timer_code = upper(public.hdr('x-timer-code'))
  );
$$;

-- A device holding the timer code may write finish slots (the primary clock);
-- meet admins always may. Backup clocks write timer_slots via RPC instead.
create or replace function public.slot_write_ok(p_race_id uuid)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select public.timer_ok(p_race_id)
      or public.meet_auth_ok((select meet_id from races where id = p_race_id));
$$;

-- ===========================================================================
-- 4. RLS rewired off races.race_code
-- ===========================================================================

-- Athletes: roster stays publicly readable (as before). Inserts come from
-- signup (X-Signup-Code) and updates also from admins so a placeholder can be
-- claimed after the race.
-- Signup creates named registrations; a timer device may only create
-- nameless placeholder rows (walk-ons recorded at the finish line).
drop policy athletes_insert on public.athletes;
create policy athletes_insert on public.athletes for insert to anon
  with check (
    public.signup_ok((select meet_id from races where id = race_id))
    or (name is null and public.timer_ok(race_id))
  );

drop policy athletes_update on public.athletes;
create policy athletes_update on public.athletes for update to anon
  using (
    public.signup_ok((select meet_id from races where id = race_id))
    or public.meet_auth_ok((select meet_id from races where id = race_id))
  );

drop policy athletes_delete on public.athletes;
create policy athletes_delete on public.athletes for delete to anon
  using (public.meet_auth_ok((select meet_id from races where id = race_id)));

-- Finish slots: live board stays publicly readable; writable by timer devices
-- and admins.
drop policy slots_insert on public.finish_slots;
create policy slots_insert on public.finish_slots for insert to anon
  with check (public.slot_write_ok(race_id));

drop policy slots_update on public.finish_slots;
create policy slots_update on public.finish_slots for update to anon
  using (public.slot_write_ok(race_id));

drop policy slots_delete on public.finish_slots;
create policy slots_delete on public.finish_slots for delete to anon
  using (public.meet_auth_ok((select meet_id from races where id = race_id)));

-- Race updates are admin-only now: the start transition happens in start_race().
drop policy races_update on public.races;
create policy races_update on public.races for update to anon
  using (public.meet_auth_ok(meet_id));

-- Timer roster: visible once a division is out of draft (comparison screens).
create policy race_timers_select on public.race_timers for select to anon
  using (
    exists (
      select 1 from races r
       where r.id = race_timers.race_id and r.status <> 'draft'
    )
    or public.timer_ok(race_id)
  );

-- Raw backup events: admin screens only.
create policy timer_slots_select on public.timer_slots for select to anon
  using (
    exists (
      select 1 from race_timers rt join races r on r.id = rt.race_id
       where rt.id = timer_slots.race_timer_id
         and public.meet_auth_ok(r.meet_id)
    )
  );

-- ===========================================================================
-- 5. Public meet view (results page + registration division picker)
-- ===========================================================================

create or replace function public.get_meet(p_code text)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_meet public.meets%rowtype;
begin
  -- Runners get one code to type; accept either the meet code or the
  -- signup code so both printed links and dictation work.
  select * into v_meet from meets
   where code = public.normalize_code(p_code)
      or signup_code = public.normalize_code(p_code)
   limit 1;
  if not found then
    raise exception 'MEET_NOT_FOUND';
  end if;

  return jsonb_build_object(
    'id', v_meet.id,
    'name', v_meet.name,
    'location', v_meet.location,
    'meet_date', v_meet.meet_date,
    'registration_locked', v_meet.registration_locked_at is not null,
    'divisions', (
      select coalesce(
        jsonb_agg(
          jsonb_build_object(
            'id', r.id, 'name', r.name, 'status', r.status,
            'starts_at', r.scheduled_start
          )
          order by r.scheduled_start asc nulls last, r.created_at asc
        ),
        '[]'::jsonb
      )
      from races r
      where r.meet_id = v_meet.id and r.status <> 'draft'
    )
  );
end;
$$;

-- ===========================================================================
-- 6. join_meet: register (or claim a code) with the signup code + division
-- ===========================================================================

create or replace function public.join_meet(
  p_signup_code text,
  p_race_id uuid,
  p_name text,
  p_school_id uuid default null,
  p_grade text default null,
  p_code text default null
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_meet public.meets%rowtype;
  v_race public.races%rowtype;
  v_athlete public.athletes%rowtype;
  v_code text;
begin
  select * into v_meet
    from meets where signup_code = upper(public.normalize_code(p_signup_code));
  if not found then
    raise exception 'SIGNUP_CODE_INVALID';
  end if;
  if v_meet.registration_locked_at is not null then
    raise exception 'REGISTRATION_LOCKED';
  end if;

  select * into v_race from races where id = p_race_id and meet_id = v_meet.id;
  if not found then
    raise exception 'DIVISION_NOT_FOUND';
  end if;
  if v_race.status = 'draft' then
    raise exception 'DIVISION_NOT_OPEN';
  end if;
  if p_name is null or char_length(trim(p_name)) = 0 then
    raise exception 'NAME_REQUIRED';
  end if;

  v_code := public.normalize_code(p_code);

  if v_code = '' then
    -- No code typed: hand out the next free generated code for this division.
    v_code := public.gen_code('public.athletes'::regclass, 'code');
    while exists (select 1 from athletes a where a.race_id = v_race.id and a.code = v_code) loop
      v_code := public.gen_code('public.athletes'::regclass, 'code');
    end loop;
  else
    if char_length(v_code) <> 6 then
      raise exception 'CODE_LENGTH';
    end if;
    -- A placeholder (name null) left at the finish line stays claimable even
    -- after finalize: that is how an unregistered runner gets their result.
    if exists (
      select 1 from athletes a
       where a.race_id = v_race.id and a.code = v_code and a.name is not null
    ) then
      raise exception 'CODE_TAKEN';
    end if;
  end if;

  select * into v_athlete from athletes
   where race_id = v_race.id and code = v_code;

  if found then
    update athletes
       set name = trim(p_name),
           school_id = p_school_id,
           grade = nullif(trim(coalesce(p_grade, '')), ''),
           registered_at = now()
     where id = v_athlete.id
     returning * into v_athlete;
  else
    insert into athletes (race_id, code, name, school_id, grade, source, registered_at)
    values (v_race.id, v_code, trim(p_name), p_school_id,
            nullif(trim(coalesce(p_grade, '')), ''),
            case when p_code is null or trim(p_code) = '' then 'assigned' else 'self' end,
            now())
    returning * into v_athlete;
  end if;

  return jsonb_build_object(
    'athlete_id', v_athlete.id,
    'code', v_athlete.code,
    'race_id', v_race.id,
    'race_name', v_race.name,
    'meet_id', v_meet.id
  );
end;
$$;

-- join_race is replaced by join_meet (meet-level signup code + division pick).
create or replace function public.join_race(
  p_race_code text, p_name text, p_school_id uuid default null,
  p_grade text default null, p_code text default null
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
begin
  raise exception 'RETIRED';
end;
$$;

-- ===========================================================================
-- 7. Timer devices: resolve, start (primary/backup), backup slots
-- ===========================================================================

create or replace function public.resolve_timer(p_code text, p_device_id text default null)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_meet public.meets%rowtype;
  v_roles jsonb;
begin
  select * into v_meet from meets where timer_code = upper(public.normalize_code(p_code));
  if not found then
    raise exception 'TIMER_CODE_INVALID';
  end if;

  v_roles := null;
  if p_device_id is not null then
    select jsonb_agg(
             jsonb_build_object('race_id', rt.race_id, 'role', rt.role)
           )
      into v_roles
      from race_timers rt join races r on r.id = rt.race_id
     where r.meet_id = v_meet.id and rt.device_id = p_device_id;
  end if;

  return jsonb_build_object(
    'meet', jsonb_build_object('id', v_meet.id, 'name', v_meet.name,
                               'location', v_meet.location, 'code', v_meet.code),
    'races', (
      select coalesce(
        jsonb_agg(
          jsonb_build_object(
            'id', r.id, 'name', r.name, 'status', r.status,
            'starts_at', r.scheduled_start, 'started_at', r.started_at
          )
          order by r.scheduled_start asc nulls last, r.created_at asc
        ),
        '[]'::jsonb
      )
      from races r
      where r.meet_id = v_meet.id and r.status <> 'draft'
    ),
    'my_roles', coalesce(v_roles, '[]'::jsonb)
  );
end;
$$;

-- First device to start a race is primary (clock authoritative); any later
-- device joins as backup. Re-calling with the same device resumes idempotently.
create or replace function public.start_race(p_race_id uuid, p_device_id text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_race public.races%rowtype;
  v_timer public.race_timers%rowtype;
  v_role text;
begin
  select * into v_race from races where id = p_race_id;
  if not found then
    raise exception 'RACE_NOT_FOUND';
  end if;
  if not (public.timer_ok(p_race_id) or public.meet_auth_ok(v_race.meet_id)) then
    raise exception 'NOT_ALLOWED';
  end if;
  if v_race.status = 'finalized' then
    raise exception 'RACE_FINALIZED';
  end if;
  if coalesce(trim(p_device_id), '') = '' then
    raise exception 'DEVICE_REQUIRED';
  end if;

  select * into v_timer from race_timers
   where race_id = p_race_id and device_id = p_device_id;

  if found then
    v_role := v_timer.role;
  else
    v_role := case
      when exists (select 1 from race_timers rt where rt.race_id = p_race_id)
      then 'backup' else 'primary'
    end;
    insert into race_timers (race_id, device_id, role)
      values (p_race_id, p_device_id, v_role)
      returning * into v_timer;
  end if;

  -- The first start wins the clock. started_at is set once and never moved.
  update races
     set status = 'running', started_at = coalesce(started_at, now())
   where id = p_race_id and started_at is null;
  select * into v_race from races where id = p_race_id;

  return jsonb_build_object(
    'role', v_role,
    'timer_id', v_timer.id,
    'started_at', v_race.started_at,
    'race_id', v_race.id,
    'status', v_race.status
  );
end;
$$;

-- Backup stopwatch taps. Stored per device for the comparison screen; they
-- never touch official finish_slots until an admin merges them.
create or replace function public.record_timer_slot(
  p_race_id uuid,
  p_device_id text,
  p_t0_offset_ms bigint
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_timer public.race_timers%rowtype;
  v_slot public.timer_slots%rowtype;
  v_seq int;
begin
  if not public.timer_ok(p_race_id) then
    raise exception 'NOT_ALLOWED';
  end if;

  select * into v_timer from race_timers
   where race_id = p_race_id and device_id = p_device_id;
  if not found then
    raise exception 'TIMER_NOT_STARTED';
  end if;

  select coalesce(max(seq), 0) + 1 into v_seq from timer_slots
   where race_timer_id = v_timer.id;

  insert into timer_slots (race_timer_id, seq, t0_offset_ms, device_id)
    values (v_timer.id, v_seq, p_t0_offset_ms, p_device_id)
    returning * into v_slot;

  return jsonb_build_object(
    'id', v_slot.id, 'seq', v_slot.seq,
    't0_offset_ms', v_slot.t0_offset_ms, 'captured_at', v_slot.captured_at
  );
end;
$$;

-- ===========================================================================
-- 8. Finalize: race (admin or timer) and whole meet (locks registration)
-- ===========================================================================

create or replace function public.finalize_race(p_race_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if not (
    public.meet_auth_ok((select meet_id from races where id = p_race_id))
    or public.timer_ok(p_race_id)
  ) then
    raise exception 'NOT_ALLOWED';
  end if;

  with ranked as (
    select s.id, row_number() over (order by s.seq) as rn
      from finish_slots s
     where s.race_id = p_race_id
       and s.status = 'matched'
       and s.athlete_id is not null
  )
  update finish_slots s
     set place = ranked.rn, updated_at = now()
    from ranked where ranked.id = s.id;

  update finish_slots
     set place = null, updated_at = now()
   where race_id = p_race_id
     and (status <> 'matched' or athlete_id is null);

  update races
     set status = 'finalized', finalized_at = now()
   where id = p_race_id;
end;
$$;

create or replace function public.finalize_meet(p_meet_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_count int;
begin
  if not public.meet_auth_ok(p_meet_id) then
    raise exception 'NOT_ALLOWED';
  end if;

  update races
     set status = 'finalized', finalized_at = coalesce(finalized_at, now())
   where meet_id = p_meet_id and status <> 'finalized';
  get diagnostics v_count = row_count;

  update meets
     set registration_locked_at = now()
   where id = p_meet_id and registration_locked_at is null;

  return jsonb_build_object('finalized_races', v_count);
end;
$$;

-- ===========================================================================
-- 9. Custom codes: availability probe + rotate (null regenerates)
-- ===========================================================================

create or replace function public.check_code_available(p_kind text, p_code text)
returns boolean
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_code text := upper(public.normalize_code(p_code));
begin
  if not public.code_ok(v_code) then
    return false;
  end if;
  if p_kind = 'signup' then
    return not exists (select 1 from meets m where m.signup_code = v_code);
  elsif p_kind = 'timer' then
    return not exists (select 1 from meets m where m.timer_code = v_code);
  elsif p_kind = 'meet' then
    return not exists (select 1 from meets m where m.code = v_code);
  else
    raise exception 'BAD_KIND';
  end if;
end;
$$;

create or replace function public.set_meet_code(p_meet_id uuid, p_kind text, p_new_code text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_code text := upper(public.normalize_code(p_new_code));
begin
  if not public.meet_auth_ok(p_meet_id) then
    raise exception 'NOT_ALLOWED';
  end if;

  if v_code = '' then
    -- Regenerate a safe random code.
    if p_kind = 'signup' then
      loop
        v_code := public.gen_code('public.meets'::regclass, 'signup_code');
        exit when not exists (select 1 from meets m where m.signup_code = v_code);
      end loop;
      update meets set signup_code = v_code where id = p_meet_id;
    elsif p_kind = 'timer' then
      loop
        v_code := public.gen_code('public.meets'::regclass, 'timer_code');
        exit when not exists (select 1 from meets m where m.timer_code = v_code);
      end loop;
      update meets set timer_code = v_code where id = p_meet_id;
    else
      raise exception 'BAD_KIND';
    end if;
  else
    if not public.code_ok(v_code) then
      if public.profane(v_code) then
        raise exception 'CODE_PROFANE';
      else
        raise exception 'CODE_FORMAT';
      end if;
    end if;
    if p_kind = 'signup' then
      if exists (select 1 from meets m where m.signup_code = v_code and m.id <> p_meet_id) then
        raise exception 'CODE_TAKEN';
      end if;
      update meets set signup_code = v_code where id = p_meet_id;
    elsif p_kind = 'timer' then
      if exists (select 1 from meets m where m.timer_code = v_code and m.id <> p_meet_id) then
        raise exception 'CODE_TAKEN';
      end if;
      update meets set timer_code = v_code where id = p_meet_id;
    else
      raise exception 'BAD_KIND';
    end if;
  end if;

  return jsonb_build_object(p_kind, v_code);
end;
$$;

-- ===========================================================================
-- 10. insert_slot_relative without the race-code branch
-- ===========================================================================

create or replace function public.insert_slot_relative(
  p_race_id uuid,
  p_anchor_slot_id uuid default null,
  p_side text default 'before',
  p_code text default null,
  p_device_id text default 'admin-edit'
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_race public.races%rowtype;
  v_anchor public.finish_slots%rowtype;
  v_athlete public.athletes%rowtype;
  v_slot public.finish_slots%rowtype;
  v_target int;
  v_max int;
  v_prev bigint;
  v_next bigint;
  v_offset bigint;
  v_code text;
begin
  select * into v_race from races where id = p_race_id;
  if not found then
    raise exception 'RACE_NOT_FOUND';
  end if;

  if not public.meet_auth_ok(v_race.meet_id) then
    raise exception 'NOT_ALLOWED';
  end if;

  if p_anchor_slot_id is null then
    select coalesce(max(seq), 0) into v_max from finish_slots where race_id = p_race_id;
    v_target := v_max + 1;
  else
    select * into v_anchor from finish_slots
     where id = p_anchor_slot_id and race_id = p_race_id;
    if not found then
      raise exception 'SLOT_NOT_FOUND';
    end if;
    if p_side not in ('before', 'after') then
      raise exception 'BAD_SIDE';
    end if;
    v_target := v_anchor.seq + case when p_side = 'after' then 1 else 0 end;
  end if;

  update finish_slots set seq = -seq
   where race_id = p_race_id and seq >= v_target;
  update finish_slots set seq = -seq + 1
   where race_id = p_race_id and seq <= -v_target;

  select max(t0_offset_ms) into v_prev from finish_slots
   where race_id = p_race_id and seq < v_target;
  select min(t0_offset_ms) into v_next from finish_slots
   where race_id = p_race_id and seq > v_target;
  v_offset := case
    when v_prev is not null and v_next is not null then (v_prev + v_next) / 2
    when v_next is not null then greatest(v_next - 1000, 0)
    when v_prev is not null then v_prev + 1000
    else 0
  end;

  v_code := nullif(public.normalize_code(p_code), '');
  if v_code is not null then
    select * into v_athlete from athletes
     where race_id = p_race_id and code = v_code;
    if not found then
      insert into athletes (race_id, code, source)
        values (p_race_id, v_code, 'placeholder')
        returning * into v_athlete;
    end if;
  end if;

  insert into finish_slots (race_id, seq, t0_offset_ms, device_id, athlete_id, status)
  values (p_race_id, v_target, v_offset, coalesce(nullif(p_device_id, ''), 'admin-edit'),
          v_athlete.id,
          case when v_athlete.id is null then 'open' else 'matched' end)
  returning * into v_slot;

  if v_race.status = 'finalized' then
    with ranked as (
      select id, row_number() over (order by seq) as rn
        from finish_slots
       where race_id = p_race_id
         and status = 'matched'
         and athlete_id is not null
    )
    update finish_slots s
       set place = ranked.rn, updated_at = now()
      from ranked where ranked.id = s.id;
    select * into v_slot from finish_slots where id = v_slot.id;
  end if;

  return jsonb_build_object(
    'slot_id', v_slot.id,
    'seq', v_slot.seq,
    'place', v_slot.place,
    'athlete_id', v_slot.athlete_id,
    'code', v_athlete.code,
    'status', v_slot.status
  );
end;
$$;

-- ===========================================================================
-- 11. Drop the retired per-race code
-- ===========================================================================

alter table public.races drop column if exists race_code;

-- ===========================================================================
-- 12. Grants + schema cache reload
-- ===========================================================================

grant execute on function public.profane(text) to anon;
grant execute on function public.code_ok(text) to anon;
grant execute on function public.signup_ok(uuid) to anon;
grant execute on function public.timer_ok(uuid) to anon;
grant execute on function public.slot_write_ok(uuid) to anon;
grant execute on function public.get_meet(text) to anon;
grant execute on function public.join_meet(text, uuid, text, uuid, text, text) to anon;
grant execute on function public.resolve_timer(text, text) to anon;
grant execute on function public.start_race(uuid, text) to anon;
grant execute on function public.record_timer_slot(uuid, text, bigint) to anon;
grant execute on function public.finalize_meet(uuid) to anon;
grant execute on function public.check_code_available(text, text) to anon;
grant execute on function public.set_meet_code(uuid, text, text) to anon;

notify pgrst, 'reload schema';


INSERT INTO public._aspire_applied_migrations (filename) VALUES ('20260918000001_meet_codes_dual_timing.sql') ON CONFLICT (filename) DO NOTHING;
COMMIT;
\endif

-- Migration: 20260919000001_gender_optional_signup.sql
-- ----------------------------------------
SELECT (NOT EXISTS (SELECT 1 FROM public._aspire_applied_migrations WHERE filename = '20260919000001_gender_optional_signup.sql'))::text AS _run_mig \gset
\if :_run_mig
BEGIN;
-- ===========================================================================
-- Gender on athletes + optional signup codes + gender-aware team scoring.
--   * meets.signup_required  — when false, /meet/<code>/signup works with no code
--   * athletes.gender        — 'M' | 'F' (null for unclaimed placeholders)
--   * join_meet gains p_meet_code + p_gender; a signup code is only demanded
--     when the meet requires one
--   * get_team_standings(p_race_id, p_gender) scores each gender separately,
--     so mixed divisions can run together and still score boys vs girls
-- ===========================================================================

alter table public.meets
  add column if not exists signup_required boolean not null default true;

alter table public.athletes
  add column if not exists gender text
    constraint athletes_gender_check check (gender is null or gender in ('M', 'F'));

-- ---------------------------------------------------------------------------
-- Signup gate: an open meet accepts registrations without the code.
-- ---------------------------------------------------------------------------
create or replace function public.signup_ok(p_meet_id uuid)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (
    select 1 from meets m
     where m.id = p_meet_id
       and m.registration_locked_at is null
       and (
         not m.signup_required
         or m.signup_code = upper(public.hdr('x-signup-code'))
       )
  );
$$;

-- ---------------------------------------------------------------------------
-- get_meet also reports whether the signup code is required.
-- ---------------------------------------------------------------------------
create or replace function public.get_meet(p_code text)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_meet public.meets%rowtype;
begin
  select * into v_meet from meets
   where code = public.normalize_code(p_code)
      or signup_code = public.normalize_code(p_code)
   limit 1;
  if not found then
    raise exception 'MEET_NOT_FOUND';
  end if;

  return jsonb_build_object(
    'id', v_meet.id,
    'code', v_meet.code,
    'name', v_meet.name,
    'location', v_meet.location,
    'meet_date', v_meet.meet_date,
    'registration_locked', v_meet.registration_locked_at is not null,
    'signup_required', v_meet.signup_required,
    'divisions', (
      select coalesce(
        jsonb_agg(
          jsonb_build_object(
            'id', r.id, 'name', r.name, 'status', r.status,
            'starts_at', r.scheduled_start
          )
          order by r.scheduled_start asc nulls last, r.created_at asc
        ),
        '[]'::jsonb
      )
      from races r
      where r.meet_id = v_meet.id and r.status <> 'draft'
    )
  );
end;
$$;

-- ---------------------------------------------------------------------------
-- join_meet: resolves the meet by signup code, or by meet code when the meet
-- does not require a signup code. Captures gender (M/F).
-- ---------------------------------------------------------------------------
drop function if exists public.join_meet(text, uuid, text, uuid, text, text);

create or replace function public.join_meet(
  p_signup_code text default null,
  p_meet_code text default null,
  p_race_id uuid default null,
  p_name text default null,
  p_school_id uuid default null,
  p_grade text default null,
  p_code text default null,
  p_gender text default null
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_meet public.meets%rowtype;
  v_race public.races%rowtype;
  v_athlete public.athletes%rowtype;
  v_code text;
  v_signup text;
begin
  v_signup := upper(public.normalize_code(coalesce(p_signup_code, '')));

  if v_signup <> '' then
    select * into v_meet from meets where signup_code = v_signup;
    if not found then
      raise exception 'SIGNUP_CODE_INVALID';
    end if;
  else
    -- No signup code: allowed only for meets that opted out of requiring one.
    select * into v_meet from meets
     where code = upper(public.normalize_code(coalesce(p_meet_code, '')))
        or signup_code = upper(public.normalize_code(coalesce(p_meet_code, '')))
     limit 1;
    if not found then
      raise exception 'SIGNUP_CODE_INVALID';
    end if;
    if v_meet.signup_required then
      raise exception 'SIGNUP_CODE_REQUIRED';
    end if;
  end if;

  if v_meet.registration_locked_at is not null then
    raise exception 'REGISTRATION_LOCKED';
  end if;

  select * into v_race from races where id = p_race_id and meet_id = v_meet.id;
  if not found then
    raise exception 'DIVISION_NOT_FOUND';
  end if;
  if v_race.status = 'draft' then
    raise exception 'DIVISION_NOT_OPEN';
  end if;
  if p_name is null or char_length(trim(p_name)) = 0 then
    raise exception 'NAME_REQUIRED';
  end if;
  if p_gender is not null and trim(p_gender) <> ''
     and upper(trim(p_gender)) not in ('M', 'F') then
    raise exception 'GENDER_INVALID';
  end if;

  v_code := public.normalize_code(p_code);

  if v_code = '' then
    -- No code typed: hand out the next free generated code for this division.
    v_code := public.gen_code('public.athletes'::regclass, 'code');
    while exists (select 1 from athletes a where a.race_id = v_race.id and a.code = v_code) loop
      v_code := public.gen_code('public.athletes'::regclass, 'code');
    end loop;
  else
    if char_length(v_code) <> 6 then
      raise exception 'CODE_LENGTH';
    end if;
    -- A placeholder (name null) left at the finish line stays claimable even
    -- after finalize: that is how an unregistered runner gets their result.
    if exists (
      select 1 from athletes a
       where a.race_id = v_race.id and a.code = v_code and a.name is not null
    ) then
      raise exception 'CODE_TAKEN';
    end if;
  end if;

  select * into v_athlete from athletes
   where race_id = v_race.id and code = v_code;

  if found then
    update athletes
       set name = trim(p_name),
           school_id = p_school_id,
           grade = nullif(trim(coalesce(p_grade, '')), ''),
           gender = coalesce(nullif(upper(trim(coalesce(p_gender, ''))), ''), gender),
           registered_at = now()
     where id = v_athlete.id
     returning * into v_athlete;
  else
    insert into athletes (race_id, code, name, school_id, grade, gender, source, registered_at)
    values (v_race.id, v_code, trim(p_name), p_school_id,
            nullif(trim(coalesce(p_grade, '')), ''),
            nullif(upper(trim(coalesce(p_gender, ''))), ''),
            case when p_code is null or trim(p_code) = '' then 'assigned' else 'self' end,
            now())
    returning * into v_athlete;
  end if;

  return jsonb_build_object(
    'athlete_id', v_athlete.id,
    'code', v_athlete.code,
    'race_id', v_race.id,
    'race_name', v_race.name,
    'meet_id', v_meet.id
  );
end;
$$;

-- ---------------------------------------------------------------------------
-- Team standings per gender: pass p_gender ('M'|'F') to score only that
-- gender using gender-relative finishing ranks. Null keeps old behavior.
-- ---------------------------------------------------------------------------
drop function if exists public.get_team_standings(uuid);

create or replace function public.get_team_standings(
  p_race_id uuid,
  p_gender text default null
)
returns table (
  school_id uuid,
  school_name text,
  score int,
  tiebreak int,
  finishers int,
  rank int
)
language sql
stable
security definer
set search_path = public
as $$
  with filtered as (
    select a.school_id, s.place
    from finish_slots s
    join athletes a on a.id = s.athlete_id
    where s.race_id = p_race_id
      and s.status = 'matched'
      and s.place is not null
      and a.school_id is not null
      and (p_gender is null or a.gender = p_gender)
  ),
  scored as (
    select
      school_id,
      row_number() over (order by place) as eplace,
      row_number() over (partition by school_id order by place) as runner_rank
    from filtered
  ),
  teams as (
    select
      school_id,
      sum(case when runner_rank <= (select team_size from races where id = p_race_id)
               then eplace end)::int as score,
      sum(case when runner_rank > (select team_size from races where id = p_race_id)
                and runner_rank <= (select tiebreak_depth from races where id = p_race_id)
               then eplace end)::int as tiebreak,
      count(*)::int as finishers
    from scored
    group by school_id
  ),
  tb as (
    select t.school_id, t.score, t.finishers, t.tiebreak
    from teams t
  )
  select
    tb.school_id,
    sc.name as school_name,
    tb.score,
    tb.tiebreak,
    tb.finishers,
    -- Standard XC: complete teams (team_size finishers) rank ahead of
    -- incomplete teams; within a tier, low score wins, then tiebreak.
    rank() over (
      order by
        (tb.finishers >= (select team_size from races where id = p_race_id)) desc nulls last,
        tb.score asc nulls last,
        tb.tiebreak asc nulls last
    )::int as rank
  from tb
  join schools sc on sc.id = tb.school_id
  order by rank, sc.name;
$$;

-- ---------------------------------------------------------------------------
-- Grants + cache refresh
-- ---------------------------------------------------------------------------
grant execute on function public.signup_ok(uuid) to anon;
grant execute on function public.get_meet(text) to anon;
grant execute on function public.join_meet(text, text, uuid, text, uuid, text, text, text) to anon;
grant execute on function public.get_team_standings(uuid, text) to anon;

notify pgrst, 'reload schema';


INSERT INTO public._aspire_applied_migrations (filename) VALUES ('20260919000001_gender_optional_signup.sql') ON CONFLICT (filename) DO NOTHING;
COMMIT;
\endif

-- Migration: 20260920000001_scanner_role.sql
-- ----------------------------------------
SELECT (NOT EXISTS (SELECT 1 FROM public._aspire_applied_migrations WHERE filename = '20260920000001_scanner_role.sql'))::text AS _run_mig \gset
\if :_run_mig
BEGIN;
-- ===========================================================================
-- Dedicated finish-line scanner role
--
-- The stopwatch timer only taps splits; a separate crew member (or two) at
-- the chute scans/types each athlete code in finishing order. A per-meet
-- `scanner_code` authorizes exactly that: resolve the meet, record scans and
-- undo the last one. Nothing else — no admin, no finalize, no edits.
--
-- Scans are recorded server-side (record_scan) so concurrent scanners can
-- never collide on finish_slots (race_id, seq): the race row is locked while
-- the next position is chosen. A scan attaches the code to the timer's oldest
-- open split slot when one exists (the official time comes from the stopwatch);
-- otherwise it appends a new slot at the current clock offset. Unknown codes
-- become unclaimed placeholders immediately so true finishing order survives;
-- registration with that same code afterwards claims them (existing flow).
-- ===========================================================================

alter table public.meets
  add column if not exists scanner_code text unique;

do $$
declare
  m record;
  c text;
begin
  for m in select id, scanner_code from public.meets loop
    if m.scanner_code is null then
      loop
        c := public.gen_code('public.meets'::regclass, 'scanner_code');
        exit when not exists (select 1 from public.meets x where x.scanner_code = c);
      end loop;
      update public.meets set scanner_code = c where id = m.id;
    end if;
  end loop;
end;
$$;

alter table public.meets
  alter column scanner_code set default gen_code('public.meets'::regclass, 'scanner_code');

-- ---------------------------------------------------------------------------
-- Code management: teach the generic setters about the scanner kind
-- ---------------------------------------------------------------------------

create or replace function public.check_code_available(p_kind text, p_code text)
returns boolean
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_code text := upper(public.normalize_code(p_code));
begin
  if not public.code_ok(v_code) then
    return false;
  end if;
  if p_kind = 'signup' then
    return not exists (select 1 from meets m where m.signup_code = v_code);
  elsif p_kind = 'timer' then
    return not exists (select 1 from meets m where m.timer_code = v_code);
  elsif p_kind = 'scanner' then
    return not exists (select 1 from meets m where m.scanner_code = v_code);
  elsif p_kind = 'meet' then
    return not exists (select 1 from meets m where m.code = v_code);
  else
    raise exception 'BAD_KIND';
  end if;
end;
$$;

create or replace function public.set_meet_code(p_meet_id uuid, p_kind text, p_new_code text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_code text := upper(public.normalize_code(p_new_code));
begin
  if not public.meet_auth_ok(p_meet_id) then
    raise exception 'NOT_ALLOWED';
  end if;

  if v_code = '' then
    -- Regenerate a safe random code.
    if p_kind = 'signup' then
      loop
        v_code := public.gen_code('public.meets'::regclass, 'signup_code');
        exit when not exists (select 1 from meets m where m.signup_code = v_code);
      end loop;
      update meets set signup_code = v_code where id = p_meet_id;
    elsif p_kind = 'timer' then
      loop
        v_code := public.gen_code('public.meets'::regclass, 'timer_code');
        exit when not exists (select 1 from meets m where m.timer_code = v_code);
      end loop;
      update meets set timer_code = v_code where id = p_meet_id;
    elsif p_kind = 'scanner' then
      loop
        v_code := public.gen_code('public.meets'::regclass, 'scanner_code');
        exit when not exists (select 1 from meets m where m.scanner_code = v_code);
      end loop;
      update meets set scanner_code = v_code where id = p_meet_id;
    else
      raise exception 'BAD_KIND';
    end if;
  else
    if not public.code_ok(v_code) then
      if public.profane(v_code) then
        raise exception 'CODE_PROFANE';
      else
        raise exception 'CODE_FORMAT';
      end if;
    end if;
    if p_kind = 'signup' then
      if exists (select 1 from meets m where m.signup_code = v_code and m.id <> p_meet_id) then
        raise exception 'CODE_TAKEN';
      end if;
      update meets set signup_code = v_code where id = p_meet_id;
    elsif p_kind = 'timer' then
      if exists (select 1 from meets m where m.timer_code = v_code and m.id <> p_meet_id) then
        raise exception 'CODE_TAKEN';
      end if;
      update meets set timer_code = v_code where id = p_meet_id;
    elsif p_kind = 'scanner' then
      if exists (select 1 from meets m where m.scanner_code = v_code and m.id <> p_meet_id) then
        raise exception 'CODE_TAKEN';
      end if;
      update meets set scanner_code = v_code where id = p_meet_id;
    else
      raise exception 'BAD_KIND';
    end if;
  end if;

  return jsonb_build_object(p_kind, v_code);
end;
$$;

-- ---------------------------------------------------------------------------
-- Scanner devices: resolve the meet from a scanner code
-- ---------------------------------------------------------------------------

create or replace function public.resolve_scanner(p_code text)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_meet public.meets%rowtype;
begin
  select * into v_meet from meets where scanner_code = upper(public.normalize_code(p_code));
  if not found then
    raise exception 'SCANNER_CODE_INVALID';
  end if;

  return jsonb_build_object(
    'meet', jsonb_build_object('id', v_meet.id, 'name', v_meet.name,
                               'location', v_meet.location, 'code', v_meet.code),
    'races', (
      select coalesce(
        jsonb_agg(
          jsonb_build_object(
            'id', r.id, 'name', r.name, 'status', r.status,
            'starts_at', r.scheduled_start, 'started_at', r.started_at
          )
          order by r.scheduled_start asc nulls last, r.created_at asc
        ),
        '[]'::jsonb
      )
      from races r
      where r.meet_id = v_meet.id and r.status <> 'draft'
    )
  );
end;
$$;

-- ---------------------------------------------------------------------------
-- record_scan: one scanned code = one recorded finisher, ordered server-side
-- ---------------------------------------------------------------------------

create or replace function public.record_scan(p_scanner_code text, p_race_id uuid, p_code text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_meet   public.meets%rowtype;
  v_race   public.races%rowtype;
  v_ath    public.athletes%rowtype;
  v_slot   public.finish_slots%rowtype;
  v_code   text := upper(public.normalize_code(p_code));
  v_new    boolean := false;
begin
  select * into v_meet from meets where scanner_code = upper(public.normalize_code(p_scanner_code));
  if not found then
    raise exception 'SCANNER_CODE_INVALID';
  end if;

  select * into v_race from races where id = p_race_id and meet_id = v_meet.id;
  if not found then
    raise exception 'RACE_NOT_FOUND';
  end if;
  if v_race.status <> 'running' or v_race.started_at is null then
    raise exception 'NOT_RUNNING';
  end if;

  if v_code !~ '^[A-Z0-9]{6}$' then
    raise exception 'CODE_FORMAT';
  end if;

  -- Serialize concurrent scanners on this race before choosing a position.
  perform id from races where id = p_race_id for update;

  select a.* into v_ath from athletes a where a.race_id = p_race_id and a.code = v_code;
  if found then
    -- A runner is only recorded once.
    select * into v_slot from finish_slots
     where race_id = p_race_id and athlete_id = v_ath.id;
    if found then
      return jsonb_build_object(
        'status', 'already_in', 'seq', v_slot.seq, 'code', v_code
      );
    end if;
  else
    -- Unknown code: keep the finisher's true place with an unclaimed
    -- placeholder; registering that same code later claims it.
    insert into athletes (race_id, code, source)
    values (p_race_id, v_code, 'placeholder')
    returning * into v_ath;
    v_new := true;
  end if;

  -- Prefer attaching to the timer's oldest open split so official times come
  -- from the stopwatch; otherwise append at the current clock.
  select * into v_slot
    from finish_slots
   where race_id = p_race_id and status = 'open' and athlete_id is null
   order by seq
   limit 1
     for update;

  if found then
    update finish_slots
       set athlete_id = v_ath.id, status = 'matched'
     where id = v_slot.id
     returning * into v_slot;
  else
    insert into finish_slots (race_id, seq, t0_offset_ms, device_id, athlete_id, status)
    values (
      p_race_id,
      (select coalesce(max(seq), 0) + 1 from finish_slots where race_id = p_race_id),
      (extract(epoch from now() - v_race.started_at) * 1000)::bigint,
      'scanner',
      v_ath.id,
      'matched'
    )
    returning * into v_slot;
  end if;

  return jsonb_build_object(
    'status', case when v_new then 'placeholder' else 'matched' end,
    'seq', v_slot.seq,
    'slot_id', v_slot.id,
    'code', v_ath.code,
    'athlete', jsonb_build_object(
      'id', v_ath.id, 'name', v_ath.name, 'grade', v_ath.grade,
      'school', (select sc.name from schools sc where sc.id = v_ath.school_id)
    )
  );
end;
$$;

-- ---------------------------------------------------------------------------
-- undo_scan: remove a mis-scan (and its unclaimed placeholder, if any)
-- ---------------------------------------------------------------------------

create or replace function public.undo_scan(p_scanner_code text, p_slot_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_meet public.meets%rowtype;
  v_race public.races%rowtype;
  v_slot public.finish_slots%rowtype;
begin
  select * into v_meet from meets where scanner_code = upper(public.normalize_code(p_scanner_code));
  if not found then
    raise exception 'SCANNER_CODE_INVALID';
  end if;

  select * into v_slot from finish_slots
   where id = p_slot_id
     and race_id in (select id from races where meet_id = v_meet.id);
  if not found then
    raise exception 'SLOT_NOT_FOUND';
  end if;

  select * into v_race from races where id = v_slot.race_id;
  if v_race.status = 'finalized' then
    raise exception 'FINALIZED';
  end if;

  perform id from races where id = v_slot.race_id for update;

  if v_slot.device_id = 'scanner' then
    -- The scan created this slot — remove it outright.
    delete from finish_slots where id = v_slot.id;
  else
    -- The slot was the timer's split tap; the scan only attached an identity.
    -- Reopen it so the official time survives and can be matched again.
    update finish_slots
       set athlete_id = null, status = 'open'
     where id = v_slot.id;
  end if;

  -- An unclaimed placeholder exists only for its finish record — remove it
  -- too so the code can be re-scanned or registered cleanly.
  if v_slot.athlete_id is not null then
    delete from athletes a
     where a.id = v_slot.athlete_id
       and a.name is null
       and a.source = 'placeholder'
       and not exists (select 1 from finish_slots s where s.athlete_id = a.id);
  end if;

  return jsonb_build_object('removed_seq', v_slot.seq);
end;
$$;

-- ---------------------------------------------------------------------------
-- Grants + pool reload
-- ---------------------------------------------------------------------------

grant execute on function public.resolve_scanner(text) to anon;
grant execute on function public.record_scan(text, uuid, text) to anon;
grant execute on function public.undo_scan(text, uuid) to anon;

notify pgrst, 'reload schema';


INSERT INTO public._aspire_applied_migrations (filename) VALUES ('20260920000001_scanner_role.sql') ON CONFLICT (filename) DO NOTHING;
COMMIT;
\endif

-- Migration: 20260921000001_athlete_codes_per_meet.sql
-- ----------------------------------------
SELECT (NOT EXISTS (SELECT 1 FROM public._aspire_applied_migrations WHERE filename = '20260921000001_athlete_codes_per_meet.sql'))::text AS _run_mig \gset
\if :_run_mig
BEGIN;
-- ===========================================================================
-- Athlete codes are meet-scoped identifiers.
--   * Generated athlete codes are 4 characters (uniqueness within the meet,
--     not globally — different meets happily reuse the same code).
--   * Entered codes may be any 1–8 alphanumeric characters, because they can
--     come from pre-printed stickers or another system entirely.
-- Finish-line scans resolve a code across the whole meet and tell the scanner
-- when it belongs to a different division instead of creating a ghost entry.
-- ===========================================================================

-- ---------------------------------------------------------------------------
-- 1. athletes.meet_id (denormalized, trigger-maintained) + per-meet uniqueness
-- ---------------------------------------------------------------------------

alter table public.athletes
  add column if not exists meet_id uuid references public.meets(id) on delete cascade;

update public.athletes a
   set meet_id = r.meet_id
  from public.races r
 where a.race_id = r.id and a.meet_id is null;

create or replace function public.set_athlete_meet()
returns trigger
language plpgsql
as $$
begin
  select meet_id into new.meet_id from races where id = new.race_id;
  return new;
end;
$$;

drop trigger if exists athletes_set_meet on public.athletes;
create trigger athletes_set_meet
  before insert or update of race_id on public.athletes
  for each row execute function public.set_athlete_meet();

alter table public.athletes alter column meet_id set not null;

-- Collapse any pre-existing same-code duplicates inside one meet before the
-- unique index lands: named rows win, otherwise the oldest row wins.
delete from public.athletes a
 where exists (
   select 1 from public.athletes b
    where b.meet_id = a.meet_id and b.code = a.code and b.id <> a.id
      and (
        (b.name is not null and a.name is null)
        or (
          (b.name is not null) = (a.name is not null)
          and (b.created_at, b.id::text) > (a.created_at, a.id::text)
        )
      )
 );

alter table public.athletes drop constraint if exists athletes_race_id_code_key;
create unique index if not exists athletes_meet_code_key
  on public.athletes (meet_id, code);

-- ---------------------------------------------------------------------------
-- 2. Generated athlete codes: 4 chars, unique within the meet
-- ---------------------------------------------------------------------------

create or replace function public.gen_athlete_code(p_meet_id uuid)
returns text
language plpgsql
as $$
declare
  v_alphabet text := '23456789ABCDEFGHJKMNPQRSTUVWXYZ';
  v_code text;
begin
  loop
    v_code := '';
    for i in 1..4 loop
      v_code := v_code || substr(v_alphabet, 1 + floor(random() * length(v_alphabet))::int, 1);
    end loop;
    exit when not exists (select 1 from athletes where meet_id = p_meet_id and code = v_code);
  end loop;
  return v_code;
end;
$$;

-- ---------------------------------------------------------------------------
-- 3. join_meet: accept 1–8 char codes, claim placeholders anywhere in the
--    meet, hand out fresh 4-char codes scoped to the meet
-- ---------------------------------------------------------------------------

create or replace function public.join_meet(
  p_signup_code text default null,
  p_meet_code text default null,
  p_race_id uuid default null,
  p_name text default null,
  p_school_id uuid default null,
  p_grade text default null,
  p_code text default null,
  p_gender text default null
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_meet public.meets%rowtype;
  v_race public.races%rowtype;
  v_athlete public.athletes%rowtype;
  v_code text;
  v_signup text;
begin
  v_signup := upper(public.normalize_code(coalesce(p_signup_code, '')));

  if v_signup <> '' then
    select * into v_meet from meets where signup_code = v_signup;
    if not found then
      raise exception 'SIGNUP_CODE_INVALID';
    end if;
  else
    -- No signup code: allowed only for meets that opted out of requiring one.
    select * into v_meet from meets
     where code = upper(public.normalize_code(coalesce(p_meet_code, '')))
        or signup_code = upper(public.normalize_code(coalesce(p_meet_code, '')))
     limit 1;
    if not found then
      raise exception 'SIGNUP_CODE_INVALID';
    end if;
    if v_meet.signup_required then
      raise exception 'SIGNUP_CODE_REQUIRED';
    end if;
  end if;

  if v_meet.registration_locked_at is not null then
    raise exception 'REGISTRATION_LOCKED';
  end if;

  select * into v_race from races where id = p_race_id and meet_id = v_meet.id;
  if not found then
    raise exception 'DIVISION_NOT_FOUND';
  end if;
  if v_race.status = 'draft' then
    raise exception 'DIVISION_NOT_OPEN';
  end if;
  if p_name is null or char_length(trim(p_name)) = 0 then
    raise exception 'NAME_REQUIRED';
  end if;
  if p_gender is not null and trim(p_gender) <> ''
     and upper(trim(p_gender)) not in ('M', 'F') then
    raise exception 'GENDER_INVALID';
  end if;

  v_code := public.normalize_code(p_code);

  if v_code = '' then
    -- No code typed: hand out a fresh generated code, free within this meet.
    v_code := public.gen_athlete_code(v_meet.id);
  else
    if char_length(v_code) > 8 then
      raise exception 'CODE_LENGTH';
    end if;
    -- Codes are unique across the whole meet: a registered runner in any
    -- division owns it. Placeholders stay claimable even after finalize.
    if exists (
      select 1 from athletes a
       where a.meet_id = v_meet.id and a.code = v_code and a.name is not null
    ) then
      raise exception 'CODE_TAKEN';
    end if;
  end if;

  select * into v_athlete from athletes
   where meet_id = v_meet.id and code = v_code;

  if found then
    -- Claim the placeholder. It keeps its division when a finish record is
    -- already attached (that is where they actually ran); otherwise it moves
    -- to the division being registered for.
    update athletes
       set name = trim(p_name),
           school_id = p_school_id,
           grade = nullif(trim(coalesce(p_grade, '')), ''),
           gender = coalesce(nullif(upper(trim(coalesce(p_gender, ''))), ''), gender),
           race_id = case
             when exists (select 1 from finish_slots s where s.athlete_id = athletes.id)
             then athletes.race_id else v_race.id end,
           registered_at = now()
     where id = v_athlete.id
     returning * into v_athlete;
  else
    insert into athletes (race_id, code, name, school_id, grade, gender, source, registered_at)
    values (v_race.id, v_code, trim(p_name), p_school_id,
            nullif(trim(coalesce(p_grade, '')), ''),
            nullif(upper(trim(coalesce(p_gender, ''))), ''),
            case when p_code is null or trim(p_code) = '' then 'assigned' else 'self' end,
            now())
    returning * into v_athlete;
  end if;

  return jsonb_build_object(
    'athlete_id', v_athlete.id,
    'code', v_athlete.code,
    'race_id', v_race.id,
    'race_name', v_race.name,
    'meet_id', v_meet.id
  );
end;
$$;

-- ---------------------------------------------------------------------------
-- 4. record_scan: 1–8 char codes; meet-wide lookup with a helpful answer when
--    the code belongs to another division
-- ---------------------------------------------------------------------------

create or replace function public.record_scan(p_scanner_code text, p_race_id uuid, p_code text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_meet   public.meets%rowtype;
  v_race   public.races%rowtype;
  v_ath    public.athletes%rowtype;
  v_slot   public.finish_slots%rowtype;
  v_code   text := upper(public.normalize_code(p_code));
  v_new    boolean := false;
begin
  select * into v_meet from meets where scanner_code = upper(public.normalize_code(p_scanner_code));
  if not found then
    raise exception 'SCANNER_CODE_INVALID';
  end if;

  select * into v_race from races where id = p_race_id and meet_id = v_meet.id;
  if not found then
    raise exception 'RACE_NOT_FOUND';
  end if;
  if v_race.status <> 'running' or v_race.started_at is null then
    raise exception 'NOT_RUNNING';
  end if;

  if v_code !~ '^[A-Z0-9]{1,8}$' then
    raise exception 'CODE_FORMAT';
  end if;

  -- Codes are unique within a meet: lock meet-wide so two scanners in
  -- different divisions can't both decide a fresh code is free.
  perform id from meets where id = v_meet.id for update;
  -- Serialize concurrent scanners on this race before choosing a position.
  perform id from races where id = p_race_id for update;

  select a.* into v_ath from athletes a
   where a.meet_id = v_meet.id and a.code = v_code;
  if found then
    if v_ath.race_id <> p_race_id then
      -- The runner belongs to another division — tell the scanner instead of
      -- recording them in the wrong finish order.
      return jsonb_build_object(
        'status', 'other_division', 'code', v_code,
        'athlete', jsonb_build_object('id', v_ath.id, 'name', v_ath.name),
        'race_name', (select r.name from races r where r.id = v_ath.race_id)
      );
    end if;
    -- A runner is only recorded once.
    select * into v_slot from finish_slots
     where race_id = p_race_id and athlete_id = v_ath.id;
    if found then
      return jsonb_build_object(
        'status', 'already_in', 'seq', v_slot.seq, 'code', v_code
      );
    end if;
  else
    -- Unknown code: keep the finisher's true place with an unclaimed
    -- placeholder; registering that same code later claims it.
    insert into athletes (race_id, code, source)
    values (p_race_id, v_code, 'placeholder')
    returning * into v_ath;
    v_new := true;
  end if;

  -- Prefer attaching to the timer's oldest open split so official times come
  -- from the stopwatch; otherwise append at the current clock.
  select * into v_slot
    from finish_slots
   where race_id = p_race_id and status = 'open' and athlete_id is null
   order by seq
   limit 1
     for update;

  if found then
    update finish_slots
       set athlete_id = v_ath.id, status = 'matched'
     where id = v_slot.id
     returning * into v_slot;
  else
    insert into finish_slots (race_id, seq, t0_offset_ms, device_id, athlete_id, status)
    values (
      p_race_id,
      (select coalesce(max(seq), 0) + 1 from finish_slots where race_id = p_race_id),
      (extract(epoch from now() - v_race.started_at) * 1000)::bigint,
      'scanner',
      v_ath.id,
      'matched'
    )
    returning * into v_slot;
  end if;

  return jsonb_build_object(
    'status', case when v_new then 'placeholder' else 'matched' end,
    'seq', v_slot.seq,
    'slot_id', v_slot.id,
    'code', v_ath.code,
    'athlete', jsonb_build_object(
      'id', v_ath.id, 'name', v_ath.name, 'grade', v_ath.grade,
      'school', (select sc.name from schools sc where sc.id = v_ath.school_id)
    )
  );
end;
$$;

-- ---------------------------------------------------------------------------
-- 5. insert_slot_relative: same length rule; a code owned by another division
--    is refused rather than silently duplicated
-- ---------------------------------------------------------------------------

create or replace function public.insert_slot_relative(
  p_race_id uuid,
  p_anchor_slot_id uuid default null,
  p_side text default 'before',
  p_code text default null,
  p_device_id text default 'admin-edit'
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_race public.races%rowtype;
  v_anchor public.finish_slots%rowtype;
  v_athlete public.athletes%rowtype;
  v_slot public.finish_slots%rowtype;
  v_target int;
  v_max int;
  v_prev bigint;
  v_next bigint;
  v_offset bigint;
  v_code text;
begin
  select * into v_race from races where id = p_race_id;
  if not found then
    raise exception 'RACE_NOT_FOUND';
  end if;

  if not public.meet_auth_ok(v_race.meet_id) then
    raise exception 'NOT_ALLOWED';
  end if;

  if p_anchor_slot_id is null then
    select coalesce(max(seq), 0) into v_max from finish_slots where race_id = p_race_id;
    v_target := v_max + 1;
  else
    select * into v_anchor from finish_slots
     where id = p_anchor_slot_id and race_id = p_race_id;
    if not found then
      raise exception 'SLOT_NOT_FOUND';
    end if;
    if p_side not in ('before', 'after') then
      raise exception 'BAD_SIDE';
    end if;
    v_target := v_anchor.seq + case when p_side = 'after' then 1 else 0 end;
  end if;

  update finish_slots set seq = -seq
   where race_id = p_race_id and seq >= v_target;
  update finish_slots set seq = -seq + 1
   where race_id = p_race_id and seq <= -v_target;

  select max(t0_offset_ms) into v_prev from finish_slots
   where race_id = p_race_id and seq < v_target;
  select min(t0_offset_ms) into v_next from finish_slots
   where race_id = p_race_id and seq > v_target;
  v_offset := case
    when v_prev is not null and v_next is not null then (v_prev + v_next) / 2
    when v_next is not null then greatest(v_next - 1000, 0)
    when v_prev is not null then v_prev + 1000
    else 0
  end;

  v_code := nullif(public.normalize_code(p_code), '');
  if v_code is not null then
    if char_length(v_code) > 8 then
      raise exception 'CODE_LENGTH';
    end if;
    select * into v_athlete from athletes
     where race_id = p_race_id and code = v_code;
    if not found then
      if exists (select 1 from athletes a
                  where a.meet_id = v_race.meet_id and a.code = v_code) then
        raise exception 'CODE_OTHER_DIVISION';
      end if;
      insert into athletes (race_id, code, source)
        values (p_race_id, v_code, 'placeholder')
        returning * into v_athlete;
    end if;
  end if;

  insert into finish_slots (race_id, seq, t0_offset_ms, device_id, athlete_id, status)
  values (p_race_id, v_target, v_offset, coalesce(nullif(p_device_id, ''), 'admin-edit'),
          v_athlete.id,
          case when v_athlete.id is null then 'open' else 'matched' end)
  returning * into v_slot;

  if v_race.status = 'finalized' then
    with ranked as (
      select id, row_number() over (order by seq) as rn
        from finish_slots
       where race_id = p_race_id
         and status = 'matched'
         and athlete_id is not null
    )
    update finish_slots s
       set place = ranked.rn, updated_at = now()
      from ranked where ranked.id = s.id;
    select * into v_slot from finish_slots where id = v_slot.id;
  end if;

  return jsonb_build_object(
    'slot_id', v_slot.id,
    'seq', v_slot.seq,
    'place', v_slot.place,
    'athlete_id', v_slot.athlete_id,
    'code', v_athlete.code,
    'status', v_slot.status
  );
end;
$$;

-- ---------------------------------------------------------------------------
-- 6. Grants + schema cache reload
-- ---------------------------------------------------------------------------

grant execute on function public.join_meet(text, text, uuid, text, uuid, text, text, text) to anon;
grant execute on function public.record_scan(text, uuid, text) to anon;
grant execute on function public.insert_slot_relative(uuid, uuid, text, text, text) to anon;

notify pgrst, 'reload schema';


INSERT INTO public._aspire_applied_migrations (filename) VALUES ('20260921000001_athlete_codes_per_meet.sql') ON CONFLICT (filename) DO NOTHING;
COMMIT;
\endif

-- Migration: 20260922000001_reopen_meet_and_required_codes.sql
-- ----------------------------------------
SELECT (NOT EXISTS (SELECT 1 FROM public._aspire_applied_migrations WHERE filename = '20260922000001_reopen_meet_and_required_codes.sql'))::text AS _run_mig \gset
\if :_run_mig
BEGIN;
-- ===========================================================================
-- Loosen the things that were previously one-way doors, plus an optional
-- "bring your own code" registration rule.
--   * meets.athlete_code_required — when true, self-registration must type the
--     code from the runner's sticker/clip instead of being handed a new one
--   * reopen_meet()               — undo a finalize: races go back to running
--     (or ready) and registration opens again
--   * set_registration_lock()     — close or re-open registration on its own
--   * insert_slot_relative()      — optionally takes the exact time, so adding a
--     missed finisher is one call rather than an insert plus an update
-- ===========================================================================

alter table public.meets
  add column if not exists athlete_code_required boolean not null default false;

-- ---------------------------------------------------------------------------
-- 1. get_meet also reports whether an athlete code is mandatory
-- ---------------------------------------------------------------------------
create or replace function public.get_meet(p_code text)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_meet public.meets%rowtype;
begin
  select * into v_meet from meets
   where code = public.normalize_code(p_code)
      or signup_code = public.normalize_code(p_code)
   limit 1;
  if not found then
    raise exception 'MEET_NOT_FOUND';
  end if;

  return jsonb_build_object(
    'id', v_meet.id,
    'code', v_meet.code,
    'name', v_meet.name,
    'location', v_meet.location,
    'meet_date', v_meet.meet_date,
    'registration_locked', v_meet.registration_locked_at is not null,
    'signup_required', v_meet.signup_required,
    'athlete_code_required', v_meet.athlete_code_required,
    'divisions', (
      select coalesce(
        jsonb_agg(
          jsonb_build_object(
            'id', r.id, 'name', r.name, 'status', r.status,
            'starts_at', r.scheduled_start
          )
          order by r.scheduled_start asc nulls last, r.created_at asc
        ),
        '[]'::jsonb
      )
      from races r
      where r.meet_id = v_meet.id and r.status <> 'draft'
    )
  );
end;
$$;

-- ---------------------------------------------------------------------------
-- 2. join_meet refuses a blank code when the meet insists on one
-- ---------------------------------------------------------------------------
create or replace function public.join_meet(
  p_signup_code text default null,
  p_meet_code text default null,
  p_race_id uuid default null,
  p_name text default null,
  p_school_id uuid default null,
  p_grade text default null,
  p_code text default null,
  p_gender text default null
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_meet public.meets%rowtype;
  v_race public.races%rowtype;
  v_athlete public.athletes%rowtype;
  v_code text;
  v_signup text;
begin
  v_signup := upper(public.normalize_code(coalesce(p_signup_code, '')));

  if v_signup <> '' then
    select * into v_meet from meets where signup_code = v_signup;
    if not found then
      raise exception 'SIGNUP_CODE_INVALID';
    end if;
  else
    -- No signup code: allowed only for meets that opted out of requiring one.
    select * into v_meet from meets
     where code = upper(public.normalize_code(coalesce(p_meet_code, '')))
        or signup_code = upper(public.normalize_code(coalesce(p_meet_code, '')))
     limit 1;
    if not found then
      raise exception 'SIGNUP_CODE_INVALID';
    end if;
    if v_meet.signup_required then
      raise exception 'SIGNUP_CODE_REQUIRED';
    end if;
  end if;

  if v_meet.registration_locked_at is not null then
    raise exception 'REGISTRATION_LOCKED';
  end if;

  select * into v_race from races where id = p_race_id and meet_id = v_meet.id;
  if not found then
    raise exception 'DIVISION_NOT_FOUND';
  end if;
  if v_race.status = 'draft' then
    raise exception 'DIVISION_NOT_OPEN';
  end if;
  if p_name is null or char_length(trim(p_name)) = 0 then
    raise exception 'NAME_REQUIRED';
  end if;
  if p_gender is not null and trim(p_gender) <> ''
     and upper(trim(p_gender)) not in ('M', 'F') then
    raise exception 'GENDER_INVALID';
  end if;

  v_code := public.normalize_code(p_code);

  if v_code = '' then
    if v_meet.athlete_code_required then
      -- Sticker-first meet: every runner arrives with a code, so handing out a
      -- new one would leave the finish line unable to match them.
      raise exception 'CODE_REQUIRED';
    end if;
    v_code := public.gen_athlete_code(v_meet.id);
  else
    if char_length(v_code) > 8 then
      raise exception 'CODE_LENGTH';
    end if;
    -- Codes are unique across the whole meet: a registered runner in any
    -- division owns it. Placeholders stay claimable even after finalize.
    if exists (
      select 1 from athletes a
       where a.meet_id = v_meet.id and a.code = v_code and a.name is not null
    ) then
      raise exception 'CODE_TAKEN';
    end if;
  end if;

  select * into v_athlete from athletes
   where meet_id = v_meet.id and code = v_code;

  if found then
    -- Claim the placeholder. It keeps its division when a finish record is
    -- already attached (that is where they actually ran); otherwise it moves
    -- to the division being registered for.
    update athletes
       set name = trim(p_name),
           school_id = p_school_id,
           grade = nullif(trim(coalesce(p_grade, '')), ''),
           gender = coalesce(nullif(upper(trim(coalesce(p_gender, ''))), ''), gender),
           race_id = case
             when exists (select 1 from finish_slots s where s.athlete_id = athletes.id)
             then athletes.race_id else v_race.id end,
           registered_at = now()
     where id = v_athlete.id
     returning * into v_athlete;
  else
    insert into athletes (race_id, code, name, school_id, grade, gender, source, registered_at)
    values (v_race.id, v_code, trim(p_name), p_school_id,
            nullif(trim(coalesce(p_grade, '')), ''),
            nullif(upper(trim(coalesce(p_gender, ''))), ''),
            case when p_code is null or trim(p_code) = '' then 'assigned' else 'self' end,
            now())
    returning * into v_athlete;
  end if;

  return jsonb_build_object(
    'athlete_id', v_athlete.id,
    'code', v_athlete.code,
    'race_id', v_race.id,
    'race_name', v_race.name,
    'meet_id', v_meet.id
  );
end;
$$;

-- ---------------------------------------------------------------------------
-- 3. Re-open a finalized meet: registration opens up again and every finalized
--    race returns to the state it can be worked on from.
-- ---------------------------------------------------------------------------
create or replace function public.reopen_meet(p_meet_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_races int;
begin
  if not public.meet_auth_ok(p_meet_id) then
    raise exception 'NOT_ALLOWED';
  end if;

  -- A race that had been started goes back to running so the stopwatch and the
  -- scanner can pick up where they left off; one that never started is ready.
  update races
     set status = case when started_at is not null then 'running' else 'ready' end,
         finalized_at = null
   where meet_id = p_meet_id and status = 'finalized';
  get diagnostics v_races = row_count;

  update meets
     set registration_locked_at = null
   where id = p_meet_id;

  return jsonb_build_object('reopened_races', v_races);
end;
$$;

-- ---------------------------------------------------------------------------
-- 4. Registration lock on its own — close it while racing, open it again when a
--    runner turns up late, without touching race status.
-- ---------------------------------------------------------------------------
create or replace function public.set_registration_lock(p_meet_id uuid, p_locked boolean)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
begin
  if not public.meet_auth_ok(p_meet_id) then
    raise exception 'NOT_ALLOWED';
  end if;

  update meets
     set registration_locked_at =
           case when p_locked then coalesce(registration_locked_at, now()) else null end
   where id = p_meet_id;

  return jsonb_build_object(
    'meet_id', p_meet_id,
    'registration_locked', p_locked
  );
end;
$$;

-- ---------------------------------------------------------------------------
-- 5. insert_slot_relative can carry the exact time now (a manager reading a
--    stopwatch or a backup watch knows the real number). Null keeps the old
--    behaviour of guessing halfway between the neighbours.
-- ---------------------------------------------------------------------------
drop function if exists public.insert_slot_relative(uuid, uuid, text, text, text);

create or replace function public.insert_slot_relative(
  p_race_id uuid,
  p_anchor_slot_id uuid default null,
  p_side text default 'before',
  p_code text default null,
  p_device_id text default 'admin-edit',
  p_t0_offset_ms bigint default null
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_race public.races%rowtype;
  v_anchor public.finish_slots%rowtype;
  v_athlete public.athletes%rowtype;
  v_slot public.finish_slots%rowtype;
  v_target int;
  v_max int;
  v_prev bigint;
  v_next bigint;
  v_offset bigint;
  v_code text;
begin
  select * into v_race from races where id = p_race_id;
  if not found then
    raise exception 'RACE_NOT_FOUND';
  end if;

  if not public.meet_auth_ok(v_race.meet_id) then
    raise exception 'NOT_ALLOWED';
  end if;

  if p_anchor_slot_id is null then
    select coalesce(max(seq), 0) into v_max from finish_slots where race_id = p_race_id;
    v_target := v_max + 1;
  else
    select * into v_anchor from finish_slots
     where id = p_anchor_slot_id and race_id = p_race_id;
    if not found then
      raise exception 'SLOT_NOT_FOUND';
    end if;
    if p_side not in ('before', 'after') then
      raise exception 'BAD_SIDE';
    end if;
    v_target := v_anchor.seq + case when p_side = 'after' then 1 else 0 end;
  end if;

  update finish_slots set seq = -seq
   where race_id = p_race_id and seq >= v_target;
  update finish_slots set seq = -seq + 1
   where race_id = p_race_id and seq <= -v_target;

  if p_t0_offset_ms is not null then
    v_offset := p_t0_offset_ms;
  else
    select max(t0_offset_ms) into v_prev from finish_slots
     where race_id = p_race_id and seq < v_target;
    select min(t0_offset_ms) into v_next from finish_slots
     where race_id = p_race_id and seq > v_target;
    v_offset := case
      when v_prev is not null and v_next is not null then (v_prev + v_next) / 2
      when v_next is not null then greatest(v_next - 1000, 0)
      when v_prev is not null then v_prev + 1000
      else 0
    end;
  end if;

  v_code := nullif(public.normalize_code(p_code), '');
  if v_code is not null then
    if char_length(v_code) > 8 then
      raise exception 'CODE_LENGTH';
    end if;
    select * into v_athlete from athletes
     where race_id = p_race_id and code = v_code;
    if not found then
      if exists (select 1 from athletes a
                  where a.meet_id = v_race.meet_id and a.code = v_code) then
        raise exception 'CODE_OTHER_DIVISION';
      end if;
      insert into athletes (race_id, code, source)
        values (p_race_id, v_code, 'placeholder')
        returning * into v_athlete;
    end if;
  end if;

  insert into finish_slots (race_id, seq, t0_offset_ms, device_id, athlete_id, status)
  values (p_race_id, v_target, v_offset, coalesce(nullif(p_device_id, ''), 'admin-edit'),
          v_athlete.id,
          case when v_athlete.id is null then 'open' else 'matched' end)
  returning * into v_slot;

  if v_race.status = 'finalized' then
    with ranked as (
      select id, row_number() over (order by seq) as rn
        from finish_slots
       where race_id = p_race_id
         and status = 'matched'
         and athlete_id is not null
    )
    update finish_slots s
       set place = ranked.rn, updated_at = now()
      from ranked where ranked.id = s.id;
    select * into v_slot from finish_slots where id = v_slot.id;
  end if;

  return jsonb_build_object(
    'slot_id', v_slot.id,
    'seq', v_slot.seq,
    'place', v_slot.place,
    'athlete_id', v_slot.athlete_id,
    'code', v_athlete.code,
    'status', v_slot.status
  );
end;
$$;

-- ---------------------------------------------------------------------------
-- 6. Grants + schema cache reload
-- ---------------------------------------------------------------------------
grant execute on function public.get_meet(text) to anon;
grant execute on function public.join_meet(text, text, uuid, text, uuid, text, text, text) to anon;
grant execute on function public.reopen_meet(uuid) to anon;
grant execute on function public.set_registration_lock(uuid, boolean) to anon;
grant execute on function public.insert_slot_relative(uuid, uuid, text, text, text, bigint) to anon;

notify pgrst, 'reload schema';


INSERT INTO public._aspire_applied_migrations (filename) VALUES ('20260922000001_reopen_meet_and_required_codes.sql') ON CONFLICT (filename) DO NOTHING;
COMMIT;
\endif

-- Migration: 20260923000001_race_registration_open_by_default.sql
-- ----------------------------------------
SELECT (NOT EXISTS (SELECT 1 FROM public._aspire_applied_migrations WHERE filename = '20260923000001_race_registration_open_by_default.sql'))::text AS _run_mig \gset
\if :_run_mig
BEGIN;
-- ===========================================================================
-- Divisions are open for registration the moment they are created, and an
-- organizer can close or re-open one race without touching the others.
--   * races.status default        'draft' -> 'registration_open'
--   * races.registration_closed_at  per-division switch (null = open)
--   * set_race_registration()     admin-only close / re-open for one race
-- ===========================================================================

alter table public.races
  alter column status set default 'registration_open';

-- A closed division stays visible (results, timing tent) but rejects signups.
alter table public.races
  add column if not exists registration_closed_at timestamptz;

-- Every draft predates this rule: a race was never deliberately left a draft,
-- the old default simply created it that way and nobody clicked "Open".
update public.races set status = 'registration_open' where status = 'draft';

-- ---------------------------------------------------------------------------
-- 1. get_meet tells the signup screen which divisions will accept a runner
-- ---------------------------------------------------------------------------
create or replace function public.get_meet(p_code text)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_meet public.meets%rowtype;
begin
  select * into v_meet from meets
   where code = public.normalize_code(p_code)
      or signup_code = public.normalize_code(p_code)
   limit 1;
  if not found then
    raise exception 'MEET_NOT_FOUND';
  end if;

  return jsonb_build_object(
    'id', v_meet.id,
    'code', v_meet.code,
    'name', v_meet.name,
    'location', v_meet.location,
    'meet_date', v_meet.meet_date,
    'registration_locked', v_meet.registration_locked_at is not null,
    'signup_required', v_meet.signup_required,
    'athlete_code_required', v_meet.athlete_code_required,
    'divisions', (
      select coalesce(
        jsonb_agg(
          jsonb_build_object(
            'id', r.id, 'name', r.name, 'status', r.status,
            'starts_at', r.scheduled_start,
            'registration_open', r.registration_closed_at is null
          )
          order by r.scheduled_start asc nulls last, r.created_at asc
        ),
        '[]'::jsonb
      )
      from races r
      where r.meet_id = v_meet.id and r.status <> 'draft'
    )
  );
end;
$$;

-- ---------------------------------------------------------------------------
-- 2. join_meet also honours the per-division switch
-- ---------------------------------------------------------------------------
create or replace function public.join_meet(
  p_signup_code text default null,
  p_meet_code text default null,
  p_race_id uuid default null,
  p_name text default null,
  p_school_id uuid default null,
  p_grade text default null,
  p_code text default null,
  p_gender text default null
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_meet public.meets%rowtype;
  v_race public.races%rowtype;
  v_athlete public.athletes%rowtype;
  v_code text;
  v_signup text;
begin
  v_signup := upper(public.normalize_code(coalesce(p_signup_code, '')));

  if v_signup <> '' then
    select * into v_meet from meets where signup_code = v_signup;
    if not found then
      raise exception 'SIGNUP_CODE_INVALID';
    end if;
  else
    -- No signup code: allowed only for meets that opted out of requiring one.
    select * into v_meet from meets
     where code = upper(public.normalize_code(coalesce(p_meet_code, '')))
        or signup_code = upper(public.normalize_code(coalesce(p_meet_code, '')))
     limit 1;
    if not found then
      raise exception 'SIGNUP_CODE_INVALID';
    end if;
    if v_meet.signup_required then
      raise exception 'SIGNUP_CODE_REQUIRED';
    end if;
  end if;

  if v_meet.registration_locked_at is not null then
    raise exception 'REGISTRATION_LOCKED';
  end if;

  select * into v_race from races where id = p_race_id and meet_id = v_meet.id;
  if not found then
    raise exception 'DIVISION_NOT_FOUND';
  end if;
  if v_race.status = 'draft' then
    raise exception 'DIVISION_NOT_OPEN';
  end if;
  if v_race.registration_closed_at is not null then
    raise exception 'DIVISION_CLOSED';
  end if;
  if p_name is null or char_length(trim(p_name)) = 0 then
    raise exception 'NAME_REQUIRED';
  end if;
  if p_gender is not null and trim(p_gender) <> ''
     and upper(trim(p_gender)) not in ('M', 'F') then
    raise exception 'GENDER_INVALID';
  end if;

  v_code := public.normalize_code(p_code);

  if v_code = '' then
    if v_meet.athlete_code_required then
      -- Sticker-first meet: every runner arrives with a code, so handing out a
      -- new one would leave the finish line unable to match them.
      raise exception 'CODE_REQUIRED';
    end if;
    v_code := public.gen_athlete_code(v_meet.id);
  else
    if char_length(v_code) > 8 then
      raise exception 'CODE_LENGTH';
    end if;
    -- Codes are unique across the whole meet: a registered runner in any
    -- division owns it. Placeholders stay claimable even after finalize.
    if exists (
      select 1 from athletes a
       where a.meet_id = v_meet.id and a.code = v_code and a.name is not null
    ) then
      raise exception 'CODE_TAKEN';
    end if;
  end if;

  select * into v_athlete from athletes
   where meet_id = v_meet.id and code = v_code;

  if found then
    -- Claim the placeholder. It keeps its division when a finish record is
    -- already attached (that is where they actually ran); otherwise it moves
    -- to the division being registered for.
    update athletes
       set name = trim(p_name),
           school_id = p_school_id,
           grade = nullif(trim(coalesce(p_grade, '')), ''),
           gender = coalesce(nullif(upper(trim(coalesce(p_gender, ''))), ''), gender),
           race_id = case
             when exists (select 1 from finish_slots s where s.athlete_id = athletes.id)
             then athletes.race_id else v_race.id end,
           registered_at = now()
     where id = v_athlete.id
     returning * into v_athlete;
  else
    insert into athletes (race_id, code, name, school_id, grade, gender, source, registered_at)
    values (v_race.id, v_code, trim(p_name), p_school_id,
            nullif(trim(coalesce(p_grade, '')), ''),
            nullif(upper(trim(coalesce(p_gender, ''))), ''),
            case when p_code is null or trim(p_code) = '' then 'assigned' else 'self' end,
            now())
    returning * into v_athlete;
  end if;

  return jsonb_build_object(
    'athlete_id', v_athlete.id,
    'code', v_athlete.code,
    'race_id', v_race.id,
    'race_name', v_race.name,
    'meet_id', v_meet.id
  );
end;
$$;

-- ---------------------------------------------------------------------------
-- 3. One division's registration switch. Independent of the meet-wide lock and
--    of race status: closing a running division stops signups but leaves the
--    stopwatch, the scanner and the results exactly where they are. Opening a
--    division that somehow ended up a draft puts it back in the lineup too.
-- ---------------------------------------------------------------------------
create or replace function public.set_race_registration(p_race_id uuid, p_open boolean)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_race public.races%rowtype;
begin
  select * into v_race from races where id = p_race_id;
  if not found then
    raise exception 'DIVISION_NOT_FOUND';
  end if;
  if not public.meet_auth_ok(v_race.meet_id) then
    raise exception 'NOT_ALLOWED';
  end if;

  update races
     set registration_closed_at = case when p_open then null else now() end,
         status = case when p_open and status = 'draft'
                      then 'registration_open' else status end
   where id = p_race_id
   returning * into v_race;

  return jsonb_build_object(
    'race_id', v_race.id,
    'registration_open', v_race.registration_closed_at is null,
    'status', v_race.status
  );
end;
$$;

grant execute on function public.set_race_registration(uuid, boolean) to anon;

notify pgrst, 'reload schema';
INSERT INTO public._aspire_applied_migrations (filename) VALUES ('20260923000001_race_registration_open_by_default.sql') ON CONFLICT (filename) DO NOTHING;
COMMIT;
\endif
-- Migration: 20260924000001_race_allowed_grades.sql
-- ----------------------------------------
SELECT (NOT EXISTS (SELECT 1 FROM public._aspire_applied_migrations WHERE filename = '20260924000001_race_allowed_grades.sql'))::text AS _run_mig `gset
\if :_run_mig
BEGIN;
-- ===========================================================================
-- Each division decides which grades may sign up for it. Cross country meets
-- run junior high, JV and varsity flights off the same clock, so the grade list
-- belongs to the race rather than being hard-wired to 9-12.
--   * races.allowed_grades   smallint[], defaults to the high-school four
--   * get_meet               hands the list to the signup screen
--   * join_meet              rejects a grade the division did not open
-- ===========================================================================

alter table public.races
  add column if not exists allowed_grades smallint[] not null default array[9, 10, 11, 12];

-- Grade lists stay sane at the database level: 1-16, no repeats, never empty.
-- (A CHECK can't hold a subquery itself, so the distinct-count lives in this function.)
create or replace function public.grades_ok(p_grades smallint[])
returns boolean
language sql
immutable
as $$
  select p_grades is not null
     and array_length(p_grades, 1) between 1 and 16
     and p_grades <@ '{1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,16}'::smallint[]
     and array_length(p_grades, 1) = (
           select count(distinct g) from unnest(p_grades) as g
         );
$$;

alter table public.races
  drop constraint if exists races_allowed_grades_ok;
alter table public.races
  add constraint races_allowed_grades_ok check (public.grades_ok(allowed_grades));

-- ---------------------------------------------------------------------------
-- 1. get_meet also publishes each division's grade list
-- ---------------------------------------------------------------------------
create or replace function public.get_meet(p_code text)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_meet public.meets%rowtype;
begin
  select * into v_meet from meets
   where code = public.normalize_code(p_code)
      or signup_code = public.normalize_code(p_code)
   limit 1;
  if not found then
    raise exception 'MEET_NOT_FOUND';
  end if;

  return jsonb_build_object(
    'id', v_meet.id,
    'code', v_meet.code,
    'name', v_meet.name,
    'location', v_meet.location,
    'meet_date', v_meet.meet_date,
    'registration_locked', v_meet.registration_locked_at is not null,
    'signup_required', v_meet.signup_required,
    'athlete_code_required', v_meet.athlete_code_required,
    'divisions', (
      select coalesce(
        jsonb_agg(
          jsonb_build_object(
            'id', r.id, 'name', r.name, 'status', r.status,
            'starts_at', r.scheduled_start,
            'registration_open', r.registration_closed_at is null,
            'allowed_grades', (
              select coalesce(
                jsonb_agg(g order by g),
                '[]'::jsonb
              )
              from unnest(r.allowed_grades) as g
            )
          )
          order by r.scheduled_start asc nulls last, r.created_at asc
        ),
        '[]'::jsonb
      )
      from races r
      where r.meet_id = v_meet.id and r.status <> 'draft'
    )
  );
end;
$$;

-- ---------------------------------------------------------------------------
-- 2. join_meet only accepts a grade the division opened
-- ---------------------------------------------------------------------------
create or replace function public.join_meet(
  p_signup_code text default null,
  p_meet_code text default null,
  p_race_id uuid default null,
  p_name text default null,
  p_school_id uuid default null,
  p_grade text default null,
  p_code text default null,
  p_gender text default null
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_meet public.meets%rowtype;
  v_race public.races%rowtype;
  v_athlete public.athletes%rowtype;
  v_code text;
  v_signup text;
  v_grade text;
begin
  v_signup := upper(public.normalize_code(coalesce(p_signup_code, '')));

  if v_signup <> '' then
    select * into v_meet from meets where signup_code = v_signup;
    if not found then
      raise exception 'SIGNUP_CODE_INVALID';
    end if;
  else
    -- No signup code: allowed only for meets that opted out of requiring one.
    select * into v_meet from meets
     where code = upper(public.normalize_code(coalesce(p_meet_code, '')))
        or signup_code = upper(public.normalize_code(coalesce(p_meet_code, '')))
     limit 1;
    if not found then
      raise exception 'SIGNUP_CODE_INVALID';
    end if;
    if v_meet.signup_required then
      raise exception 'SIGNUP_CODE_REQUIRED';
    end if;
  end if;

  if v_meet.registration_locked_at is not null then
    raise exception 'REGISTRATION_LOCKED';
  end if;

  select * into v_race from races where id = p_race_id and meet_id = v_meet.id;
  if not found then
    raise exception 'DIVISION_NOT_FOUND';
  end if;
  if v_race.status = 'draft' then
    raise exception 'DIVISION_NOT_OPEN';
  end if;
  if v_race.registration_closed_at is not null then
    raise exception 'DIVISION_CLOSED';
  end if;
  if p_name is null or char_length(trim(p_name)) = 0 then
    raise exception 'NAME_REQUIRED';
  end if;
  if p_gender is not null and trim(p_gender) <> ''
     and upper(trim(p_gender)) not in ('M', 'F') then
    raise exception 'GENDER_INVALID';
  end if;

  -- Grade stays optional, but a runner cannot invent one the division excluded.
  v_grade := nullif(trim(coalesce(p_grade, '')), '');
  if v_grade is not null then
    if v_grade !~ '^[0-9]{1,2}$' then
      raise exception 'GRADE_INVALID';
    end if;
    if not (v_grade::smallint = any (v_race.allowed_grades)) then
      raise exception 'GRADE_NOT_ALLOWED';
    end if;
  end if;

  v_code := public.normalize_code(p_code);

  if v_code = '' then
    if v_meet.athlete_code_required then
      -- Sticker-first meet: every runner arrives with a code, so handing out a
      -- new one would leave the finish line unable to match them.
      raise exception 'CODE_REQUIRED';
    end if;
    v_code := public.gen_athlete_code(v_meet.id);
  else
    if char_length(v_code) > 8 then
      raise exception 'CODE_LENGTH';
    end if;
    -- Codes are unique across the whole meet: a registered runner in any
    -- division owns it. Placeholders stay claimable even after finalize.
    if exists (
      select 1 from athletes a
       where a.meet_id = v_meet.id and a.code = v_code and a.name is not null
    ) then
      raise exception 'CODE_TAKEN';
    end if;
  end if;

  select * into v_athlete from athletes
   where meet_id = v_meet.id and code = v_code;

  if found then
    -- Claim the placeholder. It keeps its division when a finish record is
    -- already attached (that is where they actually ran); otherwise it moves
    -- to the division being registered for.
    update athletes
       set name = trim(p_name),
           school_id = p_school_id,
           grade = nullif(trim(coalesce(p_grade, '')), ''),
           gender = coalesce(nullif(upper(trim(coalesce(p_gender, ''))), ''), gender),
           race_id = case
             when exists (select 1 from finish_slots s where s.athlete_id = athletes.id)
             then athletes.race_id else v_race.id end,
           registered_at = now()
     where id = v_athlete.id
     returning * into v_athlete;
  else
    insert into athletes (race_id, code, name, school_id, grade, gender, source, registered_at)
    values (v_race.id, v_code, trim(p_name), p_school_id,
            nullif(trim(coalesce(p_grade, '')), ''),
            nullif(upper(trim(coalesce(p_gender, ''))), ''),
            case when p_code is null or trim(p_code) = '' then 'assigned' else 'self' end,
            now())
    returning * into v_athlete;
  end if;

  return jsonb_build_object(
    'athlete_id', v_athlete.id,
    'code', v_athlete.code,
    'race_id', v_race.id,
    'race_name', v_race.name,
    'meet_id', v_meet.id
  );
end;
$$;

notify pgrst, 'reload schema';
INSERT INTO public._aspire_applied_migrations (filename) VALUES ('20260924000001_race_allowed_grades.sql') ON CONFLICT (filename) DO NOTHING;
COMMIT;
\endif


\set ON_ERROR_STOP on
DO $$
DECLARE missing text;
BEGIN
    SELECT string_agg(e.f, ', ') INTO missing FROM (VALUES ('20260906000001_init.sql'), ('20260911000001_walkons_and_editable_results.sql'), ('20260912000001_meet_admins.sql'), ('20260918000001_meet_codes_dual_timing.sql'), ('20260919000001_gender_optional_signup.sql'), ('20260920000001_scanner_role.sql'), ('20260921000001_athlete_codes_per_meet.sql'), ('20260922000001_reopen_meet_and_required_codes.sql'), ('20260923000001_race_registration_open_by_default.sql'), ('20260924000001_race_allowed_grades.sql')) AS e(f)
        WHERE NOT EXISTS (SELECT 1 FROM public._aspire_applied_migrations m WHERE m.filename = e.f);
    IF missing IS NOT NULL THEN
        RAISE EXCEPTION '[Migrations] ABORT: not all migrations applied this pass (tracking left truthful for retry). Missing: %', missing;
    END IF;
    RAISE NOTICE '[Migrations] all expected migrations applied';
END;
$$;
\set ON_ERROR_STOP off

-- ============================================
-- END MIGRATIONS
-- ============================================
