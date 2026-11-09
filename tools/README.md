# tools

## build_food_index.py
Generates `Resources/FoodIndex/bundled_foods.sqlite` — the offline generic-food index (USDA FoodData Central *Foundation* + *SR Legacy*, filtered to a curated allowlist of common whole foods). CC0 data; the output is committed.

```bash
cd tools
python3 -m venv .venv && source .venv/bin/activate
pip install -r requirements.txt
# 1. Download "Foundation Foods" and "SR Legacy" CSV bundles from https://fdc.nal.usda.gov/download-datasets
#    and unzip them into tools/data/raw/
python build_food_index.py --raw data/raw --allowlist allowlist.txt --out ../Resources/FoodIndex/bundled_foods.sqlite
```

The allowlist is a plain text file, one FDC description substring or exact `fdc_id` per line. Start small (~300 foods) and grow it from real usage ("not found" logs).
