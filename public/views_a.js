'use strict';
// لوحة التحكم، المناسبات، الزائرون (+الأفواج، الاستيراد/التصدير)، حسابي

/* ============ لوحة التحكم ============ */
App.view('dashboard', async (page, ctx) => {
  const ev = curEvent();
  let date = App._dashDate && App._dashDate >= ev.start_date && App._dashDate <= ev.end_date ? App._dashDate : (todayStr() >= ev.start_date && todayStr() <= ev.end_date ? todayStr() : ev.start_date);
  const draw = async () => {
    const d = await api('GET', '/dashboard?' + qs({ event_id: App.eventId, date }));
    if (ctx.stale()) return;
    const v = d.visitors, r = d.rooms, t = d.transport, m = d.meals_today;
    const cs = App.user.role === 'country_supervisor';
    let h = `<div class="page-head"><h1>لوحة التحكم</h1><span class="tagline">${esc(ev.name)}</span><div class="grow"></div>
      <div class="row"><label style="margin:0">اليوم المعروض:</label><input type="date" id="dd" value="${date}" min="${ev.start_date}" max="${ev.end_date}" style="width:auto"><span class="muted small">${dayName(date)}</span>
      <button class="btn sec sm" id="dt">اليوم</button></div></div>`;
    if (App.user.role !== 'building_supervisor') {
      if (ev.expected_visitors) h += `<div class="card" style="margin-bottom:14px"><div class="row"><b>المتوقع ${ev.expected_visitors}</b><span class="muted">— المسجل ${v.total}</span><div class="grow"></div><b>${Math.round(v.total * 100 / ev.expected_visitors)}%</b></div><div class="progress" style="margin-top:6px"><div style="width:${Math.min(100, v.total * 100 / ev.expected_visitors)}%"></div></div></div>`;
      h += `<div class="grid stats">${statCard(v.total, cs ? 'إجمالي زائري دولتك' : 'إجمالي الزائرين')}${statCard(v.individuals, 'أفراد')}${statCard(v.families, 'عائلات')}${statCard(v.group_members, 'أفراد الأفواج')}
        ${cs ? '' : statCard(v.countries, 'الدول المشاركة')}${statCard(v.present, 'الموجودون حالياً', 'ok')}${statCard(v.arriving, 'القادمون اليوم')}${statCard(v.departing, 'المغادرون اليوم')}</div>`;
    }
    if (v.declared_unregistered) h += `<div class="muted small" style="margin-top:6px">الإجمالي يشمل ${v.declared_unregistered} فرداً من أعداد الأفواج المعلنة لم تُسجَّل أسماؤهم بعد.</div>`;
    h += '<div class="grid stats" style="margin-top:14px">';
    if (r) h += statCard(r.rooms_booked, 'الغرف المحجوزة') + statCard(r.rooms_available, 'الغرف المتاحة', 'ok') + statCard(r.occupancy_pct + '%', 'نسبة إشغال المباني', r.occupancy_pct > 90 ? 'bad' : r.occupancy_pct > 70 ? 'warn' : '');
    if (t) h += statCard(t.cars_required ?? '—', 'السيارات المطلوبة اليوم') + statCard(t.free_drivers, 'السائقون المتاحون', 'ok') + statCard(t.unassigned, 'زائرون بلا سيارة', t.unassigned ? 'bad' : 'ok');
    if (m) h += statCard(m.total, 'إجمالي وجبات اليوم') + statCard(m.residents, 'المقيمون اليوم');
    if (d.mine) h += statCard(d.mine.housed, 'تم تسكينهم', 'ok') + statCard(d.mine.unhoused, 'بانتظار التسكين', d.mine.unhoused ? 'warn' : '') + statCard(d.mine.with_driver, 'لهم سائق مكلف');
    if (v.incomplete && App.user.role !== 'building_supervisor') h += statCard(v.incomplete, 'سجلات ناقصة التواريخ', 'warn');
    h += '</div><div class="grid cols2" style="margin-top:14px">';
    if (!cs && d.by_country.length) h += `<div class="card"><h3>توزيع الزائرين حسب الدولة</h3>${bars(d.by_country)}</div>`;
    if (r) h += `<div class="card"><h3>إشغال المباني (${date})</h3>${bars(r.by_building.map(b => ({ name: b.name, n: b.pct, suffix: '%' })), { max: 100, alt: true })}
      <div class="legend" style="margin-top:12px"><span><i style="background:var(--free)"></i>متاحة ${r.rooms_state.free}</span><span><i style="background:var(--partial)"></i>جزئية ${r.rooms_state.partial}</span><span><i style="background:var(--full)"></i>مكتملة ${r.rooms_state.full}</span><span><i style="background:var(--unavail)"></i>خارج الخدمة ${r.rooms_state.unavailable}</span></div></div>`;
    if (v.total) {
      const mx = Math.max(1, ...d.flow.map(f => Math.max(f.arrivals, f.departures)));
      h += `<div class="card"><h3>الوصول والمغادرة خلال أيام المناسبة</h3><div class="cols-chart">${d.flow.map(f => `<div class="c" title="${f.date}: وصول ${f.arrivals} / مغادرة ${f.departures}"><div class="pair"><div class="b" style="height:${f.arrivals * 100 / mx}%"></div><div class="b d" style="height:${f.departures * 100 / mx}%"></div></div><span>${f.date.slice(8)}</span></div>`).join('')}</div>
        <div class="legend"><span><i style="background:var(--olive)"></i>وصول</span><span><i style="background:#c98a10"></i>مغادرة</span></div></div>`;
    }
    if (d.meals_flow && d.meals_flow.length) {
      const mx = Math.max(1, ...d.meals_flow.map(x => x.total));
      h += `<div class="card"><h3>احتياجات الوجبات اليومية</h3><div class="cols-chart">${d.meals_flow.map(x => `<div class="c" title="${x.date}: ${x.total} وجبة (إفطار ${x.breakfast} / غداء ${x.lunch} / عشاء ${x.dinner})"><div class="pair"><div class="b m" style="height:${x.total * 100 / mx}%"></div></div><span>${x.date.slice(8)}</span></div>`).join('')}</div></div>`;
    }
    h += '</div>';
    if (v.total === 0 && App.user.role !== 'building_supervisor') h += `<div class="card empty" style="margin-top:14px">لا يوجد زائرون مسجلون في هذه المناسبة بعد. ${can('admin', 'event_manager', 'country_supervisor') ? '<a href="#/visitors">سجّل أول زائر</a>' : ''}</div>`;
    page.innerHTML = h;
    $('#dd').onchange = e => { if (e.target.value) { date = App._dashDate = e.target.value; draw(); } };
    $('#dt').onclick = () => { date = App._dashDate = todayStr() >= ev.start_date && todayStr() <= ev.end_date ? todayStr() : ev.start_date; draw(); };
  };
  await draw();
});

/* ============ المناسبات ============ */
App.view('events', async page => {
  await App.reloadEvents();
  page.innerHTML = `<div class="page-head"><h1>المناسبات</h1><div class="grow"></div><button class="btn" id="add">+ مناسبة جديدة</button></div>
    <div class="table-wrap"><table><thead><tr><th>المناسبة</th><th>من</th><th>إلى</th><th>المتوقع</th><th>الوصف</th><th></th></tr></thead><tbody>
    ${App.events.map(e => `<tr><td><b>${esc(e.name)}</b> ${e.id === App.eventId ? '<span class="badge ok">الحالية</span>' : ''}</td><td>${fmtDate(e.start_date)}</td><td>${fmtDate(e.end_date)}</td><td>${e.expected_visitors || '—'}</td><td>${esc(e.description)}</td>
    <td class="actions">${e.id === App.eventId ? '' : `<button class="btn sm" data-sw="${e.id}">جعلها الحالية</button>`} <button class="btn sm sec" data-ed="${e.id}">تعديل</button> ${can('admin') ? `<button class="btn sm danger" data-del="${e.id}">حذف</button>` : ''}</td></tr>`).join('') || '<tr><td colspan="6" class="empty">لا توجد مناسبات. أنشئ أول مناسبة.</td></tr>'}</tbody></table></div>
    <p class="muted small">بيانات كل مناسبة (الزائرون والحجوزات والسائقون والوجبات) مستقلة ومحفوظة، ويمكنك التنقل بينها من القائمة العلوية دون فقدان أي بيانات.</p>`;
  const form = e => `<form id="ef"><div class="fgrid"><div class="field full"><label>اسم المناسبة *</label><input name="name" required value="${esc(e?.name)}"></div>
    <div class="field"><label>تاريخ البداية *</label><input type="date" name="start_date" required value="${esc(e?.start_date)}"></div><div class="field"><label>تاريخ النهاية *</label><input type="date" name="end_date" required value="${esc(e?.end_date)}"></div>
    <div class="field"><label>عدد الزائرين المتوقع</label><input type="number" min="0" name="expected_visitors" value="${esc(e?.expected_visitors || '')}"></div>
    <div class="field full"><label>وصف المناسبة</label><textarea name="description">${esc(e?.description)}</textarea></div></div></form>`;
  const edit = e => modal({ title: e ? 'تعديل مناسبة' : 'مناسبة جديدة', width: 600, body: form(e), buttons: [{ label: 'حفظ', onClick: async m => {
    const f = $('#ef', m.el); if (!f.reportValidity()) return; const body = formData(f);
    if (e) await api('PUT', '/events/' + e.id, body); else { const r = await api('POST', '/events', body); App.eventId = r.id; localStorage.setItem('gaouk_event', r.id); }
    m.close(); await App.reloadEvents(); toast('تم الحفظ'); App.refresh();
  } }, { label: 'إلغاء', cls: 'sec', close: true }] });
  $('#add').onclick = () => edit();
  page.onclick = async ev => {
    const b = ev.target.closest('button'); if (!b) return; const id = +(b.dataset.sw || b.dataset.ed || b.dataset.del); const e = App.events.find(x => x.id === id);
    if (b.dataset.sw) { App.eventId = id; localStorage.setItem('gaouk_event', id); App.fillEventSelect(); toast('أصبحت «' + e.name + '» المناسبة الحالية'); App.refresh(); }
    if (b.dataset.ed) edit(e);
    if (b.dataset.del) modal({ title: 'حذف مناسبة', width: 520, body: `<div class="alert err">سيُحذف كل ما يخص «${esc(e.name)}»: الزائرون والحجوزات والسائقون والمهام. تؤخذ نسخة احتياطية تلقائياً قبل الحذف.</div><div class="field"><label>اكتب اسم المناسبة للتأكيد</label><input id="cn" autocomplete="off"></div>`,
      buttons: [{ label: 'حذف نهائي', cls: 'danger', onClick: async m => { await api('DELETE', '/events/' + id, { confirm_name: $('#cn', m.el).value }); m.close(); await App.reloadEvents(); toast('تم الحذف'); App.refresh(); } }, { label: 'إلغاء', cls: 'sec', close: true }] });
  };
});

/* ============ الزائرون ============ */
const VF = { q: '', country_id: '', category: '', arrival: '', departure: '', building_id: '', room_id: '', group_id: '', unhoused: '' };
App.view('visitors', async (page, ctx) => {
  const writer = can('admin', 'event_manager', 'country_supervisor');
  const tab = ctx.sub === 'groups' ? 'groups' : 'list';
  const f = (App._vf ||= { ...VF });
  let structure = null;
  if (can('admin', 'event_manager', 'building_supervisor')) { try { structure = (await api('GET', '/structure')).buildings; } catch (_) {} }
  const groups = (await api('GET', '/groups?event_id=' + App.eventId)).groups;
  const head = `<div class="page-head"><h1>الزائرون</h1>${App.user.role === 'country_supervisor' ? `<span class="badge info">دولتك: ${esc(App.countries.map(c => c.name).join('، '))}</span>` : ''}<div class="grow"></div>
    ${writer ? `<button class="btn" id="addv">+ زائر جديد</button><button class="btn" id="addng">+ فوج جديد</button><button class="btn sec" id="addfromdb">+ من قاعدة البيانات</button><button class="btn sec" id="syncfam" title="يربط من سُجّلوا كأفراد بأرباب أسرهم حسب قاعدة البيانات">ربط الأسر</button><button class="btn sec" id="impv">استيراد Excel</button><button class="btn sec" id="expv">تصدير Excel</button>` : ''}</div>
    <div class="tabs"><button class="${tab === 'list' ? 'on' : ''}" onclick="location.hash='#/visitors'">قائمة الزائرين</button><button class="${tab === 'groups' ? 'on' : ''}" onclick="location.hash='#/visitors/groups'">العائلات والأفواج</button></div>`;
  if (tab === 'groups') return groupsTab(page, head, groups, writer, ctx);

  page.innerHTML = head + `<div class="filters card" style="padding:12px"><div><label>بحث (اسم / هاتف / رحلة)</label><input type="search" id="f_q" value="${esc(f.q)}" placeholder="ابحث…"></div>
    <div><label>الدولة</label><select id="f_country_id">${countryOpts(f.country_id, 'الكل')}</select></div>
    <div><label>نوع الزائر</label><select id="f_category">${opts(Object.entries(CAT), f.category, 'الكل')}</select></div>
    <div><label>تاريخ الوصول</label><input type="date" id="f_arrival" value="${f.arrival}"></div><div><label>تاريخ المغادرة</label><input type="date" id="f_departure" value="${f.departure}"></div>
    ${structure ? `<div><label>المبنى</label><select id="f_building_id">${opts(structure.map(b => [b.id, b.name]), f.building_id, 'الكل')}</select></div>
    <div><label>الغرفة</label><select id="f_room_id">${opts(structure.flatMap(b => b.floors.flatMap(fl => fl.rooms.map(r => [r.id, `${b.name} / ${fl.name} / ${r.number}`]))), f.room_id, 'الكل')}</select></div>` : ''}
    <div><label>الفوج</label><select id="f_group_id">${opts(groups.map(g => [g.id, g.name]), f.group_id, 'الكل')}</select></div>
    <div><label>التسكين</label><select id="f_unhoused">${opts([['1', 'لم يُسكنوا بعد']], f.unhoused, 'الكل')}</select></div>
    <div><button class="btn sec" id="f_reset">مسح التصفية</button></div></div><div id="vlist"></div>`;
  const load = async () => {
    const r = await api('GET', '/visitors?' + qs({ event_id: App.eventId, ...f })); if (ctx.stale()) return;
    const vs = r.visitors; App._vlist = vs;
    const q = (f.q || '').trim().toLowerCase(), plain = !f.category && !f.arrival && !f.departure && !f.building_id && !f.room_id && !f.unhoused;
    const gl = plain ? groups.filter(g => (!f.country_id || String(g.country_id) === String(f.country_id)) && (!f.group_id || String(g.id) === String(f.group_id)) && (!q || [g.name, g.leader_name, g.city, g.leader_phone, g.leader_phone2].join(' ').toLowerCase().includes(q))) : [];
    const grow = g => `<tr class="grp" style="background:#f3f8ee"><td><b>${esc(g.name)}</b><br><span class="badge ok">فوج</span> <span class="badge gray">${g.members_count || 0} فرد معلن</span></td><td>${esc(g.country_name)}</td><td>${[g.leader_phone, g.leader_phone2].filter(Boolean).map(x => `<div class="ltr">${esc(x)}</div>`).join('')}</td><td>${g.leader_name ? 'المسئول: ' + esc(g.leader_name) : ''}${g.city ? `<div class="muted small">${esc(g.city)}</div>` : ''}</td><td>${g.arrival_date ? fmtDate(g.arrival_date, g.arrival_time) : '—'}${g.arrival_airline || g.arrival_flight_no || g.arrival_airport ? `<div class="muted small">${esc([g.arrival_airline, g.arrival_flight_no, g.arrival_airport].filter(Boolean).join(' — '))}</div>` : ''}</td><td>${g.departure_date ? fmtDate(g.departure_date, g.departure_time) : '—'}${g.departure_airline || g.departure_flight_no || g.departure_airport ? `<div class="muted small">${esc([g.departure_airline, g.departure_flight_no, g.departure_airport].filter(Boolean).join(' — '))}</div>` : ''}</td><td colspan="2" class="muted small">رجال ${g.men_count || 0} / نساء ${g.women_count || 0} / أطفال ${g.children_count || 0} — المسجّلون بالاسم: ${g.registered ?? g.visitors_count ?? 0}</td><td></td><td class="actions">${writer ? `<button class="btn sm sec" data-gedit="${g.id}">تعديل</button> <button class="btn sm danger" data-gdel="${g.id}">حذف</button>` : ''}</td></tr>`;
    $('#vlist').innerHTML = `<div class="muted small" style="margin-bottom:6px">${vs.length} زائر${gl.length ? ' + ' + gl.length + ' فوج' : ''}${vs.length >= 5000 ? ' (تم عرض أول 5000)' : ''}</div><div class="table-wrap"><table><thead><tr><th>الاسم</th><th>الدولة</th><th>الهاتف</th><th>العائلة / الفوج</th><th>الوصول</th><th>المغادرة</th><th>الرحلة</th><th>الغرفة</th><th>السائق</th><th></th></tr></thead><tbody>
      ${gl.map(grow).join('')}${vs.map(v => `<tr class="${v.category === 'family_member' ? 'sub' : ''}"><td><a href="#" data-view="${v.id}"><b>${esc(v.full_name)}</b></a><br><span class="badge ${v.category === 'family_head' ? 'info' : ''}">${CAT[v.category]}${v.is_leader ? ' — قائد' : ''}${v.members_count ? ' (+' + v.members_count + ')' : ''}</span></td>
      <td>${esc(v.country_name)}</td><td>${[v.phone, v.phone2].filter(Boolean).map(x => `<div class="ltr">${esc(x)}</div>`).join('')}</td><td>${esc(v.head_name || v.group_name || '')}${v.guide_name ? `<div class="muted small">المرشد: ${esc(v.guide_name)}</div>` : ''}</td>
      <td>${v.arrival_date ? fmtDate(v.arrival_date, v.arrival_time) : '<span class="badge warn">ناقص</span>'}</td><td>${v.departure_date ? fmtDate(v.departure_date, v.departure_time) : '<span class="badge warn">ناقص</span>'}${v.dep_flight_no ? `<div class="muted small">${esc([v.dep_airline, v.dep_flight_no].filter(Boolean).join(' '))}${v.dep_airport ? ' — ' + esc(v.dep_airport) : ''}</div>` : ''}</td>
      <td>${esc([v.airline, v.flight_no].filter(Boolean).join(' '))}${v.airport ? `<div class="muted small">${esc(v.airport)}</div>` : ''}</td>
      <td>${v.bookings.length ? v.bookings.map(b => `<span class="badge free">${esc(roomLabel(b))}</span>`).join('<br>') : '<span class="badge gray">لم يُسكن</span>'}</td>
      <td>${v.transports.filter(t => t.kind === 'pickup').map(t => `${esc(t.driver_name)}<div class="muted small ltr">${esc(t.car_number)} · ${TASK_STATUS[t.status]}</div>`).join('') || '<span class="muted">—</span>'}</td>
      <td class="actions"><button class="btn sm sec" data-view="${v.id}">عرض</button>${writer ? ` <button class="btn sm sec" data-edit="${v.id}">تعديل</button> <button class="btn sm danger" data-del="${v.id}">حذف</button>` : ''}</td></tr>`).join('') || (gl.length ? '' : '<tr><td colspan="10" class="empty">لا توجد نتائج</td></tr>')}</tbody></table></div>`;
  };
  const reload = debounce(load, 250);
  $$('[id^=f_]', page).forEach(el => { if (el.id === 'f_reset') return; el.oninput = el.onchange = () => { f[el.id.slice(2)] = el.value; reload(); }; });
  $('#f_reset').onclick = () => { App._vf = { ...VF }; App.refresh(); };
  page.onclick = async e => {
    const ga = e.target.closest('[data-gedit],[data-gdel]'); if (ga) { e.preventDefault(); const g = groups.find(x => x.id === +(ga.dataset.gedit || ga.dataset.gdel));
      if (ga.dataset.gedit) return groupForm(g, () => App.refresh());
      if (await confirmBox(`حذف الفوج «${g.name}»؟`, { danger: true, okText: 'حذف' })) { await api('DELETE', '/groups/' + g.id); toast('تم الحذف'); App.refresh(); } return; }
    const a = e.target.closest('[data-view],[data-edit],[data-del]'); if (!a) return; e.preventDefault();
    if (a.dataset.view) return visitorDetail(+a.dataset.view, writer, load);
    const v = App._vlist.find(x => x.id === +(a.dataset.edit || a.dataset.del));
    if (a.dataset.edit) { const full = (await api('GET', '/visitors/' + v.id)).visitor; return visitorForm(full, groups, load); }
    if (await confirmBox(`حذف «${v.full_name}»؟${v.members_count ? `\nسيُحذف معه ${v.members_count} من التابعين` : ''}${v.bookings.length ? '\nوستُلغى حجوزات الغرف الخاصة به' : ''}`, { danger: true, okText: 'حذف' })) {
      await api('DELETE', '/visitors/' + v.id); toast('تم الحذف'); load();
    }
  };
  if (writer) {
    $('#addv').onclick = () => visitorForm(null, groups, load);
    $('#addng').onclick = () => groupForm(null, () => App.refresh());
    $('#addfromdb').onclick = async () => { const p = await pickPerson(); if (!p) return;
      const pre = { full_name: p.full_name, country_id: p.country_id, phone: p.phone, phone2: p.phone2, category: p.category === 'group_leader' ? 'group_member' : p.category, is_leader: p.category === 'group_leader' };
      if (p.category === 'family_member' && p.head_id) { // ربط تلقائي برب الأسرة: يُسجَّل رب الأسرة في المناسبة إن لم يكن موجوداً
        try { const all = (await api('GET', '/persons?' + qs({ event_id: App.eventId, country_id: p.country_id, category: 'family_head' }))).persons; const hp = all.find(x => x.id === p.head_id);
          if (hp) { let hid = hp.visitor_id; if (!hid) { hid = (await api('POST', '/visitors', { event_id: App.eventId, full_name: hp.full_name, country_id: hp.country_id, phone: hp.phone, phone2: hp.phone2, category: 'family_head', needs_transport: true })).id; toast('سُجّل رب الأسرة «' + hp.full_name + '» في المناسبة'); }
            pre.head = { id: hid, full_name: hp.full_name, country_id: hp.country_id, country_name: hp.country_name }; } } catch (e) { toast('تعذّر ربط رب الأسرة تلقائياً: ' + e.message, 'warn'); } }
      visitorForm(null, groups, load, pre); };
    $('#syncfam').onclick = async () => { if (!await confirmBox('سيُربط كل زائر مسجَّل كفرد وهو تابع لرب أسرة في «قاعدة البيانات» برب أسرته (ويُسجَّل رب الأسرة في المناسبة إن لم يكن مسجلاً). بياناتهم الأخرى لا تتغير.', { okText: 'ربط الأسر' })) return;
      try { const r = await api('POST', '/visitors/sync-family', { event_id: App.eventId }); toast(r.linked ? `رُبط ${r.linked} من أفراد الأسر برب أسرتهم` : 'لا توجد أسر تحتاج ربطاً'); load(); } catch (e) { toast(e.message, 'err'); } };
    $('#expv').onclick = () => download('/visitors-export?' + qs({ event_id: App.eventId, ...f, format: 'xlsx' }), `gaouk-visitors-${todayStr()}.xlsx`);
    $('#impv').onclick = () => importDialog(load);
  }
  await load();
});

function groupsTab(page, head, groups, writer, ctx) {
  page.innerHTML = head + `<div class="row" style="margin-bottom:10px">${writer ? '<button class="btn" id="addg">+ فوج جديد</button>' : ''}</div><div class="table-wrap"><table><thead><tr><th>الفوج</th><th>الدولة</th><th>القائد / المرشد</th><th>البلد</th><th>رجال / نساء / أطفال</th><th>العدد المعلن</th><th>المسجل</th><th>الوصول</th><th>المغادرة</th><th></th></tr></thead><tbody>
    ${groups.map(g => `<tr><td><b>${esc(g.name)}</b></td><td>${esc(g.country_name)}</td><td>${esc(g.leader_name)}${[g.leader_phone, g.leader_phone2].filter(Boolean).map(x => `<div class="ltr small">${esc(x)}</div>`).join('')}</td><td>${esc(g.city)}</td><td>${g.men_count} / ${g.women_count} / ${g.children_count}</td><td>${g.members_count}</td><td>${g.registered} ${g.members_count && g.registered < g.members_count ? '<span class="badge warn">ناقص</span>' : ''}</td><td>${fmtDate(g.arrival_date, g.arrival_time)}${[g.arrival_airline, g.arrival_flight_no, g.arrival_airport].filter(Boolean).length ? `<div class="muted small">${esc([g.arrival_airline, g.arrival_flight_no, g.arrival_airport].filter(Boolean).join(' — '))}</div>` : ''}</td><td>${fmtDate(g.departure_date, g.departure_time)}${[g.departure_airline, g.departure_flight_no, g.departure_airport].filter(Boolean).length ? `<div class="muted small">${esc([g.departure_airline, g.departure_flight_no, g.departure_airport].filter(Boolean).join(' — '))}</div>` : ''}</td>
    <td class="actions">${writer ? `<button class="btn sm sec" data-ge="${g.id}">تعديل</button> <button class="btn sm danger" data-gd="${g.id}">حذف</button>` : ''}</td></tr>`).join('') || '<tr><td colspan="10" class="empty">لا توجد أفواج</td></tr>'}</tbody></table></div>
    <p class="muted small">لتسجيل أعضاء الفوج: أضف زائراً جديداً واختر التصنيف «عضو في فوج» ثم الفوج. العائلات تُسجَّل برب الأسرة وتابعيه من نموذج الزائر.</p>`;
  if (writer) $('#addg').onclick = () => groupForm(null, () => App.refresh());
  page.onclick = async e => {
    const b = e.target.closest('button'); if (!b) return;
    if (b.dataset.ge) groupForm(groups.find(g => g.id === +b.dataset.ge), () => App.refresh());
    if (b.dataset.gd) { const g = groups.find(x => x.id === +b.dataset.gd); if (await confirmBox(`حذف الفوج «${g.name}»؟`, { danger: true, okText: 'حذف' })) { await api('DELETE', '/groups/' + g.id); toast('تم الحذف'); App.refresh(); } }
  };
}
function groupForm(g, done) {
  const body = `<form id="gf"><div class="fgrid"><div class="field"><label>دولة المنشأ *</label><select name="country_id" required>${countryOpts(g?.country_id ?? (App.countries.length === 1 ? App.countries[0].id : ''), 'اختر…')}</select></div>
    <div class="field"><label>البلد</label><input name="city" value="${esc(g?.city)}"></div>
    <div class="field"><label>المسئول (قائد الفوج / المرشد)</label><input name="leader_name" value="${esc(g?.leader_name)}"></div>
    <div class="field"><label>رقم هاتف المسئول 1</label><input name="leader_phone" dir="ltr" style="text-align:right" value="${esc(g?.leader_phone)}"></div><div class="field"><label>رقم هاتف المسئول 2</label><input name="leader_phone2" dir="ltr" style="text-align:right" value="${esc(g?.leader_phone2)}"></div>
    <div class="field"><label>اسم / رقم الفوج (اختياري)</label><input name="name" value="${esc(g?.name)}" placeholder="يُولَّد تلقائياً إن تُرك فارغاً"></div>
    <div class="field"><label>عدد البالغين رجال</label><input type="number" min="0" name="men_count" value="${esc(g?.men_count || '')}"></div>
    <div class="field"><label>عدد البالغين نساء</label><input type="number" min="0" name="women_count" value="${esc(g?.women_count || '')}"></div>
    <div class="field"><label>عدد الأطفال</label><input type="number" min="0" name="children_count" value="${esc(g?.children_count || '')}"></div>
    <div class="field"><label>الإجمالي</label><b id="gtot" class="badge ok" style="font-size:1rem">0</b></div>
    <div class="field"><label>تاريخ الوصول</label><input type="date" name="arrival_date" value="${esc(g?.arrival_date)}"></div><div class="field"><label>وقت الوصول</label><input type="time" name="arrival_time" value="${esc(g?.arrival_time)}"></div><div class="field"><label>شركة طيران الوصول</label><input name="arrival_airline" value="${esc(g?.arrival_airline)}"></div><div class="field"><label>مطار الوصول</label><input name="arrival_airport" value="${esc(g?.arrival_airport)}"></div><div class="field"><label>رقم رحلة الوصول</label><input name="arrival_flight_no" dir="ltr" style="text-align:right" value="${esc(g?.arrival_flight_no)}"></div>
    <div class="field"><label>مطار الوصول</label><input name="arrival_airport" value="${esc(g?.arrival_airport)}"></div><div class="field"><label>رقم رحلة الوصول</label><input name="arrival_flight_no" dir="ltr" style="text-align:right" value="${esc(g?.arrival_flight_no)}"></div>
    <div class="field"><label>تاريخ المغادرة</label><input type="date" name="departure_date" value="${esc(g?.departure_date)}"></div><div class="field"><label>وقت المغادرة</label><input type="time" name="departure_time" value="${esc(g?.departure_time)}"></div><div class="field"><label>شركة طيران المغادرة</label><input name="departure_airline" value="${esc(g?.departure_airline)}"></div><div class="field"><label>مطار المغادرة</label><input name="departure_airport" value="${esc(g?.departure_airport)}"></div><div class="field"><label>رقم رحلة المغادرة</label><input name="departure_flight_no" dir="ltr" style="text-align:right" value="${esc(g?.departure_flight_no)}"></div>
    <div class="field full"><label>ملاحظات</label><textarea name="notes">${esc(g?.notes)}</textarea></div></div></form>`;
  const gm = modal({ title: g ? 'تعديل فوج' : 'فوج جديد', width: 620, body, buttons: [{ label: 'حفظ', onClick: async m => {
    const f = $('#gf', m.el); if (!f.reportValidity()) return; const b = formData(f);
    const r = g ? await api('PUT', '/groups/' + g.id, b) : await api('POST', '/groups', { ...b, event_id: App.eventId }); m.close(); toast('تم الحفظ'); done(r.id);
  } }, { label: 'إلغاء', cls: 'sec', close: true }] });
  const tot = () => { const f = $('#gf', gm.el); $('#gtot', gm.el).textContent = ['men_count', 'women_count', 'children_count'].reduce((a, k) => a + (parseInt(f[k].value, 10) || 0), 0); };
  $$('#gf input[type=number]', gm.el).forEach(i => i.addEventListener('input', tot)); tot();
  return gm;
}

function visitorForm(v, groups, done, pre) {
  pre = pre || {}; const isNew = !v; const isMember = v && v.category === 'family_member';
  const countries = App.countries; const cs = App.user.role === 'country_supervisor';
  const members = v ? (v.members || []) : [];
  const cat = v ? v.category : (pre.category || 'individual');
  const body = `<form id="vf" autocomplete="off"><div id="dupbox"></div>
    <div class="fgrid"><div class="field full"><label>الاسم الكامل *</label><input name="full_name" required value="${esc(v?.full_name ?? pre.full_name)}"></div>
    ${isMember ? '' : `<div class="field" id="cfield"><label>الدولة *</label><select name="country_id" required>${countryOpts(v?.country_id ?? pre.country_id ?? (countries.length === 1 ? countries[0].id : ''), 'اختر…')}</select></div>
    <div class="field"><label>التصنيف *</label><select name="category">${opts(Object.entries(CAT), cat)}</select></div>`}
    <div class="field"><label>رقم الهاتف 1</label><input name="phone" dir="ltr" style="text-align:right" value="${esc(v?.phone ?? pre.phone)}"></div><div class="field"><label>رقم الهاتف 2</label><input name="phone2" dir="ltr" style="text-align:right" value="${esc(v?.phone2 ?? pre.phone2)}"></div>
    ${isMember ? `<div class="field"><label>صلة القرابة</label><input name="relation" value="${esc(v?.relation)}"></div>` : ''}</div>
    ${isMember ? '<div class="alert info">بيانات السفر والدولة لهذا التابع تُؤخذ من رب الأسرة.</div>' : `
    <div id="headbox" class="fgrid" hidden><div class="field"><label>رب الأسرة *</label><div class="row"><b id="headname" class="badge ok" style="font-size:.95rem">—</b><button type="button" class="btn sec sm" id="pickhead">اختيار / تغيير رب الأسرة</button></div></div>
      <div class="field"><label>صلة القرابة</label><input name="relation" value="${esc(v?.relation)}"></div><div class="field full"><div class="alert info" style="margin:0">الدولة وبيانات الرحلة لهذا التابع تُؤخذ تلقائياً من رب الأسرة.</div></div></div>
    <div id="grpbox" class="fgrid" hidden><div class="field"><label>الفوج *</label><select name="group_id">${opts(groups.map(g => [g.id, `${g.name} (${g.country_name})`]), v?.group_id, 'اختر الفوج…')}</select></div>
      <div class="field"><label>&nbsp;</label><label class="check"><input type="checkbox" name="is_leader" ${(v?.is_leader ?? pre.is_leader) ? 'checked' : ''}> قائد الفوج</label><button type="button" class="btn ghost sm" id="newg">+ إنشاء فوج جديد</button></div></div>
    <div id="travbox"><h3>رحلة الزائر</h3><div class="fgrid"><div class="field"><label>رقم المجموعة</label><select id="fgroup"><option value="">— بدون —</option></select></div>
    <div class="field"><label>&nbsp;</label><label class="check"><input type="checkbox" name="needs_transport" ${v ? (v.needs_transport ? 'checked' : '') : 'checked'}> يحتاج سيارة استقبال/توصيل</label></div>
    <div class="field full"><div id="ftext" class="alert info" style="margin:0">اختر رقم المجموعة لتظهر بيانات رحلتي الوصول والمغادرة. تُعدَّل بيانات الرحلات من تبويب «الرحلات».</div></div></div></div>`}
    <div class="fgrid"><div class="field full"><label>ملاحظات خاصة</label><textarea name="notes" style="min-height:56px">${esc(v?.notes)}</textarea></div></div>
    <div id="fambox" ${cat === 'family_head' ? '' : 'hidden'}><h3>أفراد الأسرة <span class="badge">العدد الكلي: <span id="famcount">${1 + members.length}</span></span></h3><div id="dbfam" class="card" hidden style="padding:8px 12px;margin:6px 0;background:#f6f9f3"></div><div class="members-edit" id="mrows"></div><button type="button" class="btn sec sm" id="addm">+ إضافة فرد</button></div></form>`;
  const mrow = m => `<div class="mrow" data-id="${m?.id || ''}"><input placeholder="الاسم الكامل" data-k="full_name" value="${esc(m?.full_name)}"><input placeholder="صلة القرابة" data-k="relation" value="${esc(m?.relation)}"><button type="button" class="btn sm danger" data-rm>×</button></div>`;
  const m = modal({ title: isNew ? 'زائر جديد' : 'تعديل: ' + v.full_name, width: 860, body, buttons: [{ label: isNew ? 'حفظ' : 'حفظ التعديلات', onClick: async mm => save(mm, false) }, { label: 'إلغاء', cls: 'sec', close: true }] });
  const F = $('#vf', m.el);
  let headId = pre.head ? pre.head.id : null, headCountry = pre.head ? pre.head.country_id : '', prevCat = cat;
  const sync = () => { const c = F.category?.value; if ($('#grpbox', m.el)) $('#grpbox', m.el).hidden = c !== 'group_member';
    if ($('#headbox', m.el)) { const fm = c === 'family_member'; $('#headbox', m.el).hidden = !fm; $('#travbox', m.el).hidden = fm; $('#cfield', m.el).hidden = fm; F.country_id.disabled = fm; } $('#fambox', m.el).hidden = c !== 'family_head' && !(v && v.category === 'family_head'); $('#famcount', m.el).textContent = 1 + $$('.mrow', m.el).length; };
  members.forEach(x => $('#mrows', m.el).insertAdjacentHTML('beforeend', mrow(x)));
  if (cat === 'family_head' && !members.length && isNew === false) {}
  $('#addm', m.el).onclick = () => { $('#mrows', m.el).insertAdjacentHTML('beforeend', mrow()); sync(); $$('.mrow input', m.el).pop().focus(); };
  m.el.onclick = e => { const r = e.target.closest('[data-rm]'); if (r) { const row = r.closest('.mrow'); const pid = row.dataset.pid; row.remove(); if (pid) { const cb = $(`#dbfam input[data-pm="${pid}"]`, m.el); if (cb) cb.checked = false; } sync(); } };
  // أفراد أسرة رب الأسرة من قاعدة البيانات: يظهرون تلقائياً ويمكن اختيار بعضهم
  const nz = x => String(x || '').replace(/\s+/g, ' ').trim();
  let dbHeadId = null;
  const loadDbFamily = async () => {
    const box = $('#dbfam', m.el); const clear = () => { box.hidden = true; box.innerHTML = ''; $$('.mrow[data-pid]', m.el).forEach(r => r.remove()); dbHeadId = null; sync(); };
    if (isMember || !F.category || F.category.value !== 'family_head') return clear();
    const cid = F.country_id && !F.country_id.disabled ? F.country_id.value : (v?.country_id || ''), name = nz(F.full_name.value); if (!cid || !name) return clear();
    try {
      const heads = (await api('GET', '/persons?' + qs({ country_id: cid, category: 'family_head' }))).persons; const h = heads.find(x => nz(x.full_name) === name); if (!h || !h.members_n) return clear();
      if (dbHeadId === h.id) return; if (nz(F.full_name.value) !== name) return;
      $$('.mrow[data-pid]', m.el).forEach(r => r.remove()); dbHeadId = h.id;
      const have = new Set($$('.mrow input[data-k=full_name]', m.el).map(i => nz(i.value)));
      const ms = (await api('GET', '/persons?' + qs({ country_id: cid, category: 'family_member' }))).persons.filter(x => x.head_id === h.id && !have.has(nz(x.full_name)));
      if (!ms.length) { box.hidden = true; box.innerHTML = ''; return; }
      box.hidden = false; box.innerHTML = `<b class="small">أفراد أسرة «${esc(h.full_name)}» في قاعدة البيانات — اختر من يزور معه:</b> <label style="margin-inline:10px;cursor:pointer"><input type="checkbox" id="dball"> الكل</label><div id="dblist">${ms.map(x => `<label style="display:block;cursor:pointer"><input type="checkbox" data-pm="${x.id}" data-nm="${esc(x.full_name)}"> ${esc(x.full_name)} ${ageBadge(x.birth_date)}</label>`).join('')}</div>`;
      const setOne = (cb, on) => { cb.checked = on; const pid = cb.dataset.pm; const ex = $(`.mrow[data-pid="${pid}"]`, m.el);
        if (on && !ex) { $('#mrows', m.el).insertAdjacentHTML('beforeend', mrow({ full_name: cb.dataset.nm })); $$('.mrow', m.el).pop().dataset.pid = pid; } else if (!on && ex) ex.remove(); };
      box.onchange = e => { if (e.target.id === 'dball') $$('#dblist input', box).forEach(cb => setOne(cb, e.target.checked)); else if (e.target.dataset.pm) setOne(e.target, e.target.checked); $('#dball', box).checked = $$('#dblist input', box).every(cb => cb.checked); sync(); };
      if (isNew) { $('#dball', box).checked = true; $$('#dblist input', box).forEach(cb => setOne(cb, true)); } sync();
    } catch (_) {}
  };
  const ldf = debounce(loadDbFamily, 350);
  const showHead = () => { const h = headRef.cur; $('#headname', m.el).textContent = h ? `${h.full_name} (${h.country_name})` : 'لم يُحدَّد بعد'; };
  const headRef = { cur: pre.head || null };
  async function chooseHead() {
    const h = await pickHead(); if (!h) return false;
    headRef.cur = h; headId = h.id; headCountry = h.country_id; showHead(); check(); return true;
  }
  F.full_name.addEventListener('input', ldf); if (F.country_id) F.country_id.addEventListener('change', ldf);
  if (F.category) F.category.onchange = async () => {
    if (F.category.value === 'family_member') { if (!headId && !(await chooseHead())) { F.category.value = prevCat === 'family_member' ? 'individual' : prevCat; } }
    prevCat = F.category.value; sync(); ldf();
  };
  if ($('#pickhead', m.el)) $('#pickhead', m.el).onclick = chooseHead;
  sync(); if (pre.head) showHead(); ldf();
  let flights = [];
  const fdesc = (f, k) => f ? `<div><b>${k}:</b> ${esc([f.airline, f.flight_no].filter(Boolean).join(' '))}${f.airport ? ' — ' + esc(f.airport) : ''}${f.flight_date ? ' — ' + esc(f.flight_date) : ''}${f.flight_time ? ' ' + esc(f.flight_time) : ''}</div>` : `<div class="muted">لا توجد رحلة ${k}</div>`;
  const showGroup = () => { if (!$('#fgroup', m.el)) return; const g = $('#fgroup', m.el).value; if (!g) { $('#ftext', m.el).innerHTML = v && (v.arrival_date || v.departure_date) ? `<b>بيانات الرحلة الحالية:</b> وصول ${esc(v.arrival_date || '—')} ${esc(v.arrival_time || '')} ${esc([v.airline, v.flight_no].filter(Boolean).join(' '))} — مغادرة ${esc(v.departure_date || '—')} ${esc(v.departure_time || '')} ${esc([v.dep_airline, v.dep_flight_no].filter(Boolean).join(' '))}` : 'اختر رقم المجموعة لتظهر بيانات رحلتي الوصول والمغادرة. تُعدَّل بيانات الرحلات من تبويب «الرحلات».'; return; }
    const fa = flights.find(f => f.group_no.toLowerCase() === g.toLowerCase() && f.kind === 'arrival'), fd = flights.find(f => f.group_no.toLowerCase() === g.toLowerCase() && f.kind === 'departure'); $('#ftext', m.el).innerHTML = fdesc(fa, 'رحلة الوصول') + fdesc(fd, 'رحلة المغادرة'); };
  const fillGroups = () => { const sel = $('#fgroup', m.el); if (!sel) return; const cid = F.country_id && !F.country_id.disabled ? +F.country_id.value : (v?.country_id || 0); const cur = sel.value;
    const gs = [...new Set(flights.filter(f => f.group_no && (!cid || !f.country_id || f.country_id === cid)).map(f => f.group_no))];
    const curNo = v ? (flights.find(f => f.id === v.arrival_flight_id) || flights.find(f => f.id === v.departure_flight_id) || {}).group_no : '';
    sel.innerHTML = '<option value="">— بدون —</option>' + gs.map(g => `<option value="${esc(g)}">${esc(g)}</option>`).join(''); sel.value = cur || curNo || ''; showGroup(); };
  if ($('#fgroup', m.el)) {
    api('GET', '/flights?event_id=' + App.eventId).then(r => { flights = r.flights; fillGroups(); }).catch(() => {});
    $('#fgroup', m.el).onchange = showGroup; if (F.country_id) F.country_id.addEventListener('change', fillGroups);
  }
  $('#newg', m.el) && ($('#newg', m.el).onclick = () => groupForm({ country_id: F.country_id.value }, async id => { const gs = (await api('GET', '/groups?event_id=' + App.eventId)).groups; groups.splice(0, groups.length, ...gs); F.group_id.innerHTML = opts(gs.map(g => [g.id, `${g.name} (${g.country_name})`]), id, 'اختر الفوج…'); }));
  const check = debounce(async () => {
    if (!F.full_name.value.trim()) return;
    try { const r = await api('POST', '/visitors/check-duplicate', { event_id: App.eventId, full_name: F.full_name.value, phone: v?.phone || '', country_id: F.country_id && !F.country_id.disabled ? F.country_id.value : (headCountry || v?.country_id), exclude_id: v?.id });
      $('#dupbox', m.el).innerHTML = r.duplicates.length ? dupHtml(r.duplicates) : ''; } catch (_) {}
  }, 400);
  F.full_name.addEventListener('input', check); if (F.country_id) F.country_id.addEventListener('change', check);
  async function save(mm, force) {
    if (!F.reportValidity()) return; const b = formData(F);
    b.event_id = App.eventId; b.needs_transport = F.needs_transport ? F.needs_transport.checked : undefined;
    if (!isMember && b.category === 'family_head') b.members = $$('.mrow', mm.el).map(r => ({ id: r.dataset.id || undefined, ...Object.fromEntries($$('input[data-k]', r).map(i => [i.dataset.k, i.value])) })).filter(x => x.full_name.trim());
    if (isMember) delete b.category;
    if (b.category === 'family_member') { if (!headId) { toast('اختر رب الأسرة أولاً', 'warn'); return; } b.head_id = headId; }
    if (force) b.force = true;
    let savedId = v?.id;
    try { const r = isNew ? await api('POST', '/visitors', b) : await api('PUT', '/visitors/' + v.id, b); if (isNew) savedId = r.id; }
    catch (e) {
      if (e.status === 409 && e.data.code === 'duplicate') {
        const hidden = e.data.duplicates.some(d => d.hidden);
        const ok = await new Promise(res => { let fin = false; const f2 = x => { if (!fin) { fin = true; res(x); } };
          modal({ title: 'تنبيه: سجل مشابه موجود', width: 560, onClose: () => f2(false), body: dupHtml(e.data.duplicates) + (hidden ? '<div class="alert err">لا يمكنك الحفظ لوجود سجل مشابه لدى دولة أخرى. تواصل مع مدير النظام.</div>' : '<p>هل تريد حفظ السجل رغم التشابه؟</p>'),
            buttons: [...(hidden ? [] : [{ label: 'حفظ رغم التكرار', cls: 'danger', onClick: x => { f2(true); x.close(); } }]), { label: 'رجوع للتعديل', cls: 'sec', onClick: x => { f2(false); x.close(); } }] }); });
        if (ok) return save(mm, true); return;
      }
      throw e;
    }
    if (savedId && !isMember && b.category !== 'family_member' && $('#fgroup', mm.el)) {
      const g = $('#fgroup', mm.el).value; const curNo = v ? ((flights.find(f => f.id === v.arrival_flight_id) || flights.find(f => f.id === v.departure_flight_id) || {}).group_no || '') : '';
      if (g || curNo) { try { await api('PUT', `/visitors/${savedId}/flights`, { group_no: g }); } catch (e) { toast('حُفظ الزائر لكن تعذّر ربط رقم المجموعة: ' + e.message, 'warn'); } }
    }
    mm.close(); toast('تم الحفظ'); done();
  }
}
// نافذة اختيار رب الأسرة (للتصنيف «تابع لأسرة»)
async function pickHead() {
  let heads;
  try { heads = (await api('GET', '/visitors?event_id=' + App.eventId)).visitors.filter(x => x.category === 'family_head'); } catch (e) { toast(e.message, 'err'); return null; }
  return new Promise(res => {
    let fin = false; const done = x => { if (!fin) { fin = true; res(x); } };
    const draw = t => { const n = Compute.norm ? Compute.norm(t) : t.trim(); const list = heads.filter(h => !t.trim() || (h.full_name + ' ' + h.country_name + ' ' + (h.phone || '')).includes(t.trim()));
      return list.length ? list.map(h => `<label style="cursor:pointer"><input type="radio" name="hd" value="${h.id}"> <b>${esc(h.full_name)}</b> <span class="muted small">— ${esc(h.country_name)}${h.phone ? ' — ' + esc(h.phone) : ''}</span></label>`).join('') : '<div class="empty">لا يوجد رب أسرة مطابق. سجّل رب الأسرة أولاً بتصنيف «رب أسرة».</div>'; };
    const m = modal({ title: 'اختر رب الأسرة', width: 560, onClose: () => done(null),
      body: `<div class="field"><input type="search" id="hq" placeholder="ابحث بالاسم أو الدولة أو الهاتف…" autofocus></div><div class="sel-list" id="hl" style="max-height:320px">${draw('')}</div>`,
      buttons: [{ label: 'اختيار', onClick: x => { const r = $('input[name=hd]:checked', x.el); if (!r) { toast('اختر رب الأسرة من القائمة', 'warn'); return; } done(heads.find(h => h.id === +r.value)); x.close(); } }, { label: 'إلغاء', cls: 'sec', onClick: x => { done(null); x.close(); } }] });
    $('#hq', m.el).oninput = e => { $('#hl', m.el).innerHTML = draw(e.target.value); };
    $('#hl', m.el).ondblclick = e => { const r = e.target.closest('label')?.querySelector('input'); if (r) { done(heads.find(h => h.id === +r.value)); m.close(); } };
  });
}
function dupHtml(list) {
  return `<div class="alert warn"><b>تنبيه تكرار محتمل:</b><ul style="margin:6px 0 0;padding-inline-start:20px">${list.map(d => d.hidden ? `<li>«${esc(d.candidate)}»: ${esc(d.reason)} — مسجل لدى دولة أخرى</li>`
    : `<li>«${esc(d.candidate)}» يشبه <b>${esc(d.full_name)}</b> (${esc(d.country_name)}${d.phone ? ' — ' + esc(d.phone) : ''}) — ${esc(d.reason)}، سجّله: ${esc(d.created_by)}</li>`).join('')}</ul></div>`;
}

async function visitorDetail(id, writer, done) {
  const v = (await api('GET', '/visitors/' + id)).visitor;
  const body = `<div class="fgrid"><div><b>الدولة:</b> ${esc(v.country_name)}</div><div><b>التصنيف:</b> ${CAT[v.category]}${v.is_leader ? ' (قائد الفوج)' : ''}</div><div><b>الهاتف:</b> <span class="ltr">${esc(v.phone) || '—'}</span>${v.phone2 ? ` — <span class="ltr">${esc(v.phone2)}</span>` : ''}</div>
    <div><b>${v.head_name ? 'رب الأسرة' : 'الفوج'}:</b> ${esc(v.head_name || v.group_name) || '—'}</div>
    <div><b>الوصول:</b> ${fmtDate(v.arrival_date, v.arrival_time)}</div><div><b>المغادرة:</b> ${fmtDate(v.departure_date, v.departure_time)}</div><div><b>رحلة الوصول:</b> ${esc([v.airline, v.flight_no].filter(Boolean).join(' ')) || '—'}</div><div><b>مطار الوصول:</b> ${esc(v.airport) || '—'}</div><div><b>رحلة المغادرة:</b> ${esc([v.dep_airline, v.dep_flight_no].filter(Boolean).join(' ')) || '—'}</div><div><b>مطار المغادرة:</b> ${esc(v.dep_airport) || '—'}</div>
    <div class="full"><b>ملاحظات:</b> ${esc(v.notes) || '—'}</div></div>
    ${v.members.length ? `<h3 style="margin-top:14px">أفراد الأسرة (${v.members.length})</h3><ul>${v.members.map(m => `<li>${esc(m.full_name)} ${m.relation ? `<span class="muted">(${esc(m.relation)})</span>` : ''}</li>`).join('')}</ul>` : ''}
    <h3 style="margin-top:14px">الغرفة المخصصة</h3>${v.bookings.length ? v.bookings.map(b => `<div class="badge free" style="margin:2px">${esc(roomLabel(b))} — ${b.from_date} ← ${b.to_date}</div>`).join('') : '<div class="muted">لم يتم التسكين بعد</div>'}
    <h3 style="margin-top:14px">السيارة والسائق</h3>${v.transports.length ? v.transports.map(t => `<div>${t.kind === 'pickup' ? 'استقبال' : 'توصيل'} ${t.task_date}${t.task_time ? ' ' + t.task_time : ''} — <b>${esc(t.driver_name)}</b> <span class="ltr">${esc(t.driver_phone)}</span> — ${esc(t.car_type)} <span class="ltr">${esc(t.car_number)}</span> — <span class="badge">${TASK_STATUS[t.status]}</span></div>`).join('') : '<div class="muted">لم يُكلَّف سائق بعد</div>'}`;
  modal({ title: v.full_name, width: 760, body, buttons: [...(writer ? [{ label: 'تعديل', onClick: async m => { const g = (await api('GET', '/groups?event_id=' + App.eventId)).groups; m.close(); visitorForm(v, g, done); } }] : []), { label: 'إغلاق', cls: 'sec', close: true }] });
}

async function importDialog(done) {
  const m = modal({ title: 'استيراد الزائرين من Excel', width: 720, body: `<p>استخدم القالب الرسمي (ملف Excel أو CSV). تُتخطى السجلات المكررة تلقائياً ويُعرض لك تقرير بالأخطاء قبل الحفظ.</p>
    <div class="row"><button class="btn sec" id="tpl">تنزيل القالب</button><button class="btn" id="pick">اختيار ملف…</button><span id="fname" class="muted"></span></div><div id="res" style="margin-top:14px"></div>`,
    buttons: [{ label: 'تنفيذ الاستيراد', onClick: async mm => { if (!file) return toast('اختر ملفاً أولاً', 'warn'); const r = await api('POST', '/visitors-import?' + qs({ event_id: App.eventId }), await file.arrayBuffer(), { raw: true, type: 'application/octet-stream' }); toast(`تم استيراد ${r.created} سجل`); mm.close(); done(); } }, { label: 'إغلاق', cls: 'sec', close: true }] });
  let file = null;
  $('#tpl', m.el).onclick = () => download('/visitors-template', 'gaouk-visitors-template.xlsx');
  $('#pick', m.el).onclick = async () => {
    file = await pickFile('.xlsx,.csv'); if (!file) return; $('#fname', m.el).textContent = file.name;
    try { const r = await api('POST', '/visitors-import?' + qs({ event_id: App.eventId, dry: 1 }), await file.arrayBuffer(), { raw: true, type: 'application/octet-stream' });
      $('#res', m.el).innerHTML = `<div class="grid stats">${statCard(r.total, 'إجمالي الصفوف')}${statCard(r.created, 'ستُضاف', 'ok')}${statCard(r.skipped.length, 'مكررة (تُتخطى)', r.skipped.length ? 'warn' : '')}${statCard(r.errors.length, 'بها أخطاء', r.errors.length ? 'bad' : '')}</div>
        ${[...r.errors.map(x => ({ ...x, t: 'err' })), ...r.skipped.map(x => ({ ...x, t: 'warn' }))].length ? `<div class="table-wrap" style="margin-top:10px;max-height:240px"><table><thead><tr><th>الصف</th><th>الاسم</th><th>المشكلة</th></tr></thead><tbody>${[...r.errors, ...r.skipped].map(x => `<tr><td>${x.row}</td><td>${esc(x.name)}</td><td>${esc(x.msg)}</td></tr>`).join('')}</tbody></table></div>` : ''}`; }
    catch (e) { $('#res', m.el).innerHTML = `<div class="alert err">${esc(e.message)}</div>`; file = null; }
  };
}

/* ============ حسابي ============ */
App.view('account', async page => {
  const u = App.user;
  page.innerHTML = `<div class="page-head"><h1>حسابي</h1></div><div class="grid cols2"><div class="card"><h3>بياناتي</h3><p><b>${esc(u.name)}</b><br><span class="muted">${esc(App.roleLabels[u.role])}</span></p><p>اسم المستخدم: <span class="ltr">${esc(u.username)}</span></p>
    ${u.role === 'country_supervisor' ? `<p>الدول المسؤول عنها: ${esc(App.countries.map(c => c.name).join('، '))}</p><p class="muted small">لا يمكنك الاطلاع على بيانات الدول الأخرى أو تعديلها إلا بتفويض من مدير النظام.</p>` : ''}</div>
    ${SB.hasDevice() && !SB.pwMode() ? '<div class="card" id="devcard"><h3>جهازي</h3><p>هذا الجهاز مربوط بحسابك، وتدخل منه تلقائياً دون كلمة مرور. لا يمكن فتح الحساب من جهاز آخر.</p><div id="biobox" class="muted small">جارٍ فحص دعم البصمة…</div></div>' : `<form class="card" id="pf"><h3>تغيير كلمة المرور</h3><div class="field"><label>كلمة المرور الحالية</label><input type="password" name="old_password" required autocomplete="current-password"></div>
    <div class="field"><label>كلمة المرور الجديدة (8 أحرف فأكثر)</label><input type="password" name="new_password" required minlength="8" autocomplete="new-password"></div><button class="btn">حفظ</button></form>`}</div>`;
  if ($('#pf')) $('#pf').onsubmit = async e => { e.preventDefault(); try { await api('POST', '/change-password', formData(e.target)); toast('تم تغيير كلمة المرور'); e.target.reset(); } catch (er) { toast(er.message, 'err'); } };
  if ($('#biobox')) {
    const draw = async () => {
      const box = $('#biobox'); if (!box) return;
      if (!(await Bio.supported())) { box.textContent = 'قفل البصمة/الوجه غير مدعوم في هذا المتصفح أو الجهاز (اختياري).'; return; }
      box.innerHTML = Bio.enabled() ? '<p class="alert info" style="margin:0 0 8px">قفل البصمة/الوجه <b>مفعّل</b>: يُطلب عند كل فتح للتطبيق.</p><button class="btn sec sm" id="biooff">إيقاف القفل</button>'
        : '<p style="margin:0 0 8px" class="muted">قفل التطبيق ببصمة الإصبع أو الوجه (اختياري).</p><button class="btn sm" id="bioon">تفعيل القفل بالبصمة / الوجه</button>';
      if ($('#bioon')) $('#bioon').onclick = async () => { try { await Bio.enable(); toast('تم تفعيل القفل'); } catch (e) { toast('لم يكتمل التفعيل: ' + (e.name === 'NotAllowedError' ? 'تم الإلغاء' : 'غير مدعوم'), 'err'); } draw(); };
      if ($('#biooff')) $('#biooff').onclick = async () => { try { await Bio.verify(); Bio.disable(); toast('أُوقف القفل'); } catch (_) { toast('يلزم التحقق بالبصمة لإيقاف القفل', 'err'); } draw(); };
    };
    draw();
  }
});

async function pickPerson() {
  let list;
  try { list = (await api('GET', '/persons?event_id=' + App.eventId)).persons; } catch (e) { toast(e.message, 'err'); return null; }
  return new Promise(res => {
    let fin = false; const done = x => { if (!fin) { fin = true; res(x); } };
    const draw = t => { const q = t.trim(); const l = list.filter(p => !q || (p.full_name + ' ' + p.country_name + ' ' + (p.city || '')).includes(q));
      return l.length ? l.map(p => `<label style="cursor:pointer"><input type="radio" name="pp" value="${p.id}"> <b>${esc(p.full_name)}</b> <span class="muted small">— ${esc(p.country_name)}${p.city ? ' / ' + esc(p.city) : ''} — ${PCAT[p.category]}${p.birth_date ? ' — ' + esc(p.birth_date) : ''}</span> ${ageBadge(p.birth_date)}${p.in_event ? ' <span class="badge warn">مسجّل في هذه المناسبة</span>' : ''}</label>`).join('') : '<div class="empty">لا نتائج. أضف المريد من تبويب «قاعدة البيانات».</div>'; };
    const m = modal({ title: 'اختر من قاعدة البيانات', width: 620, onClose: () => done(null),
      body: `<div class="field"><input type="search" id="pq" placeholder="ابحث بالاسم أو الدولة أو البلد…" autofocus></div><div class="sel-list" id="pl" style="max-height:340px">${draw('')}</div>`,
      buttons: [{ label: 'اختيار', onClick: x => { const r = $('input[name=pp]:checked', x.el); if (!r) { toast('اختر مريداً من القائمة', 'warn'); return; } done(list.find(p => p.id === +r.value)); x.close(); } }, { label: 'إلغاء', cls: 'sec', onClick: x => { done(null); x.close(); } }] });
    $('#pq', m.el).oninput = e => { $('#pl', m.el).innerHTML = draw(e.target.value); };
    $('#pl', m.el).ondblclick = e => { const r = e.target.closest('label')?.querySelector('input'); if (r) { done(list.find(p => p.id === +r.value)); m.close(); } };
  });
}
// العمر بالسنوات من تاريخ الميلاد (YYYY-MM-DD) حتى اليوم؛ بالغ = 15 فأكثر، طفل = أقل من 15
const ageOf = bd => { if (!bd || !/^\d{4}-\d\d-\d\d$/.test(bd)) return null; const b = new Date(bd + 'T00:00:00'), n = new Date(); let a = n.getFullYear() - b.getFullYear(); if (n.getMonth() < b.getMonth() || (n.getMonth() === b.getMonth() && n.getDate() < b.getDate())) a--; return a < 0 ? null : a; };
const ageGroup = bd => { const a = ageOf(bd); return a === null ? '' : a >= 15 ? 'adult' : 'child'; };
const AGEL = { adult: 'بالغ', child: 'طفل' };
const ageBadge = bd => { const g = ageGroup(bd); return g ? `<span class="badge ${g === 'adult' ? 'ok' : 'warn'}">${AGEL[g]} (${ageOf(bd)})</span>` : '<span class="muted small">—</span>'; };
const PCAT = { family_head: 'رب أسرة', family_member: 'تابع لأسرة', individual: 'فرد', group_member: 'ضمن فوج', group_leader: 'مسئول فوج' };

/* ============ قاعدة البيانات (المريدون) ============ */
App.view('persons', async page => {
  const S = App._pf ||= { q: '', country_id: '', category: '', age: '' };
  const personForm = (p, done) => {
    const body = `<form id="pf"><div class="fgrid"><div class="field full"><label>الاسم *</label><input name="full_name" required value="${esc(p?.full_name)}"></div>
      <div class="field"><label>تاريخ الميلاد <span class="muted small">(بالغ: 15 سنة فأكثر، طفل: أقل من 15)</span></label><input type="date" name="birth_date" value="${esc(p?.birth_date)}"></div>
      <div class="field"><label>الدولة *</label><select name="country_id" required>${countryOpts(p?.country_id ?? (App.countries.length === 1 ? App.countries[0].id : ''), 'اختر…')}</select></div>
      <div class="field"><label>البلد</label><input name="city" value="${esc(p?.city)}"></div>
      <div class="field"><label>رقم الهاتف 1</label><input name="phone" dir="ltr" style="text-align:right" value="${esc(p?.phone)}"></div><div class="field"><label>رقم الهاتف 2</label><input name="phone2" dir="ltr" style="text-align:right" value="${esc(p?.phone2)}"></div>
      <div class="field"><label>التصنيف *</label><select name="category" required>${opts(Object.entries(PCAT), p?.category || 'individual')}</select></div>
      <div class="field" id="hbox" hidden><label>رب الأسرة التابع له</label><select name="head_id"><option value="">— اختر رب الأسرة —</option></select></div></div></form>`;
    const pm = modal({ title: p ? 'تعديل بيانات مريد' : 'إضافة مريد', width: 560, body, buttons: [{ label: 'حفظ', onClick: async m => {
      const f = $('#pf', m.el); if (!f.reportValidity()) return; const b = formData(f); if (b.category !== 'family_member') b.head_id = '';
      p ? await api('PUT', '/persons/' + p.id, b) : await api('POST', '/persons', b); m.close(); toast('تم الحفظ'); done();
    } }, { label: 'إلغاء', cls: 'sec', close: true }] });
    const F = $('#pf', pm.el); let heads = [];
    const fillHeads = async () => { const fm = F.category.value === 'family_member'; $('#hbox', pm.el).hidden = !fm; if (!fm) return; const cid = F.country_id.value; if (!cid) { F.head_id.innerHTML = '<option value="">— اختر الدولة أولاً —</option>'; return; }
      heads = (await api('GET', '/persons?' + qs({ country_id: cid, category: 'family_head' }))).persons.filter(h => !p || h.id !== p.id);
      const cur = F.head_id.value || String(p?.head_id || ''); F.head_id.innerHTML = '<option value="">— بدون ربط —</option>' + heads.map(h => `<option value="${h.id}">${esc(h.full_name)}${h.birth_date ? ' (' + DT.d(h.birth_date) + ')' : ''}</option>`).join(''); F.head_id.value = heads.some(h => String(h.id) === cur) ? cur : ''; if (!heads.length) F.head_id.options[0].textContent = '— لا يوجد رب أسرة مسجّل لهذه الدولة —'; };
    F.category.addEventListener('change', fillHeads); F.country_id.addEventListener('change', () => { F.head_id.value = ''; fillHeads(); }); fillHeads();
  };
  page.innerHTML = `<div class="page-head"><h1>قاعدة البيانات</h1><div class="grow"></div><button class="btn" id="addp">+ إضافة مريد</button></div>
    <div class="filters card" style="padding:12px"><div><label>بحث</label><input type="search" id="p_q" value="${esc(S.q)}" placeholder="الاسم أو البلد…"></div>
    <div><label>الدولة</label><select id="p_c">${countryOpts(S.country_id, 'الكل')}</select></div><div><label>التصنيف</label><select id="p_k">${opts(Object.entries(PCAT), S.category, 'الكل')}</select></div><div><label>الفئة العمرية</label><select id="p_a">${opts([['adult', 'بالغ (15 سنة فأكثر)'], ['child', 'طفل (أقل من 15)'], ['none', 'بلا تاريخ ميلاد']], S.age, 'الكل')}</select></div></div>
    <div id="plist"></div><p class="muted small">المريدون المسجلون هنا متاحون للاختيار في أي مناسبة من تبويب «الزائرون» ← «من قاعدة البيانات».</p>`;
  let list = [];
  const draw = () => { $('#plist').innerHTML = `<div class="table-wrap"><table><thead><tr><th>الاسم</th><th>تاريخ الميلاد</th><th>الفئة العمرية</th><th>الدولة</th><th>البلد</th><th>الهاتف</th><th>التصنيف</th><th></th></tr></thead><tbody>${list.map(p => `<tr><td><b>${esc(p.full_name)}</b></td><td>${p.birth_date ? fmtDate(p.birth_date) : '—'}</td><td>${ageBadge(p.birth_date)}</td><td>${esc(p.country_name)}</td><td>${esc(p.city) || '—'}</td><td>${[p.phone, p.phone2].filter(Boolean).map(x => `<div class="ltr">${esc(x)}</div>`).join('') || '—'}</td><td>${PCAT[p.category]}${p.category === 'family_member' ? `<div class="muted small">${p.head_name ? 'تابع لـ ' + esc(p.head_name) : 'غير مربوط برب أسرة'}</div>` : ''}${p.category === 'family_head' && p.members_n ? `<div class="muted small">${p.members_n} تابع</div>` : ''}</td>
    <td class="actions"><button class="btn sm sec" data-pe="${p.id}">تعديل</button> <button class="btn sm danger" data-pd="${p.id}">حذف</button></td></tr>`).join('') || '<tr><td colspan="8" class="empty">لا يوجد مريدون</td></tr>'}</tbody></table></div>`; };
  const load = async () => { list = (await api('GET', '/persons?' + qs({ q: S.q, country_id: S.country_id, category: S.category }))).persons.filter(p => !S.age || (S.age === 'none' ? !ageGroup(p.birth_date) : ageGroup(p.birth_date) === S.age)); draw(); };
  const rd = debounce(() => { if (!$('#p_q')) return; S.q = $('#p_q').value; S.country_id = $('#p_c').value; S.category = $('#p_k').value; S.age = $('#p_a').value; load(); }, 250);
  ['p_q', 'p_c', 'p_k', 'p_a'].forEach(i => { $('#' + i).addEventListener('input', rd); $('#' + i).addEventListener('change', rd); });
  $('#addp').onclick = () => personForm(null, load);
  page.onclick = async e => { const b = e.target.closest('button'); if (!b) return;
    if (b.dataset.pe) personForm(list.find(p => p.id === +b.dataset.pe), load);
    if (b.dataset.pd) { const p = list.find(x => x.id === +b.dataset.pd); if (await confirmBox(`حذف «${p.full_name}» من قاعدة البيانات؟`, { danger: true, okText: 'حذف' })) { await api('DELETE', '/persons/' + p.id); toast('تم الحذف'); load(); } } };
  await load();
});

/* ============ الرحلات (تبويب مستقل: مجموعات رحلات كل مناسبة) ============ */
App.view('flights', async (page, ctx) => {
  const canEdit = can('admin', 'event_manager', 'country_supervisor');
  const { flights } = await api('GET', '/flights?event_id=' + App.eventId); if (ctx.stale()) return;
  const grs = (await api('GET', '/groups?event_id=' + App.eventId).catch(() => ({ groups: [] }))).groups || []; if (ctx.stale()) return;
  const KIND = { arrival: 'وصول', departure: 'مغادرة' };
  const S = App._ff ||= { q: '', country_id: '', kind: '' };
  const form = (f, done) => {
    const k = f?.kind || 'arrival';
    const body = `<form id="ff"><div class="fgrid"><div class="field"><label>رقم المجموعة *</label><input name="group_no" required value="${esc(f?.group_no)}" placeholder="مثال: 12"></div>
      <div class="field"><label>الدولة *</label><select name="country_id" required>${countryOpts(f?.country_id ?? (App.countries.length === 1 ? App.countries[0].id : ''), 'اختر…')}</select></div>
      <div class="field"><label>وصول أم مغادرة *</label><select name="kind" id="fk" ${f ? 'disabled' : ''}>${opts(Object.entries(KIND), k)}</select></div>
      <div class="field"><label>شركة الطيران</label><input name="airline" value="${esc(f?.airline)}"></div>
      <div class="field"><label>رقم الرحلة *</label><input name="flight_no" required dir="ltr" style="text-align:right" value="${esc(f?.flight_no)}"></div>
      <div class="field"><label>المطار</label><input name="airport" value="${esc(f?.airport)}"></div>
      <div class="field"><label>التاريخ</label><input type="date" name="flight_date" value="${esc(f?.flight_date)}"></div>
      <div class="field"><label id="ftl">${k === 'arrival' ? 'وقت الوصول' : 'وقت المغادرة'}</label><input type="time" name="flight_time" value="${esc(f?.flight_time)}"></div></div>
      <div class="alert info">رقم المجموعة يربط رحلة الوصول برحلة المغادرة لنفس المجموعة. عند تسجيل أي زائر تختار له رقم المجموعة فقط فتُطبَّق عليه بيانات الرحلتين، وأي تعديل هنا ينعكس على كل ركاب المجموعة.</div></form>`;
    const m = modal({ title: f ? 'تعديل رحلة' : 'رحلة جديدة', width: 640, body, buttons: [{ label: 'حفظ', onClick: async mm => {
      const F = $('#ff', mm.el); if (!F.reportValidity()) return; const b = formData(F); if (f) delete b.kind; else b.event_id = App.eventId;
      const r = f ? await api('PUT', '/flights/' + f.id, b) : await api('POST', '/flights', b); mm.close(); toast('تم الحفظ'); done(f ? f.id : r.id, !f);
    } }, { label: 'إلغاء', cls: 'sec', close: true }] });
    $('#fk', m.el).onchange = e => { $('#ftl', m.el).textContent = e.target.value === 'arrival' ? 'وقت الوصول' : 'وقت المغادرة'; };
  };
  const open = S.open ||= new Set(); let paxData = null;
  const loadPax = async () => { if (paxData) return paxData; const [vr, pr] = await Promise.all([api('GET', '/visitors?event_id=' + App.eventId), api('GET', '/persons?event_id=' + App.eventId).catch(() => ({ persons: [] }))]);
    const bd = {}; pr.persons.forEach(x => { if (x.visitor_id) bd[x.visitor_id] = x.birth_date; }); return (paxData = { vs: vr.visitors, bd }); };
  const paxHtml = f => { if (!paxData) return '<div class="muted">جارٍ التحميل…</div>'; const l = paxData.vs.filter(v => (f.kind === 'arrival' ? v.arrival_flight_id : v.departure_flight_id) === f.id);
    return l.length ? `<table class="sub"><thead><tr><th>#</th><th>الاسم</th><th>الدولة</th><th>التصنيف</th><th>العائلة / الفوج</th><th>الهاتف</th><th>الفئة العمرية</th><th>يحتاج نقل</th>${canEdit ? '<th></th>' : ''}</tr></thead><tbody>${Compute.orderPeople(l, v => paxData.bd[v.id]).map(({ v, member, head }, i) => `<tr${head ? ' style="background:#eef5ea"' : ''}><td>${i + 1}</td><td style="${member ? 'padding-inline-start:26px' : ''}">${member ? '↳ ' : ''}<b>${esc(v.full_name)}</b>${!member && v.category === 'family_member' && v.head_name ? ` <span class="muted small">(تابع لـ ${esc(v.head_name)})</span>` : ''}</td><td>${esc(v.country_name)}</td><td>${CAT[v.category]}${v.is_leader ? ' (قائد)' : ''}</td><td>${esc(v.head_name ? 'عائلة ' + v.head_name : v.group_name ? 'فوج ' + v.group_name : '')}</td><td>${[v.phone, v.phone2].filter(Boolean).map(x => `<div class="ltr">${esc(x)}</div>`).join('')}</td><td>${ageBadge(paxData.bd[v.id])}</td><td>${v.needs_transport ? 'نعم' : 'لا'}</td>${canEdit ? `<td><button class="btn sm danger" data-rm="${v.id}" data-rf="${f.id}" title="إلغاء الاسم من هذه الرحلة">إلغاء</button></td>` : ''}</tr>`).join('')}</tbody></table>` : '<div class="muted">لا يوجد ركاب مسجلون في هذه الرحلة بعد. استخدم «+ ركاب» لإضافتهم.</div>'; };
  const byTime = (a, b) => (a.flight_date || '9999').localeCompare(b.flight_date || '9999') || (a.flight_time || '99:99').localeCompare(b.flight_time || '99:99') || String(a.group_no).localeCompare(String(b.group_no), 'ar', { numeric: true }) || a.kind.localeCompare(b.kind);
  const gfl = grs.flatMap(g => ['arrival', 'departure'].filter(k => g[k + '_date'] || g[k + '_flight_no'] || g[k + '_airport']).map(k => ({ _grp: g, id: 'g' + g.id + k, kind: k, group_no: g.name, country_id: g.country_id, country_name: g.country_name, airline: g[k + '_airline'] || '', flight_no: g[k + '_flight_no'] || '', airport: g[k + '_airport'] || '', flight_date: g[k + '_date'] || '', flight_time: g[k + '_time'] || '', passengers: g.members_count || 0 })));
  const shown = () => [...flights, ...gfl].sort(byTime).filter(f => (!S.q || (f.group_no + ' ' + f.flight_no + ' ' + f.airline + ' ' + f.airport).toLowerCase().includes(S.q.toLowerCase())) && (!S.country_id || String(f.country_id) === S.country_id) && (!S.kind || f.kind === S.kind));
  const rows = () => shown().map(f => f._grp ? `<tr style="background:#f3f8ee"><td><span class="badge ok">فوج</span> <b>${esc(f.group_no)}</b></td><td>${esc(f.country_name) || '—'}</td><td><span class="badge ${f.kind === 'arrival' ? 'ok' : 'info'}">${KIND[f.kind]}</span></td><td>${esc(f.airline) || '—'}</td><td><b class="ltr">${esc(f.flight_no) || '—'}</b></td><td>${esc(f.airport) || '—'}</td><td>${f.flight_date ? fmtDate(f.flight_date) : '—'}</td><td>${esc(f.flight_time) || '—'}</td><td>${f.passengers}</td><td class="actions">${canEdit ? `<button class="btn sm sec" data-gge="${f._grp.id}">تعديل الفوج</button>` : ''}</td></tr>` : `<tr><td style="white-space:nowrap"><button class="btn sm ghost" data-fx="${f.id}" title="عرض الركاب" style="min-width:34px;font-weight:800">${open.has(f.id) ? '−' : '+'}</button> <b>${esc(f.group_no) || '—'}</b></td><td>${esc(f.country_name) || '—'}</td><td><span class="badge ${f.kind === 'arrival' ? 'ok' : 'info'}">${KIND[f.kind]}</span></td><td>${esc(f.airline)}</td><td><b class="ltr">${esc(f.flight_no)}</b></td><td>${esc(f.airport)}</td>
    <td>${f.flight_date ? fmtDate(f.flight_date) : '—'}</td><td>${esc(f.flight_time) || '—'}</td><td>${f.passengers}</td>
    <td class="actions"><button class="btn sm" data-fp="${f.id}">+ ركاب</button> <button class="btn sm sec" data-fe="${f.id}">تعديل</button> <button class="btn sm danger" data-fd="${f.id}">حذف</button></td></tr>${open.has(f.id) ? `<tr class="fx"><td colspan="10" style="background:#f6f9f3">${paxHtml(f)}</td></tr>` : ''}`).join('') || '<tr><td colspan="10" class="empty">لا توجد رحلات في هذه المناسبة. اضغط «رحلة جديدة».</td></tr>';
  page.innerHTML = `<div class="page-head"><h1>الرحلات</h1><div class="grow"></div>${canEdit ? '<button class="btn" id="addf">+ رحلة جديدة</button>' : ''}</div>
    <div class="filters card" style="padding:12px"><div><label>بحث (رقم المجموعة / الرحلة / الشركة / المطار)</label><input type="search" id="fq" value="${esc(S.q)}"></div><div><label>الدولة</label><select id="fc">${countryOpts(S.country_id, 'الكل')}</select></div><div><label>النوع</label><select id="fkk">${opts(Object.entries(KIND), S.kind, 'الكل')}</select></div></div>
    <div class="table-wrap"><table><thead><tr><th>رقم المجموعة</th><th>الدولة</th><th>النوع</th><th>شركة الطيران</th><th>رقم الرحلة</th><th>المطار</th><th>التاريخ</th><th>الوقت</th><th>الركاب</th><th></th></tr></thead><tbody id="frows">${rows()}</tbody></table></div>
    <p class="muted small">لكل مناسبة مجموعة رحلاتها الخاصة. أضف لكل مجموعة رحلة وصول ورحلة مغادرة بنفس رقم المجموعة، ثم اختر رقم المجموعة في بيانات الزائر.</p>`;
  if (open.size) loadPax().then(() => { if (!ctx.stale() && $('#frows')) $('#frows').innerHTML = rows(); }).catch(() => {});
  const redraw = () => { S.q = $('#fq').value; S.country_id = $('#fc').value; S.kind = $('#fkk').value; $('#frows').innerHTML = rows(); };
  ['fq', 'fc', 'fkk'].forEach(i => { $('#' + i).addEventListener('input', redraw); $('#' + i).addEventListener('change', redraw); });
  const after = async (id, isNew) => { await App.refresh(); if (isNew) { const f = (await api('GET', '/flights?event_id=' + App.eventId)).flights.find(x => x.id === id); if (f && await confirmBox(`تمت إضافة الرحلة ${f.flight_no} للمجموعة ${f.group_no}. هل تريد إضافة ركابها الآن من قاعدة البيانات؟`, { okText: 'إضافة ركاب' })) addPassengers(f); } };
  if ($('#addf')) $('#addf').onclick = () => form(null, after);
  page.onclick = async e => { const b = e.target.closest('button'); if (!b) return;
    if (b.dataset.gge) { const g = grs.find(x => x.id === +b.dataset.gge); if (g) groupForm(g, () => App.refresh()); return; }
    if (b.dataset.fx) { const id = +b.dataset.fx; if (open.has(id)) open.delete(id); else { open.add(id); if (!paxData) { $('#frows').innerHTML = rows(); try { await loadPax(); } catch (er) { toast(er.message, 'err'); } } } $('#frows').innerHTML = rows(); return; }
    if (b.dataset.rm) { const f = flights.find(x => x.id === +b.dataset.rf), v = paxData && paxData.vs.find(x => x.id === +b.dataset.rm); if (!f || !v) return;
      const key = f.kind === 'arrival' ? 'arrival_flight_id' : 'departure_flight_id', where = `رحلة ${KIND[f.kind]} المجموعة ${f.group_no}`;
      const n = paxData.vs.filter(x => x.head_id === v.id && x[key] === f.id).length;
      const run = async solo => { try { await api('PUT', `/visitors/${v.id}/flights`, { [key]: null, solo }); toast('أُلغي الاسم من الرحلة'); paxData = null; App.refresh(); } catch (er) { toast(er.message, 'err'); } };
      if (n) { const m = modal({ title: 'إلغاء رب الأسرة من الرحلة', width: 520, body: `<p style="margin:0">«${esc(v.full_name)}» رب أسرة، وله ${n} من أفراد أسرته في ${where}.<br>الأسماء تبقى مسجلة في الزوار في الحالتين.</p>`,
          buttons: [{ label: 'إلغاء رب الأسرة فقط (يبقى أفراده)', onClick: async x => { x.close(); await run(true); } }, { label: 'إلغاء الأسرة كلها', cls: 'danger', onClick: async x => { x.close(); await run(false); } }, { label: 'رجوع', cls: 'sec', close: true }] }); return; }
      if (await confirmBox(`إلغاء «${v.full_name}» من ${where}؟ يبقى الاسم مسجلاً في الزوار.`, { danger: true, okText: 'إلغاء الاسم' })) await run(true); return; }
    const id = +(b.dataset.fp || b.dataset.fe || b.dataset.fd); const f = flights.find(x => x.id === id); if (!f) return;
    if (b.dataset.fp) addPassengers(f); if (b.dataset.fe) form(f, () => App.refresh());
    if (b.dataset.fd && await confirmBox(`حذف رحلة ${KIND[f.kind]} المجموعة ${f.group_no} (${f.flight_no})؟ تبقى بيانات موعد الركاب كما هي ويُفك ارتباطهم بها.`, { danger: true, okText: 'حذف' })) { await api('DELETE', '/flights/' + f.id); toast('تم الحذف'); App.refresh(); } };
});
// اختيار ركاب الرحلة من قاعدة البيانات بعلامة صح
async function addPassengers(f) {
  let list; try { list = (await api('GET', '/persons?' + qs({ event_id: App.eventId, country_id: f.country_id || '' }))).persons.filter(p => !f.country_id || p.country_id === f.country_id); } catch (e) { toast(e.message, 'err'); return; }
  const sel = new Set(); const draw = (t, c) => { const q = t.trim(); const l = list.filter(p => (!q || (p.full_name + ' ' + (p.city || '')).includes(q)) && (!c || String(p.country_id) === c));
    return l.length ? l.map(p => `<label style="cursor:pointer;display:block"><input type="checkbox" data-p="${p.id}" ${sel.has(p.id) ? 'checked' : ''}> <b>${esc(p.full_name)}</b> <span class="muted small">— ${esc(p.country_name)}${p.city ? ' / ' + esc(p.city) : ''} — ${PCAT[p.category]}${p.head_name ? ' ← ' + esc(p.head_name) : ''}${p.category === 'family_head' && p.members_n ? ' (' + p.members_n + ' تابعين)' : ''}</span> ${ageBadge(p.birth_date)}${p.in_event ? ' <span class="badge info">مسجّل في المناسبة</span>' : ''}</label>`).join('') : '<div class="empty">لا نتائج. أضف الأسماء أولاً من تبويب «قاعدة البيانات».</div>'; };
  const m = modal({ title: `ركاب المجموعة ${f.group_no} — ${f.flight_no}`, width: 640, body: `<div class="fgrid"><div class="field"><input type="search" id="xq" placeholder="ابحث بالاسم أو البلد…"></div><div class="field"><select id="xc">${countryOpts('', 'كل الدول')}</select></div></div>
    <div class="card" style="padding:8px 12px;margin:6px 0;background:#f6f9f3"><b class="small">تسجيل الأسر:</b>
      <label style="display:inline-block;margin-inline:10px;cursor:pointer"><input type="checkbox" id="xhead" checked> ضم رب الأسرة</label>
      <label style="display:inline-block;cursor:pointer"><input type="checkbox" id="xmem" checked> ضم أفراد الأسرة (عند اختيار رب الأسرة)</label>
      <div class="muted small">ألغِ «ضم رب الأسرة» لتسجيل التابعين وحدهم دون رب الأسرة، أو ألغِ «ضم أفراد الأسرة» لتسجيل رب الأسرة وحده.</div></div>
    <div class="row" style="margin:6px 0"><button class="btn ghost sm" id="xall">تحديد كل الظاهر</button><button class="btn ghost sm" id="xnone">إلغاء التحديد</button><b class="badge ok" id="xn">0 محدد</b></div>
    <div class="sel-list" id="xl" style="max-height:360px">${draw('', '')}</div>`,
    buttons: [{ label: 'إضافة المحددين إلى الرحلة', onClick: async x => { if (!sel.size) { toast('حدد اسماً واحداً على الأقل', 'warn'); return; } const r = await api('POST', `/flights/${f.id}/passengers`, { person_ids: [...sel], include_head: $('#xhead', m.el).checked, include_members: $('#xmem', m.el).checked }); x.close();
      toast(`أُضيف ${r.added} زائراً جديداً وربط ${r.linked} مسجلين مسبقاً${r.skipped ? '، وتجاوز ' + r.skipped : ''}`); App.refresh(); } }, { label: 'إلغاء', cls: 'sec', close: true }] });
  const redraw = () => { $('#xl', m.el).innerHTML = draw($('#xq', m.el).value, $('#xc', m.el).value); $('#xn', m.el).textContent = sel.size + ' محدد'; };
  $('#xq', m.el).oninput = redraw; $('#xc', m.el).onchange = redraw;
  $('#xl', m.el).onchange = e => { const id = +e.target.dataset.p; if (e.target.checked) sel.add(id); else sel.delete(id); $('#xn', m.el).textContent = sel.size + ' محدد'; };
  $('#xall', m.el).onclick = () => { $$('#xl input[data-p]', m.el).forEach(i => sel.add(+i.dataset.p)); redraw(); };
  $('#xnone', m.el).onclick = () => { sel.clear(); redraw(); };
}
