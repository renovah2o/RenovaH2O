alter table public.profiles
  add column service_address jsonb,
  add constraint profiles_service_address_valid check (
    service_address is null or jsonb_typeof(service_address) = 'object'
  );

create function public.checkout_place_order_with_profile(
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
    or (v_province = 'Panamá' and v_district = 'Panamá')
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
