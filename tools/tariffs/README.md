How tariffs work now (from v1.1.1)

The tariffs live in the Supabase database (project "Prepaid Watchdog All
Accounts Data"), not in Excel. The app downloads them every time it starts.

Tables (Supabase dashboard > Table Editor):
- tariff_blocks         one row per block: region, financial year, kWh range,
                        rate EXCLUDING VAT as printed in the municipal tariff
                        book (rate_incl_vat is calculated automatically),
                        plus any per-kWh surcharge on that block.
- tariff_fixed_charges  monthly fixed charges that prepaid customers pay out of
                        their token purchases (e.g. City Power Prepaid High).

Yearly update (each July, when the municipalities publish new tariffs):
1. In tariff_blocks, add one row per block for the new year:
   start_date = 1 July, end_date = 30 June next year, same region_key and
   display_name as last year, rate_excl_vat exactly as printed (R/kWh, so
   324,12 c/kWh -> 3.2412). Put the document link in source_url.
   Joburg: put 0.06 in surcharge_excl_vat on the "above 500 kWh" block
   (6c/kWh network surcharge) if the schedule still says so.
2. If a fixed charge applies, add a row in tariff_fixed_charges with the same
   region_key and start_date (amount_excl_vat per month, as printed).
3. In the SQL editor run:   select * from public.tariff_check;
   No rows = all good. Any row describes a gap, overlap or likely typo.
4. Done - phones pick it up the next time the app opens.

Until a new year is added, the app keeps using the most recent year's rates.

Old app versions (1.1.0 and earlier) still read the GitHub Pages JSON. To
refresh it from the database:
   py tools/tariffs/export_json.py docs/tariffs.json
then commit and push docs/tariffs.json (and copy it to the old
electricity_calc repo's docs folder, which the very first release reads).

convert.py / convert.bat (Excel -> JSON) are no longer used.
