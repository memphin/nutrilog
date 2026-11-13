# tools

## versions.py
Prints which version is on the App Store, on TestFlight and on `main`, and what needs doing (see
`docs/RELEASING.md`, "Which version is where"). Standard library only: `python3 tools/versions.py [--markdown]`.

## asc_dev_certificates.py
Used by the TestFlight job: `snapshot STATE.json` before the archive lists the team's development certificates,
`revoke-new STATE.json` after the upload revokes the ones the run created (automatic signing makes one on every fresh
CI machine). Needs `ASC_KEY_ID`, `ASC_ISSUER_ID` and `ASC_KEY_PATH`, like `versions.py`; never exits with an error.
See `docs/RELEASING.md`, Troubleshooting.

## apply_translations.py
Writes Croatian translations into a String Catalog: `python3 tools/apply_translations.py <catalog.xcstrings> <translations.json>`
(see `CONTRIBUTING.md`, Localization).

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

Croatian names: `food_names_hr.csv` (`fdc_id,name_hr`, one row per bundled food) is the source of truth for the
`name_hr` column. The build applies it (`--names-hr`, default `tools/food_names_hr.csv`), fails on an `fdc_id` that
isn't in the index and lists foods without a Croatian name. The raw USDA dumps aren't kept, so after editing the CSV
apply it to the committed index in place (needs no pandas):

```bash
python3 tools/build_food_index.py --apply-names-hr Resources/FoodIndex/bundled_foods.sqlite
```

The allowlist is a plain text file, one FDC description substring or exact `fdc_id` per line. Start small (~300 foods) and grow it from real usage ("not found" logs).

Filtering rules (in the script): SR Legacy brand-name items (CAPS brands) and regional variants are dropped unless
listed by exact `fdc_id`; when Foundation and SR Legacy share a name, the row with complete macros wins, then Foundation.
Energy falls back to Atwater factors (nutrient 2048/2047) when 1008 is missing.
