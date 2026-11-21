'use strict';
/* مولّد PDF داخل المتصفح (بلا مكتبات): يرسم صفحات التقرير بالمتصفح نفسه (فيُشكَّل العربي صحيحاً) ثم يضعها في ملف PDF حقيقي */
const Pdf = (() => {
  const esc = s => String(s ?? '').replace(/[&<>"]/g, c => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' }[c]));
  const FONT = "font-family:'Segoe UI',Tahoma,'Noto Naskh Arabic','Noto Sans Arabic',Arial,sans-serif;";
  const PAD = 28, FOOT = 26;

  function rowStyle(r, i) {
    if (r.country === 'الإجمالي' || r.date === 'الإجمالي') return 'font-weight:700;background:#fdf1b8;';
    if (r.flight === 'إجمالي اليوم') return 'font-weight:700;background:#f1f6df;';
    return i % 2 ? 'background:#f6f8f4;' : '';
  }
  const td = 'border:1px solid #c9d3c4;padding:6px 7px;text-align:center;vertical-align:middle;font-weight:700;';
  const th = 'border:1px solid #14502a;padding:7px 7px;text-align:center;background:#1d5a34;color:#fff;font-weight:800;';
  const HARD = /الاسم|المقيم|الزائر/;
  const nwOf = (c, soft) => soft ? !!c.nowrap : HARD.test(c.label || '');
  const cellSt = (c, base, soft = true) => base + (nwOf(c, soft) ? 'white-space:nowrap;' : 'word-break:break-word;');

  function titleHtml(d, first) {
    return first
      ? `<div style="text-align:center;margin-bottom:10px"><div style="font-size:22px;font-weight:800;color:#14502a">جاؤوك — ${esc(d.title)}</div><div style="font-size:14px;margin-top:3px">${esc(d.event)}${d.subtitle ? ' — ' + esc(d.subtitle) : ''}</div><div style="font-size:11px;color:#666;margin-top:2px">أُعدّ بواسطة ${esc(d.generated_by)} — ${esc(DT.stamp(d.generated_at || Date.now()))} — ${d.groups ? d.groups.length + ' مجموعة' : d.rows.length + ' سطر'}</div></div>`
      : `<div style="font-size:12px;color:#14502a;font-weight:700;margin-bottom:6px">جاؤوك — ${esc(d.title)} (تابع)</div>`;
  }
  const tableHtml = (d, rows, widths, fs, soft = true) => `<table style="border-collapse:collapse;table-layout:fixed;width:${widths.reduce((a, b) => a + b, 0)}px;font-size:${fs}px"><colgroup>${widths.map(w => `<col style="width:${w}px"/>`).join('')}</colgroup>
    <thead><tr>${d.columns.map(c => `<th style="${th}">${esc(c.label)}</th>`).join('')}</tr></thead><tbody>${rows.map(({ r, i }) => `<tr style="${rowStyle(r, i)}">${d.columns.map(c => `<td style="${cellSt(c, td, soft)}">${esc(r[c.key] ?? '')}</td>`).join('')}</tr>`).join('')}</tbody></table>`;
  const wrap = (W, H, inner) => `<div xmlns="http://www.w3.org/1999/xhtml" dir="rtl" style="${FONT}width:${W}px;height:${H}px;box-sizing:border-box;padding:${PAD}px;background:#fff;color:#111;position:relative;overflow:hidden">${inner}</div>`;

  async function toJpeg(html, W, H, S) {
    const svg = `<svg xmlns="http://www.w3.org/2000/svg" width="${W}" height="${H}"><foreignObject x="0" y="0" width="${W}" height="${H}">${html}</foreignObject></svg>`;
    const img = new Image(); img.decoding = 'async';
    await new Promise((ok, no) => { img.onload = ok; img.onerror = () => no(new Error('تعذّر تجهيز صفحة PDF')); img.src = 'data:image/svg+xml;charset=utf-8,' + encodeURIComponent(svg); });
    const c = document.createElement('canvas'); c.width = Math.round(W * S); c.height = Math.round(H * S);
    const x = c.getContext('2d'); x.fillStyle = '#fff'; x.fillRect(0, 0, c.width, c.height); x.drawImage(img, 0, 0, c.width, c.height);
    const blob = await new Promise(ok => c.toBlob(ok, 'image/jpeg', 0.9));
    return { bytes: new Uint8Array(await blob.arrayBuffer()), w: c.width, h: c.height };
  }

  function buildPdf(pages, ptW, ptH) {
    const enc = new TextEncoder(); const chunks = []; const offs = []; let len = 0;
    const put = x => { const b = typeof x === 'string' ? enc.encode(x) : x; chunks.push(b); len += b.length; };
    const obj = (n, body) => { offs[n] = len; put(`${n} 0 obj\n`); put(body); put('\nendobj\n'); };
    put('%PDF-1.4\n%\xE2\xE3\xCF\xD3\n');
    const n = pages.length; const kids = pages.map((_, i) => `${3 + i * 3} 0 R`).join(' ');
    obj(1, '<< /Type /Catalog /Pages 2 0 R >>'); obj(2, `<< /Type /Pages /Kids [${kids}] /Count ${n} >>`);
    pages.forEach((p, i) => {
      const pg = 3 + i * 3, ct = pg + 1, im = pg + 2; const cs = `q ${ptW} 0 0 ${ptH} 0 0 cm /Im0 Do Q`;
      obj(pg, `<< /Type /Page /Parent 2 0 R /MediaBox [0 0 ${ptW} ${ptH}] /Resources << /XObject << /Im0 ${im} 0 R >> >> /Contents ${ct} 0 R >>`);
      obj(ct, `<< /Length ${cs.length} >>\nstream\n${cs}\nendstream`);
      offs[im] = len; put(`${im} 0 obj\n<< /Type /XObject /Subtype /Image /Width ${p.w} /Height ${p.h} /ColorSpace /DeviceRGB /BitsPerComponent 8 /Filter /DCTDecode /Length ${p.bytes.length} >>\nstream\n`); put(p.bytes); put('\nendstream\nendobj\n');
    });
    const total = 3 + n * 3; const xr = len;
    put(`xref\n0 ${total}\n0000000000 65535 f \n`); for (let i = 1; i < total; i++) put(String(offs[i]).padStart(10, '0') + ' 00000 n \n');
    put(`trailer\n<< /Size ${total} /Root 1 0 R >>\nstartxref\n${xr}\n%%EOF`);
    return new Blob(chunks, { type: 'application/pdf' });
  }


  /* تقرير المجموعات: وحدات HTML (رأس المجموعة ثم أزواج الأسماء بعمودين) تُستعمل في الشاشة وفي PDF */
  const gHead = g => {
    const info = (t, f) => f ? `<div style="margin-top:3px"><b>${t}:</b> ${esc([f.flight_date, f.airport && 'المطار: ' + f.airport, f.airline && 'شركة الطيران: ' + f.airline, f.flight_no && 'رقم الرحلة: ' + f.flight_no, f.flight_time && (t === 'رحلة الوصول' ? 'وقت الوصول: ' : 'وقت المغادرة: ') + f.flight_time].filter(Boolean).join('  |  '))}</div>` : '';
    return `<div style="margin-top:14px;padding:8px 10px;border:1px solid #1d5a34;border-radius:6px;background:#eef5ea;font-size:14px;font-weight:700"><div style="font-size:18px;font-weight:800;color:#14502a">${g.unlinked ? 'زوار غير مرتبطين برقم مجموعة' : `المجموعة رقم (${esc(g.group_no)})${g.country ? ' - ' + esc(g.country) : ''}`}</div>${info('رحلة الوصول', g.arrival)}${info('رحلة المغادرة', g.departure)}<div style="margin-top:4px;font-weight:700">المجموع: ${g.total} (${g.adults} بالغين - ${g.children} أطفال)</div></div>`;
  };
  const gCell = (n, p) => p ? `<td style="width:50%;padding:4px 8px;border-bottom:1px solid #e3e8df;vertical-align:middle;text-align:right;font-weight:700;font-size:15px"><span style="display:inline-block;width:34px;color:#777;text-align:right">${n}.</span><span style="white-space:nowrap">${esc(p.name)}</span>${p.child ? ' <span style="color:#a65b00;font-size:11px">(طفل)</span>' : ''}${p.rel ? ` <span style="color:#555;font-size:11.5px">(${esc(p.rel)})</span>` : ''}</td>` : '<td style="width:50%"></td>';
  const gRow = (g, i) => `<table style="border-collapse:collapse;width:100%;table-layout:fixed"><tr>${gCell(2 * i + 1, g.people[2 * i])}${gCell(2 * i + 2, g.people[2 * i + 1])}</tr></table>`;
  function groupUnits(d) {
    const u = []; for (const g of d.groups) { u.push({ html: gHead(g), keep: 2 }); for (let i = 0; i < Math.ceil(g.people.length / 2); i++) u.push({ html: gRow(g, i) }); } return u;
  }
  async function groupsReport(d, onProgress) {
    const W = 794, H = 1123, S = 1.6; const units = groupUnits(d);
    const stage = document.createElement('div'); stage.style.cssText = `position:fixed;left:-30000px;top:0;width:${W - 2 * PAD}px;${FONT}`; stage.setAttribute('dir', 'rtl');
    stage.innerHTML = `<div>${titleHtml(d, true)}</div>` + units.map(x => `<div>${x.html}</div>`).join(''); document.body.appendChild(stage);
    let titleH, hs; try { const k = [...stage.children]; titleH = k[0].offsetHeight + 10; hs = k.slice(1).map(x => x.getBoundingClientRect().height); } finally { stage.remove(); }
    const avail = H - 2 * PAD - FOOT; const pages = []; let cur = [], used = titleH;
    units.forEach((x, k) => { const need = hs[k] + (x.keep ? (hs[k + 1] || 0) + (hs[k + 2] || 0) : 0); if (cur.length && used + need > avail) { pages.push(cur); cur = []; used = 26; } cur.push(x); used += hs[k]; });
    pages.push(cur); const out = [];
    for (let p = 0; p < pages.length; p++) {
      const body = titleHtml(d, p === 0) + pages[p].map(x => x.html).join('') + `<div style="position:absolute;bottom:10px;left:0;right:0;text-align:center;font-size:11px;color:#777">صفحة ${p + 1} من ${pages.length}</div>`;
      out.push(await toJpeg(wrap(W, H, body), W, H, S)); if (onProgress) onProgress(p + 1, pages.length);
    }
    return buildPdf(out, 595.28, 841.89);
  }

  /** d: بيانات التقرير {title,event,subtitle,generated_by,generated_at,columns:[{key,label}],rows:[{}]} */
  async function report(d, onProgress) {
    if (d.groups) return groupsReport(d, onProgress);
    const items = d.rows.map((r, i) => ({ r, i }));
    // قياس الأعمدة والصفوف على جدول كامل خارج الشاشة: نجرّب عمودياً بخط 15 ثم أفقياً، ثم نصغّر الخط إن لزم كي يبقى الاسم في سطر واحد
    const measure = (W, fs, soft) => {
      const stage = document.createElement('div'); stage.style.cssText = `position:fixed;left:-30000px;top:0;width:${W}px;`;
      stage.innerHTML = `<div dir="rtl" style="${FONT}width:${W}px;padding:${PAD}px;box-sizing:border-box">${titleHtml(d, true)}<div id="m"></div></div>`; document.body.appendChild(stage);
      try {
        const inner = stage.firstChild; const titleH = inner.firstChild.offsetHeight + 10; const target = W - 2 * PAD;
        const m = inner.querySelector('#m'); m.innerHTML = `<table style="border-collapse:collapse;font-size:${fs}px;width:${target}px"><thead><tr>${d.columns.map(c => `<th style="${th}${nwOf(c, soft) ? 'white-space:nowrap;' : ''}">${esc(c.label)}</th>`).join('')}</tr></thead><tbody>${items.map(({ r, i }) => `<tr style="${rowStyle(r, i)}">${d.columns.map(c => `<td style="${cellSt(c, td, soft)}">${esc(r[c.key] ?? '')}</td>`).join('')}</tr>`).join('')}</tbody></table>`;
        const t = m.firstChild; const natural = t.getBoundingClientRect().width; const ths = [...t.tHead.rows[0].cells]; const raw = ths.map(x => x.getBoundingClientRect().width); const sum = raw.reduce((a, b) => a + b, 0);
        return { titleH, headH: t.tHead.offsetHeight, rowH: [...t.tBodies[0].rows].map(x => x.getBoundingClientRect().height), widths: raw.map(w => Math.floor(w * target / sum)), over: natural > target + 2, natural, target };
      } finally { stage.remove(); }
    };
    let W = 794, H = 1123, fs = 15, soft = true, S = 1.6, me = measure(W, fs, soft);
    if (me.over) { W = 1123; H = 794; me = measure(W, fs, soft); }
    if (me.over) { fs = 12; me = measure(W, fs, soft); }
    if (me.over) { soft = false; fs = 15; me = measure(W, fs, soft); }   // يبقى الاسم وحده في سطر واحد وتلتفّ بقية الخانات
    for (let k = 0; k < 4 && me.over && fs > 9; k++) { fs = Math.max(9, Math.floor(fs * me.target / me.natural * 10) / 10 - 0.2); me = measure(W, fs, soft); }
    const landscape = W > H; const { widths, titleH, headH, rowH } = me;
    // توزيع الصفوف على الصفحات
    const avail = H - 2 * PAD - FOOT; const pages = []; let cur = [], used = titleH + headH + 4;
    items.forEach((it, k) => { const h = rowH[k] + 2; if (cur.length && used + h > avail) { pages.push(cur); cur = []; used = 26 + headH + 4; } cur.push(it); used += h; });
    pages.push(cur);
    const out = [];
    for (let p = 0; p < pages.length; p++) {
      const body = titleHtml(d, p === 0) + (pages[p].length ? tableHtml(d, pages[p], widths, fs, soft) : `<div style="text-align:center;padding:40px;color:#666">لا توجد بيانات لهذا التقرير</div>`) +
        `<div style="position:absolute;bottom:10px;left:0;right:0;text-align:center;font-size:11px;color:#777">صفحة ${p + 1} من ${pages.length}</div>`;
      out.push(await toJpeg(wrap(W, H, body), W, H, S)); if (onProgress) onProgress(p + 1, pages.length);
    }
    return buildPdf(out, landscape ? 841.89 : 595.28, landscape ? 595.28 : 841.89);
  }
  return { report, groupUnits };
})();
