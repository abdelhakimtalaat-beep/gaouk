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
