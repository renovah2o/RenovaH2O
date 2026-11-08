alter table public.profiles
  add column profile_avatar_path text,
  add column birthday date,
  add column preferred_services text[] not null default '{}',
  add constraint profiles_birthday_valid check (
    birthday is null
    or (birthday >= date '1900-01-01' and birthday <= current_date)
  ),
  add constraint profiles_preferred_services_valid check (
    preferred_services <@ array['residencial', 'comercial', 'alquileres']::text[]
  );

grant update (profile_avatar_path, birthday, preferred_services)
  on public.profiles to authenticated;

insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values (
  'profile-avatars',
  'profile-avatars',
  false,
  2097152,
  array['image/jpeg', 'image/png', 'image/webp']
)
on conflict (id) do update
set
  public = excluded.public,
  file_size_limit = excluded.file_size_limit,
  allowed_mime_types = excluded.allowed_mime_types;

create policy "Users can read their own profile avatars"
  on storage.objects for select
  to authenticated
  using (
    bucket_id = 'profile-avatars'
    and (storage.foldername(name))[1] = (select auth.uid())::text
  );

create policy "Users can upload their own profile avatars"
  on storage.objects for insert
  to authenticated
  with check (
    bucket_id = 'profile-avatars'
    and (storage.foldername(name))[1] = (select auth.uid())::text
  );

create policy "Users can delete their own profile avatars"
  on storage.objects for delete
  to authenticated
  using (
    bucket_id = 'profile-avatars'
    and (storage.foldername(name))[1] = (select auth.uid())::text
  );
