-- Add San Miguelito to the service-address districts supported by checkout.
-- The old profile RPC is retained for compatibility with older clients.
create or replace function public.checkout_place_order_with_profile(
  p_items jsonb,
  p_service_type text,
  p_service_date date,
  p_start_at timestamptz,
  p_contact_phone text,
  p_profile_address jsonb,
  p_save_profile_address boolean
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_user_id uuid := (select auth.uid());
  v_order_id uuid;
  v_address text;
  v_province text;
  v_district text;
  v_corregimiento text;
  v_neighborhood text;
  v_street text;
  v_reference text;
begin
  if v_user_id is null then
    raise exception 'Inicia sesión antes de crear una orden.';
  end if;

  if p_profile_address is null
    or jsonb_typeof(p_profile_address) is distinct from 'object'
    or p_save_profile_address is null
  then
    raise exception 'Selecciona o completa una dirección válida.';
  end if;

  v_province := trim(coalesce(p_profile_address ->> 'province', ''));
  v_district := trim(coalesce(p_profile_address ->> 'district', ''));
  v_corregimiento := trim(coalesce(p_profile_address ->> 'corregimiento', ''));
  v_neighborhood := trim(coalesce(p_profile_address ->> 'neighborhood', ''));
  v_street := trim(coalesce(p_profile_address ->> 'street', ''));
  v_reference := trim(coalesce(p_profile_address ->> 'reference', ''));

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
    or (v_province = 'Panamá' and v_district in ('Panamá', 'San Miguelito'))
  ) then
    raise exception 'La provincia y el distrito seleccionados no coinciden.';
  end if;

  v_address := concat_ws(
    E'\n',
    'Provincia: ' || v_province,
    'Distrito: ' || v_district,
    'Corregimiento: ' || v_corregimiento,
    'Vecindario: ' || v_neighborhood,
    'Calle y casa/apartamento: ' || v_street,
    case when v_reference <> '' then 'Referencia: ' || v_reference end
  );

  if char_length(v_address) > 500 then
    raise exception 'La dirección es demasiado larga.';
  end if;

  select public.checkout_place_order(
    p_items,
    p_service_type,
    p_service_date,
    p_start_at,
    v_address,
    p_contact_phone,
    true
  )
  into v_order_id;

  if p_save_profile_address then
    update public.profiles
      set service_address = p_profile_address
      where id = v_user_id;

    if not found then
      raise exception 'No encontramos tu perfil para guardar la dirección.';
    end if;
  end if;

  return v_order_id;
end;
$$;

revoke all on function public.checkout_place_order_with_profile(
  jsonb, text, date, timestamptz, text, jsonb, boolean
) from public, anon;
grant execute on function public.checkout_place_order_with_profile(
  jsonb, text, date, timestamptz, text, jsonb, boolean
) to authenticated;

-- Current checkout RPC: validate all nine San Miguelito corregimientos.
create or replace function public.checkout_place_order_with_contacts(
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
    or (v_province = 'Panamá' and v_district in ('Panamá', 'San Miguelito'))
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
    or (v_district = 'San Miguelito' and v_corregimiento = any(array[
      'Amelia Denis de Icaza', 'Arnulfo Arias', 'Belisario Frías',
      'Belisario Porras', 'José Domingo Espinar', 'Mateo Iturralde',
      'Omar Torrijos', 'Rufina Alfaro', 'Victoriano Lorenzo'
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
