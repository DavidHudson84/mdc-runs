-- ═══════════════════════════════════════════════════════════════════════════
-- 0017 — Annalise, not Annelise
--
-- 0016 seeded the report list with 'annelise@hudsongroup.com.au'. Her actual
-- address, and the one her office login is on, is 'annalise@' -- Anna, not
-- Anne. A daily report to the wrong address is a daily bounce nobody sees, so
-- this is a correction rather than a tidy-up.
--
-- 0016 is left alone, per the rule that an applied migration is never edited.
-- A fresh deploy runs 0016 then this, and lands in the same place.
-- ═══════════════════════════════════════════════════════════════════════════

update public.report_recipients
   set email = 'annalise@hudsongroup.com.au',
       full_name = 'Annalise'
 where lower(email) = 'annelise@hudsongroup.com.au';
