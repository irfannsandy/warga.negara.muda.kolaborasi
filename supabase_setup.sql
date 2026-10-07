
-- GALERI WARGA NEGARA MUDA — SUPABASE SETUP
-- Jalankan seluruh skrip ini di Supabase > SQL Editor.

create extension if not exists pgcrypto;

create table if not exists public.galeri_state (
  id integer primary key,
  artworks jsonb not null default '[]'::jsonb,
  reflections jsonb not null default '[]'::jsonb,
  instruction text not null default 'Selamat datang di Galeri Warga Negara Muda! Jelajahi seluruh karya teman-temanmu baik berupa Gambar, PDF, maupun Dokumen Word. Berikan apresiasi, baca pesan yang disampaikan, dan tuliskan komentar positif yang membangun.',
  awards jsonb not null default '{}'::jsonb,
  updated_at timestamptz not null default now()
);

insert into public.galeri_state (id)
values (1)
on conflict (id) do nothing;

alter table public.galeri_state enable row level security;

drop policy if exists "Public can read gallery state" on public.galeri_state;
create policy "Public can read gallery state"
on public.galeri_state for select
to anon, authenticated
using (true);

-- Web app memakai operasi terkontrol melalui fungsi di bawah.
-- Policy INSERT/UPDATE langsung tidak dibuka ke browser.

create or replace function public.append_artwork(p_artwork jsonb)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare result jsonb;
begin
  update public.galeri_state
  set artworks = artworks || jsonb_build_array(p_artwork),
      updated_at = now()
  where id = 1
  returning artworks into result;
  return result;
end;
$$;

create or replace function public.delete_artwork(p_art_id text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare result jsonb;
begin
  update public.galeri_state
  set artworks = coalesce(
      (select jsonb_agg(item)
       from jsonb_array_elements(artworks) item
       where item->>'id' <> p_art_id),
      '[]'::jsonb
    ),
    updated_at = now()
  where id = 1
  returning artworks into result;
  return result;
end;
$$;

create or replace function public.append_reflection(p_reflection jsonb)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare result jsonb;
begin
  update public.galeri_state
  set reflections = jsonb_build_array(p_reflection) || reflections,
      updated_at = now()
  where id = 1
  returning reflections into result;
  return result;
end;
$$;

create or replace function public.delete_reflection(p_ref_id text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare result jsonb;
begin
  update public.galeri_state
  set reflections = coalesce(
      (select jsonb_agg(item)
       from jsonb_array_elements(reflections) item
       where item->>'id' <> p_ref_id),
      '[]'::jsonb
    ),
    updated_at = now()
  where id = 1
  returning reflections into result;
  return result;
end;
$$;

create or replace function public.add_comment(p_art_id text, p_comment jsonb)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare result jsonb;
begin
  update public.galeri_state
  set artworks = (
    select coalesce(jsonb_agg(
      case
        when item->>'id' = p_art_id
        then jsonb_set(
          item,
          '{comments}',
          coalesce(item->'comments','[]'::jsonb) || jsonb_build_array(p_comment),
          true
        )
        else item
      end
    ), '[]'::jsonb)
    from jsonb_array_elements(artworks) item
  ),
  updated_at = now()
  where id = 1
  returning artworks into result;
  return result;
end;
$$;

create or replace function public.delete_comment(p_art_id text, p_comment_id text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare result jsonb;
begin
  update public.galeri_state
  set artworks = (
    select coalesce(jsonb_agg(
      case
        when item->>'id' = p_art_id
        then jsonb_set(
          item,
          '{comments}',
          coalesce(
            (select jsonb_agg(c)
             from jsonb_array_elements(coalesce(item->'comments','[]'::jsonb)) c
             where c->>'id' <> p_comment_id),
            '[]'::jsonb
          ),
          true
        )
        else item
      end
    ), '[]'::jsonb)
    from jsonb_array_elements(artworks) item
  ),
  updated_at = now()
  where id = 1
  returning artworks into result;
  return result;
end;
$$;

create or replace function public.increment_artwork_counter(p_art_id text, p_field text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare result jsonb;
begin
  if p_field not in ('likes','votes') then
    raise exception 'Invalid counter';
  end if;

  update public.galeri_state
  set artworks = (
    select coalesce(jsonb_agg(
      case
        when item->>'id' = p_art_id
        then jsonb_set(
          item,
          array[p_field],
          to_jsonb(coalesce((item->>p_field)::integer,0) + 1),
          true
        )
        else item
      end
    ), '[]'::jsonb)
    from jsonb_array_elements(artworks) item
  ),
  updated_at = now()
  where id = 1
  returning artworks into result;
  return result;
end;
$$;

create or replace function public.save_gallery_settings(p_instruction text, p_awards jsonb)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare result jsonb;
begin
  update public.galeri_state
  set instruction = coalesce(p_instruction, instruction),
      awards = coalesce(p_awards, awards),
      updated_at = now()
  where id = 1
  returning jsonb_build_object(
    'instruction', instruction,
    'awards', awards
  ) into result;
  return result;
end;
$$;

-- Izinkan browser memanggil fungsi-fungsi di atas.
grant usage on schema public to anon, authenticated;
grant execute on function public.append_artwork(jsonb) to anon, authenticated;
grant execute on function public.delete_artwork(text) to anon, authenticated;
grant execute on function public.append_reflection(jsonb) to anon, authenticated;
grant execute on function public.delete_reflection(text) to anon, authenticated;
grant execute on function public.add_comment(text,jsonb) to anon, authenticated;
grant execute on function public.delete_comment(text,text) to anon, authenticated;
grant execute on function public.increment_artwork_counter(text,text) to anon, authenticated;
grant execute on function public.save_gallery_settings(text,jsonb) to anon, authenticated;

-- STORAGE: bucket publik untuk foto/PDF/Word.
insert into storage.buckets (id, name, public)
values ('galeri-karya', 'galeri-karya', true)
on conflict (id) do update set public = true;

drop policy if exists "Public can view gallery files" on storage.objects;
create policy "Public can view gallery files"
on storage.objects for select
to anon, authenticated
using (bucket_id = 'galeri-karya');

drop policy if exists "Public can upload gallery files" on storage.objects;
create policy "Public can upload gallery files"
on storage.objects for insert
to anon, authenticated
with check (bucket_id = 'galeri-karya');

-- Realtime (aman dijalankan ulang)
do $$
begin
  if not exists (
    select 1
    from pg_publication_tables
    where pubname = 'supabase_realtime'
      and schemaname = 'public'
      and tablename = 'galeri_state'
  ) then
    alter publication supabase_realtime add table public.galeri_state;
  end if;
end $$;
