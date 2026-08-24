-- ═══════════════════════════════════════════════════════════════════════════
-- 0004 — index fix, the missing marker, and admin bootstrap
-- ═══════════════════════════════════════════════════════════════════════════

-- The old key coalesced a null customer_id to a fixed uuid, so two markers on
-- the same route+weekday collided and the second was silently dropped.
-- Uniqueness only makes sense for customer stops; a run can carry any number
-- of depot/target/break/note markers.
drop index if exists public.route_stops_uq;
create unique index route_stops_uq on public.route_stops
  (route_id, weekday, customer_id, visit_no, active_from)
  where customer_id is not null;

insert into public.route_stops (business_id, route_id, customer_id, kind, label,
                                tickable, weekday, visit_no, seq, scheduled_time, frequency)
select r.business_id, r.id, null, 'target', 'Back at the plant by 5.30',
       false, 4, 1, 120, '17:30', 'weekly'
  from public.routes r
 where r.name = 'Van'
   and not exists (
     select 1 from public.route_stops rs
      where rs.route_id = r.id and rs.kind = 'target' and rs.weekday = 4);

-- Bootstrapping the first admin without anyone handing round a password.
-- Admin is granted only when an address is CONFIRMED, and only for the
-- hudsongroup.com.au domain. Signing up with a fake @hudsongroup.com.au
-- address gets you nothing, because you can never confirm it.
create or replace function public.grant_admin_on_confirm()
returns trigger language plpgsql security definer set search_path = public, pg_temp as $fn$
declare v_biz uuid;
begin
  if new.email is null or new.email not ilike '%@hudsongroup.com.au' then
    return new;
  end if;
  if new.email_confirmed_at is null then
    return new;
  end if;

  select id into v_biz from public.businesses where slug = 'mdc';
  if v_biz is null then return new; end if;

  insert into public.admins (user_id, business_id, full_name, role)
  values (new.id, v_biz, split_part(new.email, '@', 1), 'owner')
  on conflict (user_id, business_id) do nothing;

  return new;
end $fn$;

drop trigger if exists on_auth_user_confirmed on auth.users;
create trigger on_auth_user_confirmed
  after insert or update of email_confirmed_at on auth.users
  for each row execute function public.grant_admin_on_confirm();
