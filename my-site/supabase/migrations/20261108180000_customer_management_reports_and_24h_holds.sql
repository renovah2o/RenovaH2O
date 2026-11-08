update public.checkout_products
set name = 'Promoción navideña de hidrolavado residencial',
    unit_amount = 7425,
    min_quantity = 1,
    max_quantity = 1,
    pricing_mode = 'residential_promo',
    included_quantity = 50,
    additional_unit_amount = 0,
    sale_ends_on = date '2026-12-31',
    active = true
where sku = 'residential-holiday-promo';

create function public.checkout_label_fixed_residential_promo()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if new.product_name = 'Promoción navideña de hidrolavado residencial · 1 m²' then
    new.product_name := 'Promoción navideña de hidrolavado residencial · hasta 50 m²';
  end if;
  return new;
end;
$$;

revoke all on function public.checkout_label_fixed_residential_promo() from public, anon, authenticated;

create trigger checkout_label_fixed_residential_promo
  before insert on public.order_items
  for each row execute function public.checkout_label_fixed_residential_promo();

create function public.checkout_set_24_hour_hold()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if new.kind = 'service'
    and new.order_id is not null
    and new.status = 'pending'
  then
    new.hold_expires_at := now() + interval '24 hours';
  end if;
  return new;
end;
$$;

revoke all on function public.checkout_set_24_hour_hold() from public, anon, authenticated;

create trigger checkout_set_24_hour_hold
  before insert or update of hold_expires_at on public.agenda_reservations
  for each row execute function public.checkout_set_24_hour_hold();

update public.agenda_reservations
set hold_expires_at = now() + interval '24 hours'
where status = 'pending'
  and order_id is not null
  and hold_expires_at > now();

create function public.checkout_update_hold_notification_copy()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if new.order_id is not null and new.title in ('Orden recibida', 'Retención vencida') then
    new.message := replace(new.message, 'una hora', '24 horas');
  end if;
  return new;
end;
$$;

revoke all on function public.checkout_update_hold_notification_copy() from public, anon, authenticated;

create trigger checkout_update_hold_notification_copy
  before insert on public.account_notifications
  for each row execute function public.checkout_update_hold_notification_copy();

update public.account_notifications as notification
set message = replace(notification.message, 'una hora', '24 horas')
where notification.title in ('Orden recibida', 'Retención vencida')
  and notification.message like '%una hora%'
  and exists (
    select 1
    from public.orders as customer_order
    where customer_order.id = notification.order_id
      and customer_order.status = 'pending'
  );

create or replace function public.checkout_admin_set_order_status(
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

  if p_status is null or p_status not in ('paid', 'cancelled') then
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
    raise exception 'La retención venció o ya no está activa. Confirma la disponibilidad antes de continuar.';
  end if;

  if p_status = 'paid' then
    if v_reservation.hold_expires_at <= now() then
      raise exception 'La retención de 24 horas venció. El cliente debe crear otra orden para volver a confirmar disponibilidad.';
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

create function public.checkout_admin_list_customers(
  p_search text default null,
  p_limit integer default 100
)
returns table (
  customer_id uuid,
  email text,
  full_name text,
  phone text,
  birthday date,
  preferred_services text[],
  order_count bigint,
  paid_order_count bigint,
  last_order_at timestamptz
)
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  if not (select public.is_agenda_admin()) then
    raise exception 'Solo un administrador puede consultar los clientes.';
  end if;

  return query
    with order_summary as (
      select
        customer_order.user_id,
        count(*)::bigint as total_orders,
        count(*) filter (where customer_order.status = 'paid')::bigint as total_paid_orders,
        max(customer_order.created_at) as latest_order_at
      from public.orders as customer_order
      where customer_order.user_id is not null
      group by customer_order.user_id
    )
    select
      customer.id,
      customer.email::text,
      profile.full_name,
      profile.phone,
      profile.birthday,
      coalesce(profile.preferred_services, array[]::text[]),
      coalesce(order_summary.total_orders, 0),
      coalesce(order_summary.total_paid_orders, 0),
      order_summary.latest_order_at
    from auth.users as customer
    left join public.profiles as profile on profile.id = customer.id
    left join order_summary on order_summary.user_id = customer.id
    where not exists (
        select 1
        from public.agenda_admins as admin
        where admin.user_id = customer.id
      )
      and (
        nullif(trim(coalesce(p_search, '')), '') is null
        or position(
          lower(trim(p_search)) in lower(concat_ws(' ', customer.email, profile.full_name, profile.phone))
        ) > 0
      )
    order by order_summary.latest_order_at desc nulls last, profile.full_name, customer.email
    limit least(greatest(coalesce(p_limit, 100), 1), 100);
end;
$$;

revoke all on function public.checkout_admin_list_customers(text, integer) from public, anon;
grant execute on function public.checkout_admin_list_customers(text, integer) to authenticated;

create function public.checkout_admin_customer_metrics()
returns table (
  total_customers bigint,
  customers_with_paid_orders bigint,
  repeat_customers bigint,
  inactive_customers_90d bigint,
  customers_without_paid_orders bigint
)
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  if not (select public.is_agenda_admin()) then
    raise exception 'Solo un administrador puede consultar los informes.';
  end if;

  return query
    with order_summary as (
      select
        customer_order.user_id,
        count(*) filter (where customer_order.status = 'paid')::bigint as paid_orders,
        max(customer_order.created_at) filter (where customer_order.status = 'paid') as last_paid_at
      from public.orders as customer_order
      where customer_order.user_id is not null
      group by customer_order.user_id
    )
    select
      count(*)::bigint,
      count(*) filter (where coalesce(order_summary.paid_orders, 0) > 0)::bigint,
      count(*) filter (where coalesce(order_summary.paid_orders, 0) > 1)::bigint,
      count(*) filter (
        where order_summary.last_paid_at < now() - interval '90 days'
      )::bigint,
      count(*) filter (where coalesce(order_summary.paid_orders, 0) = 0)::bigint
    from auth.users as customer
    left join order_summary on order_summary.user_id = customer.id
    where not exists (
      select 1
      from public.agenda_admins as admin
      where admin.user_id = customer.id
    );
end;
$$;

revoke all on function public.checkout_admin_customer_metrics() from public, anon;
grant execute on function public.checkout_admin_customer_metrics() to authenticated;

create function public.checkout_admin_upcoming_birthdays()
returns table (
  customer_id uuid,
  full_name text,
  email text,
  phone text,
  birthday date,
  upcoming_birthday date
)
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_today date := (now() at time zone 'America/Panama')::date;
  v_year integer := extract(year from (now() at time zone 'America/Panama'))::integer;
  v_month integer := extract(month from (now() at time zone 'America/Panama'))::integer;
  v_next_month date := (date_trunc('month', v_today::timestamp) + interval '1 month')::date;
begin
  if not (select public.is_agenda_admin()) then
    raise exception 'Solo un administrador puede consultar los cumpleaños.';
  end if;

  return query
    with birthday_dates as (
      select
        profile.id,
        profile.full_name,
        customer.email::text as email,
        profile.phone,
        profile.birthday,
        make_date(
          v_year,
          v_month,
          least(
            extract(day from profile.birthday)::integer,
            extract(day from (v_next_month - 1))::integer
          )
        ) as upcoming_birthday
      from public.profiles as profile
      join auth.users as customer on customer.id = profile.id
      where profile.birthday is not null
        and extract(month from profile.birthday)::integer = v_month
        and not exists (
          select 1
          from public.agenda_admins as admin
          where admin.user_id = customer.id
        )
    )
    select
      birthday_dates.id,
      birthday_dates.full_name,
      birthday_dates.email,
      birthday_dates.phone,
      birthday_dates.birthday,
      birthday_dates.upcoming_birthday
    from birthday_dates
    where birthday_dates.upcoming_birthday >= v_today
      and birthday_dates.upcoming_birthday < v_next_month
    order by birthday_dates.upcoming_birthday, birthday_dates.full_name;
end;
$$;

revoke all on function public.checkout_admin_upcoming_birthdays() from public, anon;
grant execute on function public.checkout_admin_upcoming_birthdays() to authenticated;
