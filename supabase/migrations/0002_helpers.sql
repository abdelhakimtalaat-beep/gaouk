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
