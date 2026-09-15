-- ═══════════════════════════════════════════════════════════════════════════
-- 0019 — send the daily report once, whenever it manages to fire
--
-- The report is meant to land at 7pm so the office can sort out tomorrow
-- before they go home. It has been arriving overnight instead. The cause is
-- not the report: GitHub queues scheduled workflows and runs them when it has
-- room, and one fired six and a half hours late. Nothing in a free scheduler
-- can be made punctual.
--
-- So the workflow stops trying once and starts trying often -- six times
-- across the evening, half an hour apart. Whichever attempt actually gets a
-- runner sends the report; the rest find the day already done and stop. That
-- turns a six-hour miss into a thirty-minute one, because all six would have
-- to be delayed together for the report to be late.
--
-- This is the bit that keeps it to one email. A row per day, claimed before
-- the send and stamped after it, so the office is never told about the same
-- day twice.
--
-- A claim that is never stamped -- the runner died, Resend was down -- goes
-- stale after ten minutes and the next attempt picks the day back up. The
-- failure mode is deliberately "try again", not "stay silent".
-- ═══════════════════════════════════════════════════════════════════════════

create table if not exists public.report_sends (
  id           uuid primary key default gen_random_uuid(),
  business_id  uuid not null references public.businesses(id) on delete cascade,
  kind         text not null default 'daily',
  service_date date not null,
  claimed_at   timestamptz not null default now(),
  sent_at      timestamptz,
  attempts     int not null default 1,
  provider_id  text,
  recipients   text[],
  unique (business_id, kind, service_date)
);

comment on table public.report_sends is
  'One row per report actually sent, so several scheduled attempts at the same day produce one email. sent_at null means claimed but not yet delivered.';

alter table public.report_sends enable row level security;

drop policy if exists report_sends_admin_read on public.report_sends;
create policy report_sends_admin_read on public.report_sends
  for select using (public.is_admin(business_id));

revoke all on public.report_sends from anon;

-- ── claiming the day ───────────────────────────────────────────────────────
-- Atomic: the unique key does the work, so two runners that start at the same
-- moment cannot both win. Returns claimed => false if the day is already sent
-- or somebody else is mid-send, and the caller simply stops.

create or replace function public.claim_report_send(
  p_business_slug text,
  p_date          date,
  p_kind          text default 'daily',
  p_stale_after   interval default interval '10 minutes'
) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $fn$
declare v_biz uuid; v_row public.report_sends;
begin
  select id into v_biz from public.businesses where slug = p_business_slug and is_active;
  if v_biz is null then raise exception 'No such business: %', p_business_slug; end if;

  insert into public.report_sends as rs (business_id, kind, service_date)
  values (v_biz, p_kind, p_date)
  on conflict (business_id, kind, service_date) do update
     set claimed_at = now(), attempts = rs.attempts + 1
   where rs.sent_at is null
     and rs.claimed_at < now() - p_stale_after
  returning rs.* into v_row;

  if v_row.id is not null then
    return jsonb_build_object('claimed', true, 'attempts', v_row.attempts);
  end if;

  select * into v_row from public.report_sends
   where business_id = v_biz and kind = p_kind and service_date = p_date;

  return jsonb_build_object(
    'claimed',    false,
    'sent_at',    v_row.sent_at,
    'claimed_at', v_row.claimed_at,
    'attempts',   v_row.attempts,
    'reason',     case when v_row.sent_at is not null
                       then 'already sent' else 'another attempt is mid-send' end);
end $fn$;

comment on function public.claim_report_send(text, date, text, interval) is
  'Take the right to send one day''s report. claimed => true means go ahead; false means another attempt already has it or the email has gone.';

-- ── stamping it sent ───────────────────────────────────────────────────────

create or replace function public.mark_report_sent(
  p_business_slug text,
  p_date          date,
  p_kind          text default 'daily',
  p_provider_id   text default null,
  p_recipients    text[] default null
) returns void
language plpgsql security definer set search_path = public, pg_temp as $fn$
declare v_biz uuid;
begin
  select id into v_biz from public.businesses where slug = p_business_slug and is_active;
  if v_biz is null then raise exception 'No such business: %', p_business_slug; end if;

  update public.report_sends
     set sent_at = now(), provider_id = p_provider_id, recipients = p_recipients
   where business_id = v_biz and kind = p_kind and service_date = p_date;
end $fn$;

comment on function public.mark_report_sent(text, date, text, text, text[]) is
  'Record that the day''s report actually went out. Until this runs the claim goes stale and another attempt will retry.';

-- Only the emailer calls these, and it holds the service key. Nothing signed
-- in as a driver or an office user has any business claiming a send.
revoke execute on function public.claim_report_send(text, date, text, interval) from anon, authenticated, public;
revoke execute on function public.mark_report_sent(text, date, text, text, text[]) from anon, authenticated, public;
grant  execute on function public.claim_report_send(text, date, text, interval) to service_role;
grant  execute on function public.mark_report_sent(text, date, text, text, text[]) to service_role;
