-- ═══════════════════════════════════════════════════════════════════════════
-- 0005 — admin helpers, and four bugs found by testing against live data
-- ═══════════════════════════════════════════════════════════════════════════

-- ── 1. creating a driver ────────────────────────────────────────────────────
-- drivers.pin_hash is NOT NULL and bcrypt can't happen in a browser, so
-- creating a driver goes through here rather than a plain INSERT.
create or replace function public.admin_create_driver(
  p_business_id uuid, p_display_name text, p_phone text default null, p_pin text default null)
returns uuid
language plpgsql security definer set search_path = public, extensions, pg_temp as $fn$
declare v_id uuid; v_pin text;
begin
  if not public.is_admin(p_business_id) then
    raise exception 'not authorised' using errcode = '42501';
  end if;
  if coalesce(btrim(p_display_name), '') = '' then
    raise exception 'A driver needs a name.' using errcode = 'P0001';
  end if;

  -- House convention is the last four digits of their mobile.
  v_pin := nullif(btrim(coalesce(p_pin, '')), '');
  if v_pin is null and p_phone is not null then
    v_pin := right(regexp_replace(p_phone, '[^0-9]', '', 'g'), 4);
  end if;
  if v_pin is null or v_pin !~ '^[0-9]{4}$' then
    raise exception 'Set a four-digit PIN, or give a mobile number to take the last four from.'
      using errcode = 'P0001';
  end if;

  insert into public.drivers (business_id, display_name, phone, pin_hash, sort_order)
  values (p_business_id, btrim(p_display_name), nullif(btrim(coalesce(p_phone,'')), ''),
          crypt(v_pin, gen_salt('bf', 10)),
          coalesce((select max(sort_order) + 10 from public.drivers where business_id = p_business_id), 10))
  returning id into v_id;
  return v_id;
end $fn$;

revoke execute on function public.admin_create_driver(uuid, text, text, text) from anon, public;
grant  execute on function public.admin_create_driver(uuid, text, text, text) to authenticated;

create or replace function public.admin_driver_sessions(p_business_id uuid)
returns table (driver_id uuid, live int, last_seen timestamptz)
language sql stable security definer set search_path = public, pg_temp as $fn$
  select s.driver_id, count(*)::int, max(s.last_seen_at)
    from public.driver_sessions s
    join public.drivers d on d.id = s.driver_id
   where d.business_id = p_business_id
     and s.revoked_at is null and s.expires_at > now()
     and public.is_admin(p_business_id)
   group by s.driver_id;
$fn$;

revoke execute on function public.admin_driver_sessions(uuid) from anon, public;
grant  execute on function public.admin_driver_sessions(uuid) to authenticated;

-- ── 2. the lockout never worked ─────────────────────────────────────────────
-- driver_login used to RAISE on a wrong PIN. Each RPC call is its own
-- transaction, so the exception rolled back the INSERT recording the failed
-- attempt AND the UPDATE setting locked_until. Every failure erased its own
-- evidence and a four-digit PIN had unlimited guesses.
--
-- Failure is now a RETURNED value. Callers must check ok = false.
--
-- Also: the count only considers failures since the last SUCCESSFUL login, so a
-- driver who gets in cleanly isn't left one mistype from a lockout.
create or replace function public.driver_login(
  p_business_slug text, p_driver_id uuid, p_pin text, p_user_agent text default null)
returns jsonb language plpgsql security definer
set search_path = public, extensions, pg_temp as $fn$
declare v_biz uuid; v_hash text; v_locked timestamptz; v_name text;
        v_token text; v_fails int; v_mins int;
begin
  select b.id into v_biz from public.businesses b
   where b.slug = p_business_slug and b.is_active;
  if v_biz is null then raise exception 'Unknown business' using errcode = 'P0001'; end if;

  select d.pin_hash, d.locked_until, d.display_name into v_hash, v_locked, v_name
    from public.drivers d
   where d.id = p_driver_id and d.business_id = v_biz and d.is_active;
  if v_hash is null then raise exception 'Unknown driver' using errcode = 'P0001'; end if;

  if v_locked is not null and v_locked > now() then
    v_mins := greatest(1, ceil(extract(epoch from v_locked - now()) / 60))::int;
    return jsonb_build_object('ok', false, 'locked', true,
      'message', format('Too many wrong PINs. Try again in %s minute%s.',
                        v_mins, case when v_mins = 1 then '' else 's' end));
  end if;

  if v_hash <> crypt(p_pin, v_hash) then
    insert into public.driver_login_attempts (driver_id, business_id, succeeded)
    values (p_driver_id, v_biz, false);

    select count(*) into v_fails
      from public.driver_login_attempts a
     where a.driver_id = p_driver_id and not a.succeeded
       and a.attempted_at > now() - interval '15 minutes'
       and a.attempted_at > coalesce(
             (select max(s.attempted_at) from public.driver_login_attempts s
               where s.driver_id = p_driver_id and s.succeeded), '-infinity'::timestamptz);

    if v_fails >= 5 then
      update public.drivers set locked_until = now() + interval '15 minutes'
       where id = p_driver_id;
      return jsonb_build_object('ok', false, 'locked', true,
        'message', 'Too many wrong PINs. Try again in 15 minutes.');
    end if;

    return jsonb_build_object('ok', false, 'locked', false,
      'attempts_left', 5 - v_fails,
      'message', format('That PIN is not right. %s tr%s left before it locks.',
                        5 - v_fails, case when 5 - v_fails = 1 then 'y' else 'ies' end));
  end if;

  insert into public.driver_login_attempts (driver_id, business_id, succeeded)
  values (p_driver_id, v_biz, true);
  update public.drivers set locked_until = null where id = p_driver_id;

  v_token := encode(extensions.gen_random_bytes(32), 'base64');
  v_token := replace(replace(replace(v_token, '+', '-'), '/', '_'), '=', '');

  insert into public.driver_sessions (driver_id, token_hash, user_agent)
  values (p_driver_id, extensions.digest(v_token, 'sha256'), p_user_agent);

  return jsonb_build_object('ok', true, 'token', v_token,
    'driver', jsonb_build_object('id', p_driver_id, 'name', v_name),
    'expires_at', now() + interval '30 days');
end $fn$;

grant execute on function public.driver_login(text, uuid, text, text) to anon;

-- ── 3. a PIN reset left the driver one slip from another lockout ────────────
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

  update drivers set pin_hash = crypt(p_pin, gen_salt('bf', 10)), locked_until = null
   where id = p_driver_id;

  -- the office deliberately intervened: clear the slate
  delete from driver_login_attempts
   where driver_id = p_driver_id and not succeeded
     and attempted_at > now() - interval '24 hours';

  update driver_sessions set revoked_at = now()
   where driver_id = p_driver_id and revoked_at is null;
end $fn$;

grant execute on function public.admin_set_driver_pin(uuid, text) to authenticated;

-- ── 4. removing a stop the same day it was added just errored ───────────────
-- active_to was set to yesterday, earlier than an active_from of today, so
-- route_stops_dates_ck rejected it.
create or replace function public.admin_remove_route_stop(p_route_stop_id uuid)
returns text
language plpgsql security definer set search_path = public, pg_temp as $fn$
declare v_biz uuid; v_from date; v_used boolean;
begin
  select business_id, active_from into v_biz, v_from
    from public.route_stops where id = p_route_stop_id;
  if v_biz is null then
    raise exception 'That stop is already gone.' using errcode = 'P0001';
  end if;
  if not public.is_admin(v_biz) then
    raise exception 'not authorised' using errcode = '42501';
  end if;

  select exists (select 1 from public.run_stops where route_stop_id = p_route_stop_id)
    into v_used;

  if not v_used then                       -- never driven: nothing to preserve
    delete from public.route_stops where id = p_route_stop_id;
    return 'deleted';
  end if;

  update public.route_stops                -- driven: keep the history
     set active_to = greatest(v_from, (current_date - 1))
   where id = p_route_stop_id;
  return 'ended';
end $fn$;

revoke execute on function public.admin_remove_route_stop(uuid) from anon, public;
grant  execute on function public.admin_remove_route_stop(uuid) to authenticated;

-- ── 5. a fortnightly stop moved to another weekday vanished forever ─────────
-- Generation tests (service_date - anchor_date) % 14 = 0. If the anchor sits on
-- a different weekday to the stop that is NEVER true, so the customer silently
-- stops appearing — nothing errors, nobody notices until they ring.
-- Dragging a fortnightly stop between columns caused exactly this.
create or replace function public.snap_fortnightly_anchor()
returns trigger language plpgsql as $fn$
declare v_base date;
begin
  if new.frequency <> 'fortnightly' then return new; end if;
  v_base := coalesce(new.anchor_date, new.active_from, current_date);
  if extract(isodow from v_base)::smallint <> new.weekday then
    v_base := v_base + ((new.weekday - extract(isodow from v_base)::int + 7) % 7);
  end if;
  new.anchor_date := v_base;
  return new;
end $fn$;

drop trigger if exists route_stops_snap_anchor on public.route_stops;
create trigger route_stops_snap_anchor
  before insert or update on public.route_stops
  for each row execute function public.snap_fortnightly_anchor();

update public.route_stops set anchor_date = anchor_date
 where frequency = 'fortnightly'
   and (anchor_date is null
        or extract(isodow from anchor_date)::smallint <> weekday);
