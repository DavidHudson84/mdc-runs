# CLAUDE.md — Same Day (MDC driver runs)

Working title: **Same Day** — same-day service is what the shops promise, and the runs go out on the same day each week.

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

**Adding an office user:** they sign up at `/admin/` with a
`@hudsongroup.com.au` address. A trigger (`grant_admin_on_confirm`, migration
0004) grants admin only once the address is CONFIRMED, so a fake address at
that domain gets nothing.

> **Confirmation emails do not arrive.** No SMTP is configured, and Supabase's
> built-in mailer is rate-limited to a handful of messages and routinely drops
> them. Signup succeeds and then the person is stuck. Until SMTP is set up,
> confirm each new office user by hand:
> ```sql
> update auth.users set email_confirmed_at = now()
>  where email = 'them@hudsongroup.com.au' and email_confirmed_at is null;
> ```
> The trigger fires on that update and grants admin. Fine for two or three
> people; configure SMTP before it is more.

**Drivers never use email or passwords.** Name plus a four-digit PIN, through
the driver RPCs. The domain restriction only ever affects office logins and
cannot lock a driver out.

**Migrations 0005 and 0006 were applied through the Supabase MCP.** The .sql
files record the schema changes, but several function bodies (driver_login,
driver_today, driver_mark_loaded, admin_create_driver, list_drivers_for_picker)
live only in the database and in git history. Before any fresh deploy, dump the
current function definitions rather than trusting the migration files alone.

**Still to build:** reports (stop-level CSV export, completion by driver,
customers with repeated issues). Everything else in the original scope is done.

Seeded drivers use placeholder PINs (Kemu 1111, Darren 2222, Sione 3333, Paulo
4444). Reset them from the admin page once it exists — the house convention is
the last four digits of the driver's mobile.

`run.html?date=YYYY-MM-DD` opens another day and skips the van gate. Used for a
late run finishing after midnight, and for checking a day from the office.

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
