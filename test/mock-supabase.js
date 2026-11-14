'use strict';
// خادم محاكاة لـ Supabase للاختبار المحلي فقط: يقدّم ملفات الواجهة + /auth/v1 + /rest/v1/rpc/api فوق Postgres محلي عبر psql.
const http = require('node:http'), fs = require('node:fs'), path = require('node:path'), { spawn } = require('node:child_process'), crypto = require('node:crypto');
const PUB = path.join(__dirname, '..', 'public');
const PSQL = ['-h', '/tmp/pg', '-p', '5544', '-U', 'postgres', '-d', 'gk', '-X', '-q', '-At', '-v', 'ON_ERROR_STOP=1', '-v', 'VERBOSITY=verbose'];
const MIME = { '.html': 'text/html; charset=utf-8', '.js': 'text/javascript; charset=utf-8', '.css': 'text/css; charset=utf-8', '.svg': 'image/svg+xml' };
const tokens = new Map(); // access → {sub, exp}; refresh → sub

function psql(script, vars) {
  return new Promise(res => {
    const args = [...PSQL]; for (const [k, v] of Object.entries(vars || {})) args.push('-v', `${k}=${v}`);
    const p = spawn('psql', args); let out = '', err = ''; p.stdout.on('data', d => (out += d)); p.stderr.on('data', d => (err += d));
    p.on('close', code => res({ code, out: out.trim(), err: err.trim() })); p.stdin.end(script);
  });
}
function body(req) { return new Promise(r => { const c = []; req.on('data', d => c.push(d)); req.on('end', () => r(Buffer.concat(c).toString())); }); }
const json = (res, status, obj) => { res.writeHead(status, { 'content-type': 'application/json' }); res.end(JSON.stringify(obj)); };
const mkTokens = sub => { const a = 'mock.' + crypto.randomBytes(12).toString('hex'), r = 'ref.' + crypto.randomBytes(12).toString('hex'); tokens.set(a, { sub, exp: Date.now() + 3600e3 }); tokens.set(r, { sub }); return { access_token: a, refresh_token: r, expires_in: 3600, token_type: 'bearer' }; };

const server = http.createServer(async (req, res) => {
  const u = new URL(req.url, 'http://x');
  try {
    if (u.pathname === '/config.js') { res.writeHead(200, { 'content-type': MIME['.js'] }); return res.end(`window.GAOUK_CONFIG={SUPABASE_URL:location.origin,SUPABASE_ANON_KEY:'anon-test'};`); }
    if (u.pathname === '/auth/v1/token') {
      const b = JSON.parse((await body(req)) || '{}'); const g = u.searchParams.get('grant_type');
      if (g === 'password') {
        const r = await psql(`select id from auth.users where email = :'em' and banned_until is null and encrypted_password = extensions.crypt(:'pw', encrypted_password);`, { em: b.email, pw: b.password });
        if (!r.out) return json(res, 400, { error: 'invalid_grant', error_description: 'Invalid login credentials' });
        return json(res, 200, mkTokens(r.out));
      }
      const t = tokens.get(b.refresh_token); if (!t) return json(res, 400, { error: 'invalid_grant' });
      return json(res, 200, mkTokens(t.sub));
    }
    if (u.pathname === '/auth/v1/logout') return json(res, 204, {});
    const auth = (req.headers.authorization || '').replace('Bearer ', ''); const tk = tokens.get(auth);
    if (u.pathname === '/auth/v1/user' && req.method === 'PUT') {
      if (!tk) return json(res, 401, { msg: 'JWT expired' });
      const b = JSON.parse(await body(req)); const r = await psql(`update auth.users set encrypted_password = extensions.crypt(:'pw', extensions.gen_salt('bf')) where id = :'id';`, { pw: b.password, id: tk.sub });
      return json(res, r.code ? 400 : 200, {});
    }
    if (u.pathname === '/rest/v1/rpc/api') {
      if (!tk || tk.exp < Date.now()) return json(res, 401, { code: 'PGRST301', message: 'JWT expired' });
      const b = JSON.parse(await body(req));
      const r = await psql(`select set_config('request.jwt.claim.sub', :'sub', false);\nset role authenticated;\nselect public.api(:'m', :'p', :'q'::jsonb, :'b'::jsonb);`, { sub: tk.sub, m: b.p_method, p: b.p_path, q: JSON.stringify(b.p_query || {}), b: JSON.stringify(b.p_body || {}) });
      if (r.code) {
        const m = /ERROR:\s+(\w{5}):\s*([^\n]*)/.exec(r.err) || [];
        return json(res, 400, { code: m[1] || 'P0001', message: (m[2] || r.err).trim() });
      }
      const lines = r.out.split('\n'); return json(res, 200, JSON.parse(lines[lines.length - 1]));
    }
    // ملفات ثابتة
    let f = path.normalize(path.join(PUB, u.pathname === '/' ? 'index.html' : u.pathname)); if (!f.startsWith(PUB) || !fs.existsSync(f)) { res.writeHead(404); return res.end('nf'); }
    res.writeHead(200, { 'content-type': MIME[path.extname(f)] || 'application/octet-stream', 'cache-control': 'no-store' }); fs.createReadStream(f).pipe(res);
  } catch (e) { json(res, 500, { message: String(e) }); }
});
module.exports = { server, psql };
if (require.main === module) server.listen(+process.env.PORT || 8099, '127.0.0.1', () => console.log('mock on', server.address().port));
