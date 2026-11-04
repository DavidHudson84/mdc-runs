-- ═══════════════════════════════════════════════════════════════════════════
-- 0021 — a factory login for the Counts screen
--
-- The plant shares one tablet for the daily counts. A normal staff login would
-- open every customer, run and driver to whoever picks it up, so this adds a
-- fourth access level, 'factory', that reaches the Counts screen and nothing
-- else.
--
-- is_staff() now means owner, admin or staff -- not factory. Every existing
-- policy and function goes through is_staff() or is_admin(), so that one change
-- shuts factory out of everything that was there before. The counts tables and
-- functions switch to can_count(), which includes factory.
--
-- Several people share the factory login, so counts_save and the week buttons
-- take an optional name ("Sam") and stamp the entry as "Factory (Sam)". Who
-- typed a number still shows up.
-- ═══════════════════════════════════════════════════════════════════════════

alter table public.admins  drop constraint if exists admins_role_check;
alter table public.admins  add  constraint admins_role_check
  check (role in ('owner','admin','staff','factory'));
alter table public.invites drop constraint if exists invites_role_check;
alter table public.invites add  constraint invites_role_check
  check (role in ('owner','admin','staff','factory'));

create or replace function public.is_staff(p_business_id uuid default null)
returns boolean language sql stable security definer set search_path = public, pg_temp as $$
  select exists (
    select 1 from public.admins a
     where a.user_id = auth.uid()
       and a.role in ('owner','admin','staff')
       and (p_business_id is null or a.business_id = p_business_id));
$$;

create or replace function public.can_count(p_business_id uuid default null)
returns boolean language sql stable security definer set search_path = public, pg_temp as $$
  select exists (
    select 1 from public.admins a
     where a.user_id = auth.uid()
       and (p_business_id is null or a.business_id = p_business_id));
$$;

revoke execute on function public.can_count(uuid) from anon, public;
grant execute on function public.can_count(uuid) to authenticated;

drop policy if exists count_accounts_staff_read on public.count_accounts;
create policy count_accounts_staff_read on public.count_accounts
  for select using (public.can_count(business_id));
drop policy if exists count_items_staff_read on public.count_items;
create policy count_items_staff_read on public.count_items
  for select using (public.can_count(business_id));
drop policy if exists count_entries_staff_read on public.count_entries;
create policy count_entries_staff_read on public.count_entries
  for select using (public.can_count(business_id));
drop policy if exists count_weeks_staff_read on public.count_weeks;
create policy count_weeks_staff_read on public.count_weeks
  for select using (public.can_count(business_id));

-- The person behind a shared login. Staff and admins sign in as themselves, so
-- the name box only matters on the factory login.
create or replace function public._count_staff_name(p_by text default null)
returns text language sql stable security definer set search_path = public, pg_temp as $$
  select coalesce(a.full_name, u.email)
         || case when nullif(trim(p_by), '') is not null and a.role = 'factory'
                 then ' (' || left(trim(p_by), 40) || ')' else '' end
    from public.admins a join auth.users u on u.id = a.user_id
   where a.user_id = auth.uid() limit 1;
$$;
revoke execute on function public._count_staff_name(text) from anon, authenticated, public;
drop function if exists public._count_staff_name();

drop function if exists public.counts_save(uuid, date, int);
create or replace function public.counts_save(
  p_item_id uuid, p_date date, p_qty int, p_by text default null
) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $fn$
declare
  v_biz   uuid;
  v_tz    text;
  v_today date;
  v_week  public.count_weeks%rowtype;
begin
  select i.business_id into v_biz
    from count_items i join count_accounts a on a.id = i.account_id
   where i.id = p_item_id and i.is_active and a.is_active;
  if v_biz is null then raise exception 'That item is not on the count sheet.'; end if;
  if not public.can_count(v_biz) then raise exception 'Not allowed.'; end if;

  select timezone into v_tz from businesses where id = v_biz;
  v_today := (now() at time zone v_tz)::date;   -- rule 4
  if p_date > v_today then raise exception 'That day has not happened yet.'; end if;
  if p_date < v_today - 120 then raise exception 'That day is too far back to change here.'; end if;

  select * into v_week from count_weeks
   where business_id = v_biz and week_start = _count_monday(p_date);
  if v_week.collected_at is not null then
    raise exception 'That week has already gone to accounts. Ask them to change the invoice.';
  end if;
  if v_week.finished_at is not null then
    raise exception 'That week is marked finished. Reopen it first.';
  end if;

  if p_qty is null then
    delete from count_entries where business_id = v_biz and item_id = p_item_id and count_date = p_date;
  else
    insert into count_entries (business_id, item_id, count_date, qty, entered_by, entered_name)
    values (v_biz, p_item_id, p_date, p_qty, auth.uid(), _count_staff_name(p_by))
    on conflict (business_id, item_id, count_date) do update
      set qty = excluded.qty, entered_by = excluded.entered_by,
          entered_name = excluded.entered_name, updated_at = now();
  end if;
  return jsonb_build_object('ok', true, 'qty', p_qty);
end $fn$;

drop function if exists public.counts_finish_week(text, date);
create or replace function public.counts_finish_week(
  p_business_slug text, p_week_start date, p_by text default null
) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $fn$
declare
  v_biz uuid; v_tz text; v_today date; v_mon date := _count_monday(p_week_start);
begin
  select id, timezone into v_biz, v_tz from businesses where slug = p_business_slug and is_active;
  if v_biz is null or not public.can_count(v_biz) then raise exception 'Not allowed.'; end if;
  v_today := (now() at time zone v_tz)::date;
  if v_today < v_mon + 4 then raise exception 'That week is not over yet.'; end if;

  insert into count_weeks (business_id, week_start, finished_at, finished_by, finished_name)
  values (v_biz, v_mon, now(), auth.uid(), _count_staff_name(p_by))
  on conflict (business_id, week_start) do update
    set finished_at = coalesce(count_weeks.finished_at, now()),
        finished_by = coalesce(count_weeks.finished_by, excluded.finished_by),
        finished_name = coalesce(count_weeks.finished_name, excluded.finished_name);
  return jsonb_build_object('ok', true, 'week_start', v_mon);
end $fn$;

create or replace function public.counts_reopen_week(
  p_business_slug text, p_week_start date
) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $fn$
declare v_biz uuid; v_week public.count_weeks%rowtype;
begin
  select id into v_biz from businesses where slug = p_business_slug and is_active;
  if v_biz is null or not public.can_count(v_biz) then raise exception 'Not allowed.'; end if;
  select * into v_week from count_weeks
   where business_id = v_biz and week_start = _count_monday(p_week_start);
  if v_week.collected_at is not null then
    raise exception 'That week has already gone to accounts. Ask them to change the invoice.';
  end if;
  update count_weeks set finished_at = null, finished_by = null, finished_name = null
   where id = v_week.id;
  return jsonb_build_object('ok', true);
end $fn$;

revoke execute on function public.counts_save(uuid, date, int, text),
  public.counts_finish_week(text, date, text) from anon, public;
grant execute on function public.counts_save(uuid, date, int, text),
  public.counts_finish_week(text, date, text) to authenticated;

-- Owners can hand out the new level from the people screen too.
create or replace function public.admin_set_role(p_user_id uuid, p_role text)
returns void language plpgsql security definer set search_path = public, pg_temp as $function$
declare v_biz uuid;
begin
  select id into v_biz from public.businesses where slug = 'mdc';
  if not exists (select 1 from public.admins a
                  where a.user_id = auth.uid() and a.business_id = v_biz
                    and a.role = 'owner') then
    raise exception 'Only an owner can change access levels.' using errcode = '42501';
  end if;
  if p_role not in ('owner','admin','staff','factory') then
    raise exception 'Unknown access level.' using errcode = 'P0001';
  end if;
  if p_user_id = auth.uid() then
    raise exception 'You cannot change your own access level.' using errcode = 'P0001';
  end if;
  update public.admins set role = p_role where user_id = p_user_id and business_id = v_biz;
end $function$;

-- The invite itself. The address only has to be typed at sign-up; nothing is
-- ever mailed to it.
insert into public.invites (business_id, email, role, full_name)
select id, 'factory@hudsongroup.com.au', 'factory', 'Factory' from public.businesses where slug = 'mdc'
on conflict do nothing;
