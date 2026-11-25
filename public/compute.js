'use strict';
// حسابات لوحة التحكم والوجبات والنقل والتقارير — تتم في المتصفح على بيانات رجعت من قاعدة البيانات بعد تطبيق صلاحيات المستخدم
const Compute = (() => {
  const ROLE_LABELS = { admin: 'مدير النظام', event_manager: 'مدير المناسبة', building_supervisor: 'مشرف المبنى', transport: 'مسؤول النقل', catering: 'مسؤول الإعاشة', country_supervisor: 'مشرف دولة' };
  const CAT_LABELS = { individual: 'فرد', family_head: 'رب أسرة', family_member: 'تابع لأسرة', group_member: 'عضو في فوج' };
  const isDate = s => typeof s === 'string' && /^\d{4}-\d{2}-\d{2}$/.test(s) && new Date(s + 'T00:00:00Z').toISOString().slice(0, 10) === s;
  const addDays = (s, n) => { const d = new Date(s + 'T00:00:00Z'); d.setUTCDate(d.getUTCDate() + n); return d.toISOString().slice(0, 10); };
  const eachDay = (from, to) => { const o = []; for (let d = from; d < to; d = addDays(d, 1)) { o.push(d); if (o.length > 800) break; } return o; };
  const eachDayIncl = (from, to) => eachDay(from, addDays(to, 1));
  const today = () => { const d = new Date(); return `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, '0')}-${String(d.getDate()).padStart(2, '0')}`; };
  const HOUSERS = ['admin', 'event_manager', 'building_supervisor'], TRANSPORTERS = ['admin', 'event_manager', 'transport'], MEAL_ROLES = ['admin', 'event_manager', 'catering'], MEALS = ['breakfast', 'lunch', 'dinner'];
  const forbid = () => Object.assign(new Error('لا تملك صلاحية لتنفيذ هذا الإجراء'), { status: 403, data: {} });
  const notFound = m => Object.assign(new Error(m || 'غير موجود'), { status: 404, data: {} });

  function roomState(r, booked) { if (r.status !== 'active' || r.capacity <= 0) return 'unavailable'; if (booked <= 0) return 'free'; return booked >= r.capacity ? 'full' : 'partial'; }

  const loadVisitors = (rpc, q) => rpc('GET', '/visitors', q).then(r => r.visitors);

  // ----- النقل -----
  async function transportData(rpc, eventId, date) {
    const r = await rpc('GET', '/transports', { event_id: eventId, date });
    return r;
  }
  function transportDay(visitors, tasks, drivers, date) {
    const need = kind => {
      const col = kind === 'pickup' ? 'arrival_date' : 'departure_date';
      const vs = visitors.filter(v => v.needs_transport && v[col] === date);
      const covered = v => tasks.some(t => t.kind === kind && (t.visitor_id === v.id || (v.head_id && t.visitor_id === v.head_id) || (v.group_id && t.group_id === v.group_id)));
      return { persons: vs.length, unassigned: vs.filter(v => !covered(v)).map(v => ({ id: v.id, full_name: v.full_name, head_id: v.head_id, group_id: v.group_id, arrival_time: v.arrival_time, airport: v.airport, flight_no: v.flight_no, airline: v.airline, country_name: v.country_name })) };
    };
    const pick = need('pickup'), drop = need('dropoff'); const used = new Set(tasks.map(t => t.driver_id));
    return { date, tasks, need_pickup: pick.persons, need_dropoff: drop.persons, unassigned_pickup: pick.unassigned, unassigned_dropoff: drop.unassigned,
      assigned_passengers: tasks.reduce((a, t) => a + t.passengers, 0), fleet_capacity: drivers.reduce((a, d) => a + d.capacity, 0), fleet_cars: drivers.length, cars_used: used.size, free_drivers: drivers.filter(d => !used.has(d.id)).length };
  }
  async function transportDaily(rpc, q) {
    const date = isDate(q.date) ? q.date : today();
    const [vs, t] = await Promise.all([loadVisitors(rpc, { event_id: q.event_id }), transportData(rpc, q.event_id, date)]);
    return transportDay(vs, t.tasks, t.drivers, date);
  }
  async function transportSummary(rpc, q) {
    const [vs, t] = await Promise.all([loadVisitors(rpc, { event_id: q.event_id }), transportData(rpc, q.event_id)]);
    const dates = new Set(); vs.filter(v => v.needs_transport).forEach(v => { if (v.arrival_date) dates.add(v.arrival_date); if (v.departure_date) dates.add(v.departure_date); });
    t.tasks.forEach(x => dates.add(x.task_date));
    return { days: [...dates].sort().map(d => { const x = transportDay(vs, t.tasks.filter(k => k.task_date === d), t.drivers, d); return { date: d, need_pickup: x.need_pickup, need_dropoff: x.need_dropoff, assigned: x.assigned_passengers, fleet_capacity: x.fleet_capacity, unassigned: x.unassigned_pickup.length + x.unassigned_dropoff.length, tasks: x.tasks.length }; }) };
  }

  // ----- الوجبات -----
  async function mealsData(rpc, ev) {
    const [all, ex] = await Promise.all([loadVisitors(rpc, { event_id: ev.id }), rpc('GET', '/exclusions', { event_id: ev.id })]);
    const vs = all.filter(v => v.arrival_date); const exc = new Map();
    ex.exclusions.forEach(e => { if (!exc.has(e.visitor_id)) exc.set(e.visitor_id, new Set()); exc.get(e.visitor_id).add(e.date + '|' + e.meal); });
    let min = ev.start_date, max = ev.end_date;
    for (const v of vs) { if (v.arrival_date < min) min = v.arrival_date; const e = v.departure_date || ev.end_date; if (e > max) max = e; }
    const days = {}; for (const d of eachDayIncl(min, max)) days[d] = { date: d, residents: 0, breakfast: 0, lunch: 0, dinner: 0, total: 0, people: [] };
    for (const v of vs) {
      const end = v.departure_date || ev.end_date; const x = exc.get(v.id) || new Set();
      for (const d of eachDayIncl(v.arrival_date, end < v.arrival_date ? v.arrival_date : end)) {
        const day = days[d]; if (!day) continue; day.residents++;
        const has = {}; for (const m of MEALS) { has[m] = !(x.has(d + '|' + m) || x.has('*|' + m)); if (has[m]) { day[m]++; day.total++; } }
        day.people.push({ id: v.id, full_name: v.full_name, country_name: v.country_name, diet_notes: v.diet_notes, has, star: Object.fromEntries(MEALS.map(m => [m, x.has('*|' + m)])) });
      }
    }
    return days;
  }
  const stripPeople = ({ people, ...d }) => d;

  // ----- لوحة التحكم -----
  async function dashboard(rpc, u, q) {
    const ev = (await rpc('GET', '/events', {})).events.find(e => e.id === +q.event_id); if (!ev) throw Object.assign(new Error('يجب اختيار مناسبة صحيحة'), { status: 400, data: {} });
    const date = isDate(q.date) ? q.date : today();
    const vs = u.role === 'building_supervisor' ? [] : await loadVisitors(rpc, { event_id: ev.id });
    const countAt = f => vs.filter(f).length; const out = { event: ev, date, role: u.role };
    // أعداد الأفواج المعلنة: يُضاف لكل فوج ما لم يُسجَّل بالاسم من أعداده المعلنة (دون تكرار المسجلين)
    const grs = u.role === 'building_supervisor' ? [] : (await rpc('GET', '/groups', { event_id: ev.id }).catch(() => ({ groups: [] }))).groups || [];
    const regBy = {}; vs.forEach(v => { if (v.group_id) regBy[v.group_id] = (regBy[v.group_id] || 0) + 1; });
    const extra = grs.map(g => ({ cn: g.country_name, n: Math.max(0, (g.members_count || 0) - (regBy[g.id] || 0)) })).filter(x => x.n);
    const extraN = extra.reduce((a, x) => a + x.n, 0);
    const countries = {}; vs.forEach(v => { countries[v.country_name] = (countries[v.country_name] || 0) + 1; }); extra.forEach(x => { countries[x.cn] = (countries[x.cn] || 0) + x.n; });
    out.visitors = { total: vs.length + extraN, declared_unregistered: extraN, individuals: countAt(v => v.category === 'individual'), families: countAt(v => v.category === 'family_head'), family_members: countAt(v => v.category === 'family_member'),
      group_members: countAt(v => v.category === 'group_member') + extraN, countries: Object.keys(countries).length,
      present: countAt(v => v.arrival_date && v.arrival_date <= date && (!v.departure_date || v.departure_date >= date)), arriving: countAt(v => v.arrival_date === date), departing: countAt(v => v.departure_date === date),
      unhoused: countAt(v => !v.bookings.length), incomplete: countAt(v => !v.arrival_date || !v.departure_date) };
    out.by_country = Object.entries(countries).map(([name, n]) => ({ name, n })).sort((a, b) => b.n - a.n);
    const flow = {}; for (const d of eachDayIncl(ev.start_date, ev.end_date)) flow[d] = { date: d, arrivals: 0, departures: 0 };
    vs.forEach(v => { if (v.arrival_date) (flow[v.arrival_date] ||= { date: v.arrival_date, arrivals: 0, departures: 0 }).arrivals++; if (v.departure_date) (flow[v.departure_date] ||= { date: v.departure_date, arrivals: 0, departures: 0 }).departures++; });
    out.flow = Object.values(flow).sort((a, b) => a.date.localeCompare(b.date));
    if (HOUSERS.includes(u.role)) out.rooms = await roomStats(rpc, date);
    if (u.role === 'country_supervisor') out.mine = { housed: vs.filter(v => v.bookings.length).length, unhoused: vs.filter(v => !v.bookings.length).length, with_driver: vs.filter(v => v.transports.length).length };
    if (TRANSPORTERS.includes(u.role)) {
      const tt = await transportData(rpc, ev.id, date); const t = transportDay(vs, tt.tasks, tt.drivers, date); const maxCap = Math.max(0, ...tt.drivers.map(d => d.capacity));
      out.transport = { need_pickup: t.need_pickup, need_dropoff: t.need_dropoff, assigned_passengers: t.assigned_passengers, fleet_capacity: t.fleet_capacity,
        cars_required: maxCap ? Math.ceil((t.need_pickup + t.need_dropoff) / maxCap) : null, free_drivers: t.free_drivers, fleet_cars: t.fleet_cars, unassigned: t.unassigned_pickup.length + t.unassigned_dropoff.length };
    }
    if (MEAL_ROLES.includes(u.role)) { const days = await mealsData(rpc, ev); out.meals_today = stripPeople(days[date] || { date, residents: 0, breakfast: 0, lunch: 0, dinner: 0, total: 0 }); out.meals_flow = Object.values(days).map(stripPeople); }
    return out;
  }
  async function roomStats(rpc, date) {
    const rooms = (await rpc('GET', '/room-stats', { date })).rooms; const st = { free: 0, partial: 0, full: 0, unavailable: 0 }; const byB = {}; let cap = 0, booked = 0;
    for (const r of rooms) {
      const n = r.booked; st[roomState(r, n)]++;
      const b = byB[r.building_id] || (byB[r.building_id] = { name: r.building_name, capacity: 0, booked: 0 });
      if (r.status === 'active') { b.capacity += r.capacity; b.booked += n; cap += r.capacity; booked += n; }
    }
    return { rooms_total: rooms.length, rooms_booked: st.partial + st.full, rooms_available: st.free + st.partial, rooms_state: st, capacity: cap, booked_places: booked, occupancy_pct: cap ? Math.round(booked * 100 / cap) : 0,
      by_building: Object.values(byB).map(b => ({ ...b, pct: b.capacity ? Math.round(b.booked * 100 / b.capacity) : 0 })) };
  }

  // ----- التقارير -----
  // مدى التواريخ: date_from / date_to (أيٌّ منهما اختياري؛ بدونهما = كل أيام المناسبة). q.date يبقى للتوافق (يوم واحد)
  const range = q => { let f = isDate(q.date_from) ? q.date_from : '', t = isDate(q.date_to) ? q.date_to : ''; if (isDate(q.date)) { f = f || q.date; t = t || q.date; } if (f && t && f > t) [f, t] = [t, f]; return { f, t }; };
  const inRange = (d, r) => !!d && (!r.f || d >= r.f) && (!r.t || d <= r.t);
  const rangeText = r => r.f || r.t ? `الفترة: ${r.f || 'بداية المناسبة'} ← ${r.t || 'نهاية المناسبة'}` : 'كل أيام المناسبة';
  const C = (key, label, width = 18) => ({ key, label, width });
  const dayAr = d => ['الأحد', 'الإثنين', 'الثلاثاء', 'الأربعاء', 'الخميس', 'الجمعة', 'السبت'][new Date(d + 'T00:00:00Z').getUTCDay()];
  const roomText = bs => bs.map(b => `${b.building_name} / ${b.floor_name} / ${b.room_number}`).join('، ');
  // أعمار الزائرين: تُؤخذ من قاعدة البيانات (persons) بمطابقة الاسم والدولة؛ بالغ = 15 سنة فأكثر، طفل = أقل من 15، ومن لا تاريخ ميلاد له يُحسب بالغاً
  const ageYears = d => { if (!d || !/^\d{4}-\d\d-\d\d$/.test(d)) return null; const b = new Date(d + 'T00:00:00'), n = new Date(); let a = n.getFullYear() - b.getFullYear(); if (n.getMonth() < b.getMonth() || (n.getMonth() === b.getMonth() && n.getDate() < b.getDate())) a--; return a < 0 ? null : a; };
  async function bdMap(rpc, q) { try { const m = {}; for (const p of (await rpc('GET', '/persons', { event_id: q.event_id, country_id: q.country_id || '' })).persons) if (p.visitor_id && p.birth_date) m[p.visitor_id] = p.birth_date; return m; } catch (_) { return {}; } }
  // ترتيب الأشخاص: الأفراد أولاً (الأكبر عمراً فالأصغر)، ثم أرباب الأسر (الأكبر عمراً)، وتحت كل رب أسرة تابعوه (الأكبر عمراً). من لا تاريخ ميلاد له يأتي آخراً
  function orderPeople(list, birthOf) {
    const age = v => { const a = ageYears(birthOf(v)); return a === null ? -1 : a; };
    const byAge = (a, b) => age(b) - age(a) || String(a.full_name).localeCompare(String(b.full_name), 'ar');
    const ids = new Set(list.map(v => v.id)); const under = v => v.category === 'family_member' && v.head_id && ids.has(v.head_id);
    const heads = list.filter(v => v.category === 'family_head').sort(byAge);
    const single = list.filter(v => v.category !== 'family_head' && !under(v)).sort(byAge);
    return [...single.map(v => ({ v, member: false })), ...heads.flatMap(h => [{ v: h, member: false, head: true }, ...list.filter(m => under(m) && m.head_id === h.id).sort(byAge).map(v => ({ v, member: true }))])];
  }
  // مفتاح الأسرة: رب الأسرة وتابعوه (أو المرتبطون باسمه) تحت بعضهم
  const famOf = v => v.head_id || (v.kept_head ? 'k:' + v.kept_head + '|' + v.country_id : v.id);
  const kidOf = bd => v => { const a = ageYears(bd[v.id]); return a !== null && a < 15; };
  const cnt = (list, kid) => { const c = list.filter(kid).length; return { n: list.length, a: list.length - c, c }; };
  const cntTxt = x => `${x.n} (${x.a} بالغين - ${x.c} أطفال)`;
  const rv = (rpc, q, country) => loadVisitors(rpc, { event_id: q.event_id, country_id: country || q.country_id });
  // الأعداد المعلنة في الأفواج التي لم تُسجَّل أسماؤها بعد: لكل فوج (ما أُعلن − المسجّل بالاسم) مع تقسيم بالغين/أطفال
  async function groupExtras(rpc, q, vs, kid) {
    const grs = ((await rpc('GET', '/groups', { event_id: q.event_id }).catch(() => ({ groups: [] }))).groups || []).filter(g => !q.country_id || g.country_id === +q.country_id);
    const reg = {}; vs.forEach(v => { if (v.group_id) { const r = reg[v.group_id] ||= { n: 0, c: 0 }; r.n++; if (kid && kid(v)) r.c++; } });
    return grs.map(g => { const r = reg[g.id] || { n: 0, c: 0 }; const n = Math.max(0, (g.members_count || 0) - r.n); const c = Math.min(n, Math.max(0, (g.children_count || 0) - r.c)); return { g, n, c, a: n - c, registered: r.n }; }).filter(x => x.n > 0 || x.registered === 0 && (x.g.members_count || 0) > 0);
  }
  const REPORTS = {
    visitors_all: { roles: ['admin', 'event_manager', 'country_supervisor', 'transport', 'catering'], title: 'كشف كامل بأسماء الزائرين', async build(rpc, u, q) {
      const bd = await bdMap(rpc, q);
      const cols = [C('i', '#', 5), C('name', 'الاسم', 26), C('country', 'الدولة', 14), C('cat', 'التصنيف', 13), C('age', 'العمر', 8), C('rel', 'رب الأسرة / الفوج', 22), C('phone', 'الهاتف', 17), C('ad', 'الوصول', 12), C('at', 'الوقت', 8), C('dd', 'المغادرة', 12), C('dt', 'وقت المغادرة', 10), C('flight', 'رحلة الوصول', 16), C('airport', 'مطار الوصول', 14), C('dflight', 'رحلة المغادرة', 16), C('dairport', 'مطار المغادرة', 14), C('room', 'الغرفة', 28), C('driver', 'السائق', 18), C('notes', 'ملاحظات', 20)];
      const vsAll = await rv(rpc, q); const ex = await groupExtras(rpc, q, vsAll, kidOf(bd));
      const rows = vsAll.map((v, i) => ({ _fam: famOf(v), i: i + 1, name: v.full_name, country: v.country_name, cat: CAT_LABELS[v.category], age: ageYears(bd[v.id]) ?? '', rel: v.head_name || v.group_name || '', phone: v.phone, ad: v.arrival_date, at: v.arrival_time, dd: v.departure_date, dt: v.departure_time, dflight: [v.dep_airline, v.dep_flight_no].filter(Boolean).join(' '), dairport: v.dep_airport,
        flight: [v.airline, v.flight_no].filter(Boolean).join(' '), airport: v.airport, room: roomText(v.bookings), driver: v.transports.filter(t => t.kind === 'pickup').map(t => `${t.driver_name} (${t.car_number})`).join('، '), notes: [v.diet_notes, v.notes].filter(Boolean).join(' | ') }));
      ex.forEach(x => rows.push({ i: rows.length + 1, name: `فوج: ${x.g.name} — ${x.n} فرد (${x.a} بالغين - ${x.c} أطفال) بلا أسماء مسجلة`, country: x.g.country_name, cat: 'فوج', age: '', rel: x.g.leader_name ? 'المسئول: ' + x.g.leader_name : '', phone: [x.g.leader_phone, x.g.leader_phone2].filter(Boolean).join(' / '), ad: x.g.arrival_date, at: x.g.arrival_time, dd: x.g.departure_date, dt: x.g.departure_time, flight: [x.g.arrival_airline, x.g.arrival_flight_no].filter(Boolean).join(' '), airport: x.g.arrival_airport || '', dflight: [x.g.departure_airline, x.g.departure_flight_no].filter(Boolean).join(' '), dairport: x.g.departure_airport || '', room: '', driver: '', notes: x.g.notes || '' }));
      return { cols, rows };
    },
      sorts: [{ key: 'arr', label: 'موعد الوصول', by: r => [r.ad || '~', r.at || '~'] }, { key: 'dep', label: 'موعد المغادرة', by: r => [r.dd || '~', r.dt || '~'] }, { key: 'kind', label: 'أفراد / عائلات / أفواج', by: r => ['فرد', 'رب أسرة', 'تابع لأسرة', 'عضو في فوج'].indexOf(r.cat) } ] },
    by_country: { roles: ['admin', 'event_manager', 'country_supervisor'], title: 'إحصاء الزائرين حسب الدولة', async build(rpc, u, q) {
      const vs = await rv(rpc, q); const m = {}; const exs = await groupExtras(rpc, q, vs, null);
      for (const x of exs) { const r = m[x.g.country_name] ||= { country: x.g.country_name, total: 0, ind: 0, fam: 0, mem: 0, grp: 0, housed: 0, unhoused: 0 }; r.total += x.n; r.grp += x.n; r.unhoused += x.n; }
      for (const v of vs) { const r = m[v.country_name] ||= { country: v.country_name, total: 0, ind: 0, fam: 0, mem: 0, grp: 0, housed: 0, unhoused: 0 };
        r.total++; if (v.category === 'individual') r.ind++; if (v.category === 'family_head') r.fam++; if (v.category === 'family_member') r.mem++; if (v.category === 'group_member') r.grp++; v.bookings.length ? r.housed++ : r.unhoused++; }
      const rows = Object.values(m).sort((a, b) => b.total - a.total);
      if (rows.length > 1) rows.push(rows.reduce((t, r) => { for (const k of ['total', 'ind', 'fam', 'mem', 'grp', 'housed', 'unhoused']) t[k] += r[k]; return t; }, { country: 'الإجمالي', total: 0, ind: 0, fam: 0, mem: 0, grp: 0, housed: 0, unhoused: 0 }));
      return { cols: [C('country', 'الدولة'), C('total', 'إجمالي الزائرين', 14), C('ind', 'أفراد', 10), C('fam', 'عائلات (أرباب)', 14), C('mem', 'تابعون', 10), C('grp', 'أعضاء أفواج', 12), C('housed', 'تم تسكينهم', 12), C('unhoused', 'لم يُسكنوا', 12)], rows };
    } },
    families_groups: { roles: ['admin', 'event_manager', 'country_supervisor'], title: 'كشف العائلات والأفواج', async build(rpc, u, q) {
      const [vs, bd] = await Promise.all([rv(rpc, q), bdMap(rpc, q)]); const kid = kidOf(bd); const rows = [];
      for (const h of vs.filter(v => v.category === 'family_head')) { const mem = vs.filter(v => v.head_id === h.id); const c = cnt([h, ...mem], kid);
        rows.push({ type: 'عائلة', name: h.full_name, country: h.country_name, count: cntTxt(c), _n: c.n, ad: h.arrival_date, dd: h.departure_date, rooms: roomText([...h.bookings, ...mem.flatMap(m => m.bookings)].filter((b, i, a) => a.findIndex(x => x.room_id === b.room_id) === i)) }); }
      const groups = {}; for (const v of vs.filter(x => x.category === 'group_member')) (groups[v.group_id] ||= []).push(v);
      for (const list of Object.values(groups)) { const f = list[0]; const c = cnt(list, kid);
        rows.push({ type: 'فوج', name: f.group_name, country: f.country_name, count: cntTxt(c), _n: c.n, _a: c.a, _c: c.c, ad: f.arrival_date, dd: f.departure_date, rooms: roomText(list.flatMap(m => m.bookings).filter((b, i, a) => a.findIndex(x => x.room_id === b.room_id) === i)) }); }
      const ex = await groupExtras(rpc, q, vs, kid);
      for (const x of ex) { const ex0 = rows.find(r => r.type === 'فوج' && r.name === x.g.name && r.country === x.g.country_name);
        if (ex0) { const tot = { n: ex0._n + x.n, a: (ex0._a || 0) + x.a, c: (ex0._c || 0) + x.c }; ex0._n = tot.n; ex0.count = cntTxt(tot); }
        else rows.push({ type: 'فوج', name: x.g.name, country: x.g.country_name, count: cntTxt({ n: x.n, a: x.a, c: x.c }), _n: x.n, ad: x.g.arrival_date, dd: x.g.departure_date, rooms: '' }); }
      return { cols: [C('type', 'النوع', 9), C('name', 'الاسم / الفوج', 24), C('country', 'الدولة', 14), C('count', 'عدد الأفراد', 24), C('ad', 'الوصول', 12), C('dd', 'المغادرة', 12), C('rooms', 'الغرف', 34)], rows };
    }, sorts: [{ key: 'size', label: 'عدد الأفراد (الأكبر أولاً)', by: r => -r._n }] },
    passenger_list: { roles: ['admin', 'event_manager', 'country_supervisor', 'transport'], title: 'قائمة المسافرين (الأسماء فقط)', async build(rpc, u, q) {
      const vs = await rv(rpc, q); const norm = x => String(x || '').trim().toLowerCase(); const kind = q.kind || '', fl = norm(q.flight), day = q.day || '', ap = norm(q.airport);
      const side = (v, k) => k === 'arrival' ? { no: norm(v.flight_no), date: v.arrival_date, ap: norm(v.airport) } : { no: norm(v.dep_flight_no), date: v.departure_date, ap: norm(v.dep_airport) };
      const ok = (v, k) => { const x = side(v, k); return (!fl || x.no === fl) && (!day || x.date === day) && (!ap || x.ap === ap) && (!(fl || day || ap) || !!(x.no || x.date || x.ap)); };
      const ord = new Map(vs.map((v, i) => [v.id, i])); const list = vs.filter(v => kind ? ok(v, kind) : (ok(v, 'arrival') || ok(v, 'departure'))).sort((a, b) => a.country_name.localeCompare(b.country_name, 'ar') || ord.get(a.id) - ord.get(b.id));
      const parts = []; if (q.country_id && list[0]) parts.push('الدولة: ' + list[0].country_name); parts.push(kind === 'arrival' ? 'وصول' : kind === 'departure' ? 'مغادرة' : 'وصول ومغادرة'); if (q.flight) parts.push('الرحلة: ' + q.flight); if (day) parts.push('اليوم: ' + day + ' (' + dayAr(day) + ')'); if (q.airport) parts.push('المطار: ' + q.airport);
      return { cols: [C('i', '#', 6), C('name', 'الاسم', 40)], rows: list.map((v, i) => ({ _fam: famOf(v), i: i + 1, name: v.full_name })), subtitle: parts.join(' — ') };
    } },
    group_visit: { roles: ['admin', 'event_manager', 'country_supervisor'], title: 'تقرير الزيارة حسب المجموعات', custom: true, async build(rpc, u, q) {
      const [fr, bd, vs] = await Promise.all([rpc('GET', '/flights', { event_id: q.event_id }), bdMap(rpc, q), rv(rpc, q)]); const isChild = kidOf(bd);
      const cid = q.country_id ? +q.country_id : 0; const flights = fr.flights.filter(f => (!cid || f.country_id === cid) && f.group_no);
      const gm = new Map(); for (const f of flights) { const k = f.group_no.toLowerCase(); const g = gm.get(k) || { group_no: f.group_no, country: f.country_name || '', arrival: null, departure: null }; g[f.kind] = f; if (!g.country) g.country = f.country_name || ''; gm.set(k, g); }
      const label = v => v.category === 'family_member' && v.head_name ? `عائلة ${v.head_name}` : v.category === 'group_member' && v.group_name ? `فوج ${v.group_name}` : '';
      const mk = (g, list) => { const people = orderPeople(list, v => bd[v.id]).map(({ v }) => ({ name: v.full_name, rel: label(v), child: isChild(v) })); const kids = people.filter(x => x.child).length; return { ...g, people, total: people.length, adults: people.length - kids, children: kids }; };
      const groups = [...gm.values()].sort((a, b) => a.group_no.localeCompare(b.group_no, 'ar', { numeric: true })).map(g => {
        const ids = [g.arrival && g.arrival.id, g.departure && g.departure.id].filter(Boolean);
        return mk(g, vs.filter(v => ids.includes(v.arrival_flight_id) || ids.includes(v.departure_flight_id))); });
      const lone = vs.filter(v => !flights.some(f => f.id === v.arrival_flight_id || f.id === v.departure_flight_id));
      if (lone.length) groups.push(mk({ group_no: '', country: '', arrival: null, departure: null, unlinked: true }, lone));
      const fmt = (t, f) => f ? `${t}: ${[f.flight_date, f.airport && 'المطار: ' + f.airport, f.airline && 'شركة الطيران: ' + f.airline, f.flight_no && 'رقم الرحلة: ' + f.flight_no, f.flight_time && (t === 'رحلة الوصول' ? 'وقت الوصول: ' : 'وقت المغادرة: ') + f.flight_time, [f.phone1, f.phone2, f.phone3].some(Boolean) && 'أرقام التواصل: ' + [f.phone1, f.phone2, f.phone3].filter(Boolean).join(' / ')].filter(Boolean).join(' — ')}` : '';
      const tot = g => `المجموع: ${g.total} (${g.adults} بالغين - ${g.children} أطفال)`; const cols = [C('a', '#', 5), C('b', 'الاسم', 28), C('c', 'العائلة / الفوج', 22), C('d', '#', 5), C('e', 'الاسم', 28), C('f', 'العائلة / الفوج', 22)]; const rows = [];
      for (const g of groups) {
        const row = (a, st) => rows.push({ a, b: '', c: '', d: '', e: '', f: '', _style: st });
        row(g.unlinked ? 'زوار غير مرتبطين برقم مجموعة' : `المجموعة رقم (${g.group_no})${g.country ? ' - ' + g.country : ''}`, 'sub'); if (g.arrival) row(fmt('رحلة الوصول', g.arrival)); if (g.departure) row(fmt('رحلة المغادرة', g.departure)); row(tot(g));
        const h = Math.ceil(g.people.length / 2); for (let i = 0; i < h; i++) { const x = g.people[2 * i], y = g.people[2 * i + 1]; rows.push({ a: 2 * i + 1, b: x.name, c: x.rel, d: y ? 2 * i + 2 : '', e: y ? y.name : '', f: y ? y.rel : '' }); }
        rows.push({ a: '', b: '', c: '', d: '', e: '', f: '' });
      }
      const all = groups.reduce((t, g) => ({ n: t.n + g.total, a: t.a + g.adults, c: t.c + g.children }), { n: 0, a: 0, c: 0 });
      return { cols, rows, groups, subtitle: `${groups.length} مجموعة — الإجمالي ${all.n} (${all.a} بالغين - ${all.c} أطفال)` };
    } },
    arrivals_departures: { roles: ['admin', 'event_manager', 'country_supervisor', 'transport'], title: 'كشف القادمين والمغادرين', async build(rpc, u, q) {
      const vs = await rv(rpc, q); const R = range(q); const rows = []; const ordv = new Map(vs.map((v, i) => [v.id, i]));
      for (const v of vs) {
        if (inRange(v.arrival_date, R)) rows.push({ _o: ordv.get(v.id), _fam: famOf(v), date: v.arrival_date, type: 'وصول', time: v.arrival_time, name: v.full_name, country: v.country_name, flight: [v.airline, v.flight_no].filter(Boolean).join(' '), airport: v.airport, driver: v.transports.filter(t => t.kind === 'pickup').map(t => t.driver_name).join('، ') });
        if (inRange(v.departure_date, R)) rows.push({ _o: ordv.get(v.id), _fam: famOf(v), date: v.departure_date, type: 'مغادرة', time: v.departure_time, name: v.full_name, country: v.country_name, flight: [v.dep_airline, v.dep_flight_no].filter(Boolean).join(' '), airport: v.dep_airport || '', driver: v.transports.filter(t => t.kind === 'dropoff').map(t => t.driver_name).join('، ') });
      }
      const bdm = await bdMap(rpc, q);
      for (const x of await groupExtras(rpc, q, vs, kidOf(bdm))) { const nm = `فوج: ${x.g.name} — ${x.n} فرد (${x.a} بالغين - ${x.c} أطفال)${x.g.leader_name ? ' — المسئول: ' + x.g.leader_name : ''}`;
        if (inRange(x.g.arrival_date, R)) rows.push({ date: x.g.arrival_date, type: 'وصول', time: x.g.arrival_time || '', name: nm, country: x.g.country_name, flight: [x.g.arrival_airline, x.g.arrival_flight_no].filter(Boolean).join(' '), airport: x.g.arrival_airport || '', driver: '' });
        if (inRange(x.g.departure_date, R)) rows.push({ date: x.g.departure_date, type: 'مغادرة', time: x.g.departure_time || '', name: nm, country: x.g.country_name, flight: [x.g.departure_airline, x.g.departure_flight_no].filter(Boolean).join(' '), airport: x.g.departure_airport || '', driver: '' }); }
      rows.sort((a, b) => a.date.localeCompare(b.date) || a.type.localeCompare(b.type) || String(a.time).localeCompare(String(b.time)) || (a._o ?? 1e9) - (b._o ?? 1e9));
      return { cols: [C('date', 'التاريخ', 12), C('type', 'النوع', 9), C('time', 'الوقت', 8), C('name', 'الاسم', 26), C('country', 'الدولة', 14), C('flight', 'الرحلة', 18), C('airport', 'المطار', 16), C('driver', 'السائق', 18)], rows, subtitle: rangeText(R) };
    } },
    arrivals_counts: { roles: ['admin', 'event_manager', 'country_supervisor', 'transport'], title: 'القادمون والمغادرون — أعداد حسب اليوم والرحلة', async build(rpc, u, q) {
      const [vs0, bd] = await Promise.all([rv(rpc, q), bdMap(rpc, q)]); const kid0 = kidOf(bd); const kid = v => v._kid !== undefined ? v._kid : kid0(v); const R = range(q); const m = new Map();
      const vs = [...vs0]; for (const x of await groupExtras(rpc, q, vs0, kid0)) for (let i = 0; i < x.n; i++) vs.push({ id: 'g' + x.g.id + '_' + i, _kid: i >= x.a, country_name: x.g.country_name, arrival_date: x.g.arrival_date, departure_date: x.g.departure_date, airline: x.g.arrival_airline || '', flight_no: [x.g.arrival_flight_no, '(فوج ' + x.g.name + ')'].filter(Boolean).join(' '), airport: x.g.arrival_airport || '', dep_airline: x.g.departure_airline || '', dep_flight_no: [x.g.departure_flight_no, '(فوج ' + x.g.name + ')'].filter(Boolean).join(' '), dep_airport: x.g.departure_airport || '' });
      const fmap = new Map(((await rpc('GET', '/flights', { event_id: q.event_id }).catch(() => ({ flights: [] }))).flights || []).map(f => [f.id, [f.phone1, f.phone2, f.phone3].filter(Boolean).join(' / ')]));
      const add = (date, flight, airport, country, v, k) => { const key = [date, flight, airport, country].join('|'); const r = m.get(key) || { date, flight, airport, country, arr: [], dep: [], phones: '' }; r[k].push(v); if (!r.phones) r.phones = fmap.get(k === 'arr' ? v.arrival_flight_id : v.departure_flight_id) || ''; m.set(key, r); };
      for (const v of vs) {
        if (inRange(v.arrival_date, R)) add(v.arrival_date, [v.airline, v.flight_no].filter(Boolean).join(' ') || 'بدون رحلة', v.airport || '', v.country_name, v, 'arr');
        if (inRange(v.departure_date, R)) add(v.departure_date, [v.dep_airline, v.dep_flight_no].filter(Boolean).join(' ') || '—', v.dep_airport || '', v.country_name, v, 'dep');
      }
      const days = [...new Set([...m.values()].map(r => r.date))].sort(); const rows = []; let A = [], D = [];
      const line = (date, flight, airport, country, a, d, phones = '') => ({ date, flight, airport, country, phones, arr: cntTxt(cnt(a, kid)), dep: cntTxt(cnt(d, kid)), total: cntTxt(cnt([...a, ...d], kid)), _a: a.length, _d: d.length });
      for (const d of days) {
        const list = [...m.values()].filter(r => r.date === d).sort((a, b) => (a.flight === '—') - (b.flight === '—') || a.flight.localeCompare(b.flight) || a.country.localeCompare(b.country, 'ar'));
        const dayTxt = `${dayAr(d)} ${d}`; let sa = [], sd = [];
        for (const r of list) { rows.push(line(dayTxt, r.flight, r.airport, r.country, r.arr, r.dep, r.phones)); sa = sa.concat(r.arr); sd = sd.concat(r.dep); }
        rows.push(line(dayTxt, 'إجمالي اليوم', '', '', sa, sd)); A = A.concat(sa); D = D.concat(sd);
      }
      if (days.length) rows.push(line('الإجمالي', '', '', '', A, D));
      return { cols: [C('date', 'اليوم', 22), C('country', 'الدولة', 14), C('flight', 'الرحلة', 22), C('airport', 'المطار', 16), C('phones', 'أرقام التواصل', 26), C('arr', 'عدد القادمين', 24), C('dep', 'عدد المغادرين', 24), C('total', 'المجموع', 24)], rows, subtitle: rangeText(R) };
    } },
    housing: { roles: HOUSERS, title: 'كشف تسكين المباني والأدوار', async build(rpc, u, q) {
      let bs = (await rpc('GET', '/bookings', { event_id: q.event_id })).bookings;
      if (q.building_id) bs = bs.filter(b => b.building_id === +q.building_id); if (q.floor_id) bs = bs.filter(b => b.floor_id === +q.floor_id);
      const st = (await rpc('GET', '/structure', {})).buildings; const cap = {}; st.forEach(b => b.floors.forEach(f => f.rooms.forEach(r => (cap[r.id] = r.capacity))));
      const vsH = await rv(rpc, q).catch(() => []); const hmap = new Map(vsH.map((v, i) => [v.id, { i, f: famOf(v) }]));
      bs = bs.slice().sort((a, b) => (a.building_name || '').localeCompare(b.building_name || '', 'ar') || (a.floor_name || '').localeCompare(b.floor_name || '', 'ar') || String(a.room_number).localeCompare(String(b.room_number), 'ar', { numeric: true }) || ((hmap.get(a.visitor_id) || {}).i ?? 1e9) - ((hmap.get(b.visitor_id) || {}).i ?? 1e9));
      const rows = bs.map(b => ({ _fam: (hmap.get(b.visitor_id) || {}).f, building: b.building_name, floor: b.floor_name, room: b.room_number, capacity: cap[b.room_id] ?? '', name: b.full_name, country: b.country_name, from_date: b.from_date, to_date: b.to_date }));
      return { cols: [C('building', 'المبنى', 18), C('floor', 'الدور', 14), C('room', 'الغرفة', 9), C('capacity', 'السعة', 8), C('name', 'المقيم', 26), C('country', 'الدولة', 14), C('from_date', 'من', 12), C('to_date', 'إلى', 12)], rows };
    } },
    rooms_status: { roles: HOUSERS, title: 'كشف الغرف المتاحة والمشغولة', async build(rpc, u, q) {
      const date = isDate(q.date) ? q.date : today(); const [st, rs] = await Promise.all([rpc('GET', '/structure', {}), rpc('GET', '/room-stats', { date })]);
      const m = new Map(rs.rooms.map(r => [r.id, r.booked])); const lab = { free: 'متاحة', partial: 'مشغولة جزئياً', full: 'مكتملة', unavailable: 'خارج الخدمة' }; const rows = [];
      for (const b of st.buildings) for (const f of b.floors) for (const r of f.rooms) { const n = m.get(r.id) || 0; rows.push({ building: b.name, floor: f.name, room: r.number, capacity: r.capacity, booked: n, remaining: r.status === 'active' ? Math.max(0, r.capacity - n) : 0, state: lab[roomState(r, n)] }); }
      return { cols: [C('building', 'المبنى', 18), C('floor', 'الدور', 14), C('room', 'الغرفة', 9), C('capacity', 'السعة', 8), C('booked', 'المحجوز', 9), C('remaining', 'المتبقي', 9), C('state', 'الحالة', 16)], rows, subtitle: 'بتاريخ ' + date };
    } },
    drivers_tasks: { roles: TRANSPORTERS, title: 'كشف السائقين ومهامهم', async build(rpc, u, q) {
      const st = { not_started: 'لم يبدأ', on_the_way: 'في الطريق', received: 'تم الاستقبال', done: 'انتهت المهمة' };
      const R = range(q); const rows = (await transportData(rpc, q.event_id, undefined)).tasks.filter(t => !R.f && !R.t || inRange(t.task_date, R)).map(t => ({ driver: t.driver_name, phone: t.driver_phone, car: [t.car_type, t.car_number].filter(Boolean).join(' - '), cap: t.car_capacity, kind: t.kind === 'pickup' ? 'استقبال' : 'توصيل مغادرة', date: t.task_date, time: t.task_time, airport: t.airport, who: t.visitor_name || ('فوج: ' + t.group_name), country: t.country_name, pax: t.passengers, flight: t.flight_info, status: st[t.status] }));
      return { cols: [C('driver', 'السائق', 18), C('phone', 'الهاتف', 16), C('car', 'السيارة', 20), C('cap', 'السعة', 7), C('kind', 'المهمة', 12), C('date', 'التاريخ', 12), C('time', 'الوقت', 8), C('airport', 'المطار', 16), C('who', 'الزائر / الفوج', 24), C('country', 'الدولة', 12), C('pax', 'الركاب', 8), C('flight', 'الرحلة', 16), C('status', 'الحالة', 13)], rows };
    } },
    meals_daily: { roles: MEAL_ROLES, title: 'كشف الوجبات اليومية', async build(rpc, u, q) {
      const ev = (await rpc('GET', '/events', {})).events.find(e => e.id === +q.event_id); const days = Object.values(await mealsData(rpc, ev));
      return { cols: [C('date', 'التاريخ', 13), C('residents', 'عدد المقيمين', 13), C('breakfast', 'الإفطار', 10), C('lunch', 'الغداء', 10), C('dinner', 'العشاء', 10), C('total', 'إجمالي الوجبات', 14)], rows: days.map(stripPeople) };
    } },
    supervisors: { roles: ['admin', 'event_manager'], title: 'كشف مسؤوليات المشرفين', async build(rpc) {
      const us = (await rpc('GET', '/users', {})).users.filter(x => ['building_supervisor', 'country_supervisor'].includes(x.role));
      const rows = us.map(x => ({ name: x.name, role: ROLE_LABELS[x.role], phone: x.phone, scope: x.role === 'country_supervisor' ? 'الدول: ' + x.countries.map(c => c.name).join('، ') : x.floors.map(f => `${f.building_name} / ${f.floor_name}`).join('، '), status: x.status === 'active' ? 'نشط' : 'موقوف', notes: x.notes }));
      return { cols: [C('name', 'الاسم', 22), C('role', 'الصفة', 14), C('phone', 'الهاتف', 16), C('scope', 'المسؤولية', 50), C('status', 'الحالة', 9), C('notes', 'ملاحظات', 24)], rows };
    } },
  };
  // تصفية وترتيب وإخفاء أعمدة وترقيم: تُطبَّق على نتيجة التقرير قبل العرض والـPDF وExcel
  const isTot = r => r.country === 'الإجمالي' || r.date === 'الإجمالي' || r.flight === 'إجمالي اليوم';
  const sv = v => v === null || v === undefined ? '' : String(v);
  const cmpv = (a, b) => { if (Array.isArray(a)) { for (let i = 0; i < a.length; i++) { const c = cmpv(a[i], b[i]); if (c) return c; } return 0; } const ea = a === '' || a == null, eb = b === '' || b == null; if (ea || eb) return ea === eb ? 0 : ea ? 1 : -1; if (typeof a === 'number' && typeof b === 'number') return a - b; return String(a).localeCompare(String(b), 'ar', { numeric: true }); };
  function refine(def, cols, rows, subtitle, q) {
    const sorts = [...(def.sorts || []).map(x => ({ key: x.key, label: x.label })), ...cols.filter(c => c.key !== 'i').map(c => ({ key: c.key, label: c.label }))];
    const meta = { columns: cols.filter(c => c.key !== 'i').map(c => ({ key: c.key, label: c.label })), sorts, values: {} };
    for (const c of cols) { const set = new Set(rows.filter(r => !isTot(r)).map(r => sv(r[c.key])).filter(Boolean)); meta.values[c.key] = set.size <= 120 ? [...set].sort(cmpv) : null; }
    const notes = []; const lab = k => (cols.find(c => c.key === k) || {}).label || k; const search = String(q.search || '').trim(); const fcol = q.fcol && cols.some(c => c.key === q.fcol) ? q.fcol : '', fval = q.fval || '';
    const filtered = !!(fcol && fval) || !!search; if (filtered) rows = rows.filter(r => !isTot(r));
    if (fcol && fval) { rows = rows.filter(r => sv(r[fcol]) === fval); notes.push(`التصفية: ${lab(fcol)} = ${fval}`); }
    if (search) { rows = rows.filter(r => cols.some(c => sv(r[c.key]).includes(search))); notes.push(`بحث: ${search}`); }
    const ex = (def.sorts || []).find(x => x.key === q.sort); const by = ex ? ex.by : cols.some(c => c.key === q.sort) ? (r => r[q.sort]) : null;
    if (by) { const dir = q.sdir === 'desc' ? -1 : 1; const raw = rows.filter(r => !isTot(r)); const lead = new Map(); raw.forEach(r => { if (r._fam !== undefined && !lead.has(r._fam)) lead.set(r._fam, r); });
      const gk = r => r._fam !== undefined ? lead.get(r._fam) : r; const li = r => raw.indexOf(gk(r)); const body = raw.map((r, i) => [r, i]).sort((a, b) => dir * cmpv(by(gk(a[0])), by(gk(b[0]))) || li(a[0]) - li(b[0]) || a[1] - b[1]).map(x => x[0]); const tail = filtered ? [] : rows.filter(r => r.country === 'الإجمالي' || r.date === 'الإجمالي'); rows = body.concat(tail); notes.push(`الترتيب: ${(sorts.find(x => x.key === q.sort) || {}).label}${dir < 0 ? ' (تنازلي)' : ''}`); }
    const hide = String(q.hide || '').split(',').filter(Boolean); let shown = cols.filter(c => c.key !== 'i' && !hide.includes(c.key)); if (!shown.length) shown = cols.filter(c => c.key !== 'i');
    if (hide.length && shown.length < cols.length - (cols.some(c => c.key === 'i') ? 1 : 0)) notes.push(`أعمدة مخفية: ${hide.map(lab).join('، ')}`);
    let n = 0; rows = rows.map(r => ({ ...r, sn: isTot(r) ? '' : ++n }));
    cols = [C('sn', '#', 6), ...shown].map(c => ({ ...c, nowrap: /الاسم|المقيم|الزائر/.test(c.label) || rows.every(r => sv(r[c.key]).length <= 26) }));
    return { cols, rows, subtitle: [subtitle, ...notes].filter(Boolean).join(' — '), meta };
  }
  async function report(rpc, u, type, q) {
    const def = REPORTS[type]; if (!def) throw notFound('تقرير غير معروف'); if (!def.roles.includes(u.role)) throw forbid();
    const ev = (await rpc('GET', '/events', {})).events.find(e => e.id === +q.event_id); if (!ev) throw Object.assign(new Error('يجب اختيار مناسبة صحيحة'), { status: 400, data: {} });
    let { cols, rows, subtitle, groups } = await def.build(rpc, u, { ...q, event_id: ev.id }); let meta = null;
    if (!def.custom) ({ cols, rows, subtitle, meta } = refine(def, cols, rows, subtitle, q));
    return { def, ev, cols, rows, subtitle, groups, meta };
  }
  const reportList = u => Object.entries(REPORTS).filter(([, d]) => d.roles.includes(u.role)).map(([k, d]) => ({ key: k, title: d.title }));
  const api = { orderPeople, ageYears, ROLE_LABELS, CAT_LABELS, dashboard, mealsData, stripPeople, transportDaily, transportSummary, report, reportList, isDate, today };
  if (typeof module !== 'undefined' && module.exports) module.exports = api; else window.Compute = api;
  return api;
})();
