create schema if not exists private;
revoke all on schema private from public, anon, authenticated;

create or replace function private.enforce_order_rate_limit()
returns trigger
language plpgsql
security definer
set search_path = ''
as $function$
declare
  v_recent_count integer;
begin
  if (select auth.uid()) is null or new.user_id is distinct from (select auth.uid()) then
    return new;
  end if;

  perform pg_advisory_xact_lock(hashtextextended('renova-order:' || new.user_id::text, 0));

  select count(*)::integer into v_recent_count
  from public.orders
  where user_id = new.user_id
    and created_at > now() - interval '10 minutes';

  if v_recent_count >= 3 then
    raise exception 'Por seguridad, puedes crear un máximo de 3 órdenes cada 10 minutos. Inténtalo más tarde.'
      using errcode = 'P0001';
  end if;

  return new;
end;
$function$;

create or replace function private.enforce_support_conversation_rate_limit()
returns trigger
language plpgsql
security definer
set search_path = ''
as $function$
declare
  v_recent_count integer;
begin
  if (select auth.uid()) is null or new.user_id is distinct from (select auth.uid()) then
    return new;
  end if;

  perform pg_advisory_xact_lock(hashtextextended('renova-support-conversation:' || new.user_id::text, 0));

  select count(*)::integer into v_recent_count
  from public.support_conversations
  where user_id = new.user_id
    and created_at > now() - interval '1 hour';

  if v_recent_count >= 3 then
    raise exception 'Por seguridad, puedes abrir un máximo de 3 consultas por hora. Inténtalo más tarde.'
      using errcode = 'P0001';
  end if;

  return new;
end;
$function$;

create or replace function private.enforce_support_message_rate_limit()
returns trigger
language plpgsql
security definer
set search_path = ''
as $function$
declare
  v_recent_count integer;
begin
  if new.sender_role <> 'customer'
     or (select auth.uid()) is null
     or new.sender_id is distinct from (select auth.uid()) then
    return new;
  end if;

  perform pg_advisory_xact_lock(hashtextextended('renova-support-message:' || new.sender_id::text, 0));

  select count(*)::integer into v_recent_count
  from public.support_messages
  where sender_id = new.sender_id
    and sender_role = 'customer'
    and created_at > now() - interval '10 minutes';

  if v_recent_count >= 10 then
    raise exception 'Por seguridad, puedes enviar un máximo de 10 mensajes cada 10 minutos. Inténtalo más tarde.'
      using errcode = 'P0001';
  end if;

  return new;
end;
$function$;

revoke all on function private.enforce_order_rate_limit() from public, anon, authenticated;
revoke all on function private.enforce_support_conversation_rate_limit() from public, anon, authenticated;
revoke all on function private.enforce_support_message_rate_limit() from public, anon, authenticated;

drop trigger if exists renova_order_rate_limit on public.orders;
create trigger renova_order_rate_limit before insert on public.orders
for each row execute function private.enforce_order_rate_limit();

drop trigger if exists renova_support_conversation_rate_limit on public.support_conversations;
create trigger renova_support_conversation_rate_limit before insert on public.support_conversations
for each row execute function private.enforce_support_conversation_rate_limit();

drop trigger if exists renova_support_message_rate_limit on public.support_messages;
create trigger renova_support_message_rate_limit before insert on public.support_messages
for each row execute function private.enforce_support_message_rate_limit();
