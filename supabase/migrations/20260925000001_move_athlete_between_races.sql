-- Keep the existing edit form atomic when an admin corrects a runner's race.
-- Finish slots belong to their original race; never strand one by moving its athlete.
drop function public.admin_update_athlete(uuid, text, uuid, text, text, text, boolean);

create function public.admin_update_athlete(
  p_athlete_id uuid,
  p_name text default null,
  p_school_id uuid default null,
  p_grade text default null,
  p_gender text default null,
  p_code text default null,
  p_clear_school boolean default false,
  p_race_id uuid default null,
  p_expected_race_id uuid default null
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_athlete public.athletes%rowtype;
  v_race public.races%rowtype;
  v_name text;
  v_code text;
  v_grade text;
  v_gender text;
  v_moving boolean;
begin
  select * into v_athlete from athletes where id = p_athlete_id;
  if not found then
    raise exception 'ATHLETE_NOT_FOUND';
  end if;
  if not public.meet_auth_ok(v_athlete.meet_id) then
    raise exception 'NOT_ALLOWED';
  end if;

  -- record_scan takes this same meet lock before it can attach a finish.
  perform 1 from meets where id = v_athlete.meet_id for update;
  select * into v_athlete from athletes where id = p_athlete_id for update;
  if not found then
    raise exception 'ATHLETE_NOT_FOUND';
  end if;
  if not public.meet_auth_ok(v_athlete.meet_id) then
    raise exception 'NOT_ALLOWED';
  end if;
  if p_expected_race_id is not null and v_athlete.race_id <> p_expected_race_id then
    raise exception 'RACE_CHANGED';
  end if;

  select * into v_race from races
   where id = coalesce(p_race_id, v_athlete.race_id)
     and meet_id = v_athlete.meet_id;
  if not found then
    raise exception 'DESTINATION_RACE_INVALID';
  end if;
  v_moving := v_race.id <> v_athlete.race_id;
  if v_moving and exists (
    select 1 from finish_slots s where s.athlete_id = v_athlete.id
  ) then
    raise exception 'FINISH_ALREADY_RECORDED';
  end if;

  -- Null arguments leave old fields unchanged; empty grade/gender clears them.
  v_name := case when p_name is null then v_athlete.name else trim(p_name) end;
  if v_name is null or char_length(v_name) = 0 then
    raise exception 'NAME_REQUIRED';
  end if;

  if p_code is not null then
    v_code := public.normalize_code(p_code);
    if v_code = '' then
      raise exception 'CODE_INVALID';
    end if;
    if char_length(v_code) > 8 then
      raise exception 'CODE_LENGTH';
    end if;
    if exists (
      select 1 from athletes a
       where a.meet_id = v_athlete.meet_id and a.code = v_code and a.id <> v_athlete.id
    ) then
      raise exception 'CODE_TAKEN';
    end if;
  else
    v_code := v_athlete.code;
  end if;

  v_grade := case when p_grade is null then v_athlete.grade else nullif(trim(p_grade), '') end;
  if v_grade is not null and (p_grade is not null or v_moving) then
    if v_grade !~ '^[0-9]{1,2}$' then
      raise exception 'GRADE_INVALID';
    end if;
    if not (v_grade::smallint = any (v_race.allowed_grades)) then
      raise exception 'GRADE_NOT_ALLOWED';
    end if;
  end if;

  if p_gender is not null then
    v_gender := nullif(upper(trim(p_gender)), '');
    if v_gender is not null and v_gender not in ('M', 'F') then
      raise exception 'GENDER_INVALID';
    end if;
  else
    v_gender := v_athlete.gender;
  end if;

  if p_school_id is not null and not exists (
    select 1 from schools s where s.id = p_school_id and s.meet_id = v_athlete.meet_id
  ) then
    raise exception 'SCHOOL_NOT_FOUND';
  end if;

  update athletes
     set name = v_name,
         code = v_code,
         race_id = v_race.id,
         school_id = case when p_clear_school then null else coalesce(p_school_id, school_id) end,
         grade = v_grade,
         gender = v_gender
   where id = v_athlete.id
   returning * into v_athlete;

  return jsonb_build_object(
    'athlete_id', v_athlete.id,
    'race_id', v_athlete.race_id,
    'race_name', v_race.name,
    'code', v_athlete.code,
    'name', v_athlete.name,
    'grade', v_athlete.grade,
    'gender', v_athlete.gender,
    'school_id', v_athlete.school_id,
    'finish_count', (select count(*) from finish_slots s where s.athlete_id = v_athlete.id)
  );
end;
$$;

grant execute on function public.admin_update_athlete(uuid, text, uuid, text, text, text, boolean, uuid, uuid) to anon;

create index if not exists idx_slots_athlete on public.finish_slots (athlete_id)
  where athlete_id is not null;

-- Every finish attachment takes a share lock on the athlete. A simultaneous
-- race change then waits until the slot is visible, or wins first and causes
-- the slot attachment to fail rather than leaving mismatched races.
create function public.guard_finish_slot_athlete_race()
returns trigger
language plpgsql
set search_path = public
as $$
declare
  v_race_id uuid;
begin
  if new.athlete_id is not null then
    select race_id into v_race_id from athletes where id = new.athlete_id for share;
    if v_race_id is distinct from new.race_id then
      raise exception 'ATHLETE_RACE_MISMATCH';
    end if;
  end if;
  return new;
end;
$$;

create trigger finish_slots_athlete_race
  before insert or update of race_id, athlete_id on public.finish_slots
  for each row execute function public.guard_finish_slot_athlete_race();

-- Protect all athlete race changes (including a signup claiming a placeholder),
-- not only calls through admin_update_athlete.
create function public.guard_athlete_race_with_finish()
returns trigger
language plpgsql
set search_path = public
as $$
begin
  if new.race_id is distinct from old.race_id and exists (
    select 1 from finish_slots where athlete_id = old.id
  ) then
    raise exception 'FINISH_ALREADY_RECORDED';
  end if;
  return new;
end;
$$;

create trigger athletes_keep_finish_race
  before update of race_id on public.athletes
  for each row execute function public.guard_athlete_race_with_finish();

notify pgrst, 'reload schema';
