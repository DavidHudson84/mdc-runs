-- ═══════════════════════════════════════════════════════════════════════════
-- 0006 — confirm-loaded, drivers without a PIN yet
-- (applied to the live database via the Supabase MCP; recorded here so a fresh
--  deploy reaches the same state)
-- ═══════════════════════════════════════════════════════════════════════════

-- ── confirm loaded ──────────────────────────────────────────────────────────
-- Two separate facts about a stop: the gear went ON the van, and it came OFF at
-- the customer. Kept as its own timestamp rather than another status, so the
-- pending/done/issue machine is untouched and a driver can still go straight to
-- Done when loading isn't a separate step.
alter table public.run_stops
  add column if not exists loaded_at timestamptz,
  add column if not exists loaded_by_driver_id uuid references public.drivers(id) on delete set null;

create index if not exists run_stops_loaded_idx
  on public.run_stops (run_day_id) where loaded_at is not null;

alter table public.stop_events drop constraint if exists stop_events_action_check;
alter table public.stop_events add constraint stop_events_action_check
  check (action in ('done','issue','undo','note','created','reassigned','loaded','unloaded'));

-- driver_mark_loaded, driver_today (now returning loaded_at), admin_create_driver,
-- driver_login (null-hash guard) and list_drivers_for_picker (has_pin) are all
-- defined in the migrations applied via MCP on 24 Aug 2026. See git history.

-- ── drivers without a PIN yet ───────────────────────────────────────────────
-- The office adds a driver, then sets the PIN separately. Forcing one at
-- creation meant inventing a credential for a real person.
alter table public.drivers alter column pin_hash drop not null;
