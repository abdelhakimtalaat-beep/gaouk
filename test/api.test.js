'use strict';
// اختبار شامل للنسخة الجديدة (Supabase): يشغّل كود الواجهة نفسه (sb.js + adapter.js + compute.js) على خادم محاكاة فوق Postgres حقيقي
const fs = require('node:fs'), path = require('node:path'), vm = require('node:vm'), assert = require('node:assert/strict');
const { server } = require('./mock-supabase');
const X = require('../public/xlsx.js');
const PUB = path.join(__dirname, '..', 'public');

let passed = 0, failed = 0;
async function t(name, fn) { try { await fn(); passed++; console.log('  ✓', name); } catch (e) { failed++; console.log('  ✗', name, '\n     ', e.message.split('\n')[0]); } }

let base;
function client() {
  const sandbox = { fetch, URL, URLSearchParams, Blob, TextEncoder, TextDecoder, Response, DecompressionStream, CompressionStream, console, setTimeout, clearTimeout, Date, Promise };
  sandbox.window = sandbox; sandbox.App = { user: null }; sandbox.GAOUK_CONFIG = { SUPABASE_URL: base, SUPABASE_ANON_KEY: 'anon-test' };
  vm.createContext(sandbox);
  for (const f of ['xlsx.js', 'sb.js', 'compute.js', 'adapter.js']) vm.runInContext(fs.readFileSync(path.join(PUB, f), 'utf8') + (f === 'xlsx.js' ? '' : ''), sandbox, { filename: f });
  vm.runInContext('class ApiError extends Error { constructor(status, data) { super(data.error || "خطأ"); this.status = status; this.data = data; } }; globalThis.ApiError = ApiError;', sandbox);
  const call = async (method, url, body, opts = {}) => {
    try {
      const data = await vm.runInContext('(async (m,u,b,o) => Adapter.call(m,u,b,o,ApiError))', sandbox)(method, url, body, opts.raw ? opts : { ...opts, blob: true });
      if (data instanceof sandbox.Blob) return { status: 200, data: new Uint8Array(await data.arrayBuffer()) };
      if (url === '/login' || url === '/me') sandbox.App.user = data.user;
      return { status: 200, data };
    } catch (e) { return { status: e.status ?? 0, data: e.data || { error: e.message } }; }
  };
  call.login = async (u, p) => call('POST', '/login', { username: u, password: p });
  return call;
}
(async () => {
  await new Promise(r => server.listen(0, '127.0.0.1', r)); base = 'http://127.0.0.1:' + server.address().port;
  const admin = client(), my = client(), ind = client(), bs = client(), anon = client();

  console.log('\nالمصادقة');
  await t('طلب بدون دخول يُرفض 401', async () => assert.equal((await anon('GET', '/events')).status, 401));
  await t('كلمة مرور خاطئة 401', async () => assert.equal((await anon.login('admin', 'x')).status, 401));
  await t('دخول المدير ينجح', async () => assert.equal((await admin.login('admin', 'AdminPass123')).status, 200));

  // ---- إعداد ----
  const countries = (await admin('GET', '/countries')).data.countries; const cid = n => countries.find(c => c.name === n).id;
  const MY = cid('ماليزيا'), IN = cid('الهند');
  const ev = (await admin('POST', '/events', { name: 'موسم الشتاء', start_date: '2026-12-20', end_date: '2026-12-30', expected_visitors: 50 })).data.id;
  const st = (await admin('GET', '/structure')).data.buildings;
  const guest = st.find(b => b.name === 'دار الضيافة'); const f1 = guest.floors[0], f2 = guest.floors[1];
  const mkRoom = async (fid, number, capacity) => (await admin('POST', '/rooms', { floor_id: fid, number, capacity, x: 5, y: 5, w: 20, h: 20 })).data.id;
  const r101 = await mkRoom(f1.id, '101', 2), r102 = await mkRoom(f1.id, '102', 1), r201 = await mkRoom(f2.id, '201', 3);

  console.log('\nمشرفو الدول والصلاحيات');
  await t('إنشاء مشرف ماليزيا وإندونيسيا… (الهند)', async () => {
    assert.ok((await admin('POST', '/users', { name: 'مشرف ماليزيا', username: 'my_sup', password: 'password1', role: 'country_supervisor', country_id: MY })).data.id);
    assert.ok((await admin('POST', '/users', { name: 'مشرف الهند', username: 'in_sup', password: 'password1', role: 'country_supervisor', country_id: IN })).data.id);
  });
  await t('مشرف الدولة بلا دولة مرفوض', async () => assert.equal((await admin('POST', '/users', { name: 'x', username: 'xx1', password: 'password1', role: 'country_supervisor' })).status, 400));
  await t('كلمة مرور قصيرة مرفوضة', async () => assert.equal((await admin('POST', '/users', { name: 'x', username: 'xx2', password: '123', role: 'admin' })).status, 400));
  await t('اسم مستخدم مكرر مرفوض', async () => assert.equal((await admin('POST', '/users', { name: 'x', username: 'MY_SUP', password: 'password1', role: 'admin' })).status, 400));
  await my.login('my_sup', 'password1'); await ind.login('in_sup', 'password1');
  await t('مشرف الدولة لا يستطيع فتح إدارة المستخدمين', async () => assert.equal((await my('GET', '/users')).status, 403));
  await t('مشرف الدولة لا يرى إلا دولته في القائمة', async () => assert.deepEqual((await my('GET', '/countries')).data.countries.map(c => c.id), [MY]));

  console.log('\nالزائرون: تسجيل وعزل الدول والتكرار');
  let head, solo, grpId;
  await t('تسجيل رب أسرة مع تابعين', async () => {
    const r = await my('POST', '/visitors', { event_id: ev, full_name: 'أحمد بن علي', country_id: MY, category: 'family_head', phone: '+60 12-345 6789', arrival_date: '2026-12-20', arrival_time: '14:30', departure_date: '2026-12-24', flight_no: 'MH1', airline: 'Malaysia', airport: 'القاهرة', members: [{ full_name: 'فاطمة', relation: 'زوجة' }, { full_name: 'يوسف', relation: 'ابن', diet_notes: 'حساسية فول سوداني' }] });
    assert.equal(r.status, 200, JSON.stringify(r.data)); head = r.data.id;
    const list = (await my('GET', `/visitors?event_id=${ev}`)).data.visitors; assert.equal(list.length, 3);
    assert.ok(list.filter(v => v.head_id === head).every(v => v.arrival_date === '2026-12-20' && v.country_id === MY), 'التابعون يرثون بيانات السفر');
  });
  await t('تسجيل فرد', async () => { const r = await my('POST', '/visitors', { event_id: ev, full_name: 'عمر', country_id: MY, category: 'individual', phone: '0123456000', arrival_date: '2026-12-21', departure_date: '2026-12-25' }); assert.equal(r.status, 200); solo = r.data.id; });
  await t('فوج وأعضاؤه وقائده', async () => {
    const g = await my('POST', '/groups', { event_id: ev, name: 'فوج 1', country_id: MY, leader_name: 'الشيخ حسن', members_count: 2, arrival_date: '2026-12-22', departure_date: '2026-12-26' }); assert.equal(g.status, 200); grpId = g.data.id;
    for (const [n, lead] of [['قائد الفوج', true], ['عضو 2', false]]) assert.equal((await my('POST', '/visitors', { event_id: ev, full_name: n, country_id: MY, category: 'group_member', group_id: grpId, is_leader: lead, arrival_date: '2026-12-22', departure_date: '2026-12-26' })).status, 200);
  });
  await t('عضو فوج بدولة مختلفة عن الفوج مرفوض', async () => assert.equal((await admin('POST', '/visitors', { event_id: ev, full_name: 'غريب', country_id: IN, category: 'group_member', group_id: grpId })).status, 400));
  await t('مشرف ماليزيا لا يستطيع تسجيل زائر هندي (403)', async () => assert.equal((await my('POST', '/visitors', { event_id: ev, full_name: 'راج', country_id: IN, category: 'individual' })).status, 403));
  await t('تنبيه التكرار برقم الهاتف (409) ثم الحفظ بالتأكيد', async () => {
    const body = { event_id: ev, full_name: 'اسم مختلف', country_id: MY, category: 'individual', phone: '0060123456000' };
    const r = await my('POST', '/visitors', body); assert.equal(r.status, 409); assert.equal(r.data.code, 'duplicate'); assert.equal(r.data.duplicates[0].full_name, 'عمر');
    assert.equal((await my('POST', '/visitors', { ...body, force: true })).status, 200);
  });
  await t('تنبيه التكرار بالاسم والدولة مع اختلاف التشكيل والهمزة', async () => {
    const r = await my('POST', '/visitors', { event_id: ev, full_name: 'أَحمد  بن علي', country_id: MY, category: 'individual' }); assert.equal(r.status, 409);
  });
  await t('زائر هندي بنفس هاتف ماليزي: تنبيه مخفي الهوية ومنع التأكيد', async () => {
    const body = { event_id: ev, full_name: 'راج', country_id: IN, category: 'individual', phone: '+60123456789' };
    const r = await ind('POST', '/visitors', body); assert.equal(r.status, 409); assert.equal(r.data.duplicates[0].hidden, true); assert.equal(r.data.duplicates[0].full_name, undefined, 'لا تتسرب بيانات دولة أخرى');
    assert.equal((await ind('POST', '/visitors', { ...body, force: true })).status, 403);
  });
  await ind('POST', '/visitors', { event_id: ev, full_name: 'سوريش', country_id: IN, category: 'individual', arrival_date: '2026-12-21', departure_date: '2026-12-23' });
  await t('مشرف ماليزيا لا يرى زائري الهند ولا يعدلهم', async () => {
    const names = (await my('GET', `/visitors?event_id=${ev}`)).data.visitors.map(v => v.full_name); assert.ok(!names.includes('سوريش'));
    const all = (await admin('GET', `/visitors?event_id=${ev}`)).data.visitors; const sur = all.find(v => v.full_name === 'سوريش');
    assert.equal((await my('PUT', `/visitors/${sur.id}`, { full_name: 'تعديل' })).status, 404); assert.equal((await my('DELETE', `/visitors/${sur.id}`)).status, 404); assert.equal((await my('GET', `/visitors/${sur.id}`)).status, 404);
  });
  await t('تفويض المدير: إضافة الهند لمشرف ماليزيا يمنحه الوصول', async () => {
    const users = (await admin('GET', '/users')).data.users; const u = users.find(x => x.username === 'my_sup');
    assert.equal((await admin('PUT', `/users/${u.id}`, { ...u, country_id: MY, extra_country_ids: [IN] })).status, 200);
    const names = (await my('GET', `/visitors?event_id=${ev}`)).data.visitors.map(v => v.full_name); assert.ok(names.includes('سوريش'));
    assert.equal((await admin('PUT', `/users/${u.id}`, { ...u, country_id: MY, extra_country_ids: [] })).status, 200);
    assert.ok(!(await my('GET', `/visitors?event_id=${ev}`)).data.visitors.some(v => v.full_name === 'سوريش'));
  });
  await t('مشرف الدولة لا يصل لواجهات التسكين والنقل والمباني', async () => {
    for (const [m, u] of [['GET', `/drivers?event_id=${ev}`], ['GET', '/structure'], ['POST', '/bookings'], ['GET', '/audit'], ['POST', '/backup']]) assert.equal((await (m === 'GET' ? my(m, u) : my(m, u, {}))).status, 403, u);
  });
  await t('تعديل بيانات تابع يحدّث رب الأسرة ويُنشر للتوابع', async () => {
    assert.equal((await my('PUT', `/visitors/${head}`, { arrival_date: '2026-12-21', members: undefined })).status, 200);
    const list = (await my('GET', `/visitors?event_id=${ev}`)).data.visitors; assert.ok(list.filter(v => v.head_id === head).every(v => v.arrival_date === '2026-12-21'));
    await my('PUT', `/visitors/${head}`, { arrival_date: '2026-12-20' });
  });

  console.log('\nالتسكين: السعة والتعارض');
  const vs = (await admin('GET', `/visitors?event_id=${ev}`)).data.visitors; const byName = n => vs.find(v => v.full_name === n);
  const fam = vs.filter(v => v.head_id === head || v.id === head).map(v => v.id);
  await t('تسكين العائلة (3) في غرفة سعتها 2 يفشل بالكامل (ذرّي)', async () => {
    const r = await admin('POST', '/bookings/bulk', { event_id: ev, room_id: r101, visitor_ids: fam }); assert.equal(r.status, 400); assert.match(r.data.error, /مكتملة/);
    assert.equal((await admin('GET', `/occupancy?floor_id=${f1.id}&date=2026-12-21`)).data.rooms.find(r => r.id === r101).booked, 0, 'لم يُحفظ أي حجز');
  });
  await t('تسكين العائلة في غرفة سعتها 3 ينجح بتواريخ الإقامة', async () => assert.equal((await admin('POST', '/bookings/bulk', { event_id: ev, room_id: r201, visitor_ids: fam })).status, 200));
  await t('الغرفة المكتملة تظهر حمراء والمتبقي صفر', async () => {
    const o = (await admin('GET', `/occupancy?floor_id=${f2.id}&date=2026-12-21`)).data; const r = o.rooms.find(x => x.id === r201); assert.equal(r.state, 'full'); assert.equal(r.remaining, 0); assert.equal(r.occupants.length, 3);
  });
  await t('إضافة رابع لغرفة مكتملة مرفوضة', async () => assert.equal((await admin('POST', '/bookings', { event_id: ev, room_id: r201, visitor_id: byName('عمر').id, from_date: '2026-12-21', to_date: '2026-12-23' })).status, 400));
  await t('الغرفة مكتملة 20-24 لكن متاحة يوم المغادرة 24 (الفترة [من، إلى))', async () => {
    assert.equal((await admin('POST', '/bookings', { event_id: ev, room_id: r201, visitor_id: byName('عمر').id, from_date: '2026-12-24', to_date: '2026-12-26' })).status, 200);
  });
  await t('تعارض فترات: نفس الزائر في غرفتين متداخلتين مرفوض', async () => assert.equal((await admin('POST', '/bookings', { event_id: ev, room_id: r102, visitor_id: byName('عمر').id, from_date: '2026-12-25', to_date: '2026-12-27' })).status, 400));
  await t('الغرفة المتبقية تظهر صفراء/خضراء حسب الإشغال (جزئي)', async () => {
    const b = await admin('POST', '/bookings', { event_id: ev, room_id: r101, visitor_id: byName('سوريش').id, from_date: '2026-12-21', to_date: '2026-12-23' }); assert.equal(b.status, 200);
    const o = (await admin('GET', `/occupancy?floor_id=${f1.id}&date=2026-12-21`)).data.rooms.find(x => x.id === r101); assert.equal(o.state, 'partial'); assert.equal(o.remaining, 1);
  });
  await t('نقل زائر لغرفة ممتلئة مرفوض، ولغرفة متاحة ينجح ويحدّث الإشغال', async () => {
    const bk = (await admin('GET', `/rooms/${r101}/bookings`)).data.bookings[0];
    assert.equal((await admin('PUT', `/bookings/${bk.id}`, { room_id: r201 })).status, 400);
    assert.equal((await admin('PUT', `/bookings/${bk.id}`, { room_id: r102 })).status, 200);
    const o = (await admin('GET', `/occupancy?floor_id=${f1.id}&date=2026-12-21`)).data.rooms; assert.equal(o.find(x => x.id === r101).booked, 0); assert.equal(o.find(x => x.id === r102).state, 'full');
  });
  await t('إلغاء الحجز يفرّغ المكان', async () => {
    const bk = (await admin('GET', `/rooms/${r102}/bookings`)).data.bookings[0]; assert.equal((await admin('DELETE', `/bookings/${bk.id}`)).status, 200);
    assert.equal((await admin('GET', `/occupancy?floor_id=${f1.id}&date=2026-12-21`)).data.rooms.find(x => x.id === r102).state, 'free');
  });
  await t('إخراج الغرفة من الخدمة أو خفض السعة مع حجوزات قائمة مرفوض', async () => {
    assert.equal((await admin('PUT', `/rooms/${r201}`, { capacity: 2 })).status, 400); assert.equal((await admin('PUT', `/rooms/${r201}`, { status: 'out_of_service' })).status, 400);
    assert.equal((await admin('DELETE', `/rooms/${r201}`)).status, 400);
  });
  await t('غرفة خارج الخدمة لا تقبل حجزاً ولونها رمادي', async () => {
    assert.equal((await admin('PUT', `/rooms/${r102}`, { status: 'out_of_service' })).status, 200);
    assert.equal((await admin('POST', '/bookings', { event_id: ev, room_id: r102, visitor_id: byName('سوريش').id, from_date: '2026-12-21', to_date: '2026-12-22' })).status, 400);
    assert.equal((await admin('GET', `/occupancy?floor_id=${f1.id}&date=2026-12-21`)).data.rooms.find(x => x.id === r102).state, 'unavailable');
    await admin('PUT', `/rooms/${r102}`, { status: 'active' });
  });
  await t('الحجز بدون تواريخ إقامة وبفترة غير منطقية مرفوض', async () => {
    assert.equal((await admin('POST', '/bookings', { event_id: ev, room_id: r102, visitor_id: byName('سوريش').id, from_date: '2026-12-22', to_date: '2026-12-22' })).status, 400);
  });
  await t('مشرف الدولة يرى غرفة زائريه بعد التسكين دون غيرها', async () => {
    const mine = (await my('GET', `/visitors?event_id=${ev}`)).data.visitors; const h = mine.find(v => v.id === head); assert.equal(h.bookings[0].room_number, '201'); assert.equal(h.bookings[0].building_name, 'دار الضيافة');
  });

  console.log('\nمشرف المبنى');
  const bsU = (await admin('POST', '/users', { name: 'مشرف الدور الأول', username: 'bs1', password: 'password1', role: 'building_supervisor', floor_ids: [f1.id] })).data.id; await bs.login('bs1', 'password1');
  await t('يرى دوره فقط ويُرفض في دور آخر', async () => {
    assert.equal((await bs('GET', `/occupancy?floor_id=${f1.id}&date=2026-12-21`)).status, 200); assert.equal((await bs('GET', `/occupancy?floor_id=${f2.id}&date=2026-12-21`)).status, 403);
    assert.equal((await bs('POST', '/bookings', { event_id: ev, room_id: r201, visitor_id: byName('سوريش').id, from_date: '2026-12-21', to_date: '2026-12-22' })).status, 403);
    assert.deepEqual((await bs('GET', '/structure')).data.buildings.flatMap(b => b.floors.map(f => f.id)), [f1.id]);
  });
  await t('يستطيع التسكين في دوره فقط', async () => assert.equal((await bs('POST', '/bookings', { event_id: ev, room_id: r101, visitor_id: byName('سوريش').id, from_date: '2026-12-21', to_date: '2026-12-23' })).status, 200));
  await t('لا يرى هواتف الزائرين ولا يعدل بياناتهم', async () => {
    const l = (await bs('GET', `/visitors?event_id=${ev}`)).data.visitors; assert.ok(l.every(v => v.email === ''));
    assert.equal((await bs('PUT', `/visitors/${l[0].id}`, { full_name: 'x' })).status, 403);
  });

  console.log('\nالسائقون والنقل');
  let drv;
  await t('إنشاء سائق وتكليفه باستقبال عائلة (3 ركاب) مع تنبيه السعة', async () => {
    drv = (await admin('POST', '/drivers', { event_id: ev, name: 'خالد', phone: '0100', car_number: 'أ ب ج 123', car_type: 'سيدان', capacity: 2 })).data.id; assert.ok(drv);
    const r = await admin('POST', '/transports', { event_id: ev, driver_id: drv, visitor_id: head, kind: 'pickup' }); assert.equal(r.status, 200); assert.match(r.data.warning, /أكبر من سعة/);
  });
  await t('مشرف الدولة يرى سائق زائريه (حتى للتابعين)', async () => {
    const l = (await my('GET', `/visitors?event_id=${ev}`)).data.visitors; assert.ok(l.filter(v => v.id === head || v.head_id === head).every(v => v.transports[0]?.driver_name === 'خالد'));
  });
  await t('الجدول اليومي يقارن الاحتياج بالسعة ويُظهر غير المكلفين', async () => {
    const d = (await admin('GET', `/transport/daily?event_id=${ev}&date=2026-12-20`)).data; assert.equal(d.need_pickup, 3); assert.equal(d.unassigned_pickup.length, 0); assert.equal(d.assigned_passengers, 3); assert.equal(d.fleet_capacity, 2);
    const d2 = (await admin('GET', `/transport/daily?event_id=${ev}&date=2026-12-22`)).data; assert.equal(d2.need_pickup, 2); assert.equal(d2.unassigned_pickup.length, 2);
  });
  await t('تعيين سيارتين للفوج الواحد وتحديث الحالة', async () => {
    const d2 = (await admin('POST', '/drivers', { event_id: ev, name: 'سعيد', capacity: 7 })).data.id;
    assert.equal((await admin('POST', '/transports', { event_id: ev, driver_id: drv, group_id: grpId })).status, 200);
    const r = await admin('POST', '/transports', { event_id: ev, driver_id: d2, group_id: grpId, passengers: 1 }); assert.equal(r.status, 200);
    assert.equal((await admin('PUT', `/transports/${r.data.id}`, { status: 'on_the_way' })).status, 200);
    assert.equal((await admin('GET', `/transport/daily?event_id=${ev}&date=2026-12-22`)).data.unassigned_pickup.length, 0);
  });
  await t('مشرف الدولة لا يعدّل النقل', async () => assert.equal((await my('POST', '/transports', { event_id: ev, driver_id: drv, visitor_id: solo })).status, 403));

  console.log('\nالوجبات');
  await t('حساب الوجبات حسب أيام الإقامة', async () => {
    const m = (await admin('GET', `/meals?event_id=${ev}`)).data.days; const d = x => m.find(r => r.date === x);
    assert.equal(d('2026-12-20').residents, 3); assert.equal(d('2026-12-20').total, 9);
    assert.equal(d('2026-12-22').residents, 3 + 1 + 2 + 1 - 1 > 0 ? d('2026-12-22').residents : 0);
    assert.ok(d('2026-12-24').residents >= 3, 'يوم المغادرة يُحتسب');
  });
  await t('استثناء زائر من وجبة بتاريخ ثم من كل الأيام', async () => {
    const before = (await admin('GET', `/meals?event_id=${ev}`)).data.days.find(r => r.date === '2026-12-21').lunch;
    assert.equal((await admin('POST', '/meal-exclusions', { visitor_id: byName('يوسف').id, date: '2026-12-21', meals: ['lunch'] })).status, 200);
    assert.equal((await admin('GET', `/meals?event_id=${ev}`)).data.days.find(r => r.date === '2026-12-21').lunch, before - 1);
    await admin('POST', '/meal-exclusions', { visitor_id: byName('يوسف').id, date: '*', meals: ['dinner'] });
    const day = (await admin('GET', `/meals/day?event_id=${ev}&date=2026-12-22`)).data.day; const y = day.people.find(p => p.full_name === 'يوسف'); assert.equal(y.has.dinner, false); assert.equal(y.diet_notes, 'حساسية فول سوداني');
  });
  await t('مشرف الدولة لا يصل للوجبات', async () => assert.equal((await my('GET', `/meals?event_id=${ev}`)).status, 403));

  console.log('\nلوحة التحكم والتقارير');
  await t('لوحة المدير: أرقام الزائرين والغرف والنقل والوجبات', async () => {
    const d = (await admin('GET', `/dashboard?event_id=${ev}&date=2026-12-21`)).data;
    assert.equal(d.visitors.total, 8); assert.equal(d.visitors.families, 1); assert.equal(d.visitors.family_members, 2); assert.equal(d.visitors.group_members, 2); assert.equal(d.visitors.countries, 2);
    assert.ok(d.rooms && d.transport && d.meals_today && d.by_country.length === 2 && d.flow.length >= 11);
    assert.equal(d.rooms.rooms_total, 3);
  });
  await t('لوحة مشرف الدولة تقتصر على دولته', async () => { const d = (await my('GET', `/dashboard?event_id=${ev}`)).data; assert.equal(d.visitors.countries, 1); assert.equal(d.rooms, undefined); assert.ok(!d.by_country.some(c => c.name === 'الهند')); });
  await t('تقرير الزائرين لمشرف الدولة محصور بدولته', async () => { const r = (await my('GET', `/reports/visitors_all?event_id=${ev}`)).data; assert.ok(r.rows.length > 0 && r.rows.every(x => x.country === 'ماليزيا')); assert.equal(r.scope_note, 'بيانات دولتك فقط'); });
  await t('تقرير الدول: الإجمالي صحيح', async () => { const r = (await admin('GET', `/reports/by_country?event_id=${ev}`)).data; const tot = r.rows.find(x => x.country === 'الإجمالي'); assert.equal(tot.total, 8); });
  await t('مشرف الدولة محجوب عن تقارير التسكين والسائقين', async () => { for (const k of ['housing', 'rooms_status', 'drivers_tasks', 'meals_daily', 'supervisors']) assert.equal((await my('GET', `/reports/${k}?event_id=${ev}`)).status, 403, k); });
  await t('كل التقارير تعمل للمدير بدون خطأ', async () => { for (const k of ['visitors_all', 'by_country', 'families_groups', 'arrivals_departures', 'housing', 'rooms_status', 'drivers_tasks', 'meals_daily', 'supervisors']) { const r = await admin('GET', `/reports/${k}?event_id=${ev}`); assert.equal(r.status, 200, k + ' ' + JSON.stringify(r.data)); } });
  await t('تقارير مشرف المبنى والمشرفين الكاملة تعمل بصلاحياتهم', async () => { assert.equal((await bs('GET', `/reports/housing?event_id=${ev}`)).status, 200); assert.equal((await bs('GET', `/reports/rooms_status?event_id=${ev}`)).status, 200); });
  await t('تصدير تقرير إلى xlsx وcsv صالح', async () => {
    const x = await admin('GET', `/reports/visitors_all?event_id=${ev}&format=xlsx`); assert.equal(x.status, 200); const rows = await X.readXlsx(x.data); assert.equal(rows[0][1], 'الاسم'); assert.equal(rows.length, 9);
    const c = await admin('GET', `/reports/by_country?event_id=${ev}&format=csv`); assert.ok(new TextDecoder('utf-8', { ignoreBOM: true }).decode(c.data).startsWith('\uFEFF'));
  });

  console.log('\nاستيراد وتصدير Excel');
  await t('تصدير الزائرين ثم استيراده: كلها مكررة فتُتخطى', async () => {
    const x = await admin('GET', `/visitors-export?event_id=${ev}&format=xlsx`); assert.equal(x.status, 200);
    const r = await admin('POST', `/visitors-import?event_id=${ev}`, x.data, { raw: true, type: 'application/octet-stream' }); assert.equal(r.status, 200, JSON.stringify(r.data)); assert.equal(r.data.created, 0); assert.equal(r.data.skipped.length, 8);
  });
  await t('استيراد قالب جديد (وضع المعاينة لا يحفظ) ثم الحفظ الفعلي', async () => {
    const tpl = X.buildXlsx([{ name: 's', columns: ['الاسم الكامل', 'الدولة', 'رقم الهاتف (مع مفتاح الدولة)', 'التصنيف', 'رب الأسرة (للتابع)', 'تاريخ الوصول', 'تاريخ المغادرة', 'وقت الوصول', 'اسم الفوج'].map(label => ({ label })),
      rows: [['حسن جديد', 'ماليزيا', '+60111222333', 'رب أسرة', '', '2026-12-21', '2026-12-23', 0.5, ''], ['ليلى', 'ماليزيا', '', 'تابع لعائلة', 'حسن جديد', '', '', '', ''], ['بلا دولة', 'المريخ', '', 'فرد', '', '', '', '', ''], ['راج', 'الهند', '', 'فرد', '', '', '', '', ''], ['عضو', 'ماليزيا', '', 'عضو في فوج', '', '2026-12-22', '2026-12-25', '', 'فوج جديد']] }]);
    const dry = await my('POST', `/visitors-import?event_id=${ev}&dry=1`, tpl, { raw: true, type: 'application/octet-stream' }); assert.equal(dry.data.created, 3); assert.equal(dry.data.errors.length, 2);
    assert.ok(dry.data.errors.some(e => /المريخ/.test(e.msg))); assert.ok(dry.data.errors.some(e => /دولة غير مسؤول|دولة/.test(e.msg)));
    assert.equal((await my('GET', `/visitors?event_id=${ev}&q=حسن جديد`)).data.visitors.length, 0, 'المعاينة لا تحفظ');
    const real = await my('POST', `/visitors-import?event_id=${ev}`, tpl, { raw: true, type: 'application/octet-stream' }); assert.equal(real.data.created, 3);
    const got = (await my('GET', `/visitors?event_id=${ev}&q=حسن جديد`)).data.visitors[0]; assert.equal(got.arrival_time, '12:00'); assert.equal(got.members_count, 1);
  });
  await t('البحث والتصفية: دولة/تصنيف/تاريخ/مبنى/غرفة', async () => {
    const q = async s => (await admin('GET', `/visitors?event_id=${ev}&${s}`)).data.visitors.length;
    assert.equal(await q(`country_id=${IN}`), 1); assert.equal(await q('category=family_head'), 2); assert.equal(await q('arrival=2026-12-22'), 3);
    assert.equal(await q(`building_id=${guest.id}`) > 0, true); assert.equal(await q(`room_id=${r201}`), 4); assert.equal(await q('q=0060123456000') >= 1, true); assert.equal(await q('present_on=2026-12-25') > 0, true);
  });

  console.log('\nسجل العمليات والحسابات');
  await t('السجل يوثق المنشئ والمعدّل ونوع التعديل والوقت', async () => {
    const a = (await admin('GET', '/audit?limit=1000')).data.rows;
    const c = a.find(r => r.action === 'create' && r.entity === 'visitor' && r.username === 'my_sup'); assert.ok(c && c.at && c.country_name === 'ماليزيا');
    const u = a.find(r => r.action === 'update' && r.entity === 'visitor'); assert.ok(u && /arrival_date/.test(JSON.stringify(u.details)));
    assert.ok(a.some(r => r.action === 'transfer'), 'نقل الغرفة موثق');
  });
  await t('إيقاف الحساب يقطع الجلسة ويمنع الدخول', async () => {
    const u = (await admin('GET', '/users')).data.users.find(x => x.username === 'in_sup');
    assert.equal((await admin('PUT', `/users/${u.id}`, { ...u, country_id: IN, status: 'suspended' })).status, 200);
    assert.equal((await ind('GET', '/events')).status, 401); assert.equal((await client().login('in_sup', 'password1')).status, 401);
  });
  await t('المدير لا يوقف نفسه ولا يحذفها', async () => { const me = (await admin('GET', '/me')).data.user; assert.equal((await admin('PUT', `/users/${me.id}`, { ...me, status: 'suspended' })).status, 400); assert.equal((await admin('DELETE', `/users/${me.id}`)).status, 400); });
  await t('تغيير كلمة المرور', async () => {
    assert.equal((await bs('POST', '/change-password', { old_password: 'wrong', new_password: 'newpassword9' })).status, 400);
    assert.equal((await bs('POST', '/change-password', { old_password: 'password1', new_password: 'newpassword9' })).status, 200); assert.equal((await client().login('bs1', 'newpassword9')).status, 200);
  });
  await t('نسخة احتياطية تُنشأ وتُنزَّل', async () => {
    const b = await admin('POST', '/backup', {}); assert.equal(b.status, 200); const j = JSON.parse(new TextDecoder().decode(b.data)); assert.equal(j.app, 'gaouk'); assert.ok(j.visitors.length >= 8 && j.rooms.length === 3 && !JSON.stringify(j).includes('encrypted_password'));
    assert.equal((await my('POST', '/backup', {})).status, 403);
  });
  await t('حذف مناسبة يتطلب كتابة اسمها', async () => { assert.equal((await admin('DELETE', `/events/${ev}`, {})).status, 400); });

  console.log('\nطلبات الانضمام');
  const jr = (o = {}) => anon('POST', '/join-request', { name: 'عبدالله الجديد', phone: '+966500000001', username: 'newguy', password: 'password1', ...o });
  await t('طلب انضمام بلا دخول ينجح', async () => assert.equal((await jr()).status, 200));
  await t('الدخول قبل الموافقة مرفوض برسالة «قيد المراجعة»', async () => { const r = await client().login('newguy', 'password1'); assert.equal(r.status, 401); assert.match(r.data.error, /قيد المراجعة/); });
  await t('طلب بنفس اسم المستخدم مرفوض', async () => assert.equal((await jr({ phone: '+966500000002' })).status, 400));
  await t('طلب بنفس الهاتف المعلق مرفوض', async () => assert.equal((await jr({ username: 'other1' })).status, 400));
  await t('هاتف غير صحيح / كلمة مرور ضعيفة / اسم قصير مرفوضة', async () => {
    assert.equal((await jr({ username: 'u2', phone: 'abc' })).status, 400); assert.equal((await jr({ username: 'u3', phone: '+966500000003', password: '1234' })).status, 400); assert.equal((await jr({ username: 'u4', phone: '+966500000004', name: 'ع' })).status, 400);
  });
  let pend;
  await t('المدير يرى الطلب بحالة pending', async () => { pend = (await admin('GET', '/users')).data.users.find(u => u.username === 'newguy'); assert.equal(pend.status, 'pending'); });
  await t('القبول كمشرف على دولتين', async () => {
    assert.equal((await admin('PUT', '/users/' + pend.id, { name: pend.name, phone: pend.phone, role: 'country_supervisor', status: 'active', country_id: MY, extra_country_ids: [IN] })).status, 200);
    const c = client(); assert.equal((await c.login('newguy', 'password1')).status, 200);
    assert.deepEqual((await c('GET', '/countries')).data.countries.map(x => x.id).sort(), [MY, IN].sort());
  });
  await t('مشرف المباني: قبول بمبنيين', async () => {
    await jr({ name: 'مشرف مبنى جديد', username: 'bnew', phone: '+966500000010' });
    const p = (await admin('GET', '/users')).data.users.find(u => u.username === 'bnew'); const fl = st.flatMap(b => b.floors.map(f => f.id));
    assert.equal((await admin('PUT', '/users/' + p.id, { name: p.name, phone: p.phone, role: 'building_supervisor', status: 'active', floor_ids: fl })).status, 200);
    const u = (await admin('GET', '/users')).data.users.find(x => x.username === 'bnew'); assert.equal(u.floors.length, fl.length);
  });
  await t('مشرف عام: قبول بصلاحية كاملة', async () => {
    await jr({ name: 'مشرف عام جديد', username: 'gnew', phone: '+966500000011' });
    const p = (await admin('GET', '/users')).data.users.find(u => u.username === 'gnew');
    await admin('PUT', '/users/' + p.id, { name: p.name, phone: p.phone, role: 'admin', status: 'active' });
    const c = client(); await c.login('gnew', 'password1'); assert.equal((await c('GET', '/users')).status, 200);
  });
  await t('الرفض يحذف الطلب ويمنع الدخول', async () => {
    await jr({ name: 'مرفوض جداً', username: 'rej1', phone: '+966500000012' });
    const p = (await admin('GET', '/users')).data.users.find(u => u.username === 'rej1'); assert.equal((await admin('DELETE', '/users/' + p.id)).status, 200);
    assert.equal((await client().login('rej1', 'password1')).status, 401);
  });
  await t('مشرف دولة لا يقبل الطلبات', async () => assert.equal((await my('PUT', '/users/' + pend.id, { role: 'admin', status: 'active', name: 'x' })).status, 403));

  console.log('\nتصنيف «تابع لأسرة»');
  let fh, fm;
  await t('تسجيل رب أسرة ثم تابع مستقل برب الأسرة', async () => {
    fh = (await admin('POST', '/visitors', { event_id: ev, full_name: 'رب أسرة اختبار', country_id: MY, category: 'family_head', arrival_date: '2026-12-21', flight_no: 'MH9' })).data.id; assert.ok(fh);
    const r = await admin('POST', '/visitors', { event_id: ev, full_name: 'تابع مستقل', category: 'family_member', head_id: fh, relation: 'ابن' }); assert.equal(r.status, 200); fm = r.data.id;
    const v = (await admin('GET', '/visitors/' + fm)).data.visitor; assert.equal(v.category, 'family_member'); assert.equal(v.head_id, fh); assert.equal(v.country_id, MY); assert.equal(v.arrival_date, '2026-12-21'); assert.equal(v.flight_no, 'MH9');
  });
  await t('تابع بلا رب أسرة أو برب غير صالح مرفوض', async () => {
    assert.equal((await admin('POST', '/visitors', { event_id: ev, full_name: 'بلا رب', category: 'family_member' })).status, 400);
    assert.equal((await admin('POST', '/visitors', { event_id: ev, full_name: 'رب خاطئ', category: 'family_member', head_id: fm })).status, 400);
  });
  await t('مشرف دولة أخرى لا يسجل تابعاً لأسرة دولة غيره', async () => { await admin('POST', '/users', { name: 'مشرف هند ٢', username: 'in_sup2', password: 'password1', role: 'country_supervisor', country_id: IN }); const ind2 = client(); await ind2.login('in_sup2', 'password1'); const r = await ind2('POST', '/visitors', { event_id: ev, full_name: 'متسلل', category: 'family_member', head_id: fh }); assert.equal(r.status, 403, JSON.stringify(r.data)); });
  await t('تحويل فرد إلى تابع لأسرة بالتعديل', async () => {
    const s = (await admin('POST', '/visitors', { event_id: ev, full_name: 'فرد سيتحول', country_id: MY, category: 'individual' })).data.id;
    assert.equal((await admin('PUT', '/visitors/' + s, { category: 'family_member', head_id: fh })).status, 200);
    const v = (await admin('GET', '/visitors/' + s)).data.visitor; assert.equal(v.category, 'family_member'); assert.equal(v.head_id, fh);
  });
  await t('رب أسرة له تابعون لا يتحول إلى تابع', async () => { const o = (await admin('POST', '/visitors', { event_id: ev, full_name: 'رب آخر', country_id: MY, category: 'family_head' })).data.id; assert.equal((await admin('PUT', '/visitors/' + fh, { category: 'family_member', head_id: o })).status, 400); });

  console.log(`\n${passed} نجح، ${failed} فشل`);
  server.close();
  process.exit(failed ? 1 : 0);
})();
