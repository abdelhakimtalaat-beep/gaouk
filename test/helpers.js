'use strict';
const fs = require('node:fs'), path = require('node:path'), vm = require('node:vm');
const PUB = path.join(__dirname, '..', 'public');
const ctx = { base: null };
function client() {
  const sandbox = { fetch, URL, URLSearchParams, Blob, TextEncoder, TextDecoder, Response, DecompressionStream, CompressionStream, console, setTimeout, clearTimeout, Date, Promise };
  sandbox.window = sandbox; sandbox.App = { user: null }; sandbox.GAOUK_CONFIG = { SUPABASE_URL: ctx.base, SUPABASE_ANON_KEY: 'anon-test' };
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

module.exports = { client, ctx };
