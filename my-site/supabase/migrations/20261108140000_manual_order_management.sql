-- Manual order management and auditable refunds. Additive migration.
create table if not exists public.order_refunds (
  id uuid primary key default gen_random_uuid(),
  order_id uuid not null references public.orders(id) on delete cascade,
  amount integer not null check (amount > 0),
  method text not null check (method in ('Yappy','Transferencia bancaria','Efectivo','Otro')),
  reason text not null check (char_length(trim(reason)) between 1 and 350),
  created_by uuid references auth.users(id) on delete set null,
  created_at timestamptz not null default now()
);
create index if not exists order_refunds_order_created_idx on public.order_refunds(order_id,created_at desc);
alter table public.order_refunds enable row level security;
revoke all on public.order_refunds from anon, authenticated;

create table if not exists public.order_status_history (
  id uuid primary key default gen_random_uuid(),
  order_id uuid not null references public.orders(id) on delete cascade,
  old_status text,
  new_status text not null,
  changed_by uuid references auth.users(id) on delete set null,
  note text,
  created_at timestamptz not null default now()
);
create index if not exists order_status_history_order_created_idx on public.order_status_history(order_id,created_at desc);

create or replace function public.capture_order_status_change()
returns trigger language plpgsql security definer set search_path=''
as $
begin
  if new.status is distinct from old.status then
    insert into public.order_status_history(order_id,old_status,new_status,changed_by,note)
    values(new.id,old.status,new.status,(select auth.uid()),null);
  end if;
  return new;
end;
$;
revoke all on function public.capture_order_status_change() from public,anon,authenticated;
create trigger capture_order_status_change after update of status on public.orders
for each row execute function public.capture_order_status_change();
alter table public.order_status_history enable row level security;
revoke all on public.order_status_history from anon, authenticated;

create or replace function public.checkout_admin_list_order_refunds()
returns table(order_id uuid,amount integer,method text,reason text,created_at timestamptz)
language plpgsql stable security definer set search_path=''
as $$
begin
  if not (select public.is_agenda_admin()) then raise exception 'Solo un administrador puede consultar los reembolsos.'; end if;
  return query select r.order_id,r.amount,r.method,r.reason,r.created_at from public.order_refunds r order by r.created_at desc;
end;
$$;
revoke all on function public.checkout_admin_list_order_refunds() from public,anon;
grant execute on function public.checkout_admin_list_order_refunds() to authenticated;

create or replace function public.checkout_admin_record_refund(p_order_id uuid,p_amount integer,p_method text,p_reason text)
returns void language plpgsql security definer set search_path=''
as $$
declare v_order public.orders%rowtype; v_total_refunded bigint;
begin
  if not (select public.is_agenda_admin()) then raise exception 'Solo un administrador puede registrar reembolsos.'; end if;
  if p_amount is null or p_amount<=0 or p_method is null or p_method not in ('Yappy','Transferencia bancaria','Efectivo','Otro')
    or p_reason is null or char_length(trim(p_reason)) not between 1 and 350 then raise exception 'Los datos del reembolso no son válidos.'; end if;
  select * into v_order from public.orders where id=p_order_id for update;
  if not found or v_order.status<>'paid' then raise exception 'Solo se pueden reembolsar órdenes pagadas.'; end if;
  select coalesce(sum(amount),0) into v_total_refunded from public.order_refunds where order_id=p_order_id;
  if p_amount::bigint > v_order.total_amount::bigint-v_total_refunded then raise exception 'El reembolso supera el saldo disponible de la orden.'; end if;
  insert into public.order_refunds(order_id,amount,method,reason,created_by) values(p_order_id,p_amount,p_method,trim(p_reason),(select auth.uid()));
  v_total_refunded:=v_total_refunded+p_amount;
  if v_total_refunded>=v_order.total_amount then
    update public.orders set status='refunded' where id=p_order_id;
    update public.agenda_reservations set status='cancelled',hold_expires_at=null where order_id=p_order_id and status in ('pending','confirmed');
  end if;
  insert into public.account_notifications(user_id,order_id,title,message)
  values(v_order.user_id,p_order_id,
    case when v_total_refunded>=v_order.total_amount then 'Reembolso completado' else 'Reembolso parcial registrado' end,
    'Se registró un reembolso manual de $'||to_char(p_amount::numeric/100,'FM999999990.00')||' mediante '||p_method||'. Detalle: '||trim(p_reason)
    ||case when v_total_refunded>=v_order.total_amount then ' La orden quedó reembolsada y su horario fue liberado.' else ' La orden mantiene el estado pagado mientras exista un saldo pendiente de reembolso.' end);
end;
$$;
revoke all on function public.checkout_admin_record_refund(uuid,integer,text,text) from public,anon;
grant execute on function public.checkout_admin_record_refund(uuid,integer,text,text) to authenticated;

create or replace function public.checkout_admin_cancel_paid_order(p_order_id uuid)
returns void language plpgsql security definer set search_path=''
as $$
declare v_order public.orders%rowtype;
begin
  if not (select public.is_agenda_admin()) then raise exception 'Solo un administrador puede cancelar órdenes.'; end if;
  select * into v_order from public.orders where id=p_order_id for update;
  if not found or v_order.status<>'paid' then raise exception 'Solo se pueden cancelar órdenes pagadas.'; end if;
  if exists(select 1 from public.order_refunds where order_id=p_order_id) then raise exception 'Esta orden tiene reembolsos registrados. Completa el proceso de reembolso antes de cancelarla.'; end if;
  update public.orders set status='cancelled' where id=p_order_id;
  update public.agenda_reservations set status='cancelled',hold_expires_at=null where order_id=p_order_id and status in ('pending','confirmed');
  insert into public.account_notifications(user_id,order_id,title,message) values(v_order.user_id,p_order_id,'Orden cancelada','Tu orden fue cancelada y el horario quedó liberado. Esta acción no implica un reembolso.');
end;
$$;
revoke all on function public.checkout_admin_cancel_paid_order(uuid) from public,anon;
grant execute on function public.checkout_admin_cancel_paid_order(uuid) to authenticated;
