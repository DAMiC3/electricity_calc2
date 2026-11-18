-- Prepaid Watchdog: tariffs live in the database (2026-11-18)
--
-- Replaces the Excel -> convert.py -> GitHub Pages JSON pipeline.
-- One row per tariff block, the same shape the old spreadsheet had, so it is
-- easy to edit in the Supabase Table Editor.
--
-- Yearly update (each July): add rows for the new financial year with
-- start_date = 1 July, end_date = 30 June next year, one row per block,
-- entering the EX-VAT rate exactly as printed in the municipal tariff book.
-- The app uses rate_incl_vat, which is calculated automatically.
-- Then run:  select * from public.tariff_check;   (no rows = no problems)

create table if not exists public.tariff_blocks (
  id             bigint generated always as identity primary key,
  region_key     text    not null,                 -- e.g. 'tshwane'
  display_name   text    not null,                 -- shown in the app's region list
  customer_type  text    not null default 'residential'
                 check (customer_type in ('residential', 'commercial')),
  start_date     date    not null,                 -- first day the rates apply (inclusive)
  end_date       date,                             -- last day (inclusive); null = until replaced
  tier_from      integer not null check (tier_from >= 1),        -- first kWh of the block
  tier_to        integer check (tier_to is null or tier_to >= tier_from), -- last kWh; null = open-ended
  rate_excl_vat  numeric(12, 6) not null check (rate_excl_vat > 0),        -- R/kWh as printed (ex VAT)
  surcharge_excl_vat numeric(12, 6) not null default 0
                 check (surcharge_excl_vat >= 0),  -- extra R/kWh levied on this block (e.g. Joburg 6c network surcharge above 500 kWh)
  rate_incl_vat  numeric generated always as
                 ((rate_excl_vat + surcharge_excl_vat) * 1.15) stored,      -- R/kWh the app uses
  source_url     text,
  notes          text,
  created_at     timestamptz not null default now(),
  constraint tariff_blocks_unique_block
    unique (region_key, customer_type, start_date, tier_from),
  constraint tariff_blocks_dates_ok
    check (end_date is null or end_date >= start_date)
);

comment on table public.tariff_blocks is
  'Electricity tariff blocks per municipality and financial year. Enter rate_excl_vat as printed; rate_incl_vat is calculated (15% VAT). Check with: select * from public.tariff_check;';

alter table public.tariff_blocks enable row level security;

-- Everyone (including the sign-in screen, before login) may read tariffs.
drop policy if exists tariff_blocks_read on public.tariff_blocks;
create policy tariff_blocks_read on public.tariff_blocks
  for select to anon, authenticated
  using (true);

-- No write policies: tariffs are edited in the Supabase dashboard only.
revoke all on table public.tariff_blocks from anon, authenticated;
grant select on table public.tariff_blocks to anon, authenticated;

-- ---------------------------------------------------------------------------
-- Monthly fixed charges that prepaid customers pay out of their token
-- purchases (e.g. City Power "Prepaid High": R70 service + R130 capacity
-- from 1 July 2024). One row per tariff period; start_date must match the
-- start_date of that period's rows in tariff_blocks.
-- ---------------------------------------------------------------------------
create table if not exists public.tariff_fixed_charges (
  id                    bigint generated always as identity primary key,
  region_key            text    not null,
  customer_type         text    not null default 'residential'
                        check (customer_type in ('residential', 'commercial')),
  start_date            date    not null,
  end_date              date,
  amount_excl_vat       numeric(12, 2) not null check (amount_excl_vat >= 0), -- R per month, as printed
  amount_incl_vat       numeric generated always as (amount_excl_vat * 1.15) stored,
  -- Purchases smaller than this (Rand, VAT incl.) pay only half of what they
  -- cost towards the fixed charge and half towards electricity; larger
  -- purchases pay the outstanding fixed charge first. Null = always first.
  split_below_incl_vat  numeric(12, 2) check (split_below_incl_vat is null or split_below_incl_vat > 0),
  source_url            text,
  notes                 text,
  created_at            timestamptz not null default now(),
  constraint tariff_fixed_charges_unique unique (region_key, customer_type, start_date)
);

comment on table public.tariff_fixed_charges is
  'Monthly fixed charges deducted from prepaid token purchases. start_date must match a tariff_blocks period.';

alter table public.tariff_fixed_charges enable row level security;
drop policy if exists tariff_fixed_charges_read on public.tariff_fixed_charges;
create policy tariff_fixed_charges_read on public.tariff_fixed_charges
  for select to anon, authenticated
  using (true);
revoke all on table public.tariff_fixed_charges from anon, authenticated;
grant select on table public.tariff_fixed_charges to anon, authenticated;

-- ---------------------------------------------------------------------------
-- Sanity check view: lists anything that would make the app calculate wrongly.
-- ---------------------------------------------------------------------------
create or replace view public.tariff_check
with (security_invoker = true) as
with periods as (
  select region_key, customer_type, start_date,
         count(*) filter (where tier_to is null)    as open_blocks,
         min(tier_from)                             as first_from
  from public.tariff_blocks
  group by region_key, customer_type, start_date
),
ordered_blocks as (
  select b.*,
         lag(tier_to) over (partition by region_key, customer_type, start_date
                            order by tier_from) as prev_to,
         lag(rate_excl_vat + surcharge_excl_vat) over (partition by region_key, customer_type, start_date
                                  order by tier_from) as prev_rate
  from public.tariff_blocks b
),
ordered_periods as (
  select p.*,
         lag(end_date) over (partition by region_key, customer_type
                             order by start_date) as prev_end
  from (select distinct region_key, customer_type, start_date, end_date
        from public.tariff_blocks) p
)
select region_key, customer_type, start_date, 'first block must start at 1 kWh' as problem
  from periods where first_from <> 1
union all
select region_key, customer_type, start_date, 'needs exactly one open-ended (blank tier_to) block'
  from periods where open_blocks <> 1
union all
select region_key, customer_type, start_date, 'blocks in one period have different end_date values'
  from (select region_key, customer_type, start_date, count(distinct coalesce(end_date, 'infinity'::date)) n
        from public.tariff_blocks group by 1, 2, 3) x where n > 1
union all
select region_key, customer_type, start_date, 'blocks in one period have different display_name values'
  from (select region_key, customer_type, start_date, count(distinct display_name) n
        from public.tariff_blocks group by 1, 2, 3) x where n > 1
union all
select region_key, customer_type, start_date,
       'gap/overlap: block starting at ' || tier_from || ' should start at ' || (prev_to + 1)
  from ordered_blocks where prev_to is not null and tier_from <> prev_to + 1
union all
select region_key, customer_type, start_date,
       'open-ended block is not the last block (starts at ' || tier_from || ')'
  from ordered_blocks
  where prev_to is null and tier_from <> 1
union all
select region_key, customer_type, start_date,
       'rate drops from ' || prev_rate || ' to ' || (rate_excl_vat + surcharge_excl_vat) || ' at block starting ' || tier_from || ' (check for a typo)'
  from ordered_blocks where prev_rate is not null and rate_excl_vat + surcharge_excl_vat < prev_rate
union all
select region_key, customer_type, start_date,
       'period overlaps or leaves a gap after the previous one (previous ended ' || prev_end || ')'
  from ordered_periods where prev_end is not null and start_date <> prev_end + 1
union all
select f.region_key, f.customer_type, f.start_date,
       'fixed charge has no matching tariff period in tariff_blocks'
  from public.tariff_fixed_charges f
  where not exists (select 1 from public.tariff_blocks b
                    where b.region_key = f.region_key
                      and b.customer_type = f.customer_type
                      and b.start_date = f.start_date);

revoke all on public.tariff_check from anon, authenticated;
