-- ═══════════════════════════════════════════════════════════════════════════
-- MDC Driver Runs — 0003 generation + the driver RPCs
--
-- Drivers hold no table privileges. Everything they do goes through these
-- SECURITY DEFINER functions, each of which:
--   * sets search_path = public, pg_temp  (search-path hijack is the #1 real
--     attack against SECURITY DEFINER, and what Supabase's linter flags)
--   * resolves an opaque session token to a driver, or raises
--   * scopes every read and write to that driver, on that date
-- ═══════════════════════════════════════════════════════════════════════════

-- ── helpers ────────────────────────────────────────────────────────────────

-- "Today" is always the business's own calendar day. Never current_date, never
-- the browser's UTC date: a UTC-derived date is wrong in Melbourne from 10am to
-- midnight during daylight saving.
create or replace function public.biz_today(p_business_id uuid)
returns date language sql stable security definer set search_path = public, pg_temp as $fn$
  select (now() at time zone b.timezone)::date from public.businesses b where b.id = p_business_id;
$fn$;

-- Resolves a token and slides the session's expiry. Raises on anything invalid.
-- extensions on the path: digest() is pgcrypto, which Supabase installs there
create or replace function public.driver_from_token(p_token text)
returns uuid language plpgsql security definer set search_path = public, extensions, pg_temp as $fn$
declare v_driver uuid;
begin
  update public.driver_sessions s
     set last_seen_at = now()
   where s.token_hash = digest(p_token, 'sha256')
     and s.revoked_at is null
     and s.expires_at > now()
  returning s.driver_id into v_driver;

  if v_driver is null then
    raise exception 'Session expired. Sign in again.' using errcode = '28000';
  end if;
  if not exists (select 1 from public.drivers d where d.id = v_driver and d.is_active) then
    raise exception 'Session expired. Sign in again.' using errcode = '28000';
  end if;
  return v_driver;
end $fn$;

-- ── generation ─────────────────────────────────────────────────────────────
-- Idempotent, additive only, never updates or deletes an existing run_stop.
-- Called on demand by driver_today() and the admin day view. No cron.
create or replace function public.ensure_run_day(p_route_id uuid, p_service_date date)
returns uuid language plpgsql security definer set search_path = public, pg_temp as $fn$
declare v_biz uuid; v_driver uuid; v_wd smallint; v_action text; v_id uuid; v_status text;
begin
  select business_id, default_driver_id into v_biz, v_driver
    from public.routes where id = p_route_id and is_active;
  if v_biz is null then
    raise exception 'route % not found or inactive', p_route_id using errcode = 'P0001';
  end if;

  v_wd := extract(isodow from p_service_date)::smallint;

  -- serialise concurrent first-openers on the same route + date
  perform pg_advisory_xact_lock(hashtextextended(p_route_id::text || p_service_date::text, 0));

  select action into v_action
    from public.calendar_exceptions
   where business_id = v_biz
     and exception_date = p_service_date
     and (route_id = p_route_id or route_id is null)
   order by (route_id is not null) desc      -- route-specific beats business-wide
   limit 1;

  insert into public.run_days (business_id, route_id, service_date, driver_id, status)
  values (v_biz, p_route_id, p_service_date, v_driver,
          case when v_action = 'no_run' then 'cancelled' else 'planned' end)
  on conflict (route_id, service_date) do nothing;

  select id, status into v_id, v_status
    from public.run_days where route_id = p_route_id and service_date = p_service_date;

  if v_status = 'cancelled' then return v_id; end if;

  insert into public.run_stops (
    business_id, run_day_id, customer_id, route_stop_id, seq,
    kind, label, tickable, scheduled_time, earliest_time, origin)
  select v_biz, v_id, rs.customer_id, rs.id, rs.seq,
         rs.kind, rs.label,
         case when rs.kind = 'customer' then true else rs.tickable end,
         rs.scheduled_time,
         coalesce(rs.earliest_time, c.earliest_time),
         'template'
    from public.route_stops rs
    left join public.customers c on c.id = rs.customer_id
   where rs.route_id = p_route_id
     and rs.weekday  = v_wd
     and rs.active_from <= p_service_date
     and (rs.active_to is null or rs.active_to >= p_service_date)
     and (rs.customer_id is null or c.archived_at is null)
     and case rs.frequency
           when 'weekly'      then true
           when 'fortnightly' then mod(p_service_date - rs.anchor_date, 14) = 0
           when 'monthly_nth' then ceil(extract(day from p_service_date) / 7.0) = rs.nth_of_month
           else false                                   -- on_call never generates
         end
  -- run_stops_template_uq is a PARTIAL index, so its predicate must be repeated
  -- here or Postgres cannot infer which index the conflict target refers to
  on conflict (run_day_id, route_stop_id) where route_stop_id is not null
  do nothing;                                            -- never clobbers ticked work

  return v_id;
end $fn$;

-- ── driver: sign in ────────────────────────────────────────────────────────

create or replace function public.list_drivers_for_picker(p_business_slug text)
returns table (id uuid, display_name text)
language sql stable security definer set search_path = public, pg_temp as $fn$
  select d.id, d.display_name
    from public.drivers d
    join public.businesses b on b.id = d.business_id
   where b.slug = p_business_slug and b.is_active and d.is_active
   order by d.sort_order, d.display_name;
$fn$;

create or replace function public.driver_login(
  p_business_slug text, p_driver_id uuid, p_pin text, p_user_agent text default null)
returns jsonb language plpgsql security definer set search_path = public, extensions, pg_temp as $fn$
declare v_biz uuid; v_hash text; v_locked timestamptz; v_name text;
        v_token text; v_fails int;
begin
  select b.id into v_biz from public.businesses b where b.slug = p_business_slug and b.is_active;
  if v_biz is null then raise exception 'Unknown business' using errcode = 'P0001'; end if;

  select d.pin_hash, d.locked_until, d.display_name into v_hash, v_locked, v_name
    from public.drivers d
   where d.id = p_driver_id and d.business_id = v_biz and d.is_active;
  if v_hash is null then raise exception 'Unknown driver' using errcode = 'P0001'; end if;

  if v_locked is not null and v_locked > now() then
    raise exception 'Too many wrong PINs. Try again in % minutes.',
      greatest(1, ceil(extract(epoch from v_locked - now()) / 60))::int using errcode = 'P0001';
  end if;

  if v_hash <> crypt(p_pin, v_hash) then
    insert into public.driver_login_attempts (driver_id, business_id, succeeded)
    values (p_driver_id, v_biz, false);

    select count(*) into v_fails from public.driver_login_attempts
     where driver_id = p_driver_id and not succeeded
       and attempted_at > now() - interval '15 minutes';

    if v_fails >= 5 then
      update public.drivers set locked_until = now() + interval '15 minutes' where id = p_driver_id;
      raise exception 'Too many wrong PINs. Try again in 15 minutes.' using errcode = 'P0001';
    end if;
    raise exception 'That PIN is not right.' using errcode = 'P0001';
  end if;

  insert into public.driver_login_attempts (driver_id, business_id, succeeded)
  values (p_driver_id, v_biz, true);
  update public.drivers set locked_until = null where id = p_driver_id;

  -- 32 random bytes. Only sha256(token) is stored, so a database leak yields
  -- no usable sessions.
  v_token := encode(gen_random_bytes(32), 'base64');
  v_token := replace(replace(replace(v_token, '+', '-'), '/', '_'), '=', '');

  insert into public.driver_sessions (driver_id, token_hash, user_agent)
  values (p_driver_id, digest(v_token, 'sha256'), p_user_agent);

  return jsonb_build_object(
    'token', v_token,
    'driver', jsonb_build_object('id', p_driver_id, 'name', v_name),
    'expires_at', now() + interval '30 days');
end $fn$;

create or replace function public.driver_logout(p_token text)
returns void language plpgsql security definer set search_path = public, extensions, pg_temp as $fn$
begin
  update public.driver_sessions set revoked_at = now()
   where token_hash = digest(p_token, 'sha256') and revoked_at is null;
end $fn$;

-- ── driver: the van, once a day ────────────────────────────────────────────

create or replace function public.driver_vehicle_options(p_token text)
returns jsonb language plpgsql security definer set search_path = public, pg_temp as $fn$
declare v_driver uuid; v_biz uuid; v_date date;
begin
  v_driver := public.driver_from_token(p_token);
  select business_id into v_biz from public.drivers where id = v_driver;
  v_date := public.biz_today(v_biz);

  return jsonb_build_object(
    'service_date', v_date,
    'existing', (
      select to_jsonb(l) from public.vehicle_logs l
       where l.driver_id = v_driver and l.service_date = v_date and l.ended_at is null
       order by l.started_at desc limit 1),
    'last_vehicle_id', (
      select l.vehicle_id from public.vehicle_logs l
       where l.driver_id = v_driver order by l.service_date desc, l.started_at desc limit 1),
    'vehicles', coalesce((
      select jsonb_agg(jsonb_build_object(
               'id', v.id, 'rego', v.rego, 'label', v.label, 'odometer', v.odometer,
               'service_due_date', v.service_due_date, 'service_due_km', v.service_due_km,
               'rego_expiry', v.rego_expiry,
               'service_soon',
                 (v.service_due_km is not null and v.odometer is not null
                    and v.service_due_km - v.odometer <= 500)
                 or (v.service_due_date is not null and v.service_due_date - v_date <= 14),
               'rego_soon', v.rego_expiry is not null and v.rego_expiry - v_date <= 30)
               order by v.label)
        from public.vehicles v where v.business_id = v_biz and v.is_active), '[]'::jsonb),
    'check_items', coalesce((
      select jsonb_agg(jsonb_build_object('id', i.id, 'label', i.label) order by i.sort_order)
        from public.vehicle_check_items i
       where i.business_id = v_biz and i.is_active), '[]'::jsonb));
end $fn$;

create or replace function public.driver_start_vehicle_log(
  p_token text, p_vehicle_id uuid, p_odometer int, p_answers jsonb default '[]'::jsonb,
  p_skipped boolean default false, p_skip_reason text default null)
returns jsonb language plpgsql security definer set search_path = public, pg_temp as $fn$
declare v_driver uuid; v_biz uuid; v_date date; v_prev int; v_failed boolean; v_id uuid;
begin
  v_driver := public.driver_from_token(p_token);
  select business_id into v_biz from public.drivers where id = v_driver;
  v_date := public.biz_today(v_biz);

  select odometer into v_prev from public.vehicles
   where id = p_vehicle_id and business_id = v_biz and is_active;
  if not found then raise exception 'Unknown van' using errcode = 'P0001'; end if;

  if p_skipped then
    if coalesce(btrim(p_skip_reason), '') = '' then
      raise exception 'Say why the check was skipped.' using errcode = 'P0001';
    end if;
  else
    -- One fat-fingered extra digit otherwise poisons the service-due
    -- calculation permanently, so reject rather than accept and correct later.
    if p_odometer is null then
      raise exception 'Enter the odometer reading.' using errcode = 'P0001';
    end if;
    if v_prev is not null and p_odometer < v_prev then
      raise exception 'That reading (%) is below the last one (%). Check and re-enter.',
        p_odometer, v_prev using errcode = 'P0001';
    end if;
    if v_prev is not null and p_odometer > v_prev + 1500 then
      raise exception 'That reading (%) is more than 1500km above the last one (%). Check and re-enter.',
        p_odometer, v_prev using errcode = 'P0001';
    end if;

    -- anything answered "no" demands a note, or the check is theatre
    if exists (select 1 from jsonb_array_elements(p_answers) a
                where (a->>'ok')::boolean is false
                  and coalesce(btrim(a->>'note'), '') = '') then
      raise exception 'Add a note for anything you answered no to.' using errcode = 'P0001';
    end if;
  end if;

  v_failed := exists (select 1 from jsonb_array_elements(p_answers) a
                       where (a->>'ok')::boolean is false);

  insert into public.vehicle_logs (
    business_id, vehicle_id, driver_id, service_date,
    odometer_start, answers, failed, skipped, skip_reason)
  values (v_biz, p_vehicle_id, v_driver, v_date,
          case when p_skipped then null else p_odometer end,
          coalesce(p_answers, '[]'::jsonb), v_failed, p_skipped, p_skip_reason)
  returning id into v_id;

  if not p_skipped then
    update public.vehicles set odometer = p_odometer, odometer_at = now()
     where id = p_vehicle_id;
  end if;

  update public.run_days
     set vehicle_log_id = v_id
   where service_date = v_date
     and (driver_id = v_driver
          or exists (select 1 from public.run_stops rs
                      where rs.run_day_id = run_days.id and rs.assigned_driver_id = v_driver));

  return jsonb_build_object('id', v_id, 'service_date', v_date, 'failed', v_failed);
end $fn$;

create or replace function public.driver_close_vehicle_log(p_token text, p_odometer int default null)
returns void language plpgsql security definer set search_path = public, pg_temp as $fn$
declare v_driver uuid; v_biz uuid; v_date date; v_start int; v_log uuid;
begin
  v_driver := public.driver_from_token(p_token);
  select business_id into v_biz from public.drivers where id = v_driver;
  v_date := public.biz_today(v_biz);

  select id, odometer_start into v_log, v_start from public.vehicle_logs
   where driver_id = v_driver and service_date = v_date and ended_at is null
   order by started_at desc limit 1;
  if v_log is null then return; end if;       -- never block finishing a run

  update public.vehicle_logs
     set ended_at = now(),
         odometer_end = case when p_odometer is not null and (v_start is null or p_odometer >= v_start)
                             then p_odometer else null end
   where id = v_log;
end $fn$;

-- ── driver: the run ────────────────────────────────────────────────────────

create or replace function public.driver_today(p_token text, p_service_date date default null)
returns jsonb language plpgsql security definer set search_path = public, pg_temp as $fn$
declare v_driver uuid; v_biz uuid; v_date date; v_r record;
begin
  v_driver := public.driver_from_token(p_token);
  select business_id into v_biz from public.drivers where id = v_driver;
  v_date := coalesce(p_service_date, public.biz_today(v_biz));

  -- generate every active route for the date; cheap, idempotent, once a day
  for v_r in select id from public.routes where business_id = v_biz and is_active loop
    perform public.ensure_run_day(v_r.id, v_date);
  end loop;

  return jsonb_build_object(
    'driver', (select jsonb_build_object('id', d.id, 'name', d.display_name)
                 from public.drivers d where d.id = v_driver),
    'service_date', v_date,
    'server_time', now(),
    'vehicle_log', (select to_jsonb(l) from public.vehicle_logs l
                     where l.driver_id = v_driver and l.service_date = v_date
                     order by l.started_at desc limit 1),
    'runs', coalesce((
      select jsonb_agg(r order by r->>'route_name')
        from (
          select jsonb_build_object(
                   'run_day_id', rd.id,
                   'route_name', rt.name,
                   'start_time', rt.start_time,
                   'status', rd.status,
                   'cancel_reason', rd.cancel_reason,
                   'cancel_label', (select ce.label from public.calendar_exceptions ce
                                     where ce.business_id = v_biz
                                       and ce.exception_date = v_date
                                       and (ce.route_id = rd.route_id or ce.route_id is null)
                                     order by (ce.route_id is not null) desc limit 1),
                   'stops', coalesce((
                     select jsonb_agg(jsonb_build_object(
                              'id', s.id, 'seq', s.seq, 'kind', s.kind,
                              'tickable', s.tickable, 'status', s.status,
                              'scheduled_time', s.scheduled_time,
                              'earliest_time', s.earliest_time,
                              -- LIVE while pending, frozen snapshot once settled
                              'name', case when s.status = 'pending'
                                           then coalesce(c.name, s.label)
                                           else coalesce(s.customer_name, s.label) end,
                              'address', case when s.status = 'pending'
                                              then c.address_line else s.address_line end,
                              'suburb', case when s.status = 'pending'
                                             then c.suburb else s.suburb end,
                              'phone', case when s.status = 'pending'
                                            then c.phone else s.phone end,
                              'contact_name', case when s.status = 'pending'
                                                   then c.contact_name else s.contact_name end,
                              'standing_order', case when s.status = 'pending'
                                                     then coalesce(s.standing_order, c.standing_order)
                                                     else s.standing_order end,
                              'access_notes', case when s.status = 'pending'
                                                   then c.access_notes else s.access_notes end,
                              'issue_reason', s.issue_reason, 'issue_note', s.issue_note,
                              'marked_at', s.marked_at)
                            order by s.seq, s.created_at)
                       from public.run_stops s
                       left join public.customers c on c.id = s.customer_id
                      where s.run_day_id = rd.id
                        and s.status <> 'skipped'
                        and coalesce(s.assigned_driver_id, rd.driver_id) = v_driver), '[]'::jsonb)
                 ) as r
            from public.run_days rd
            join public.routes rt on rt.id = rd.route_id
           where rd.service_date = v_date
             and rd.business_id = v_biz
             and (rd.driver_id = v_driver
                  or exists (select 1 from public.run_stops s2
                              where s2.run_day_id = rd.id
                                and s2.assigned_driver_id = v_driver
                                and s2.status <> 'skipped'))
        ) q), '[]'::jsonb));
end $fn$;

create or replace function public.driver_mark_stop(
  p_token text, p_run_stop_id uuid, p_status text,
  p_issue_reason text default null, p_issue_note text default null,
  p_client_event_id uuid default null, p_marked_at timestamptz default null)
returns jsonb language plpgsql security definer set search_path = public, pg_temp as $fn$
declare v_driver uuid; v_marked timestamptz; v_s record;
begin
  v_driver := public.driver_from_token(p_token);

  if p_status not in ('done','issue') then
    raise exception 'bad status %', p_status using errcode = 'P0001';
  end if;
  if p_status = 'issue' and p_issue_reason not in ('nobody_home','nothing_ready','other') then
    raise exception 'An issue needs a reason.' using errcode = 'P0001';
  end if;

  -- Replay of a queued offline action: already recorded, return current state
  -- rather than erroring. stop_events has a unique index on client_event_id.
  if p_client_event_id is not null
     and exists (select 1 from public.stop_events where client_event_id = p_client_event_id) then
    return (select to_jsonb(s) from public.run_stops s where s.id = p_run_stop_id);
  end if;

  select s.*, rd.driver_id as day_driver into v_s
    from public.run_stops s join public.run_days rd on rd.id = s.run_day_id
   where s.id = p_run_stop_id;
  if v_s.id is null then raise exception 'Stop not found' using errcode = 'P0001'; end if;
  if coalesce(v_s.assigned_driver_id, v_s.day_driver) <> v_driver then
    raise exception 'That stop is not on your run.' using errcode = '42501';
  end if;
  if not v_s.tickable then
    raise exception 'That one is a direction, not a stop.' using errcode = 'P0001';
  end if;

  -- device clock, clamped: a phone with a broken clock must not write 2019
  v_marked := least(greatest(coalesce(p_marked_at, now()), now() - interval '36 hours'),
                    now() + interval '5 minutes');

  update public.run_stops s
     set status = p_status,
         issue_reason = case when p_status = 'issue' then p_issue_reason end,
         issue_note   = case when p_status = 'issue' then nullif(btrim(p_issue_note), '') end,
         marked_at = v_marked, recorded_at = now(), marked_by_driver_id = v_driver,
         -- freeze the snapshot at the moment of completion (rule 2)
         customer_name  = coalesce(c.name, s.label),
         address_line   = c.address_line,
         suburb         = c.suburb,
         phone          = c.phone,
         contact_name   = c.contact_name,
         standing_order = coalesce(s.standing_order, c.standing_order),
         access_notes   = c.access_notes
    from (select * from public.customers where id = v_s.customer_id) c
   where s.id = p_run_stop_id;

  -- markers and ad-hoc stops have no customer row; the join above drops them
  update public.run_stops s
     set status = p_status,
         issue_reason = case when p_status = 'issue' then p_issue_reason end,
         issue_note   = case when p_status = 'issue' then nullif(btrim(p_issue_note), '') end,
         marked_at = v_marked, recorded_at = now(), marked_by_driver_id = v_driver,
         customer_name = coalesce(s.customer_name, s.label)
   where s.id = p_run_stop_id and s.customer_id is null;

  insert into public.stop_events (
    run_stop_id, client_event_id, driver_id, actor, action,
    issue_reason, issue_note, marked_at, was_offline)
  values (p_run_stop_id, coalesce(p_client_event_id, gen_random_uuid()), v_driver, 'driver',
          p_status, p_issue_reason, p_issue_note, v_marked,
          p_marked_at is not null and p_marked_at < now() - interval '2 minutes');

  update public.run_days set status = 'in_progress', started_at = coalesce(started_at, now())
   where id = v_s.run_day_id and status = 'planned';

  return (select to_jsonb(s) from public.run_stops s where s.id = p_run_stop_id);
end $fn$;

create or replace function public.driver_undo_stop(
  p_token text, p_run_stop_id uuid, p_client_event_id uuid default null)
returns jsonb language plpgsql security definer set search_path = public, pg_temp as $fn$
declare v_driver uuid; v_s record;
begin
  v_driver := public.driver_from_token(p_token);

  select s.*, rd.driver_id as day_driver into v_s
    from public.run_stops s join public.run_days rd on rd.id = s.run_day_id
   where s.id = p_run_stop_id;
  if v_s.id is null then raise exception 'Stop not found' using errcode = 'P0001'; end if;
  if coalesce(v_s.assigned_driver_id, v_s.day_driver) <> v_driver then
    raise exception 'That stop is not on your run.' using errcode = '42501';
  end if;

  -- status resets, but the snapshot and the event history stay: an undo is a
  -- fact about the day, not an erasure of it
  update public.run_stops
     set status = 'pending', issue_reason = null, issue_note = null,
         marked_at = null, recorded_at = null
   where id = p_run_stop_id;

  insert into public.stop_events (run_stop_id, client_event_id, driver_id, actor, action, marked_at)
  values (p_run_stop_id, coalesce(p_client_event_id, gen_random_uuid()), v_driver, 'driver', 'undo', now());

  return (select to_jsonb(s) from public.run_stops s where s.id = p_run_stop_id);
end $fn$;

create or replace function public.driver_finish_run(p_token text, p_run_day_id uuid)
returns jsonb language plpgsql security definer set search_path = public, pg_temp as $fn$
declare v_driver uuid; v_open int;
begin
  v_driver := public.driver_from_token(p_token);

  -- non-tickable markers are excluded: a direction can never block a finish
  select count(*) into v_open
    from public.run_stops s join public.run_days rd on rd.id = s.run_day_id
   where s.run_day_id = p_run_day_id
     and s.status = 'pending' and s.tickable
     and coalesce(s.assigned_driver_id, rd.driver_id) = v_driver;

  if v_open > 0 then
    raise exception 'Still % stop(s) to go.', v_open using errcode = 'P0001';
  end if;

  update public.run_days set status = 'complete', completed_at = now()
   where id = p_run_day_id;

  return jsonb_build_object('run_day_id', p_run_day_id, 'status', 'complete');
end $fn$;

-- ── grants: nothing implicit ───────────────────────────────────────────────
revoke execute on function
  public.biz_today(uuid), public.driver_from_token(text),
  public.ensure_run_day(uuid, date),
  public.list_drivers_for_picker(text),
  public.driver_login(text, uuid, text, text),
  public.driver_logout(text),
  public.driver_vehicle_options(text),
  public.driver_start_vehicle_log(text, uuid, int, jsonb, boolean, text),
  public.driver_close_vehicle_log(text, int),
  public.driver_today(text, date),
  public.driver_mark_stop(text, uuid, text, text, text, uuid, timestamptz),
  public.driver_undo_stop(text, uuid, uuid),
  public.driver_finish_run(text, uuid)
from anon, public;

-- the twelve the phone may call, and nothing else
grant execute on function public.list_drivers_for_picker(text)                                    to anon;
grant execute on function public.driver_login(text, uuid, text, text)                             to anon;
grant execute on function public.driver_logout(text)                                              to anon;
grant execute on function public.driver_vehicle_options(text)                                     to anon;
grant execute on function public.driver_start_vehicle_log(text, uuid, int, jsonb, boolean, text)  to anon;
grant execute on function public.driver_close_vehicle_log(text, int)                              to anon;
grant execute on function public.driver_today(text, date)                                         to anon;
grant execute on function public.driver_mark_stop(text, uuid, text, text, text, uuid, timestamptz) to anon;
grant execute on function public.driver_undo_stop(text, uuid, uuid)                               to anon;
grant execute on function public.driver_finish_run(text, uuid)                                    to anon;

-- the admin UI additionally needs generation, for viewing a future day
grant execute on function public.ensure_run_day(uuid, date) to authenticated;
grant execute on function public.biz_today(uuid)            to authenticated;
