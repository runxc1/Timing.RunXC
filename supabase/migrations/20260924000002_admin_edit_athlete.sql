-- ===========================================================================
-- Fixing a registration after the fact. Runners mistype their name, pick the
-- wrong school, the wrong grade, the wrong gender, or copy an athlete code
-- badly, and until now nobody could correct it without deleting the runner.
-- An admin-only RPC does the edit so the same rules signup used still apply:
-- codes stay 1-8 characters and unique inside the meet, grades have to be a
-- grade the division actually offers, and the school has to belong to the meet.
-- ===========================================================================

create or replace function public.admin_update_athlete(
  p_athlete_id uuid,
  p_name text default null,
  p_school_id uuid default null,
  p_grade text default null,
  p_gender text default null,
  p_code text default null,
  p_clear_school boolean default false
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
begin
  select * into v_athlete from athletes where id = p_athlete_id;
  if not found then
    raise exception 'ATHLETE_NOT_FOUND';
  end if;
  if not public.meet_auth_ok(v_athlete.meet_id) then
    raise exception 'NOT_ALLOWED';
  end if;

  select * into v_race from races where id = v_athlete.race_id;

  -- Convention: a null p_grade / p_gender / p_code means "unchanged" (an empty
  -- string clears grade or gender), and school needs its own flag because uuids
  -- have no empty value to send.
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
    -- Codes are unique across the meet, not just this division.
    if exists (
      select 1 from athletes a
       where a.meet_id = v_athlete.meet_id and a.code = v_code and a.id <> v_athlete.id
    ) then
      raise exception 'CODE_TAKEN';
    end if;
  else
    v_code := v_athlete.code;
  end if;

  if p_grade is not null then
    v_grade := nullif(trim(p_grade), '');
    if v_grade is not null then
      if v_grade !~ '^[0-9]{1,2}$' then
        raise exception 'GRADE_INVALID';
      end if;
      if not (v_grade::smallint = any (v_race.allowed_grades)) then
        raise exception 'GRADE_NOT_ALLOWED';
      end if;
    end if;
  else
    v_grade := v_athlete.grade;
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
         school_id = case when p_clear_school then null else coalesce(p_school_id, school_id) end,
         grade = v_grade,
         gender = v_gender
   where id = v_athlete.id
   returning * into v_athlete;

  -- How much timing data hangs off this runner: renaming their code is safe
  -- because finish slots point at the row, but the admin should hear about it.
  return jsonb_build_object(
    'athlete_id', v_athlete.id,
    'race_id', v_athlete.race_id,
    'code', v_athlete.code,
    'name', v_athlete.name,
    'grade', v_athlete.grade,
    'gender', v_athlete.gender,
    'school_id', v_athlete.school_id,
    'finish_count', (select count(*) from finish_slots s where s.athlete_id = v_athlete.id)
  );
end;
$$;

grant execute on function public.admin_update_athlete(uuid, text, uuid, text, text, text, boolean) to anon;

notify pgrst, 'reload schema';
