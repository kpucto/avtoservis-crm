-- Выполнить целиком в Supabase: SQL Editor -> New query.
create extension if not exists pgcrypto;

create table if not exists public.profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  full_name text not null default '',
  role text not null default 'employee' check (role in ('owner','manager','tenant','employee')),
  tenant_name text,
  created_at timestamptz not null default now()
);
create table if not exists public.clients (
  id uuid primary key default gen_random_uuid(),
  full_name text not null,
  phone text not null,
  email text,
  notes text,
  created_at timestamptz not null default now()
);
create table if not exists public.vehicles (
  id uuid primary key default gen_random_uuid(),
  client_id uuid not null references public.clients(id) on delete cascade,
  make text not null,
  model text not null,
  year integer,
  plate text,
  vin text,
  mileage integer,
  created_at timestamptz not null default now()
);
create table if not exists public.appointments (
  id uuid primary key default gen_random_uuid(),
  client_id uuid not null references public.clients(id),
  vehicle_id uuid not null references public.vehicles(id),
  starts_at timestamptz not null,
  duration_minutes integer not null default 60,
  lift text not null default 'Подъёмник 1',
  complaint text not null default '',
  status text not null default 'Новая запись'
    check (status in ('Новая запись','Клиент приехал','Диагностика','Согласование','В ремонте','Ожидание запчастей','Готов','Выдан','Отменена')),
  assigned_tenant uuid references public.profiles(id),
  created_by uuid references auth.users(id),
  created_at timestamptz not null default now()
);
create table if not exists public.work_orders (
  id uuid primary key default gen_random_uuid(),
  order_no bigint generated always as identity unique,
  appointment_id uuid references public.appointments(id) on delete set null,
  client_id uuid not null references public.clients(id),
  vehicle_id uuid not null references public.vehicles(id),
  tenant_id uuid references public.profiles(id),
  status text not null default 'Открыт' check (status in ('Открыт','На согласовании','В работе','Ожидает запчасти','Готов','Закрыт','Отменён')),
  labor_total numeric(12,2) not null default 0,
  parts_total numeric(12,2) not null default 0,
  discount numeric(12,2) not null default 0,
  total numeric(12,2) generated always as (greatest(0,labor_total + parts_total - discount)) stored,
  service_fee_rate numeric(5,2) not null default 10.00,
  service_fee numeric(12,2) generated always as (round(greatest(0,labor_total + parts_total - discount) * service_fee_rate / 100, 2)) stored,
  notes text,
  created_by uuid references auth.users(id),
  created_at timestamptz not null default now(),
  closed_at timestamptz
);
create table if not exists public.work_order_lines (
  id uuid primary key default gen_random_uuid(),
  work_order_id uuid not null references public.work_orders(id) on delete cascade,
  line_type text not null check (line_type in ('work','part')),
  title text not null,
  quantity numeric(10,2) not null default 1,
  unit_price numeric(12,2) not null default 0,
  line_total numeric(12,2) generated always as (quantity * unit_price) stored
);
create table if not exists public.payments (
  id uuid primary key default gen_random_uuid(),
  work_order_id uuid not null references public.work_orders(id) on delete cascade,
  amount numeric(12,2) not null check (amount > 0),
  method text not null default 'Наличные',
  paid_at timestamptz not null default now(),
  note text
);
create table if not exists public.audit_log (
  id bigint generated always as identity primary key,
  actor_id uuid references auth.users(id),
  action text not null,
  entity text not null,
  entity_id uuid,
  details jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now()
);

alter table public.profiles enable row level security;
alter table public.clients enable row level security;
alter table public.vehicles enable row level security;
alter table public.appointments enable row level security;
alter table public.work_orders enable row level security;
alter table public.work_order_lines enable row level security;
alter table public.payments enable row level security;
alter table public.audit_log enable row level security;

-- Базовые политики для авторизованных сотрудников одной организации.
-- Для отдельных организаций/арендаторов изоляцию следует расширить до запуска в production.
create policy "profiles read authenticated" on public.profiles for select to authenticated using (true);
create policy "profiles update self" on public.profiles for update to authenticated using (id = auth.uid()) with check (id = auth.uid());
create policy "clients authenticated access" on public.clients for all to authenticated using (true) with check (true);
create policy "vehicles authenticated access" on public.vehicles for all to authenticated using (true) with check (true);
create policy "appointments authenticated access" on public.appointments for all to authenticated using (true) with check (true);
create policy "orders authenticated access" on public.work_orders for all to authenticated using (true) with check (true);
create policy "lines authenticated access" on public.work_order_lines for all to authenticated using (true) with check (true);
create policy "payments authenticated access" on public.payments for all to authenticated using (true) with check (true);
create policy "audit insert authenticated" on public.audit_log for insert to authenticated with check (actor_id = auth.uid());
create policy "audit read authenticated" on public.audit_log for select to authenticated using (true);

-- Первый пользователь: после регистрации его роль можно выставить вручную в таблице profiles на owner.
create or replace function public.handle_new_user()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  insert into public.profiles(id, full_name, role)
  values(new.id, coalesce(new.raw_user_meta_data->>'full_name',''), 'employee')
  on conflict (id) do nothing;
  return new;
end; $$;
drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created after insert on auth.users
for each row execute procedure public.handle_new_user();
