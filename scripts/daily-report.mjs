// ═══════════════════════════════════════════════════════════════════════════
// The daily run report, as an email.
//
// Runs once a day from .github/workflows/daily-report.yml. It asks the
// database one question -- daily_report() -- and turns the answer into an
// email. It decides nothing and stores nothing, so if the numbers look wrong
// the fault is in the SQL function, not here.
//
// Plain Node, no packages, no build step. The same rule as the rest of the
// app: nothing here needs installing before it will run.
//
//   node scripts/daily-report.mjs              today, Melbourne
//   node scripts/daily-report.mjs 2026-09-14   a particular day
//   DRY_RUN=1 node scripts/daily-report.mjs    print it instead of sending
// ═══════════════════════════════════════════════════════════════════════════

import { fileURLToPath } from 'node:url';
import { resolve } from 'node:path';

const SUPABASE_URL = process.env.SUPABASE_URL || 'https://gfvybedbfeguhizzgrow.supabase.co';
const SERVICE_KEY  = process.env.SUPABASE_SERVICE_KEY;   // GitHub secret, never committed
const RESEND_KEY   = process.env.RESEND_API_KEY;         // GitHub secret, never committed
// noreply@hangr.au, not a fresh sameday@ address. The first two reports were
// accepted by Microsoft and then never reached the mailbox -- the signature of
// Defender quarantine, which holds a message outside the mailbox entirely. A
// brand-new sending address has no reputation with the tenant; this one has
// already delivered to it. Override with the REPORT_FROM repository variable.
const FROM         = process.env.REPORT_FROM || 'SameDay — Master Dry Cleaners <noreply@hangr.au>';
const SLUG         = process.env.BUSINESS_SLUG || 'mdc';
const ADMIN_URL    = 'https://davidhudson84.github.io/mdc-runs/admin/daily.html';
const DRY_RUN      = !!process.env.DRY_RUN;
const TZ           = 'Australia/Melbourne';

/* ── which day the report covers ─────────────────────────────────────────── */
// Never "whatever today is when this happens to run". GitHub's scheduler is
// not punctual -- the first scheduled report was due at 7pm Monday and fired
// at 1:38am Tuesday, six and a half hours late, by which time "today" had
// ticked over and it reported an empty Tuesday.
//
// So the report always covers the day whose runs have just finished. Fired in
// the evening, that is today. Fired in the small hours or the morning, it is a
// late evening report, so it is yesterday. Midday is the cutoff: past that,
// a delay is so long that the current day's runs are the more useful answer.
//
// An explicit date on the command line always wins -- that is how the office
// re-sends a particular day.

export function serviceDate(now = new Date()) {
  const parts = new Intl.DateTimeFormat('en-CA', {
    timeZone: TZ, year: 'numeric', month: '2-digit', day: '2-digit',
    hour: '2-digit', hourCycle: 'h23'
  }).formatToParts(now);
  const at = k => parts.find(p => p.type === k).value;
  const day = new Date(`${at('year')}-${at('month')}-${at('day')}T00:00:00Z`);
  if (Number(at('hour')) < 12) day.setUTCDate(day.getUTCDate() - 1);
  return day.toISOString().slice(0, 10);
}

const date         = process.argv[2] || serviceDate();

const REASONS = {
  nobody_home: 'Nobody home',
  nothing_ready: 'Nothing ready',
  other: 'Something else'
};

const esc = s => String(s ?? '').replace(/[<>&"]/g, c =>
  ({ '<':'&lt;', '>':'&gt;', '&':'&amp;', '"':'&quot;' }[c]));

/* ── the day ─────────────────────────────────────────────────────────────── */

async function fetchReport() {
  if (!SERVICE_KEY) throw new Error('SUPABASE_SERVICE_KEY is not set');
  const res = await fetch(`${SUPABASE_URL}/rest/v1/rpc/daily_report`, {
    method: 'POST',
    headers: {
      apikey: SERVICE_KEY,
      Authorization: `Bearer ${SERVICE_KEY}`,
      'Content-Type': 'application/json'
    },
    body: JSON.stringify({ p_business_slug: SLUG, p_date: date })
  });
  const text = await res.text();
  if (!res.ok) throw new Error(`daily_report failed (${res.status}): ${text}`);
  return JSON.parse(text);
}

/* ── the email ───────────────────────────────────────────────────────────── */
// Tables and inline styles throughout. Outlook ignores most of a stylesheet
// and all of flexbox, and this has to be readable on David's phone first.

const INK = '#16202B', DIM = '#5B6B7C', LINE = '#E3E8EE';
const BLUE = '#114C9C', GREEN = '#1B7F4B', RED = '#B3261E', AMBER = '#8A5A00';

const shell = (title, body) => `<!doctype html>
<html><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>${esc(title)}</title></head>
<body style="margin:0;padding:0;background:#F4F6F9;">
<table role="presentation" width="100%" cellpadding="0" cellspacing="0" border="0"
  style="background:#F4F6F9;padding:20px 12px;">
<tr><td align="center">
<table role="presentation" width="640" cellpadding="0" cellspacing="0" border="0"
  style="width:100%;max-width:640px;background:#FFFFFF;border:1px solid ${LINE};
  border-radius:10px;overflow:hidden;font-family:-apple-system,BlinkMacSystemFont,
  'Segoe UI',Helvetica,Arial,sans-serif;color:${INK};">
${body}
</table></td></tr></table></body></html>`;

const section = (heading, inner, colour = INK) => `
<tr><td style="padding:22px 24px 0 24px;">
  <div style="font-size:12px;font-weight:700;letter-spacing:.09em;text-transform:uppercase;
    color:${colour};padding-bottom:10px;border-bottom:2px solid ${LINE};">${esc(heading)}</div>
</td></tr>
<tr><td style="padding:12px 24px 0 24px;">${inner}</td></tr>`;

const rowsTable = rows => `
<table role="presentation" width="100%" cellpadding="0" cellspacing="0" border="0"
  style="font-size:14.5px;line-height:1.45;border-collapse:collapse;">${rows}</table>`;

function tile(n, label, colour) {
  return `<td align="center" style="padding:14px 6px;border:1px solid ${LINE};">
    <div style="font-size:26px;font-weight:700;color:${colour};line-height:1.1;">${n}</div>
    <div style="font-size:10.5px;font-weight:700;letter-spacing:.07em;text-transform:uppercase;
      color:${DIM};padding-top:3px;">${esc(label)}</div></td>`;
}

function buildHtml(r) {
  const t = r.totals || {};
  const P = [];

  // header
  P.push(`<tr><td style="background:${BLUE};padding:22px 24px;">
    <div style="color:#FFFFFF;font-size:19px;font-weight:700;letter-spacing:-.01em;">
      SameDay — driver runs</div>
    <div style="color:#C8DBF5;font-size:14px;padding-top:3px;">
      ${esc(r.date_long)} &middot; ${esc(r.business)}</div></td></tr>`);

  // the numbers
  P.push(`<tr><td style="padding:20px 24px 0 24px;">
    <table role="presentation" width="100%" cellpadding="0" cellspacing="0" border="0"
      style="border-collapse:collapse;table-layout:fixed;"><tr>
      ${tile(t.done ?? 0, 'Delivered', GREEN)}
      ${tile(t.issue ?? 0, 'Issues', t.issue ? RED : DIM)}
      ${tile(t.pending ?? 0, 'Missed', t.pending ? RED : DIM)}
      ${tile(t.completion == null ? '—' : t.completion + '%', 'Completion', BLUE)}
    </tr></table></td></tr>`);

  if (!t.stops) {
    P.push(`<tr><td style="padding:22px 24px;font-size:14.5px;color:${DIM};">
      No stops on the board for ${esc(r.weekday)}. Either no runs go out today,
      or the pattern has nothing set for this day.</td></tr>`);
  }

  // needs action
  if (r.attention?.length) {
    P.push(section('Needs someone to do something', rowsTable(
      r.attention.map(a => `<tr><td style="padding:7px 0;border-bottom:1px solid ${LINE};
        color:${AMBER};">&#9679;&nbsp; ${esc(a)}</td></tr>`).join('')), AMBER));
  }

  // missed
  if (r.missed?.length) {
    P.push(section(`Not done — ${r.missed.length} stop${r.missed.length === 1 ? '' : 's'}`, rowsTable(
      r.missed.map(m => `<tr><td style="padding:8px 0;border-bottom:1px solid ${LINE};">
        <strong>${esc(m.customer)}</strong>${m.suburb ? `<span style="color:${DIM};"> · ${esc(m.suburb)}</span>` : ''}
        ${m.adhoc ? `<span style="color:${DIM};font-size:12.5px;"> · added today</span>` : ''}
        <div style="color:${DIM};font-size:13px;">${esc(m.run)} · ${esc(m.driver)}${
          m.phone ? ' · ' + esc(m.phone) : ''}</div></td></tr>`).join('')), RED));
  }

  // issues
  if (r.issues?.length) {
    P.push(section(`Problems reported — ${r.issues.length}`, rowsTable(
      r.issues.map(i => `<tr><td style="padding:8px 0;border-bottom:1px solid ${LINE};">
        <strong>${esc(i.customer)}</strong>${i.suburb ? `<span style="color:${DIM};"> · ${esc(i.suburb)}</span>` : ''}
        <span style="color:${RED};font-size:13px;"> — ${esc(REASONS[i.reason] || i.reason || 'Issue')}</span>
        ${i.note ? `<div style="padding-top:2px;">&ldquo;${esc(i.note)}&rdquo;</div>` : ''}
        <div style="color:${DIM};font-size:13px;">${esc(i.at || '')} · ${esc(i.run)} · ${esc(i.driver)}${
          i.phone ? ' · ' + esc(i.phone) : ''}</div></td></tr>`).join('')), RED));
  }

  // run by run
  if (r.runs?.length) {
    P.push(section('Run by run', `
      <table role="presentation" width="100%" cellpadding="0" cellspacing="0" border="0"
        style="font-size:14px;border-collapse:collapse;">
        <tr style="color:${DIM};font-size:11px;font-weight:700;letter-spacing:.06em;text-transform:uppercase;">
          <td style="padding:0 0 6px 0;">Run</td>
          <td align="center" style="padding:0 0 6px 0;">Done</td>
          <td align="center" style="padding:0 0 6px 0;">Issue</td>
          <td align="center" style="padding:0 0 6px 0;">Left</td>
          <td align="right" style="padding:0 0 6px 0;">Out</td></tr>
        ${r.runs.map(x => `<tr>
          <td style="padding:8px 0;border-top:1px solid ${LINE};">
            <strong>${esc(x.run)}</strong>
            <div style="color:${DIM};font-size:12.5px;">${esc(x.driver)}${
              x.rego ? ' · ' + esc(x.rego) : ''}</div></td>
          <td align="center" style="padding:8px 0;border-top:1px solid ${LINE};color:${GREEN};font-weight:700;">${x.done}</td>
          <td align="center" style="padding:8px 0;border-top:1px solid ${LINE};color:${x.issue ? RED : DIM};font-weight:700;">${x.issue || '–'}</td>
          <td align="center" style="padding:8px 0;border-top:1px solid ${LINE};color:${x.pending ? RED : DIM};font-weight:700;">${x.pending || '–'}</td>
          <td align="right" style="padding:8px 0;border-top:1px solid ${LINE};color:${DIM};font-size:12.5px;">${
            x.status === 'cancelled' ? 'Cancelled' + (x.cancel_reason ? '<br>' + esc(x.cancel_reason) : '')
            : !x.started ? 'Never opened'
            : esc(x.started) + (x.finished ? '–' + esc(x.finished) : '<br>not finished')}</td>
        </tr>`).join('')}
      </table>`));
  }

  // messages
  if (r.messages?.length) {
    P.push(section('Messages to drivers', rowsTable(
      r.messages.map(m => `<tr><td style="padding:8px 0;border-bottom:1px solid ${LINE};">
        <strong>To ${esc(m.to)}</strong>
        <span style="color:${DIM};font-size:13px;"> · sent ${esc(m.sent || '')}${
          m.sent_by ? ' by ' + esc(m.sent_by) : ''}</span>
        <div style="padding-top:2px;">&ldquo;${esc(m.body)}&rdquo;</div>
        <div style="font-size:13px;color:${m.read ? GREEN : RED};">${
          m.read ? 'Read ' + esc(m.read) + (m.reply ? ' — replied “' + esc(m.reply) + '”' : '')
                 : 'Not read yet'}</div></td></tr>`).join(''))));
  }

  // vans
  if (r.van_checks?.length) {
    P.push(section('Vans', rowsTable(
      r.van_checks.map(v => `<tr><td style="padding:8px 0;border-bottom:1px solid ${LINE};">
        <strong>${esc(v.van || 'Van')}</strong>${v.rego ? `<span style="color:${DIM};"> · ${esc(v.rego)}</span>` : ''}
        <span style="color:${DIM};"> · ${esc(v.driver || '')}</span>
        <div style="font-size:13px;color:${v.skipped || v.failed ? AMBER : DIM};">${
          v.skipped ? 'Check skipped' + (v.skip_reason ? ' — ' + esc(v.skip_reason) : '')
          : v.failed ? 'Fault reported — ' + esc(v.faults || '')
          : 'Check done'}${v.odometer != null ? ' · ' + Number(v.odometer).toLocaleString('en-AU') + ' km' : ''}</div>
      </td></tr>`).join(''))));
  }

  // stops the office pulled
  if (r.removed?.length) {
    P.push(section('Taken off the run by the office', rowsTable(
      r.removed.map(x => `<tr><td style="padding:7px 0;border-bottom:1px solid ${LINE};">
        <strong>${esc(x.customer)}</strong>
        <span style="color:${DIM};font-size:13px;"> · ${esc(x.run)}${
          x.reason ? ' · ' + esc(x.reason) : ''}</span></td></tr>`).join(''))));
  }

  // footer
  P.push(`<tr><td style="padding:26px 24px 24px 24px;">
    <a href="${ADMIN_URL}?date=${esc(r.date)}" style="display:inline-block;background:${BLUE};
      color:#FFFFFF;text-decoration:none;font-size:14.5px;font-weight:600;
      padding:11px 20px;border-radius:7px;">Open the day in the office</a>
    <div style="color:${DIM};font-size:12px;padding-top:16px;line-height:1.5;">
      Sent automatically at ${esc(r.generated_at)} Melbourne time. Counts cover stops a
      driver can tick — depot, breaks and notes are left out.</div></td></tr>`);

  return shell(`Runs — ${r.date_long}`, P.join(''));
}

function buildText(r) {
  const t = r.totals || {};
  const L = [`SameDay — driver runs`, r.date_long, ''];
  L.push(`Delivered ${t.done ?? 0} · Issues ${t.issue ?? 0} · Missed ${t.pending ?? 0} · ` +
         `Completion ${t.completion == null ? '—' : t.completion + '%'}`, '');
  if (r.attention?.length) L.push('NEEDS ACTION', ...r.attention.map(a => ' - ' + a), '');
  if (r.missed?.length) L.push(`NOT DONE (${r.missed.length})`,
    ...r.missed.map(m => ` - ${m.customer}${m.suburb ? ', ' + m.suburb : ''} (${m.run}, ${m.driver})`), '');
  if (r.issues?.length) L.push(`PROBLEMS (${r.issues.length})`,
    ...r.issues.map(i => ` - ${i.customer} — ${REASONS[i.reason] || i.reason}` +
      `${i.note ? ': "' + i.note + '"' : ''} (${i.at}, ${i.driver})`), '');
  if (r.runs?.length) L.push('RUN BY RUN',
    ...r.runs.map(x => ` - ${x.run} (${x.driver}): ${x.done} done, ${x.issue} issue, ` +
      `${x.pending} left — ${x.status === 'cancelled' ? 'cancelled'
        : !x.started ? 'never opened' : x.started + (x.finished ? '–' + x.finished : ', not finished')}`), '');
  if (r.messages?.length) L.push('MESSAGES',
    ...r.messages.map(m => ` - To ${m.to}: "${m.body}" — ${m.read ? 'read ' + m.read : 'NOT READ'}` +
      `${m.reply ? ', replied "' + m.reply + '"' : ''}`), '');
  L.push(`${ADMIN_URL}?date=${r.date}`);
  return L.join('\n');
}

/* ── send ────────────────────────────────────────────────────────────────── */

async function send(to, subject, html, text) {
  if (!RESEND_KEY) throw new Error('RESEND_API_KEY is not set');
  const res = await fetch('https://api.resend.com/emails', {
    method: 'POST',
    headers: { Authorization: `Bearer ${RESEND_KEY}`, 'Content-Type': 'application/json' },
    body: JSON.stringify({ from: FROM, to, subject, html, text })
  });
  const body = await res.text();
  if (!res.ok) throw new Error(`Resend rejected the email (${res.status}): ${body}`);
  return JSON.parse(body);
}

/* ── go ──────────────────────────────────────────────────────────────────── */
// Only when run directly, so the date rule above can be imported and checked
// on its own. Which day the report covers is the one thing here worth being
// certain about -- getting it wrong sends an empty report for the wrong day.

async function main() {
  const r = await fetchReport();
  const t = r.totals || {};

  // A subject line that can be read from the lock screen without opening it.
  const bits = [`${t.done ?? 0} delivered`];
  if (t.pending) bits.push(`${t.pending} missed`);
  if (t.issue) bits.push(`${t.issue} issue${t.issue === 1 ? '' : 's'}`);
  const subject = `Runs ${r.weekday} ${String(r.date).slice(8,10)}/${String(r.date).slice(5,7)} — ${bits.join(', ')}`;

  const html = buildHtml(r);
  const text = buildText(r);
  const to = (r.recipients || []).map(x => x.email);

  if (DRY_RUN) {
    console.log(subject); console.log(''); console.log(text);
    console.log(`\n[dry run] would go to: ${to.join(', ') || '(nobody)'}`);
    if (process.env.DRY_RUN_HTML) console.log('\n' + html);
  } else if (!to.length) {
    console.log('Nobody on the recipient list — nothing sent.');
  } else {
    const out = await send(to, subject, html, text);
    console.log(`Sent to ${to.join(', ')} (${out.id})`);
  }
}

if (fileURLToPath(import.meta.url) === resolve(process.argv[1] || '')) await main();
