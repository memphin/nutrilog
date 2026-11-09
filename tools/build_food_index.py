#!/usr/bin/env python3
"""Build the bundled offline food index from USDA FoodData Central CSV dumps.

Output schema matches a subset of the app's `food` table so rows can be copied
straight into the user database with source='bundled'.

Usage: see tools/README.md. Phase 0 skeleton — nutrient ID mapping is complete,
allowlist filtering is simple substring matching; refine as needed.
"""
from __future__ import annotations
import argparse, sqlite3, uuid, sys
from pathlib import Path
import pandas as pd

# FDC nutrient ids (nutrient.csv) → our columns. Energy: 1008 kcal (fallback 2047/2048 Atwater).
NUTRIENTS = {
    1008: "kcal_100", 1003: "protein_g_100", 1005: "carbs_g_100", 1004: "fat_g_100",
    1079: "fiber_g_100", 2000: "sugar_g_100", 1258: "sat_fat_g_100", 1093: "sodium_mg_100",
}

# Foundation foods often report energy only as Atwater general (2047) / specific (2048) factors.
ENERGY_FALLBACKS = (2048, 2047)

def find_csv_dir(raw: Path) -> Path:
    """Accept either the unzipped folder itself or a parent containing it."""
    if (raw / "food.csv").exists():
        return raw
    hits = sorted(p.parent for p in raw.rglob("food.csv"))
    if not hits:
        sys.exit(f"no food.csv under {raw}")
    return hits[0]

def load_one(raw: Path):
    d = find_csv_dir(raw)
    food = pd.read_csv(d / "food.csv", usecols=["fdc_id", "data_type", "description"])
    food = food[food.data_type.isin(["foundation_food", "sr_legacy_food"])]
    fn = pd.read_csv(d / "food_nutrient.csv", usecols=["fdc_id", "nutrient_id", "amount"])
    fn = fn[fn.nutrient_id.isin(list(NUTRIENTS) + list(ENERGY_FALLBACKS)) & fn.fdc_id.isin(food.fdc_id)]
    wide = fn.pivot_table(index="fdc_id", columns="nutrient_id", values="amount", aggfunc="first")
    for nid in list(NUTRIENTS) + list(ENERGY_FALLBACKS):
        if nid not in wide.columns:
            wide[nid] = float("nan")
    for nid in ENERGY_FALLBACKS:
        wide[1008] = wide[1008].fillna(wide[nid])
    wide = wide[list(NUTRIENTS)].rename(columns=NUTRIENTS)
    return food.merge(wide, left_on="fdc_id", right_index=True, how="inner")

def load(raws: list[Path]):
    df = pd.concat([load_one(r) for r in raws], ignore_index=True)
    # Prefer rows with complete macros, then Foundation over SR Legacy, when both describe the same food.
    macros = ["kcal_100", "protein_g_100", "carbs_g_100", "fat_g_100"]
    df["_rank"] = df[macros].isna().any(axis=1).astype(int) * 2 + (df.data_type != "foundation_food").astype(int)
    df = df.sort_values(["_rank", "description"]).drop_duplicates("description").drop(columns="_rank")
    return df

# Drop SR Legacy brand-name items (brands are written in CAPS, e.g. "POST HONEY BUNCHES OF OATS")
# and regional/program-specific variants that only add noise to a generic-food index.
PROGRAM_NOTE = r"\s*\((?:[Ii]ncludes|[Ff]ormerly)[^)]*\)"
EXCLUDE_REGEX = (r"\b(?!USDA\b|NFS\b|USA\b)[A-Z]{3,}\b|Alaska Native|Navajo|Hopi|Shoshone|Apache|"
                 r"Northern Plains Indians|Babyfood|Oscar Mayer|Restaurant|Fast foods")

def _allow_ids(allowlist: Path | None) -> set[int]:
    """Explicit fdc_ids in the allowlist bypass the brand/noise filter."""
    if not allowlist:
        return set()
    return {int(l.strip()) for l in allowlist.read_text().splitlines() if l.strip().isdigit()}

def apply_allowlist(df: pd.DataFrame, allowlist: Path | None):
    df = df.assign(description=df.description.str.replace(PROGRAM_NOTE, "", regex=True).str.strip())
    df = df[~df.description.str.contains(EXCLUDE_REGEX, regex=True) | df.fdc_id.isin(_allow_ids(allowlist))]
    df = df.drop_duplicates("description")  # cleaning can make names collide; first (Foundation) wins
    if not allowlist:
        return df
    terms, ids = [], set()
    for line in allowlist.read_text().splitlines():
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        (ids.add(int(line)) if line.isdigit() else terms.append(line.lower()))
    mask = df.fdc_id.isin(ids)
    for t in terms:
        mask |= df.description.str.lower().str.contains(t, regex=False)
    return df[mask]

def write(df: pd.DataFrame, out: Path):
    out.parent.mkdir(parents=True, exist_ok=True)
    if out.exists():
        out.unlink()
    con = sqlite3.connect(out)
    con.executescript("""
        CREATE TABLE bundled_food (
            id TEXT PRIMARY KEY, source_id TEXT NOT NULL, name TEXT NOT NULL,
            kcal_100 REAL NOT NULL, protein_g_100 REAL NOT NULL, carbs_g_100 REAL NOT NULL, fat_g_100 REAL NOT NULL,
            fiber_g_100 REAL, sugar_g_100 REAL, sat_fat_g_100 REAL, sodium_mg_100 REAL
        );
        CREATE VIRTUAL TABLE bundled_food_fts USING fts5(name, content='bundled_food', content_rowid='rowid',
            tokenize="unicode61 remove_diacritics 2");
    """)
    rows = []
    for r in df.itertuples(index=False):
        if pd.isna(r.kcal_100) or pd.isna(r.protein_g_100) or pd.isna(r.carbs_g_100) or pd.isna(r.fat_g_100):
            continue
        rows.append((str(uuid.uuid5(uuid.NAMESPACE_URL, f"fdc:{r.fdc_id}")), str(r.fdc_id), r.description,
                     r.kcal_100, r.protein_g_100, r.carbs_g_100, r.fat_g_100,
                     *(None if pd.isna(getattr(r, c)) else float(getattr(r, c))
                       for c in ("fiber_g_100", "sugar_g_100", "sat_fat_g_100", "sodium_mg_100"))))
    con.executemany("INSERT INTO bundled_food VALUES (?,?,?,?,?,?,?,?,?,?,?)", rows)
    con.execute("INSERT INTO bundled_food_fts(bundled_food_fts) VALUES ('rebuild')")
    con.commit(); con.close()
    print(f"wrote {len(rows)} foods → {out}")

if __name__ == "__main__":
    ap = argparse.ArgumentParser()
    ap.add_argument("--raw", type=Path, nargs="+", required=True, help="one or more unzipped FDC CSV folders")
    ap.add_argument("--allowlist", type=Path)
    ap.add_argument("--out", type=Path, required=True)
    a = ap.parse_args()
    df = load(a.raw)
    df = apply_allowlist(df, a.allowlist)
    if df.empty:
        sys.exit("no foods matched")
    write(df, a.out)
