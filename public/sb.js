'use strict';
// عميل Supabase خفيف (بدون مكتبات): تسجيل الدخول، تجديد الجلسة، واستدعاء دالة api في قاعدة البيانات
const SB = (() => {
  const cfg = () => window.GAOUK_CONFIG || {};
  const KEY = 'gaouk_session';
  const store = (() => { try { localStorage.setItem('__t', '1'); localStorage.removeItem('__t'); return localStorage; } catch (_) { const m = {}; return { getItem: k => m[k] ?? null, setItem: (k, v) => (m[k] = v), removeItem: k => delete m[k] }; } })();
  let sess = null; try { sess = JSON.parse(store.getItem(KEY) || 'null'); } catch (_) {}
  const save = s => { sess = s; if (s) store.setItem(KEY, JSON.stringify(s)); else store.removeItem(KEY); };
  const hdr = extra => ({ apikey: cfg().SUPABASE_ANON_KEY, 'Content-Type': 'application/json', ...extra });
  const err = (status, message, extra) => Object.assign(new Error(message), { status, data: { error: message, ...extra } });
  const configured = () => cfg().SUPABASE_URL && !/YOUR-PROJECT/.test(cfg().SUPABASE_URL) && cfg().SUPABASE_ANON_KEY && !/YOUR-ANON/.test(cfg().SUPABASE_ANON_KEY);

  async function raw(path, init) {
    try { return await fetch(cfg().SUPABASE_URL + path, init); } catch (_) { throw err(0, 'تعذر الاتصال بالخادم. تحقق من الإنترنت'); }
  }
  function setSession(j) { save({ access_token: j.access_token, refresh_token: j.refresh_token, expires_at: Date.now() + (j.expires_in || 3600) * 1000 }); }

  async function login(username, password) {
    if (!configured()) throw err(0, 'لم يتم ضبط ملف config.js بعد (رابط المشروع والمفتاح)');
    const r = await raw('/auth/v1/token?grant_type=password', { method: 'POST', headers: hdr(), body: JSON.stringify({ email: String(username).trim().toLowerCase() + '@gaouk.app', password }) });
    const j = await r.json().catch(() => ({}));
    if (!r.ok) throw err(r.status === 400 ? 401 : r.status, 'اسم المستخدم أو كلمة المرور غير صحيحة');
    setSession(j);
  }
  async function refresh() {
    if (!sess || !sess.refresh_token) throw err(401, 'انتهت الجلسة');
    const r = await raw('/auth/v1/token?grant_type=refresh_token', { method: 'POST', headers: hdr(), body: JSON.stringify({ refresh_token: sess.refresh_token }) });
    const j = await r.json().catch(() => ({}));
    if (!r.ok) { save(null); throw err(401, 'انتهت الجلسة'); }
    setSession(j);
  }
  async function token() {
    if (!sess) throw err(401, 'يجب تسجيل الدخول');
    if (sess.expires_at - Date.now() < 60000) await refresh();
    return sess.access_token;
  }
  async function logout() {
    try { if (sess) await raw('/auth/v1/logout', { method: 'POST', headers: hdr({ Authorization: 'Bearer ' + sess.access_token }) }); } catch (_) {}
    save(null);
  }
  async function setPassword(pw) {
    const r = await raw('/auth/v1/user', { method: 'PUT', headers: hdr({ Authorization: 'Bearer ' + (await token()) }), body: JSON.stringify({ password: pw }) });
    const j = await r.json().catch(() => ({}));
    if (!r.ok) throw err(r.status, j.msg || j.message || j.error_description || 'تعذر تغيير كلمة المرور');
  }
  // استدعاء نقطة الدخول الوحيدة public.api
  async function rpc(method, path, query, body, retry = true) {
    const r = await raw('/rest/v1/rpc/api', { method: 'POST', headers: hdr({ Authorization: 'Bearer ' + (await token()) }), body: JSON.stringify({ p_method: method, p_path: path, p_query: query || {}, p_body: body || {} }) });
    const j = await r.json().catch(() => null);
    if (!r.ok) {
      const code = j && j.code, msg = (j && (j.message || j.msg)) || 'خطأ في الخادم';
      if ((code === 'PT401' || code === 'PGRST301' || r.status === 401) && retry && sess) { try { await refresh(); return rpc(method, path, query, body, false); } catch (_) {} }
      if (code === 'PT401' || code === 'PGRST301' || r.status === 401) { save(null); throw err(401, msg === 'JWT expired' ? 'انتهت الجلسة' : msg); }
      if (code === 'PT403') throw err(403, msg);
      if (code === 'PT404') throw err(404, msg);
      if (code === '42501') throw err(403, 'غير مصرح');
      throw err(400, msg);
    }
    if (j && typeof j === 'object' && j._status) throw err(j._status, j.error || 'خطأ', j);
    return j;
  }
  return { login, logout, rpc, setPassword, configured, hasSession: () => !!sess };
})();
