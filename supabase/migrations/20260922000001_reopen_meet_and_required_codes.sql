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
