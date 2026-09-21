-- ===========================================================================
-- Dedicated finish-line scanner role
--
-- The stopwatch timer only taps splits; a separate crew member (or two) at
-- the chute scans/types each athlete code in finishing order. A per-meet
-- `scanner_code` authorizes exactly that: resolve the meet, record scans and
-- undo the last one. Nothing else — no admin, no finalize, no edits.
--
-- Scans are recorded server-side (record_scan) so concurrent scanners can
-- never collide on finish_slots (race_id, seq): the race row is locked while
-- the next position is chosen. A scan attaches the code to the timer's oldest
-- open split slot when one exists (the official time comes from the stopwatch);
-- otherwise it appends a new slot at the current clock offset. Unknown codes
-- become unclaimed placeholders immediately so true finishing order survives;
-- registration with that same code afterwards claims them (existing flow).
-- ===========================================================================

alter table public.meets
  add column if not exists scanner_code text unique;

do $$
declare
  m record;
  c text;
begin
  for m in select id, scanner_code from public.meets loop
    if m.scanner_code is null then
      loop
        c := public.gen_code('public.meets'::regclass, 'scanner_code');
        exit when not exists (select 1 from public.meets x where x.scanner_code = c);
      end loop;
      update public.meets set scanner_code = c where id = m.id;
    end if;
  end loop;
end;
$$;

alter table public.meets
  alter column scanner_code set default gen_code('public.meets'::regclass, 'scanner_code');

-- ---------------------------------------------------------------------------
-- Code management: teach the generic setters about the scanner kind
-- ---------------------------------------------------------------------------

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
  elsif p_kind = 'scanner' then
    return not exists (select 1 from meets m where m.scanner_code = v_code);
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
    elsif p_kind = 'scanner' then
      loop
        v_code := public.gen_code('public.meets'::regclass, 'scanner_code');
        exit when not exists (select 1 from meets m where m.scanner_code = v_code);
      end loop;
      update meets set scanner_code = v_code where id = p_meet_id;
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
    elsif p_kind = 'scanner' then
      if exists (select 1 from meets m where m.scanner_code = v_code and m.id <> p_meet_id) then
        raise exception 'CODE_TAKEN';
      end if;
      update meets set scanner_code = v_code where id = p_meet_id;
    else
      raise exception 'BAD_KIND';
    end if;
  end if;

  return jsonb_build_object(p_kind, v_code);
end;
$$;

-- ---------------------------------------------------------------------------
-- Scanner devices: resolve the meet from a scanner code
-- ---------------------------------------------------------------------------

create or replace function public.resolve_scanner(p_code text)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_meet public.meets%rowtype;
begin
  select * into v_meet from meets where scanner_code = upper(public.normalize_code(p_code));
  if not found then
    raise exception 'SCANNER_CODE_INVALID';
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
    )
  );
end;
$$;

-- ---------------------------------------------------------------------------
-- record_scan: one scanned code = one recorded finisher, ordered server-side
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

  if v_code !~ '^[A-Z0-9]{6}$' then
    raise exception 'CODE_FORMAT';
  end if;

  -- Serialize concurrent scanners on this race before choosing a position.
  perform id from races where id = p_race_id for update;

  select a.* into v_ath from athletes a where a.race_id = p_race_id and a.code = v_code;
  if found then
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
-- undo_scan: remove a mis-scan (and its unclaimed placeholder, if any)
-- ---------------------------------------------------------------------------

create or replace function public.undo_scan(p_scanner_code text, p_slot_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_meet public.meets%rowtype;
  v_race public.races%rowtype;
  v_slot public.finish_slots%rowtype;
begin
  select * into v_meet from meets where scanner_code = upper(public.normalize_code(p_scanner_code));
  if not found then
    raise exception 'SCANNER_CODE_INVALID';
  end if;

  select * into v_slot from finish_slots
   where id = p_slot_id
     and race_id in (select id from races where meet_id = v_meet.id);
  if not found then
    raise exception 'SLOT_NOT_FOUND';
  end if;

  select * into v_race from races where id = v_slot.race_id;
  if v_race.status = 'finalized' then
    raise exception 'FINALIZED';
  end if;

  perform id from races where id = v_slot.race_id for update;

  if v_slot.device_id = 'scanner' then
    -- The scan created this slot — remove it outright.
    delete from finish_slots where id = v_slot.id;
  else
    -- The slot was the timer's split tap; the scan only attached an identity.
    -- Reopen it so the official time survives and can be matched again.
    update finish_slots
       set athlete_id = null, status = 'open'
     where id = v_slot.id;
  end if;

  -- An unclaimed placeholder exists only for its finish record — remove it
  -- too so the code can be re-scanned or registered cleanly.
  if v_slot.athlete_id is not null then
    delete from athletes a
     where a.id = v_slot.athlete_id
       and a.name is null
       and a.source = 'placeholder'
       and not exists (select 1 from finish_slots s where s.athlete_id = a.id);
  end if;

  return jsonb_build_object('removed_seq', v_slot.seq);
end;
$$;

-- ---------------------------------------------------------------------------
-- Grants + pool reload
-- ---------------------------------------------------------------------------

grant execute on function public.resolve_scanner(text) to anon;
grant execute on function public.record_scan(text, uuid, text) to anon;
grant execute on function public.undo_scan(text, uuid) to anon;

notify pgrst, 'reload schema';
