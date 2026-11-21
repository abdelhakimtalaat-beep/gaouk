'use strict';
/* التاريخ والوقت في كل التطبيق: يوم/شهر/عام وبأرقام عربية (٠١٢٣٤٥٦٧٨٩).
   القيمة المخزَّنة تبقى ISO (YYYY-MM-DD و HH:MM) فلا يتأثر الحفظ ولا قاعدة البيانات؛ التغيير في العرض والإدخال فقط. */
const DT = (() => {
  const AR = '٠١٢٣٤٥٦٧٨٩';
  const toAr = s => String(s).replace(/\d/g, d => AR[d]);
  const toLat = s => String(s).replace(/[٠-٩]/g, c => AR.indexOf(c)).replace(/[۰-۹]/g, c => '۰۱۲۳۴۵۶۷۸۹'.indexOf(c));
  const d = iso => { const m = /^(\d{4})-(\d{2})-(\d{2})$/.exec(iso || ''); return m ? toAr(`${m[3]}/${m[2]}/${m[1]}`) : (iso ? String(iso) : ''); };
  const t = hm => (hm ? toAr(hm) : '');
  // يحوّل أي تواريخ (2026-12-07 أو 07/12/2026) وأوقات (14:30) داخل نص إلى الشكل العربي
  const text = s => typeof s !== 'string' ? s : s.replace(/(?<!\d)(\d{4})-(\d{2})-(\d{2})(?!\d)/g, (_, y, m, dd) => toAr(`${dd}/${m}/${y}`)).replace(/(?<!\d)\d{1,2}\/\d{1,2}\/\d{4}(?!\d)/g, toAr).replace(/(?<!\d)\d{1,2}:\d{2}(?::\d{2})?(?!\d)/g, toAr);
  const stamp = (x = new Date()) => { const p = n => String(n).padStart(2, '0'); const o = x instanceof Date ? x : new Date(x); return toAr(`${p(o.getDate())}/${p(o.getMonth() + 1)}/${o.getFullYear()} ${p(o.getHours())}:${p(o.getMinutes())}`); };
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
    const vis = document.createElement('input'); vis.type = 'text'; vis.className = 'dt-vis'; vis.inputMode = 'numeric'; vis.autocomplete = 'off'; vis.dir = 'ltr'; vis.placeholder = isD ? 'يوم/شهر/عام' : 'ساعة:دقيقة'; vis.maxLength = isD ? 10 : 5;
    const st = real.getAttribute('style'); if (st) { vis.setAttribute('style', st); real.removeAttribute('style'); }
    if (real.required) { vis.required = true; real.required = false; }
    const btn = document.createElement('span'); btn.className = 'dt-btn'; btn.setAttribute('role', 'button'); btn.title = isD ? 'اختيار من التقويم' : 'اختيار الوقت'; btn.textContent = isD ? '📅' : '🕒';
    real.classList.add('dt-real'); real.tabIndex = -1; real.parentNode.insertBefore(wrap, real); wrap.append(vis, btn, real);
    let typing = false;
    const show = () => { if (typing) return; vis.value = isD ? d(valDesc.get.call(real)) : t(valDesc.get.call(real)); vis.setCustomValidity(''); };
    Object.defineProperty(real, 'value', { configurable: true, get() { return valDesc.get.call(real); }, set(v) { valDesc.set.call(real, v); show(); } });
    const setReal = v => { if (valDesc.get.call(real) === v) return; valDesc.set.call(real, v); typing = true; real.dispatchEvent(new Event('input', { bubbles: true })); real.dispatchEvent(new Event('change', { bubbles: true })); typing = false; };
    vis.addEventListener('input', () => {
      const g = toLat(vis.value).replace(/\D/g, '').slice(0, isD ? 8 : 4);
      const f = isD ? g.slice(0, 2) + (g.length > 2 ? '/' + g.slice(2, 4) : '') + (g.length > 4 ? '/' + g.slice(4) : '') : g.slice(0, 2) + (g.length > 2 ? ':' + g.slice(2) : '');
      vis.value = toAr(f); let iso = '', msg = '';
      if (!g.length) msg = '';
      else if (isD) {
        if (g.length < 8) msg = 'أدخل التاريخ كاملاً: يوم/شهر/عام';
        else { const dd = +g.slice(0, 2), mm = +g.slice(2, 4), yy = +g.slice(4); const x = new Date(Date.UTC(yy, mm - 1, dd)); if (yy < 1900 || x.getUTCMonth() !== mm - 1 || x.getUTCDate() !== dd) msg = 'تاريخ غير صحيح'; else { iso = `${g.slice(4)}-${g.slice(2, 4)}-${g.slice(0, 2)}`; if ((real.min && iso < real.min) || (real.max && iso > real.max)) { msg = 'التاريخ خارج المدى المسموح'; iso = ''; } } }
      } else if (g.length < 4) msg = 'أدخل الوقت كاملاً: ساعة:دقيقة'; else { const h = +g.slice(0, 2), mi = +g.slice(2); if (h > 23 || mi > 59) msg = 'وقت غير صحيح'; else iso = `${g.slice(0, 2)}:${g.slice(2)}`; }
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
