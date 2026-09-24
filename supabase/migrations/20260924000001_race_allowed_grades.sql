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
