create or replace function public.apply_social_birthday_default()
returns trigger
language plpgsql
set search_path = ''
as $function$
declare
  v_provider text := coalesce(auth.jwt() -> 'app_metadata' ->> 'provider', '');
begin
  if coalesce(new.birthday_source_admin_locked, false) then
    return new;
  end if;

  if new.birthday_manual is null then
    if v_provider = 'google' and new.birthday_google is not null then
      new.birthday_source := 'google';
      new.birthday := new.birthday_google;
    elsif v_provider = 'facebook' and new.birthday_facebook is not null then
      new.birthday_source := 'facebook';
      new.birthday := new.birthday_facebook;
    end if;
  end if;

  return new;
end;
$function$;

grant update (birthday_google, birthday_facebook) on table public.profiles to authenticated;
