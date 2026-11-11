#!/usr/bin/env python3
"""Adds a release of Atelier to Atelier's own AltStore source (#23), so
Atelier can update itself (#24) and other AltStore-compatible apps can list it.

Reads the bundle ID, version, build number, minimum iOS version and privacy
usage descriptions from the IPA's Info.plist, so the source can't disagree with
the app it points at, and adds its size and SHA-256.

The source's own fields and the app's description come from
release/source-template.json; the versions come from the published source.json,
so earlier releases stay listed. Only the notes' first paragraph goes in, as
plain text. The new version goes first. Publishing the
same version and build again replaces its entry.

Each release listed also gets a news item, "Atelier 0.2.0 is out" with its
What's New, which apps show with Atelier's button to get or open it. The
template's news goes after them, and an item there with a release's
identifier, such as release-0.2.0, replaces that release's.

The app's screenshots are the PNGs in --screenshots (release/screenshots), in
the order of their names, with the size each file has. publish_release.py
publishes that folder at --screenshots-url. Each URL ends in a hash of its
file, so an app that keeps images by URL, as Atelier does, loads a screenshot
again once it's replaced.

Usage:
  python3 scripts/update_source.py --ipa Atelier-unsigned.ipa \\
      --version 0.1.0 --download-url https://…/Atelier-unsigned.ipa \\
      [--published source.json] [--notes notes.md] [--date 2026-10-22T12:00:00Z] \\
      [--screenshots release/screenshots --screenshots-url https://…/screenshots/] \\
      --output source.json

--version is the tag without its "v". A pre-release tag such as v0.1.0-alpha
lists version 0.1.0, which the IPA must have (iOS wants plain numbers there,
and AltStore checks the IPA against the source), shown as 0.1.0-alpha
(marketingVersion), with the app marked beta while it's the newest release.
"""

import argparse
import datetime
import hashlib
import json
import pathlib
import plistlib
import re
import struct
import sys
import zipfile

# The app's bundleIdentifier in the template, com.atelier.app, is the one
# Atelier looks for in its own source to update itself
# (SelfUpdate.sourceBundleID in the app, #24), and builds already installed
# keep looking for it. JSON takes no comments, so it's noted here.
TEMPLATE = pathlib.Path(__file__).resolve().parent.parent / "release" / "source-template.json"
INFO_PLIST = re.compile(r"^Payload/[^/]+\.app/Info\.plist$")
PNG = b"\x89PNG\r\n\x1a\n"
# A screenshot's name goes into its URL as it is.
SCREENSHOT_NAME = re.compile(r"[A-Za-z0-9][A-Za-z0-9._-]*\.png")


class Error(Exception):
    pass


def summary(notes):
    """The notes' first paragraph as plain text, for the source's "What's
    New": Atelier shows it as plain text and only a few lines of it. The
    full notes, in Markdown, stay on the GitHub release. Headings, images,
    HTML comments and empty paragraphs are skipped."""
    text = re.sub(r"<!--.*?-->", "", notes.replace("\r\n", "\n"), flags=re.S)
    for paragraph in re.split(r"\n\s*\n", text):
        lines = [line.strip() for line in paragraph.strip().splitlines()]
        lines = [line for line in lines if line and not line.startswith("#")]
        if not lines:
            continue
        plain = " ".join(lines)
        plain = re.sub(r"!\[[^\]]*\]\([^)]*\)", "", plain)
        plain = re.sub(r"\[([^\]]+)\]\([^)]*\)", r"\1", plain)
        plain = re.sub(r"(\*\*|__|~~)(.+?)\1", r"\2", plain)
        plain = re.sub(r"(?<!\w)([*_])(?!\s)(.+?)(?<!\s)\1(?!\w)", r"\2", plain)
        plain = re.sub(r"`([^`]*)`", r"\1", plain)
        plain = re.sub(r"^(?:[-*+]|\d+\.)\s+", "", plain)
        plain = re.sub(r"\s+", " ", plain).strip()
        if plain:
            return plain
    return None


def app_info(ipa):
    """The main app's Info.plist inside the IPA."""
    with zipfile.ZipFile(ipa) as archive:
        names = [name for name in archive.namelist() if INFO_PLIST.match(name)]
        if len(names) != 1:
            raise Error(f"{ipa}: expected one Payload/*.app/Info.plist, found {len(names)}")
        return plistlib.loads(archive.read(names[0]))


def sha256(path):
    digest = hashlib.sha256()
    with open(path, "rb") as file:
        for chunk in iter(lambda: file.read(1 << 20), b""):
            digest.update(chunk)
    return digest.hexdigest()


def privacy(info):
    """AltStore's appPermissions.privacy: each usage description by key."""
    return {key: value for key, value in sorted(info.items()) if key.startswith("NS") and key.endswith("UsageDescription")}


def screenshots_in(folder, base_url):
    """The folder's PNGs as the source lists screenshots, in the order of
    their names (2-library.png before 10-settings.png), each with its size
    and its URL under base_url. None when there are none, or no folder."""
    if not base_url.startswith("https://"):
        raise Error(f"screenshots URL isn't https: {base_url}")
    base_url = base_url.rstrip("/") + "/"
    # Split at the numbers, which are every other part, to compare them as numbers.
    paths = sorted(pathlib.Path(folder).glob("*.png"),
                   key=lambda path: [int(part) if index % 2 else part for index, part in enumerate(re.split(r"([0-9]+)", path.name))])
    screenshots = []
    for path in paths:
        if not SCREENSHOT_NAME.fullmatch(path.name):
            raise Error(f"{path}: a screenshot's name goes into its URL, so it takes only letters, digits, dots, dashes and underscores")
        data = path.read_bytes()
        if data[:8] != PNG or data[12:16] != b"IHDR":
            raise Error(f"{path} isn't a PNG")
        width, height = struct.unpack(">II", data[16:24])
        screenshots.append({
            "imageURL": f"{base_url}{path.name}?v={hashlib.sha256(data).hexdigest()[:8]}",
            "width": width,
            "height": height,
        })
    return screenshots or None


def release_news(app):
    """A news item for each release of the app, from its versions, newest
    first: one per release, so a release published again with a new build
    keeps one."""
    news = {}
    for entry in app["versions"]:
        release = entry.get("marketingVersion") or entry["version"]
        news.setdefault(f"release-{release}", {
            "identifier": f"release-{release}",
            "title": f"{app['name']} {release} is out",
            "caption": entry["localizedDescription"],
            "date": entry["date"],
            # AltStore colours a news card with its item's tint only, not the source's.
            **({"tintColor": app["tintColor"]} if app.get("tintColor") else {}),
            "appID": app["bundleIdentifier"],
        })
    return list(news.values())


def update(template, published, ipa, release, download_url, notes=None, date=None, screenshots=None):
    version = release.split("-", 1)[0]
    info = app_info(ipa)
    bundle_id = info.get("CFBundleIdentifier")
    short_version = info.get("CFBundleShortVersionString")
    build = str(info.get("CFBundleVersion", ""))
    if short_version != version:
        raise Error(f"the IPA is version {short_version}, not {version}")
    if not build:
        raise Error("the IPA has no CFBundleVersion")
    if not download_url.startswith("https://"):
        raise Error(f"download URL isn't https: {download_url}")

    source = json.loads(json.dumps(template))
    apps = [app for app in source["apps"] if app["bundleIdentifier"] == bundle_id]
    if len(apps) != 1:
        raise Error(f"the template has no app with bundle ID {bundle_id}")
    app = apps[0]

    previous = []
    for published_app in (published or {}).get("apps", []):
        if published_app.get("bundleIdentifier") == bundle_id:
            previous = published_app.get("versions", [])
    previous = [v for v in previous if (v.get("version"), str(v.get("buildVersion", ""))) != (version, build)]

    entry = {
        "version": version,
        **({"marketingVersion": release} if release != version else {}),
        "buildVersion": build,
        "date": date or datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "localizedDescription": summary(notes or "") or f"Atelier {release}.",
        "downloadURL": download_url,
        "size": pathlib.Path(ipa).stat().st_size,
        "sha256": sha256(ipa),
    }
    if info.get("MinimumOSVersion"):
        entry["minOSVersion"] = info["MinimumOSVersion"]
    app["versions"] = [entry] + previous
    if screenshots:
        app["screenshots"] = screenshots
        # Apps that predate `screenshots`, such as AltStore 1, read only
        # these; AltStore's own source lists both.
        app["screenshotURLs"] = [screenshot["imageURL"] for screenshot in screenshots]
    if release != version:
        app["beta"] = True
    app["appPermissions"] = {"entitlements": [], "privacy": privacy(info)}
    news = source.get("news", [])
    by_hand = {item.get("identifier") for item in news}
    source["news"] = [item for item in release_news(app) if item["identifier"] not in by_hand] + news
    return source


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument("--ipa", required=True)
    parser.add_argument("--version", required=True)
    parser.add_argument("--download-url", required=True)
    parser.add_argument("--published", help="the source.json published now; missing or absent for the first release")
    parser.add_argument("--notes", help="a file with this release's notes")
    parser.add_argument("--date", help="ISO 8601; now when left out")
    parser.add_argument("--screenshots", help="a folder of PNGs to list as the app's screenshots, in the order of their names")
    parser.add_argument("--screenshots-url", help="where publish_release.py publishes the --screenshots folder")
    parser.add_argument("--template", default=str(TEMPLATE))
    parser.add_argument("--output", required=True)
    args = parser.parse_args(argv)
    if args.screenshots and not args.screenshots_url:
        parser.error("--screenshots needs --screenshots-url")

    template = json.loads(pathlib.Path(args.template).read_text())
    published = None
    if args.published and pathlib.Path(args.published).is_file():
        published = json.loads(pathlib.Path(args.published).read_text())
    notes = pathlib.Path(args.notes).read_text() if args.notes else None
    try:
        screenshots = screenshots_in(args.screenshots, args.screenshots_url) if args.screenshots else None
        source = update(template, published, args.ipa, args.version.removeprefix("v"), args.download_url, notes, args.date,
                        screenshots)
    except Error as error:
        print(f"error: {error}", file=sys.stderr)
        return 1
    pathlib.Path(args.output).write_text(json.dumps(source, indent=2, ensure_ascii=False) + "\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())
