-- «جاؤوك» — ملف الإعداد الكامل لقاعدة بيانات Supabase: الصقه كاملاً في SQL Editor ثم Run (مرة واحدة)

-- ============ 0001_schema.sql ============
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

-- ============ 0002_helpers.sql ============
-- «جاؤوك» — دوال مساعدة داخلية (schema gk غير مكشوف للواجهة) + مشغلات السعة والتعارض

-- ---------- المستخدم الحالي ----------
-- PT401 → HTTP 401 (الواجهة تعيد المستخدم لصفحة الدخول)، PT403 → 403، PT404 → 404
create or replace function gk.cur() returns public.profiles
language plpgsql stable security definer set search_path = public, gk, pg_temp as $fn$
declare r public.profiles;
begin
  select * into r from public.profiles where auth_id = auth.uid() and status = 'active';
  if not found then
    raise exception 'الجلسة غير صالحة أو الحساب موقوف' using errcode = 'PT401';
  end if;
  return r;
end $fn$;

create or replace function gk.my_countries(uid int) returns int[]
language sql stable security definer set search_path = public, pg_temp as $fn$
  select coalesce(array_agg(country_id order by is_primary desc, country_id), '{}') from public.user_countries where user_id = uid $fn$;

create or replace function gk.my_floors(uid int) returns int[]
language sql stable security definer set search_path = public, pg_temp as $fn$
  select coalesce(array_agg(floor_id order by floor_id), '{}') from public.user_floors where user_id = uid $fn$;

create or replace function gk.need(u public.profiles, roles text[]) returns void
language plpgsql immutable as $fn$
begin
  if not (u.role = any(roles)) then
    raise exception 'لا تملك صلاحية لتنفيذ هذا الإجراء' using errcode = 'PT403';
  end if;
end $fn$;

create or replace function gk.forbid(msg text default 'لا تملك صلاحية لتنفيذ هذا الإجراء') returns void
language plpgsql immutable as $fn$ begin raise exception '%', msg using errcode = 'PT403'; end $fn$;
create or replace function gk.notfound(msg text default 'العنصر غير موجود') returns void
language plpgsql immutable as $fn$ begin raise exception '%', msg using errcode = 'PT404'; end $fn$;
create or replace function gk.bad(msg text) returns void
language plpgsql immutable as $fn$ begin raise exception '%', msg; end $fn$;

-- ---------- سجل العمليات ----------
create or replace function gk.audit(u public.profiles, act text, ent text, eid int, details jsonb default '{}'::jsonb, ev int default null, cid int default null) returns void
language plpgsql security definer set search_path = public, pg_temp as $fn$
begin
  insert into public.audit_log (username, action, entity, entity_id, event_id, country_id, details)
  values (coalesce(u.username, ''), act, ent, eid, ev, cid, coalesce(details, '{}'::jsonb));
end $fn$;

-- فرق القيم بين صفين (jsonb) لحقول محددة: {حقل: [قديم, جديد]}
create or replace function gk.diff(o jsonb, n jsonb, fields text[]) returns jsonb
language plpgsql immutable as $fn$
declare f text; d jsonb := '{}'::jsonb;
begin
  foreach f in array fields loop
    if n ? f and coalesce(o ->> f, '') is distinct from coalesce(n ->> f, '') then
      d := d || jsonb_build_object(f, jsonb_build_array(o -> f, n -> f));
    end if;
  end loop;
  return d;
end $fn$;

-- ---------- التحقق والتطبيع ----------
create or replace function gk.is_date(t text) returns boolean
language plpgsql immutable as $fn$
begin
  if t is null or t !~ '^\d{4}-\d{2}-\d{2}$' then return false; end if;
  return to_char(t::date, 'YYYY-MM-DD') = t;
exception when others then return false;
end $fn$;

create or replace function gk.is_time(t text) returns boolean
language sql immutable as $fn$ select t ~ '^([01]\d|2[0-3]):[0-5]\d$' $fn$;

create or replace function gk.norm_name(t text) returns text
language sql immutable as $fn$
  select btrim(regexp_replace(lower(translate(
    regexp_replace(normalize(coalesce(t, ''), NFKC), '[ً-ٰٟـ]', '', 'g'),
    'أإآٱىة', 'ااااي' || 'ه')), '\s+', ' ', 'g')) $fn$;

create or replace function gk.norm_phone(t text) returns text
language sql immutable as $fn$
  select regexp_replace(regexp_replace(
    translate(coalesce(t, ''), '٠١٢٣٤٥٦٧٨٩۰۱۲۳۴۵۶۷۸۹', '01234567890123456789'), '\D', '', 'g'), '^00', '') $fn$;

create or replace function gk.txt(v jsonb, k text, mx int default 500) returns text
language sql immutable as $fn$ select left(btrim(coalesce(v ->> k, '')), mx) $fn$;

create or replace function gk.room_state(st text, cap int, booked int) returns text
language sql immutable as $fn$
  select case when st <> 'active' or cap <= 0 then 'unavailable' when booked <= 0 then 'free' when booked >= cap then 'full' else 'partial' end $fn$;

create or replace function gk.room_label(rid int) returns text
language sql stable security definer set search_path = public, pg_temp as $fn$
  select b.name || ' - ' || f.name || ' - غرفة ' || r.number from public.rooms r join public.floors f on f.id = r.floor_id join public.buildings b on b.id = f.building_id where r.id = rid $fn$;

-- أقصى عدد نزلاء متزامنين في غرفة
create or replace function gk.max_concurrent(rid int) returns int
language sql stable security definer set search_path = public, pg_temp as $fn$
  select coalesce(max(c), 0)::int from (
    select (select count(*) from public.bookings x where x.room_id = rid and x.from_date <= b.from_date and x.to_date > b.from_date) c
    from public.bookings b where b.room_id = rid) t $fn$;

-- ---------- مشغلات الثوابت (تعمل مهما كان مصدر الكتابة) ----------
-- 1) الحجز: حالة الغرفة، السعة في كل يوم، وعدم تداخل فترات نفس الزائر
create or replace function gk.booking_guard() returns trigger
language plpgsql security definer set search_path = public, gk, pg_temp as $fn$
declare r public.rooms; v public.visitors; o record; d date; n int;
begin
  -- قفل صف الغرفة لتسلسل الحجوزات المتزامنة ومنع تجاوز السعة
  select * into r from public.rooms where id = new.room_id for update;
  if r.status <> 'active' then raise exception 'الغرفة % خارج الخدمة', r.number; end if;
  if r.capacity <= 0 then raise exception 'الغرفة % سعتها صفر', r.number; end if;
  if not gk.is_date(new.from_date) or not gk.is_date(new.to_date) then raise exception 'تواريخ الحجز غير صحيحة'; end if;
  if new.to_date <= new.from_date then raise exception 'تاريخ المغادرة يجب أن يكون بعد تاريخ الوصول بيوم على الأقل'; end if;
  select * into v from public.visitors where id = new.visitor_id;
  select b.from_date f, b.to_date t, rr.number num into o
    from public.bookings b join public.rooms rr on rr.id = b.room_id
    where b.visitor_id = new.visitor_id and b.id <> coalesce(new.id, 0) and b.from_date < new.to_date and new.from_date < b.to_date limit 1;
  if found then
    raise exception 'الزائر «%» محجوز مسبقاً في غرفة % خلال فترة متداخلة (% ← %)', v.full_name, o.num, o.f, o.t;
  end if;
  for d in select generate_series(new.from_date::date, new.to_date::date - 1, interval '1 day')::date loop
    select count(*) into n from public.bookings b
      where b.room_id = new.room_id and b.id <> coalesce(new.id, 0) and b.from_date <= to_char(d, 'YYYY-MM-DD') and b.to_date > to_char(d, 'YYYY-MM-DD');
    if n + 1 > r.capacity then
      raise exception 'الغرفة % مكتملة بتاريخ % (السعة %) ولا يمكن إضافة «%»', r.number, to_char(d, 'YYYY-MM-DD'), r.capacity, v.full_name;
    end if;
  end loop;
  return new;
end $fn$;
create trigger bookings_guard before insert or update of room_id, visitor_id, from_date, to_date on public.bookings
  for each row execute function gk.booking_guard();

-- 2) الغرفة: لا خفض للسعة ولا إخراج من الخدمة تحت حجوزات قائمة
create or replace function gk.room_guard() returns trigger
language plpgsql security definer set search_path = public, gk, pg_temp as $fn$
declare m int;
begin
  if new.capacity < old.capacity or (new.status <> 'active' and old.status = 'active') then
    m := gk.max_concurrent(old.id);
    if m > 0 and (new.status <> 'active' or new.capacity < m) then
      raise exception 'لا يمكن التعديل: يوجد حجز متزامن يصل إلى % أشخاص في هذه الغرفة. انقلهم أولاً', m;
    end if;
  end if;
  return new;
end $fn$;
create trigger rooms_guard before update of capacity, status on public.rooms
  for each row execute function gk.room_guard();

-- ============ 0003_visitors.sql ============
-- «جاؤوك» — منطق الزائرين والأفواج واكتشاف التكرار والاستيراد (دوال داخلية في schema gk)

create or replace function gk.truthy(v jsonb, k text) returns boolean
language sql immutable as $fn$ select coalesce(v ->> k, '') in ('true', '1', 't') $fn$;

create or replace function gk.can_see_country(u public.profiles, cid int) returns boolean
language sql stable security definer set search_path = public, gk, pg_temp as $fn$
  select u.role <> 'country_supervisor' or cid = any (gk.my_countries(u.id)) $fn$;

-- رؤية الزائر حسب الدور (cs = دول المشرف، fl = أدوار المبنى)
create or replace function gk.can_see(role text, cs int[], fl int[], vid int, vcountry int) returns boolean
language sql stable security definer set search_path = public, pg_temp as $fn$
  select case
    when role in ('admin', 'event_manager', 'transport', 'catering') then true
    when role = 'country_supervisor' then vcountry = any (cs)
    when role = 'building_supervisor' then
      exists (select 1 from public.bookings b join public.rooms r on r.id = b.room_id where b.visitor_id = vid and r.floor_id = any (fl))
      or not exists (select 1 from public.bookings bb where bb.visitor_id = vid)
    else false end $fn$;

create or replace function gk.get_event(eid int) returns public.events
language plpgsql stable security definer set search_path = public, gk, pg_temp as $fn$
declare e public.events;
begin
  select * into e from public.events where id = eid;
  if not found then raise exception 'يجب اختيار مناسبة صحيحة'; end if;
  return e;
end $fn$;

-- ---------- تنظيف وتحقق بيانات الزائر ----------
create or replace function gk.clean_visitor(b jsonb, u public.profiles, ev_id int, member boolean default false, allow_member boolean default false) returns jsonb
language plpgsql security definer set search_path = public, gk, pg_temp as $fn$
declare o jsonb := '{}'::jsonb; nm text; cid int; cat text; gid int; g public.groups_;
        ad text; dd text; at text; em text;
begin
  nm := gk.txt(b, 'full_name', 150);
  if nm = '' then raise exception 'الاسم الكامل مطلوب'; end if;
  o := jsonb_build_object('full_name', nm);
  if not member then
    cid := nullif(b ->> 'country_id', '')::int;
    if cid is null or not exists (select 1 from public.countries where id = cid) then raise exception 'اختر الدولة للزائر «%»', nm; end if;
    if not gk.can_see_country(u, cid) then perform gk.forbid('لا يمكنك تسجيل زائرين من دولة غير مسؤول عنها'); end if;
    cat := b ->> 'category';
    if cat is null or not (cat in ('individual', 'family_head', 'group_member') or (allow_member and cat = 'family_member')) then raise exception 'تصنيف الزائر غير صحيح'; end if;
    gid := nullif(b ->> 'group_id', '')::int;
    if cat = 'group_member' then
      select * into g from public.groups_ where id = gid and event_id = ev_id;
      if not found then raise exception 'اختر الفوج لعضو الفوج'; end if;
      if g.country_id <> cid then raise exception 'الفوج «%» تابع لدولة مختلفة عن دولة الزائر', g.name; end if;
    else gid := null; end if;
    ad := gk.txt(b, 'arrival_date', 10); dd := gk.txt(b, 'departure_date', 10); at := gk.txt(b, 'arrival_time', 5);
    if ad <> '' and not gk.is_date(ad) then raise exception 'تاريخ الوصول غير صحيح'; end if;
    if dd <> '' and not gk.is_date(dd) then raise exception 'تاريخ المغادرة غير صحيح'; end if;
    if ad <> '' and dd <> '' and dd < ad then raise exception 'تاريخ المغادرة قبل الوصول للزائر «%»', nm; end if;
    if at <> '' and not gk.is_time(at) then raise exception 'وقت الوصول غير صحيح (استخدم صيغة 14:30)'; end if;
    o := o || jsonb_build_object('country_id', cid, 'category', cat, 'guide_name', gk.txt(b, 'guide_name', 120), 'group_id', gid,
      'is_leader', (cat = 'group_member' and gk.truthy(b, 'is_leader')),
      'arrival_date', ad, 'departure_date', dd, 'arrival_time', at,
      'flight_no', gk.txt(b, 'flight_no', 30), 'airline', gk.txt(b, 'airline', 60), 'airport', gk.txt(b, 'airport', 80),
      'needs_transport', not (coalesce(b ->> 'needs_transport', '1') in ('false', '0', 'f')));
  end if;
  em := gk.txt(b, 'email', 120);
  if em <> '' and em !~ '^[^@\s]+@[^@\s]+\.[^@\s]+$' then raise exception 'البريد الإلكتروني غير صحيح'; end if;
  return o || jsonb_build_object('phone', gk.txt(b, 'phone', 30), 'email', em, 'relation', gk.txt(b, 'relation', 40),
    'diet_notes', gk.txt(b, 'diet_notes', 500), 'notes', gk.txt(b, 'notes', 1000));
end $fn$;

-- ---------- اكتشاف التكرار ----------
create or replace function gk.find_dups(ev_id int, u public.profiles, cand jsonb, exclude int[] default '{}') returns jsonb
language plpgsql security definer set search_path = public, gk, pg_temp as $fn$
declare pn text := gk.norm_phone(cand ->> 'phone'); nn text := gk.norm_name(cand ->> 'full_name'); k text; res jsonb := '[]'::jsonb; r record; reason text; cid int := nullif(cand ->> 'country_id', '')::int;
begin
  k := case when length(pn) >= 7 then right(pn, 7) else '' end;
  for r in
    select v.id, v.full_name, v.country_id, v.phone, v.created_by, v.category, c.name country_name, v.phone_norm
    from public.visitors v join public.countries c on c.id = v.country_id
    where v.event_id = ev_id and not (v.id = any (exclude))
      and ((k <> '' and right(v.phone_norm, 7) = k) or (nn <> '' and v.name_norm = nn and v.country_id = cid))
    limit 5
  loop
    reason := case when k <> '' and right(r.phone_norm, 7) = k then 'نفس رقم الهاتف' else 'نفس الاسم والدولة' end;
    if not gk.can_see_country(u, r.country_id) then
      res := res || jsonb_build_array(jsonb_build_object('hidden', true, 'reason', reason, 'candidate', cand ->> 'full_name'));
    else
      res := res || jsonb_build_array(jsonb_build_object('id', r.id, 'full_name', r.full_name, 'country_name', r.country_name, 'phone', r.phone,
        'created_by', r.created_by, 'category', r.category, 'reason', reason, 'candidate', cand ->> 'full_name'));
    end if;
  end loop;
  return res;
end $fn$;

create or replace function gk.ins_visitor(o jsonb, ev_id int, u public.profiles, head int default null) returns int
language plpgsql security definer set search_path = public, gk, pg_temp as $fn$
declare nid int;
begin
  insert into public.visitors (event_id, full_name, name_norm, country_id, phone, phone_norm, email, category, head_id, group_id, is_leader, relation, guide_name,
      arrival_date, arrival_time, departure_date, flight_no, airline, airport, needs_transport, diet_notes, notes, created_by, updated_by)
  values (ev_id, o ->> 'full_name', gk.norm_name(o ->> 'full_name'), (o ->> 'country_id')::int, o ->> 'phone', gk.norm_phone(o ->> 'phone'), coalesce(o ->> 'email', ''),
      o ->> 'category', head, nullif(o ->> 'group_id', '')::int, gk.truthy(o, 'is_leader'), coalesce(o ->> 'relation', ''), coalesce(o ->> 'guide_name', ''),
      coalesce(o ->> 'arrival_date', ''), coalesce(o ->> 'arrival_time', ''), coalesce(o ->> 'departure_date', ''), coalesce(o ->> 'flight_no', ''),
      coalesce(o ->> 'airline', ''), coalesce(o ->> 'airport', ''), not (coalesce(o ->> 'needs_transport', 'true') in ('false', '0', 'f')),
      coalesce(o ->> 'diet_notes', ''), coalesce(o ->> 'notes', ''), u.username, u.username)
  returning id into nid;
  return nid;
end $fn$;

-- تنظيف قائمة التابعين: بيانات السفر والدولة تُنسخ من رب الأسرة
create or replace function gk.clean_members(lst jsonb, head jsonb, u public.profiles, ev_id int) returns jsonb
language plpgsql security definer set search_path = public, gk, pg_temp as $fn$
declare res jsonb := '[]'::jsonb; m jsonb; c jsonb; f text;
begin
  if lst is null or jsonb_typeof(lst) <> 'array' then return res; end if;
  for m in select * from jsonb_array_elements(lst) loop
    c := gk.clean_visitor(m, u, ev_id, true);
    c := c || jsonb_build_object('id', nullif(m ->> 'id', '')::int, 'category', 'family_member', 'group_id', null, 'is_leader', false);
    foreach f in array array['country_id', 'arrival_date', 'arrival_time', 'departure_date', 'flight_no', 'airline', 'airport', 'needs_transport', 'guide_name'] loop
      c := c || jsonb_build_object(f, head -> f);
    end loop;
    res := res || jsonb_build_array(c);
  end loop;
  return res;
end $fn$;

create or replace function gk.conflicts_for(ev_id int, u public.profiles, head jsonb, members jsonb, exclude int[]) returns jsonb
language plpgsql security definer set search_path = public, gk, pg_temp as $fn$
declare res jsonb; m jsonb;
begin
  res := gk.find_dups(ev_id, u, head, exclude);
  for m in select * from jsonb_array_elements(members) loop
    res := res || gk.find_dups(ev_id, u, jsonb_build_object('full_name', m ->> 'full_name', 'phone', m ->> 'phone', 'country_id', head ->> 'country_id'), exclude);
  end loop;
  return res;
end $fn$;

-- يعيد null إن لم يوجد تكرار، وإلا ردّ 409/403 جاهز للواجهة
create or replace function gk.dup_gate(force boolean, dups jsonb) returns jsonb
language plpgsql immutable as $fn$
begin
  if jsonb_array_length(dups) = 0 then return null; end if;
  if not force then return jsonb_build_object('_status', 409, 'error', 'يوجد سجل مشابه مسجل مسبقاً', 'code', 'duplicate', 'duplicates', dups); end if;
  if exists (select 1 from jsonb_array_elements(dups) d where d ? 'hidden') then
    return jsonb_build_object('_status', 403, 'error', 'يوجد سجل مشابه لدى دولة أخرى. تواصل مع مدير النظام قبل الحفظ');
  end if;
  return null;
end $fn$;

-- ---------- إنشاء زائر ----------
create or replace function gk.visitor_create(u public.profiles, b jsonb) returns jsonb
language plpgsql security definer set search_path = public, gk, pg_temp as $fn$
declare ev public.events := gk.get_event(nullif(b ->> 'event_id', '')::int); o jsonb; members jsonb := '[]'::jsonb; gate jsonb; id int; m jsonb;
begin
  perform gk.need(u, array['admin', 'event_manager', 'country_supervisor']);
  o := gk.clean_visitor(b, u, ev.id);
  if o ->> 'category' = 'family_head' then members := gk.clean_members(b -> 'members', o, u, ev.id); end if;
  gate := gk.dup_gate(gk.truthy(b, 'force'), gk.conflicts_for(ev.id, u, o, members, '{}'));
  if gate is not null then return gate; end if;
  id := gk.ins_visitor(o, ev.id, u);
  for m in select * from jsonb_array_elements(members) loop perform gk.ins_visitor(m, ev.id, u, id); end loop;
  perform gk.audit(u, 'create', 'visitor', id, jsonb_build_object('name', o ->> 'full_name', 'category', o ->> 'category', 'members', jsonb_array_length(members)), ev.id, (o ->> 'country_id')::int);
  return jsonb_build_object('id', id);
end $fn$;

create or replace function gk.visitor_get_scoped(u public.profiles, vid int) returns public.visitors
language plpgsql stable security definer set search_path = public, gk, pg_temp as $fn$
declare v public.visitors;
begin
  select * into v from public.visitors where id = vid;
  if not found or not gk.can_see(u.role, gk.my_countries(u.id), gk.my_floors(u.id), v.id, v.country_id) then
    perform gk.notfound('الزائر غير موجود أو خارج صلاحياتك');
  end if;
  return v;
end $fn$;

-- ---------- تعديل زائر ----------
create or replace function gk.visitor_update(u public.profiles, vid int, b jsonb) returns jsonb
language plpgsql security definer set search_path = public, gk, pg_temp as $fn$
declare old public.visitors := gk.visitor_get_scoped(u, vid); ev public.events := gk.get_event(old.event_id);
  o jsonb; members jsonb; gate jsonb; exclude int[]; old_members jsonb; changed boolean; new_members jsonb := '[]'::jsonb; m jsonb; keep int[] := '{}';
  removed text[] := '{}'; added text[] := '{}'; d jsonb; rm record; nid int; warns jsonb := '[]'::jsonb; bk record; mid int;
begin
  perform gk.need(u, array['admin', 'event_manager', 'country_supervisor']);
  if old.category = 'family_member' then
    o := gk.clean_visitor(to_jsonb(old) || b, u, ev.id, true);
    if o ->> 'full_name' <> old.full_name or o ->> 'phone' <> old.phone then
      gate := gk.dup_gate(gk.truthy(b, 'force'), gk.find_dups(ev.id, u, jsonb_build_object('full_name', o ->> 'full_name', 'phone', o ->> 'phone', 'country_id', old.country_id), array[old.id]));
      if gate is not null then return gate; end if;
    end if;
    update public.visitors set full_name = o ->> 'full_name', name_norm = gk.norm_name(o ->> 'full_name'), phone = o ->> 'phone', phone_norm = gk.norm_phone(o ->> 'phone'),
      email = o ->> 'email', relation = o ->> 'relation', diet_notes = o ->> 'diet_notes', notes = o ->> 'notes', updated_by = u.username, updated_at = now() where id = old.id;
    perform gk.audit(u, 'update', 'visitor', old.id, gk.diff(to_jsonb(old), o, array['full_name', 'phone', 'email', 'relation', 'diet_notes', 'notes']), ev.id, old.country_id);
    return jsonb_build_object('ok', true);
  end if;

  o := gk.clean_visitor(to_jsonb(old) || b || jsonb_build_object('category', coalesce(b ->> 'category', old.category)), u, ev.id);
  if old.category = 'family_head' and o ->> 'category' <> 'family_head' and exists (select 1 from public.visitors where head_id = old.id) then
    raise exception 'لا يمكن تغيير تصنيف رب أسرة له تابعون. احذف التابعين أولاً';
  end if;
  select coalesce(jsonb_agg(to_jsonb(x)), '[]'::jsonb) into old_members from public.visitors x where x.head_id = old.id;
  members := case when o ->> 'category' = 'family_head' then gk.clean_members(case when b ? 'members' then b -> 'members' else old_members end, o, u, ev.id) else '[]'::jsonb end;
  select array_agg(id) into exclude from (select old.id id union all select id from public.visitors where head_id = old.id) t;
  changed := o ->> 'full_name' <> old.full_name or o ->> 'phone' <> old.phone or (o ->> 'country_id')::int <> old.country_id;
  for m in select * from jsonb_array_elements(members) loop
    if m ->> 'id' is null or not exists (select 1 from public.visitors x where x.id = (m ->> 'id')::int and x.head_id = old.id and x.full_name = m ->> 'full_name' and x.phone = m ->> 'phone') then
      new_members := new_members || jsonb_build_array(m);
    end if;
  end loop;
  if changed or jsonb_array_length(new_members) > 0 then
    gate := gk.dup_gate(gk.truthy(b, 'force'),
      gk.conflicts_for(ev.id, u, case when changed then o else o || jsonb_build_object('full_name', '', 'phone', '') end, new_members, exclude));
    if gate is not null then return gate; end if;
  end if;

  update public.visitors set full_name = o ->> 'full_name', name_norm = gk.norm_name(o ->> 'full_name'), country_id = (o ->> 'country_id')::int, phone = o ->> 'phone',
    phone_norm = gk.norm_phone(o ->> 'phone'), email = o ->> 'email', category = o ->> 'category', group_id = nullif(o ->> 'group_id', '')::int, is_leader = gk.truthy(o, 'is_leader'),
    guide_name = o ->> 'guide_name', arrival_date = o ->> 'arrival_date', arrival_time = o ->> 'arrival_time', departure_date = o ->> 'departure_date', flight_no = o ->> 'flight_no',
    airline = o ->> 'airline', airport = o ->> 'airport', needs_transport = gk.truthy(o, 'needs_transport'), diet_notes = o ->> 'diet_notes', notes = o ->> 'notes',
    updated_by = u.username, updated_at = now() where id = old.id;

  for m in select * from jsonb_array_elements(members) loop
    mid := nullif(m ->> 'id', '')::int;
    if mid is not null and exists (select 1 from public.visitors where id = mid and head_id = old.id) then
      keep := keep || mid;
      update public.visitors set full_name = m ->> 'full_name', name_norm = gk.norm_name(m ->> 'full_name'), phone = m ->> 'phone', phone_norm = gk.norm_phone(m ->> 'phone'),
        email = m ->> 'email', relation = m ->> 'relation', diet_notes = m ->> 'diet_notes', notes = m ->> 'notes', country_id = (m ->> 'country_id')::int,
        arrival_date = m ->> 'arrival_date', arrival_time = m ->> 'arrival_time', departure_date = m ->> 'departure_date', flight_no = m ->> 'flight_no',
        airline = m ->> 'airline', airport = m ->> 'airport', needs_transport = gk.truthy(m, 'needs_transport'), guide_name = m ->> 'guide_name',
        updated_by = u.username, updated_at = now() where id = mid;
    else
      nid := gk.ins_visitor(m, ev.id, u, old.id); keep := keep || nid; added := added || (m ->> 'full_name');
    end if;
  end loop;
  for rm in select id, full_name from public.visitors where head_id = old.id and not (id = any (keep)) loop
    removed := removed || rm.full_name; delete from public.visitors where id = rm.id;
  end loop;
  d := gk.diff(to_jsonb(old), o, array['full_name', 'country_id', 'phone', 'email', 'category', 'guide_name', 'group_id', 'is_leader', 'relation', 'arrival_date', 'arrival_time',
    'departure_date', 'flight_no', 'airline', 'airport', 'needs_transport', 'diet_notes', 'notes']);
  if cardinality(removed) > 0 then d := d || jsonb_build_object('removed_members', to_jsonb(removed)); end if;
  if cardinality(added) > 0 then d := d || jsonb_build_object('added_members', to_jsonb(added)); end if;
  perform gk.audit(u, 'update', 'visitor', old.id, d, ev.id, (o ->> 'country_id')::int);

  for bk in select b2.from_date, b2.to_date, v.full_name from public.bookings b2 join public.visitors v on v.id = b2.visitor_id
            where b2.visitor_id = old.id or v.head_id = old.id loop
    if ((o ->> 'arrival_date') <> '' and bk.from_date < o ->> 'arrival_date') or ((o ->> 'departure_date') <> '' and bk.to_date > o ->> 'departure_date') then
      warns := warns || to_jsonb(format('حجز الغرفة للزائر «%s» (%s ← %s) لا يطابق تواريخ الإقامة الجديدة. راجع التسكين', bk.full_name, bk.from_date, bk.to_date));
    end if;
  end loop;
  return jsonb_build_object('ok', true, 'warnings', warns);
end $fn$;

create or replace function gk.visitor_delete(u public.profiles, vid int) returns jsonb
language plpgsql security definer set search_path = public, gk, pg_temp as $fn$
declare v public.visitors; mem jsonb;
begin
  perform gk.need(u, array['admin', 'event_manager', 'country_supervisor']);
  v := gk.visitor_get_scoped(u, vid);
  select coalesce(jsonb_agg(full_name), '[]'::jsonb) into mem from public.visitors where head_id = v.id;
  delete from public.visitors where id = v.id;
  perform gk.audit(u, 'delete', 'visitor', v.id, jsonb_build_object('name', v.full_name, 'category', v.category, 'members', mem), v.event_id, v.country_id);
  return jsonb_build_object('ok', true);
end $fn$;

-- ---------- قائمة الزائرين ----------
create or replace function gk.visitors_list(u public.profiles, q jsonb) returns jsonb
language plpgsql stable security definer set search_path = public, gk, pg_temp as $fn$
declare ev public.events := gk.get_event(nullif(q ->> 'event_id', '')::int); cs int[] := gk.my_countries(u.id); fl int[] := gk.my_floors(u.id);
  t text := btrim(coalesce(q ->> 'q', '')); nn text; pn text; res jsonb;
begin
  nn := '%' || gk.norm_name(t) || '%'; pn := gk.norm_phone(t);
  select coalesce(jsonb_agg(row_j order by sort_name, sub, full_name), '[]'::jsonb) into res from (
    select
      (to_jsonb(v) - 'phone_norm' - 'name_norm'
        || jsonb_build_object('country_name', c.name, 'group_name', g.name, 'head_name', h.full_name,
             'members_count', (select count(*) from public.visitors m where m.head_id = v.id),
             'phone', case when u.role = 'catering' then '' else v.phone end,
             'email', case when u.role in ('catering', 'building_supervisor') then '' else v.email end,
             'bookings', coalesce((select jsonb_agg(jsonb_build_object('id', b.id, 'visitor_id', b.visitor_id, 'room_id', b.room_id, 'from_date', b.from_date, 'to_date', b.to_date,
                 'room_number', r.number, 'floor_id', r.floor_id, 'floor_name', f.name, 'building_id', bl.id, 'building_name', bl.name) order by b.from_date)
               from public.bookings b join public.rooms r on r.id = b.room_id join public.floors f on f.id = r.floor_id join public.buildings bl on bl.id = f.building_id
               where b.visitor_id = v.id), '[]'::jsonb),
             'transports', case when u.role in ('building_supervisor', 'catering') then '[]'::jsonb else coalesce((
               select jsonb_agg(jsonb_build_object('id', tr.id, 'visitor_id', tr.visitor_id, 'group_id', tr.group_id, 'kind', tr.kind, 'task_date', tr.task_date, 'task_time', tr.task_time,
                 'status', tr.status, 'passengers', tr.passengers, 'driver_name', d.name, 'driver_phone', d.phone, 'car_number', d.car_number, 'car_type', d.car_type))
               from public.transports tr join public.drivers d on d.id = tr.driver_id
               where tr.event_id = v.event_id and (tr.visitor_id = v.id or (v.head_id is not null and tr.visitor_id = v.head_id) or (v.group_id is not null and tr.group_id = v.group_id))), '[]'::jsonb) end
        )) row_j,
      coalesce(h.full_name, v.full_name) sort_name, (v.head_id is not null) sub, v.full_name
    from public.visitors v join public.countries c on c.id = v.country_id
      left join public.groups_ g on g.id = v.group_id left join public.visitors h on h.id = v.head_id
    where v.event_id = ev.id and gk.can_see(u.role, cs, fl, v.id, v.country_id)
      and (t = '' or v.name_norm like nn or (length(pn) >= 3 and v.phone_norm like '%' || pn || '%') or v.flight_no ilike '%' || t || '%')
      and (nullif(q ->> 'country_id', '') is null or v.country_id = (q ->> 'country_id')::int)
      and (nullif(q ->> 'category', '') is null or v.category = q ->> 'category')
      and (nullif(q ->> 'group_id', '') is null or v.group_id = (q ->> 'group_id')::int)
      and (not gk.is_date(q ->> 'arrival') or v.arrival_date = q ->> 'arrival')
      and (not gk.is_date(q ->> 'departure') or v.departure_date = q ->> 'departure')
      and (not gk.is_date(q ->> 'present_on') or (v.arrival_date <> '' and v.arrival_date <= q ->> 'present_on' and (v.departure_date = '' or v.departure_date >= q ->> 'present_on')))
      and (nullif(q ->> 'room_id', '') is null or v.id in (select visitor_id from public.bookings where room_id = (q ->> 'room_id')::int))
      and (nullif(q ->> 'floor_id', '') is null or v.id in (select b.visitor_id from public.bookings b join public.rooms r on r.id = b.room_id where r.floor_id = (q ->> 'floor_id')::int))
      and (nullif(q ->> 'building_id', '') is null or v.id in (select b.visitor_id from public.bookings b join public.rooms r on r.id = b.room_id join public.floors f on f.id = r.floor_id where f.building_id = (q ->> 'building_id')::int))
      and (coalesce(q ->> 'unhoused', '') <> '1' or not exists (select 1 from public.bookings bb where bb.visitor_id = v.id))
    limit 5000
  ) s;
  return res;
end $fn$;

-- ---------- الأفواج ----------
create or replace function gk.group_input(b jsonb, u public.profiles) returns jsonb
language plpgsql security definer set search_path = public, gk, pg_temp as $fn$
declare nm text := gk.txt(b, 'name', 100); cid int := nullif(b ->> 'country_id', '')::int; a text := gk.txt(b, 'arrival_date', 10); d text := gk.txt(b, 'departure_date', 10);
begin
  if nm = '' then raise exception 'اسم أو رقم الفوج مطلوب'; end if;
  if cid is null or not exists (select 1 from public.countries where id = cid) then raise exception 'دولة الفوج مطلوبة'; end if;
  if not gk.can_see_country(u, cid) then perform gk.forbid('لا يمكنك إدارة أفواج دولة أخرى'); end if;
  if (a <> '' and not gk.is_date(a)) or (d <> '' and not gk.is_date(d)) then raise exception 'تاريخ غير صحيح'; end if;
  if a <> '' and d <> '' and d < a then raise exception 'تاريخ المغادرة قبل الوصول'; end if;
  return jsonb_build_object('name', nm, 'country_id', cid, 'leader_name', gk.txt(b, 'leader_name', 120), 'members_count', greatest(0, coalesce(nullif(b ->> 'members_count', '')::int, 0)),
    'arrival_date', a, 'departure_date', d, 'notes', gk.txt(b, 'notes', 1000));
end $fn$;

create or replace function gk.groups_list(u public.profiles, q jsonb) returns jsonb
language plpgsql stable security definer set search_path = public, gk, pg_temp as $fn$
declare ev public.events := gk.get_event(nullif(q ->> 'event_id', '')::int); cs int[] := gk.my_countries(u.id);
begin
  return jsonb_build_object('groups', coalesce((select jsonb_agg(to_jsonb(g) || jsonb_build_object('country_name', c.name, 'registered', (select count(*) from public.visitors v where v.group_id = g.id)) order by g.name)
    from public.groups_ g join public.countries c on c.id = g.country_id
    where g.event_id = ev.id and (u.role <> 'country_supervisor' or g.country_id = any (cs))), '[]'::jsonb));
end $fn$;

create or replace function gk.group_create(u public.profiles, b jsonb) returns jsonb
language plpgsql security definer set search_path = public, gk, pg_temp as $fn$
declare ev public.events := gk.get_event(nullif(b ->> 'event_id', '')::int); o jsonb; id int;
begin
  perform gk.need(u, array['admin', 'event_manager', 'country_supervisor']);
  o := gk.group_input(b, u);
  insert into public.groups_ (event_id, name, country_id, leader_name, members_count, arrival_date, departure_date, notes, created_by)
  values (ev.id, o ->> 'name', (o ->> 'country_id')::int, o ->> 'leader_name', (o ->> 'members_count')::int, o ->> 'arrival_date', o ->> 'departure_date', o ->> 'notes', u.username) returning groups_.id into id;
  perform gk.audit(u, 'create', 'group', id, o, ev.id, (o ->> 'country_id')::int);
  return jsonb_build_object('id', id);
end $fn$;

create or replace function gk.group_update(u public.profiles, gid int, b jsonb) returns jsonb
language plpgsql security definer set search_path = public, gk, pg_temp as $fn$
declare old public.groups_; o jsonb;
begin
  perform gk.need(u, array['admin', 'event_manager', 'country_supervisor']);
  select * into old from public.groups_ where id = gid;
  if not found or not gk.can_see_country(u, old.country_id) then perform gk.notfound(); end if;
  o := gk.group_input(to_jsonb(old) || b, u);
  update public.groups_ set name = o ->> 'name', country_id = (o ->> 'country_id')::int, leader_name = o ->> 'leader_name', members_count = (o ->> 'members_count')::int,
    arrival_date = o ->> 'arrival_date', departure_date = o ->> 'departure_date', notes = o ->> 'notes' where id = old.id;
  perform gk.audit(u, 'update', 'group', old.id, gk.diff(to_jsonb(old), o, array['name', 'country_id', 'leader_name', 'members_count', 'arrival_date', 'departure_date', 'notes']), old.event_id, (o ->> 'country_id')::int);
  return jsonb_build_object('ok', true);
end $fn$;

create or replace function gk.group_delete(u public.profiles, gid int) returns jsonb
language plpgsql security definer set search_path = public, gk, pg_temp as $fn$
declare old public.groups_;
begin
  perform gk.need(u, array['admin', 'event_manager', 'country_supervisor']);
  select * into old from public.groups_ where id = gid;
  if not found or not gk.can_see_country(u, old.country_id) then perform gk.notfound(); end if;
  if exists (select 1 from public.visitors where group_id = old.id) then raise exception 'لا يمكن حذف فوج له أعضاء مسجلون. انقلهم أو احذفهم أولاً'; end if;
  delete from public.groups_ where id = old.id;
  perform gk.audit(u, 'delete', 'group', old.id, jsonb_build_object('name', old.name), old.event_id, old.country_id);
  return jsonb_build_object('ok', true);
end $fn$;

-- ---------- استيراد من Excel (المتصفح يقرأ الملف ويرسل الصفوف؛ هذه الدالة تتحقق وتُدرج) ----------
-- rows: [{line, full_name, country, phone, email, category(تسمية عربية), guide_name, head, group, leader, arrival_date, arrival_time, departure_date,
--         flight_no, airline, airport, transport, diet_notes, notes, _bad_date, _bad_time}]
create or replace function gk.visitors_import(u public.profiles, b jsonb) returns jsonb
language plpgsql security definer set search_path = public, gk, pg_temp as $fn$
declare ev public.events := gk.get_event(nullif(b ->> 'event_id', '')::int); dry boolean := gk.truthy(b, 'dry');
  r jsonb; res jsonb; created int := 0; total int := 0; skipped jsonb := '[]'::jsonb; errors jsonb := '[]'::jsonb;
  cid int; cat text; base jsonb; headrow public.visitors; gname text; g public.groups_; o jsonb; dups jsonb; f text; line int;
begin
  perform gk.need(u, array['admin', 'event_manager', 'country_supervisor']);
  if jsonb_typeof(b -> 'rows') <> 'array' or jsonb_array_length(b -> 'rows') = 0 then raise exception 'الملف لا يحتوي على بيانات'; end if;
  if jsonb_array_length(b -> 'rows') > 3000 then raise exception 'الحد الأقصى 3000 صف في المرة الواحدة'; end if;
  total := jsonb_array_length(b -> 'rows');
  begin
    -- التابعون بعد أرباب الأسر ليجدوا رب الأسرة في نفس الملف
    for r in select x from jsonb_array_elements(b -> 'rows') x order by (gk.norm_name(x ->> 'category') = gk.norm_name('تابع لعائلة')), (x ->> 'line')::int loop
      line := (r ->> 'line')::int;
      begin
        select id into cid from public.countries where gk.norm_name(name) = gk.norm_name(r ->> 'country');
        if cid is null then raise exception 'الدولة «%» غير موجودة في قائمة الدول', coalesce(r ->> 'country', ''); end if;
        cat := case gk.norm_name(r ->> 'category') when gk.norm_name('رب أسرة') then 'family_head' when gk.norm_name('تابع لعائلة') then 'family_member'
                when gk.norm_name('عضو في فوج') then 'group_member' else 'individual' end;
        if gk.truthy(r, '_bad_date') then raise exception 'صيغة التاريخ غير صحيحة (استخدم 2026-12-20)'; end if;
        if gk.truthy(r, '_bad_time') then raise exception 'صيغة الوقت غير صحيحة'; end if;
        base := jsonb_build_object('full_name', r ->> 'full_name', 'country_id', cid, 'phone', coalesce(r ->> 'phone', ''), 'email', coalesce(r ->> 'email', ''), 'category', cat,
          'guide_name', coalesce(r ->> 'guide_name', ''), 'arrival_date', coalesce(r ->> 'arrival_date', ''), 'arrival_time', coalesce(r ->> 'arrival_time', ''),
          'departure_date', coalesce(r ->> 'departure_date', ''), 'flight_no', coalesce(r ->> 'flight_no', ''), 'airline', coalesce(r ->> 'airline', ''), 'airport', coalesce(r ->> 'airport', ''),
          'needs_transport', gk.norm_name(r ->> 'transport') <> gk.norm_name('لا'), 'diet_notes', coalesce(r ->> 'diet_notes', ''), 'notes', coalesce(r ->> 'notes', ''));
        headrow := null;
        if cat = 'family_member' then
          select * into headrow from public.visitors where event_id = ev.id and category = 'family_head' and name_norm = gk.norm_name(r ->> 'head') and country_id = cid limit 1;
          if headrow.id is null then raise exception 'رب الأسرة «%» غير موجود (يجب أن يكون مسجلاً أو في نفس الملف)', coalesce(r ->> 'head', ''); end if;
          base := base || jsonb_build_object('country_id', headrow.country_id, 'arrival_date', headrow.arrival_date, 'arrival_time', headrow.arrival_time, 'departure_date', headrow.departure_date,
            'flight_no', headrow.flight_no, 'airline', headrow.airline, 'airport', headrow.airport, 'needs_transport', headrow.needs_transport, 'guide_name', headrow.guide_name);
        end if;
        if cat = 'group_member' then
          gname := gk.txt(r, 'group', 100);
          if gname = '' then raise exception 'اسم الفوج مطلوب لعضو الفوج'; end if;
          select * into g from public.groups_ where event_id = ev.id and name = gname and country_id = cid limit 1;
          if g.id is null then
            insert into public.groups_ (event_id, name, country_id, arrival_date, departure_date, created_by)
            values (ev.id, gname, cid, coalesce(r ->> 'arrival_date', ''), coalesce(r ->> 'departure_date', ''), u.username) returning * into g;
          end if;
          base := base || jsonb_build_object('group_id', g.id, 'is_leader', gk.norm_name(r ->> 'leader') = gk.norm_name('نعم'));
        end if;
        o := gk.clean_visitor(base, u, ev.id, false, true);
        if cat = 'family_member' then
          o := o || jsonb_build_object('category', 'family_member');
        end if;
        dups := gk.find_dups(ev.id, u, o, '{}');
        if jsonb_array_length(dups) > 0 then
          skipped := skipped || jsonb_build_array(jsonb_build_object('row', line, 'name', o ->> 'full_name',
            'msg', 'مكرر: ' || (dups -> 0 ->> 'reason') || case when dups -> 0 ? 'hidden' then ' (مسجل لدى دولة أخرى)' else '' end));
          continue;
        end if;
        perform gk.ins_visitor(o, ev.id, u, headrow.id);
        created := created + 1;
      exception when sqlstate 'PT403' or sqlstate 'P0001' then
        errors := errors || jsonb_build_array(jsonb_build_object('row', line, 'name', coalesce(r ->> 'full_name', ''), 'msg', sqlerrm));
      end;
    end loop;
    if not dry then
      perform gk.audit(u, 'import', 'visitor', null, jsonb_build_object('created', created, 'skipped', jsonb_array_length(skipped), 'errors', jsonb_array_length(errors)), ev.id);
    end if;
    res := jsonb_build_object('created', created, 'skipped', skipped, 'errors', errors, 'total', total, 'dry', dry);
    if dry then raise exception '%', res::text using errcode = 'GKDRY'; end if;
  exception when sqlstate 'GKDRY' then
    res := sqlerrm::jsonb;
  end;
  return res;
end $fn$;

-- ============ 0004_admin_ops.sql ============
-- «جاؤوك» — الإدارة (الدول، المناسبات، المستخدمون، المباني) + التسكين + النقل + الوجبات

create schema if not exists extensions;
create extension if not exists pgcrypto with schema extensions;

create or replace function gk.is_email(t text) returns boolean language sql immutable as $fn$ select t ~ '^[^@\s]+@[^@\s]+\.[^@\s]+$' $fn$;
create or replace function gk.int_or(v text, d int) returns int language sql immutable as $fn$
  select case when v ~ '^-?\d{1,9}$' then v::int else d end $fn$;
create or replace function gk.pct(v text, d real) returns real language sql immutable as $fn$
  select least(100, greatest(0, case when v ~ '^-?\d+(\.\d+)?$' then v::real else d end)) $fn$;

-- ================= الحساب الحالي =================
create or replace function gk.me(u public.profiles) returns jsonb
language sql stable security definer set search_path = public, gk, pg_temp as $fn$
  select jsonb_build_object('user', jsonb_build_object('id', u.id, 'name', u.name, 'username', u.username, 'role', u.role, 'phone', u.phone, 'email', u.email,
    'countries', gk.my_countries(u.id), 'floors', gk.my_floors(u.id),
    'primary_country', (select country_id from public.user_countries where user_id = u.id and is_primary limit 1))) $fn$;

-- ================= الدول =================
create or replace function gk.countries_list(u public.profiles) returns jsonb
language sql stable security definer set search_path = public, gk, pg_temp as $fn$
  select jsonb_build_object('countries', coalesce(jsonb_agg(to_jsonb(c) order by c.name), '[]'::jsonb))
  from public.countries c where u.role <> 'country_supervisor' or c.id = any (gk.my_countries(u.id)) $fn$;

create or replace function gk.country_save(u public.profiles, cid int, b jsonb) returns jsonb
language plpgsql security definer set search_path = public, gk, pg_temp as $fn$
declare nm text := gk.txt(b, 'name', 80); id int;
begin
  perform gk.need(u, array['admin']);
  if nm = '' then raise exception 'اسم الدولة مطلوب'; end if;
  begin
    if cid is null then
      insert into public.countries (name, dial_code) values (nm, gk.txt(b, 'dial_code', 8)) returning countries.id into id;
      perform gk.audit(u, 'create', 'country', id, jsonb_build_object('name', nm));
      return jsonb_build_object('id', id);
    else
      update public.countries set name = nm, dial_code = gk.txt(b, 'dial_code', 8) where countries.id = cid;
      perform gk.audit(u, 'update', 'country', cid, jsonb_build_object('name', nm));
      return jsonb_build_object('ok', true);
    end if;
  exception when unique_violation then raise exception 'هذه الدولة مسجلة مسبقاً';
  end;
end $fn$;

create or replace function gk.country_delete(u public.profiles, cid int) returns jsonb
language plpgsql security definer set search_path = public, gk, pg_temp as $fn$
begin
  perform gk.need(u, array['admin']);
  if exists (select 1 from public.visitors where country_id = cid) or exists (select 1 from public.groups_ where country_id = cid) then
    raise exception 'لا يمكن حذف دولة لها زائرون أو أفواج مسجلون';
  end if;
  delete from public.countries where id = cid;
  perform gk.audit(u, 'delete', 'country', cid);
  return jsonb_build_object('ok', true);
end $fn$;

-- ================= المناسبات =================
create or replace function gk.event_input(b jsonb) returns jsonb
language plpgsql immutable as $fn$
declare nm text := gk.txt(b, 'name', 150);
begin
  if nm = '' then raise exception 'اسم المناسبة مطلوب'; end if;
  if not gk.is_date(b ->> 'start_date') or not gk.is_date(b ->> 'end_date') then raise exception 'تاريخ البداية والنهاية مطلوبان'; end if;
  if (b ->> 'end_date') < (b ->> 'start_date') then raise exception 'تاريخ النهاية يجب أن يكون بعد البداية'; end if;
  return jsonb_build_object('name', nm, 'start_date', b ->> 'start_date', 'end_date', b ->> 'end_date', 'description', gk.txt(b, 'description', 2000),
    'expected_visitors', greatest(0, gk.int_or(b ->> 'expected_visitors', 0)));
end $fn$;

create or replace function gk.event_save(u public.profiles, eid int, b jsonb) returns jsonb
language plpgsql security definer set search_path = public, gk, pg_temp as $fn$
declare e jsonb := gk.event_input(b); old public.events; id int;
begin
  perform gk.need(u, array['admin', 'event_manager']);
  if eid is null then
    insert into public.events (name, start_date, end_date, description, expected_visitors)
    values (e ->> 'name', e ->> 'start_date', e ->> 'end_date', e ->> 'description', (e ->> 'expected_visitors')::int) returning events.id into id;
    perform gk.audit(u, 'create', 'event', id, e, id);
    return jsonb_build_object('id', id);
  end if;
  old := gk.get_event(eid);
  update public.events set name = e ->> 'name', start_date = e ->> 'start_date', end_date = e ->> 'end_date', description = e ->> 'description',
    expected_visitors = (e ->> 'expected_visitors')::int where events.id = old.id;
  perform gk.audit(u, 'update', 'event', old.id, gk.diff(to_jsonb(old), e, array['name', 'start_date', 'end_date', 'description', 'expected_visitors']), old.id);
  return jsonb_build_object('ok', true);
end $fn$;

create or replace function gk.event_delete(u public.profiles, eid int, b jsonb) returns jsonb
language plpgsql security definer set search_path = public, gk, pg_temp as $fn$
declare ev public.events := gk.get_event(eid);
begin
  perform gk.need(u, array['admin']);
  if b ->> 'confirm_name' is distinct from ev.name then raise exception 'اكتب اسم المناسبة بالضبط لتأكيد الحذف (يحذف كل زائريها وحجوزاتها)'; end if;
  delete from public.events where id = ev.id;
  perform gk.audit(u, 'delete', 'event', ev.id, jsonb_build_object('name', ev.name));
  return jsonb_build_object('ok', true);
end $fn$;

-- ================= المستخدمون =================
create or replace function gk.users_list(u public.profiles) returns jsonb
language plpgsql stable security definer set search_path = public, gk, pg_temp as $fn$
begin
  perform gk.need(u, array['admin', 'event_manager']);
  return jsonb_build_object('users', coalesce((select jsonb_agg(
    jsonb_build_object('id', p.id, 'name', p.name, 'phone', p.phone, 'email', p.email, 'username', p.username, 'role', p.role, 'status', p.status, 'notes', p.notes, 'created_at', p.created_at,
      'countries', coalesce((select jsonb_agg(jsonb_build_object('id', uc.country_id, 'name', c.name, 'is_primary', uc.is_primary) order by uc.is_primary desc) from public.user_countries uc join public.countries c on c.id = uc.country_id where uc.user_id = p.id), '[]'::jsonb),
      'floors', coalesce((select jsonb_agg(jsonb_build_object('id', uf.floor_id, 'floor_name', f.name, 'building_name', b.name, 'building_id', b.id)) from public.user_floors uf join public.floors f on f.id = uf.floor_id join public.buildings b on b.id = f.building_id where uf.user_id = p.id), '[]'::jsonb))
    order by p.role, p.name) from public.profiles p), '[]'::jsonb));
end $fn$;

create or replace function gk.user_input(b jsonb, is_new boolean) returns jsonb
language plpgsql immutable as $fn$
declare o jsonb; un text; cids int[]; prim int := gk.int_or(b ->> 'country_id', 0); x jsonb;
begin
  o := jsonb_build_object('name', gk.txt(b, 'name', 120), 'phone', gk.txt(b, 'phone', 30), 'email', gk.txt(b, 'email', 120), 'notes', gk.txt(b, 'notes', 1000),
    'role', b ->> 'role', 'status', case when b ->> 'status' = 'suspended' then 'suspended' else 'active' end);
  if o ->> 'name' = '' then raise exception 'الاسم مطلوب'; end if;
  if (o ->> 'role') is null or not (o ->> 'role') in ('admin', 'event_manager', 'building_supervisor', 'transport', 'catering', 'country_supervisor') then raise exception 'الدور غير صحيح'; end if;
  if o ->> 'email' <> '' and not gk.is_email(o ->> 'email') then raise exception 'البريد الإلكتروني غير صحيح'; end if;
  if is_new or b ? 'username' then
    un := gk.txt(b, 'username', 40);
    if un !~ '^[A-Za-z0-9_.-]{3,40}$' then raise exception 'اسم المستخدم 3-40 حرفاً إنجليزياً أو أرقاماً أو ( _ . - )'; end if;
    o := o || jsonb_build_object('username', un);
  end if;
  if (is_new or coalesce(b ->> 'password', '') <> '') and (length(coalesce(b ->> 'password', '')) < 8 or (b ->> 'password') !~ '[A-Za-z]' or (b ->> 'password') !~ '\d') then
    raise exception 'كلمة المرور 8 أحرف على الأقل وتحتوي على حروف وأرقام';
  end if;
  select coalesce(array_agg(distinct i), '{}') into cids from (
    select prim i where prim > 0
    union select gk.int_or(e, 0) from jsonb_array_elements_text(case when jsonb_typeof(b -> 'extra_country_ids') = 'array' then b -> 'extra_country_ids' else '[]'::jsonb end) e) t where i > 0;
  if o ->> 'role' = 'country_supervisor' then
    if prim <= 0 then raise exception 'يجب تحديد الدولة المسؤول عنها المشرف'; end if;
    if exists (select 1 from unnest(cids) c where not exists (select 1 from public.countries where id = c)) then raise exception 'دولة غير موجودة'; end if;
  else cids := '{}'; end if;
  return o || jsonb_build_object('_countries', to_jsonb(cids), '_primary', prim,
    '_floors', case when o ->> 'role' = 'building_supervisor' and jsonb_typeof(b -> 'floor_ids') = 'array'
      then (select coalesce(jsonb_agg(distinct gk.int_or(e, 0)), '[]'::jsonb) from jsonb_array_elements_text(b -> 'floor_ids') e) else '[]'::jsonb end);
end $fn$;

create or replace function gk.user_relations(pid int, o jsonb) returns void
language plpgsql security definer set search_path = public, gk, pg_temp as $fn$
declare c int; f int;
begin
  delete from public.user_countries where user_id = pid;
  for c in select (jsonb_array_elements_text(o -> '_countries'))::int loop
    insert into public.user_countries (user_id, country_id, is_primary) values (pid, c, c = (o ->> '_primary')::int);
  end loop;
  delete from public.user_floors where user_id = pid;
  for f in select (jsonb_array_elements_text(o -> '_floors'))::int loop
    if exists (select 1 from public.floors where id = f) then insert into public.user_floors (user_id, floor_id) values (pid, f) on conflict do nothing; end if;
  end loop;
end $fn$;

-- إنشاء حساب دخول في Supabase Auth (البريد الداخلي = اسم المستخدم@gaouk.app)
create or replace function gk.make_auth_user(uname text, pw text) returns uuid
language plpgsql security definer set search_path = public, extensions, auth, pg_temp as $fn$
declare uid uuid := gen_random_uuid(); em text := lower(uname) || '@gaouk.app';
begin
  insert into auth.users (instance_id, id, aud, role, email, encrypted_password, email_confirmed_at, raw_app_meta_data, raw_user_meta_data, created_at, updated_at,
      confirmation_token, email_change, email_change_token_new, recovery_token, email_change_token_current, phone_change, phone_change_token, reauthentication_token)
  values ('00000000-0000-0000-0000-000000000000', uid, 'authenticated', 'authenticated', em, crypt(pw, gen_salt('bf')), now(),
      '{"provider":"email","providers":["email"]}', '{}', now(), now(), '', '', '', '', '', '', '', '');
  insert into auth.identities (id, user_id, identity_data, provider, provider_id, last_sign_in_at, created_at, updated_at)
  values (gen_random_uuid(), uid, jsonb_build_object('sub', uid::text, 'email', em, 'email_verified', true), 'email', uid::text, now(), now(), now());
  return uid;
end $fn$;

create or replace function gk.user_create(u public.profiles, b jsonb) returns jsonb
language plpgsql security definer set search_path = public, gk, pg_temp as $fn$
declare o jsonb := gk.user_input(b, true); aid uuid; pid int;
begin
  perform gk.need(u, array['admin']);
  if exists (select 1 from public.profiles where lower(username) = lower(o ->> 'username')) then raise exception 'اسم المستخدم مستخدم مسبقاً'; end if;
  aid := gk.make_auth_user(o ->> 'username', b ->> 'password');
  insert into public.profiles (auth_id, name, phone, email, username, role, status, notes)
  values (aid, o ->> 'name', o ->> 'phone', o ->> 'email', o ->> 'username', o ->> 'role', o ->> 'status', o ->> 'notes') returning id into pid;
  perform gk.user_relations(pid, o);
  perform gk.audit(u, 'create', 'user', pid, jsonb_build_object('username', o ->> 'username', 'role', o ->> 'role', 'countries', o -> '_countries'), null, nullif((o ->> '_primary')::int, 0));
  return jsonb_build_object('id', pid);
end $fn$;

create or replace function gk.user_update(u public.profiles, pid int, b jsonb) returns jsonb
language plpgsql security definer set search_path = public, extensions, gk, auth, pg_temp as $fn$
declare old public.profiles; o jsonb; uname text; d jsonb;
begin
  perform gk.need(u, array['admin']);
  select * into old from public.profiles where id = pid;
  if not found then perform gk.notfound(); end if;
  o := gk.user_input(b, false);
  if pid = u.id and (o ->> 'status' <> 'active' or o ->> 'role' <> 'admin') then raise exception 'لا يمكنك إيقاف حسابك أو تغيير دورك'; end if;
  uname := coalesce(o ->> 'username', old.username);
  if exists (select 1 from public.profiles where lower(username) = lower(uname) and id <> pid) then raise exception 'اسم المستخدم مستخدم مسبقاً'; end if;
  update public.profiles set name = o ->> 'name', phone = o ->> 'phone', email = o ->> 'email', username = uname, role = o ->> 'role', status = o ->> 'status', notes = o ->> 'notes' where id = pid;
  d := gk.diff(to_jsonb(old), o || jsonb_build_object('username', uname), array['name', 'phone', 'email', 'username', 'role', 'status']);
  update auth.users set email = lower(uname) || '@gaouk.app', banned_until = case when o ->> 'status' = 'active' then null else 'infinity'::timestamptz end, updated_at = now() where id = old.auth_id;
  update auth.identities set identity_data = jsonb_set(identity_data, '{email}', to_jsonb(lower(uname) || '@gaouk.app')) where user_id = old.auth_id;
  if coalesce(b ->> 'password', '') <> '' then
    update auth.users set encrypted_password = crypt(b ->> 'password', gen_salt('bf')), updated_at = now() where id = old.auth_id;
    d := d || jsonb_build_object('password', 'reset');
  end if;
  perform gk.user_relations(pid, o);
  d := d || jsonb_build_object('countries', o -> '_countries');
  perform gk.audit(u, 'update', 'user', pid, d, null, nullif((o ->> '_primary')::int, 0));
  return jsonb_build_object('ok', true);
end $fn$;

create or replace function gk.user_delete(u public.profiles, pid int) returns jsonb
language plpgsql security definer set search_path = public, gk, auth, pg_temp as $fn$
declare old public.profiles;
begin
  perform gk.need(u, array['admin']);
  if pid = u.id then raise exception 'لا يمكنك حذف حسابك'; end if;
  select * into old from public.profiles where id = pid;
  if not found then perform gk.notfound(); end if;
  delete from public.profiles where id = pid;
  delete from auth.users where id = old.auth_id;
  perform gk.audit(u, 'delete', 'user', pid, jsonb_build_object('username', old.username));
  return jsonb_build_object('ok', true);
end $fn$;

-- إنشاء أول مدير (يُنفَّذ مرة واحدة من SQL Editor فقط).
-- إن كان لديك مستخدم أنشأته من Authentication → Users بالبريد  اسم_المستخدم@gaouk.app  فسيُربط به بدل إنشاء جديد.
create or replace function public.gk_bootstrap_admin(p_username text, p_password text, p_name text default 'مدير النظام') returns text
language plpgsql security definer set search_path = public, gk, auth, pg_temp as $fn$
declare aid uuid; pid int;
begin
  if exists (select 1 from public.profiles) then raise exception 'تم إنشاء مدير مسبقاً'; end if;
  select id into aid from auth.users where email = lower(p_username) || '@gaouk.app';
  if aid is null then
    if length(coalesce(p_password, '')) < 8 then raise exception 'كلمة المرور 8 أحرف على الأقل'; end if;
    aid := gk.make_auth_user(p_username, p_password);
  end if;
  insert into public.profiles (auth_id, name, username, role) values (aid, p_name, p_username, 'admin') returning id into pid;
  return 'تم إنشاء المدير: ' || p_username;
end $fn$;
revoke all on function public.gk_bootstrap_admin(text, text, text) from public, anon, authenticated;

-- ================= المباني والأدوار والغرف =================
create or replace function gk.structure(u public.profiles) returns jsonb
language plpgsql stable security definer set search_path = public, gk, pg_temp as $fn$
declare fl int[] := gk.my_floors(u.id); res jsonb;
begin
  perform gk.need(u, array['admin', 'event_manager', 'building_supervisor']);
  select coalesce(jsonb_agg(to_jsonb(b) || jsonb_build_object('floors', fls) order by b.sort, b.id), '[]'::jsonb) into res
  from public.buildings b,
  lateral (select coalesce(jsonb_agg(
      (to_jsonb(f) - 'plan_image') || jsonb_build_object('has_plan', coalesce(f.plan_image, '') <> '',
        'rooms', coalesce((select jsonb_agg(to_jsonb(r) order by (case when r.number ~ '^\d+$' then r.number::int end), r.number) from public.rooms r where r.floor_id = f.id), '[]'::jsonb),
        'supervisors', coalesce((select jsonb_agg(jsonb_build_object('id', p.id, 'name', p.name, 'phone', p.phone)) from public.user_floors uf join public.profiles p on p.id = uf.user_id where uf.floor_id = f.id and p.status = 'active'), '[]'::jsonb),
        'capacity', coalesce((select sum(r.capacity) from public.rooms r where r.floor_id = f.id and r.status = 'active'), 0))
      order by f.sort, f.id), '[]'::jsonb) fls
    from public.floors f where f.building_id = b.id and (u.role <> 'building_supervisor' or f.id = any (fl))) x
  where u.role <> 'building_supervisor' or jsonb_array_length(fls) > 0;
  return jsonb_build_object('buildings', res);
end $fn$;

create or replace function gk.building_save(u public.profiles, bid int, b jsonb) returns jsonb
language plpgsql security definer set search_path = public, gk, pg_temp as $fn$
declare nm text := gk.txt(b, 'name', 80); id int;
begin
  perform gk.need(u, array['admin']);
  if nm = '' then raise exception 'اسم المبنى مطلوب'; end if;
  begin
    if bid is null then
      insert into public.buildings (name, sort) values (nm, (select coalesce(max(sort), 0) + 1 from public.buildings)) returning buildings.id into id;
      perform gk.audit(u, 'create', 'building', id, jsonb_build_object('name', nm)); return jsonb_build_object('id', id);
    end if;
    update public.buildings set name = nm where buildings.id = bid;
    perform gk.audit(u, 'update', 'building', bid, jsonb_build_object('name', nm)); return jsonb_build_object('ok', true);
  exception when unique_violation then raise exception 'اسم المبنى مستخدم مسبقاً';
  end;
end $fn$;

create or replace function gk.building_delete(u public.profiles, bid int) returns jsonb
language plpgsql security definer set search_path = public, gk, pg_temp as $fn$
begin
  perform gk.need(u, array['admin']);
  if exists (select 1 from public.bookings b join public.rooms r on r.id = b.room_id join public.floors f on f.id = r.floor_id where f.building_id = bid) then
    raise exception 'لا يمكن حذف مبنى به حجوزات. انقل الحجوزات أولاً';
  end if;
  delete from public.buildings where id = bid;
  perform gk.audit(u, 'delete', 'building', bid); return jsonb_build_object('ok', true);
end $fn$;

create or replace function gk.floor_save(u public.profiles, fid int, b jsonb) returns jsonb
language plpgsql security definer set search_path = public, gk, pg_temp as $fn$
declare nm text := gk.txt(b, 'name', 80); bid int := gk.int_or(b ->> 'building_id', 0); id int;
begin
  perform gk.need(u, array['admin']);
  begin
    if fid is null then
      if nm = '' or not exists (select 1 from public.buildings where buildings.id = bid) then raise exception 'اسم الدور والمبنى مطلوبان'; end if;
      insert into public.floors (building_id, name, sort) values (bid, nm, (select coalesce(max(sort), 0) + 1 from public.floors where building_id = bid)) returning floors.id into id;
      perform gk.audit(u, 'create', 'floor', id, jsonb_build_object('name', nm, 'building_id', bid)); return jsonb_build_object('id', id);
    end if;
    if nm = '' then raise exception 'اسم الدور مطلوب'; end if;
    update public.floors set name = nm where floors.id = fid;
    perform gk.audit(u, 'update', 'floor', fid, jsonb_build_object('name', nm)); return jsonb_build_object('ok', true);
  exception when unique_violation then raise exception 'هذا الدور موجود في المبنى';
  end;
end $fn$;

create or replace function gk.floor_delete(u public.profiles, fid int) returns jsonb
language plpgsql security definer set search_path = public, gk, pg_temp as $fn$
begin
  perform gk.need(u, array['admin']);
  if exists (select 1 from public.bookings b join public.rooms r on r.id = b.room_id where r.floor_id = fid) then raise exception 'لا يمكن حذف دور به حجوزات'; end if;
  delete from public.floors where id = fid;
  perform gk.audit(u, 'delete', 'floor', fid); return jsonb_build_object('ok', true);
end $fn$;

-- صورة الكروكي: data URL مضغوطة من المتصفح (حد أقصى ≈ 2.5MB)
create or replace function gk.floor_plan_set(u public.profiles, fid int, b jsonb) returns jsonb
language plpgsql security definer set search_path = public, gk, pg_temp as $fn$
declare img text := coalesce(b ->> 'image', '');
begin
  perform gk.need(u, array['admin']);
  if not exists (select 1 from public.floors where id = fid) then perform gk.notfound(); end if;
  if img <> '' and img !~ '^data:image/(png|jpeg|webp);base64,[A-Za-z0-9+/=]+$' then raise exception 'الصيغ المدعومة: PNG أو JPG أو WEBP'; end if;
  if length(img) > 3500000 then raise exception 'الصورة كبيرة جداً'; end if;
  update public.floors set plan_image = nullif(img, '') where id = fid;
  perform gk.audit(u, 'update', 'floor', fid, jsonb_build_object('plan', case when img = '' then 'removed' else 'uploaded' end));
  return jsonb_build_object('ok', true);
end $fn$;

create or replace function gk.floor_plan_get(u public.profiles, fid int) returns jsonb
language plpgsql stable security definer set search_path = public, gk, pg_temp as $fn$
declare f public.floors;
begin
  perform gk.need(u, array['admin', 'event_manager', 'building_supervisor']);
  select * into f from public.floors where id = fid;
  if not found or coalesce(f.plan_image, '') = '' then perform gk.notfound('لا يوجد كروكي لهذا الدور'); end if;
  if u.role = 'building_supervisor' and not (fid = any (gk.my_floors(u.id))) then perform gk.forbid(); end if;
  return jsonb_build_object('image', f.plan_image);
end $fn$;

create or replace function gk.room_input(b jsonb) returns jsonb
language plpgsql immutable as $fn$
declare n text := gk.txt(b, 'number', 30); cap int := gk.int_or(b ->> 'capacity', -1);
begin
  if n = '' then raise exception 'رقم الغرفة مطلوب'; end if;
  if cap < 0 or cap > 200 then raise exception 'سعة الغرفة يجب أن تكون رقماً بين 0 و200'; end if;
  return jsonb_build_object('number', n, 'capacity', cap, 'status', case when b ->> 'status' = 'out_of_service' then 'out_of_service' else 'active' end,
    'notes', gk.txt(b, 'notes', 500), 'x', gk.pct(b ->> 'x', 2), 'y', gk.pct(b ->> 'y', 2), 'w', greatest(2, gk.pct(b ->> 'w', 14)), 'h', greatest(2, gk.pct(b ->> 'h', 14)));
end $fn$;

create or replace function gk.room_create(u public.profiles, b jsonb) returns jsonb
language plpgsql security definer set search_path = public, gk, pg_temp as $fn$
declare fid int := gk.int_or(b ->> 'floor_id', 0); o jsonb; id int;
begin
  perform gk.need(u, array['admin']);
  if not exists (select 1 from public.floors where floors.id = fid) then raise exception 'الدور غير موجود'; end if;
  o := gk.room_input(b);
  begin
    insert into public.rooms (floor_id, number, capacity, status, x, y, w, h, notes)
    values (fid, o ->> 'number', (o ->> 'capacity')::int, o ->> 'status', (o ->> 'x')::real, (o ->> 'y')::real, (o ->> 'w')::real, (o ->> 'h')::real, o ->> 'notes') returning rooms.id into id;
  exception when unique_violation then raise exception 'رقم الغرفة مستخدم في هذا الدور'; end;
  perform gk.audit(u, 'create', 'room', id, o || jsonb_build_object('floor_id', fid));
  return jsonb_build_object('id', id);
end $fn$;

create or replace function gk.room_update(u public.profiles, rid int, b jsonb) returns jsonb
language plpgsql security definer set search_path = public, gk, pg_temp as $fn$
declare old public.rooms; o jsonb;
begin
  perform gk.need(u, array['admin']);
  select * into old from public.rooms where id = rid;
  if not found then perform gk.notfound(); end if;
  o := gk.room_input(to_jsonb(old) || b);
  begin
    update public.rooms set number = o ->> 'number', capacity = (o ->> 'capacity')::int, status = o ->> 'status', x = (o ->> 'x')::real, y = (o ->> 'y')::real,
      w = (o ->> 'w')::real, h = (o ->> 'h')::real, notes = o ->> 'notes' where id = rid;   -- مشغّل rooms_guard يمنع الخفض تحت الحجوزات
  exception when unique_violation then raise exception 'رقم الغرفة مستخدم في هذا الدور'; end;
  perform gk.audit(u, 'update', 'room', rid, gk.diff(to_jsonb(old), o, array['number', 'capacity', 'status', 'notes']));
  return jsonb_build_object('ok', true);
end $fn$;

create or replace function gk.floor_layout(u public.profiles, fid int, b jsonb) returns jsonb
language plpgsql security definer set search_path = public, gk, pg_temp as $fn$
declare r jsonb; n int := 0;
begin
  perform gk.need(u, array['admin']);
  for r in select * from jsonb_array_elements(case when jsonb_typeof(b -> 'rooms') = 'array' then b -> 'rooms' else '[]'::jsonb end) loop
    update public.rooms set x = gk.pct(r ->> 'x', 2), y = gk.pct(r ->> 'y', 2), w = greatest(2, gk.pct(r ->> 'w', 14)), h = greatest(2, gk.pct(r ->> 'h', 14))
      where id = gk.int_or(r ->> 'id', 0) and floor_id = fid;
    n := n + 1;
  end loop;
  perform gk.audit(u, 'update', 'floor', fid, jsonb_build_object('layout', n || ' rooms'));
  return jsonb_build_object('ok', true);
end $fn$;

create or replace function gk.room_delete(u public.profiles, rid int) returns jsonb
language plpgsql security definer set search_path = public, gk, pg_temp as $fn$
begin
  perform gk.need(u, array['admin']);
  if exists (select 1 from public.bookings where room_id = rid) then raise exception 'لا يمكن حذف غرفة بها حجوزات. انقل الحجوزات أو أخرج الغرفة من الخدمة'; end if;
  delete from public.rooms where id = rid;
  perform gk.audit(u, 'delete', 'room', rid); return jsonb_build_object('ok', true);
end $fn$;

-- ================= التسكين =================
create or replace function gk.floor_guard(u public.profiles, floor_id int) returns void
language plpgsql stable security definer set search_path = public, gk, pg_temp as $fn$
begin
  if u.role = 'building_supervisor' and not (floor_id = any (gk.my_floors(u.id))) then perform gk.forbid('هذه الغرفة ليست ضمن الأدوار المسؤول عنها'); end if;
end $fn$;

create or replace function gk.add_booking(u public.profiles, ev public.events, r public.rooms, v public.visitors, f text, t text, notes text) returns int
language plpgsql security definer set search_path = public, gk, pg_temp as $fn$
declare id int; ff text := coalesce(nullif(f, ''), nullif(v.arrival_date, '')); tt text := coalesce(nullif(t, ''), nullif(v.departure_date, ''));
begin
  if ff is null or tt is null then raise exception 'الزائر «%» ليس له تاريخ وصول/مغادرة كاملان. أكملهما أو حدد فترة الحجز', v.full_name; end if;
  insert into public.bookings (event_id, visitor_id, room_id, from_date, to_date, notes, created_by, updated_by)   -- مشغّل bookings_guard يفحص السعة والتعارض
  values (ev.id, v.id, r.id, ff, tt, left(coalesce(notes, ''), 500), u.username, u.username) returning bookings.id into id;
  perform gk.audit(u, 'create', 'booking', id, jsonb_build_object('visitor', v.full_name, 'room', gk.room_label(r.id), 'from', ff, 'to', tt), ev.id, v.country_id);
  return id;
end $fn$;

create or replace function gk.visitor_for(u public.profiles, vid int, eid int) returns public.visitors
language plpgsql stable security definer set search_path = public, gk, pg_temp as $fn$
declare v public.visitors;
begin
  select * into v from public.visitors where id = vid and event_id = eid;
  if not found or not gk.can_see(u.role, gk.my_countries(u.id), gk.my_floors(u.id), v.id, v.country_id) then raise exception 'الزائر غير موجود في هذه المناسبة'; end if;
  return v;
end $fn$;

create or replace function gk.booking_create(u public.profiles, b jsonb) returns jsonb
language plpgsql security definer set search_path = public, gk, pg_temp as $fn$
declare ev public.events := gk.get_event(gk.int_or(b ->> 'event_id', 0)); r public.rooms; v public.visitors;
begin
  perform gk.need(u, array['admin', 'event_manager', 'building_supervisor']);
  select * into r from public.rooms where id = gk.int_or(b ->> 'room_id', 0);
  if not found then raise exception 'الغرفة غير موجودة'; end if;
  perform gk.floor_guard(u, r.floor_id);
  v := gk.visitor_for(u, gk.int_or(b ->> 'visitor_id', 0), ev.id);
  return jsonb_build_object('id', gk.add_booking(u, ev, r, v, b ->> 'from_date', b ->> 'to_date', b ->> 'notes'));
end $fn$;

create or replace function gk.booking_bulk(u public.profiles, b jsonb) returns jsonb
language plpgsql security definer set search_path = public, gk, pg_temp as $fn$
declare ev public.events := gk.get_event(gk.int_or(b ->> 'event_id', 0)); r public.rooms; ids int[]; i int; n int := 0;
begin
  perform gk.need(u, array['admin', 'event_manager', 'building_supervisor']);
  select * into r from public.rooms where id = gk.int_or(b ->> 'room_id', 0);
  if not found then raise exception 'الغرفة غير موجودة'; end if;
  perform gk.floor_guard(u, r.floor_id);
  select coalesce(array_agg(distinct gk.int_or(e, 0)), '{}') into ids from jsonb_array_elements_text(case when jsonb_typeof(b -> 'visitor_ids') = 'array' then b -> 'visitor_ids' else '[]'::jsonb end) e;
  ids := array_remove(ids, 0);
  if cardinality(ids) = 0 then raise exception 'اختر زائراً واحداً على الأقل'; end if;
  foreach i in array ids loop
    perform gk.add_booking(u, ev, r, gk.visitor_for(u, i, ev.id), b ->> 'from_date', b ->> 'to_date', b ->> 'notes'); n := n + 1;
  end loop;
  return jsonb_build_object('count', n);   -- ذرّي: أي خطأ يلغي العملية كلها
end $fn$;

create or replace function gk.booking_update(u public.profiles, bid int, b jsonb) returns jsonb
language plpgsql security definer set search_path = public, gk, pg_temp as $fn$
declare old public.bookings; oldr public.rooms; r public.rooms; v public.visitors; f text; t text;
begin
  perform gk.need(u, array['admin', 'event_manager', 'building_supervisor']);
  select * into old from public.bookings where id = bid;
  if not found then perform gk.notfound(); end if;
  select * into oldr from public.rooms where id = old.room_id; perform gk.floor_guard(u, oldr.floor_id);
  if nullif(b ->> 'room_id', '') is not null then select * into r from public.rooms where id = gk.int_or(b ->> 'room_id', 0); else r := oldr; end if;
  if r.id is null then raise exception 'الغرفة غير موجودة'; end if;
  perform gk.floor_guard(u, r.floor_id);
  select * into v from public.visitors where id = old.visitor_id;
  f := coalesce(nullif(b ->> 'from_date', ''), old.from_date); t := coalesce(nullif(b ->> 'to_date', ''), old.to_date);
  update public.bookings set room_id = r.id, from_date = f, to_date = t, notes = case when b ? 'notes' then gk.txt(b, 'notes', 500) else old.notes end, updated_by = u.username, updated_at = now() where id = old.id;
  perform gk.audit(u, case when r.id <> old.room_id then 'transfer' else 'update' end, 'booking', old.id,
    jsonb_build_object('visitor', v.full_name, 'from_room', gk.room_label(oldr.id), 'to_room', gk.room_label(r.id), 'from', f, 'to', t), old.event_id, v.country_id);
  return jsonb_build_object('ok', true);
end $fn$;

create or replace function gk.booking_delete(u public.profiles, bid int) returns jsonb
language plpgsql security definer set search_path = public, gk, pg_temp as $fn$
declare old public.bookings; r public.rooms; v public.visitors;
begin
  perform gk.need(u, array['admin', 'event_manager', 'building_supervisor']);
  select * into old from public.bookings where id = bid;
  if not found then perform gk.notfound(); end if;
  select * into r from public.rooms where id = old.room_id; perform gk.floor_guard(u, r.floor_id);
  select * into v from public.visitors where id = old.visitor_id;
  delete from public.bookings where id = old.id;
  perform gk.audit(u, 'delete', 'booking', old.id, jsonb_build_object('visitor', v.full_name, 'room', gk.room_label(r.id), 'from', old.from_date, 'to', old.to_date), old.event_id, v.country_id);
  return jsonb_build_object('ok', true);
end $fn$;

create or replace function gk.occupancy(u public.profiles, q jsonb) returns jsonb
language plpgsql stable security definer set search_path = public, gk, pg_temp as $fn$
declare d text := case when gk.is_date(q ->> 'date') then q ->> 'date' else to_char(now(), 'YYYY-MM-DD') end; f public.floors; bn text; rooms jsonb; sup jsonb;
begin
  perform gk.need(u, array['admin', 'event_manager', 'building_supervisor']);
  select * into f from public.floors where id = gk.int_or(q ->> 'floor_id', 0);
  if not found then perform gk.notfound('الدور غير موجود'); end if;
  if u.role = 'building_supervisor' and not (f.id = any (gk.my_floors(u.id))) then perform gk.forbid(); end if;
  select name into bn from public.buildings where id = f.building_id;
  select coalesce(jsonb_agg(
      to_jsonb(r) || jsonb_build_object('occupants', occ, 'booked', jsonb_array_length(occ),
        'remaining', case when r.status = 'active' then greatest(0, r.capacity - jsonb_array_length(occ)) else 0 end,
        'state', gk.room_state(r.status, r.capacity, jsonb_array_length(occ)))
      order by (case when r.number ~ '^\d+$' then r.number::int end), r.number), '[]'::jsonb) into rooms
  from public.rooms r,
  lateral (select coalesce(jsonb_agg(jsonb_build_object('booking_id', b.id, 'room_id', b.room_id, 'from_date', b.from_date, 'to_date', b.to_date, 'notes', b.notes,
        'visitor_id', v.id, 'full_name', v.full_name, 'category', v.category, 'country_name', c.name, 'event_name', e.name, 'arrival_date', v.arrival_date, 'departure_date', v.departure_date) order by v.full_name), '[]'::jsonb) occ
    from public.bookings b join public.visitors v on v.id = b.visitor_id join public.countries c on c.id = v.country_id join public.events e on e.id = b.event_id
    where b.room_id = r.id and b.from_date <= d and b.to_date > d) o
  where r.floor_id = f.id;
  select coalesce(jsonb_agg(jsonb_build_object('name', p.name, 'phone', p.phone)), '[]'::jsonb) into sup
    from public.user_floors uf join public.profiles p on p.id = uf.user_id where uf.floor_id = f.id and p.status = 'active';
  return jsonb_build_object('floor', jsonb_build_object('id', f.id, 'name', f.name, 'building_name', bn, 'has_plan', coalesce(f.plan_image, '') <> '', 'supervisors', sup), 'date', d, 'rooms', rooms);
end $fn$;

create or replace function gk.room_bookings(u public.profiles, rid int) returns jsonb
language plpgsql stable security definer set search_path = public, gk, pg_temp as $fn$
declare r public.rooms;
begin
  perform gk.need(u, array['admin', 'event_manager', 'building_supervisor']);
  select * into r from public.rooms where id = rid;
  if not found then perform gk.notfound(); end if;
  perform gk.floor_guard(u, r.floor_id);
  return jsonb_build_object('room', to_jsonb(r), 'bookings', coalesce((select jsonb_agg(to_jsonb(b) || jsonb_build_object('full_name', v.full_name, 'country_name', c.name, 'event_name', e.name) order by b.from_date, v.full_name)
    from public.bookings b join public.visitors v on v.id = b.visitor_id join public.countries c on c.id = v.country_id join public.events e on e.id = b.event_id where b.room_id = r.id), '[]'::jsonb));
end $fn$;

-- إحصاءات الغرف في تاريخ معين (للوحة التحكم)، محصورة بأدوار مشرف المبنى
create or replace function gk.room_stats(u public.profiles, q jsonb) returns jsonb
language plpgsql stable security definer set search_path = public, gk, pg_temp as $fn$
declare d text := case when gk.is_date(q ->> 'date') then q ->> 'date' else to_char(now(), 'YYYY-MM-DD') end; fl int[] := gk.my_floors(u.id);
begin
  return jsonb_build_object('rooms', coalesce((select jsonb_agg(jsonb_build_object('id', r.id, 'capacity', r.capacity, 'status', r.status, 'building_id', f.building_id, 'building_name', bl.name, 'floor_id', f.id,
      'booked', (select count(*) from public.bookings b where b.room_id = r.id and b.from_date <= d and b.to_date > d)))
    from public.rooms r join public.floors f on f.id = r.floor_id join public.buildings bl on bl.id = f.building_id
    where u.role <> 'building_supervisor' or f.id = any (fl)), '[]'::jsonb));
end $fn$;

-- كل الحجوزات في مناسبة (للتقارير) محصورة بصلاحية رؤية الزائر
create or replace function gk.bookings_list(u public.profiles, q jsonb) returns jsonb
language plpgsql stable security definer set search_path = public, gk, pg_temp as $fn$
declare ev public.events := gk.get_event(gk.int_or(q ->> 'event_id', 0)); cs int[] := gk.my_countries(u.id); fl int[] := gk.my_floors(u.id);
begin
  return jsonb_build_object('bookings', coalesce((select jsonb_agg(jsonb_build_object('id', b.id, 'visitor_id', v.id, 'full_name', v.full_name, 'country_name', c.name, 'room_id', r.id, 'room_number', r.number,
      'floor_id', f.id, 'floor_name', f.name, 'building_id', bl.id, 'building_name', bl.name, 'from_date', b.from_date, 'to_date', b.to_date) order by bl.sort, f.sort, r.number, v.full_name)
    from public.bookings b join public.visitors v on v.id = b.visitor_id join public.countries c on c.id = v.country_id
      join public.rooms r on r.id = b.room_id join public.floors f on f.id = r.floor_id join public.buildings bl on bl.id = f.building_id
    where b.event_id = ev.id and gk.can_see(u.role, cs, fl, v.id, v.country_id)
      and (u.role <> 'building_supervisor' or f.id = any (fl))), '[]'::jsonb));
end $fn$;

-- ================= السائقون والنقل =================
create or replace function gk.drivers_list(u public.profiles, q jsonb) returns jsonb
language plpgsql stable security definer set search_path = public, gk, pg_temp as $fn$
declare ev public.events := gk.get_event(gk.int_or(q ->> 'event_id', 0));
begin
  perform gk.need(u, array['admin', 'event_manager', 'transport']);
  return jsonb_build_object('drivers', coalesce((select jsonb_agg(to_jsonb(d) order by d.name) from public.drivers d where d.event_id = ev.id), '[]'::jsonb));
end $fn$;

create or replace function gk.driver_input(b jsonb) returns jsonb
language plpgsql immutable as $fn$
declare nm text := gk.txt(b, 'name', 100);
begin
  if nm = '' then raise exception 'اسم السائق مطلوب'; end if;
  return jsonb_build_object('name', nm, 'phone', gk.txt(b, 'phone', 30), 'car_number', gk.txt(b, 'car_number', 30), 'car_type', gk.txt(b, 'car_type', 60),
    'capacity', least(80, greatest(1, gk.int_or(b ->> 'capacity', 4))), 'notes', gk.txt(b, 'notes', 500));
end $fn$;

create or replace function gk.driver_create(u public.profiles, b jsonb) returns jsonb
language plpgsql security definer set search_path = public, gk, pg_temp as $fn$
declare ev public.events := gk.get_event(gk.int_or(b ->> 'event_id', 0)); o jsonb := gk.driver_input(b); id int;
begin
  perform gk.need(u, array['admin', 'event_manager', 'transport']);
  insert into public.drivers (event_id, name, phone, car_number, car_type, capacity, notes)
  values (ev.id, o ->> 'name', o ->> 'phone', o ->> 'car_number', o ->> 'car_type', (o ->> 'capacity')::int, o ->> 'notes') returning drivers.id into id;
  perform gk.audit(u, 'create', 'driver', id, o, ev.id); return jsonb_build_object('id', id);
end $fn$;

create or replace function gk.driver_update(u public.profiles, did int, b jsonb) returns jsonb
language plpgsql security definer set search_path = public, gk, pg_temp as $fn$
declare old public.drivers; o jsonb;
begin
  perform gk.need(u, array['admin', 'event_manager', 'transport']);
  select * into old from public.drivers where id = did; if not found then perform gk.notfound(); end if;
  o := gk.driver_input(to_jsonb(old) || b);
  update public.drivers set name = o ->> 'name', phone = o ->> 'phone', car_number = o ->> 'car_number', car_type = o ->> 'car_type', capacity = (o ->> 'capacity')::int, notes = o ->> 'notes' where id = did;
  perform gk.audit(u, 'update', 'driver', did, gk.diff(to_jsonb(old), o, array['name', 'phone', 'car_number', 'car_type', 'capacity', 'notes']), old.event_id);
  return jsonb_build_object('ok', true);
end $fn$;

create or replace function gk.driver_delete(u public.profiles, did int, b jsonb) returns jsonb
language plpgsql security definer set search_path = public, gk, pg_temp as $fn$
declare old public.drivers;
begin
  perform gk.need(u, array['admin', 'event_manager', 'transport']);
  select * into old from public.drivers where id = did; if not found then perform gk.notfound(); end if;
  if exists (select 1 from public.transports where driver_id = did) and not gk.truthy(b, 'force') then
    return jsonb_build_object('_status', 409, 'error', 'للسائق مهام مسجلة. الحذف سيحذفها أيضاً', 'code', 'confirm');
  end if;
  delete from public.drivers where id = did;
  perform gk.audit(u, 'delete', 'driver', did, jsonb_build_object('name', old.name), old.event_id);
  return jsonb_build_object('ok', true);
end $fn$;

create or replace function gk.passengers_for(v public.visitors, gid int) returns int
language plpgsql stable security definer set search_path = public, pg_temp as $fn$
declare g public.groups_; reg int;
begin
  if gid is not null then
    select * into g from public.groups_ where id = gid; select count(*) into reg from public.visitors where group_id = gid;
    return greatest(coalesce(g.members_count, 0), reg, 1);
  end if;
  if v.id is not null and v.category = 'family_head' then return 1 + (select count(*) from public.visitors where head_id = v.id)::int; end if;
  return 1;
end $fn$;

create or replace function gk.transport_input(b jsonb, ev public.events) returns jsonb
language plpgsql stable security definer set search_path = public, gk, pg_temp as $fn$
declare drv public.drivers; v public.visitors; g public.groups_; gid int; kind text := case when b ->> 'kind' = 'dropoff' then 'dropoff' else 'pickup' end; d text; t text; st text; pax int;
  base_arr text; base_dep text; base_time text := ''; ap text := ''; fi text := '';
begin
  select * into drv from public.drivers where id = gk.int_or(b ->> 'driver_id', 0) and event_id = ev.id;
  if not found then raise exception 'اختر السائق'; end if;
  if nullif(b ->> 'visitor_id', '') is not null then
    select * into v from public.visitors where id = gk.int_or(b ->> 'visitor_id', 0) and event_id = ev.id;
    if not found then raise exception 'الزائر غير موجود'; end if;
    base_arr := v.arrival_date; base_dep := v.departure_date; base_time := v.arrival_time; ap := v.airport; fi := btrim(v.airline || ' ' || v.flight_no);
  elsif nullif(b ->> 'group_id', '') is not null then
    select * into g from public.groups_ where id = gk.int_or(b ->> 'group_id', 0) and event_id = ev.id;
    if not found then raise exception 'الفوج غير موجود'; end if;
    gid := g.id; base_arr := g.arrival_date; base_dep := g.departure_date;
  else raise exception 'اختر الزائر أو الفوج المكلف بنقله'; end if;
  d := coalesce(nullif(gk.txt(b, 'task_date', 10), ''), case when kind = 'pickup' then base_arr else base_dep end);
  if not gk.is_date(d) then raise exception 'تاريخ المهمة مطلوب'; end if;
  t := coalesce(nullif(gk.txt(b, 'task_time', 5), ''), case when kind = 'pickup' and v.id is not null then base_time else '' end);
  if t <> '' and not gk.is_time(t) then raise exception 'الوقت غير صحيح'; end if;
  st := case when b ->> 'status' in ('not_started', 'on_the_way', 'received', 'done') then b ->> 'status' else 'not_started' end;
  pax := greatest(1, coalesce(nullif(gk.int_or(b ->> 'passengers', 0), 0), gk.passengers_for(v, gid)));
  return jsonb_build_object('driver_id', drv.id, 'driver_capacity', drv.capacity, 'driver_name', drv.name, 'visitor_id', v.id, 'group_id', gid, 'kind', kind, 'task_date', d, 'task_time', t,
    'airport', coalesce(nullif(gk.txt(b, 'airport', 80), ''), ap), 'flight_info', coalesce(nullif(gk.txt(b, 'flight_info', 120), ''), fi), 'passengers', pax, 'status', st, 'notes', gk.txt(b, 'notes', 500));
end $fn$;

create or replace function gk.transport_warn(o jsonb) returns text
language sql immutable as $fn$
  select case when (o ->> 'passengers')::int > (o ->> 'driver_capacity')::int
    then format('عدد الركاب (%s) أكبر من سعة السيارة (%s). أضف سيارة أخرى للفوج', o ->> 'passengers', o ->> 'driver_capacity') end $fn$;

create or replace function gk.transport_create(u public.profiles, b jsonb) returns jsonb
language plpgsql security definer set search_path = public, gk, pg_temp as $fn$
declare ev public.events := gk.get_event(gk.int_or(b ->> 'event_id', 0)); o jsonb; id int;
begin
  perform gk.need(u, array['admin', 'event_manager', 'transport']);
  o := gk.transport_input(b, ev);
  insert into public.transports (event_id, driver_id, visitor_id, group_id, kind, task_date, task_time, airport, flight_info, passengers, status, notes, created_by, updated_by)
  values (ev.id, (o ->> 'driver_id')::int, nullif(o ->> 'visitor_id', '')::int, nullif(o ->> 'group_id', '')::int, o ->> 'kind', o ->> 'task_date', o ->> 'task_time', o ->> 'airport', o ->> 'flight_info',
    (o ->> 'passengers')::int, o ->> 'status', o ->> 'notes', u.username, u.username) returning transports.id into id;
  perform gk.audit(u, 'create', 'transport', id, jsonb_build_object('driver', o ->> 'driver_name', 'date', o ->> 'task_date', 'passengers', (o ->> 'passengers')::int), ev.id);
  return jsonb_build_object('id', id, 'warning', gk.transport_warn(o));
end $fn$;

create or replace function gk.transport_update(u public.profiles, tid int, b jsonb) returns jsonb
language plpgsql security definer set search_path = public, gk, pg_temp as $fn$
declare old public.transports; ev public.events; o jsonb;
begin
  perform gk.need(u, array['admin', 'event_manager', 'transport']);
  select * into old from public.transports where id = tid; if not found then perform gk.notfound(); end if;
  ev := gk.get_event(old.event_id);
  o := gk.transport_input(to_jsonb(old) || b || jsonb_build_object('passengers', coalesce(b ->> 'passengers', old.passengers::text)), ev);
  update public.transports set driver_id = (o ->> 'driver_id')::int, visitor_id = nullif(o ->> 'visitor_id', '')::int, group_id = nullif(o ->> 'group_id', '')::int, kind = o ->> 'kind',
    task_date = o ->> 'task_date', task_time = o ->> 'task_time', airport = o ->> 'airport', flight_info = o ->> 'flight_info', passengers = (o ->> 'passengers')::int,
    status = o ->> 'status', notes = o ->> 'notes', updated_by = u.username, updated_at = now() where id = tid;
  perform gk.audit(u, 'update', 'transport', tid, gk.diff(to_jsonb(old), o, array['driver_id', 'task_date', 'task_time', 'passengers', 'status', 'notes', 'airport']), ev.id);
  return jsonb_build_object('ok', true, 'warning', gk.transport_warn(o));
end $fn$;

create or replace function gk.transport_delete(u public.profiles, tid int) returns jsonb
language plpgsql security definer set search_path = public, gk, pg_temp as $fn$
declare old public.transports;
begin
  perform gk.need(u, array['admin', 'event_manager', 'transport']);
  select * into old from public.transports where id = tid; if not found then perform gk.notfound(); end if;
  delete from public.transports where id = tid;
  perform gk.audit(u, 'delete', 'transport', tid, jsonb_build_object('date', old.task_date), old.event_id);
  return jsonb_build_object('ok', true);
end $fn$;

create or replace function gk.transports_list(u public.profiles, q jsonb) returns jsonb
language plpgsql stable security definer set search_path = public, gk, pg_temp as $fn$
declare ev public.events := gk.get_event(gk.int_or(q ->> 'event_id', 0));
begin
  perform gk.need(u, array['admin', 'event_manager', 'transport']);
  return jsonb_build_object('tasks', coalesce((select jsonb_agg(to_jsonb(t) || jsonb_build_object('driver_name', d.name, 'driver_phone', d.phone, 'car_number', d.car_number, 'car_type', d.car_type,
      'car_capacity', d.capacity, 'visitor_name', v.full_name, 'group_name', g.name, 'country_name', c.name) order by t.task_date, t.task_time, d.name)
    from public.transports t join public.drivers d on d.id = t.driver_id left join public.visitors v on v.id = t.visitor_id left join public.groups_ g on g.id = t.group_id
      left join public.countries c on c.id = coalesce(v.country_id, g.country_id)
    where t.event_id = ev.id and (not gk.is_date(q ->> 'date') or t.task_date = q ->> 'date')), '[]'::jsonb),
    'drivers', coalesce((select jsonb_agg(to_jsonb(d)) from public.drivers d where d.event_id = ev.id), '[]'::jsonb));
end $fn$;

-- ================= الوجبات =================
create or replace function gk.exclusions_list(u public.profiles, q jsonb) returns jsonb
language plpgsql stable security definer set search_path = public, gk, pg_temp as $fn$
declare ev public.events := gk.get_event(gk.int_or(q ->> 'event_id', 0));
begin
  perform gk.need(u, array['admin', 'event_manager', 'catering']);
  return jsonb_build_object('exclusions', coalesce((select jsonb_agg(jsonb_build_object('visitor_id', me.visitor_id, 'date', me.date, 'meal', me.meal))
    from public.meal_exclusions me join public.visitors v on v.id = me.visitor_id where v.event_id = ev.id), '[]'::jsonb));
end $fn$;

create or replace function gk.meal_exclusion_set(u public.profiles, b jsonb) returns jsonb
language plpgsql security definer set search_path = public, gk, pg_temp as $fn$
declare v public.visitors; d text; ms text[]; m text; ex boolean := coalesce(b ->> 'excluded', 'true') not in ('false', '0'); ar text[] := '{}';
begin
  perform gk.need(u, array['admin', 'event_manager', 'catering']);
  select * into v from public.visitors where id = gk.int_or(b ->> 'visitor_id', 0);
  if not found then perform gk.notfound('الزائر غير موجود'); end if;
  d := case when b ->> 'date' = '*' then '*' else gk.txt(b, 'date', 10) end;
  if d <> '*' and not gk.is_date(d) then raise exception 'التاريخ غير صحيح'; end if;
  select coalesce(array_agg(x), '{}') into ms from (select jsonb_array_elements_text(case when jsonb_typeof(b -> 'meals') = 'array' then b -> 'meals' else jsonb_build_array(b ->> 'meal') end) x) t
    where x in ('breakfast', 'lunch', 'dinner');
  if cardinality(ms) = 0 then raise exception 'اختر وجبة'; end if;
  foreach m in array ms loop
    if ex then insert into public.meal_exclusions (visitor_id, date, meal) values (v.id, d, m) on conflict do nothing;
    else delete from public.meal_exclusions where visitor_id = v.id and date = d and meal = m; end if;
    ar := ar || case m when 'breakfast' then 'الإفطار' when 'lunch' then 'الغداء' else 'العشاء' end;
  end loop;
  perform gk.audit(u, case when ex then 'meal_exclude' else 'meal_include' end, 'visitor', v.id, jsonb_build_object('visitor', v.full_name, 'date', d, 'meals', to_jsonb(ar)), v.event_id, v.country_id);
  return jsonb_build_object('ok', true);
end $fn$;

-- ================= سجل العمليات والنسخ =================
create or replace function gk.audit_list(u public.profiles, q jsonb) returns jsonb
language plpgsql stable security definer set search_path = public, gk, pg_temp as $fn$
begin
  perform gk.need(u, array['admin']);
  return jsonb_build_object('rows', coalesce((select jsonb_agg(x order by (x ->> 'id')::bigint desc) from (
    select to_jsonb(a) || jsonb_build_object('country_name', c.name, 'at', to_char(a.at at time zone 'UTC', 'YYYY-MM-DD HH24:MI:SS')) x
    from public.audit_log a left join public.countries c on c.id = a.country_id
    where (nullif(q ->> 'username', '') is null or a.username = q ->> 'username')
      and (nullif(q ->> 'entity', '') is null or a.entity = q ->> 'entity')
      and (nullif(q ->> 'action', '') is null or a.action = q ->> 'action')
      and (nullif(q ->> 'country_id', '') is null or a.country_id = gk.int_or(q ->> 'country_id', 0))
      and (nullif(q ->> 'from', '') is null or a.at >= (q ->> 'from')::date)
      and (nullif(q ->> 'to', '') is null or a.at < (q ->> 'to')::date + 1)
    order by a.id desc limit least(1000, gk.int_or(q ->> 'limit', 300))) s), '[]'::jsonb));
end $fn$;

-- نسخة احتياطية كاملة (JSON) يحمّلها المدير؛ بالإضافة إلى نسخ Supabase التلقائية
create or replace function gk.backup_export(u public.profiles) returns jsonb
language plpgsql security definer set search_path = public, gk, pg_temp as $fn$
declare res jsonb := jsonb_build_object('app', 'gaouk', 'version', 2, 'exported_at', now()); t text;
begin
  perform gk.need(u, array['admin']);
  foreach t in array array['countries', 'events', 'buildings', 'floors', 'rooms', 'groups_', 'visitors', 'bookings', 'drivers', 'transports', 'meal_exclusions'] loop
    execute format('select $1 || jsonb_build_object(%L, coalesce((select jsonb_agg(to_jsonb(x)) from public.%I x), ''[]''::jsonb))', t, t) into res using res;
  end loop;
  res := res || jsonb_build_object('profiles', (select coalesce(jsonb_agg(to_jsonb(p) - 'auth_id'), '[]'::jsonb) from public.profiles p),
    'user_countries', (select coalesce(jsonb_agg(to_jsonb(x)), '[]'::jsonb) from public.user_countries x), 'user_floors', (select coalesce(jsonb_agg(to_jsonb(x)), '[]'::jsonb) from public.user_floors x));
  perform gk.audit(u, 'backup', 'system', null, jsonb_build_object('format', 'json'));
  return res;
end $fn$;

-- ============ 0005_api.sql ============
-- «جاؤوك» — نقطة الدخول الوحيدة للواجهة: public.api(method, path, query, body)
-- كل طلب يُفحص فيه: الجلسة، الحساب غير موقوف، الدور، ونطاق الدولة/الأدوار. الجداول نفسها مغلقة.

-- بوابة الأدوار الأولى (قبل أي قراءة): تضمن رد 403 للدور غير المصرّح قبل أي تحقق آخر
create or replace function gk.role_gate(key text, role text) returns void
language plpgsql immutable as $fn$
declare allowed text[];
begin
  allowed := case
    when key ~ '^(GET|POST|PUT|DELETE) /(bookings|occupancy|rooms/:id/bookings)' then array['admin', 'event_manager', 'building_supervisor']
    when key = 'GET /room-stats' then array['admin', 'event_manager', 'building_supervisor']
    when key ~ '^(GET|POST|PUT|DELETE) /(drivers|transports)' then array['admin', 'event_manager', 'transport']
    when key ~ '^(GET|POST) /(exclusions|meal-exclusions)' then array['admin', 'event_manager', 'catering']
    when key in ('POST /visitors', 'PUT /visitors/:id', 'DELETE /visitors/:id', 'POST /visitors/check-duplicate', 'POST /visitors-import', 'POST /groups', 'PUT /groups/:id', 'DELETE /groups/:id')
      then array['admin', 'event_manager', 'country_supervisor']
    when key in ('GET /audit', 'POST /backup', 'POST /countries', 'PUT /countries/:id', 'DELETE /countries/:id', 'POST /users', 'PUT /users/:id', 'DELETE /users/:id', 'POST /buildings', 'PUT /buildings/:id',
      'DELETE /buildings/:id', 'POST /floors', 'PUT /floors/:id', 'DELETE /floors/:id', 'PUT /floors/:id/plan', 'PUT /floors/:id/layout', 'POST /rooms', 'PUT /rooms/:id', 'DELETE /rooms/:id', 'DELETE /events/:id') then array['admin']
    when key in ('GET /users', 'POST /events', 'PUT /events/:id', 'GET /structure') then array['admin', 'event_manager'] || case when key = 'GET /structure' then array['building_supervisor'] else array[]::text[] end
    else null end;
  if allowed is not null and not (role = any (allowed)) then raise exception 'لا تملك صلاحية لتنفيذ هذا الإجراء' using errcode = 'PT403'; end if;
end $fn$;

create or replace function public.api(p_method text, p_path text, p_query jsonb default '{}'::jsonb, p_body jsonb default '{}'::jsonb) returns jsonb
language plpgsql security definer set search_path = public, gk, extensions, pg_temp as $fn$
declare u public.profiles; seg text[]; key text; n1 int; n2 int; q jsonb := coalesce(p_query, '{}'::jsonb); b jsonb := coalesce(p_body, '{}'::jsonb); m text := upper(p_method);
begin
  u := gk.cur();
  seg := string_to_array(trim(both '/' from p_path), '/');
  select string_agg(case when s ~ '^\d+$' then ':id' else s end, '/') into key from unnest(seg) s;
  key := m || ' /' || key;
  n1 := case when seg[2] ~ '^\d+$' then seg[2]::int end;
  if key like 'GET /reports/%' then key := 'GET /reports'; end if;
  perform gk.role_gate(key, u.role);
  return case key
    when 'GET /me' then gk.me(u)
    when 'GET /countries' then gk.countries_list(u)
    when 'POST /countries' then gk.country_save(u, null, b)
    when 'PUT /countries/:id' then gk.country_save(u, n1, b)
    when 'DELETE /countries/:id' then gk.country_delete(u, n1)
    when 'GET /events' then jsonb_build_object('events', coalesce((select jsonb_agg(to_jsonb(e) order by e.start_date desc) from public.events e), '[]'::jsonb))
    when 'POST /events' then gk.event_save(u, null, b)
    when 'PUT /events/:id' then gk.event_save(u, n1, b)
    when 'DELETE /events/:id' then gk.event_delete(u, n1, b)
    when 'GET /users' then gk.users_list(u)
    when 'POST /users' then gk.user_create(u, b)
    when 'PUT /users/:id' then gk.user_update(u, n1, b)
    when 'DELETE /users/:id' then gk.user_delete(u, n1)
    when 'GET /structure' then gk.structure(u)
    when 'POST /buildings' then gk.building_save(u, null, b)
    when 'PUT /buildings/:id' then gk.building_save(u, n1, b)
    when 'DELETE /buildings/:id' then gk.building_delete(u, n1)
    when 'POST /floors' then gk.floor_save(u, null, b)
    when 'PUT /floors/:id' then gk.floor_save(u, n1, b)
    when 'DELETE /floors/:id' then gk.floor_delete(u, n1)
    when 'GET /floors/:id/plan' then gk.floor_plan_get(u, n1)
    when 'PUT /floors/:id/plan' then gk.floor_plan_set(u, n1, b)
    when 'PUT /floors/:id/layout' then gk.floor_layout(u, n1, b)
    when 'POST /rooms' then gk.room_create(u, b)
    when 'PUT /rooms/:id' then gk.room_update(u, n1, b)
    when 'DELETE /rooms/:id' then gk.room_delete(u, n1)
    when 'GET /rooms/:id/bookings' then gk.room_bookings(u, n1)
    when 'GET /occupancy' then gk.occupancy(u, q)
    when 'GET /room-stats' then gk.room_stats(u, q)
    when 'GET /bookings' then gk.bookings_list(u, q)
    when 'POST /bookings' then gk.booking_create(u, b)
    when 'POST /bookings/bulk' then gk.booking_bulk(u, b)
    when 'PUT /bookings/:id' then gk.booking_update(u, n1, b)
    when 'DELETE /bookings/:id' then gk.booking_delete(u, n1)
    when 'GET /visitors' then jsonb_build_object('visitors', gk.visitors_list(u, q))
    when 'GET /visitors/:id' then gk.visitor_detail(u, n1)
    when 'POST /visitors' then gk.visitor_create(u, b)
    when 'PUT /visitors/:id' then gk.visitor_update(u, n1, b)
    when 'DELETE /visitors/:id' then gk.visitor_delete(u, n1)
    when 'POST /visitors/check-duplicate' then gk.check_duplicate(u, b)
    when 'POST /visitors-import' then gk.visitors_import(u, b)
    when 'GET /groups' then gk.groups_list(u, q)
    when 'POST /groups' then gk.group_create(u, b)
    when 'PUT /groups/:id' then gk.group_update(u, n1, b)
    when 'DELETE /groups/:id' then gk.group_delete(u, n1)
    when 'GET /drivers' then gk.drivers_list(u, q)
    when 'POST /drivers' then gk.driver_create(u, b)
    when 'PUT /drivers/:id' then gk.driver_update(u, n1, b)
    when 'DELETE /drivers/:id' then gk.driver_delete(u, n1, b)
    when 'GET /transports' then gk.transports_list(u, q)
    when 'POST /transports' then gk.transport_create(u, b)
    when 'PUT /transports/:id' then gk.transport_update(u, n1, b)
    when 'DELETE /transports/:id' then gk.transport_delete(u, n1)
    when 'GET /exclusions' then gk.exclusions_list(u, q)
    when 'POST /meal-exclusions' then gk.meal_exclusion_set(u, b)
    when 'GET /audit' then gk.audit_list(u, q)
    when 'POST /backup' then gk.backup_export(u)
    when 'POST /audit-event' then gk.audit_event(u, b)
    when 'GET /pulse' then jsonb_build_object('last', (select coalesce(max(id), 0) from public.audit_log))
    else (select gk.notfound('المسار غير موجود: ' || key)::text::jsonb)
  end;
end $fn$;

create or replace function gk.visitor_detail(u public.profiles, vid int) returns jsonb
language plpgsql stable security definer set search_path = public, gk, pg_temp as $fn$
declare v public.visitors := gk.visitor_get_scoped(u, vid); row jsonb;
begin
  select x into row from jsonb_array_elements(gk.visitors_list(u, jsonb_build_object('event_id', v.event_id))) x where (x ->> 'id')::int = v.id;
  row := row || jsonb_build_object(
    'members', coalesce((select jsonb_agg(jsonb_build_object('id', m.id, 'full_name', m.full_name, 'phone', m.phone, 'email', m.email, 'relation', m.relation, 'diet_notes', m.diet_notes, 'notes', m.notes) order by m.id)
      from public.visitors m where m.head_id = v.id), '[]'::jsonb),
    'exclusions', coalesce((select jsonb_agg(jsonb_build_object('date', e.date, 'meal', e.meal)) from public.meal_exclusions e where e.visitor_id = v.id), '[]'::jsonb));
  return jsonb_build_object('visitor', row);
end $fn$;

create or replace function gk.check_duplicate(u public.profiles, b jsonb) returns jsonb
language plpgsql stable security definer set search_path = public, gk, pg_temp as $fn$
declare ev public.events := gk.get_event(gk.int_or(b ->> 'event_id', 0)); ex int[] := '{}'; xid int := gk.int_or(b ->> 'exclude_id', 0);
begin
  perform gk.need(u, array['admin', 'event_manager', 'country_supervisor']);
  if xid > 0 then select array_agg(id) into ex from (select xid id union all select id from public.visitors where head_id = xid) t; end if;
  return jsonb_build_object('duplicates', case when coalesce(b ->> 'full_name', '') <> '' or coalesce(b ->> 'phone', '') <> ''
    then gk.find_dups(ev.id, u, jsonb_build_object('full_name', gk.txt(b, 'full_name'), 'phone', gk.txt(b, 'phone'), 'country_id', b ->> 'country_id'), coalesce(ex, '{}')) else '[]'::jsonb end);
end $fn$;

-- ===== الصلاحيات: الواجهة لا ترى إلا api =====
revoke all on function public.api(text, text, jsonb, jsonb) from public, anon;
grant execute on function public.api(text, text, jsonb, jsonb) to authenticated;

-- ============ 0006_audit_event.sql ============
-- تسجيل أحداث تتم في المتصفح (تصدير، تقارير، استيراد) في سجل العمليات
create or replace function gk.audit_event(u public.profiles, b jsonb) returns jsonb
language plpgsql security definer set search_path = public, gk, pg_temp as $fn$
declare a text := b ->> 'action'; ent text := coalesce(b ->> 'entity', 'report');
begin
  if a not in ('export', 'report') or ent not in ('visitor', 'report', 'system') then raise exception 'حدث غير مسموح'; end if;
  perform gk.audit(u, a, ent, null, case when jsonb_typeof(b -> 'details') = 'object' then b -> 'details' else '{}'::jsonb end, nullif(gk.int_or(b ->> 'event_id', 0), 0));
  return jsonb_build_object('ok', true);
end $fn$;

-- ============ 0007_seed.sql ============
-- بيانات أولية قابلة للتعديل من داخل التطبيق: الدول والمباني/الأدوار حسب المواصفات. لا غرف ولا سعات (تُدخل من الكروكي).
insert into public.countries (name, dial_code) values ('ماليزيا', '+60'), ('إندونيسيا', '+62'), ('الهند', '+91'), ('الكويت', '+965'), ('المملكة العربية السعودية', '+966')
on conflict (name) do nothing;

do $$
declare spec jsonb := '[["الدار",["الدور الثالث","الروف"]],["دار الضيافة",["الدور الأول","الدور الثاني","الدور الثالث"]],["الاستراحة الخضراء",["الدور الأول","الدور الثاني","الدور الثالث"]],["البرج",["الدور الثاني","الدور الثالث"]],["الفرن",["الدور الأول","الدور الثاني"]]]';
  b jsonb; bid int; i int := 0; f text; j int;
begin
  if exists (select 1 from public.buildings) then return; end if;
  for b in select * from jsonb_array_elements(spec) loop
    insert into public.buildings (name, sort) values (b ->> 0, i) returning id into bid; i := i + 1; j := 0;
    for f in select jsonb_array_elements_text(b -> 1) loop insert into public.floors (building_id, name, sort) values (bid, f, j); j := j + 1; end loop;
  end loop;
end $$;

-- ============ 0008_family_and_requests.sql ============
-- «جاؤوك» — ترقية 8: (أ) تصنيف «تابع لأسرة» مستقل برب أسرة يُختار من القائمة، (ب) طلبات الانضمام وموافقة المشرف
-- آمن للتشغيل أكثر من مرة. نفّذه في SQL Editor إن كانت قاعدتك منشأة مسبقاً.

-- ============ (أ) تابع لأسرة ============
create or replace function gk.member_head(u public.profiles, ev public.events, hid int, self_id int) returns public.visitors
language plpgsql security definer set search_path = public, gk, pg_temp as $fn$
declare h public.visitors;
begin
  select * into h from public.visitors where id = hid and event_id = ev.id and category = 'family_head' and id <> coalesce(self_id, 0);
  if not found then raise exception 'اختر رب الأسرة التابع لها'; end if;
  if not gk.can_see_country(u, h.country_id) then perform gk.forbid('لا يمكنك التسجيل لدولة غير مسؤول عنها'); end if;
  return h;
end $fn$;

create or replace function gk.member_inherit(o jsonb, h public.visitors) returns jsonb
language sql immutable as $fn$
  select o || jsonb_build_object('country_id', h.country_id, 'category', 'family_member', 'group_id', null, 'is_leader', false, 'guide_name', h.guide_name,
    'arrival_date', h.arrival_date, 'arrival_time', h.arrival_time, 'departure_date', h.departure_date, 'flight_no', h.flight_no, 'airline', h.airline, 'airport', h.airport, 'needs_transport', h.needs_transport) $fn$;

create or replace function gk.visitor_member_create(u public.profiles, ev public.events, b jsonb) returns jsonb
language plpgsql security definer set search_path = public, gk, pg_temp as $fn$
declare h public.visitors := gk.member_head(u, ev, nullif(b ->> 'head_id', '')::int, null); o jsonb; gate jsonb; id int;
begin
  o := gk.clean_visitor(b, u, ev.id, true);
  gate := gk.dup_gate(gk.truthy(b, 'force'), gk.find_dups(ev.id, u, jsonb_build_object('full_name', o ->> 'full_name', 'phone', o ->> 'phone', 'country_id', h.country_id), '{}'));
  if gate is not null then return gate; end if;
  id := gk.ins_visitor(gk.member_inherit(o, h), ev.id, u, h.id);
  perform gk.audit(u, 'create', 'visitor', id, jsonb_build_object('name', o ->> 'full_name', 'category', 'family_member', 'head', h.full_name), ev.id, h.country_id);
  return jsonb_build_object('id', id);
end $fn$;

create or replace function gk.visitor_to_member(u public.profiles, old public.visitors, ev public.events, b jsonb) returns jsonb
language plpgsql security definer set search_path = public, gk, pg_temp as $fn$
declare h public.visitors := gk.member_head(u, ev, nullif(b ->> 'head_id', '')::int, old.id); o jsonb; gate jsonb;
begin
  if exists (select 1 from public.visitors where head_id = old.id) then raise exception 'لا يمكن تحويل رب أسرة له تابعون إلى تابع. احذف تابعيه أولاً'; end if;
  o := gk.clean_visitor(to_jsonb(old) || b, u, ev.id, true);
  if o ->> 'full_name' <> old.full_name or o ->> 'phone' <> old.phone then
    gate := gk.dup_gate(gk.truthy(b, 'force'), gk.find_dups(ev.id, u, jsonb_build_object('full_name', o ->> 'full_name', 'phone', o ->> 'phone', 'country_id', h.country_id), array[old.id]));
    if gate is not null then return gate; end if;
  end if;
  o := gk.member_inherit(o, h);
  update public.visitors set full_name = o ->> 'full_name', name_norm = gk.norm_name(o ->> 'full_name'), phone = o ->> 'phone', phone_norm = gk.norm_phone(o ->> 'phone'),
    category = 'family_member', head_id = h.id, group_id = null, is_leader = false, country_id = h.country_id, guide_name = h.guide_name, relation = o ->> 'relation', notes = o ->> 'notes',
    arrival_date = h.arrival_date, arrival_time = h.arrival_time, departure_date = h.departure_date, flight_no = h.flight_no, airline = h.airline, airport = h.airport,
    needs_transport = h.needs_transport, updated_by = u.username, updated_at = now() where id = old.id;
  perform gk.audit(u, 'update', 'visitor', old.id, jsonb_build_object('category', jsonb_build_object('from', old.category, 'to', 'family_member'), 'head', h.full_name), ev.id, h.country_id);
  return jsonb_build_object('ok', true, 'warnings', '[]'::jsonb);
end $fn$;

create or replace function gk.visitor_create(u public.profiles, b jsonb) returns jsonb
language plpgsql security definer set search_path = public, gk, pg_temp as $fn$
declare ev public.events := gk.get_event(nullif(b ->> 'event_id', '')::int); o jsonb; members jsonb := '[]'::jsonb; gate jsonb; id int; m jsonb;
begin
  perform gk.need(u, array['admin', 'event_manager', 'country_supervisor']);
  if b ->> 'category' = 'family_member' then return gk.visitor_member_create(u, ev, b); end if;
  o := gk.clean_visitor(b, u, ev.id);
  if o ->> 'category' = 'family_head' then members := gk.clean_members(b -> 'members', o, u, ev.id); end if;
  gate := gk.dup_gate(gk.truthy(b, 'force'), gk.conflicts_for(ev.id, u, o, members, '{}'));
  if gate is not null then return gate; end if;
  id := gk.ins_visitor(o, ev.id, u);
  for m in select * from jsonb_array_elements(members) loop perform gk.ins_visitor(m, ev.id, u, id); end loop;
  perform gk.audit(u, 'create', 'visitor', id, jsonb_build_object('name', o ->> 'full_name', 'category', o ->> 'category', 'members', jsonb_array_length(members)), ev.id, (o ->> 'country_id')::int);
  return jsonb_build_object('id', id);
end $fn$;

create or replace function gk.visitor_update(u public.profiles, vid int, b jsonb) returns jsonb
language plpgsql security definer set search_path = public, gk, pg_temp as $fn$
declare old public.visitors := gk.visitor_get_scoped(u, vid); ev public.events := gk.get_event(old.event_id);
  o jsonb; members jsonb; gate jsonb; exclude int[]; old_members jsonb; changed boolean; new_members jsonb := '[]'::jsonb; m jsonb; keep int[] := '{}';
  removed text[] := '{}'; added text[] := '{}'; d jsonb; rm record; nid int; warns jsonb := '[]'::jsonb; bk record; mid int;
begin
  perform gk.need(u, array['admin', 'event_manager', 'country_supervisor']);
  if b ->> 'category' = 'family_member' and old.category <> 'family_member' then return gk.visitor_to_member(u, old, ev, b); end if;
  if old.category = 'family_member' then
    o := gk.clean_visitor(to_jsonb(old) || b, u, ev.id, true);
    if o ->> 'full_name' <> old.full_name or o ->> 'phone' <> old.phone then
      gate := gk.dup_gate(gk.truthy(b, 'force'), gk.find_dups(ev.id, u, jsonb_build_object('full_name', o ->> 'full_name', 'phone', o ->> 'phone', 'country_id', old.country_id), array[old.id]));
      if gate is not null then return gate; end if;
    end if;
    update public.visitors set full_name = o ->> 'full_name', name_norm = gk.norm_name(o ->> 'full_name'), phone = o ->> 'phone', phone_norm = gk.norm_phone(o ->> 'phone'),
      email = o ->> 'email', relation = o ->> 'relation', diet_notes = o ->> 'diet_notes', notes = o ->> 'notes', updated_by = u.username, updated_at = now() where id = old.id;
    perform gk.audit(u, 'update', 'visitor', old.id, gk.diff(to_jsonb(old), o, array['full_name', 'phone', 'email', 'relation', 'diet_notes', 'notes']), ev.id, old.country_id);
    return jsonb_build_object('ok', true);
  end if;

  o := gk.clean_visitor(to_jsonb(old) || b || jsonb_build_object('category', coalesce(b ->> 'category', old.category)), u, ev.id);
  if old.category = 'family_head' and o ->> 'category' <> 'family_head' and exists (select 1 from public.visitors where head_id = old.id) then
    raise exception 'لا يمكن تغيير تصنيف رب أسرة له تابعون. احذف التابعين أولاً';
  end if;
  select coalesce(jsonb_agg(to_jsonb(x)), '[]'::jsonb) into old_members from public.visitors x where x.head_id = old.id;
  members := case when o ->> 'category' = 'family_head' then gk.clean_members(case when b ? 'members' then b -> 'members' else old_members end, o, u, ev.id) else '[]'::jsonb end;
  select array_agg(id) into exclude from (select old.id id union all select id from public.visitors where head_id = old.id) t;
  changed := o ->> 'full_name' <> old.full_name or o ->> 'phone' <> old.phone or (o ->> 'country_id')::int <> old.country_id;
  for m in select * from jsonb_array_elements(members) loop
    if m ->> 'id' is null or not exists (select 1 from public.visitors x where x.id = (m ->> 'id')::int and x.head_id = old.id and x.full_name = m ->> 'full_name' and x.phone = m ->> 'phone') then
      new_members := new_members || jsonb_build_array(m);
    end if;
  end loop;
  if changed or jsonb_array_length(new_members) > 0 then
    gate := gk.dup_gate(gk.truthy(b, 'force'),
      gk.conflicts_for(ev.id, u, case when changed then o else o || jsonb_build_object('full_name', '', 'phone', '') end, new_members, exclude));
    if gate is not null then return gate; end if;
  end if;

  update public.visitors set full_name = o ->> 'full_name', name_norm = gk.norm_name(o ->> 'full_name'), country_id = (o ->> 'country_id')::int, phone = o ->> 'phone',
    phone_norm = gk.norm_phone(o ->> 'phone'), email = o ->> 'email', category = o ->> 'category', group_id = nullif(o ->> 'group_id', '')::int, is_leader = gk.truthy(o, 'is_leader'),
    guide_name = o ->> 'guide_name', arrival_date = o ->> 'arrival_date', arrival_time = o ->> 'arrival_time', departure_date = o ->> 'departure_date', flight_no = o ->> 'flight_no',
    airline = o ->> 'airline', airport = o ->> 'airport', needs_transport = gk.truthy(o, 'needs_transport'), diet_notes = o ->> 'diet_notes', notes = o ->> 'notes',
    updated_by = u.username, updated_at = now() where id = old.id;

  for m in select * from jsonb_array_elements(members) loop
    mid := nullif(m ->> 'id', '')::int;
    if mid is not null and exists (select 1 from public.visitors where id = mid and head_id = old.id) then
      keep := keep || mid;
      update public.visitors set full_name = m ->> 'full_name', name_norm = gk.norm_name(m ->> 'full_name'), phone = m ->> 'phone', phone_norm = gk.norm_phone(m ->> 'phone'),
        email = m ->> 'email', relation = m ->> 'relation', diet_notes = m ->> 'diet_notes', notes = m ->> 'notes', country_id = (m ->> 'country_id')::int,
        arrival_date = m ->> 'arrival_date', arrival_time = m ->> 'arrival_time', departure_date = m ->> 'departure_date', flight_no = m ->> 'flight_no',
        airline = m ->> 'airline', airport = m ->> 'airport', needs_transport = gk.truthy(m, 'needs_transport'), guide_name = m ->> 'guide_name',
        updated_by = u.username, updated_at = now() where id = mid;
    else
      nid := gk.ins_visitor(m, ev.id, u, old.id); keep := keep || nid; added := added || (m ->> 'full_name');
    end if;
  end loop;
  for rm in select id, full_name from public.visitors where head_id = old.id and not (id = any (keep)) loop
    removed := removed || rm.full_name; delete from public.visitors where id = rm.id;
  end loop;
  d := gk.diff(to_jsonb(old), o, array['full_name', 'country_id', 'phone', 'email', 'category', 'guide_name', 'group_id', 'is_leader', 'relation', 'arrival_date', 'arrival_time',
    'departure_date', 'flight_no', 'airline', 'airport', 'needs_transport', 'diet_notes', 'notes']);
  if cardinality(removed) > 0 then d := d || jsonb_build_object('removed_members', to_jsonb(removed)); end if;
  if cardinality(added) > 0 then d := d || jsonb_build_object('added_members', to_jsonb(added)); end if;
  perform gk.audit(u, 'update', 'visitor', old.id, d, ev.id, (o ->> 'country_id')::int);

  for bk in select b2.from_date, b2.to_date, v.full_name from public.bookings b2 join public.visitors v on v.id = b2.visitor_id
            where b2.visitor_id = old.id or v.head_id = old.id loop
    if ((o ->> 'arrival_date') <> '' and bk.from_date < o ->> 'arrival_date') or ((o ->> 'departure_date') <> '' and bk.to_date > o ->> 'departure_date') then
      warns := warns || to_jsonb(format('حجز الغرفة للزائر «%s» (%s ← %s) لا يطابق تواريخ الإقامة الجديدة. راجع التسكين', bk.full_name, bk.from_date, bk.to_date));
    end if;
  end loop;
  return jsonb_build_object('ok', true, 'warnings', warns);
end $fn$;

-- ============ (ب) طلبات الانضمام ============
do $$ declare c record; begin
  for c in select conname from pg_constraint where conrelid = 'public.profiles'::regclass and contype = 'c'
           and (pg_get_constraintdef(oid) like '%country_supervisor%' or pg_get_constraintdef(oid) like '%suspended%') loop
    execute format('alter table public.profiles drop constraint %I', c.conname);
  end loop;
end $$;
alter table public.profiles add constraint profiles_role_check check (role in ('admin','event_manager','building_supervisor','transport','catering','country_supervisor','pending'));
alter table public.profiles add constraint profiles_status_check check (status in ('active','suspended','pending'));

create or replace function gk.cur() returns public.profiles
language plpgsql stable security definer set search_path = public, gk, pg_temp as $fn$
declare r public.profiles;
begin
  select * into r from public.profiles where auth_id = auth.uid();
  if not found then raise exception 'الجلسة غير صالحة. سجّل الدخول من جديد' using errcode = 'PT401'; end if;
  if r.status = 'pending' then raise exception 'طلب انضمامك قيد المراجعة. سيُفعَّل حسابك بعد موافقة المشرف' using errcode = 'PT401'; end if;
  if r.status <> 'active' then raise exception 'الحساب موقوف. تواصل مع المشرف' using errcode = 'PT401'; end if;
  return r;
end $fn$;

-- يُستدعى بلا تسجيل دخول من صفحة الدخول: ينشئ حساباً معلّقاً لا يملك أي صلاحية حتى يقبله المشرف
create or replace function public.join_request(p_name text, p_phone text, p_username text, p_password text) returns jsonb
language plpgsql security definer set search_path = public, gk, extensions, auth, pg_temp as $fn$
declare nm text := btrim(coalesce(p_name, '')); ph text := btrim(coalesce(p_phone, '')); un text := btrim(coalesce(p_username, '')); aid uuid; pid int;
begin
  if length(nm) < 3 or length(nm) > 120 then raise exception 'اكتب اسمك الكامل'; end if;
  if ph !~ '^\+?[0-9 ()-]{7,20}$' then raise exception 'رقم الهاتف غير صحيح (اكتبه مع مفتاح الدولة)'; end if;
  if un !~ '^[A-Za-z0-9_.-]{3,40}$' then raise exception 'اسم المستخدم 3-40 حرفاً إنجليزياً أو أرقاماً أو ( _ . - )'; end if;
  if length(coalesce(p_password, '')) < 8 or p_password !~ '[A-Za-z]' or p_password !~ '\d' then raise exception 'كلمة المرور 8 أحرف على الأقل وتحتوي على حروف وأرقام'; end if;
  if exists (select 1 from public.profiles where lower(username) = lower(un)) then raise exception 'اسم المستخدم مستخدم مسبقاً، اختر اسماً آخر'; end if;
  if exists (select 1 from public.profiles where status = 'pending' and gk.norm_phone(phone) = gk.norm_phone(ph)) then raise exception 'يوجد طلب سابق بهذا الرقم قيد المراجعة'; end if;
  if (select count(*) from public.profiles where status = 'pending') >= 100 then raise exception 'عدد الطلبات المعلقة كبير حالياً. تواصل مع المشرف مباشرة'; end if;
  aid := gk.make_auth_user(un, p_password);
  insert into public.profiles (auth_id, name, phone, username, role, status) values (aid, nm, ph, un, 'pending', 'pending') returning id into pid;
  insert into public.audit_log (username, action, entity, entity_id, details) values (un, 'join_request', 'user', pid, jsonb_build_object('name', nm, 'phone', ph));
  return jsonb_build_object('ok', true);
end $fn$;
revoke all on function public.join_request(text, text, text, text) from public;
grant execute on function public.join_request(text, text, text, text) to anon, authenticated;
