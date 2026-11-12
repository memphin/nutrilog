#!/usr/bin/env python3
"""Revokes the development certificates a CI run created (the TestFlight job in .github/workflows/ci.yml).

Automatic cloud signing (`xcodebuild archive -allowProvisioningUpdates` with an App Store Connect API key) creates a
new "Created via API" development certificate on every fresh runner, because the runner never has the private key of
an earlier one. Left alone they pile up until the account hits Apple's certificate limit and archiving fails. The
uploaded build is signed for distribution on export, so the development certificate isn't needed after the run.

    asc_dev_certificates.py snapshot STATE.json   # before the archive: remember the development certificates
    asc_dev_certificates.py revoke-new STATE.json # after the export: revoke the ones that weren't there before

Only DEVELOPMENT and IOS_DEVELOPMENT certificates that appeared after the snapshot are revoked; without a snapshot
nothing is. Reads ASC_KEY_ID, ASC_ISSUER_ID and ASC_KEY_PATH (the .p8 file) from the environment, like
tools/versions.py. Standard library plus the `openssl` command. Never fails: problems are printed as GitHub warnings
and the exit status is 0, so cleanup can't fail a release.
"""
from __future__ import annotations

import json
import os
import sys
import urllib.error
import urllib.request

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from versions import asc_token  # noqa: E402 — the API token (ES256 JWT via `openssl`), shared with tools/versions.py

API = "https://api.appstoreconnect.apple.com/v1/certificates"
DEVELOPMENT_TYPES = ("DEVELOPMENT", "IOS_DEVELOPMENT")


def request(method: str, url: str, token: str) -> dict | None:
    req = urllib.request.Request(url, method=method, headers={"Authorization": f"Bearer {token}"})
    with urllib.request.urlopen(req, timeout=30) as response:
        body = response.read()
    return json.loads(body) if body else None


def list_development_certificates(token: str, get=request) -> dict[str, dict]:
    """id → attributes of every development certificate of the team, all pages."""
    url = f"{API}?filter[certificateType]={','.join(DEVELOPMENT_TYPES)}&limit=200&fields[certificates]=certificateType,displayName,name,serialNumber,expirationDate"
    certificates: dict[str, dict] = {}
    while url:
        page = get("GET", url, token) or {}
        for item in page.get("data", []):
            certificates[item["id"]] = item.get("attributes", {})
        url = (page.get("links") or {}).get("next")
    return certificates


def new_certificates(before: dict[str, dict], after: dict[str, dict]) -> dict[str, dict]:
    """The development certificates in `after` that weren't in `before`."""
    return {
        cert_id: attributes for cert_id, attributes in after.items()
        if cert_id not in before and attributes.get("certificateType") in DEVELOPMENT_TYPES
    }


def warn(message: str):
    print(f"::warning title=Development certificate cleanup::{message}")


def main(argv: list[str], get=request, token_maker=asc_token) -> int:
    if len(argv) != 3 or argv[1] not in ("snapshot", "revoke-new"):
        print(__doc__)
        return 0
    command, state_path = argv[1], argv[2]
    try:
        token = token_maker()
        if not token:
            warn("ASC_KEY_ID, ASC_ISSUER_ID or ASC_KEY_PATH is not set.")
            return 0
        current = list_development_certificates(token, get=get)
        if command == "snapshot":
            with open(state_path, "w") as f:
                json.dump(current, f)
            print(f"{len(current)} development certificate(s) before the build.")
            return 0
        try:
            with open(state_path) as f:
                before = json.load(f)
        except (OSError, ValueError):
            warn("No snapshot from before the build, so nothing is revoked. Check Certificates in the developer account.")
            return 0
        created = new_certificates(before, current)
        if not created:
            print("No development certificate was created by this run.")
            return 0
        for cert_id, attributes in created.items():
            label = attributes.get("displayName") or attributes.get("name") or cert_id
            try:
                get("DELETE", f"{API}/{cert_id}", token)
                print(f"Revoked the development certificate this run created: {label} ({cert_id}).")
            except Exception as error:  # noqa: BLE001
                warn(f"Couldn't revoke {label} ({cert_id}): {error}. Revoke it under Certificates.")
        return 0
    except Exception as error:  # noqa: BLE001 — cleanup must never fail the release
        warn(f"App Store Connect API: {error}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
