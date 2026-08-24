// Admin-side data access. Unlike drivers (who hold no table privileges and go
// through SECURITY DEFINER functions), the office signs in with Supabase Auth
// and reads tables directly — RLS does the work via the admins table.
import { SUPABASE_URL, SUPABASE_KEY } from './config.js';

const SESSION_KEY = 'mdc.admin';

export const auth = {
  get session() {
    try { return JSON.parse(localStorage.getItem(SESSION_KEY) || 'null'); }
    catch { return null; }
  },
  get token() { const s = auth.session; return s && s.access_token; },
  save(s) { localStorage.setItem(SESSION_KEY, JSON.stringify(s)); },
  clear() { localStorage.removeItem(SESSION_KEY); }
};

export async function signIn(email, password) {
  const res = await fetch(`${SUPABASE_URL}/auth/v1/token?grant_type=password`, {
    method: 'POST',
    headers: { apikey: SUPABASE_KEY, 'Content-Type': 'application/json' },
    body: JSON.stringify({ email, password })
  });
  const body = await res.json();
  if (!res.ok) throw new Error(body.error_description || body.msg || 'Sign in failed');
  auth.save(body);
  return body;
}

async function refresh() {
  const s = auth.session;
  if (!s || !s.refresh_token) return false;
  const res = await fetch(`${SUPABASE_URL}/auth/v1/token?grant_type=refresh_token`, {
    method: 'POST',
    headers: { apikey: SUPABASE_KEY, 'Content-Type': 'application/json' },
    body: JSON.stringify({ refresh_token: s.refresh_token })
  });
  if (!res.ok) { auth.clear(); return false; }
  auth.save(await res.json());
  return true;
}

// PostgREST call with the admin's JWT. Retries once through a token refresh so
// a stale hour-old tab doesn't dump the user back at the login screen.
export async function db(path, opts = {}, retried = false) {
  const res = await fetch(`${SUPABASE_URL}/rest/v1/${path}`, {
    ...opts,
    headers: {
      apikey: SUPABASE_KEY,
      Authorization: `Bearer ${auth.token}`,
      'Content-Type': 'application/json',
      ...(opts.headers || {})
    }
  });
  if (res.status === 401 && !retried) {
    if (await refresh()) return db(path, opts, true);
    auth.clear();
    throw new Error('Signed out. Sign in again.');
  }
  const text = await res.text();
  let body = null;
  try { body = text ? JSON.parse(text) : null; } catch { body = text; }
  if (!res.ok) throw new Error((body && body.message) || `Request failed (${res.status})`);
  return body;
}

export async function rpcAdmin(fn, args = {}) {
  return db(`rpc/${fn}`, { method: 'POST', body: JSON.stringify(args) });
}

/* ── shared chrome ───────────────────────────────────────────────────────── */

export const esc = s => String(s ?? '')
  .replace(/[<>&"]/g, c => ({ '<':'&lt;', '>':'&gt;', '&':'&amp;', '"':'&quot;' }[c]));

export const hhmm = t => t ? String(t).slice(0, 5) : '';

export const clock = iso => iso
  ? new Date(iso).toLocaleTimeString('en-AU', { hour:'numeric', minute:'2-digit' })
      .toLowerCase().replace(' ', '')
  : '';

export const longDate = d =>
  new Date(d + 'T00:00:00').toLocaleDateString('en-AU',
    { weekday:'long', day:'numeric', month:'long' });

export function todayISO() {
  // Melbourne, always — never the browser's UTC date
  const f = new Intl.DateTimeFormat('en-CA', {
    timeZone: 'Australia/Melbourne', year:'numeric', month:'2-digit', day:'2-digit'
  });
  return f.format(new Date());
}

export function nav(current) {
  const items = [
    ['index.html', 'Today'],
    ['customers.html', 'Customers'],
    ['vans.html', 'Vans']
  ];
  return `<nav class="anav">
    <a class="brand" href="index.html">Driver Runs</a>
    <div class="tabs">
      ${items.map(([href, label]) =>
        `<a href="${href}" ${href === current ? 'aria-current="page"' : ''}>${label}</a>`).join('')}
    </div>
    <button class="signout" id="asignout">Sign out</button>
  </nav>`;
}

export function wireNav() {
  const b = document.getElementById('asignout');
  if (b) b.addEventListener('click', () => { auth.clear(); location.replace('index.html'); });
}

export async function signUp(email, password) {
  const res = await fetch(`${SUPABASE_URL}/auth/v1/signup`, {
    method: 'POST',
    headers: { apikey: SUPABASE_KEY, 'Content-Type': 'application/json' },
    body: JSON.stringify({ email, password })
  });
  const body = await res.json();
  if (!res.ok) throw new Error(body.error_description || body.msg || 'Could not create that login');
  return body;
}

// One login card shared by every admin page. Handles sign-in and first-time
// sign-up, and calls back when there's a live session.
export function mountLogin(root, onSuccess) {
  let mode = 'in', error = '', note = '';

  function draw() {
    root.innerHTML = `<div class="login-card">
      <span class="mark">Master Dry Cleaners</span>
      <h1>Driver Runs &mdash; office</h1>
      <p class="sub">${mode === 'in'
        ? 'Sign in with your work email.'
        : 'Create your login. Only @hudsongroup.com.au addresses get access, and you&rsquo;ll need to confirm the email.'}</p>
      ${error ? `<p class="err">${esc(error)}</p>` : ''}
      ${note ? `<p class="err" style="background:var(--accent-soft);border-color:var(--accent-line);color:var(--accent)">${esc(note)}</p>` : ''}
      <label for="email">Email</label>
      <input id="email" type="email" autocomplete="username" placeholder="you@hudsongroup.com.au">
      <label for="pw">Password</label>
      <input id="pw" type="password" autocomplete="${mode === 'in' ? 'current-password' : 'new-password'}">
      <button class="primary" id="go">${mode === 'in' ? 'Sign in' : 'Create login'}</button>
      <button class="linkish" id="swap" style="margin-top:14px">${
        mode === 'in' ? 'First time? Create your login' : 'Already have a login? Sign in'}</button>
    </div>`;

    const go = async () => {
      const email = root.querySelector('#email').value.trim();
      const pw = root.querySelector('#pw').value;
      if (!email || !pw) { error = 'Enter your email and password.'; note = ''; return draw(); }
      try {
        if (mode === 'in') { await signIn(email, pw); onSuccess(); return; }
        const r = await signUp(email, pw);
        if (r.access_token) { auth.save(r); onSuccess(); return; }
        mode = 'in'; error = '';
        note = 'Check your email and click the confirmation link, then sign in.';
        draw();
      } catch (err) { error = err.message; note = ''; draw(); }
    };

    root.querySelector('#go').addEventListener('click', go);
    root.querySelector('#pw').addEventListener('keydown', e => { if (e.key === 'Enter') go(); });
    root.querySelector('#swap').addEventListener('click', () => {
      mode = mode === 'in' ? 'up' : 'in'; error = ''; note = ''; draw();
    });
  }

  draw();
}
