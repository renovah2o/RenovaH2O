-- Paquetes comerciales comprables y reservas de jornada completa.
-- Esta migración amplía el catálogo y conserva las reglas de alquiler y residencial existentes.

alter table public.checkout_products
  drop constraint if exists checkout_products_category_check;
alter table public.checkout_products
  add constraint checkout_products_category_check
  check (category in ('alquileres', 'residencial', 'comercial'));

alter table public.orders
  drop constraint if exists orders_service_type_valid;
alter table public.orders
  add constraint orders_service_type_valid
  check (
    service_type is null
    or service_type in ('residencial_am', 'residencial_pm', 'comercial', 'alquileres')
  );

insert into public.checkout_products (
  sku, name, category, product_kind, unit_amount, min_quantity, max_quantity,
  pricing_mode, included_quantity, additional_unit_amount, sale_ends_on, sort_order
)
values
  ('commercial-115-500', 'Servicio de Hidrolavado Comercial · 115 a 500 m²', 'comercial', 'area', 175, 115, 500, 'unit', null, null, null, 40),
  ('commercial-600-1000', 'Servicio de Hidrolavado Comercial · 600 a 1,000 m²', 'comercial', 'area', 150, 600, 1000, 'unit', null, null, null, 50),
  ('commercial-1250-5000', 'Servicio de Hidrolavado Comercial · 1,250 a 5,000 m²', 'comercial', 'area', 125, 1250, 5000, 'unit', null, null, null, 60)
on conflict (sku) do update
set
  name = excluded.name,
  category = excluded.category,
  product_kind = excluded.product_kind,
  unit_amount = excluded.unit_amount,
  min_quantity = excluded.min_quantity,
  max_quantity = excluded.max_quantity,
  pricing_mode = excluded.pricing_mode,
  included_quantity = excluded.included_quantity,
  additional_unit_amount = excluded.additional_unit_amount,
  sale_ends_on = excluded.sale_ends_on,
  sort_order = excluded.sort_order,
  active = true;

create or replace function public.checkout_available_slots(
  p_service_type text,
  p_service_date date
)
returns table (
  starts_at timestamptz,
  ends_at timestamptz,
  label text
)
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_rule public.agenda_service_rules%rowtype;
  v_hours public.agenda_weekly_hours%rowtype;
  v_starts_at timestamptz;
  v_ends_at timestamptz;
begin
  if (select auth.uid()) is null then
    raise exception 'Inicia sesión para consultar la disponibilidad.';
  end if;

  if p_service_type not in ('residencial_am', 'residencial_pm', 'comercial', 'alquileres')
    or p_service_date is null
  then
    raise exception 'Selecciona un servicio y una fecha válidos.';
  end if;

  perform public.checkout_release_expired_holds();

  select *
    into v_rule
    from public.agenda_service_rules
    where service_type = p_service_type;

  select *
    into v_hours
    from public.agenda_weekly_hours
    where day_of_week = extract(dow from p_service_date)::smallint;

  if not found or not v_hours.is_open then
    return;
  end if;

  if v_rule.uses_full_business_day then
    v_starts_at := (p_service_date + v_hours.opens_at) at time zone 'America/Panama';
    v_ends_at := (p_service_date + v_hours.closes_at) at time zone 'America/Panama';
  else
    if v_rule.starts_at is null or v_rule.starts_at < v_hours.opens_at then
      return;
    end if;

    if p_service_type <> 'alquileres'
      and v_rule.starts_at + make_interval(mins => v_rule.duration_minutes) > v_hours.closes_at
    then
      return;
    end if;

    v_starts_at := (p_service_date + v_rule.starts_at) at time zone 'America/Panama';
    v_ends_at := v_starts_at + make_interval(mins => v_rule.duration_minutes);
  end if;

  return query
    select v_starts_at, v_ends_at, v_rule.display_name
    where not exists (
      select 1
      from public.agenda_reservations as reservation
      where (
        reservation.status = 'confirmed'
        or (
          reservation.status = 'pending'
          and reservation.hold_expires_at > now()
        )
      )
        and tstzrange(reservation.starts_at, reservation.ends_at, '[)')
          && tstzrange(v_starts_at, v_ends_at, '[)')
    );
end;
$$;

revoke all on function public.checkout_available_slots(text, date) from public, anon;
grant execute on function public.checkout_available_slots(text, date) to authenticated;

create or replace function public.checkout_place_order(
  p_items jsonb,
  p_service_type text,
  p_service_date date,
  p_start_at timestamptz,
  p_service_address text,
  p_contact_phone text,
  p_confirm_contact boolean
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_user_id uuid := (select auth.uid());
  v_line record;
  v_product public.checkout_products%rowtype;
  v_category text;
  v_machine_count integer := 0;
  v_residential_count integer := 0;
  v_total integer := 0;
  v_line_total integer;
  v_line_name text;
  v_order_id uuid;
  v_rule public.agenda_service_rules%rowtype;
  v_hours public.agenda_weekly_hours%rowtype;
  v_expected_start timestamptz;
  v_ends_at timestamptz;
begin
  if v_user_id is null then
    raise exception 'Inicia sesión antes de crear una orden.';
  end if;

  if p_items is null
    or jsonb_typeof(p_items) <> 'array'
    or jsonb_array_length(p_items) = 0
    or jsonb_array_length(p_items) > 20
  then
    raise exception 'El carrito está vacío o contiene demasiados productos.';
  end if;

  if p_service_address is null or char_length(trim(p_service_address)) not between 5 and 500 then
    raise exception 'Escribe una dirección válida para coordinar el servicio o la entrega.';
  end if;

  if p_contact_phone is null or char_length(trim(p_contact_phone)) not between 7 and 32 then
    raise exception 'Escribe un teléfono de contacto válido.';
  end if;

  if p_confirm_contact is distinct from true then
    raise exception 'Confirma que el teléfono es correcto y que podemos guardarlo en tu perfil.';
  end if;

  if p_service_type not in ('residencial_am', 'residencial_pm', 'comercial', 'alquileres')
    or p_service_date is null
    or p_start_at is null
  then
    raise exception 'Selecciona una fecha y un horario disponibles.';
  end if;

  if exists (
    select 1
    from jsonb_to_recordset(p_items) as submitted(sku text, quantity integer)
    where submitted.sku is null
      or submitted.quantity is null
      or submitted.quantity <= 0
  ) or (
    select count(*) <> count(distinct submitted.sku)
    from jsonb_to_recordset(p_items) as submitted(sku text, quantity integer)
  ) then
    raise exception 'El carrito contiene productos o cantidades inválidas.';
  end if;

  perform pg_advisory_xact_lock(718205031);
  perform public.checkout_release_expired_holds();

  select *
    into v_rule
    from public.agenda_service_rules
    where service_type = p_service_type;

  select *
    into v_hours
    from public.agenda_weekly_hours
    where day_of_week = extract(dow from p_service_date)::smallint;

  if not found or not v_hours.is_open then
    raise exception 'Ese día no hay disponibilidad para el servicio seleccionado.';
  end if;

  if p_service_date < (now() at time zone 'America/Panama')::date then
    raise exception 'Selecciona una fecha futura.';
  end if;

  if v_rule.uses_full_business_day then
    v_expected_start := (p_service_date + v_hours.opens_at) at time zone 'America/Panama';
    v_ends_at := (p_service_date + v_hours.closes_at) at time zone 'America/Panama';
  else
    if v_rule.starts_at is null or v_rule.starts_at < v_hours.opens_at then
      raise exception 'La hora elegida queda fuera del horario de atención.';
    end if;

    if p_service_type <> 'alquileres'
      and v_rule.starts_at + make_interval(mins => v_rule.duration_minutes) > v_hours.closes_at
    then
      raise exception 'Ese horario no está disponible para el servicio seleccionado.';
    end if;

    v_expected_start := (p_service_date + v_rule.starts_at) at time zone 'America/Panama';
    v_ends_at := v_expected_start + make_interval(mins => v_rule.duration_minutes);
  end if;

  if p_start_at <> v_expected_start then
    raise exception 'La fecha u hora cambió. Vuelve a consultar la disponibilidad.';
  end if;

  if exists (
    select 1
    from public.agenda_reservations as reservation
    where (
      reservation.status = 'confirmed'
      or (
        reservation.status = 'pending'
        and reservation.hold_expires_at > now()
      )
    )
      and tstzrange(reservation.starts_at, reservation.ends_at, '[)')
        && tstzrange(v_expected_start, v_ends_at, '[)')
  ) then
    raise exception 'Ese horario acaba de dejar de estar disponible. Selecciona otra fecha u hora.';
  end if;

  for v_line in
    select submitted.sku, submitted.quantity
    from jsonb_to_recordset(p_items) as submitted(sku text, quantity integer)
  loop
    select *
      into v_product
      from public.checkout_products
      where sku = v_line.sku
        and active
        and (sale_ends_on is null or sale_ends_on >= (now() at time zone 'America/Panama')::date);

    if not found then
      raise exception 'El producto "%" ya no está disponible.', v_line.sku;
    end if;

    if v_line.quantity not between v_product.min_quantity and v_product.max_quantity then
      raise exception 'La cantidad de "%" debe estar entre % y %.',
        v_product.name, v_product.min_quantity, v_product.max_quantity;
    end if;

    if v_category is null then
      v_category := v_product.category;
    elsif v_category <> v_product.category then
      raise exception 'Un pedido debe contener solo productos de alquiler o solo productos residenciales.';
    end if;

    if v_product.product_kind = 'machine' then
      v_machine_count := v_machine_count + v_line.quantity;
    elsif v_product.product_kind = 'area' then
      v_residential_count := v_residential_count + 1;
    end if;

    if v_product.pricing_mode = 'residential_promo' then
      v_line_total := v_product.unit_amount
        + greatest(v_line.quantity - v_product.included_quantity, 0) * v_product.additional_unit_amount;
      v_line_name := v_product.name || ' · ' || v_line.quantity::text || ' m²';
    else
      v_line_total := v_product.unit_amount * v_line.quantity;
      v_line_name := v_product.name;
      if v_product.product_kind = 'area' then
        v_line_name := v_product.name || ' · ' || v_line.quantity::text || ' m²';
      end if;
    end if;

    v_total := v_total + v_line_total;
  end loop;

  if v_category = 'alquileres' and v_machine_count = 0 then
    raise exception 'Agrega al menos una hidrolavadora para alquilar accesorios.';
  end if;

  if v_machine_count > 2 then
    raise exception 'Solo hay 2 hidrolavadoras disponibles para alquiler por orden.';
  end if;

  if v_category = 'residencial'
    and (v_residential_count <> 1 or p_service_type not in ('residencial_am', 'residencial_pm'))
  then
    raise exception 'Selecciona un solo paquete residencial y un horario AM o PM.';
  end if;

  if v_category = 'comercial'
    and (v_residential_count <> 1 or p_service_type <> 'comercial')
  then
    raise exception 'Selecciona un solo paquete comercial y una jornada completa.';
  end if;

  if v_category = 'alquileres' and p_service_type <> 'alquileres' then
    raise exception 'Los pedidos de alquiler requieren una reserva de 24 horas.';
  end if;

  if v_category is null then
    raise exception 'El carrito está vacío.';
  end if;

  if v_category = 'alquileres' then
    v_total := v_total + 25000 * v_machine_count;
  end if;

  insert into public.orders (
    user_id, status, total_amount, currency, service_type, service_address, contact_phone
  )
  values (
    v_user_id, 'pending', v_total, 'USD', p_service_type,
    trim(p_service_address), trim(p_contact_phone)
  )
  returning id into v_order_id;

  for v_line in
    select submitted.sku, submitted.quantity
    from jsonb_to_recordset(p_items) as submitted(sku text, quantity integer)
  loop
    select *
      into v_product
      from public.checkout_products
      where sku = v_line.sku;

    if v_product.pricing_mode = 'residential_promo' then
      v_line_total := v_product.unit_amount
        + greatest(v_line.quantity - v_product.included_quantity, 0) * v_product.additional_unit_amount;
      v_line_name := v_product.name || ' · ' || v_line.quantity::text || ' m²';
      insert into public.order_items (order_id, product_name, quantity, unit_amount)
      values (v_order_id, v_line_name, 1, v_line_total);
    else
      v_line_total := v_product.unit_amount;
      v_line_name := v_product.name;
      if v_product.product_kind = 'area' then
        v_line_name := v_product.name || ' · ' || v_line.quantity::text || ' m²';
      end if;
      insert into public.order_items (order_id, product_name, quantity, unit_amount)
      values (v_order_id, v_line_name, v_line.quantity, v_line_total);
    end if;
  end loop;

  if v_category = 'alquileres' then
    insert into public.order_items (order_id, product_name, quantity, unit_amount)
    values (
      v_order_id,
      'Depósito de garantía reembolsable · por hidrolavadora',
      v_machine_count,
      25000
    );
  end if;

  insert into public.agenda_reservations (
    kind, user_id, service_type, starts_at, ends_at, status, created_by, order_id, hold_expires_at
  )
  values (
    'service', v_user_id, p_service_type, v_expected_start, v_ends_at,
    'pending', v_user_id, v_order_id, now() + interval '1 hour'
  );

  update public.profiles
    set phone = trim(p_contact_phone)
    where id = v_user_id;

  if not found then
    raise exception 'No encontramos tu perfil para guardar el teléfono de contacto.';
  end if;

  insert into public.account_notifications (user_id, order_id, title, message)
  values (
    v_user_id,
    v_order_id,
    'Orden recibida',
    'Recibimos tu orden. Contacta a RenovaH2O para coordinar el pago; la fecha se retiene por una hora y se confirmará en tu agenda cuando un agente valide el pago.'
  );

  insert into public.account_notifications (user_id, order_id, title, message)
  select
    admin.user_id,
    v_order_id,
    'Nueva orden por confirmar',
    'Un cliente creó una orden que requiere confirmación manual del pago.'
  from public.agenda_admins as admin;

  return v_order_id;
end;
$$;

revoke all on function public.checkout_place_order(jsonb, text, date, timestamptz, text, text, boolean)
  from public, anon;
grant execute on function public.checkout_place_order(jsonb, text, date, timestamptz, text, text, boolean)
  to authenticated;
