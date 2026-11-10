alter table public.profiles
  add column if not exists birthday_manual date,
  add column if not exists birthday_google date,
  add column if not exists birthday_facebook date,
  add column if not exists birthday_source text not null default 'manual';

update public.profiles
set birthday_manual = birthday
where birthday_manual is null and birthday is not null;

alter table public.profiles drop constraint if exists profiles_birthday_source_check;
alter table public.profiles add constraint profiles_birthday_source_check
  check (birthday_source in ('manual', 'google', 'facebook'));

create or replace function public.enforce_profile_birthday_change_limit()
returns trigger language plpgsql set search_path = ''
as $$
declare
  v_role text := coalesce(auth.jwt() ->> 'role', '');
  v_same_day_month boolean;
begin
  if v_role = 'service_role' or (select public.is_agenda_admin()) then
    if new.birthday is not null then
      new.birthday := make_date(2000, extract(month from new.birthday)::integer, extract(day from new.birthday)::integer);
    end if;
    if new.birthday is distinct from old.birthday then new.birthday_last_changed_at := now(); end if;
    return new;
  end if;
  if new.birthday is not distinct from old.birthday then return new; end if;
  v_same_day_month := old.birthday is not null and new.birthday is not null
    and extract(month from old.birthday) = extract(month from new.birthday)
    and extract(day from old.birthday) = extract(day from new.birthday);
  if v_same_day_month then
    new.birthday := old.birthday;
    new.birthday_last_changed_at := old.birthday_last_changed_at;
    return new;
  end if;
  if old.birthday is not null and old.birthday_last_changed_at is not null
     and old.birthday_last_changed_at > now() - interval '1 year' then
    raise exception using errcode = 'P0001',
      message = 'El cumpleaños solo puede modificarse una vez cada 12 meses. Contacta a soporte si necesitas corregirlo antes.';
  end if;
  if new.birthday is not null then
    new.birthday := make_date(2000, extract(month from new.birthday)::integer, extract(day from new.birthday)::integer);
  end if;
  new.birthday_last_changed_at := now();
  return new;
end;
$$;

drop function if exists public.checkout_admin_list_customers(text, integer);
create function public.checkout_admin_list_customers(p_search text default null, p_limit integer default 100)
returns table (
  customer_id uuid, email text, full_name text, phone text, birthday date, preferred_services text[],
  order_count bigint, paid_order_count bigint, last_order_at timestamptz,
  birthday_manual date, birthday_google date, birthday_facebook date, birthday_source text
)
language plpgsql stable security definer set search_path = ''
as $$
begin
  if not (select public.is_agenda_admin()) then raise exception 'Solo un administrador puede consultar los clientes.'; end if;
  return query
    with order_summary as (
      select customer_order.user_id, count(*)::bigint as total_orders,
        count(*) filter (where customer_order.status = 'paid')::bigint as total_paid_orders,
        max(customer_order.created_at) as latest_order_at
      from public.orders as customer_order where customer_order.user_id is not null group by customer_order.user_id
    )
    select customer.id, customer.email::text, profile.full_name, profile.phone, profile.birthday,
      coalesce(profile.preferred_services, array[]::text[]), coalesce(order_summary.total_orders, 0),
      coalesce(order_summary.total_paid_orders, 0), order_summary.latest_order_at,
      profile.birthday_manual, profile.birthday_google, profile.birthday_facebook, profile.birthday_source
    from auth.users as customer
    left join public.profiles as profile on profile.id = customer.id
    left join order_summary on order_summary.user_id = customer.id
    where not exists (select 1 from public.agenda_admins as admin where admin.user_id = customer.id)
      and (nullif(trim(coalesce(p_search, '')), '') is null or position(
        lower(trim(p_search)) in lower(concat_ws(' ', customer.email, profile.full_name, profile.phone))
      ) > 0)
    order by order_summary.latest_order_at desc nulls last, profile.full_name, customer.email
    limit least(greatest(coalesce(p_limit, 100), 1), 100);
end;
$$;
revoke all on function public.checkout_admin_list_customers(text, integer) from public, anon;
grant execute on function public.checkout_admin_list_customers(text, integer) to authenticated;

create or replace function public.checkout_admin_set_customer_birthday(
  p_customer_id uuid, p_birthday_manual date, p_birthday_source text
)
returns date language plpgsql security definer set search_path = ''
as $$
declare v_selected_birthday date;
begin
  if not (select public.is_agenda_admin()) then raise exception 'Solo un administrador puede modificar los cumpleaños.'; end if;
  if p_birthday_source not in ('manual', 'google', 'facebook') then raise exception 'La fuente de cumpleaños no es válida.'; end if;
  select case p_birthday_source when 'manual' then p_birthday_manual
    when 'google' then profile.birthday_google when 'facebook' then profile.birthday_facebook end
  into v_selected_birthday from public.profiles as profile where profile.id = p_customer_id for update;
  if not found then raise exception 'No se encontró el perfil del cliente.'; end if;
  if v_selected_birthday is null then
    raise exception 'La fuente seleccionada no tiene una fecha disponible. Registra la fecha manual o sincroniza el proveedor.';
  end if;
  v_selected_birthday := make_date(2000, extract(month from v_selected_birthday)::integer, extract(day from v_selected_birthday)::integer);
  update public.profiles
  set birthday_manual = case when p_birthday_manual is null then null else make_date(2000, extract(month from p_birthday_manual)::integer, extract(day from p_birthday_manual)::integer) end,
      birthday_source = p_birthday_source, birthday = v_selected_birthday
  where id = p_customer_id
    and not exists (select 1 from public.agenda_admins as admin where admin.user_id = p_customer_id);
  if not found then raise exception 'No se encontró un cliente editable.'; end if;
  return v_selected_birthday;
end;
$$;
revoke all on function public.checkout_admin_set_customer_birthday(uuid, date, text) from public, anon;
grant execute on function public.checkout_admin_set_customer_birthday(uuid, date, text) to authenticated;
