# tools

## build_food_index.py
Generates `Resources/FoodIndex/bundled_foods.sqlite` — the offline generic-food index (USDA FoodData Central *Foundation* + *SR Legacy*, filtered to a curated allowlist of common whole foods). CC0 data; the output is committed.

```bash
cd tools
python3 -m venv .venv && source .venv/bin/activate
pip install -r requirements.txt
# 1. Download the "Foundation Foods" and "SR Legacy" CSV bundles from https://fdc.nal.usda.gov/download-datasets
#    and unzip each into its own folder (both contain food.csv):
#      tools/data/raw/foundation/   (last built from the 2026-04-30 release — the 2026-10-29 zip
#                                    is missing food.csv / food_nutrient.csv)
#      tools/data/raw/sr_legacy/    (2018-04, final release)
python build_food_index.py --raw data/raw/foundation data/raw/sr_legacy \
  --allowlist allowlist.txt --out ../Resources/FoodIndex/bundled_foods.sqlite
```

The allowlist is a plain text file, one FDC description substring or exact `fdc_id` per line. Start small (~300 foods) and grow it from real usage ("not found" logs).

Filtering rules (in the script): SR Legacy brand-name items (CAPS brands) and regional variants are dropped unless
listed by exact `fdc_id`; when Foundation and SR Legacy share a name, the row with complete macros wins, then Foundation.
Energy falls back to Atwater factors (nutrient 2048/2047) when 1008 is missing.
