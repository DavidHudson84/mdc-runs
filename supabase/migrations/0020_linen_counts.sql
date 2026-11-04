-- ═══════════════════════════════════════════════════════════════════════════
-- 0020 — linen and uniform counts
--
-- Some commercial customers are billed on what came through the plant that
-- week: aprons, tablecloths, uniforms by the piece. The count used to be typed
-- straight onto the invoice by whoever remembered, and when nobody did, the
-- invoices sat at $0 for a month.
--
-- Now the office types the day's count in here, item by item, and presses
-- "Week finished" on Monday. That locks the week. Something outside this app
-- reads the finished weeks and does the invoicing -- this app never knows how,
-- and holds no prices. It is a tally sheet and nothing more.
--
--   count_accounts  one per customer (or per site, where one customer has two)
--   count_items     what gets counted for that customer
--   count_entries   one number per item per day
--   count_weeks     a Monday-to-Sunday week, finished or not, collected or not
--
-- Staff write only through the counts_* functions, so the lock on a finished
-- week cannot be stepped around from a browser. Reading is plain RLS.
--
-- The outside reader gets in with a key, not a login. Only sha256 of the key
-- is stored. Same idea as driver sessions.
-- ═══════════════════════════════════════════════════════════════════════════

create table if not exists public.count_accounts (
  id           uuid primary key default gen_random_uuid(),
  business_id  uuid not null references public.businesses(id) on delete cascade,
  slug         text not null,
  name         text not null,
  note         text,
  cadence      text not null default 'weekly'
               check (cadence in ('weekly','fortnightly','monthly')),
  seq          int not null default 0,
  is_active    boolean not null default true,
  created_at   timestamptz not null default now(),
  unique (business_id, slug)
);

create table if not exists public.count_items (
  id           uuid primary key default gen_random_uuid(),
  business_id  uuid not null references public.businesses(id) on delete cascade,
  account_id   uuid not null references public.count_accounts(id) on delete cascade,
  slug         text not null,
  label        text not null,
  seq          int not null default 0,
  is_active    boolean not null default true,
  created_at   timestamptz not null default now(),
  unique (business_id, account_id, slug)
);

create table if not exists public.count_entries (
  id           uuid primary key default gen_random_uuid(),
  business_id  uuid not null references public.businesses(id) on delete cascade,
  item_id      uuid not null references public.count_items(id) on delete cascade,
  count_date   date not null,
  qty          int not null check (qty >= 0 and qty <= 100000),
  entered_by   uuid,
  entered_name text,
  updated_at   timestamptz not null default now(),
  unique (business_id, item_id, count_date)
);

create index if not exists count_entries_date_ix on public.count_entries (business_id, count_date);

-- week_start is always a Monday. finished_at null = still open for typing.
-- collected_at is stamped by the outside reader once it has used the week, and
-- after that nobody can reopen it from here -- the fix goes on the invoice.
create table if not exists public.count_weeks (
  id             uuid primary key default gen_random_uuid(),
  business_id    uuid not null references public.businesses(id) on delete cascade,
  week_start     date not null check (extract(isodow from week_start) = 1),
  finished_at    timestamptz,
  finished_by    uuid,
  finished_name  text,
  collected_at   timestamptz,
  collected_note text,
  unique (business_id, week_start)
);

create table if not exists public.count_export_keys (
  id           uuid primary key default gen_random_uuid(),
  business_id  uuid not null references public.businesses(id) on delete cascade,
  key_hash     bytea not null unique,
  label        text not null,
  is_active    boolean not null default true,
  created_at   timestamptz not null default now()
);

alter table public.count_accounts     enable row level security;
alter table public.count_items        enable row level security;
alter table public.count_entries      enable row level security;
alter table public.count_weeks        enable row level security;
alter table public.count_export_keys  enable row level security;

drop policy if exists count_accounts_staff_read on public.count_accounts;
create policy count_accounts_staff_read on public.count_accounts
  for select using (public.is_staff(business_id));
drop policy if exists count_items_staff_read on public.count_items;
create policy count_items_staff_read on public.count_items
  for select using (public.is_staff(business_id));
drop policy if exists count_entries_staff_read on public.count_entries;
create policy count_entries_staff_read on public.count_entries
  for select using (public.is_staff(business_id));
drop policy if exists count_weeks_staff_read on public.count_weeks;
create policy count_weeks_staff_read on public.count_weeks
  for select using (public.is_staff(business_id));
-- count_export_keys: no policy at all. Nobody reads it but the functions below.

revoke all on public.count_accounts, public.count_items, public.count_entries,
              public.count_weeks, public.count_export_keys from anon;
revoke insert, update, delete on public.count_accounts, public.count_items,
              public.count_entries, public.count_weeks from authenticated;
revoke all on public.count_export_keys from authenticated;

-- ── helpers ────────────────────────────────────────────────────────────────

create or replace function public._count_monday(p_date date)
returns date language sql immutable set search_path = public, pg_temp as $$
  select p_date - (extract(isodow from p_date)::int - 1);
$$;

create or replace function public._count_staff_name()
returns text language sql stable security definer set search_path = public, pg_temp as $$
  select coalesce(a.full_name, u.email)
    from public.admins a join auth.users u on u.id = a.user_id
   where a.user_id = auth.uid() limit 1;
$$;

-- ── staff: save one number ─────────────────────────────────────────────────
-- A blank box is a null and removes the entry. Zero is kept as zero, so
-- "nothing came in" and "nobody counted" stay different things.

create or replace function public.counts_save(
  p_item_id uuid, p_date date, p_qty int
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
  if not public.is_staff(v_biz) then raise exception 'Not allowed.'; end if;

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
    values (v_biz, p_item_id, p_date, p_qty, auth.uid(), _count_staff_name())
    on conflict (business_id, item_id, count_date) do update
      set qty = excluded.qty, entered_by = excluded.entered_by,
          entered_name = excluded.entered_name, updated_at = now();
  end if;
  return jsonb_build_object('ok', true, 'qty', p_qty);
end $fn$;

-- ── staff: finish / reopen a week ──────────────────────────────────────────

create or replace function public.counts_finish_week(
  p_business_slug text, p_week_start date
) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $fn$
declare
  v_biz uuid; v_tz text; v_today date; v_mon date := _count_monday(p_week_start);
begin
  select id, timezone into v_biz, v_tz from businesses where slug = p_business_slug and is_active;
  if v_biz is null or not public.is_staff(v_biz) then raise exception 'Not allowed.'; end if;
  v_today := (now() at time zone v_tz)::date;
  -- Friday at the earliest: the plant is closed at the weekend, so a week
  -- can be closed off on Friday afternoon or any time after.
  if v_today < v_mon + 4 then raise exception 'That week is not over yet.'; end if;

  insert into count_weeks (business_id, week_start, finished_at, finished_by, finished_name)
  values (v_biz, v_mon, now(), auth.uid(), _count_staff_name())
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
  if v_biz is null or not public.is_staff(v_biz) then raise exception 'Not allowed.'; end if;
  select * into v_week from count_weeks
   where business_id = v_biz and week_start = _count_monday(p_week_start);
  if v_week.collected_at is not null then
    raise exception 'That week has already gone to accounts. Ask them to change the invoice.';
  end if;
  update count_weeks set finished_at = null, finished_by = null, finished_name = null
   where id = v_week.id;
  return jsonb_build_object('ok', true);
end $fn$;

-- ── the outside reader ─────────────────────────────────────────────────────

create or replace function public._count_key_business(p_key text)
returns uuid language sql stable security definer set search_path = public, pg_temp as $$
  select business_id from public.count_export_keys
   where key_hash = extensions.digest(p_key, 'sha256') and is_active;
$$;

-- Everything between two dates: the sheet (accounts and items), every count,
-- and the state of every week the range touches.
create or replace function public.counts_export(
  p_key text, p_from date, p_to date
) returns jsonb
language plpgsql stable security definer set search_path = public, pg_temp as $fn$
declare v_biz uuid := _count_key_business(p_key);
begin
  if v_biz is null then raise exception 'Not allowed.'; end if;
  if p_to < p_from or p_to - p_from > 400 then raise exception 'Bad date range.'; end if;
  return jsonb_build_object(
    'from', p_from, 'to', p_to,
    'accounts', coalesce((select jsonb_agg(jsonb_build_object(
        'slug', a.slug, 'name', a.name, 'cadence', a.cadence, 'is_active', a.is_active,
        'items', coalesce((select jsonb_agg(jsonb_build_object('slug', i.slug, 'label', i.label,
                   'is_active', i.is_active) order by i.seq)
                   from count_items i where i.account_id = a.id), '[]'::jsonb))
        order by a.seq)
      from count_accounts a where a.business_id = v_biz), '[]'::jsonb),
    'entries', coalesce((select jsonb_agg(jsonb_build_object(
        'account', a.slug, 'item', i.slug, 'date', e.count_date, 'qty', e.qty)
        order by e.count_date, a.seq, i.seq)
      from count_entries e join count_items i on i.id = e.item_id
      join count_accounts a on a.id = i.account_id
      where e.business_id = v_biz and e.count_date between p_from and p_to), '[]'::jsonb),
    'weeks', coalesce((select jsonb_agg(jsonb_build_object(
        'week_start', w.week_start, 'finished_at', w.finished_at, 'finished_by', w.finished_name,
        'collected_at', w.collected_at, 'collected_note', w.collected_note) order by w.week_start)
      from count_weeks w where w.business_id = v_biz
       and w.week_start between _count_monday(p_from) and p_to), '[]'::jsonb));
end $fn$;

-- Stamps a finished week as used. Refuses an unfinished one, so a week the
-- office has not closed can never be locked from outside.
create or replace function public.counts_mark_collected(
  p_key text, p_week_start date, p_note text default null
) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $fn$
declare v_biz uuid := _count_key_business(p_key); v_n int;
begin
  if v_biz is null then raise exception 'Not allowed.'; end if;
  update count_weeks set collected_at = now(), collected_note = left(p_note, 2000)
   where business_id = v_biz and week_start = _count_monday(p_week_start)
     and finished_at is not null and collected_at is null;
  get diagnostics v_n = row_count;
  return jsonb_build_object('ok', v_n = 1);
end $fn$;

revoke execute on function public._count_monday(date), public._count_staff_name(),
  public._count_key_business(text) from anon, authenticated, public;
revoke execute on function public.counts_save(uuid, date, int),
  public.counts_finish_week(text, date), public.counts_reopen_week(text, date),
  public.counts_export(text, date, date), public.counts_mark_collected(text, date, text)
  from anon, public;
grant execute on function public.counts_save(uuid, date, int),
  public.counts_finish_week(text, date), public.counts_reopen_week(text, date) to authenticated;
grant execute on function public.counts_export(text, date, date),
  public.counts_mark_collected(text, date, text) to anon, authenticated;

-- ── the sheet itself ───────────────────────────────────────────────────────
-- Taken from the zero-quantity lines on each customer's weekly invoice: those
-- are the ones somebody has to count. Flat weekly charges are not here.

insert into public.count_accounts (business_id, slug, name, note, cadence, seq)
select b.id, x.slug, x.name, x.note, x.cadence, x.seq
  from public.businesses b
 cross join (values
   ('frog',          'Frog Collective',                 'Queen Vic Market cafe and bakery', 'weekly',  10),
   ('kempe-geelong', 'Kempe Engineering — Geelong',      'Company-owned uniforms',           'weekly',  20),
   ('kempe-pivot',   'Kempe Engineering — Pivot site',   'North Shore uniforms',             'weekly',  30),
   ('little-ginger', 'Little Ginger',                   null,                               'weekly',  40),
   ('seaview',       'Seaview Williamstown',             'Event centre',                     'weekly',  50),
   ('the-views',     'The Views',                       'Event centre',                     'weekly',  60),
   ('westgate',      'Westgate Party Hire',             null,                               'weekly',  70),
   ('pacific-meats', 'Pacific Meats',                   'Monthly. Pacific Meat and Edgars uniforms', 'monthly', 80)
 ) as x(slug, name, note, cadence, seq)
 where b.slug = 'mdc'
on conflict (business_id, slug) do nothing;

insert into public.count_items (business_id, account_id, slug, label, seq)
select a.business_id, a.id, x.slug, x.label, x.seq
  from public.count_accounts a
  join public.businesses b on b.id = a.business_id and b.slug = 'mdc'
  join (values
   ('frog','aprons','Aprons',10), ('frog','oven-mitts','Oven mitts',20),
   ('frog','bread-tin-covers','Bread tin covers / liners',30), ('frog','t-shirts','T-shirts',40),
   ('frog','trolley-covers','Trolley covers',50), ('frog','mats','Mats',60),
   ('kempe-geelong','overalls','Overalls',10), ('kempe-geelong','shirts','Shirts',20),
   ('kempe-geelong','trousers','Trousers',30), ('kempe-geelong','jackets','Jackets',40),
   ('kempe-geelong','jackets-heavy','Heavy jackets',50),
   ('kempe-pivot','jackets','Jackets',10), ('kempe-pivot','jackets-heavy','Heavy jackets',20),
   ('kempe-pivot','trousers','Trousers',30), ('kempe-pivot','overalls','Overalls',40),
   ('kempe-pivot','jumpers','Jumpers',50), ('kempe-pivot','shirts','Shirts',60),
   ('little-ginger','rental-135x135','Rental 135×135',10), ('little-ginger','rental-135x305','Rental 135×305',20),
   ('little-ginger','table-cloth','Tablecloths',30), ('little-ginger','tea-towel','Tea / hand towels',40),
   ('little-ginger','napkin','Napkins',50),
   ('seaview','table-cloth','Seaview tablecloths',10), ('seaview','serviette','Serviettes',20),
   ('seaview','chair-cover','Chair covers',30), ('seaview','table-cloth-224','224×224 tablecloths',40),
   ('the-views','round-tc','Round tablecloths',10), ('the-views','medium-tc','Medium tablecloths',20),
   ('the-views','mats','Mats',30), ('the-views','chair-cover','Chair covers',40),
   ('the-views','table-runner','Table runners',50),
   ('westgate','medium-tc','Medium tablecloths',10), ('westgate','serviette','Serviettes',20),
   ('pacific-meats','pm-trousers','Pacific — trousers',10), ('pacific-meats','pm-shirts','Pacific — shirts',20),
   ('pacific-meats','pm-coats','Pacific + Big Butcher — coats',30), ('pacific-meats','pm-lumber','Pacific — lumber',40),
   ('pacific-meats','edgars-trousers','Edgars — trousers',50), ('pacific-meats','edgars-shirts','Edgars — shirts',60),
   ('pacific-meats','overalls','Overalls',70), ('pacific-meats','mats','Mats 3×5',80),
   ('pacific-meats','tea-towels','Tea towels',90)
  ) as x(account, slug, label, seq) on x.account = a.slug
on conflict (business_id, account_id, slug) do nothing;

-- The export key itself is inserted by hand, never in a committed file:
--   insert into count_export_keys (business_id, key_hash, label)
--   select id, extensions.digest('<key>', 'sha256'), 'AIOS invoicing' from businesses where slug='mdc';
