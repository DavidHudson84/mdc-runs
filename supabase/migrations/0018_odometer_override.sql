-- ═══════════════════════════════════════════════════════════════════════════
-- 0018 — the driver can override the odometer check
--
-- The pre-start check refused any reading below the last one on file, or more
-- than 1500km above it, and there was no way past it. That is correct nine
-- times in ten -- a fat-fingered extra digit poisons the service-due sum for
-- good -- but the tenth time the driver is standing at the van looking at the
-- real number and cannot start the run. It happens whenever a van is swapped
-- between drivers, and whenever an earlier reading went in wrong and every
-- reading since has been "below the last one".
--
-- So the check now asks instead of refusing. An out-of-range reading comes
-- back as SQLSTATE P0002 -- a distinct code, so the phone can tell "that looks
-- wrong, are you sure?" from a real error -- and the app shows what they typed
-- next to what is on file. If they confirm, the reading is taken, the van's
-- odometer is updated to it, and the log records that it was overridden and
-- what the previous figure was.
--
-- Nothing is silently accepted: an override lands on the daily report under
-- "needs someone to do something", with both numbers, so the office sees it
-- that evening.
--
-- The one thing still refused outright is a reading outside 0 to 2,000,000 km,
-- which is not a van, it is a typo.
-- ═══════════════════════════════════════════════════════════════════════════

alter table public.vehicle_logs
  add column if not exists odometer_overridden boolean not null default false,
  add column if not exists odometer_prev       int;

comment on column public.vehicle_logs.odometer_overridden is
  'The driver confirmed a reading the sanity check would otherwise have refused.';
comment on column public.vehicle_logs.odometer_prev is
  'What the van odometer said before this override, kept so the office can see both numbers.';

-- ── the pre-start check ────────────────────────────────────────────────────
-- Dropped and recreated rather than replaced: the new p_override argument
-- changes the signature, and leaving the old six-argument version in place
-- would give PostgREST two functions of the same name to choose between.

drop function if exists public.driver_start_vehicle_log(text, uuid, integer, jsonb, boolean, text);

create or replace function public.driver_start_vehicle_log(
  p_token text, p_vehicle_id uuid, p_odometer int, p_answers jsonb default '[]'::jsonb,
  p_skipped boolean default false, p_skip_reason text default null,
  p_override boolean default false)
returns jsonb language plpgsql security definer set search_path = public, pg_temp as $fn$
declare
  v_driver uuid; v_biz uuid; v_date date; v_prev int; v_failed boolean; v_id uuid;
  v_odd boolean := false;          -- the reading does not follow on from the last one
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
    if p_odometer is null then
      raise exception 'Enter the odometer reading.' using errcode = 'P0001';
    end if;

    -- Not a van. No confirmation gets past this one.
    if p_odometer < 0 or p_odometer > 2000000 then
      raise exception 'That reading (%) is not a real odometer. Check and re-enter.',
        p_odometer using errcode = 'P0001';
    end if;

    v_odd := v_prev is not null
             and (p_odometer < v_prev or p_odometer > v_prev + 1500);

    -- P0002, not P0001: the phone offers to confirm this one rather than
    -- treating it as a dead end.
    if v_odd and not p_override then
      if p_odometer < v_prev then
        raise exception 'That reading (%) is below the last one (%).',
          p_odometer, v_prev using errcode = 'P0002';
      else
        raise exception 'That reading (%) is more than 1500km above the last one (%).',
          p_odometer, v_prev using errcode = 'P0002';
      end if;
    end if;

    -- anything answered "no" demands a note, or the check is theatre
    if exists (select 1 from jsonb_array_elements(p_answers) a
                where (a->>'ok')::boolean is false
                  and coalesce(btrim(a->>'note'), '') = '') then
      raise exception 'Add a note for anything that is not right.' using errcode = 'P0001';
    end if;
  end if;

  v_failed := exists (select 1 from jsonb_array_elements(p_answers) a
                       where (a->>'ok')::boolean is false);

  insert into public.vehicle_logs (business_id, vehicle_id, driver_id, service_date,
    odometer_start, answers, failed, skipped, skip_reason,
    odometer_overridden, odometer_prev)
  values (v_biz, p_vehicle_id, v_driver, v_date,
          case when p_skipped then null else p_odometer end,
          coalesce(p_answers, '[]'::jsonb), v_failed, p_skipped, p_skip_reason,
          not p_skipped and v_odd,
          case when not p_skipped and v_odd then v_prev end)
  returning id into v_id;

  -- The driver is the one standing at the van. Once they have confirmed the
  -- number, it is the number -- including when it is lower than what was on
  -- file, which is what a van swap or a corrected typo looks like.
  if not p_skipped then
    update public.vehicles set odometer = p_odometer, odometer_at = now() where id = p_vehicle_id;
  end if;

  update public.run_days set vehicle_log_id = v_id
   where service_date = v_date
     and (driver_id = v_driver
          or exists (select 1 from public.run_stops rs
                      where rs.run_day_id = run_days.id and rs.assigned_driver_id = v_driver));

  return jsonb_build_object('id', v_id, 'service_date', v_date, 'failed', v_failed,
                            'odometer_overridden', not p_skipped and v_odd);
end $fn$;

comment on function public.driver_start_vehicle_log(text, uuid, int, jsonb, boolean, text, boolean) is
  'The once-a-day van check. An odometer that does not follow on from the last one raises SQLSTATE P0002 so the app can offer to confirm it; p_override => true takes it and records the override.';

revoke execute on function public.driver_start_vehicle_log(text, uuid, int, jsonb, boolean, text, boolean)
  from public;
grant execute on function public.driver_start_vehicle_log(text, uuid, int, jsonb, boolean, text, boolean)
  to anon;

-- ── the daily report, carrying the override through ────────────────────────
-- Same function as 0016 with two additions: the van list says when a reading
-- was overridden and what it was before, and an override raises a line in
-- "needs someone to do something". 0016 is left alone, per the rule that an
-- applied migration is never edited.

create or replace function public.daily_report(
  p_business_slug text default 'mdc',
  p_date          date default null
) returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_biz      uuid;
  v_name     text;
  v_tz       text;
  v_date     date;
  v_role     text;
  v_week     date;
  v_out      jsonb;
begin
  select id, name, timezone into v_biz, v_name, v_tz
    from businesses where slug = p_business_slug and is_active;
  if v_biz is null then
    raise exception 'No such business: %', p_business_slug;
  end if;

  -- Rule 4: today is a Melbourne date, never the server's UTC one.
  v_date := coalesce(p_date, (now() at time zone v_tz)::date);
  v_week := v_date - ((extract(isodow from v_date)::int) - 1);

  -- The office reads it signed in; the scheduled emailer reads it with the
  -- service key. Nothing else gets in -- anon holds no grant on this function.
  v_role := coalesce(current_setting('request.jwt.claims', true)::jsonb ->> 'role', current_user);
  if v_role not in ('service_role', 'postgres') and not is_admin(v_biz) then
    raise exception 'Not allowed';
  end if;

  with
  -- Every run generated for the day, with its driver and the van they signed
  -- out. Cancelled runs stay in, flagged, so a public holiday reads as a
  -- decision rather than as a day everyone forgot to work.
  rd as (
    select r.id, r.status, r.started_at, r.completed_at, r.cancel_reason, r.notes,
           r.driver_id,
           rt.name as run_name, rt.sort_order, rt.start_time,
           d.display_name as driver,
           vl.odometer_start, vl.odometer_end, vl.failed as check_failed,
           vl.skipped as check_skipped, vl.skip_reason, vl.answers,
           v.label as van, v.rego
      from run_days r
      join routes rt on rt.id = r.route_id
      left join drivers d on d.id = r.driver_id
      left join vehicle_logs vl on vl.id = r.vehicle_log_id
      left join vehicles v on v.id = vl.vehicle_id
     where r.business_id = v_biz and r.service_date = v_date
  ),
  -- Markers (depot, break, target, note) are not work, so they never count
  -- towards done or missed. tickable = false is the whole test.
  st as (
    select s.*, rd.run_name, rd.sort_order, rd.driver, rd.status as run_status,
           coalesce(ad.display_name, rd.driver) as worked_by
      from run_stops s
      join rd on rd.id = s.run_day_id
      left join drivers ad on ad.id = s.assigned_driver_id
     where s.tickable
  ),
  tot as (
    select count(*)                                     as stops,
           count(*) filter (where status = 'done')       as done,
           count(*) filter (where status = 'issue')      as issue,
           count(*) filter (where status = 'pending')    as pending,
           count(*) filter (where status = 'skipped')    as skipped,
           count(*) filter (where origin = 'adhoc')      as adhoc,
           count(*) filter (where loaded_at is not null) as loaded
      from st
  )
  select jsonb_build_object(
    'business',     v_name,
    'date',         v_date,
    'weekday',      trim(to_char(v_date, 'Day')),
    'date_long',    trim(to_char(v_date, 'Day')) || ', ' || to_char(v_date, 'DD FMMonth YYYY'),
    'generated_at', to_char(now() at time zone v_tz, 'HH12:MIam'),

    'totals', (select jsonb_build_object(
        'stops', stops, 'done', done, 'issue', issue, 'pending', pending,
        'skipped', skipped, 'adhoc', adhoc, 'loaded', loaded,
        'completion', case when done + issue + pending > 0
                      then round(done::numeric * 100 / (done + issue + pending)) end)
      from tot),

    -- ── run by run ───────────────────────────────────────────────────────
    'runs', coalesce((select jsonb_agg(x order by x->>'sort', x->>'run') from (
        select jsonb_build_object(
          'run',       rd.run_name,
          'sort',      lpad(coalesce(rd.sort_order, 99)::text, 3, '0'),
          'driver',    coalesce(rd.driver, 'Nobody assigned'),
          'van',       rd.van, 'rego', rd.rego,
          'status',    rd.status,
          'cancel_reason', rd.cancel_reason,
          'started',   to_char(rd.started_at   at time zone v_tz, 'HH12:MIam'),
          'finished',  to_char(rd.completed_at at time zone v_tz, 'HH12:MIam'),
          'km',        case when rd.odometer_end is not null and rd.odometer_start is not null
                            then rd.odometer_end - rd.odometer_start end,
          'done',      count(s.*) filter (where s.status = 'done'),
          'issue',     count(s.*) filter (where s.status = 'issue'),
          'pending',   count(s.*) filter (where s.status = 'pending'),
          'skipped',   count(s.*) filter (where s.status = 'skipped'),
          'stops',     count(s.*),
          'last_tick', to_char(max(s.marked_at) at time zone v_tz, 'HH12:MIam')
        ) as x
        from rd left join st s on s.run_day_id = rd.id
        group by rd.id, rd.run_name, rd.sort_order, rd.driver, rd.van, rd.rego,
                 rd.status, rd.cancel_reason, rd.started_at, rd.completed_at,
                 rd.odometer_start, rd.odometer_end
      ) q), '[]'::jsonb),

    -- ── what nobody got to ───────────────────────────────────────────────
    -- Still pending at the end of the day on a run that was not cancelled.
    -- This is the section the report exists for.
    'missed', coalesce((select jsonb_agg(jsonb_build_object(
          'customer', coalesce(s.customer_name, c.name, s.label),
          'suburb',   coalesce(s.suburb, c.suburb),
          'phone',    coalesce(s.phone, c.phone),
          'run',      s.run_name,
          'driver',   coalesce(s.worked_by, 'Nobody assigned'),
          'time',     to_char(s.scheduled_time, 'HH12:MIam'),
          'adhoc',    s.origin = 'adhoc')
        order by s.sort_order, s.seq)
      from st s left join customers c on c.id = s.customer_id
     where s.status = 'pending' and s.run_status <> 'cancelled'), '[]'::jsonb),

    -- ── problems the driver reported ─────────────────────────────────────
    'issues', coalesce((select jsonb_agg(jsonb_build_object(
          'customer', coalesce(s.customer_name, c.name, s.label),
          'suburb',   coalesce(s.suburb, c.suburb),
          'phone',    coalesce(s.phone, c.phone),
          'run',      s.run_name,
          'driver',   coalesce(s.worked_by, ''),
          'reason',   s.issue_reason,
          'note',     s.issue_note,
          'at',       to_char(s.marked_at at time zone v_tz, 'HH12:MIam'))
        order by s.marked_at)
      from st s left join customers c on c.id = s.customer_id
     where s.status = 'issue'), '[]'::jsonb),

    -- ── stops the office pulled off the run ──────────────────────────────
    'removed', coalesce((select jsonb_agg(jsonb_build_object(
          'customer', coalesce(s.customer_name, c.name, s.label),
          'run',      s.run_name,
          'reason',   s.skipped_reason)
        order by s.sort_order, s.seq)
      from st s left join customers c on c.id = s.customer_id
     where s.status = 'skipped'), '[]'::jsonb),

    -- ── messages ─────────────────────────────────────────────────────────
    -- In-app only. An unread one has not reached anybody, which is the whole
    -- reason it is in the report.
    'messages', coalesce((select jsonb_agg(jsonb_build_object(
          'to',      coalesce(d.display_name, 'Everyone'),
          'body',    m.body,
          'sent',    to_char(m.created_at at time zone v_tz, 'HH12:MIam'),
          'sent_by', a.full_name,
          'read',    to_char(rr.read_at at time zone v_tz, 'HH12:MIam'),
          'reply',   rr.reply)
        order by m.created_at)
      from driver_messages m
      left join drivers d on d.id = m.driver_id
      left join admins a on a.user_id = m.created_by
      left join driver_message_reads rr on rr.message_id = m.id
     where m.business_id = v_biz
       and (m.created_at at time zone v_tz)::date = v_date), '[]'::jsonb),

    -- ── vans ─────────────────────────────────────────────────────────────
    'van_checks', coalesce((select jsonb_agg(jsonb_build_object(
          'driver',   d.display_name,
          'van',      v.label, 'rego', v.rego,
          'odometer', vl.odometer_start,
          'odometer_overridden', vl.odometer_overridden,
          'odometer_prev', vl.odometer_prev,
          'km',       case when vl.odometer_end is not null and vl.odometer_start is not null
                           then vl.odometer_end - vl.odometer_start end,
          'skipped',  vl.skipped,
          'skip_reason', vl.skip_reason,
          'failed',   vl.failed,
          'faults',   (select string_agg(trim(both from (a->>'label') ||
                              coalesce(' - ' || (a->>'note'), '')), '; ')
                         from jsonb_array_elements(coalesce(vl.answers, '[]'::jsonb)) a
                        where (a->>'ok') = 'false'))
        order by d.display_name)
      from vehicle_logs vl
      left join drivers d on d.id = vl.driver_id
      left join vehicles v on v.id = vl.vehicle_id
     where vl.business_id = v_biz and vl.service_date = v_date), '[]'::jsonb),

    -- ── things somebody has to do ────────────────────────────────────────
    'attention', coalesce((select jsonb_agg(t order by ord, t) from (
        -- a run that was never opened
        select 1 as ord, rd.run_name || ' - ' || coalesce(rd.driver, 'nobody') ||
               ' never opened the app today' as t
          from rd where rd.status = 'planned'
           and exists (select 1 from st s where s.run_day_id = rd.id)
        union all
        -- out all day and never pressed Finish
        select 2, rd.run_name || ' - ' || coalesce(rd.driver, 'the driver') ||
               ' started at ' || to_char(rd.started_at at time zone v_tz, 'HH12:MIam') ||
               ' and never finished the run'
          from rd where rd.status = 'in_progress' and rd.started_at is not null
        union all
        -- weekly van check still not done, for somebody who worked this week
        select 3, d.display_name || ' has not done the weekly van check'
          from drivers d
         where d.business_id = v_biz and d.is_active
           and exists (select 1 from rd where rd.driver_id = d.id and rd.status <> 'cancelled')
           and not exists (select 1 from vehicle_logs vl
                            where vl.driver_id = d.id and not vl.skipped
                              and jsonb_array_length(coalesce(vl.answers, '[]'::jsonb)) > 0
                              and vl.service_date between v_week and v_date)
        union all
        -- pre-start check failed or was skipped
        select 4, coalesce(v.label, 'A van') || ' failed the pre-start check (' ||
               coalesce(d.display_name, '?') || ')'
          from vehicle_logs vl
          left join vehicles v on v.id = vl.vehicle_id
          left join drivers d on d.id = vl.driver_id
         where vl.business_id = v_biz and vl.service_date = v_date and vl.failed
        union all
        select 4, coalesce(d.display_name, 'A driver') || ' skipped the pre-start check' ||
               coalesce(' - ' || vl.skip_reason, '')
          from vehicle_logs vl left join drivers d on d.id = vl.driver_id
         where vl.business_id = v_biz and vl.service_date = v_date and vl.skipped
        union all
        -- an odometer the driver confirmed past the sanity check. Usually a van
        -- swap or an earlier typo being corrected, occasionally a fresh typo --
        -- either way somebody should glance at it, because service due dates
        -- are worked out from this number.
        select 4, coalesce(v.label, 'A van') || ' odometer entered as ' ||
               to_char(vl.odometer_start, 'FM999,999,999') || ' km by ' ||
               coalesce(d.display_name, 'the driver') || ', last reading was ' ||
               to_char(vl.odometer_prev, 'FM999,999,999') || ' km'
          from vehicle_logs vl
          left join vehicles v on v.id = vl.vehicle_id
          left join drivers d on d.id = vl.driver_id
         where vl.business_id = v_biz and vl.service_date = v_date
           and vl.odometer_overridden and vl.odometer_prev is not null
        union all
        -- a message nobody has opened
        select 5, 'Message to ' || coalesce(d.display_name, 'everyone') ||
               ' still unread: ' || m.body
          from driver_messages m
          left join drivers d on d.id = m.driver_id
         where m.business_id = v_biz
           and (m.created_at at time zone v_tz)::date = v_date
           and not exists (select 1 from driver_message_reads r where r.message_id = m.id)
        union all
        -- locked out of their own phone
        select 6, d.display_name || ' is locked out until ' ||
               to_char(d.locked_until at time zone v_tz, 'HH12:MIam') || ' (five wrong PINs)'
          from drivers d
         where d.business_id = v_biz and d.locked_until > now()
        union all
        -- servicing and rego, same thresholds as the Today board
        select 7, v.label || ' (' || v.rego || ') - service ' ||
               case when v.service_due_km - v.odometer < 0
                    then abs(v.service_due_km - v.odometer)::text || ' km overdue'
                    else 'due in ' || (v.service_due_km - v.odometer)::text || ' km' end
          from vehicles v
         where v.business_id = v_biz and v.is_active
           and v.service_due_km is not null and v.odometer is not null
           and v.service_due_km - v.odometer <= 500
        union all
        select 7, v.label || ' (' || v.rego || ') - service due ' ||
               case when v.service_due_date < v_date
                    then (v_date - v.service_due_date)::text || ' days ago'
                    else 'in ' || (v.service_due_date - v_date)::text || ' days' end
          from vehicles v
         where v.business_id = v_biz and v.is_active
           and v.service_due_date is not null and v.service_due_date - v_date <= 14
        union all
        select 8, v.label || ' (' || v.rego || ') - rego ' ||
               case when v.rego_expiry < v_date then 'EXPIRED'
                    else 'expires in ' || (v.rego_expiry - v_date)::text || ' days' end
          from vehicles v
         where v.business_id = v_biz and v.is_active
           and v.rego_expiry is not null and v.rego_expiry - v_date <= 30
      ) q), '[]'::jsonb),

    'recipients', coalesce((select jsonb_agg(jsonb_build_object(
          'email', email, 'name', full_name) order by created_at)
      from report_recipients where business_id = v_biz and is_active), '[]'::jsonb)
  ) into v_out;

  return v_out;
end;
$$;

comment on function public.daily_report(text, date) is
  'Everything that happened on one service date, as jsonb. Read-only. Used by the office daily report screen and by the scheduled email. Melbourne dates.';

revoke execute on function public.daily_report(text, date) from anon, public;
grant  execute on function public.daily_report(text, date) to authenticated, service_role;
