-- =====================================================================
-- MI CAJA - Esquema de base de datos (Supabase / PostgreSQL)
-- Pégalo completo en: Supabase > SQL Editor > New query > Run
-- Seguridad: cada usuario solo puede ver y modificar SUS propias filas (RLS)
-- =====================================================================

-- ---------- PERFILES ----------
create table if not exists public.profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  name text not null default '' check (char_length(name) <= 100),
  business text not null default '' check (char_length(business) <= 120),
  symbol text not null default '$' check (char_length(symbol) between 1 and 4),
  created_at timestamptz not null default now()
);

-- ---------- TABLAS DE NEGOCIO ----------
create table if not exists public.products (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null default auth.uid() references auth.users(id) on delete cascade,
  name text not null check (char_length(name) between 1 and 120),
  cost numeric(12,2) not null default 0 check (cost >= 0),
  price numeric(12,2) not null check (price >= 0),
  stock integer not null default 0 check (stock >= 0),
  min_stock integer not null default 5 check (min_stock >= 0),
  created_at timestamptz not null default now()
);

create table if not exists public.customers (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null default auth.uid() references auth.users(id) on delete cascade,
  name text not null check (char_length(name) between 1 and 120),
  phone text not null default '' check (char_length(phone) <= 40),
  notes text not null default '' check (char_length(notes) <= 500),
  created_at timestamptz not null default now()
);

create table if not exists public.sales (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null default auth.uid() references auth.users(id) on delete cascade,
  customer_id uuid references public.customers(id) on delete set null,
  method text not null check (method in ('Efectivo','Tarjeta','Transferencia','Fiado')),
  items jsonb not null default '[]'::jsonb,
  total numeric(12,2) not null default 0 check (total >= 0),
  created_at timestamptz not null default now()
);

create table if not exists public.orders (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null default auth.uid() references auth.users(id) on delete cascade,
  customer_id uuid references public.customers(id) on delete set null,
  description text not null check (char_length(description) between 1 and 200),
  total numeric(12,2) not null default 0 check (total >= 0),
  due date,
  status text not null default 'pendiente' check (status in ('pendiente','listo','entregado')),
  created_at timestamptz not null default now()
);

create table if not exists public.expenses (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null default auth.uid() references auth.users(id) on delete cascade,
  concept text not null check (char_length(concept) between 1 and 200),
  amount numeric(12,2) not null check (amount > 0),
  category text not null default 'Otros' check (char_length(category) <= 40),
  spent_on date not null default current_date,
  created_at timestamptz not null default now()
);

-- ---------- SEGURIDAD POR FILA (RLS) ----------
alter table public.profiles enable row level security;

drop policy if exists profiles_select_own on public.profiles;
drop policy if exists profiles_insert_own on public.profiles;
drop policy if exists profiles_update_own on public.profiles;
create policy profiles_select_own on public.profiles for select to authenticated using (id = (select auth.uid()));
create policy profiles_insert_own on public.profiles for insert to authenticated with check (id = (select auth.uid()));
create policy profiles_update_own on public.profiles for update to authenticated using (id = (select auth.uid())) with check (id = (select auth.uid()));

do $$
declare t text;
begin
  foreach t in array array['products','customers','sales','orders','expenses'] loop
    execute format('alter table public.%I enable row level security', t);
    execute format('drop policy if exists %I on public.%I', t || '_own', t);
    execute format(
      'create policy %I on public.%I for all to authenticated using (user_id = (select auth.uid())) with check (user_id = (select auth.uid()))',
      t || '_own', t);
    execute format('create index if not exists %I on public.%I (user_id)', t || '_user_idx', t);
  end loop;
end $$;

-- Nadie sin sesión puede tocar nada
revoke all on public.profiles, public.products, public.customers, public.sales, public.orders, public.expenses from anon;

-- ---------- PERFIL AUTOMÁTICO AL REGISTRARSE ----------
create or replace function public.handle_new_user()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  insert into public.profiles (id, name, business)
  values (
    new.id,
    left(coalesce(new.raw_user_meta_data->>'name', ''), 100),
    left(coalesce(new.raw_user_meta_data->>'business', ''), 120)
  )
  on conflict (id) do nothing;
  return new;
end $$;

revoke execute on function public.handle_new_user() from public, anon, authenticated;

drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function public.handle_new_user();

-- ---------- CREAR VENTA (el servidor valida stock y toma los precios) ----------
create or replace function public.create_sale(p_customer uuid, p_method text, p_items jsonb)
returns uuid language plpgsql set search_path = public as $$
declare
  it jsonb;
  prod public.products%rowtype;
  v_qty integer;
  v_total numeric(12,2) := 0;
  v_items jsonb := '[]'::jsonb;
  v_id uuid;
begin
  if auth.uid() is null then raise exception 'APP: Sesión no válida'; end if;
  if p_method not in ('Efectivo','Tarjeta','Transferencia','Fiado') then
    raise exception 'APP: Método de pago no válido';
  end if;
  if p_items is null or jsonb_typeof(p_items) <> 'array'
     or jsonb_array_length(p_items) = 0 or jsonb_array_length(p_items) > 100 then
    raise exception 'APP: La venta no tiene productos';
  end if;
  if p_customer is not null and not exists (
       select 1 from public.customers where id = p_customer and user_id = auth.uid()) then
    raise exception 'APP: Cliente no encontrado';
  end if;

  for it in select * from jsonb_array_elements(p_items) loop
    v_qty := (it->>'qty')::integer;
    if v_qty is null or v_qty <= 0 or v_qty > 100000 then raise exception 'APP: Cantidad no válida'; end if;

    select * into prod from public.products
      where id = (it->>'id')::uuid and user_id = auth.uid() for update;
    if not found then raise exception 'APP: Producto no encontrado'; end if;
    if prod.stock < v_qty then raise exception 'APP: Stock insuficiente de %', prod.name; end if;

    update public.products set stock = stock - v_qty where id = prod.id;
    v_total := v_total + v_qty * prod.price;
    v_items := v_items || jsonb_build_object(
      'id', prod.id, 'name', prod.name, 'qty', v_qty, 'price', prod.price, 'cost', prod.cost);
  end loop;

  insert into public.sales (customer_id, method, items, total)
  values (p_customer, p_method, v_items, v_total)
  returning id into v_id;

  return v_id;
end $$;

-- ---------- ANULAR VENTA (devuelve el stock) ----------
create or replace function public.void_sale(p_sale uuid)
returns void language plpgsql set search_path = public as $$
declare
  s public.sales%rowtype;
  it jsonb;
begin
  select * into s from public.sales where id = p_sale and user_id = auth.uid() for update;
  if not found then raise exception 'APP: Venta no encontrada'; end if;

  for it in select * from jsonb_array_elements(s.items) loop
    update public.products
      set stock = stock + (it->>'qty')::integer
      where id = (it->>'id')::uuid and user_id = auth.uid();
  end loop;

  delete from public.sales where id = s.id;
end $$;

revoke all on function public.create_sale(uuid, text, jsonb) from public, anon;
revoke all on function public.void_sale(uuid) from public, anon;
grant execute on function public.create_sale(uuid, text, jsonb) to authenticated;
grant execute on function public.void_sale(uuid) to authenticated;
