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
