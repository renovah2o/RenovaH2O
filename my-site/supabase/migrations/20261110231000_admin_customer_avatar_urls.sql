drop function if exists public.checkout_admin_list_customers(text, integer);

create function public.checkout_admin_list_customers(p_search text default null, p_limit integer default 100)
returns table (
  customer_id uuid, email text, full_name text, phone text, birthday date, preferred_services text[],
  order_count bigint, paid_order_count bigint, last_order_at timestamptz,
  birthday_manual date, birthday_google date, birthday_facebook date, birthday_source text,
  avatar_url text
)
language plpgsql stable security definer set search_path = ''
as $$
begin
  if not (select public.is_agenda_admin()) then
    raise exception 'Solo un administrador puede consultar los clientes.';
  end if;

  return query
    with order_summary as (
      select customer_order.user_id, count(*)::bigint as total_orders,
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
      order_summary.latest_order_at,
      profile.birthday_manual,
      profile.birthday_google,
      profile.birthday_facebook,
      profile.birthday_source,
      coalesce(
        (
          select coalesce(
            nullif(social_identity.identity_data ->> 'picture', ''),
            nullif(social_identity.identity_data ->> 'avatar_url', ''),
            nullif(social_identity.identity_data #>> '{picture,data,url}', '')
          )
          from auth.identities as social_identity
          where social_identity.user_id = customer.id
          order by case social_identity.provider
            when 'google' then 0
            when 'facebook' then 1
            else 2
          end
          limit 1
        ),
        nullif(customer.raw_user_meta_data ->> 'picture', ''),
        nullif(customer.raw_user_meta_data ->> 'avatar_url', '')
      )::text
    from auth.users as customer
    left join public.profiles as profile on profile.id = customer.id
    left join order_summary on order_summary.user_id = customer.id
    where not exists (
      select 1 from public.agenda_admins as admin
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
