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
