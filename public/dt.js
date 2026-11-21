'use strict';
/* التاريخ والوقت في كل التطبيق: يوم/شهر/عام وبأرقام عربية (٠١٢٣٤٥٦٧٨٩).
   القيمة المخزَّنة تبقى ISO (YYYY-MM-DD و HH:MM) فلا يتأثر الحفظ ولا قاعدة البيانات؛ التغيير في العرض والإدخال فقط. */
const DT = (() => {
  const AR = '٠١٢٣٤٥٦٧٨٩';
  const toAr = s => String(s).replace(/\d/g, d => AR[d]);
  const toLat = s => String(s).replace(/[٠-٩]/g, c => AR.indexOf(c)).replace(/[۰-۹]/g, c => '۰۱۲۳۴۵۶۷۸۹'.indexOf(c));
  // التاريخ: عام/شهر/يوم (اليوم في الآخر). الوقت: 12 ساعة مع «ص» صباحاً و«م» مساءً
  const d = iso => { const m = /^(\d{4})-(\d{2})-(\d{2})$/.exec(iso || ''); return m ? toAr(`${m[1]}/${m[2]}/${m[3]}`) : (iso ? String(iso) : ''); };
  const t12 = (h, mi) => { h = +h; return toAr(`${String(h % 12 || 12).padStart(2, '0')}:${mi} `) + (h >= 12 ? 'م' : 'ص'); };
  const t = hm => { const m = /^(\d{1,2}):(\d{2})/.exec(hm || ''); return m ? t12(m[1], m[2]) : (hm ? String(hm) : ''); };
  // يحوّل أي تواريخ (2026-12-07) وأوقات (14:30) داخل نص إلى الشكل العربي
  const text = s => typeof s !== 'string' ? s : s.replace(/(?<!\d)(\d{4})-(\d{2})-(\d{2})(?!\d)/g, (_, y, m, dd) => toAr(`${y}/${m}/${dd}`)).replace(/(?<![\d:])([01]?\d|2[0-3]):([0-5]\d)(?::[0-5]\d)?(?![\d:])/g, (_, h, mi) => t12(h, mi));
  const stamp = (x = new Date()) => { const p = n => String(n).padStart(2, '0'); const o = x instanceof Date ? x : new Date(x); return toAr(`${o.getFullYear()}/${p(o.getMonth() + 1)}/${p(o.getDate())} `) + t12(o.getHours(), p(o.getMinutes())); };
  const deep = v => typeof v === 'string' ? text(v) : Array.isArray(v) ? v.map(deep) : v && typeof v === 'object' ? Object.fromEntries(Object.entries(v).map(([k, x]) => [k, deep(x)])) : v;
  const api = { toAr, toLat, d, t, text, stamp, deep };
  if (typeof module !== 'undefined' && module.exports) { module.exports = api; return api; }
  if (typeof document === 'undefined') return api;

  // ===== تحويل النصوص الظاهرة =====
  const SKIP = /^(SCRIPT|STYLE|TEXTAREA|INPUT)$/;
  function fixText(n) { const p = n.parentNode; if (!p || SKIP.test(p.nodeName)) return; const v = n.nodeValue; if (v && /\d/.test(v)) { const w = text(v); if (w !== v) n.nodeValue = w; } }
  function fix(root) {
    if (root.nodeType === 3) return fixText(root); if (root.nodeType !== 1 || SKIP.test(root.nodeName)) return;
    const tw = document.createTreeWalker(root, NodeFilter.SHOW_TEXT); let n; while ((n = tw.nextNode())) fixText(n);
    if (root.matches && root.matches('input[type=date],input[type=time]')) enhance(root); else if (root.querySelectorAll) root.querySelectorAll('input[type=date],input[type=time]').forEach(enhance);
  }

  // ===== حقول التاريخ والوقت =====
  const valDesc = Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, 'value');
  function enhance(real) {
    if (real.dataset.dt) return; real.dataset.dt = '1';
    const kind = real.type, isD = kind === 'date';
    const wrap = document.createElement('span'); wrap.className = 'dt-wrap';
    const vis = document.createElement('input'); vis.type = 'text'; vis.className = 'dt-vis'; vis.inputMode = 'numeric'; vis.autocomplete = 'off'; vis.dir = 'ltr'; vis.placeholder = isD ? 'عام/شهر/يوم' : 'ساعة:دقيقة ص/م'; vis.maxLength = isD ? 10 : 8;
    const st = real.getAttribute('style'); if (st) { vis.setAttribute('style', st); real.removeAttribute('style'); }
    if (real.required) { vis.required = true; real.required = false; }
    const btn = document.createElement('span'); btn.className = 'dt-btn'; btn.setAttribute('role', 'button'); btn.title = isD ? 'اختيار من التقويم' : 'اختيار الوقت'; btn.textContent = isD ? '📅' : '🕒';
    real.classList.add('dt-real'); real.tabIndex = -1; real.parentNode.insertBefore(wrap, real); wrap.append(vis, btn, real);
    let typing = false;
    const show = () => { if (typing) return; fromReal(); prevFull = !isD && !!valDesc.get.call(real); vis.value = isD ? d(valDesc.get.call(real)) : t(valDesc.get.call(real)); vis.setCustomValidity(''); };
    Object.defineProperty(real, 'value', { configurable: true, get() { return valDesc.get.call(real); }, set(v) { valDesc.set.call(real, v); show(); } });
    const setReal = v => { if (valDesc.get.call(real) === v) return; valDesc.set.call(real, v); typing = true; real.dispatchEvent(new Event('input', { bubbles: true })); real.dispatchEvent(new Event('change', { bubbles: true })); typing = false; };
    let per = 'ص', prevFull = false;
    const fromReal = () => { const m = /^(\d{2}):(\d{2})$/.exec(valDesc.get.call(real)); if (m) per = +m[1] >= 12 ? 'م' : 'ص'; };
    vis.addEventListener('input', () => {
      const raw = toLat(vis.value); let g = raw.replace(/\D/g, '').slice(0, isD ? 8 : 4); let iso = '', msg = '';
      if (isD) {
        const f = g.slice(0, 4) + (g.length > 4 ? '/' + g.slice(4, 6) : '') + (g.length > 6 ? '/' + g.slice(6) : ''); vis.value = toAr(f);
        if (!g.length) msg = '';
        else if (g.length < 8) msg = 'أدخل التاريخ كاملاً: عام/شهر/يوم';
        else { const yy = +g.slice(0, 4), mm = +g.slice(4, 6), dd = +g.slice(6); const x = new Date(Date.UTC(yy, mm - 1, dd)); if (yy < 1900 || x.getUTCMonth() !== mm - 1 || x.getUTCDate() !== dd) msg = 'تاريخ غير صحيح'; else { iso = `${g.slice(0, 4)}-${g.slice(4, 6)}-${g.slice(6)}`; if ((real.min && iso < real.min) || (real.max && iso > real.max)) { msg = 'التاريخ خارج المدى المسموح'; iso = ''; } } }
      } else {
        if (!g.length) per = 'ص';
        const L = (raw.match(/[صمapAP]/g) || []).map(c => (/[مpP]/.test(c) ? 'م' : 'ص')), nw = L.find(x => x !== per) || L[0];
        if (nw) per = nw; else if (prevFull && g.length === 4) g = g.slice(0, 3); // حُذف حرف الفترة بالمسح: نحذف آخر رقم
        const f = g.slice(0, 2) + (g.length > 2 ? ':' + g.slice(2) : ''); let h = g.length >= 2 ? +g.slice(0, 2) : -1;
        if (g.length === 4) { if (h > 12 && h <= 23) per = 'م'; vis.value = toAr(f) + ' ' + per; } else vis.value = toAr(f);
        prevFull = g.length === 4;
        if (!g.length) msg = ''; else if (g.length < 4) msg = 'أدخل الوقت كاملاً: ساعة:دقيقة ثم ص أو م';
        else { const mi = +g.slice(2); if (h > 23 || mi > 59 || h === 0 && per === 'م') msg = 'وقت غير صحيح'; else { const h24 = h > 12 ? h : (h % 12) + (per === 'م' ? 12 : 0); iso = `${String(h24).padStart(2, '0')}:${g.slice(2)}`; } }
      }
      vis.setCustomValidity(msg); setReal(iso);
    });
    vis.addEventListener('blur', () => { typing = false; if (!vis.validationMessage) show(); });
    const pick = () => { try { real.showPicker ? real.showPicker() : real.focus(); } catch (_) { real.focus(); } };
    btn.addEventListener('click', e => { e.preventDefault(); pick(); });
    real.addEventListener('change', show); real.addEventListener('input', show);
    show();
  }

  function start() {
    fix(document.body);
    new MutationObserver(ms => { for (const m of ms) { if (m.type === 'characterData') fixText(m.target); else m.addedNodes.forEach(fix); } }).observe(document.body, { childList: true, subtree: true, characterData: true });
  }
  if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', start); else start();
  return api;
})();
