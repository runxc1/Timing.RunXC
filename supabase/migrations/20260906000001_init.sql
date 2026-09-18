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
