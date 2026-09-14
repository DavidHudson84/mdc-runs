# CLAUDE.md — SameDay (MDC driver runs)

Working title: **SameDay** — same-day service is what the shops promise, and the runs go out on the same day each week.

Driver run sheets for Master Dry Cleaners. A phone app where a driver opens their run
for the day and ticks stops off, and an admin site where the office maintains drivers,
customers, vans and the weekly pattern.

Owner: David Hudson. He is not a coder — explain outcomes and cost, not mechanics.
Australian spelling throughout. Full scope lives in the plan at
`C:\Users\David\.claude\plans\we-re-looking-to-create-async-summit.md`.

---

## Where it's up to

**Live at https://davidhudson84.github.io/mdc-runs/** (drivers) and
**/admin/** (office).

**Driver side — built and tested end to end** against the live database: name
picker, four-digit PIN with lockout, the once-a-day van check (van, odometer,
checklist), and the run screen with Done / Issue / undo, an offline outbox and
finish-run.

**Admin side — five screens, query shapes validated, interactions untested.**
Today's board, Runs (create a run, Mon–Sat grid, drag customers between days),
Customers (search, edit, read-only "appears on"), Drivers (add, PIN set/reset,
lockout clear, sign out devices) and Vans (register plus "Who was driving?").

Every PostgREST query shape has been checked against the live API and every
table join resolves. What has **not** been exercised is the interaction layer —
drag-and-drop reordering, the add-stop modal, PIN setting — because they need a
signed-in session. Expect rough edges there first.

**Adding an office user:** access is by **invitation**, not by email domain
(migration 0012). The address goes on the `invites` list first, with the level
it gets; then they sign up at `/admin/` with that same address. The
`grant_admin_on_confirm` trigger reads the invite and grants the level, but
only once the address is CONFIRMED. Any address works — Jess is on a hotmail
one. Without an invite a signup gets an auth account and nothing else: no
`admins` row, and every RLS policy runs through `admins`, so no data at all.

The `@hudsongroup.com.au` rule survives in one place only: the very first
account ever created is let in as owner, so there is somebody who can write the
first invite. That has already happened, so it will never fire again.

```sql
insert into public.invites (business_id, email, role, full_name)
select id, 'them@example.com', 'admin', 'Their Name'
  from public.businesses where slug = 'mdc';
```
Roles are `owner`, `admin` and `staff`. If they signed up before you invited
them, run `select apply_invite('them@example.com');` afterwards to grant it.
There is no screen for any of this yet — it is SQL through the Supabase MCP.

> **Confirmation emails do not arrive.** No SMTP is configured, and Supabase's
> built-in mailer is rate-limited to a handful of messages and routinely drops
> them. Signup succeeds and then the person is stuck. Until SMTP is set up,
> confirm each new office user by hand:
> ```sql
> update auth.users set email_confirmed_at = now()
>  where email = 'them@example.com' and email_confirmed_at is null;
> ```
> The trigger fires on that update and grants admin. Fine for two or three
> people; configure SMTP before it is more.

**Drivers never use email or passwords.** Name plus a four-digit PIN, through
the driver RPCs. The invite list only ever affects office logins and cannot
lock a driver out.

**Migrations 0005 and 0006 were applied through the Supabase MCP.** The .sql
files record the schema changes, but several function bodies (driver_login,
driver_today, driver_mark_loaded, admin_create_driver, list_drivers_for_picker)
live only in the database and in git history. Before any fresh deploy, dump the
current function definitions rather than trusting the migration files alone.

**Still to build:** nothing from the original scope. Reports are done — the
Reports screen covers a date range (stop-level CSV export, completion by driver,
customers with repeated issues) and the Daily report covers one day and is
emailed out each evening.

The four drivers are **Kemu, Keith, Binod and Darren**, on the runs Van,
Werribee, Truck and Darren's Van. All four were issued real PINs on 11 Sep 2026
and the placeholders are gone.

**A PIN cannot be read back — only reset.** It is stored as a bcrypt hash, so
nobody, David included, can look up what a driver's PIN currently is. Reset it
from the Drivers page, or `admin_set_driver_pin(driver_id, '1234')`, which also
clears any lockout **and signs that driver's devices out** — a reset assumes a
lost phone, so a driver mid-run will be logged out and needs the new PIN before
their next one. Never write a live PIN into this repo; it is public.

No mobile numbers are on file for any driver, so the house convention (last four
digits of the mobile) cannot be applied until `drivers.phone` is populated.

## The real customer list is loaded

Migrations 0013–0015 load the November 2023 run sheets: **83 customers** and a
**Mon–Sat pattern of about 180 template stops** across the four runs. The two
source spreadsheets are in `data/`, and `data/build_nov23_import.py` is the
one-off desk tool that turned them into 0013 and 0014 — change the sheet or the
tool and regenerate; do not hand-edit those two files.

`customers.external_ref` is the join back to the sheet: `NOV23-nnn` is the line
number in `data/nov23-all-records.csv`, `C-nnn` came off Kemu's Thursday sheet,
`MDC-*` are the shops. Re-importing matches on that ref, so it updates rather
than duplicates.

**Two things the sheets never recorded, and which the office still has to fix:**

- **Which driver does which customer.** Split by suburb — the west on Kemu's
  van, the city and inner east and south on Darren's, Werribee and Wyndham on
  Keith's, Geelong on the truck. Geography only; the sheet says nothing about
  it. The Runs screen has no move-between-runs, so correcting one is a remove
  and an add.
- **The order of stops within a day.** Alphabetical, because the master sheet
  is. The exception is Kemu's Thursday, whose real running order came off his
  own sheet — that one is right, and 0015 restored it after the import
  flattened it.

Watch for `admin_remove_route_stop`: it retires a stop by setting
`active_to`, and Kemu's whole Thursday had been retired that way (every row
`active_to = active_from = 2026-08-24`) before the import ran. A run that looks
empty to `ensure_run_day()` may not be empty in the admin grid — check
`active_to is null` before concluding a day has no pattern.

`run.html?date=YYYY-MM-DD` opens another day and skips the van gate. Used for a
late run finishing after midnight, and for checking a day from the office.

## The daily report

Every evening an email goes to whoever is on the `report_recipients` list —
David and Annalise to start with — saying how the day went: delivered, issues,
what nobody got to, every message the office sent and whether the driver opened
it, the van checks, and a short list of things somebody has to do something
about. The same report is on screen at **/admin/daily.html**, with a date picker
and a Copy-as-text button for pasting into WhatsApp.

Three pieces, and only three:

- **`daily_report(slug, date)`** (migration 0016) does all of the work and
  returns one jsonb blob. The screen and the email both call it, so they cannot
  disagree. It is read-only — it decides nothing and writes nothing, which is
  what makes it safe to run unattended.
- **`scripts/daily-report.mjs`** turns that blob into an email and posts it to
  Resend. Plain Node, no packages, nothing to install. Change the wording of the
  email here.
- **`.github/workflows/daily-report.yml`** runs it at 09:17 UTC, Monday to
  Saturday — 7:17pm Melbourne in winter, 8:17pm in summer. Late enough that
  every run is off the road, so "never finished the run" in the report means
  the driver really did forget to press Finish.

**GitHub's scheduler is not punctual, and the report is built to survive it.**
The first scheduled report was due at 7pm Monday and fired at 1:38am Tuesday —
six and a half hours late — and reported an empty Tuesday, because it had asked
for "today" and today had ticked over. Delays like that cannot be prevented;
GitHub queues scheduled work and the top of the hour is the busiest moment,
which is why the cron sits at 17 minutes past. What can be fixed is the
consequence: `serviceDate()` in the script decides which day the report covers
from the Melbourne clock, and a run before midday is treated as a late report
for the day before. So a delayed report is still the right day's report. An
explicit date on the command line always wins over that rule.
`node scripts/daily-report.test.mjs` checks the rule against eleven fire
times, the real 1:38am failure and the night the clocks change among them.
No packages, no runner — it is plain Node, like everything else here.

**This is the one scheduled job in the project.** Rule "no cron" was about run
generation — runs still build themselves the moment somebody opens the app, and
nothing about the report changes that. An email that arrives at a set time has
to be fired by something, and a GitHub Action is the cheapest thing that does
it: no Edge Function, no pg_cron, no extra hosting, no build step, and the run
history is visible in the repo's Actions tab.

**To send a day by hand** (or re-send one): Actions → Daily run report → Run
workflow, and put a date in. Leave it blank for today. Tick "dry run" to see
what it would say without sending it.

**Two repository secrets make it work**, under Settings → Secrets and variables
→ Actions. Neither is ever written into the repo, which is public:

| Secret | Where it comes from |
| --- | --- |
| `SUPABASE_SERVICE_KEY` | Supabase dashboard → Project settings → API keys |
| `RESEND_API_KEY` | resend.com → API keys, sending permission only |

The from-address defaults to `noreply@hangr.au`. It started as `sameday@`, and
the first two reports were accepted by Microsoft and then vanished -- not the
inbox, not Junk, not any folder, and **not quarantine either**, which was
checked. Switching to `noreply@` fixed it immediately.

What it actually was: something files bulk-looking mail straight into Deleted
Items. On that day four promotional emails landed there, along with an older
`letters@hangr.au` test from August, while the inbox had nothing newer. David
runs Fyxer AI on Outlook, which sorts mail after delivery; a daily no-reply
HTML email is exactly the shape it treats as marketing. `noreply@` got through
because it had already delivered to that mailbox before.

**If a report goes missing, look in Deleted Items**, not Junk and not
quarantine. The durable fixes are `hangr.au` on the Outlook safe-senders list,
and eventually sending from a domain the office already trusts.

To send as Master Dry Cleaners, verify that domain in Resend and set a
repository **variable** (not a secret) called `REPORT_FROM`, e.g.
`SameDay <runs@masterdrycleaners.com.au>`. Mail from a domain the office already
recognises is the real fix; `hangr.au` is a stopgap.

**Adding or removing a recipient** is one line of SQL, the same as invites —
there is no screen for it:

```sql
insert into public.report_recipients (business_id, email, full_name)
select id, 'them@example.com', 'Their Name'
  from public.businesses where slug = 'mdc';

update public.report_recipients set is_active = false
 where lower(email) = 'them@example.com';
```

Set `is_active = false` rather than deleting, so it stays obvious later that
somebody used to be on the list.

## Scope — this project only

This repo is standalone. It has nothing to do with DrapesQuotePro, Fergus,
Xero, Employment Hero, Deputy, or the wider Hudson Group AIOS workspace, and it
must not grow dependencies on any of them. If a session starts pulling in
portfolio context, it is running from the wrong folder — the working directory
should be this repo, not `Desktop\AIOS`.

## Stack

Static HTML/CSS/vanilla JS on GitHub Pages, Supabase behind it. **No npm, no framework,
no build step, no bundler, no Edge Functions, no cron.** `supabase-js` loads as an ES
module from the jsDelivr CDN. Every part added is a part David has to describe accurately
to Claude in eight months when something breaks.

- Supabase project: `gfvybedbfeguhizzgrow` (`mdc-runs`, ap-southeast-2 Sydney)
- Organisation: `hudson-budget` (Pro). ~$10/month for this project's compute.
- **Do not reuse the DrapesQuotePro project** (`kspezkqanaqrhbirqmlc`). Separate blast
  radius, separate anon key, and MDC is under contract to sell — this data may need to
  transfer or be severed independently around November 2026.

---

## The five hard rules

**1. Never hard-delete a template-sourced `run_stop`.**
Removal is `status = 'skipped'` with a reason. A delete lets the next `ensure_run_day()`
resurrect the row and send a driver to a cancelled stop. Enforced by the
`run_stops_no_hard_delete` trigger, not just convention. The escape hatch for genuine
cascades is `set_config('app.allow_run_stop_delete','on',true)` inside the transaction.

**2. `run_stops` reads live while pending, freezes on completion.**
A pending stop renders from the `customers` row joined live, so an edit made at 9am
reaches the driver at 10am. The snapshot columns (`customer_name`, `address_line`,
`suburb`, `phone`, `contact_name`, `standing_order`, `access_notes`) are written **at the
moment the stop is marked done or issue** — never at generation. Completed stops then
render from the frozen copy and never change again.

**3. `service_role` never leaves the machine.**
It must never appear in `assets/config.js`, any committed file, or any client code.
The repo is public. Grep for `service_role` before every deploy. The anon key is public
by design and that is fine — RLS and function grants are the security boundary.

**4. "Today" always comes from the business timezone.**
`(now() at time zone b.timezone)::date`. Never `current_date`, never the browser's UTC
date. A UTC-derived date is wrong in Melbourne from 10am to midnight during daylight
saving.

**5. Doubling up is a per-stop field update.**
`run_stops.assigned_driver_id` is nullable and falls back to `run_days.driver_id`. Never
re-parent rows between run days to reassign work.

---

## Architecture

Two layers, hard separated.

**Template** — `routes`, `route_stops`. The weekly pattern. Editing it changes future
runs and nothing already generated.

**Instance** — `run_days`, `run_stops`, `stop_events`. One materialised row per stop per
actual date. This is what drivers tick. Once generated it is independent of the template.

`ensure_run_day(route_id, service_date)` copies template → instance. It is `SECURITY
DEFINER`, idempotent, **additive only**, takes `pg_advisory_xact_lock` on route+date, and
is called on demand by `driver_today()` and the admin day view. No cron, no nightly job.

Every variation the office needs is an edit to the instance layer alone: public holiday
(`calendar_exceptions`), driver away (`run_days.driver_id`), stops split across two
drivers (`run_stops.assigned_driver_id`), extra stop today (`origin = 'adhoc'`).

### Things the real data forced

- **`route_stops.visit_no`** is in the unique key. Albert Park store is visited twice on
  one Thursday — early, and again at 4.30. Real second visits exist.
- **`frequency`** is not just weekly. `fortnightly` (anchored), `monthly_nth`, and
  `on_call`. On-call stops **never generate**; they are inserted from the day editor with
  `origin = 'adhoc'`.
- **Markers** are a `kind` column, not a table: `customer`, `depot`, `target`, `break`,
  `note`. Non-customer kinds carry `label` and no `customer_id`. Markers with
  `tickable = false` are excluded from the pending count so they can never block
  `driver_finish_run`.

---

## Security model

The repo is public and the anon key is published. RLS plus function grants are the
entire boundary.

- RLS on every table. Admin-only policies via `is_admin(business_id)`.
- `REVOKE ALL ... FROM anon` on all tables and sequences, plus
  `ALTER DEFAULT PRIVILEGES ... REVOKE`, so RLS is the second line and not the first.
- `drivers.pin_hash` and `driver_sessions` are additionally revoked from `authenticated`.
  The admin UI reads drivers through a view that excludes the hash.
- Drivers reach data **only** through `SECURITY DEFINER` RPCs, each with
  `SET search_path = public, pg_temp`, each granted to `anon` explicitly after
  `REVOKE EXECUTE ON ALL FUNCTIONS IN SCHEMA public FROM anon, public`.
- PINs: bcrypt cost 10 via `crypt()`. Five failures in 15 minutes sets `locked_until`.
- Sessions: 32 random bytes, base64url, returned once. The database stores only
  `sha256(token)`. Tokens travel in POST bodies, never query strings.

Run Supabase's security advisor after every DDL change and clear findings before moving on.

---

## Conventions

- Migrations are numbered and live in `supabase/migrations/`. Never edit an applied one —
  add a new file.
- All timestamps `timestamptz`. All ids `uuid` / `gen_random_uuid()`.
- `business_id` on every table and in every unique index. The schema is multi-business
  from day one so Dr Drapes and Wheelie can be added without a rebuild.
- `seq` spaced by 10 on insert.
- Bump `BUILD` in `assets/config.js` on every deploy — the service worker caches by it,
  and a stale cached version is the classic failure of this hosting setup.
- `marked_at` comes from the device, `recorded_at` from the server, clamped server-side
  to `[now() - 36h, now() + 5m]`.

## Deploy

Commit and push to `main`. GitHub Pages serves from the repo root. Never hand files back
for someone to upload manually.
