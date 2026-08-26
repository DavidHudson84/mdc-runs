-- ==========================================================================
-- 0015 - put Kemu's Thursday back in its real order
--
-- Hand-written, not generated. It repairs two things the 0014 import exposed.
--
-- 1. Kemu's whole Thursday pattern had been retired on 2026-08-24: every one
--    of those 13 rows carries active_to = 2026-08-24, the same day it was
--    created. Nothing generated after that date was picking them up. Because
--    they were no longer in force, 0014's "skip customers already on this run
--    and day" guard correctly saw an empty Thursday and laid the master
--    sheet's Thursday customers down alphabetically - losing his running
--    order, both Albert Park visits, Rent My Dress, the Butler store and the
--    start and finish markers.
--
--    This restores the order off his own sheet, puts the four missing stops
--    back, and re-hangs the markers. The master sheet's extra Thursday
--    customers keep their places behind the known-good run. The retired rows
--    are left exactly as they are - days already generated from them keep
--    their history.
--
-- 2. Generating a Thursday to test 0014 added the new template stops to the
--    Van day for 2026-08-27, which was already part driven. Those duplicates
--    are marked skipped with a reason, never deleted, per the standing rule
--    on template-sourced stops.
-- ==========================================================================

-- -- 1a. the stops the master sheet could not know about --------------------
insert into public.route_stops (business_id, route_id, customer_id, kind, tickable,
       weekday, visit_no, seq, scheduled_time, frequency)
select 'b7d18d8b-aa7c-4dd8-a37a-4ced75748239',
       '353c2c0e-4dd6-4fbd-bbc4-7c797bf625c6', c.id, 'customer', true,
       4, v.visit_no, v.seq, v.at::time, 'weekly'
  from (values
  ('C-004', 1,  40, null),      -- Albert Park store, first call
  ('C-008', 1,  80, null),      -- Rent My Dress
  ('C-010', 1, 100, '14:30'),   -- Butler store
  ('C-004', 2, 110, '16:30')    -- Albert Park store, back again at 4.30
       ) as v(ref, visit_no, seq, at)
  join public.customers c
    on c.business_id = 'b7d18d8b-aa7c-4dd8-a37a-4ced75748239' and c.external_ref = v.ref
 where not exists (
   select 1 from public.route_stops x
    where x.route_id = '353c2c0e-4dd6-4fbd-bbc4-7c797bf625c6' and x.weekday = 4
      and x.customer_id = c.id and x.visit_no = v.visit_no and x.active_to is null);

-- -- 1b. the start and finish markers ---------------------------------------
insert into public.route_stops (business_id, route_id, customer_id, kind, label,
       tickable, weekday, visit_no, seq, scheduled_time, frequency)
select 'b7d18d8b-aa7c-4dd8-a37a-4ced75748239',
       '353c2c0e-4dd6-4fbd-bbc4-7c797bf625c6', null, v.kind, v.label,
       v.tickable, 4, 1, v.seq, v.at::time, 'weekly'
  from (values
  ('depot',  'Leave the plant',            true,    5, '10:30'),
  ('target', 'Back at the plant by 5.30',  false, 900, '17:30')
       ) as v(kind, label, tickable, seq, at)
 where not exists (
   select 1 from public.route_stops x
    where x.route_id = '353c2c0e-4dd6-4fbd-bbc4-7c797bf625c6' and x.weekday = 4
      and x.kind = v.kind and x.active_to is null);

-- -- 1c. Kemu's order, off his own sheet -------------------------------------
-- His eleven stops first, in the order he drives them, then the six the
-- master sheet adds to a Thursday, alphabetically, behind them.
update public.route_stops rs set seq = v.seq
  from (values
  ('C-001',       10),   -- Western Imaging for Women
  ('C-002',       20),   -- Butchers Yarraville
  ('C-003',       30),   -- John Holland East
  ('C-005',       50),   -- Williamstown Butcher
  ('C-006',       60),   -- Seaview Events
  ('C-007',       70),   -- Cupcake Queen, fortnightly
  ('C-009',       90),   -- Greek Church
  ('NOV23-030',  120),   -- John Holland West
  ('NOV23-040',  130),   -- Morning Star Hotel
  ('NOV23-041',  140),   -- My Mama Said
  ('NOV23-053',  150),   -- Scienceworks
  ('NOV23-062',  160),   -- Tasty Chips
  ('NOV23-072',  170)    -- VRC
       ) as v(ref, seq)
  join public.customers c
    on c.business_id = 'b7d18d8b-aa7c-4dd8-a37a-4ced75748239' and c.external_ref = v.ref
 where rs.route_id = '353c2c0e-4dd6-4fbd-bbc4-7c797bf625c6'
   and rs.weekday = 4 and rs.visit_no = 1 and rs.active_to is null
   and rs.customer_id = c.id;

-- -- 2. the duplicates on the part-driven day of 2026-08-27 -----------------
-- Skipped, not deleted: a hard delete lets the next ensure_run_day() put them
-- straight back and send a driver to a stop that was never really there.
update public.run_stops rs
   set status = 'skipped',
       skipped_reason = 'Duplicate - added by the November 2023 sheet import '
                        || 'on top of a day already generated. Not a real second visit.',
       updated_at = now()
  from public.run_days rd
 where rs.run_day_id = rd.id
   and rd.route_id = '353c2c0e-4dd6-4fbd-bbc4-7c797bf625c6'
   and rs.status = 'pending'
   and rs.kind = 'customer'
   and rs.route_stop_id in (
         select id from public.route_stops
          where route_id = '353c2c0e-4dd6-4fbd-bbc4-7c797bf625c6'
            and weekday = 4 and active_from >= '2026-08-26')
   and exists (
         select 1 from public.run_stops other
          where other.run_day_id = rs.run_day_id
            and other.customer_id = rs.customer_id
            and other.id <> rs.id
            and other.seq < rs.seq
            and other.status <> 'skipped');
