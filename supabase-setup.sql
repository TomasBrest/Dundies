-- Dundies: nastavenie databázy. Celé to vlož do Supabase → SQL Editor → Run.

-- Tabuľky
create table if not exists public.maps (
  id uuid primary key default gen_random_uuid(),
  name text not null default 'Naša mapa',
  code text unique not null,
  created_by uuid not null default auth.uid() references auth.users(id) on delete cascade,
  created_at timestamptz not null default now()
);

create table if not exists public.map_members (
  map_id uuid not null references public.maps(id) on delete cascade,
  user_id uuid not null references auth.users(id) on delete cascade,
  display_name text,
  joined_at timestamptz not null default now(),
  primary key (map_id, user_id)
);

create table if not exists public.memories (
  id uuid primary key default gen_random_uuid(),
  map_id uuid not null references public.maps(id) on delete cascade,
  created_by uuid default auth.uid() references auth.users(id) on delete set null,
  author_name text,
  name text,
  date date,
  note text,
  lat double precision not null,
  lng double precision not null,
  photos text[] not null default '{}',
  kind text not null default 'visited',
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
alter table public.memories add column if not exists kind text not null default 'visited';
create index if not exists memories_map_idx on public.memories(map_id);

-- Je prihlásený používateľ členom mapy?
create or replace function public.is_member(m uuid)
returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.map_members where map_id = m and user_id = auth.uid());
$$;

-- Zabezpečenie: každý vidí len mapy, ktorých je členom
alter table public.maps enable row level security;
alter table public.map_members enable row level security;
alter table public.memories enable row level security;

drop policy if exists "maps_select" on public.maps;
create policy "maps_select" on public.maps for select to authenticated using (public.is_member(id));
drop policy if exists "maps_update" on public.maps;
create policy "maps_update" on public.maps for update to authenticated using (public.is_member(id));

drop policy if exists "members_select" on public.map_members;
create policy "members_select" on public.map_members for select to authenticated using (public.is_member(map_id));
drop policy if exists "members_leave" on public.map_members;
create policy "members_leave" on public.map_members for delete to authenticated using (user_id = auth.uid());

drop policy if exists "memories_all" on public.memories;
create policy "memories_all" on public.memories for all to authenticated
  using (public.is_member(map_id)) with check (public.is_member(map_id));

-- Vytvorenie mapy s kódom (napr. BEET-4821)
create or replace function public.create_map(p_name text, p_display text)
returns public.maps language plpgsql security definer set search_path = public as $$
declare
  words text[] := array['BEET','DUNDIE','SCRANTON','STAPLER','PRETZEL','BEARS','PAPER','JELLO'];
  c text;
  m public.maps;
begin
  if auth.uid() is null then raise exception 'Nie si prihlásený'; end if;
  loop
    c := words[1 + floor(random() * array_length(words, 1))::int] || '-' || lpad(floor(random() * 10000)::int::text, 4, '0');
    exit when not exists (select 1 from public.maps where code = c);
  end loop;
  insert into public.maps (name, code, created_by) values (coalesce(nullif(p_name, ''), 'Naša mapa'), c, auth.uid()) returning * into m;
  insert into public.map_members (map_id, user_id, display_name) values (m.id, auth.uid(), p_display);
  return m;
end $$;

-- Pripojenie sa kódom
create or replace function public.join_map(p_code text, p_display text)
returns public.maps language plpgsql security definer set search_path = public as $$
declare m public.maps;
begin
  if auth.uid() is null then raise exception 'Nie si prihlásený'; end if;
  select * into m from public.maps where code = upper(trim(p_code));
  if m.id is null then raise exception 'Taký kód neexistuje'; end if;
  insert into public.map_members (map_id, user_id, display_name) values (m.id, auth.uid(), p_display)
    on conflict (map_id, user_id) do update set display_name = excluded.display_name;
  return m;
end $$;

grant execute on function public.create_map(text, text) to authenticated;
grant execute on function public.join_map(text, text) to authenticated;
grant execute on function public.is_member(uuid) to authenticated;

-- Úložisko fotiek (súkromné, vidia ho len členovia mapy)
insert into storage.buckets (id, name, public) values ('photos', 'photos', false) on conflict (id) do nothing;

drop policy if exists "photos_select" on storage.objects;
create policy "photos_select" on storage.objects for select to authenticated
  using (bucket_id = 'photos' and public.is_member(((storage.foldername(name))[1])::uuid));
drop policy if exists "photos_insert" on storage.objects;
create policy "photos_insert" on storage.objects for insert to authenticated
  with check (bucket_id = 'photos' and public.is_member(((storage.foldername(name))[1])::uuid));
drop policy if exists "photos_delete" on storage.objects;
create policy "photos_delete" on storage.objects for delete to authenticated
  using (bucket_id = 'photos' and public.is_member(((storage.foldername(name))[1])::uuid));

-- Živé aktualizácie (keď partner pridá miesto, hneď ho uvidíš)
do $$ begin
  alter publication supabase_realtime add table public.memories;
exception when duplicate_object then null; end $$;
