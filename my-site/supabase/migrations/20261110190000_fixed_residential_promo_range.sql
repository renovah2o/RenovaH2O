create or replace function public.checkout_label_fixed_residential_promo()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if new.product_name = 'Promoción navideña de hidrolavado residencial · 1 m²' then
    new.product_name := 'Promoción navideña de hidrolavado residencial · 10 a 50 m²';
  end if;
  return new;
end;
$$;

revoke all on function public.checkout_label_fixed_residential_promo() from public, anon, authenticated;
