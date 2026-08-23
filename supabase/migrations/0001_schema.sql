-- ═══════════════════════════════════════════════════════════════════════════
-- MDC Driver Runs — 0001 schema
--
-- Two layers, hard separated:
--   template  : routes, route_stops        (the weekly pattern)
--   instance  : run_days, run_stops        (one materialised day, what drivers tick)
--
-- Three rules that carry the whole design (see CLAUDE.md):
--   1. run_stops.assigned_driver_id is nullable, falls back to run_days.driver_id.
--      Doubling up is a per-stop field update, never re-parenting rows.
--   2. run_stops reads LIVE from customers while pending, and freezes its snapshot
--      columns at the moment it is marked done/issue. Never snapshot at generation.
--   3. Never hard-delete a template-sourced run_stop. Removal is status='skipped'.
--      Enforced by a trigger at the bottom of this file, not just convention.
-- ═══════════════════════════════════════════════════════════════════════════

create extension if not exists pgcrypto;

-- ── tenancy ────────────────────────────────────────────────────────────────
create table public.businesses (
  id         uuid primary key default gen_random_uuid(),
  slug       text not null unique,                 -- 'mdc', 'drdrapes', 'wheelie'
  name       text not null,
  timezone   text not null default 'Australia/Melbourne',
  is_active  boolean not null default true,
  created_at timestamptz not null default now()
);

create table public.admins (
  user_id     uuid not null references auth.users(id) on delete cascade,
  business_id uuid not null references public.businesses(id) on delete cascade,
  full_name   text,
  role        text not null default 'admin' check (role in ('admin','owner')),
  created_at  timestamptz not null default now(),
  primary key (user_id, business_id)
);

-- ── drivers ────────────────────────────────────────────────────────────────
create table public.drivers (
  id           uuid primary key default gen_random_uuid(),
  business_id  uuid not null references public.businesses(id) on delete restrict,
  display_name text not null,
  phone        text,
  pin_hash     text not null,                      -- bcrypt via crypt()
  is_active    boolean not null default true,
  sort_order   int not null default 100,
  locked_until timestamptz,
  created_at   timestamptz not null default now(),
  updated_at   timestamptz not null default now()
);
create unique index drivers_name_uq on public.drivers (business_id, lower(display_name)) where is_active;
create index drivers_picker_idx on public.drivers (business_id, sort_order) where is_active;

create table public.driver_sessions (
  id           uuid primary key default gen_random_uuid(),
  driver_id    uuid not null references public.drivers(id) on delete cascade,
  token_hash   bytea not null unique,              -- sha256 of the opaque token
  issued_at    timestamptz not null default now(),
  expires_at   timestamptz not null default (now() + interval '30 days'),
  last_seen_at timestamptz not null default now(),
  revoked_at   timestamptz,
  user_agent   text
);
create index driver_sessions_live_idx on public.driver_sessions (driver_id) where revoked_at is null;

create table public.driver_login_attempts (
  id           bigint generated always as identity primary key,
  driver_id    uuid references public.drivers(id) on delete cascade,
  business_id  uuid,
  succeeded    boolean not null,
  attempted_at timestamptz not null default now()
);
create index dla_recent_idx on public.driver_login_attempts (driver_id, attempted_at desc);

-- ── customers ──────────────────────────────────────────────────────────────
create table public.customers (
  id             uuid primary key default gen_random_uuid(),
  business_id    uuid not null references public.businesses(id) on delete restrict,
  name           text not null,
  address_line   text,
  suburb         text,
  postcode       text,
  phone          text,
  contact_name   text,
  standing_order text,          -- what to collect and drop. Primary line on the driver card.
  notes          text,          -- general standing notes
  access_notes   text,          -- gate code, key, dog, who to ask for
  earliest_time  time,          -- 'not before 9.30' (Seaview)
  external_ref   text,          -- stable key from the Excel master
  price_rise_date date,
  price_rise_pct  numeric(5,2),
  lat            numeric(9,6),
  lng            numeric(9,6),
  archived_at    timestamptz,   -- soft delete only; never hard delete
  created_at     timestamptz not null default now(),
  updated_at     timestamptz not null default now()
);
create unique index customers_extref_uq on public.customers (business_id, external_ref) where external_ref is not null;
create index customers_live_idx on public.customers (business_id, lower(name)) where archived_at is null;
create index customers_search_idx on public.customers using gin (
  to_tsvector('simple', coalesce(name,'') || ' ' || coalesce(address_line,'') || ' ' || coalesce(suburb,''))
);

-- ── vehicles ───────────────────────────────────────────────────────────────
create table public.vehicles (
  id                  uuid primary key default gen_random_uuid(),
  business_id         uuid not null references public.businesses(id) on delete restrict,
  rego                text not null,
  label               text not null,                -- 'Van 3', 'Fixed truck'
  make_model          text,
  odometer            int,
  odometer_at         timestamptz,
  service_due_date    date,
  service_due_km      int,
  service_interval_km int,
  rego_expiry         date,
  is_active           boolean not null default true,
  notes               text,
  created_at          timestamptz not null default now(),
  updated_at          timestamptz not null default now()
);
create unique index vehicles_rego_uq on public.vehicles (business_id, upper(rego)) where is_active;
create index vehicles_active_idx on public.vehicles (business_id, label) where is_active;

-- editable pre-start questions, not hard-coded
create table public.vehicle_check_items (
  id          uuid primary key default gen_random_uuid(),
  business_id uuid not null references public.businesses(id) on delete cascade,
  label       text not null,
  sort_order  int not null default 100,
  is_active   boolean not null default true,
  created_at  timestamptz not null default now()
);

-- THE fine-attribution record: date + rego -> driver.
-- Deliberately NOT unique on (vehicle_id, service_date) — two drivers can share
-- a van in one day and both rows are the truth.
create table public.vehicle_logs (
  id             uuid primary key default gen_random_uuid(),
  business_id    uuid not null references public.businesses(id) on delete restrict,
  vehicle_id     uuid not null references public.vehicles(id) on delete restrict,
  driver_id      uuid not null references public.drivers(id)  on delete restrict,
  service_date   date not null,
  started_at     timestamptz not null default now(),
  ended_at       timestamptz,
  odometer_start int,
  odometer_end   int,
  answers        jsonb not null default '[]'::jsonb,   -- [{item_id,label,ok,note}]
  failed         boolean not null default false,        -- any 'no' answer
  skipped        boolean not null default false,
  skip_reason    text,
  created_at     timestamptz not null default now(),
  constraint vehicle_logs_skip_ck check (not skipped or skip_reason is not null),
  constraint vehicle_logs_odo_ck  check (odometer_end is null or odometer_start is null
                                         or odometer_end >= odometer_start)
);
create index vehicle_logs_lookup_idx on public.vehicle_logs (vehicle_id, service_date);
create index vehicle_logs_driver_idx on public.vehicle_logs (driver_id, service_date);
create index vehicle_logs_open_idx   on public.vehicle_logs (business_id, service_date desc);

-- ── template layer ─────────────────────────────────────────────────────────
create table public.routes (
  id                uuid primary key default gen_random_uuid(),
  business_id       uuid not null references public.businesses(id) on delete restrict,
  name              text not null,                 -- 'Van', 'Fixed truck', 'West & Geelong'
  default_driver_id uuid references public.drivers(id) on delete set null,
  start_time        time,                          -- Kemu's 10.30am
  is_active         boolean not null default true,
  sort_order        int not null default 100,
  created_at        timestamptz not null default now(),
  updated_at        timestamptz not null default now()
);
create unique index routes_name_uq on public.routes (business_id, lower(name));

create table public.route_stops (
  id             uuid primary key default gen_random_uuid(),
  business_id    uuid not null references public.businesses(id) on delete restrict,
  route_id       uuid not null references public.routes(id) on delete cascade,
  customer_id    uuid references public.customers(id) on delete restrict,

  -- markers: entries that are directions, not visits
  kind           text not null default 'customer'
                   check (kind in ('customer','depot','target','break','note')),
  label          text,                              -- marker text, e.g. 'Back at the factory by 2.00'
  tickable       boolean not null default false,    -- depot markers seed true; notes stay false

  weekday        smallint not null check (weekday between 1 and 7),   -- ISO, 1 = Monday
  visit_no       smallint not null default 1,       -- Albert Park twice on one Thursday
  seq            int not null default 0,            -- spaced by 10 on insert
  scheduled_time time,                              -- Butler 2.30, Albert Park 4.30
  earliest_time  time,                              -- overrides customer.earliest_time
  standing_order text,                              -- day-specific override (Woodfrog Tue vs Thu)
  stop_notes     text,

  frequency      text not null default 'weekly'
                   check (frequency in ('weekly','fortnightly','monthly_nth','on_call')),
  anchor_date    date,                              -- which fortnight it falls on
  nth_of_month   smallint check (nth_of_month between 1 and 5),

  active_from    date not null default current_date,
  active_to      date,                              -- null = open-ended
  created_at     timestamptz not null default now(),
  updated_at     timestamptz not null default now(),

  constraint route_stops_dates_ck check (active_to is null or active_to >= active_from),
  constraint route_stops_kind_ck  check ((kind = 'customer') = (customer_id is not null)),
  constraint route_stops_label_ck check (kind = 'customer' or label is not null),
  constraint route_stops_fortnight_ck check (frequency <> 'fortnightly' or anchor_date is not null),
  constraint route_stops_monthly_ck   check (frequency <> 'monthly_nth' or nth_of_month is not null)
);
-- visit_no in the key is what permits a real second visit to the same customer
create unique index route_stops_uq on public.route_stops
  (route_id, weekday, coalesce(customer_id, '00000000-0000-0000-0000-000000000000'::uuid), visit_no, active_from);
create index route_stops_gen_idx on public.route_stops (route_id, weekday, active_from, active_to);
create index route_stops_cust_idx on public.route_stops (customer_id) where customer_id is not null;

create table public.calendar_exceptions (
  id             uuid primary key default gen_random_uuid(),
  business_id    uuid not null references public.businesses(id) on delete cascade,
  route_id       uuid references public.routes(id) on delete cascade,   -- null = all routes
  exception_date date not null,
  action         text not null check (action in ('no_run','run_anyway')),
  label          text,                              -- 'Melbourne Cup Day'
  created_at     timestamptz not null default now()
);
create unique index calendar_exceptions_uq on public.calendar_exceptions
  (business_id, coalesce(route_id, '00000000-0000-0000-0000-000000000000'::uuid), exception_date);

-- ── instance layer ─────────────────────────────────────────────────────────
create table public.run_days (
  id             uuid primary key default gen_random_uuid(),
  business_id    uuid not null references public.businesses(id) on delete restrict,
  route_id       uuid not null references public.routes(id) on delete restrict,
  service_date   date not null,
  driver_id      uuid references public.drivers(id) on delete set null,
  vehicle_log_id uuid references public.vehicle_logs(id) on delete set null,
  status         text not null default 'planned'
                   check (status in ('planned','in_progress','complete','cancelled')),
  cancel_reason  text,
  generated_at   timestamptz not null default now(),
  generated_from text not null default 'template'
                   check (generated_from in ('template','manual','import')),
  started_at     timestamptz,
  completed_at   timestamptz,
  notes          text,
  created_at     timestamptz not null default now(),
  updated_at     timestamptz not null default now()
);
create unique index run_days_uq on public.run_days (route_id, service_date);
create index run_days_driver_idx on public.run_days (driver_id, service_date);
create index run_days_biz_date_idx on public.run_days (business_id, service_date desc);

create table public.run_stops (
  id                 uuid primary key default gen_random_uuid(),
  business_id        uuid not null references public.businesses(id) on delete restrict,
  run_day_id         uuid not null references public.run_days(id) on delete cascade,
  customer_id        uuid references public.customers(id) on delete set null,
  route_stop_id      uuid references public.route_stops(id) on delete set null,  -- null = ad-hoc
  assigned_driver_id uuid references public.drivers(id) on delete set null,      -- null = run_day driver

  kind           text not null default 'customer'
                   check (kind in ('customer','depot','target','break','note')),
  label          text,
  tickable       boolean not null default true,

  seq            int not null default 0,
  scheduled_time time,
  earliest_time  time,

  -- Snapshot columns. NULL while pending (the app reads the customer live);
  -- written at the moment the stop is marked done/issue. See rule 2.
  customer_name  text,
  address_line   text,
  suburb         text,
  phone          text,
  contact_name   text,
  standing_order text,
  access_notes   text,

  origin       text not null default 'template'
                 check (origin in ('template','adhoc','carried_over')),
  status       text not null default 'pending'
                 check (status in ('pending','done','issue','skipped')),
  issue_reason text check (issue_reason in ('nobody_home','nothing_ready','other')),
  issue_note   text,
  marked_at    timestamptz,   -- driver's device clock, server-clamped
  recorded_at  timestamptz,   -- when the server accepted it
  marked_by_driver_id uuid references public.drivers(id) on delete set null,
  skipped_reason text,
  created_at   timestamptz not null default now(),
  updated_at   timestamptz not null default now(),

  constraint run_stops_issue_ck check (status <> 'issue' or issue_reason is not null),
  constraint run_stops_label_ck check (kind = 'customer' or label is not null)
);
-- idempotent regeneration hinges on this
create unique index run_stops_template_uq on public.run_stops (run_day_id, route_stop_id)
  where route_stop_id is not null;
create index run_stops_day_seq_idx on public.run_stops (run_day_id, seq);
create index run_stops_open_idx    on public.run_stops (run_day_id) where status = 'pending';
create index run_stops_driver_idx  on public.run_stops (assigned_driver_id) where assigned_driver_id is not null;
create index run_stops_cust_idx    on public.run_stops (customer_id) where customer_id is not null;

-- ── audit / offline idempotency ────────────────────────────────────────────
create table public.stop_events (
  id              bigint generated always as identity primary key,
  run_stop_id     uuid not null references public.run_stops(id) on delete cascade,
  client_event_id uuid not null,           -- generated on the phone, dedupes replays
  driver_id       uuid references public.drivers(id) on delete set null,
  actor           text not null default 'driver' check (actor in ('driver','admin','system')),
  action          text not null check (action in ('done','issue','undo','note','created','reassigned')),
  issue_reason    text,
  issue_note      text,
  marked_at       timestamptz not null,
  recorded_at     timestamptz not null default now(),
  was_offline     boolean not null default false
);
create unique index stop_events_client_uq on public.stop_events (client_event_id);
create index stop_events_stop_idx on public.stop_events (run_stop_id, recorded_at desc);

-- ── import traceability ────────────────────────────────────────────────────
create table public.import_batches (
  id          uuid primary key default gen_random_uuid(),
  business_id uuid not null references public.businesses(id) on delete cascade,
  kind        text not null check (kind in ('customers','pattern')),
  filename    text,
  raw_payload jsonb,
  summary     jsonb,
  imported_by uuid references auth.users(id) on delete set null,
  created_at  timestamptz not null default now()
);

-- ── rule 3, enforced ───────────────────────────────────────────────────────
-- A template-sourced run_stop must never be hard-deleted: the next
-- ensure_run_day() would resurrect it and send someone to a cancelled stop.
-- Removal is status='skipped'. Cascade from run_days is allowed via a session flag.
create or replace function public.no_hard_delete_run_stop()
returns trigger language plpgsql as $$
begin
  if old.route_stop_id is not null
     and coalesce(current_setting('app.allow_run_stop_delete', true), 'off') <> 'on' then
    raise exception
      'run_stop % came from the weekly pattern and cannot be deleted. Set status=''skipped'' instead.', old.id
      using errcode = 'P0001';
  end if;
  return old;
end $$;

create trigger run_stops_no_hard_delete
  before delete on public.run_stops
  for each row execute function public.no_hard_delete_run_stop();

-- ── updated_at ─────────────────────────────────────────────────────────────
create or replace function public.touch_updated_at()
returns trigger language plpgsql as $$
begin new.updated_at = now(); return new; end $$;

do $$
declare t text;
begin
  foreach t in array array['drivers','customers','vehicles','routes','route_stops','run_days','run_stops']
  loop
    execute format(
      'create trigger %I_touch before update on public.%I for each row execute function public.touch_updated_at()',
      t, t);
  end loop;
end $$;
