-- tariff_check: also flag a period with a blank end_date that is followed by
-- a newer period (the overlap was previously not reported).
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
                             order by start_date) as prev_end,
         lag(start_date) over (partition by region_key, customer_type
                               order by start_date) as prev_start
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
select region_key, customer_type, start_date,
       'previous period (from ' || prev_start || ') has a blank end_date - set it to the day before this one'
  from ordered_periods where prev_start is not null and prev_end is null
union all
select f.region_key, f.customer_type, f.start_date,
       'fixed charge has no matching tariff period in tariff_blocks'
  from public.tariff_fixed_charges f
  where not exists (select 1 from public.tariff_blocks b
                    where b.region_key = f.region_key
                      and b.customer_type = f.customer_type
                      and b.start_date = f.start_date);

revoke all on public.tariff_check from anon, authenticated;

do $$
begin
  if exists (select 1 from public.tariff_check) then
    raise exception 'tariff_check reports problems after update';
  end if;
end $$;
