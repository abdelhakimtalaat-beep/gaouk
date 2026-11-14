-- «جاؤوك» — المخطط الأساسي
-- الأمان: كل الجداول مغلقة تماماً أمام الواجهة (RLS بلا سياسات + سحب الصلاحيات)،
-- والوصول يتم فقط عبر دوال RPC في 0002 تفحص الدور والدولة وتكتب سجل العمليات.

create schema if not exists gk;

create table public.countries (
  id serial primary key,
  name text not null unique,
  dial_code text not null default ''
);

create table public.profiles (
  id serial primary key,
  auth_id uuid not null unique references auth.users(id) on delete cascade,
  name text not null,
  phone text not null default '',
  email text not null default '',
  username text not null,
  role text not null check (role in ('admin','event_manager','building_supervisor','transport','catering','country_supervisor')),
  status text not null default 'active' check (status in ('active','suspended')),
  notes text not null default '',
  created_at timestamptz not null default now()
);
create unique index profiles_username_key on public.profiles (lower(username));

create table public.user_countries (
  user_id int not null references public.profiles(id) on delete cascade,
  country_id int not null references public.countries(id) on delete cascade,
  is_primary boolean not null default false,
  primary key (user_id, country_id)
);

create table public.events (
  id serial primary key,
  name text not null,
  start_date text not null check (start_date ~ '^\d{4}-\d{2}-\d{2}$'),
  end_date text not null check (end_date ~ '^\d{4}-\d{2}-\d{2}$'),
  description text not null default '',
  expected_visitors int not null default 0,
  created_at timestamptz not null default now()
);

create table public.buildings (
  id serial primary key,
  name text not null unique,
  sort int not null default 0
);
create table public.floors (
  id serial primary key,
  building_id int not null references public.buildings(id) on delete cascade,
  name text not null,
  sort int not null default 0,
  plan_image text,                 -- صورة الكروكي (data URL مضغوطة من المتصفح)
  unique (building_id, name)
);
-- موقع الغرفة x,y,w,h بنسبة مئوية من مساحة رسم الدور ليحافظ على التوزيع المكاني للكروكي
create table public.rooms (
  id serial primary key,
  floor_id int not null references public.floors(id) on delete cascade,
  number text not null,
  capacity int not null check (capacity >= 0),
  status text not null default 'active' check (status in ('active','out_of_service')),
  x real not null default 2, y real not null default 2, w real not null default 14, h real not null default 14,
  notes text not null default '',
  unique (floor_id, number)
);
create table public.user_floors (
  user_id int not null references public.profiles(id) on delete cascade,
  floor_id int not null references public.floors(id) on delete cascade,
  primary key (user_id, floor_id)
);

create table public.groups_ (
  id serial primary key,
  event_id int not null references public.events(id) on delete cascade,
  name text not null,
  country_id int not null references public.countries(id),
  leader_name text not null default '',
  members_count int not null default 0,
  arrival_date text not null default '',
  departure_date text not null default '',
  notes text not null default '',
  created_by text not null default '',
  created_at timestamptz not null default now()
);

create table public.visitors (
  id serial primary key,
  event_id int not null references public.events(id) on delete cascade,
  full_name text not null,
  name_norm text not null default '',
  country_id int not null references public.countries(id),
  phone text not null default '',
  phone_norm text not null default '',
  email text not null default '',
  category text not null check (category in ('individual','family_head','family_member','group_member')),
  head_id int references public.visitors(id) on delete cascade,
  group_id int references public.groups_(id) on delete set null,
  is_leader boolean not null default false,
  relation text not null default '',
  guide_name text not null default '',
  arrival_date text not null default '',
  arrival_time text not null default '',
  departure_date text not null default '',
  flight_no text not null default '',
  airline text not null default '',
  airport text not null default '',
  needs_transport boolean not null default true,
  diet_notes text not null default '',
  notes text not null default '',
  created_by text not null default '',
  created_at timestamptz not null default now(),
  updated_by text not null default '',
  updated_at timestamptz not null default now()
);
create index visitors_event_idx on public.visitors (event_id, country_id);
create index visitors_phone_idx on public.visitors (event_id, phone_norm);
create index visitors_head_idx on public.visitors (head_id);

-- الفترة [من، إلى): تُحتسب ليلة الوصول ولا تُحتسب ليلة المغادرة
create table public.bookings (
  id serial primary key,
  event_id int not null references public.events(id) on delete cascade,
  visitor_id int not null references public.visitors(id) on delete cascade,
  room_id int not null references public.rooms(id) on delete restrict,
  from_date text not null check (from_date ~ '^\d{4}-\d{2}-\d{2}$'),
  to_date text not null check (to_date ~ '^\d{4}-\d{2}-\d{2}$'),
  notes text not null default '',
  created_by text not null default '',
  created_at timestamptz not null default now(),
  updated_by text not null default '',
  updated_at timestamptz not null default now(),
  check (to_date > from_date)
);
create index bookings_room_idx on public.bookings (room_id, from_date, to_date);
create index bookings_visitor_idx on public.bookings (visitor_id);

create table public.drivers (
  id serial primary key,
  event_id int not null references public.events(id) on delete cascade,
  name text not null,
  phone text not null default '',
  car_number text not null default '',
  car_type text not null default '',
  capacity int not null default 4,
  notes text not null default ''
);
create table public.transports (
  id serial primary key,
  event_id int not null references public.events(id) on delete cascade,
  driver_id int not null references public.drivers(id) on delete cascade,
  visitor_id int references public.visitors(id) on delete cascade,
  group_id int references public.groups_(id) on delete cascade,
  kind text not null default 'pickup' check (kind in ('pickup','dropoff')),
  task_date text not null,
  task_time text not null default '',
  airport text not null default '',
  flight_info text not null default '',
  passengers int not null default 1,
  status text not null default 'not_started' check (status in ('not_started','on_the_way','received','done')),
  notes text not null default '',
  created_by text not null default '',
  updated_by text not null default '',
  updated_at timestamptz not null default now()
);
create index transports_date_idx on public.transports (event_id, task_date);

-- date = '*' تعني كل أيام الإقامة
create table public.meal_exclusions (
  visitor_id int not null references public.visitors(id) on delete cascade,
  date text not null,
  meal text not null check (meal in ('breakfast','lunch','dinner')),
  primary key (visitor_id, date, meal)
);

create table public.audit_log (
  id bigserial primary key,
  at timestamptz not null default now(),
  username text not null default '',
  action text not null,
  entity text not null,
  entity_id int,
  event_id int,
  country_id int,
  details jsonb not null default '{}'::jsonb
);
create index audit_at_idx on public.audit_log (at desc);

-- ===== إغلاق الجداول أمام الواجهة: لا وصول مباشر إطلاقاً =====
do $$ declare t text; begin
  for t in select tablename from pg_tables where schemaname = 'public' loop
    execute format('alter table public.%I enable row level security', t);
    execute format('revoke all on public.%I from anon, authenticated', t);
  end loop;
end $$;
revoke all on all sequences in schema public from anon, authenticated;
revoke all on schema gk from public, anon, authenticated;
