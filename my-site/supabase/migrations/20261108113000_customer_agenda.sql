create table public.agenda_admins (
  user_id uuid primary key references auth.users (id) on delete cascade,
  created_at timestamptz not null default now()
);

alter table public.agenda_admins enable row level security;
revoke all on public.agenda_admins from anon, authenticated;

create function public.is_agenda_admin()
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1
    from public.agenda_admins
    where user_id = (select auth.uid())
  );
$$;

revoke all on function public.is_agenda_admin() from public, anon;
grant execute on function public.is_agenda_admin() to authenticated;

create table public.agenda_weekly_hours (
  day_of_week smallint primary key check (day_of_week between 0 and 6),
  is_open boolean not null,
  opens_at time,
  closes_at time,
  constraint agenda_weekly_hours_valid check (
    (is_open and opens_at is not null and closes_at is not null and opens_at < closes_at)
    or (not is_open and opens_at is null and closes_at is null)
  )
);

alter table public.agenda_weekly_hours enable row level security;
revoke all on public.agenda_weekly_hours from anon, authenticated;
grant select, update on public.agenda_weekly_hours to authenticated;

create policy "Authenticated users can view weekly agenda hours"
  on public.agenda_weekly_hours for select
  to authenticated
  using (true);

create policy "Agenda admins can update weekly agenda hours"
  on public.agenda_weekly_hours for update
  to authenticated
  using ((select public.is_agenda_admin()))
  with check ((select public.is_agenda_admin()));

insert into public.agenda_weekly_hours (day_of_week, is_open, opens_at, closes_at)
values
  (0, true,  time '07:00', time '17:00'),
  (1, true,  time '07:00', time '17:00'),
  (2, true,  time '07:00', time '17:00'),
  (3, true,  time '07:00', time '17:00'),
  (4, true,  time '07:00', time '17:00'),
  (5, true,  time '07:00', time '12:00'),
  (6, false, null, null);

create function public.agenda_save_weekly_hours(p_hours jsonb)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_count integer;
  v_distinct_count integer;
  v_existing_count integer;
begin
  if not (select public.is_agenda_admin()) then
    raise exception 'Solo un administrador puede cambiar el horario semanal.';
  end if;

  if p_hours is null or jsonb_typeof(p_hours) <> 'array' or jsonb_array_length(p_hours) <> 7 then
    raise exception 'Se requiere el horario completo de los siete días.';
  end if;

  select count(*), count(distinct requested.day_of_week), count(weekly.day_of_week)
    into v_count, v_distinct_count, v_existing_count
    from jsonb_to_recordset(p_hours) as requested(
      day_of_week smallint, is_open boolean, opens_at time, closes_at time
    )
    left join public.agenda_weekly_hours as weekly
      on weekly.day_of_week = requested.day_of_week;

  if v_count <> 7 or v_distinct_count <> 7 or v_existing_count <> 7 then
    raise exception 'El horario contiene días inválidos o repetidos.';
  end if;

  if exists (
    select 1
    from jsonb_to_recordset(p_hours) as requested(
      day_of_week smallint, is_open boolean, opens_at time, closes_at time
    )
    where requested.is_open is null
      or (
        requested.is_open
        and (
          requested.opens_at is null
          or requested.closes_at is null
          or requested.opens_at >= requested.closes_at
        )
      )
      or (
        not requested.is_open
        and (requested.opens_at is not null or requested.closes_at is not null)
      )
  ) then
    raise exception 'Revisa las horas de apertura y cierre.';
  end if;

  update public.agenda_weekly_hours as weekly
    set
      is_open = requested.is_open,
      opens_at = requested.opens_at,
      closes_at = requested.closes_at
    from jsonb_to_recordset(p_hours) as requested(
      day_of_week smallint, is_open boolean, opens_at time, closes_at time
    )
    where weekly.day_of_week = requested.day_of_week;
end;
$$;

revoke all on function public.agenda_save_weekly_hours(jsonb) from public, anon;
grant execute on function public.agenda_save_weekly_hours(jsonb) to authenticated;

create table public.agenda_service_rules (
  service_type text primary key check (
    service_type in ('residencial_am', 'residencial_pm', 'comercial', 'alquileres')
  ),
  display_name text not null check (char_length(display_name) between 1 and 80),
  starts_at time,
  duration_minutes integer not null check (duration_minutes between 15 and 2880),
  uses_full_business_day boolean not null default false,
  constraint agenda_service_rule_start_valid check (
    (uses_full_business_day and starts_at is null)
    or (not uses_full_business_day and starts_at is not null)
  )
);

alter table public.agenda_service_rules enable row level security;
revoke all on public.agenda_service_rules from anon, authenticated;
grant select, update on public.agenda_service_rules to authenticated;

create policy "Authenticated users can view agenda service rules"
  on public.agenda_service_rules for select
  to authenticated
  using (true);

create policy "Agenda admins can update service rules"
  on public.agenda_service_rules for update
  to authenticated
  using ((select public.is_agenda_admin()))
  with check ((select public.is_agenda_admin()));

insert into public.agenda_service_rules (
  service_type, display_name, starts_at, duration_minutes, uses_full_business_day
)
values
  ('residencial_am', 'Residencial · AM', time '07:00', 300, false),
  ('residencial_pm', 'Residencial · PM', time '12:00', 300, false),
  ('comercial', 'Comercial · día completo', null, 600, true),
  ('alquileres', 'Alquiler · 24 horas', time '07:00', 1440, false);

create function public.agenda_save_service_rules(p_rules jsonb)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_count integer;
  v_distinct_count integer;
  v_existing_count integer;
begin
  if not (select public.is_agenda_admin()) then
    raise exception 'Solo un administrador puede cambiar las reglas de servicio.';
  end if;

  if p_rules is null or jsonb_typeof(p_rules) <> 'array' or jsonb_array_length(p_rules) <> 4 then
    raise exception 'Se requieren las reglas de los cuatro tipos de servicio.';
  end if;

  select count(*), count(distinct requested.service_type), count(rule.service_type)
    into v_count, v_distinct_count, v_existing_count
    from jsonb_to_recordset(p_rules) as requested(
      service_type text, starts_at time, duration_minutes integer
    )
    left join public.agenda_service_rules as rule
      on rule.service_type = requested.service_type;

  if v_count <> 4 or v_distinct_count <> 4 or v_existing_count <> 4 then
    raise exception 'Las reglas contienen tipos inválidos o repetidos.';
  end if;

  if exists (
    select 1
    from jsonb_to_recordset(p_rules) as requested(
      service_type text, starts_at time, duration_minutes integer
    )
    join public.agenda_service_rules as rule
      on rule.service_type = requested.service_type
    where requested.duration_minutes is null
      or requested.duration_minutes not between 15 and 2880
      or (rule.uses_full_business_day and requested.starts_at is not null)
      or (not rule.uses_full_business_day and requested.starts_at is null)
  ) then
    raise exception 'Revisa las horas iniciales y duraciones de los servicios.';
  end if;

  update public.agenda_service_rules as rule
    set
      starts_at = requested.starts_at,
      duration_minutes = requested.duration_minutes
    from jsonb_to_recordset(p_rules) as requested(
      service_type text, starts_at time, duration_minutes integer
    )
    where rule.service_type = requested.service_type;
end;
$$;

revoke all on function public.agenda_save_service_rules(jsonb) from public, anon;
grant execute on function public.agenda_save_service_rules(jsonb) to authenticated;

create table public.agenda_reservations (
  id uuid primary key default gen_random_uuid(),
  kind text not null check (kind in ('service', 'block')),
  user_id uuid references auth.users (id) on delete cascade,
  service_type text references public.agenda_service_rules (service_type),
  starts_at timestamptz not null,
  ends_at timestamptz not null,
  status text not null default 'confirmed' check (status in ('confirmed', 'cancelled')),
  created_by uuid not null references auth.users (id),
  created_at timestamptz not null default now(),
  constraint agenda_reservations_valid check (
    ends_at > starts_at
    and (
      (kind = 'service' and user_id is not null and service_type is not null)
      or (kind = 'block' and user_id is null and service_type is null)
    )
  ),
  constraint agenda_reservations_no_overlap
    exclude using gist ((tstzrange(starts_at, ends_at, '[)')) with &&)
    where (status = 'confirmed')
);

create index agenda_reservations_user_starts_at_idx
  on public.agenda_reservations (user_id, starts_at);

create index agenda_reservations_starts_at_idx
  on public.agenda_reservations (starts_at)
  where status = 'confirmed';

alter table public.agenda_reservations enable row level security;
revoke all on public.agenda_reservations from anon, authenticated;
grant select (id, kind, user_id, service_type, starts_at, ends_at, status, created_at)
  on public.agenda_reservations to authenticated;
grant update (starts_at, ends_at, status)
  on public.agenda_reservations to authenticated;

create policy "Customers can view their own service reservations"
  on public.agenda_reservations for select
  to authenticated
  using (
    (kind = 'service' and user_id = (select auth.uid()))
    or (select public.is_agenda_admin())
  );

create policy "Agenda admins can update reservations"
  on public.agenda_reservations for update
  to authenticated
  using ((select public.is_agenda_admin()))
  with check ((select public.is_agenda_admin()));

create function public.agenda_create_reservation(
  p_customer_email text,
  p_service_type text,
  p_starts_at timestamptz,
  p_ends_at timestamptz
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_user_id uuid;
  v_reservation_id uuid;
begin
  if not (select public.is_agenda_admin()) then
    raise exception 'Solo un administrador puede crear reservas.';
  end if;

  if p_ends_at <= p_starts_at then
    raise exception 'La hora final debe ser posterior a la hora inicial.';
  end if;

  if not exists (
    select 1
    from public.agenda_service_rules
    where service_type = p_service_type
  ) then
    raise exception 'El tipo de servicio no es válido.';
  end if;

  select id
    into v_user_id
    from auth.users
    where lower(email) = lower(trim(p_customer_email))
    limit 1;

  if v_user_id is null then
    raise exception 'No encontramos una cuenta registrada con ese correo.';
  end if;

  insert into public.agenda_reservations (
    kind, user_id, service_type, starts_at, ends_at, created_by
  )
  values (
    'service', v_user_id, p_service_type, p_starts_at, p_ends_at, (select auth.uid())
  )
  returning id into v_reservation_id;

  return v_reservation_id;
end;
$$;

revoke all on function public.agenda_create_reservation(text, text, timestamptz, timestamptz)
  from public, anon;
grant execute on function public.agenda_create_reservation(text, text, timestamptz, timestamptz)
  to authenticated;

create function public.agenda_create_block(
  p_starts_at timestamptz,
  p_ends_at timestamptz
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_reservation_id uuid;
begin
  if not (select public.is_agenda_admin()) then
    raise exception 'Solo un administrador puede bloquear horarios.';
  end if;

  if p_ends_at <= p_starts_at then
    raise exception 'La hora final debe ser posterior a la hora inicial.';
  end if;

  insert into public.agenda_reservations (
    kind, starts_at, ends_at, created_by
  )
  values (
    'block', p_starts_at, p_ends_at, (select auth.uid())
  )
  returning id into v_reservation_id;

  return v_reservation_id;
end;
$$;

revoke all on function public.agenda_create_block(timestamptz, timestamptz)
  from public, anon;
grant execute on function public.agenda_create_block(timestamptz, timestamptz)
  to authenticated;

create function public.agenda_list_admin_reservations()
returns table (
  id uuid,
  kind text,
  customer_email text,
  customer_name text,
  service_type text,
  starts_at timestamptz,
  ends_at timestamptz,
  status text
)
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  if not (select public.is_agenda_admin()) then
    raise exception 'Solo un administrador puede consultar todas las reservas.';
  end if;

  return query
    select
      reservation.id,
      reservation.kind,
      customer.email::text,
      profile.full_name,
      reservation.service_type,
      reservation.starts_at,
      reservation.ends_at,
      reservation.status
    from public.agenda_reservations as reservation
    left join auth.users as customer on customer.id = reservation.user_id
    left join public.profiles as profile on profile.id = reservation.user_id
    order by reservation.starts_at
    limit 250;
end;
$$;

revoke all on function public.agenda_list_admin_reservations() from public, anon;
grant execute on function public.agenda_list_admin_reservations() to authenticated;
