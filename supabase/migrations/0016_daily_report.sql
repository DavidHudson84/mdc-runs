-- ═══════════════════════════════════════════════════════════════════════════
-- 0016 — the daily report
--
-- One function, daily_report(), that answers "how did today go?" in a single
-- jsonb blob: what went out, what came back ticked, what nobody got to, every
-- issue with its note, every message the office sent and whether the driver
-- read it, the van checks, and a short list of things somebody has to do
-- something about.
--
-- It is the ONLY place the day is summarised. The office screen
-- (/admin/daily.html) and the emailer (.github/workflows/daily-report.yml)
-- both call this, so the email and the screen can never drift apart.
--
-- Read-only. It makes no decisions and changes no rows -- deliberately, so it
-- is safe to call from a scheduled job with nobody watching.
-- ═══════════════════════════════════════════════════════════════════════════

-- ── who gets the email ─────────────────────────────────────────────────────
-- Adding somebody is one insert. There is no screen for it, the same as
-- invites. Set is_active = false rather than deleting, so it is obvious later
-- that somebody used to be on the list.

create table if not exists public.report_recipients (
  id           uuid primary key default gen_random_uuid(),
  business_id  uuid not null references public.businesses(id) on delete cascade,
  email        text not null,
  full_name    text,
  is_active    boolean not null default true,
  created_at   timestamptz not null default now(),
  constraint report_recipients_email_ck check (position('@' in email) > 1)
);

create unique index if not exists report_recipients_biz_email_uk
  on public.report_recipients (business_id, lower(email));

alter table public.report_recipients enable row level security;

drop policy if exists report_recipients_admin_all on public.report_recipients;
create policy report_recipients_admin_all on public.report_recipients
  for all using (public.is_admin(business_id)) with check (public.is_admin(business_id));

revoke all on public.report_recipients from anon;

insert into public.report_recipients (business_id, email, full_name)
select b.id, x.email, x.full_name
  from public.businesses b
  cross join (values
    ('david@hudsongroup.com.au',    'David Hudson'),
    ('annelise@hudsongroup.com.au', 'Annelise')
  ) as x(email, full_name)
 where b.slug = 'mdc'
on conflict do nothing;

-- ── the report ─────────────────────────────────────────────────────────────

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
