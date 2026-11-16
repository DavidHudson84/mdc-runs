-- 0022 — two more items on the Westgate Party Hire count sheet
--
-- Westgate only had medium tablecloths and serviettes. They also send chair
-- covers, which were not being counted (and so not billed), and sometimes
-- large round tablecloths. Slugs follow the ones already used on The Views.
-- Prices live outside this repo, with the invoicing.

insert into public.count_items (business_id, account_id, slug, label, seq)
select a.business_id, a.id, x.slug, x.label, x.seq
  from public.count_accounts a
  join public.businesses b on b.id = a.business_id and b.slug = 'mdc'
  join (values
   ('westgate','round-tc','Large round tablecloths',30),
   ('westgate','chair-cover','Chair covers',40)
  ) as x(account, slug, label, seq) on x.account = a.slug
on conflict (business_id, account_id, slug) do nothing;
