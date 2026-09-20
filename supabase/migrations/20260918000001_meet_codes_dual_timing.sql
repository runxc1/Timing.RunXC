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
