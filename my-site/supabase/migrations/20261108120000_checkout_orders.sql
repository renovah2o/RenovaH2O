create table public.checkout_products (
  sku text primary key,
  name text not null check (char_length(name) between 1 and 160),
  category text not null check (category in ('alquileres', 'residencial')),
  product_kind text not null check (product_kind in ('machine', 'accessory', 'area')),
  unit_amount integer not null check (unit_amount >= 0),
  min_quantity integer not null check (min_quantity > 0),
  max_quantity integer not null check (max_quantity >= min_quantity),
  pricing_mode text not null default 'unit' check (pricing_mode in ('unit', 'residential_promo')),
  included_quantity integer,
  additional_unit_amount integer,
  sale_ends_on date,
  sort_order smallint not null default 0,
  active boolean not null default true,
  constraint checkout_products_promo_valid check (
    (pricing_mode = 'unit' and included_quantity is null and additional_unit_amount is null)
    or (
      pricing_mode = 'residential_promo'
      and category = 'residencial'
      and product_kind = 'area'
      and included_quantity is not null
      and additional_unit_amount is not null
    )
  )
);

alter table public.checkout_products enable row level security;
revoke all on public.checkout_products from anon, authenticated;
grant select on public.checkout_products to anon, authenticated;

create policy "Active checkout products are publicly readable"
  on public.checkout_products for select
  to anon, authenticated
  using (
    active
    and (
      sale_ends_on is null
      or sale_ends_on >= (now() at time zone 'America/Panama')::date
    )
  );

insert into public.checkout_products (
  sku, name, category, product_kind, unit_amount, min_quantity, max_quantity,
  pricing_mode, included_quantity, additional_unit_amount, sale_ends_on, sort_order
)
values
  ('rental-35', 'Hidrolavadora 4000 PSI · 3.5 GPM (hasta 24 horas)', 'alquileres', 'machine', 5000, 1, 25, 'unit', null, null, null, 10),
  ('rental-23', 'Hidrolavadora 2700 PSI · 2.3 GPM (hasta 24 horas)', 'alquileres', 'machine', 4000, 1, 25, 'unit', null, null, null, 20),
  ('rental-surface-cleaner', 'Disco de hidrolavado de 20 pulgadas', 'alquileres', 'accessory', 5000, 1, 25, 'unit', null, null, null, 30),
  ('rental-turbo-nozzle', 'Turbo nozzle', 'alquileres', 'accessory', 1000, 1, 25, 'unit', null, null, null, 40),
  ('rental-broom', 'Broom de 24 pulgadas', 'alquileres', 'accessory', 3000, 1, 25, 'unit', null, null, null, 50),
  ('rental-extra-hose', 'Manguera adicional de 50 pies', 'alquileres', 'accessory', 3000, 1, 25, 'unit', null, null, null, 60),
  ('residential-holiday-promo', 'Promoción navideña de hidrolavado residencial', 'residencial', 'area', 7425, 10, 64, 'residential_promo', 50, 150, date '2026-12-31', 10),
  ('residential-65-100', 'Hidrolavado residencial · 65 a 100 m²', 'residencial', 'area', 200, 65, 100, 'unit', null, null, null, 20),
  ('residential-115-500', 'Hidrolavado residencial · 115 a 500 m²', 'residencial', 'area', 175, 115, 500, 'unit', null, null, null, 30)
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

alter table public.orders
  add column service_type text,
  add column service_address text,
  add column contact_phone text,
  add column payment_confirmed_by uuid references auth.users (id) on delete set null,
  add column payment_confirmed_at timestamptz,
  add column adjustment_amount integer not null default 0,
  add column adjustment_note text,
  add constraint orders_service_type_valid check (
    service_type is null
    or service_type in ('residencial_am', 'residencial_pm', 'alquileres')
  ),
  add constraint orders_service_address_length check (
    service_address is null or char_length(service_address) between 5 and 500
  ),
  add constraint orders_contact_phone_length check (
    contact_phone is null or char_length(contact_phone) between 7 and 32
  ),
  add constraint orders_adjustment_note_length check (
    adjustment_note is null or char_length(adjustment_note) <= 500
  );

alter table public.agenda_reservations
  drop constraint agenda_reservations_status_check,
  drop constraint agenda_reservations_no_overlap,
  add column order_id uuid references public.orders (id) on delete set null,
  add column hold_expires_at timestamptz,
  add constraint agenda_reservations_status_valid
    check (status in ('pending', 'confirmed', 'cancelled')),
  add constraint agenda_reservations_hold_valid
    check (status <> 'pending' or (order_id is not null and hold_expires_at is not null)),
  add constraint agenda_reservations_order_id_unique unique (order_id),
  add constraint agenda_reservations_no_overlap
    exclude using gist ((tstzrange(starts_at, ends_at, '[)')) with &&)
    where (status = 'confirmed');

create index agenda_reservations_pending_hold_idx
  on public.agenda_reservations (hold_expires_at)
  where status = 'pending';

create table public.account_notifications (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users (id) on delete cascade,
  order_id uuid references public.orders (id) on delete set null,
  title text not null check (char_length(title) between 1 and 120),
  message text not null check (char_length(message) between 1 and 500),
  created_at timestamptz not null default now(),
  read_at timestamptz
);

create index account_notifications_user_created_at_idx
  on public.account_notifications (user_id, created_at desc);

alter table public.account_notifications enable row level security;
revoke all on public.account_notifications from anon, authenticated;
grant select on public.account_notifications to authenticated;
grant update (read_at) on public.account_notifications to authenticated;

create policy "Users can read their own notifications"
  on public.account_notifications for select
  to authenticated
  using ((select auth.uid()) = user_id);

create policy "Users can mark their own notifications as read"
  on public.account_notifications for update
  to authenticated
  using ((select auth.uid()) = user_id)
  with check ((select auth.uid()) = user_id);

create function public.checkout_release_expired_holds()
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  with expired_reservations as (
    update public.agenda_reservations
      set status = 'cancelled'
      where status = 'pending'
        and hold_expires_at <= now()
      returning order_id
  ),
  expired_orders as (
    update public.orders as customer_order
      set status = 'cancelled'
      from expired_reservations as reservation
      where customer_order.id = reservation.order_id
        and customer_order.status = 'pending'
      returning customer_order.id, customer_order.user_id
  )
  insert into public.account_notifications (user_id, order_id, title, message)
  select
    expired_orders.user_id,
    expired_orders.id,
    'Retención vencida',
    'La retención de una hora terminó sin confirmación del pago y liberamos el horario. Si todavía deseas reservarlo, crea una nueva orden.'
  from expired_orders
  where expired_orders.user_id is not null;
end;
$$;

revoke all on function public.checkout_release_expired_holds() from public, anon, authenticated;
grant execute on function public.checkout_release_expired_holds() to authenticated;

create function public.checkout_guard_reservation_overlap()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  perform pg_advisory_xact_lock(718205031);
  perform public.checkout_release_expired_holds();

  if new.status in ('pending', 'confirmed')
    and exists (
      select 1
      from public.agenda_reservations as reservation
      where reservation.id is distinct from new.id
        and (
          reservation.status = 'confirmed'
          or (
            reservation.status = 'pending'
            and reservation.hold_expires_at > now()
          )
        )
        and tstzrange(reservation.starts_at, reservation.ends_at, '[)')
          && tstzrange(new.starts_at, new.ends_at, '[)')
    )
  then
    raise exception 'Ese horario acaba de dejar de estar disponible. Selecciona otra fecha u hora.';
  end if;

  return new;
end;
$$;

revoke all on function public.checkout_guard_reservation_overlap() from public, anon, authenticated;

create trigger checkout_guard_reservation_insert
  before insert on public.agenda_reservations
  for each row execute function public.checkout_guard_reservation_overlap();

create trigger checkout_guard_reservation_reschedule
  before update of starts_at, ends_at on public.agenda_reservations
  for each row execute function public.checkout_guard_reservation_overlap();

create function public.checkout_available_slots(
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

  if p_service_type not in ('residencial_am', 'residencial_pm', 'alquileres')
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

  if not found or not v_hours.is_open or v_rule.starts_at is null then
    return;
  end if;

  if v_rule.starts_at < v_hours.opens_at then
    return;
  end if;

  if p_service_type <> 'alquileres'
    and v_rule.starts_at + make_interval(mins => v_rule.duration_minutes) > v_hours.closes_at
  then
    return;
  end if;

  v_starts_at := (p_service_date + v_rule.starts_at) at time zone 'America/Panama';
  v_ends_at := v_starts_at + make_interval(mins => v_rule.duration_minutes);

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

create function public.checkout_place_order(
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

  if p_service_type not in ('residencial_am', 'residencial_pm', 'alquileres')
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

  if not found or not v_hours.is_open or v_rule.starts_at is null then
    raise exception 'Ese día no hay disponibilidad para el servicio seleccionado.';
  end if;

  if p_service_date < (now() at time zone 'America/Panama')::date then
    raise exception 'Selecciona una fecha futura.';
  end if;

  if v_rule.starts_at < v_hours.opens_at then
    raise exception 'La hora elegida queda fuera del horario de atención.';
  end if;

  if p_service_type <> 'alquileres'
    and v_rule.starts_at + make_interval(mins => v_rule.duration_minutes) > v_hours.closes_at
  then
    raise exception 'Ese horario no está disponible para el servicio seleccionado.';
  end if;

  v_expected_start := (p_service_date + v_rule.starts_at) at time zone 'America/Panama';
  v_ends_at := v_expected_start + make_interval(mins => v_rule.duration_minutes);

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

  if v_category = 'residencial'
    and (v_residential_count <> 1 or p_service_type not in ('residencial_am', 'residencial_pm'))
  then
    raise exception 'Selecciona un solo paquete residencial y un horario AM o PM.';
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

create function public.checkout_admin_list_orders()
returns table (
  order_id uuid,
  user_email text,
  customer_name text,
  contact_phone text,
  service_address text,
  service_type text,
  total_amount integer,
  currency text,
  status text,
  adjustment_amount integer,
  adjustment_note text,
  created_at timestamptz,
  hold_expires_at timestamptz,
  starts_at timestamptz,
  ends_at timestamptz,
  items jsonb
)
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  if not (select public.is_agenda_admin()) then
    raise exception 'Solo un administrador puede consultar las órdenes.';
  end if;

  return query
    select
      customer_order.id,
      customer.email::text,
      profile.full_name,
      customer_order.contact_phone,
      customer_order.service_address,
      customer_order.service_type,
      customer_order.total_amount,
      customer_order.currency,
      customer_order.status,
      customer_order.adjustment_amount,
      customer_order.adjustment_note,
      customer_order.created_at,
      reservation.hold_expires_at,
      reservation.starts_at,
      reservation.ends_at,
      coalesce((
        select jsonb_agg(
          jsonb_build_object(
            'product_name', item.product_name,
            'quantity', item.quantity,
            'unit_amount', item.unit_amount
          )
          order by item.product_name
        )
        from public.order_items as item
        where item.order_id = customer_order.id
      ), '[]'::jsonb)
    from public.orders as customer_order
    left join auth.users as customer on customer.id = customer_order.user_id
    left join public.profiles as profile on profile.id = customer_order.user_id
    left join public.agenda_reservations as reservation on reservation.order_id = customer_order.id
    order by customer_order.created_at desc
    limit 100;
end;
$$;

revoke all on function public.checkout_admin_list_orders() from public, anon;
grant execute on function public.checkout_admin_list_orders() to authenticated;

create function public.checkout_admin_set_order_status(
  p_order_id uuid,
  p_status text
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_order public.orders%rowtype;
  v_reservation public.agenda_reservations%rowtype;
  v_message text;
begin
  if not (select public.is_agenda_admin()) then
    raise exception 'Solo un administrador puede actualizar el estado de una orden.';
  end if;

  if p_status not in ('paid', 'cancelled') then
    raise exception 'El estado solicitado no es válido.';
  end if;

  perform pg_advisory_xact_lock(718205031);
  perform public.checkout_release_expired_holds();

  select *
    into v_order
    from public.orders
    where id = p_order_id
    for update;

  if not found or v_order.status <> 'pending' then
    raise exception 'La orden no está pendiente de confirmación.';
  end if;

  select *
    into v_reservation
    from public.agenda_reservations
    where order_id = p_order_id
    for update;

  if not found or v_reservation.status <> 'pending' then
    raise exception 'La retención de esta orden venció o ya no está activa. Confirma la disponibilidad antes de continuar.';
  end if;

  if p_status = 'paid' then
    if v_reservation.hold_expires_at <= now() then
      raise exception 'La retención de una hora venció. El cliente debe crear otra orden para volver a confirmar disponibilidad.';
    end if;

    if exists (
      select 1
      from public.agenda_reservations as other_reservation
      where other_reservation.id <> v_reservation.id
        and (
          other_reservation.status = 'confirmed'
          or (
            other_reservation.status = 'pending'
            and other_reservation.hold_expires_at > now()
          )
        )
        and tstzrange(other_reservation.starts_at, other_reservation.ends_at, '[)')
          && tstzrange(v_reservation.starts_at, v_reservation.ends_at, '[)')
    ) then
      raise exception 'El horario ya no está disponible. No se puede confirmar este pago para esa fecha.';
    end if;

    update public.agenda_reservations
      set status = 'confirmed', hold_expires_at = null
      where id = v_reservation.id;
    v_message := 'Un agente confirmó el pago. Tu fecha ya está confirmada en Mi agenda.';
  else
    update public.agenda_reservations
      set status = 'cancelled'
      where id = v_reservation.id;
    v_message := 'La orden fue cancelada y el horario quedó liberado. Contacta a RenovaH2O si necesitas ayuda.';
  end if;

  update public.orders
    set
      status = p_status,
      payment_confirmed_by = case when p_status = 'paid' then (select auth.uid()) else payment_confirmed_by end,
      payment_confirmed_at = case when p_status = 'paid' then now() else payment_confirmed_at end
    where id = p_order_id;

  if v_order.user_id is not null then
    insert into public.account_notifications (user_id, order_id, title, message)
    values (
      v_order.user_id,
      p_order_id,
      case when p_status = 'paid' then 'Pago confirmado' else 'Orden cancelada' end,
      v_message
    );
  end if;
end;
$$;

revoke all on function public.checkout_admin_set_order_status(uuid, text) from public, anon;
grant execute on function public.checkout_admin_set_order_status(uuid, text) to authenticated;

create function public.checkout_admin_record_adjustment(
  p_order_id uuid,
  p_adjustment_amount integer,
  p_message text
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_order public.orders%rowtype;
  v_amount_label text;
  v_title text;
  v_message text;
begin
  if not (select public.is_agenda_admin()) then
    raise exception 'Solo un administrador puede actualizar el ajuste de una orden.';
  end if;

  if p_adjustment_amount is null
    or p_adjustment_amount not between -100000000 and 100000000
    or p_message is null
    or char_length(trim(p_message)) not between 1 and 350
  then
    raise exception 'Escribe un ajuste válido y un mensaje para el cliente.';
  end if;

  select *
    into v_order
    from public.orders
    where id = p_order_id
    for update;

  if not found or v_order.status <> 'paid' then
    raise exception 'Solo se pueden registrar ajustes en órdenes pagadas.';
  end if;

  if v_order.total_amount::bigint + p_adjustment_amount < 0 then
    raise exception 'La devolución no puede superar el total original de la orden.';
  end if;

  update public.orders
    set adjustment_amount = p_adjustment_amount,
        adjustment_note = trim(p_message)
    where id = p_order_id;

  v_amount_label := '$' || to_char(abs(p_adjustment_amount)::numeric / 100, 'FM999999990.00');
  if p_adjustment_amount > 0 then
    v_title := 'Saldo adicional pendiente';
    v_message := 'Saldo adicional: ' || v_amount_label || '. ' || trim(p_message)
      || ' El pago se coordina manualmente con RenovaH2O.';
  elsif p_adjustment_amount < 0 then
    v_title := 'Devolución pendiente';
    v_message := 'Devolución por coordinar: ' || v_amount_label || '. ' || trim(p_message)
      || ' Un agente coordinará contigo la devolución manualmente.';
  else
    v_title := 'Medición revisada';
    v_message := 'No hay saldo adicional ni devolución. ' || trim(p_message);
  end if;

  insert into public.account_notifications (user_id, order_id, title, message)
  values (v_order.user_id, p_order_id, v_title, v_message);
end;
$$;

revoke all on function public.checkout_admin_record_adjustment(uuid, integer, text) from public, anon;
grant execute on function public.checkout_admin_record_adjustment(uuid, integer, text) to authenticated;
