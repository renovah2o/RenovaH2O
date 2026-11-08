create table public.profile_addresses (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users (id) on delete cascade,
  alias text not null check (char_length(trim(alias)) between 1 and 60),
  address jsonb not null check (jsonb_typeof(address) = 'object'),
  is_default boolean not null default false,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table public.profile_phones (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users (id) on delete cascade,
  alias text not null check (char_length(trim(alias)) between 1 and 60),
  phone text not null check (char_length(trim(phone)) between 7 and 32),
  is_default boolean not null default false,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create unique index profile_addresses_one_default_per_user
  on public.profile_addresses (user_id)
  where is_default;

create unique index profile_phones_one_default_per_user
  on public.profile_phones (user_id)
  where is_default;

create trigger profile_addresses_set_updated_at
  before update on public.profile_addresses
  for each row execute function public.set_updated_at();

create trigger profile_phones_set_updated_at
  before update on public.profile_phones
  for each row execute function public.set_updated_at();

create index profile_addresses_user_created_idx
  on public.profile_addresses (user_id, created_at);

create index profile_phones_user_created_idx
  on public.profile_phones (user_id, created_at);

alter table public.profile_addresses enable row level security;
alter table public.profile_phones enable row level security;
revoke all on public.profile_addresses, public.profile_phones from anon, authenticated;
grant select, insert, update, delete on public.profile_addresses, public.profile_phones to authenticated;
grant update (service_address) on public.profiles to authenticated;

create policy "Users manage their own addresses"
  on public.profile_addresses for all
  to authenticated
  using ((select auth.uid()) = user_id)
  with check ((select auth.uid()) = user_id);

create policy "Users manage their own phones"
  on public.profile_phones for all
  to authenticated
  using ((select auth.uid()) = user_id)
  with check ((select auth.uid()) = user_id);

create function public.profile_set_default_contact(
  p_contact_type text,
  p_contact_id uuid
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_user_id uuid := (select auth.uid());
begin
  if v_user_id is null or p_contact_id is null then
    raise exception 'Inicia sesión y selecciona un contacto válido.';
  end if;

  if p_contact_type = 'address' then
    update public.profile_addresses
      set is_default = false
      where user_id = v_user_id and is_default;
    update public.profile_addresses
      set is_default = true
      where id = p_contact_id and user_id = v_user_id;
    if not found then
      raise exception 'No encontramos esa dirección en tu perfil.';
    end if;
    update public.profiles
      set service_address = (
        select address from public.profile_addresses
        where id = p_contact_id and user_id = v_user_id
      )
      where id = v_user_id;
  elsif p_contact_type = 'phone' then
    update public.profile_phones
      set is_default = false
      where user_id = v_user_id and is_default;
    update public.profile_phones
      set is_default = true
      where id = p_contact_id and user_id = v_user_id;
    if not found then
      raise exception 'No encontramos ese teléfono en tu perfil.';
    end if;
    update public.profiles
      set phone = (
        select phone from public.profile_phones
        where id = p_contact_id and user_id = v_user_id
      )
      where id = v_user_id;
  else
    raise exception 'Tipo de contacto no válido.';
  end if;
end;
$$;

revoke all on function public.profile_set_default_contact(text, uuid) from public, anon;
grant execute on function public.profile_set_default_contact(text, uuid) to authenticated;

insert into public.profile_addresses (user_id, alias, address, is_default)
select id, 'Principal', service_address, true
from public.profiles
where service_address is not null
  and jsonb_typeof(service_address) = 'object'
on conflict do nothing;

insert into public.profile_phones (user_id, alias, phone, is_default)
select id, 'Principal', phone, true
from public.profiles
where phone is not null
  and char_length(trim(phone)) between 7 and 32
on conflict do nothing;

create function public.checkout_place_order_with_contacts(
  p_items jsonb,
  p_service_type text,
  p_service_date date,
  p_start_at timestamptz,
  p_address_id uuid,
  p_new_address jsonb,
  p_address_alias text,
  p_phone_id uuid,
  p_new_phone text,
  p_phone_alias text
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_user_id uuid := (select auth.uid());
  v_address_id uuid := p_address_id;
  v_phone_id uuid := p_phone_id;
  v_address jsonb;
  v_phone text;
  v_address_text text;
  v_province text;
  v_district text;
  v_corregimiento text;
  v_neighborhood text;
  v_street text;
  v_reference text;
  v_order_id uuid;
begin
  if v_user_id is null then
    raise exception 'Inicia sesión antes de crear una orden.';
  end if;

  if (p_address_id is null) = (p_new_address is null)
    or (p_phone_id is null) = (p_new_phone is null)
  then
    raise exception 'Selecciona una dirección y un teléfono guardados o agrega datos nuevos.';
  end if;

  if p_new_address is not null then
    if jsonb_typeof(p_new_address) is distinct from 'object'
      or p_address_alias is null
      or char_length(trim(p_address_alias)) not between 1 and 60
    then
      raise exception 'Ingresa un alias y una dirección válidos.';
    end if;

    insert into public.profile_addresses (user_id, alias, address, is_default)
    values (
      v_user_id,
      trim(p_address_alias),
      p_new_address,
      not exists (
        select 1 from public.profile_addresses where user_id = v_user_id and is_default
      )
    )
    returning id, address into v_address_id, v_address;
  else
    select id, address into v_address_id, v_address
    from public.profile_addresses
    where id = p_address_id and user_id = v_user_id;

    if not found then
      raise exception 'No encontramos esa dirección en tu perfil. Vuelve a cargar los datos.';
    end if;
  end if;

  if p_new_phone is not null then
    if char_length(trim(p_new_phone)) not between 7 and 32
      or p_phone_alias is null
      or char_length(trim(p_phone_alias)) not between 1 and 60
    then
      raise exception 'Ingresa un alias y un teléfono válidos.';
    end if;

    insert into public.profile_phones (user_id, alias, phone, is_default)
    values (
      v_user_id,
      trim(p_phone_alias),
      trim(p_new_phone),
      not exists (
        select 1 from public.profile_phones where user_id = v_user_id and is_default
      )
    )
    returning id, phone into v_phone_id, v_phone;
  else
    select id, phone into v_phone_id, v_phone
    from public.profile_phones
    where id = p_phone_id and user_id = v_user_id;

    if not found then
      raise exception 'No encontramos ese teléfono en tu perfil. Vuelve a cargar los datos.';
    end if;
  end if;

  v_province := trim(coalesce(v_address ->> 'province', ''));
  v_district := trim(coalesce(v_address ->> 'district', ''));
  v_corregimiento := trim(coalesce(v_address ->> 'corregimiento', ''));
  v_neighborhood := trim(coalesce(v_address ->> 'neighborhood', ''));
  v_street := trim(coalesce(v_address ->> 'street', ''));
  v_reference := trim(coalesce(v_address ->> 'reference', ''));

  if char_length(v_province) not between 1 and 40
    or char_length(v_district) not between 1 and 60
    or char_length(v_corregimiento) not between 1 and 80
    or char_length(v_neighborhood) not between 1 and 80
    or char_length(v_street) not between 1 and 100
    or char_length(v_reference) > 100
  then
    raise exception 'Completa todos los campos obligatorios de la dirección.';
  end if;

  if not (
    (v_province = 'Panamá Oeste' and v_district in ('Arraiján', 'La Chorrera'))
    or (v_province = 'Panamá' and v_district = 'Panamá')
  ) then
    raise exception 'La provincia y el distrito seleccionados no coinciden.';
  end if;

  if not (
    (v_district = 'Arraiján' and v_corregimiento = any(array[
      'Arraiján', 'Burunga', 'Cerro Silvestre', 'Juan Demóstenes Arosemena',
      'Nuevo Arraiján', 'Nuevo Emperador', 'San Vicente de Bique', 'Santa Clara',
      'Veracruz', 'Vista Alegre'
    ]))
    or (v_district = 'La Chorrera' and v_corregimiento = any(array[
      'Barrio Balboa', 'Barrio Colón', 'Amador', 'Arosemena', 'El Arado',
      'El Coco', 'Feuillet', 'Guadalupe', 'Herrera', 'Hurtado', 'Iturralde',
      'La Represa', 'Los Díaz', 'Mendoza', 'Obaldía', 'Playa Leona',
      'Puerto Caimito', 'Santa Rita'
    ]))
    or (v_district = 'Panamá' and v_corregimiento = any(array[
      'San Felipe', 'El Chorrillo', 'Santa Ana', 'Calidonia', 'Curundú',
      'Bella Vista', 'Betania', 'San Francisco', 'Pueblo Nuevo', 'Río Abajo',
      'Parque Lefevre', 'Juan Díaz', 'Don Bosco', 'Las Mañanitas', 'Tocumen',
      'Las Cumbres', 'Alcalde Díaz', 'Ernesto Córdoba Campos', 'Caimitillo',
      'Pedregal', 'Las Garzas', 'Pacora', '24 de Diciembre', 'Chilibre',
      'San Martín', 'Ancón'
    ]))
  ) then
    raise exception 'El corregimiento no corresponde al distrito seleccionado.';
  end if;

  v_address_text := concat_ws(
    E'\n',
    'Provincia: ' || v_province,
    'Distrito: ' || v_district,
    'Corregimiento: ' || v_corregimiento,
    'Vecindario: ' || v_neighborhood,
    'Calle y casa/apartamento: ' || v_street,
    case when v_reference <> '' then 'Referencia: ' || v_reference end
  );

  if char_length(v_address_text) > 500 then
    raise exception 'La dirección es demasiado larga.';
  end if;

  select public.checkout_place_order(
    p_items,
    p_service_type,
    p_service_date,
    p_start_at,
    v_address_text,
    v_phone,
    true
  )
  into v_order_id;

  update public.profiles
    set service_address = v_address,
        phone = v_phone
    where id = v_user_id;

  return v_order_id;
end;
$$;

revoke all on function public.checkout_place_order_with_contacts(
  jsonb, text, date, timestamptz, uuid, jsonb, text, uuid, text, text
) from public, anon;
grant execute on function public.checkout_place_order_with_contacts(
  jsonb, text, date, timestamptz, uuid, jsonb, text, uuid, text, text
) to authenticated;

create function public.agenda_list_admin_month(
  p_month_start date,
  p_month_end date
)
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
    raise exception 'Solo un administrador puede consultar el calendario.';
  end if;

  if p_month_start is null or p_month_end is null or p_month_end <= p_month_start then
    raise exception 'Selecciona un mes válido.';
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
    where reservation.starts_at < (p_month_end::timestamp at time zone 'America/Panama')
      and reservation.ends_at > (p_month_start::timestamp at time zone 'America/Panama')
      and reservation.status in ('pending', 'confirmed')
      and (reservation.status <> 'pending' or reservation.hold_expires_at > now())
    order by reservation.starts_at;
end;
$$;

revoke all on function public.agenda_list_admin_month(date, date) from public, anon;
grant execute on function public.agenda_list_admin_month(date, date) to authenticated;
