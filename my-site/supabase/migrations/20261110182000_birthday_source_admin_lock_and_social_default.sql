alter table public.profiles
  add column if not exists birthday_source_admin_locked boolean not null default false;

-- Preserve previously selected social sources as administrator choices.
update public.profiles
set birthday_source_admin_locked = true
where birthday_source in ('google', 'facebook')
  and birthday_source_admin_locked = false;

create or replace function public.apply_social_birthday_default()
returns trigger
language plpgsql
set search_path = ''
as $$
declare
  v_provider text := coalesce(auth.jwt() -> 'app_metadata' ->> 'provider', '');
begin
  if coalesce(new.birthday_source_admin_locked, false) then
    return new;
  end if;

  if v_provider = 'google' and new.birthday_google is not null then
    new.birthday_source := 'google';
    new.birthday := make_date(
      2000,
      extract(month from new.birthday_google)::integer,
      extract(day from new.birthday_google)::integer
    );
  elsif v_provider = 'facebook' and new.birthday_facebook is not null then
    new.birthday_source := 'facebook';
    new.birthday := make_date(
      2000,
      extract(month from new.birthday_facebook)::integer,
      extract(day from new.birthday_facebook)::integer
    );
  end if;

  return new;
end;
$$;

drop trigger if exists profiles_apply_social_birthday_default on public.profiles;
create trigger profiles_apply_social_birthday_default
before update of birthday_google, birthday_facebook on public.profiles
for each row
execute function public.apply_social_birthday_default();

create or replace function public.checkout_admin_set_customer_birthday(
  p_customer_id uuid, p_birthday_manual date, p_birthday_source text
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

  v_selected_birthday := make_date(
    2000,
    extract(month from v_selected_birthday)::integer,
    extract(day from v_selected_birthday)::integer
  );

  update public.profiles
  set birthday_manual = case
        when p_birthday_manual is null then null
        else make_date(
          2000,
          extract(month from p_birthday_manual)::integer,
          extract(day from p_birthday_manual)::integer
        )
      end,
      birthday_source = p_birthday_source,
      birthday = v_selected_birthday,
      birthday_source_admin_locked = true
  where id = p_customer_id
    and not exists (
      select 1 from public.agenda_admins as admin
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
