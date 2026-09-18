-- ============================================
-- SUPABASE MIGRATIONS (auto-generated)
-- Generated at: 2026-09-18 12:20:30
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

\set ON_ERROR_STOP on
DO $$
DECLARE missing text;
BEGIN
    SELECT string_agg(e.f, ', ') INTO missing FROM (VALUES ('20260906000001_init.sql'), ('20260911000001_walkons_and_editable_results.sql'), ('20260912000001_meet_admins.sql')) AS e(f)
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
