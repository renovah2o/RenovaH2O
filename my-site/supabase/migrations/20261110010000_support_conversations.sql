-- Conversaciones de atención al cliente de RenovaH2O.
-- Requiere las migraciones previas de agenda_admins, profiles y account_notifications.

-- La función de correo usa service_role para dirigir avisos a la bandeja administrativa.
grant select on public.agenda_admins to service_role;

create table public.support_conversations (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users (id) on delete cascade,
  subject text not null check (char_length(trim(subject)) between 4 and 120),
  category text not null check (category in ('cotizacion', 'servicio', 'orden', 'alquiler', 'pagos', 'otro')),
  status text not null default 'open' check (status in ('open', 'in_progress', 'closed')),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create index support_conversations_user_updated_idx
  on public.support_conversations (user_id, updated_at desc);
create index support_conversations_status_updated_idx
  on public.support_conversations (status, updated_at desc);

create table public.support_messages (
  id uuid primary key default gen_random_uuid(),
  conversation_id uuid not null references public.support_conversations (id) on delete cascade,
  sender_id uuid not null references auth.users (id) on delete cascade,
  sender_role text not null check (sender_role in ('customer', 'admin')),
  body text not null check (char_length(trim(body)) between 2 and 3000),
  created_at timestamptz not null default now()
);

create index support_messages_conversation_created_idx
  on public.support_messages (conversation_id, created_at asc);

alter table public.support_conversations enable row level security;
alter table public.support_messages enable row level security;

revoke all on public.support_conversations from anon, authenticated;
revoke all on public.support_messages from anon, authenticated;
grant select on public.support_conversations to authenticated;
grant select on public.support_messages to authenticated;

create policy "Customers and admins can read support conversations"
  on public.support_conversations for select
  to authenticated
  using (
    user_id = (select auth.uid())
    or (select public.is_agenda_admin())
  );

create policy "Customers and admins can read support messages"
  on public.support_messages for select
  to authenticated
  using (
    exists (
      select 1
      from public.support_conversations as conversation
      where conversation.id = support_messages.conversation_id
        and (
          conversation.user_id = (select auth.uid())
          or (select public.is_agenda_admin())
        )
    )
  );

create function public.support_create_conversation(
  p_subject text,
  p_category text,
  p_message text
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_user_id uuid := (select auth.uid());
  v_conversation_id uuid;
  v_subject text := trim(coalesce(p_subject, ''));
  v_message text := trim(coalesce(p_message, ''));
begin
  if v_user_id is null then
    raise exception 'Inicia sesión para enviar una consulta y conservar el historial en tu cuenta.';
  end if;

  if char_length(v_subject) not between 4 and 120 then
    raise exception 'Escribe un asunto de entre 4 y 120 caracteres.';
  end if;

  if p_category is null or p_category not in ('cotizacion', 'servicio', 'orden', 'alquiler', 'pagos', 'otro') then
    raise exception 'Selecciona una categoría válida.';
  end if;

  if char_length(v_message) not between 10 and 3000 then
    raise exception 'El mensaje debe tener entre 10 y 3,000 caracteres.';
  end if;

  insert into public.support_conversations (user_id, subject, category)
  values (v_user_id, v_subject, p_category)
  returning id into v_conversation_id;

  insert into public.support_messages (conversation_id, sender_id, sender_role, body)
  values (v_conversation_id, v_user_id, 'customer', v_message);

  insert into public.account_notifications (user_id, title, message)
  select admin.user_id, 'Nueva consulta de contacto',
    left(v_subject || ': ' || v_message, 490)
  from public.agenda_admins as admin;

  return v_conversation_id;
end;
$$;

revoke all on function public.support_create_conversation(text, text, text) from public, anon;
grant execute on function public.support_create_conversation(text, text, text) to authenticated;

create function public.support_send_message(
  p_conversation_id uuid,
  p_message text
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_user_id uuid := (select auth.uid());
  v_conversation public.support_conversations%rowtype;
  v_sender_role text;
  v_body text := trim(coalesce(p_message, ''));
  v_message_id uuid;
begin
  if v_user_id is null then
    raise exception 'Inicia sesión para responder esta consulta.';
  end if;

  if char_length(v_body) not between 2 and 3000 then
    raise exception 'El mensaje debe tener entre 2 y 3,000 caracteres.';
  end if;

  select *
    into v_conversation
    from public.support_conversations
    where id = p_conversation_id
    for update;

  if not found then
    raise exception 'No encontramos esta conversación.';
  end if;

  if v_conversation.user_id = v_user_id then
    v_sender_role := 'customer';
    if v_conversation.status = 'closed' then
      raise exception 'Esta consulta está cerrada. Crea una nueva consulta para continuar.';
    end if;
  elsif (select public.is_agenda_admin()) then
    v_sender_role := 'admin';
  else
    raise exception 'No tienes permiso para responder esta conversación.';
  end if;

  insert into public.support_messages (conversation_id, sender_id, sender_role, body)
  values (p_conversation_id, v_user_id, v_sender_role, v_body)
  returning id into v_message_id;

  update public.support_conversations
    set status = case
          when v_sender_role = 'admin' then 'in_progress'
          else 'open'
        end,
        updated_at = now()
    where id = p_conversation_id;

  if v_sender_role = 'admin' then
    insert into public.account_notifications (user_id, title, message)
    values (
      v_conversation.user_id,
      'Respuesta a tu consulta',
      left(v_body, 490)
    );
  else
    insert into public.account_notifications (user_id, title, message)
    select admin.user_id, 'Nueva respuesta de un cliente',
      left(v_conversation.subject || ': ' || v_body, 490)
    from public.agenda_admins as admin;
  end if;

  return v_message_id;
end;
$$;

revoke all on function public.support_send_message(uuid, text) from public, anon;
grant execute on function public.support_send_message(uuid, text) to authenticated;

create function public.support_admin_list_conversations(
  p_status text default null,
  p_search text default null
)
returns table (
  conversation_id uuid,
  user_id uuid,
  customer_name text,
  customer_email text,
  subject text,
  category text,
  status text,
  created_at timestamptz,
  updated_at timestamptz,
  last_message text,
  last_message_at timestamptz,
  last_sender_role text
)
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  if not (select public.is_agenda_admin()) then
    raise exception 'Solo un administrador puede consultar la bandeja de contacto.';
  end if;

  if p_status is not null and p_status not in ('open', 'in_progress', 'closed') then
    raise exception 'El filtro de estado no es válido.';
  end if;

  return query
    select
      conversation.id,
      conversation.user_id,
      coalesce(nullif(trim(profile.full_name), ''), nullif(split_part(customer.email, '@', 1), ''), 'Cliente')::text,
      customer.email::text,
      conversation.subject,
      conversation.category,
      conversation.status,
      conversation.created_at,
      conversation.updated_at,
      latest.body,
      latest.created_at,
      latest.sender_role
    from public.support_conversations as conversation
    left join public.profiles as profile on profile.id = conversation.user_id
    left join auth.users as customer on customer.id = conversation.user_id
    left join lateral (
      select message.body, message.created_at, message.sender_role
      from public.support_messages as message
      where message.conversation_id = conversation.id
      order by message.created_at desc
      limit 1
    ) as latest on true
    where (p_status is null or conversation.status = p_status)
      and (
        nullif(trim(p_search), '') is null
        or conversation.subject ilike '%' || trim(p_search) || '%'
        or coalesce(profile.full_name, '') ilike '%' || trim(p_search) || '%'
        or coalesce(customer.email, '') ilike '%' || trim(p_search) || '%'
      )
    order by conversation.updated_at desc
    limit 200;
end;
$$;

revoke all on function public.support_admin_list_conversations(text, text) from public, anon;
grant execute on function public.support_admin_list_conversations(text, text) to authenticated;

create function public.support_admin_set_status(
  p_conversation_id uuid,
  p_status text
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  if not (select public.is_agenda_admin()) then
    raise exception 'Solo un administrador puede actualizar el estado de una consulta.';
  end if;

  if p_status is null or p_status not in ('open', 'in_progress', 'closed') then
    raise exception 'El estado solicitado no es válido.';
  end if;

  update public.support_conversations
    set status = p_status, updated_at = now()
    where id = p_conversation_id;

  if not found then
    raise exception 'No encontramos esta conversación.';
  end if;
end;
$$;

revoke all on function public.support_admin_set_status(uuid, text) from public, anon;
grant execute on function public.support_admin_set_status(uuid, text) to authenticated;
