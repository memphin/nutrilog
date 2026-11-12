#!/usr/bin/env python3
"""Writes translations from a JSON file into a String Catalog (.xcstrings).

Xcode extracts the English keys (build in Xcode, or `xcodebuild -exportLocalizations`); this fills in a language.
Translations file: {"<key>": <value>, ...} where <value> is
  - "text"                                  a plain translation
  - {"one": "…", "few": "…", "other": "…"}  plural forms of the string's single integer argument (%lld)
  - {"hr": <value>, "en": <value>}          per-language values, e.g. English plural forms next to the Croatian ones
  - {"localization": {...}}                  a raw xcstrings localization object (substitutions for several plurals)

Usage: tools/apply_translations.py <catalog.xcstrings> <translations.json> [--language hr] [--check]
--check only lists the keys of the catalog that have no translation in the language, and exits 1 if there are any.
"""

import argparse
import json
import sys

PLURAL_CATEGORIES = ("zero", "one", "two", "few", "many", "other")


def localization(value):
    """The xcstrings localization object for one language."""
    if isinstance(value, str):
        return {"stringUnit": {"state": "translated", "value": value}}
    if "localization" in value:
        return value["localization"]
    if set(value) <= set(PLURAL_CATEGORIES) and "other" in value:
        return {"variations": {"plural": {
            category: {"stringUnit": {"state": "translated", "value": value[category]}}
            for category in PLURAL_CATEGORIES if category in value
        }}}
    raise ValueError(f"unrecognized translation value: {value!r}")


def needs_translation(key, entry):
    # Keys made only of format specifiers and punctuation ("%@ · %@") read the same in every language.
    return entry.get("shouldTranslate", True) and entry.get("extractionState") != "stale"


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("catalog")
    parser.add_argument("translations", nargs="?")
    parser.add_argument("--language", default="hr")
    parser.add_argument("--check", action="store_true")
    args = parser.parse_args()

    with open(args.catalog, encoding="utf-8") as handle:
        catalog = json.load(handle)
    strings = catalog["strings"]

    if args.check:
        missing = [key for key, entry in strings.items()
                   if needs_translation(key, entry) and args.language not in entry.get("localizations", {})]
        for key in missing:
            print(key)
        sys.exit(1 if missing else 0)

    with open(args.translations, encoding="utf-8") as handle:
        translations = json.load(handle)

    unknown = [key for key in translations if key not in strings]
    for key, value in translations.items():
        if key in unknown:
            continue
        per_language = value if isinstance(value, dict) and set(value) & {"hr", "en"} and set(value) <= {"hr", "en"} \
            else {args.language: value}
        localizations = strings[key].setdefault("localizations", {})
        for language, language_value in per_language.items():
            localizations[language] = localization(language_value)

    with open(args.catalog, "w", encoding="utf-8") as handle:
        # Xcode's own formatting, so a later build in Xcode does not rewrite the whole file.
        json.dump(catalog, handle, ensure_ascii=False, indent=2, separators=(",", " : "), sort_keys=True)
        handle.write("\n")

    if unknown:
        print(f"{len(unknown)} keys are not in the catalog (renamed or removed in code?):", file=sys.stderr)
        for key in unknown:
            print(f"  {key}", file=sys.stderr)


if __name__ == "__main__":
    main()
