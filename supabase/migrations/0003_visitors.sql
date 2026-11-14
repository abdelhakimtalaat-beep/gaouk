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
