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
