-- ═══════════════════════════════════════════════════════════════════════════
-- MDC Driver Runs — 0002 RLS, grants and the admin helper
--
-- The repo is public and the anon key is published. RLS plus function grants
-- are the ENTIRE security boundary.
--
-- Two lines of defence, in this order:
--   1. anon holds no table privileges at all. Revoked below, including future
--      tables via ALTER DEFAULT PRIVILEGES. This is the first line.
--   2. RLS policies, admin-only, keyed on the admins table. The second line.
--
-- Drivers never touch a table directly. They reach data only through the
-- SECURITY DEFINER RPCs in 0003.
-- ═══════════════════════════════════════════════════════════════════════════

-- RLS was enabled on all 16 tables when 0001 ran (Supabase's "Run and enable
-- RLS" path). Assert it rather than assume it — a table that silently lost RLS
-- would be readable the moment a grant appeared.
do $do$
declare t text; missing text[] := '{}';
begin
  foreach t in array array[
    'businesses','admins','drivers','driver_sessions','driver_login_attempts',
    'customers','vehicles','vehicle_check_items','vehicle_logs','routes',
    'route_stops','calendar_exceptions','run_days','run_stops','stop_events',
    'import_batches']
  loop
    execute format('alter table public.%I enable row level security', t);
    if not (select relrowsecurity from pg_class
             where oid = format('public.%I', t)::regclass) then
      missing := missing || t;
    end if;
  end loop;
  if array_length(missing, 1) > 0 then
    raise exception 'RLS not enabled on: %', array_to_string(missing, ', ');
  end if;
end $do$;

-- ── admin identity ─────────────────────────────────────────────────────────
-- SECURITY DEFINER so policies on admins cannot recurse into themselves.
create or replace function public.is_admin(p_business_id uuid default null)
returns boolean
language sql stable security definer set search_path = public, pg_temp as $fn$
  select exists (
    select 1 from public.admins a
     where a.user_id = auth.uid()
       and (p_business_id is null or a.business_id = p_business_id)
  );
$fn$;

revoke execute on function public.is_admin(uuid) from anon, public;
grant  execute on function public.is_admin(uuid) to authenticated;

-- ── policies ───────────────────────────────────────────────────────────────
-- Every policy targets authenticated only. anon gets no policy anywhere,
-- which combined with the revokes below means anon reaches nothing.

create policy businesses_admin_all on public.businesses
  for all to authenticated using (public.is_admin(id)) with check (public.is_admin(id));

-- an admin sees their own row, plus every admin of a business they administer
create policy admins_self_or_admin on public.admins
  for all to authenticated
  using (user_id = auth.uid() or public.is_admin(business_id))
  with check (public.is_admin(business_id));

do $do$
declare t text;
begin
  foreach t in array array[
    'drivers','customers','vehicles','vehicle_check_items','vehicle_logs',
    'routes','route_stops','calendar_exceptions','run_days','run_stops',
    'import_batches']
  loop
    execute format($p$
      create policy %I_admin_all on public.%I
        for all to authenticated
        using (public.is_admin(business_id))
        with check (public.is_admin(business_id))$p$, t, t);
  end loop;
end $do$;

-- stop_events has no business_id of its own; reach it through its run_stop.
-- Read-only for admins: the append is done by SECURITY DEFINER RPCs.
create policy stop_events_admin_read on public.stop_events
  for select to authenticated
  using (exists (
    select 1 from public.run_stops rs
     where rs.id = stop_events.run_stop_id and public.is_admin(rs.business_id)
  ));

-- driver_sessions and driver_login_attempts get NO policy. They are reachable
-- only through SECURITY DEFINER functions, and are revoked from both roles below.

-- ── grants: anon reaches nothing ───────────────────────────────────────────
revoke all on all tables    in schema public from anon;
revoke all on all sequences in schema public from anon;
revoke all on all routines  in schema public from anon;
alter default privileges in schema public revoke all on tables    from anon;
alter default privileges in schema public revoke all on sequences from anon;
alter default privileges in schema public revoke all on routines  from anon;

-- ── grants: authenticated (the admin UI) ───────────────────────────────────
grant usage on schema public to authenticated;
grant select, insert, update, delete on all tables in schema public to authenticated;
grant usage, select on all sequences in schema public to authenticated;

-- Secrets stay out of reach even for admins. The PIN hash is never read by the
-- UI and is only ever written by admin_set_driver_pin() in 0003.
revoke all on public.driver_sessions       from authenticated;
revoke all on public.driver_login_attempts from authenticated;

revoke all on public.drivers from authenticated;
grant select (id, business_id, display_name, phone, is_active, sort_order,
              locked_until, created_at, updated_at)
  on public.drivers to authenticated;
grant update (display_name, phone, is_active, sort_order, locked_until)
  on public.drivers to authenticated;
grant insert, delete on public.drivers to authenticated;

-- stop_events is append-only and written by RPCs; admins read, never write.
revoke insert, update, delete on public.stop_events from authenticated;

-- ── admin-only helpers that must bypass the column grants ──────────────────

-- PINs are set from the admin page, never chosen by the driver. House
-- convention is the last four digits of their mobile; the UI offers that as a
-- one-click prefill and allows an override. The hash is unrecoverable, so a
-- forgotten PIN is reset, never looked up.
-- pgcrypto lives in the extensions schema on Supabase, so crypt/gen_salt need it
-- on the search_path or the function raises 'crypt(text, text) does not exist'.
create or replace function public.admin_set_driver_pin(p_driver_id uuid, p_pin text)
returns void
language plpgsql security definer set search_path = public, extensions, pg_temp as $fn$
declare v_biz uuid;
begin
  select business_id into v_biz from drivers where id = p_driver_id;
  if v_biz is null then
    raise exception 'driver % not found', p_driver_id using errcode = 'P0001';
  end if;
  if not public.is_admin(v_biz) then
    raise exception 'not authorised' using errcode = '42501';
  end if;
  if p_pin !~ '^[0-9]{4}$' then
    raise exception 'PIN must be exactly four digits' using errcode = 'P0001';
  end if;

  update drivers
     set pin_hash = crypt(p_pin, gen_salt('bf', 10)),
         locked_until = null                  -- setting a PIN clears any lockout
   where id = p_driver_id;

  -- a reset invalidates existing sessions: a lost phone is the usual reason
  update driver_sessions set revoked_at = now()
   where driver_id = p_driver_id and revoked_at is null;
end $fn$;

revoke execute on function public.admin_set_driver_pin(uuid, text) from anon, public;
grant  execute on function public.admin_set_driver_pin(uuid, text) to authenticated;

-- Deactivating a driver must also kill their sessions, or an ex-employee keeps
-- a valid one for up to 30 days. One action, not two.
create or replace function public.admin_revoke_driver_sessions(p_driver_id uuid)
returns int
language plpgsql security definer set search_path = public, pg_temp as $fn$
declare v_biz uuid; v_n int;
begin
  select business_id into v_biz from drivers where id = p_driver_id;
  if v_biz is null or not public.is_admin(v_biz) then
    raise exception 'not authorised' using errcode = '42501';
  end if;
  update driver_sessions set revoked_at = now()
   where driver_id = p_driver_id and revoked_at is null;
  get diagnostics v_n = row_count;
  return v_n;
end $fn$;

revoke execute on function public.admin_revoke_driver_sessions(uuid) from anon, public;
grant  execute on function public.admin_revoke_driver_sessions(uuid) to authenticated;

create or replace function public.deactivate_driver_sessions()
returns trigger language plpgsql security definer set search_path = public, pg_temp as $fn$
begin
  if old.is_active and not new.is_active then
    update driver_sessions set revoked_at = now()
     where driver_id = new.id and revoked_at is null;
  end if;
  return new;
end $fn$;

create trigger drivers_deactivate_revokes_sessions
  after update of is_active on public.drivers
  for each row execute function public.deactivate_driver_sessions();
