#!/usr/bin/env python3
"""Which Vitalion version is where: App Store (production), TestFlight (test) and main (development).

    python3 tools/versions.py                # table in the terminal
    python3 tools/versions.py --markdown     # Markdown, as posted to the pinned "Release status" issue

Standard library only (plus the `openssl` and `git` commands). Sources:

- App Store: the public iTunes Lookup API, no key needed. With an App Store Connect key, also a version that is
  waiting for review or release.
- TestFlight: the App Store Connect API. Needs ASC_KEY_ID, ASC_ISSUER_ID and the key, either ASC_KEY_P8 (the .p8
  as base64, as stored in the GitHub secret) or ASC_KEY_PATH (path to the .p8). Without them this row is skipped.
- Development: git (newest v* tag, commits since it) and MARKETING_VERSION in project.yml.

The ".github/workflows/release-status.yml" workflow runs this and keeps the issue up to date (docs/RELEASING.md).
"""
import argparse
import base64
import datetime as dt
import json
import os
import re
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.parse
import urllib.request

BUNDLE_ID = "hr.ivanjuric.nutrilog"
STORE_COUNTRIES = ("us", "hr")  # the lookup only answers for storefronts the app is sold in
ASC_API = "https://api.appstoreconnect.apple.com/v1"
EXPIRY_WARNING_DAYS = 14
ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


# --- helpers -------------------------------------------------------------------------------------------------------

def version_key(version):
    """'1.1.5' -> (1, 1, 5), so versions compare as numbers. Non-numeric parts count as 0."""
    return tuple(int(p) if p.isdigit() else 0 for p in (version or "0").split("."))


def same_version(a, b):
    """'1.0' and '1.0.0' are the same version."""
    ka, kb = list(version_key(a)), list(version_key(b))
    n = max(len(ka), len(kb))
    return ka + [0] * (n - len(ka)) == kb + [0] * (n - len(kb))


def parse_date(value):
    if not value:
        return None
    return dt.datetime.fromisoformat(value.replace("Z", "+00:00")).astimezone(dt.timezone.utc)


def day(value):
    return value.strftime("%Y-%m-%d") if value else "?"


def get_json(url, headers=None):
    request = urllib.request.Request(url, headers={"Accept": "application/json", **(headers or {})})
    with urllib.request.urlopen(request, timeout=30) as response:
        return json.load(response)


def git(*args):
    return subprocess.run(["git", "-C", ROOT, *args], check=True, capture_output=True, text=True).stdout.strip()


# --- App Store ---------------------------------------------------------------------------------------------------

def app_store_live():
    """The version on sale, from the public lookup API."""
    for country in STORE_COUNTRIES:
        query = urllib.parse.urlencode({"bundleId": BUNDLE_ID, "country": country})
        results = get_json("https://itunes.apple.com/lookup?" + query).get("results", [])
        if results:
            app = results[0]
            return {
                "version": app["version"],
                "released": parse_date(app.get("currentVersionReleaseDate")),
                "url": app.get("trackViewUrl", "").split("?")[0],
            }
    return None


# --- App Store Connect -------------------------------------------------------------------------------------------

def _der_to_raw(signature):
    """ES256 JWTs need the raw 64-byte r||s signature; openssl gives an ASN.1 DER sequence of two integers."""
    def read_int(data, i):
        assert data[i] == 0x02, "bad DER signature"
        length = data[i + 1]
        value = data[i + 2:i + 2 + length]
        return int.from_bytes(value, "big"), i + 2 + length

    assert signature[0] == 0x30, "bad DER signature"
    start = 2 if signature[1] < 0x80 else 2 + (signature[1] & 0x7F)
    r, i = read_int(signature, start)
    s, _ = read_int(signature, i)
    return r.to_bytes(32, "big") + s.to_bytes(32, "big")


def _b64url(data):
    return base64.urlsafe_b64encode(data).rstrip(b"=").decode()


def asc_token():
    """A 10-minute App Store Connect API token, or None when no key is configured."""
    key_id, issuer = os.environ.get("ASC_KEY_ID"), os.environ.get("ASC_ISSUER_ID")
    if os.environ.get("ASC_KEY_P8"):
        key = base64.b64decode(os.environ["ASC_KEY_P8"])
    elif os.environ.get("ASC_KEY_PATH"):
        with open(os.path.expanduser(os.environ["ASC_KEY_PATH"]), "rb") as f:
            key = f.read()
    else:
        key = None
    if not (key_id and issuer and key):
        return None

    now = int(time.time())
    header = _b64url(json.dumps({"alg": "ES256", "kid": key_id, "typ": "JWT"}).encode())
    payload = _b64url(json.dumps({"iss": issuer, "iat": now, "exp": now + 600, "aud": "appstoreconnect-v1"}).encode())
    signing_input = f"{header}.{payload}".encode()
    with tempfile.NamedTemporaryFile(suffix=".p8") as key_file:
        key_file.write(key)
        key_file.flush()
        der = subprocess.run(["openssl", "dgst", "-sha256", "-sign", key_file.name],
                             input=signing_input, check=True, capture_output=True).stdout
    return f"{header}.{payload}.{_b64url(_der_to_raw(der))}"


def asc_get(token, path, **params):
    url = f"{ASC_API}/{path}?" + urllib.parse.urlencode(params)
    return get_json(url, {"Authorization": f"Bearer {token}"})


def asc_status(token):
    """Newest TestFlight build and the newest App Store version record (which may be in review)."""
    apps = asc_get(token, "apps", **{"filter[bundleId]": BUNDLE_ID, "fields[apps]": "bundleId"})["data"]
    if not apps:
        raise RuntimeError(f"no App Store Connect app with bundle ID {BUNDLE_ID}")
    app_id = apps[0]["id"]

    builds = asc_get(token, "builds", **{
        "filter[app]": app_id, "sort": "-uploadedDate", "limit": "1", "include": "preReleaseVersion",
    })
    build = None
    if builds["data"]:
        b = builds["data"][0]["attributes"]
        versions = {i["id"]: i["attributes"]["version"] for i in builds.get("included", [])
                    if i["type"] == "preReleaseVersions"}
        relation = builds["data"][0]["relationships"]["preReleaseVersion"]["data"]
        build = {
            "version": versions.get(relation["id"]) if relation else None,
            "build": b.get("version"),
            "state": b.get("processingState"),
            "uploaded": parse_date(b.get("uploadedDate")),
            "expires": parse_date(b.get("expirationDate")),
            "expired": b.get("expired", False),
        }

    # App Store version records carry a hand-typed label ("1.1"); the build attached to each one has the real version.
    store_versions = asc_get(token, f"apps/{app_id}/appStoreVersions", **{
        "filter[platform]": "IOS", "limit": "10", "include": "build",
    })
    live = pending = None
    for record in store_versions["data"]:
        a = record["attributes"]
        state = a.get("appVersionState") or a.get("appStoreState")
        entry = {"label": a.get("versionString"), "state": state, **store_build(token, record)}
        if state in LIVE_STATES:
            if live is None:
                live = entry
                live["whats_new"] = whats_new(token, record["id"])
        elif state not in GONE_STATES and pending is None and live is None:
            pending = entry  # newer than the live one (the list is newest first)
    return build, live, pending


LIVE_STATES = ("READY_FOR_SALE", "READY_FOR_DISTRIBUTION")
GONE_STATES = ("REPLACED_WITH_NEW_VERSION", "REMOVED_FROM_SALE", "DEVELOPER_REMOVED_FROM_SALE")


def store_build(token, record):
    """{'version': '1.1.4', 'build': '40'} of the build attached to an App Store version record, or {}."""
    relation = record.get("relationships", {}).get("build", {}).get("data")
    if not relation:
        return {}
    build = asc_get(token, f"builds/{relation['id']}", include="preReleaseVersion")
    included = build.get("included", [])
    return {
        "version": included[0]["attributes"]["version"] if included else None,
        "build": build["data"]["attributes"].get("version"),
    }


def whats_new(token, version_id):
    """The App Store "What's New" text, English if there is one."""
    localizations = asc_get(token, f"appStoreVersions/{version_id}/appStoreVersionLocalizations")["data"]
    texts = {l["attributes"]["locale"]: l["attributes"].get("whatsNew") for l in localizations}
    for locale in ("en-US", "en-GB"):
        if texts.get(locale):
            return texts[locale].strip()
    return next((t.strip() for t in texts.values() if t), None)


# --- development and release notes --------------------------------------------------------------------------------

INTERNAL = re.compile(r"^(Release \d|Release status|CI|Tests?|Docs?|Tools|Backlog|Chore)\b", re.IGNORECASE)
FIXED = re.compile(r"\b(fix(es|ed)?|crash(es)?|bugs?|wrong)\b", re.IGNORECASE)


def development():
    with open(os.path.join(ROOT, "project.yml")) as f:
        match = re.search(r'^\s*MARKETING_VERSION:\s*"?([^"\s]+)"?', f.read(), re.MULTILINE)
    tags = sorted((t for t in git("tag", "--list", "v*").split() if re.fullmatch(r"v\d+\.\d+\.\d+", t)),
                  key=lambda t: version_key(t[1:]))
    tag = tags[-1] if tags else None
    return {
        "version": match.group(1) if match else None,
        "branch": git("rev-parse", "--abbrev-ref", "HEAD"),
        "commit": git("rev-parse", "--short", "HEAD"),
        "tag": tag,
        "tags": tags,
        "since_tag": int(git("rev-list", "--count", f"{tag}..HEAD")) if tag else None,
    }


def changes(since, until):
    """Commit subjects in since..until (squash-merged PR titles), sorted into what users notice.

    Releases, CI, tests and docs are left out. A title that mentions a fix, crash or bug goes under "Fixed",
    everything else under "New & improved".
    """
    span = f"{since}..{until}" if since else until
    out = {"New & improved": [], "Fixed": []}
    for subject in git("log", "--format=%s", "--no-merges", span).splitlines():
        if INTERNAL.match(subject):
            continue
        out["Fixed" if FIXED.search(subject) else "New & improved"].append(subject)
    return out


def release_notes(status):
    """[(title, [labels], date, changes)] from the unreleased work on main down to the version on the App Store."""
    dev = status.get("dev")
    if not dev:
        return []
    tags = dev["tags"]
    where = {}
    live, pending, tf = status.get("live"), status.get("pending"), status.get("testflight")
    for label, info in (("App Store", live), ("App Store, next", pending), ("TestFlight", tf)):
        if info and info.get("version"):
            where.setdefault("v" + info["version"], []).append(label)
    production = live.get("version") if live else None
    if not production and status.get("store"):
        production = status["store"]["version"]  # the label: only matches a tag when it is the full version

    out = []
    if dev["since_tag"]:
        out.append(("Unreleased (main)", ["Development"], None, changes(dev["tag"], "HEAD")))
    for n in range(len(tags) - 1, -1, -1):
        tag = tags[n]
        date = git("log", "-1", "--format=%cs", tag)
        out.append((tag[1:], where.get(tag, []), date, changes(tags[n - 1] if n else None, tag)))
        if production and same_version(tag[1:], production):
            break
        if len(out) >= 12:
            break
    return out


# --- report --------------------------------------------------------------------------------------------------------

def collect():
    status = {"errors": []}
    try:
        status["store"] = app_store_live()
    except (urllib.error.URLError, ValueError, KeyError) as e:
        status["errors"].append(f"App Store lookup failed: {e}")
    try:
        token = asc_token()
        if token:
            status["testflight"], status["live"], status["pending"] = asc_status(token)
        else:
            status["no_key"] = True
    except (urllib.error.URLError, subprocess.CalledProcessError, RuntimeError, ValueError, KeyError) as e:
        status["errors"].append(f"App Store Connect failed: {e}")
    try:
        status["dev"] = development()
    except (OSError, subprocess.CalledProcessError) as e:
        status["errors"].append(f"git/project.yml failed: {e}")
    return status


def full(info):
    """'1.1.4 (40)' for a record with a build, else its label."""
    if info.get("version"):
        return f"{info['version']} ({info['build']})" if info.get("build") else info["version"]
    return info.get("label") or "?"


def rows(status):
    """(environment, version, details) for each row."""
    out = []
    store, live = status.get("store"), status.get("live")
    if store or live:
        details = []
        if live and live.get("version") and live.get("label") and not same_version(live["label"], live["version"]):
            details.append(f"listed as {live['label']}")
        if store:
            details.append(f"live since {day(store['released'])}")
        out.append(("Production (App Store)", full(live) if live else store["version"], " · ".join(details)))
    elif "store" in status:
        out.append(("Production (App Store)", "—", "not on the App Store"))
    pending = status.get("pending")
    if pending:
        state = (pending["state"] or "?").replace("_", " ").lower()
        listed = f"listed as {pending['label']} · " if pending.get("version") and pending.get("label") \
            and not same_version(pending["label"], pending["version"]) else ""
        out.append(("App Store, next", full(pending), listed + state))

    tf = status.get("testflight")
    if tf:
        expiry = "**expired**" if tf["expired"] else f"expires {day(tf['expires'])}"
        state = "" if tf["state"] == "VALID" else f" · {(tf['state'] or '?').lower()}"
        out.append(("Test (TestFlight)", full(tf), f"uploaded {day(tf['uploaded'])} · {expiry}{state}"))
    elif status.get("no_key"):
        out.append(("Test (TestFlight)", "?", "no App Store Connect key (set ASC_KEY_ID, ASC_ISSUER_ID, ASC_KEY_PATH)"))
    elif "testflight" in status:
        out.append(("Test (TestFlight)", "—", "no builds"))

    dev = status.get("dev")
    if dev:
        if dev["tag"] is None:
            since = "no release tag yet"
        elif dev["since_tag"]:
            since = f"{dev['since_tag']} commit{'s' if dev['since_tag'] != 1 else ''} since {dev['tag']}"
        else:
            since = f"at {dev['tag']}"
        out.append(("Development", dev["version"] or "?", f"{dev['branch']} @ {dev['commit']} · {since}"))
    return out


def notes(status):
    """Things that need a decision or an action."""
    out = []
    tf, dev, pending = status.get("testflight"), status.get("dev"), status.get("pending")
    live = status.get("live") or {}
    production = live.get("version")
    now = dt.datetime.now(dt.timezone.utc)
    if tf and tf["expires"] and not tf["expired"] and (tf["expires"] - now).days < EXPIRY_WARNING_DAYS:
        out.append(f"⚠️ TestFlight build {full(tf)} expires in {(tf['expires'] - now).days} days. "
                   "Push a new patch tag to keep testing.")
    if tf and tf["state"] not in ("VALID", "PROCESSING"):
        out.append(f"⚠️ TestFlight build {full(tf)} is {tf['state']}.")
    if dev and dev["tag"] and tf and tf["version"] and not same_version(dev["tag"][1:], tf["version"]):
        out.append(f"⚠️ The newest tag is {dev['tag']}, but TestFlight has {tf['version']}. "
                   "Check the TestFlight upload job for that tag.")
    submitted = pending and pending.get("version") and tf and same_version(pending["version"], tf["version"] or "")
    if tf and production and tf["version"] and version_key(tf["version"]) > version_key(production) \
            and not same_version(tf["version"], production) and not submitted:
        out.append(f"ℹ️ {tf['version']} is on TestFlight and not yet submitted to the App Store.")
    if dev and dev["tag"] and dev["since_tag"] and dev["version"] and same_version(dev["version"], dev["tag"][1:]):
        out.append(f"ℹ️ There are unreleased commits, but project.yml still says {dev['version']}. "
                   "Bump MARKETING_VERSION before the next tag.")
    out.extend(f"❌ {e}" for e in status["errors"])
    return out


def heading(title, labels, date):
    return " · ".join([title] + labels + ([date] if date else []))


def as_text(status):
    table = rows(status)
    width = max((len(r[0]) for r in table), default=0)
    vwidth = max((len(r[1]) for r in table), default=0)
    lines = [f"{env:<{width}}  {ver:<{vwidth}}  {details}".replace("**", "") for env, ver, details in table]
    extra = notes(status)
    if extra:
        lines += [""] + extra
    history = release_notes(status)
    if history:
        lines += ["", "What's in each version", "======================"]
    for title, labels, date, groups in history:
        lines += ["", heading(title, labels, date)]
        items = [(g, s) for g, subjects in groups.items() for s in subjects]
        lines += [f"  {'fix' if g == 'Fixed' else '+  '} {s}" for g, s in items] or ["  (internal changes only)"]
    return "\n".join(lines)


def as_markdown(status):
    lines = ["| Environment | Version | Details |", "|---|---|---|"]
    lines += [f"| {env} | **{ver}** | {details} |" for env, ver, details in rows(status)]
    extra = notes(status)
    if extra:
        lines += [""] + [f"- {n}" for n in extra]
    store = status.get("store")
    if store and store.get("url"):
        lines += ["", f"[App Store page]({store['url']})"]

    history = release_notes(status)
    if history:
        lines += ["", "## What's in each version", ""]
    whats_new_text = (status.get("live") or {}).get("whats_new")
    for title, labels, date, groups in history:
        lines += [f"### {heading(title, [f'**{l}**' for l in labels], date)}", ""]
        if "App Store" in labels and whats_new_text:
            lines += ["> " + line for line in whats_new_text.splitlines()] + [""]
        if not any(groups.values()):
            lines += ["_Internal changes only (CI, tests, docs)._", ""]
        for group, subjects in groups.items():
            if subjects:
                lines += [f"**{group}**", ""] + [f"- {s}" for s in subjects] + [""]
    lines.append("<sub>Notes are the merged PR titles between release tags; CI, test, doc and release commits are "
                 "left out. The quote under the App Store version is its \"What's New\" text.</sub>")
    return "\n".join(lines)


def main():
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument("--markdown", action="store_true", help="print Markdown instead of plain text")
    args = parser.parse_args()
    status = collect()
    print(as_markdown(status) if args.markdown else as_text(status))
    return 1 if status["errors"] and not rows(status) else 0


if __name__ == "__main__":
    sys.exit(main())
