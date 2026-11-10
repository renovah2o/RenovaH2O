-- Preserve the complete birthday date, including the year.
-- The previous implementation forced every birthday to year 2000.

create or replace function public.enforce_profile_birthday_change_limit()
returns trigger
language plpgsql
set search_path = ''
as $$
declare
  v_role text := coalesce(auth.jwt() ->> 'role', '');
  v_same_day_month boolean;
begin
  if v_role = 'service_role' or (select public.is_agenda_admin()) then
    if new.birthday is distinct from old.birthday then
      new.birthday_last_changed_at := now();
    end if;
    return new;
  end if;

  if new.birthday is not distinct from old.birthday then
    return new;
  end if;

  v_same_day_month := old.birthday is not null
    and new.birthday is not null
    and extract(month from old.birthday) = extract(month from new.birthday)
    and extract(day from old.birthday) = extract(day from new.birthday);

  if v_same_day_month then
    -- A year-only correction is handled by an administrator; keep the
    -- customer's once-per-12-month self-service restriction unchanged.
    new.birthday := old.birthday;
    new.birthday_last_changed_at := old.birthday_last_changed_at;
    return new;
  end if;

  if old.birthday is not null
     and old.birthday_last_changed_at is not null
     and old.birthday_last_changed_at > now() - interval '1 year' then
    raise exception using
      errcode = 'P0001',
      message = 'El cumpleaños solo puede modificarse una vez cada 12 meses. Contacta a soporte si necesitas corregirlo antes.';
  end if;

  new.birthday_last_changed_at := now();
  return new;
end;
$$;

create or replace function public.checkout_admin_set_customer_birthday(
  p_customer_id uuid,
  p_birthday_manual date,
  p_birthday_source text
)
returns date
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_selected_birthday date;
begin
  if not (select public.is_agenda_admin()) then
    raise exception 'Solo un administrador puede modificar los cumpleaños.';
  end if;

  if p_birthday_source not in ('manual', 'google', 'facebook') then
    raise exception 'La fuente de cumpleaños no es válida.';
  end if;

  select case p_birthday_source
    when 'manual' then p_birthday_manual
    when 'google' then profile.birthday_google
    when 'facebook' then profile.birthday_facebook
  end
  into v_selected_birthday
  from public.profiles as profile
  where profile.id = p_customer_id
  for update;

  if not found then
    raise exception 'No se encontró el perfil del cliente.';
  end if;

  if v_selected_birthday is null then
    raise exception 'La fuente seleccionada no tiene una fecha disponible. Registra la fecha manual o sincroniza el proveedor.';
  end if;

  update public.profiles
  set birthday_manual = p_birthday_manual,
      birthday_source = p_birthday_source,
      birthday = v_selected_birthday
  where id = p_customer_id
    and not exists (
      select 1
      from public.agenda_admins as admin
      where admin.user_id = p_customer_id
    );

  if not found then
    raise exception 'No se encontró un cliente editable.';
  end if;

  return v_selected_birthday;
end;
$$;

revoke all on function public.checkout_admin_set_customer_birthday(uuid, date, text) from public, anon;
grant execute on function public.checkout_admin_set_customer_birthday(uuid, date, text) to authenticated;
