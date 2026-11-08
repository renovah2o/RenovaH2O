create function public.checkout_enforce_48_hour_notice()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if new.kind = 'service'
    and new.order_id is not null
    and new.status = 'pending'
    and new.starts_at < now() + interval '48 hours'
  then
    raise exception 'Las reservas requieren al menos 48 horas de anticipación. Elige otra fecha disponible.';
  end if;

  return new;
end;
$$;

revoke all on function public.checkout_enforce_48_hour_notice() from public, anon, authenticated;

create trigger checkout_enforce_48_hour_notice_insert
  before insert on public.agenda_reservations
  for each row execute function public.checkout_enforce_48_hour_notice();

create trigger checkout_enforce_48_hour_notice_reschedule
  before update of starts_at, ends_at on public.agenda_reservations
  for each row execute function public.checkout_enforce_48_hour_notice();
