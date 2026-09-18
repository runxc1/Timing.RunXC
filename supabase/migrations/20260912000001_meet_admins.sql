-- timing.runXC.run — registered meet/race admins
--
-- Organizers now register (name + email) when they create a meet, and can
-- delegate administration to other people. Each admin gets their own 6-char
-- credential, presented in the same X-Meet-Admin-Code header the owner code
-- uses, so any of them can create races, manage schools and edit results.
-- Emails are never publicly readable: meet_admins has no anonymous select.

-- ---------------------------------------------------------------------------
-- Table
-- ---------------------------------------------------------------------------

create table public.meet_admins (
  id uuid primary key default gen_random_uuid(),
  meet_id uuid not null references public.meets (id) on delete cascade,
  email text not null,
  name text,
  code text not null unique,
  role text not null default 'admin' check (role in ('owner', 'admin')),
  created_at timestamptz not null default now(),
  unique (meet_id, email)
);

create index meet_admins_meet_id_idx on public.meet_admins (meet_id);

alter table public.meet_admins enable row level security;

-- ---------------------------------------------------------------------------
-- Credential check: owner code or any delegated admin code
-- ---------------------------------------------------------------------------

create or replace function public.meet_auth_ok(p_meet_id uuid)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (
    select 1
      from meets m
     where m.id = p_meet_id
       and (
         m.admin_code = upper(public.hdr('x-meet-admin-code'))
         or exists (
           select 1 from meet_admins a
            where a.meet_id = m.id
              and a.code = upper(public.hdr('x-meet-admin-code'))
         )
       )
  );
$$;

-- Meet management policies now accept delegated admins too.
drop policy meets_update on public.meets;
create policy meets_update on public.meets for update to anon
  using (public.meet_auth_ok(id));
drop policy meets_delete on public.meets;
create policy meets_delete on public.meets for delete to anon
  using (public.meet_auth_ok(id));

drop policy schools_insert on public.schools;
create policy schools_insert on public.schools for insert to anon
  with check (public.meet_auth_ok(meet_id));
drop policy schools_update on public.schools;
create policy schools_update on public.schools for update to anon
  using (public.meet_auth_ok(meet_id));
drop policy schools_delete on public.schools;
create policy schools_delete on public.schools for delete to anon
  using (public.meet_auth_ok(meet_id));

drop policy races_insert on public.races;
create policy races_insert on public.races for insert to anon
  with check (public.meet_auth_ok(meet_id));
drop policy races_update on public.races;
create policy races_update on public.races for update to anon
  using (public.meet_auth_ok(meet_id) or race_code = upper(public.hdr('x-race-code')));
drop policy races_delete on public.races;
create policy races_delete on public.races for delete to anon
  using (public.meet_auth_ok(meet_id));

-- Admin list: visible and editable only to people who already hold a
-- credential for that meet. The owner row cannot be removed.
create policy meet_admins_select on public.meet_admins for select to anon
  using (public.meet_auth_ok(meet_id));
create policy meet_admins_delete on public.meet_admins for delete to anon
  using (public.meet_auth_ok(meet_id) and role <> 'owner');
-- No insert policy: rows are created by add_meet_admin() (security definer).

-- ---------------------------------------------------------------------------
-- add_meet_admin / remove_meet_admin
-- ---------------------------------------------------------------------------

create or replace function public.add_meet_admin(
  p_meet_id uuid,
  p_email text,
  p_name text default null,
  p_role text default 'admin'
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_email text := lower(trim(coalesce(p_email, '')));
  v_admin public.meet_admins%rowtype;
  v_code text;
begin
  if not public.meet_auth_ok(p_meet_id) then
    raise exception 'NOT_ALLOWED';
  end if;
  if v_email = '' or position('@' in v_email) = 0 then
    raise exception 'EMAIL_REQUIRED';
  end if;
  if p_role not in ('owner', 'admin') then
    raise exception 'BAD_ROLE';
  end if;
  if exists (select 1 from meet_admins a where a.meet_id = p_meet_id and a.email = v_email) then
    raise exception 'ADMIN_EXISTS';
  end if;

  v_code := public.gen_code('public.meet_admins'::regclass, 'code');

  insert into meet_admins (meet_id, email, name, code, role)
    values (p_meet_id, v_email, nullif(trim(coalesce(p_name, '')), ''), v_code, p_role)
    returning * into v_admin;

  return jsonb_build_object(
    'id', v_admin.id, 'email', v_admin.email, 'name', v_admin.name,
    'role', v_admin.role, 'code', v_admin.code
  );
end;
$$;

create or replace function public.remove_meet_admin(p_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_admin public.meet_admins%rowtype;
begin
  select * into v_admin from meet_admins where id = p_id;
  if not found then
    raise exception 'ADMIN_NOT_FOUND';
  end if;
  if not public.meet_auth_ok(v_admin.meet_id) then
    raise exception 'NOT_ALLOWED';
  end if;
  if v_admin.role = 'owner' then
    raise exception 'OWNER_IMMUTABLE';
  end if;
  delete from meet_admins where id = p_id;
end;
$$;

-- Delegated admins count as meet authority inside the RPCs too.
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
    or public.meet_auth_ok((select meet_id from races where id = p_race_id))
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
    or public.meet_auth_ok(v_race.meet_id)
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
grant execute on function public.add_meet_admin(uuid, text, text, text) to anon;
grant execute on function public.remove_meet_admin(uuid) to anon;
grant execute on function public.finalize_race(uuid) to anon;
grant execute on function public.meet_auth_ok(uuid) to anon;
