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
