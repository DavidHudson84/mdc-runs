// Talks to Supabase over plain fetch. No supabase-js: every call we make is an
// RPC POST, and the library would be 40kb to save about ten lines.
import { SUPABASE_URL, SUPABASE_KEY, BUSINESS_SLUG } from './config.js';

const TOKEN_KEY = 'mdc.token';
const DRIVER_KEY = 'mdc.driver';
const OUTBOX_KEY = 'mdc.outbox';
const CACHE_KEY = 'mdc.lastRun';

/* ── session ─────────────────────────────────────────────────────────────── */

export const session = {
  get token() { return localStorage.getItem(TOKEN_KEY); },
  get driver() {
    try { return JSON.parse(localStorage.getItem(DRIVER_KEY) || 'null'); }
    catch { return null; }
  },
  save(token, driver) {
    localStorage.setItem(TOKEN_KEY, token);
    localStorage.setItem(DRIVER_KEY, JSON.stringify(driver));
  },
  clear() {
    localStorage.removeItem(TOKEN_KEY);
    localStorage.removeItem(DRIVER_KEY);
    localStorage.removeItem(OUTBOX_KEY);
    localStorage.removeItem(CACHE_KEY);
  }
};

/* ── raw call ────────────────────────────────────────────────────────────── */

export class ApiError extends Error {
  constructor(message, code) { super(message); this.code = code; }
}

export async function rpc(fn, args = {}) {
  const res = await fetch(`${SUPABASE_URL}/rest/v1/rpc/${fn}`, {
    method: 'POST',
    headers: { apikey: SUPABASE_KEY, 'Content-Type': 'application/json' },
    body: JSON.stringify(args)
  });
  const text = await res.text();
  let body = null;
  try { body = text ? JSON.parse(text) : null; } catch { body = text; }

  if (!res.ok) {
    const msg = (body && body.message) || `Something went wrong (${res.status})`;
    const err = new ApiError(msg, body && body.code);
    // Any session error means sign in again, whatever the wording
    if (err.code === '28000') session.clear();
    throw err;
  }
  return body;
}

/* ── the calls ───────────────────────────────────────────────────────────── */

export const api = {
  drivers:  ()                => rpc('list_drivers_for_picker', { p_business_slug: BUSINESS_SLUG }),
  // Returns {ok:false, message} for a wrong or locked-out PIN rather than
  // throwing: the failed-attempt record and the lockout must COMMIT, and an
  // exception would roll them back.
  login:    async (driverId, pin) => {
              const r = await rpc('driver_login', {
                p_business_slug: BUSINESS_SLUG,
                p_driver_id: driverId,
                p_pin: pin,
                p_user_agent: navigator.userAgent.slice(0, 200)
              });
              if (!r || r.ok !== true) throw new ApiError((r && r.message) || 'Sign in failed', 'PIN');
              return r;
            },
  logout:   ()                => rpc('driver_logout', { p_token: session.token }),
  vanOptions: ()              => rpc('driver_vehicle_options', { p_token: session.token }),
  startVan: (opts)            => rpc('driver_start_vehicle_log', {
                                   p_token: session.token,
                                   p_vehicle_id: opts.vehicleId,
                                   p_odometer: opts.odometer ?? null,
                                   p_answers: opts.answers || [],
                                   p_skipped: !!opts.skipped,
                                   p_skip_reason: opts.skipReason || null
                                 }),
  closeVan: (odo)             => rpc('driver_close_vehicle_log', {
                                   p_token: session.token, p_odometer: odo ?? null
                                 }),
  today:    (date)            => rpc('driver_today', {
                                   p_token: session.token, p_service_date: date || null
                                 }),
  finish:   (runDayId)        => rpc('driver_finish_run', {
                                   p_token: session.token, p_run_day_id: runDayId
                                 }),
  inbox:    ()                => rpc('driver_inbox', { p_token: session.token }),
  ackMessage: (id, reply)     => rpc('driver_ack_message', {
                                   p_token: session.token, p_message_id: id,
                                   p_reply: reply || null
                                 })
};

/* ── outbox ──────────────────────────────────────────────────────────────── */
// Ticks are recorded locally the instant they happen and drained when there is
// signal. client_event_id makes replay free: stop_events has a unique index on
// it, so a duplicate returns the current state instead of double-recording.

function readOutbox() {
  try { return JSON.parse(localStorage.getItem(OUTBOX_KEY) || '[]'); }
  catch { return []; }
}
function writeOutbox(items) {
  localStorage.setItem(OUTBOX_KEY, JSON.stringify(items));
}

export function queueLength() { return readOutbox().length; }

export function queueAction(action) {
  const items = readOutbox();
  items.push({ ...action, client_event_id: crypto.randomUUID(), marked_at: new Date().toISOString() });
  writeOutbox(items);
  drain();
}

let draining = false;

export async function drain() {
  if (draining || !navigator.onLine) return;
  const items = readOutbox();
  if (!items.length) return;

  draining = true;
  try {
    while (readOutbox().length) {
      const queue = readOutbox();
      const item = queue[0];
      try {
        if (item.type === 'mark') {
          await rpc('driver_mark_stop', {
            p_token: session.token,
            p_run_stop_id: item.stopId,
            p_status: item.status,
            p_issue_reason: item.reason || null,
            p_issue_note: item.note || null,
            p_client_event_id: item.client_event_id,
            p_marked_at: item.marked_at
          });
        } else if (item.type === 'loaded') {
          await rpc('driver_mark_loaded', {
            p_token: session.token,
            p_run_stop_id: item.stopId,
            p_loaded: item.loaded,
            p_client_event_id: item.client_event_id,
            p_marked_at: item.marked_at
          });
        } else if (item.type === 'undo') {
          await rpc('driver_undo_stop', {
            p_token: session.token,
            p_run_stop_id: item.stopId,
            p_client_event_id: item.client_event_id
          });
        }
      } catch (err) {
        // A rejection the server will never accept (bad stop, not your run)
        // must not wedge the queue forever. Drop it and carry on.
        if (err.code && err.code !== '28000' && !(err instanceof TypeError)) {
          console.warn('dropping unsendable action', item, err.message);
        } else {
          break;   // offline or session gone: stop, keep the queue, retry later
        }
      }
      writeOutbox(readOutbox().slice(1));
    }
  } finally {
    draining = false;
    window.dispatchEvent(new CustomEvent('outbox'));
  }
}

// Drain on every plausible recovery moment. Deliberately NOT Background Sync,
// which is Chromium-only and half the drivers will be on iPhones.
window.addEventListener('online', drain);
document.addEventListener('visibilitychange', () => { if (!document.hidden) drain(); });
setInterval(() => { if (queueLength()) drain(); }, 20000);

/* ── last-run cache ──────────────────────────────────────────────────────── */
// So opening the app with no signal shows this morning's run rather than an error.

export function cacheRun(payload) {
  localStorage.setItem(CACHE_KEY, JSON.stringify({ at: Date.now(), payload }));
}
export function readCachedRun() {
  try { return JSON.parse(localStorage.getItem(CACHE_KEY) || 'null'); }
  catch { return null; }
}
