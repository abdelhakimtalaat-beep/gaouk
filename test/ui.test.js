'use strict';
// اختبار الواجهة في متصفح حقيقي (Chrome headless) على النسخة الجديدة (Supabase محاكاة فوق Postgres حقيقي)
const fs = require('node:fs'), assert = require('node:assert/strict');
const { server } = require('./mock-supabase');
const { client, ctx: H } = require('./helpers');
const { chromium } = require('/opt/npm-tools/node_modules/playwright');
const OUT = process.env.SHOTS || '/tmp/shots-sb'; fs.mkdirSync(OUT, { recursive: true });

let passed = 0, failed = 0;
const t = async (name, fn) => { try { await fn(); passed++; console.log('  ✓', name); } catch (e) { failed++; console.log('  ✗', name, '\n     ', String(e.message).split('\n')[0]); } };

(async () => {
  await new Promise(r => server.listen(0, '127.0.0.1', r)); const base = 'http://127.0.0.1:' + server.address().port; H.base = base;
  // --- بيانات تجريبية عبر نفس طبقة الواجهة ---
  const adminC = client(); await adminC.login('admin', 'AdminPass123');
  const api = async (m, u, b) => { const r = await adminC(m, u, b); if (r.status !== 200) { const e = new Error(u + ' ' + (r.data.error || r.status)); e.status = r.status; throw e; } return r.data; };
  const co = (await api('GET', '/countries')).countries; const cid = n => co.find(c => c.name === n).id;
  const ev = (await api('POST', '/events', { name: 'موسم الشتاء ٢٠٢٦', start_date: '2026-11-10', end_date: '2026-11-20', expected_visitors: 40, description: 'استقبال الوفود' })).id;
  const st = (await api('GET', '/structure')).buildings; const guest = st.find(b => b.name === 'دار الضيافة'); const fl = guest.floors[0];
  const rooms = [];
  const spec = [['101', 4, 4, 6, 22, 20], ['102', 3, 28, 6, 22, 20], ['103', 2, 52, 6, 22, 20], ['104', 6, 76, 6, 20, 20], ['105', 2, 4, 40, 30, 26], ['106', 4, 38, 40, 28, 26], ['107', 2, 70, 40, 26, 26]];
  for (const [n, c, x, y, w, h] of spec) rooms.push((await api('POST', '/rooms', { floor_id: fl.id, number: n, capacity: c, x, y, w, h })).id);
  await api('PUT', '/rooms/' + rooms[6], { status: 'out_of_service' });
  await api('POST', '/users', { name: 'أمين ماليزيا', username: 'my_sup', password: 'password1', role: 'country_supervisor', country_id: cid('ماليزيا'), phone: '+60111' });
  await api('POST', '/users', { name: 'مشرف الهند', username: 'in_sup', password: 'password1', role: 'country_supervisor', country_id: cid('الهند') });
  await api('POST', '/users', { name: 'مشرف دار الضيافة', username: 'bsup', password: 'password1', role: 'building_supervisor', floor_ids: [fl.id] });
  const mk = (n, country, extra = {}) => api('POST', '/visitors', { event_id: ev, full_name: n, country_id: cid(country), category: 'individual', arrival_date: '2026-11-12', arrival_time: '15:00', departure_date: '2026-11-16', airport: 'مطار القاهرة', flight_no: 'MH' + Math.floor(Math.random() * 900 + 100), airline: 'الخطوط الماليزية', ...extra });
  const h = (await mk('عبدالرحمن بن إسماعيل', 'ماليزيا', { category: 'family_head', phone: '+60123000111', members: [{ full_name: 'مريم', relation: 'زوجة' }, { full_name: 'إبراهيم', relation: 'ابن', diet_notes: 'حساسية مكسرات' }] })).id;
  await mk('أحمد ديب', 'الكويت', { phone: '+96550001' }); await mk('سوريش كومار', 'الهند', { departure_date: '2026-11-18' });
  const g = (await api('POST', '/groups', { event_id: ev, name: 'فوج جاكرتا 1', country_id: cid('إندونيسيا'), leader_name: 'الحاج يوسف', members_count: 3, arrival_date: '2026-11-13', departure_date: '2026-11-17' })).id;
  for (const [n, l] of [['يوسف رحمن', true], ['ديوي سارتيكا', false], ['بودي سانتوسو', false]]) await mk(n, 'إندونيسيا', { category: 'group_member', group_id: g, is_leader: l, arrival_date: '2026-11-13', departure_date: '2026-11-17' });
  const all = (await api('GET', `/visitors?event_id=${ev}`)).visitors; const fam = all.filter(v => v.id === h || v.head_id === h).map(v => v.id);
  await api('POST', '/bookings/bulk', { event_id: ev, room_id: rooms[3], visitor_ids: fam });
  await api('POST', '/bookings', { event_id: ev, room_id: rooms[0], visitor_id: all.find(v => v.full_name === 'أحمد ديب').id });
  const d1 = (await api('POST', '/drivers', { event_id: ev, name: 'خالد المنصور', phone: '01001', car_number: 'س ص ع 1234', car_type: 'ميني فان', capacity: 7 })).id;
  await api('POST', '/drivers', { event_id: ev, name: 'سعيد', capacity: 4, car_type: 'سيدان' });
  await api('POST', '/transports', { event_id: ev, driver_id: d1, visitor_id: h, kind: 'pickup' });

  const browser = await chromium.launch({ executablePath: '/usr/bin/google-chrome', args: ['--no-sandbox','--disable-background-networking','--disable-component-update','--disable-sync','--no-first-run'] });
  const errors = [];
  const newPage = async (w = 1366, h = 900) => { const ctx = await browser.newContext({ viewport: { width: w, height: h }, locale: 'ar-EG', acceptDownloads: true }); const p = await ctx.newPage(); p.on('console', m => { if (m.type() === 'error') errors.push(m.text()); }); p.on('pageerror', e => errors.push('PAGEERROR ' + e.message)); return p; };
  const login = async (p, u, pw) => { await p.goto(base); await p.fill('#u', u); await p.fill('#p', pw); await p.click('#lf button'); await p.waitForSelector('#page'); };
  const go = async (p, hash, sel) => { await p.evaluate(h => (location.hash = h), hash); await p.waitForTimeout(150); await p.waitForSelector(sel || '#page h1', { timeout: 8000 }); await p.waitForTimeout(250); };

  const p = await newPage();
  console.log('\nواجهة المدير');
  await t('صفحة الدخول RTL وبالعربية', async () => { await p.goto(base); assert.equal(await p.evaluate(() => document.documentElement.dir), 'rtl'); assert.match(await p.textContent('.login-card'), /جاؤوك/); await p.screenshot({ path: OUT + '/01-login.png' }); });
  await t('رفض دخول خاطئ برسالة عربية', async () => { await p.fill('#u', 'admin'); await p.fill('#p', 'bad'); await p.click('#lf button'); await p.waitForSelector('#lerr:not([hidden])'); assert.match(await p.textContent('#lerr'), /غير صحيحة/); });
  await t('دخول المدير وعرض لوحة التحكم', async () => { await login(p, 'admin', 'AdminPass123'); await p.waitForSelector('.stat'); await go(p, '#/dashboard', '.stat'); const txt = await p.textContent('#page'); assert.match(txt, /إجمالي الزائرين/); assert.match(txt, /نسبة إشغال المباني/); await p.screenshot({ path: OUT + '/02-dashboard.png', fullPage: true }); });
  for (const [h, name, shot] of [['#/events', 'المناسبات', '03-events'], ['#/visitors', 'الزائرون', '04-visitors'], ['#/visitors/groups', 'الأفواج', '05-groups'], ['#/drivers', 'الجدول اليومي للنقل', '07-drivers'], ['#/drivers/list', 'قائمة السائقين', ''], ['#/drivers/days', 'احتياج الأيام', ''], ['#/meals', 'الوجبات', '08-meals'], ['#/reports', 'التقارير', '09-reports'], ['#/people', 'مشرفو الدول', '10-people'], ['#/people/building', 'مشرفو المباني', ''], ['#/countries', 'الدول', '11-countries'], ['#/audit', 'سجل العمليات', '12-audit'], ['#/system', 'النسخ الاحتياطي', ''], ['#/account', 'حسابي', '']])
    await t('تحميل شاشة ' + name, async () => { await go(p, h); assert.ok(!(await p.textContent('#page')).includes('حدث خطأ')); if (shot) await p.screenshot({ path: `${OUT}/${shot}.png`, fullPage: true }); });

  console.log('\nخريطة التسكين');
  await t('عرض الكروكي بالألوان الصحيحة', async () => {
    await p.evaluate(() => { App._hs = null; }); await go(p, '#/housing', '#sb');
    // اختيار دار الضيافة/الدور الأول
    await p.selectOption('#sb', { label: 'دار الضيافة' }); await p.waitForSelector('.room');
    const cls = await p.$$eval('.room', els => Object.fromEntries(els.map(e => [e.querySelector('span').textContent, e.className.replace('room ', '')])));
    assert.equal(cls['101'], 'partial'); assert.equal(cls['102'], 'free'); assert.equal(cls['107'], 'unavailable');
    assert.equal(cls['104'], 'partial', 'غرفة 104 (6 سعة، 3 محجوزين) مشغولة جزئياً'); assert.equal(await p.$$eval('.room', e => e.length), 7);
    await p.screenshot({ path: OUT + '/06-housing-map.png', fullPage: true });
  });
  await t('النقر على غرفة يعرض نافذة التفاصيل والمقيمين', async () => {
    await p.click('.room[data-r="' + rooms[3] + '"]'); await p.waitForSelector('.modal'); const txt = await p.textContent('.modal');
    for (const s of ['السعة الإجمالية', 'المتبقي', 'عبدالرحمن بن إسماعيل', 'مريم', 'المشرف المسؤول', 'مشرف دار الضيافة']) assert.ok(txt.includes(s), s);
    await p.screenshot({ path: OUT + '/06b-room-dialog.png' }); await p.click('.modal-f button:has-text("إغلاق")');
  });
  await t('تسكين زائر من نافذة الغرفة يحدّث الخريطة فوراً', async () => {
    await p.click('.room[data-r="' + rooms[1] + '"]'); await p.waitForSelector('#al'); await p.check('#al input[type=checkbox] >> nth=0'); const first = await p.textContent('#al label >> nth=0'); await p.click('#go'); await p.waitForSelector('.modal', { state: 'detached' }).catch(() => {});
    await p.waitForSelector('.modal'); const t1 = await p.textContent('.modal'); assert.ok(/المحجوزون[^]*1/.test(t1)); await p.click('.modal-f button:has-text("إغلاق")');
    const room = await p.$eval('.room[data-r="' + rooms[1] + '"]', e => e.className); assert.ok(room.includes('partial'));
  });
  await t('منع تجاوز السعة: غرفة سعتها 2 ترفض 3', async () => {
    const fresh = []; for (const n of ['زائر أ', 'زائر ب', 'زائر ج']) fresh.push((await mk(n, 'ماليزيا')).id);
    const r = await adminC('POST', '/bookings/bulk', { event_id: ev, room_id: rooms[2], visitor_ids: fresh });
    assert.equal(r.status, 400, JSON.stringify(r.data)); assert.match(r.data.error, /مكتملة/, r.data.error);
  });
  await t('وضع تحرير الكروكي: سحب غرفة وحفظ الموضع', async () => {
    await p.click('#e_start'); await p.waitForSelector('.editing'); const el = await p.$('.room[data-r="' + rooms[2] + '"]'); const b = await el.boundingBox(); const before = await el.evaluate(e => e.style.left);
    await p.mouse.move(b.x + b.width / 2, b.y + b.height / 2); await p.mouse.down(); await p.mouse.move(b.x + b.width / 2 - 120, b.y + b.height / 2 + 60, { steps: 6 }); await p.mouse.up();
    const after = await el.evaluate(e => e.style.left); assert.notEqual(before, after); await p.waitForSelector('.dirty'); await p.click('#e_save'); await p.waitForSelector('.dirty', { state: 'detached' }); await p.screenshot({ path: OUT + '/06c-housing-edit.png', fullPage: true });
    const saved = (await api('GET', `/occupancy?floor_id=${fl.id}&date=2026-11-12`)).rooms.find(r => r.id === rooms[2]); assert.ok(Math.abs(saved.x - parseFloat(after)) < 0.6);
  });
  await t('إضافة غرفة جديدة من المحرر', async () => { await p.click('#e_add'); await p.fill('#rf [name=number]', '108'); await p.fill('#rf [name=capacity]', '5'); await p.click('.modal-f button:has-text("حفظ")'); await p.waitForSelector('.room[data-r] >> text=108'); await p.click('#e_end'); });
  await t('إدارة المباني والأدوار تفتح وتعرض المباني الخمسة', async () => { await p.click('#mgb'); await p.waitForSelector('.modal'); const txt = await p.textContent('.modal'); for (const s of ['الدار', 'دار الضيافة', 'الاستراحة الخضراء', 'البرج', 'الفرن', 'الروف']) assert.ok(txt.includes(s), s); await p.click('.modal-f button'); });

  console.log('\nتسجيل زائر عبر النموذج');
  await t('نموذج زائر جديد: رب أسرة مع تابعين + تنبيه التكرار', async () => {
    await go(p, '#/visitors', '#addv'); await p.click('#addv'); await p.waitForSelector('#vf');
    await p.fill('#vf [name=full_name]', 'خالد بن سالم'); await p.selectOption('#vf [name=country_id]', { label: 'ماليزيا' }); await p.selectOption('#vf [name=category]', 'family_head'); await p.waitForSelector('#fambox:not([hidden])');
    await p.fill('#vf [name=phone]', '+60 12 300 0111'); await p.waitForSelector('#dupbox .alert'); assert.match(await p.textContent('#dupbox'), /عبدالرحمن/); await p.screenshot({ path: OUT + '/04b-visitor-form.png' });
    await p.fill('#vf [name=phone]', '+60199888777'); await p.click('#addm'); await p.fill('.mrow input[data-k=full_name]', 'سلمى'); await p.fill('.mrow input[data-k=relation]', 'زوجة');
    await p.fill('#vf [name=arrival_date]', '2026-11-14'); await p.fill('#vf [name=departure_date]', '2026-11-18'); await p.click('.modal-f button:has-text("حفظ")'); await p.waitForSelector('#vf', { state: 'detached' });
    await p.fill('#f_q', 'سلمى'); await p.waitForTimeout(500); assert.match(await p.textContent('#vlist'), /سلمى/);
  });
  await t('البحث والتصفية حسب الدولة', async () => { await p.fill('#f_q', ''); await p.selectOption('#f_country_id', { label: 'إندونيسيا' }); await p.waitForTimeout(500); const n = await p.$$eval('#vlist tbody tr', r => r.length); assert.equal(n, 3); await p.click('#f_reset'); });
  await t('تصدير Excel من الواجهة يُنزل ملفاً صالحاً', async () => { await go(p, '#/visitors', '#expv'); const [dl] = await Promise.all([p.waitForEvent('download'), p.click('#expv')]); const f = await dl.path(); const buf = fs.readFileSync(f); assert.equal(buf[0], 0x50, 'magic ' + buf[0]); assert.ok(dl.suggestedFilename().endsWith('.xlsx'), 'name=' + dl.suggestedFilename()); });
  await t('تقرير وطباعة وتصدير', async () => { await go(p, '#/reports', '#run'); await p.selectOption('#rt', 'by_country'); await p.waitForFunction(() => (document.querySelector('#sheet') || {}).textContent?.includes('الإجمالي'), null, { timeout: 8000 }); assert.match(await p.textContent('#sheet'), /الإجمالي/); const [dl] = await Promise.all([p.waitForEvent('download'), p.click('#xl')]); assert.ok(dl.suggestedFilename().endsWith('.xlsx'), 'name=' + dl.suggestedFilename()); });
  await t('كشف المطبخ: إلغاء علامة وجبة يخفض العدد', async () => {
    await go(p, '#/meals', '#kitchen'); const row = await p.$('#kitchen input[data-m=lunch]'); const before = await p.textContent('#kitchen .stat:nth-child(3) .n'); await row.uncheck(); await p.waitForTimeout(700);
    const after = await p.textContent('#kitchen .stat:nth-child(3) .n'); assert.equal(+after, +before - 1);
  });
  await t('الجدول اليومي للنقل: تظهر المهمة وتنبيه غير المكلفين', async () => { await go(p, '#/drivers', '#td'); await p.fill('#td', '2026-11-12'); await p.dispatchEvent('#td', 'change'); await p.waitForTimeout(500); const txt = await p.textContent('#page'); assert.match(txt, /خالد المنصور/); assert.match(txt, /بلا سيارة استقبال/); await p.screenshot({ path: OUT + '/07b-transport-day.png', fullPage: true }); });

  console.log('\nمشرف الدولة (ماليزيا)');
  const q = await newPage();
  await t('دخول مشرف ماليزيا: قائمة محدودة ولوحة خاصة بدولته', async () => {
    await login(q, 'my_sup', 'password1'); const nav = await q.$$eval('#nav a', a => a.map(x => x.textContent.trim())); assert.deepEqual(nav, ['لوحة التحكم', 'الزائرون', 'التقارير والطباعة', 'حسابي']);
    await go(q, '#/dashboard', '.stat'); assert.ok(!(await q.textContent('#page')).includes('الدول المشاركة')); await q.screenshot({ path: OUT + '/13-country-dashboard.png', fullPage: true });
  });
  await t('لا يرى زوار الكويت والهند والفوج الإندونيسي', async () => { await go(q, '#/visitors', '#vlist table'); const txt = await q.textContent('#vlist'); assert.ok(txt.includes('عبدالرحمن')); for (const s of ['أحمد ديب', 'سوريش', 'يوسف رحمن']) assert.ok(!txt.includes(s), s); await q.screenshot({ path: OUT + '/14-country-visitors.png', fullPage: true }); });
  await t('يرى غرفة زائريه بعد التسكين', async () => { assert.match(await q.textContent('#vlist'), /دار الضيافة \/ الدور الأول \/ 104/); });
  await t('نموذجه يقتصر على دولته', async () => { await q.click('#addv'); await q.waitForSelector('#vf'); const opts = await q.$$eval('#vf [name=country_id] option', o => o.map(x => x.textContent)); assert.deepEqual(opts, ['اختر…', 'ماليزيا'], JSON.stringify(opts)); await q.click('.modal-f button:has-text("إلغاء")'); });
  await t('محاولة فتح صفحة التسكين مباشرة تعود للوحة', async () => { await q.evaluate(() => (location.hash = '#/housing')); await q.waitForTimeout(500); assert.match(await q.textContent('#page'), /لوحة التحكم/); });
  await t('تقارير مشرف الدولة محصورة بدولته', async () => { await go(q, '#/reports', '#run'); await q.waitForSelector('#sheet'); const txt = await q.textContent('#sheet'); assert.ok(txt.includes('ماليزيا') && !txt.includes('الكويت')); });

  console.log('\nمشرف المبنى + الجوال');
  const b = await newPage();
  await t('مشرف المبنى يرى دور دار الضيافة الأول فقط', async () => { await login(b, 'bsup', 'password1'); await go(b, '#/housing', '.room, #sb'); assert.equal(await b.$$eval('#sb option', o => o.length), 1); assert.equal(await b.$$eval('#floors button', o => o.length), 1); assert.equal(await b.$('#e_start'), null); });
  const mob = await newPage(390, 800);
  await t('عرض الجوال: القائمة الجانبية تفتح وتغلق والصفحة بلا تمرير أفقي', async () => {
    await login(mob, 'admin', 'AdminPass123'); await mob.waitForSelector('.stat'); assert.equal(await mob.$eval('#side', e => getComputedStyle(e).transform !== 'none'), true);
    await mob.click('#mb'); await mob.waitForTimeout(300); assert.ok(await mob.$eval('#side', e => e.classList.contains('open'))); await mob.screenshot({ path: OUT + '/15-mobile-menu.png' }); await mob.click('#nav a[data-id=housing]'); await mob.waitForSelector('#sb'); await mob.selectOption('#sb', { label: 'دار الضيافة' }); await mob.waitForSelector('.room'); await mob.waitForTimeout(300);
    const sw = await mob.evaluate(() => document.documentElement.scrollWidth); assert.ok(sw <= 392, 'scrollWidth=' + sw); await mob.screenshot({ path: OUT + '/16-mobile-housing.png', fullPage: true });
  });
  await t('عرض التابلت (820px) سليم', async () => { const tb = await newPage(820, 1000); await login(tb, 'admin', 'AdminPass123'); await go(tb, '#/visitors', '#vlist'); await tb.screenshot({ path: OUT + '/17-tablet-visitors.png' }); });


  console.log('\nتصنيف «تابع لأسرة» وطلبات الانضمام');
  await t('النموذج بلا البريد وملاحظات الطعام، والتابع يختار رب الأسرة من نافذة', async () => {
    await go(p, '#/visitors', '#addv'); await p.click('#addv'); await p.waitForSelector('#vf');
    assert.equal(await p.$$eval('#vf [name=email], #vf [name=diet_notes]', e => e.length), 0);
    await p.fill('#vf [name=full_name]', 'تابع من النموذج'); await p.selectOption('#vf [name=category]', 'family_member');
    await p.waitForSelector('#hq'); await p.fill('#hq', 'خالد بن سالم'); await p.waitForTimeout(200);
    await p.screenshot({ path: OUT + '/17-pick-head.png' });
    await p.click('#hl label:has-text("خالد بن سالم") input'); await p.click('.modal-f button:has-text("اختيار")');
    await p.waitForSelector('#headbox:not([hidden])'); assert.match(await p.textContent('#headname'), /خالد بن سالم/);
    assert.equal(await p.isHidden('#travbox'), true); await p.fill('#vf [name=relation]', 'ابن'); await p.screenshot({ path: OUT + '/18-member-form.png' });
    await p.click('.modal-f button:has-text("حفظ")'); await p.waitForSelector('#vf', { state: 'detached' });
    await p.fill('#f_q', 'تابع من النموذج'); await p.waitForTimeout(500); const vt = await p.textContent('#vlist'); assert.ok(/تابع لأسرة/.test(vt), 'TEXT=' + vt.replace(/\s+/g,' ').slice(0, 300)); await p.fill('#f_q', '');
  });
  await t('إلغاء اختيار رب الأسرة يعيد التصنيف السابق', async () => {
    await p.click('#addv'); await p.waitForSelector('#vf'); await p.selectOption('#vf [name=category]', 'family_member'); await p.waitForSelector('#hq');
    await p.click('.overlay:last-of-type .modal-f button:has-text("إلغاء")'); await p.waitForTimeout(200); assert.equal(await p.inputValue('#vf [name=category]'), 'individual'); await p.click('.overlay:has(#vf) .x');
  });
  const jp = await newPage();
  await t('زائر الرابط: طلب انضمام ثم رفض الدخول قبل الموافقة', async () => {
    await jp.goto(base); await jp.click('#joinbtn'); await jp.waitForSelector('#jf');
    await jp.fill('#jf [name=name]', 'محمد المتطوع'); await jp.fill('#jf [name=phone]', '+60111222333'); await jp.fill('#jf [name=username]', 'volunteer1'); await jp.fill('#jf [name=password]', 'volpass123');
    await jp.screenshot({ path: OUT + '/19-join-form.png' });
    await jp.click('.modal-f button:has-text("إرسال")'); await jp.waitForSelector('text=وصل طلبك إلى المشرف'); await jp.click('.modal-f button:has-text("حسناً")');
    await jp.fill('#u', 'volunteer1'); await jp.fill('#p', 'volpass123'); await jp.click('#lf button'); await jp.waitForSelector('#lerr:not([hidden])'); assert.match(await jp.textContent('#lerr'), /قيد المراجعة/);
  });
  await t('المدير يرى شارة الطلبات ويقبله كمشرف دولتين', async () => {
    await p.evaluate(() => App.refreshPending()); await p.waitForSelector('.nav-badge:not([hidden])'); await go(p, '#/people', '[data-a]');
    assert.match(await p.textContent('#page'), /محمد المتطوع/); await p.screenshot({ path: OUT + '/20-requests.png', fullPage: true });
    await p.click('[data-a]'); await p.waitForSelector('#arl'); await p.selectOption('#arl', 'country_supervisor'); await p.waitForSelector('#acb:not([hidden])');
    await p.click('#acb label:has-text("ماليزيا") input'); await p.click('#acb label:has-text("الهند") input'); await p.screenshot({ path: OUT + '/21-approve.png' });
    await p.click('.modal-f button:has-text("قبول")'); await p.waitForSelector('#arl', { state: 'detached' });
    const jp2 = await newPage(); await login(jp2, 'volunteer1', 'volpass123'); assert.match(await jp2.textContent('.user-chip'), /مشرف دولة/); await jp2.close();
  });
  await t('رفض طلب انضمام', async () => {
    const x = await newPage(); await x.goto(base); await x.click('#joinbtn'); await x.fill('#jf [name=name]', 'شخص مرفوض'); await x.fill('#jf [name=phone]', '+60999888777'); await x.fill('#jf [name=username]', 'rejectme'); await x.fill('#jf [name=password]', 'rejpass123');
    await x.click('.modal-f button:has-text("إرسال")'); await x.waitForSelector('text=وصل طلبك إلى المشرف');
    await go(p, '#/people/requests', '[data-r]'); await p.click('[data-r]'); await p.click('.modal-f button:has-text("رفض")'); await p.waitForFunction(() => !document.querySelector('[data-r]'));
    await x.close();
  });

  await t('لا أخطاء في الكونسول أثناء كل ما سبق', async () => { const real = errors.filter(e => !/favicon|401|403|400|409|404/.test(e)); assert.deepEqual(real, [], JSON.stringify(real)); });
  console.log(`\n${passed} نجح، ${failed} فشل`);
  await browser.close(); server.close(); process.exit(failed ? 1 : 0);
})().catch(e => { console.error('فشل الإعداد:', e); process.exit(2); });
