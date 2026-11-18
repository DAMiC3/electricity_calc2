"""Export the tariffs from the database to docs/tariffs.json.

The current app (v1.1.1+) reads tariffs straight from the database, so this is
ONLY for people who still run an older app version (they download
https://damic3.github.io/electricity_calc2/tariffs.json, and the very first
release used https://damic3.github.io/electricity_calc/tariffs.json).

Older versions cannot apply monthly fixed charges; they only get the block
rates (VAT and surcharges included).

usage:  py tools/tariffs/export_json.py [output.json]
"""
import json
import sys
import urllib.request
from datetime import date

URL = 'https://qzcziazzbyvidawwlnen.supabase.co/rest/v1/tariff_blocks'
# Public (anon) key - the same one shipped in the app; it can only read tariffs.
KEY = ('eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6InF6Y3ppYXp6Ynl2aWRhd3dsbmVuIiwicm9sZSI6ImFub24iLCJpYXQiOjE3NjE1NjUxMzAsImV4cCI6MjA3NzE0MTEzMH0'
       '.lheIfO7B9d0a0Qhp5Hgg8jco1g6_Pn1U2EgCcwwddYk')

out_path = sys.argv[1] if len(sys.argv) > 1 else 'docs/tariffs.json'
query = ('?select=region_key,display_name,start_date,end_date,tier_from,tier_to,rate_incl_vat'
         '&customer_type=eq.residential&order=region_key,start_date,tier_from')
req = urllib.request.Request(URL + query, headers={'apikey': KEY, 'Authorization': 'Bearer ' + KEY})
rows = json.load(urllib.request.urlopen(req, timeout=30))
if not rows:
    sys.exit('No tariff rows returned - not writing anything.')

regions, index = [], {}
for r in rows:
    k = (r['region_key'], r['start_date'])
    if k not in index:
        index[k] = {'regionKey': r['region_key'], 'displayName': r['display_name'],
                    'startDate': r['start_date'], 'endDate': r['end_date'], 'blocks': []}
        regions.append(index[k])
    index[k]['blocks'].append({'from': int(r['tier_from']),
                               'to': None if r['tier_to'] is None else int(r['tier_to']),
                               'rate': round(float(r['rate_incl_vat']), 4)})

payload = {'versionYear': max(int(r['startDate'][:4]) for r in regions),
           'exportedOn': date.today().isoformat(),
           'regions': regions}
with open(out_path, 'w', encoding='utf-8') as f:
    json.dump(payload, f, ensure_ascii=False, indent=2)
print(f'OK: wrote {out_path} with {len(regions)} region-periods ({len(rows)} blocks)')
