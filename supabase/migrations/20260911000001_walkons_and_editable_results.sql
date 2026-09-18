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
