#!/usr/bin/env python3
"""
Puts a new KultrDL release into the AltStore / SideStore source kept in a
GitHub gist (the one Kultr is in).

Run by the iOS workflow after a release is published. It finds KultrDL in
the gist's JSON file (by bundle identifier, or by name) and adds the new
version at the top of its `versions` list. When KultrDL isn't in the source
yet, it is added, shaped like the other apps there (Kultr's entry is the
template: the same fields, in the same order). Everything else in the file
is left as it is.

Environment:
  GIST_TOKEN   a token that may edit the gist (classic token, "gist" scope)
  GIST_ID      the gist's id (the last part of its address)
  VERSION      e.g. 1.0.0
  BUILD        the build number
  NOTES_FILE   the release notes (Markdown); the part before "## Install" is used
  IPA          path to the built KultrDL.ipa, for its size
  REPOSITORY   owner/repo, for the download address
  SOURCE_FILE  optional: the source file to add KultrDL to when several could take it
  DEVELOPER_NAME  optional: the developer name shown for KultrDL
  APP_DETAILS  optional: a JSON file whose fields (subtitle, description, screenshots…) are copied onto KultrDL
"""

import copy
import datetime
import json
import os
import re
import sys
import urllib.request

BUNDLE_ID = "app.kultr.dl"
NAME = "KultrDL"
MIN_OS = "17.0"


def api(method, url, token, body=None):
    request = urllib.request.Request(url, method=method, data=None if body is None else json.dumps(body).encode())
    request.add_header("Authorization", f"Bearer {token}")
    request.add_header("Accept", "application/vnd.github+json")
    request.add_header("User-Agent", "KultrDL-iOS-release")
    if body is not None:
        request.add_header("Content-Type", "application/json")
    with urllib.request.urlopen(request) as response:
        return json.load(response)


def plain_notes(path):
    """The release notes as AltStore shows them: plain text, up to the Install section."""
    try:
        text = open(path, encoding="utf-8").read()
    except OSError:
        return ""
    text = text.split("## Install")[0]
    lines = []
    for line in text.splitlines():
        if line.startswith("#"):
            continue
        line = re.sub(r"\[([^\]]+)\]\(([^)]+)\)", r"\1 (\2)", line)
        line = line.replace("**", "").replace("`", "")
        line = re.sub(r"^- ", "• ", line)
        lines.append(line.rstrip())
    return "\n".join(lines).strip()


def is_kultrdl(app):
    bundle = str(app.get("bundleIdentifier", ""))
    return bundle == BUNDLE_ID or bundle.startswith(BUNDLE_ID + ".") or str(app.get("name", "")).strip().lower() == "kultrdl"


def is_kultr(app):
    bundle = str(app.get("bundleIdentifier", ""))
    return bundle == "app.kultr.ios" or str(app.get("name", "")).strip().lower() == "kultr"


def details():
    path = os.environ.get("APP_DETAILS", "")
    if path and os.path.exists(path):
        with open(path, encoding="utf-8") as f:
            return json.load(f)
    return {}


def apply_release(app, entry):
    """The store page from the repository, and the new version at the top of the list."""
    app.update(details())
    developer = os.environ.get("DEVELOPER_NAME", "").strip()
    if developer:
        app["developerName"] = developer
    if isinstance(app.get("versions"), list):
        app["versions"] = [entry] + [v for v in app["versions"] if v.get("version") != entry["version"]]
    legacy = {
        "version": entry["version"],
        "versionDate": entry["date"],
        "versionDescription": entry["localizedDescription"],
        "downloadURL": entry["downloadURL"],
        "size": entry["size"],
    }
    for key, value in legacy.items():
        if key in app or "versions" not in app:
            app[key] = value


def new_app(template, entry):
    """KultrDL shaped like [template] (another app in the source): its fields, in its order."""
    info = details()
    fresh = {
        "name": NAME,
        "bundleIdentifier": BUNDLE_ID,
        "developerName": os.environ.get("DEVELOPER_NAME", "").strip() or (template or {}).get("developerName", "evropiani"),
        "subtitle": info.get("subtitle", ""),
        "localizedDescription": info.get("localizedDescription", ""),
        "iconURL": info.get("iconURL", ""),
        "tintColor": info.get("tintColor", "#7c6fd6"),
        "category": info.get("category", "entertainment"),
        "screenshots": info.get("screenshots", []),
        "screenshotURLs": info.get("screenshotURLs", []),
        "versions": [entry],
        "version": entry["version"],
        "versionDate": entry["date"],
        "versionDescription": entry["localizedDescription"],
        "downloadURL": entry["downloadURL"],
        "size": entry["size"],
        "appPermissions": info.get("appPermissions", {"entitlements": [], "privacy": {}}),
    }
    if not template:
        # No other app to copy the shape of: the current AltStore format.
        keep = ["name", "bundleIdentifier", "developerName", "subtitle", "localizedDescription", "iconURL",
                "tintColor", "category", "screenshots", "versions", "appPermissions"]
        return {key: fresh[key] for key in keep}
    app = {}
    for key in template:
        if key in fresh:
            app[key] = fresh[key]
    # What the template has no place for but AltStore needs.
    for key in ("name", "bundleIdentifier", "developerName", "localizedDescription", "iconURL"):
        app.setdefault(key, fresh[key])
    if "versions" not in template and "downloadURL" not in template:
        app["versions"] = [entry]
    for key in ("subtitle", "screenshots", "tintColor"):
        if key in template or fresh.get(key):
            app.setdefault(key, fresh[key])
    return app


def indent_of(text):
    match = re.search(r'\n( +)"', text)
    return len(match.group(1)) if match else 2


def main():
    token = os.environ.get("GIST_TOKEN", "")
    gist_id = os.environ.get("GIST_ID", "").strip().rstrip("/").split("/")[-1]
    if not token or not gist_id:
        print("No GIST_TOKEN secret or gist id set up; the source gist is not updated.")
        return 0

    version = os.environ["VERSION"]
    repository = os.environ["REPOSITORY"]
    entry = {
        "version": version,
        "buildVersion": os.environ.get("BUILD", ""),
        "date": datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "localizedDescription": plain_notes(os.environ.get("NOTES_FILE", "")),
        "downloadURL": f"https://github.com/{repository}/releases/download/v{version}/KultrDL.ipa",
        "size": os.path.getsize(os.environ["IPA"]),
        "minOSVersion": MIN_OS,
    }

    wanted_name = os.environ.get("SOURCE_FILE", "").strip()
    gist = api("GET", f"https://api.github.com/gists/{gist_id}", token)
    sources = {}
    for name, file in gist.get("files", {}).items():
        content = file.get("content") or ""
        if file.get("truncated") and file.get("raw_url"):
            with urllib.request.urlopen(file["raw_url"]) as response:
                content = response.read().decode("utf-8")
        try:
            source = json.loads(content)
        except ValueError:
            continue
        if isinstance(source, dict) and isinstance(source.get("apps"), list):
            sources[name] = (content, source)
    if not sources:
        print("The gist has no AltStore source file.", file=sys.stderr)
        return 1

    changed = {}
    has_kultrdl = [name for name, (_, s) in sources.items() if any(is_kultrdl(a) for a in s["apps"])]
    targets = has_kultrdl or [
        next((n for n in sources if n == wanted_name), None)
        or next((n for n, (_, s) in sources.items() if any(is_kultr(a) for a in s["apps"])), None)
        or next(iter(sources))
    ]
    for name in targets:
        content, source = sources[name]
        apps = source["apps"]
        found = False
        for app in apps:
            if is_kultrdl(app):
                apply_release(app, entry)
                found = True
        if not found:
            template = next((a for a in apps if is_kultr(a)), apps[0] if apps else None)
            app = new_app(copy.deepcopy(template) if template else None, entry)
            at = next((i + 1 for i, a in enumerate(apps) if is_kultr(a)), len(apps))
            apps.insert(at, app)
            print(f"Added {NAME} to {name}.")
        text = json.dumps(source, indent=indent_of(content), ensure_ascii=False)
        if content.endswith("\n"):
            text += "\n"
        if text != content:
            changed[name] = {"content": text}

    if not changed:
        print(f"{NAME} {version} was already in the source.")
        return 0
    api("PATCH", f"https://api.github.com/gists/{gist_id}", token, {"files": changed})
    for name in changed:
        print(f"Updated {name} in gist {gist_id} to {NAME} {version}.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
