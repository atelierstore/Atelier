#!/usr/bin/env python3
"""Publishes a release of Atelier (#23): a GitHub Release for the tag with the
unsigned IPA, then the app icon, the screenshots and the updated source.json on
the repo's `source` branch. In that order, so the source never lists an IPA or
a screenshot that isn't there yet; screenshots it no longer lists are removed
after it. The branch only holds what the source serves, so release commits
never land on main; the first release creates it.

A release starts with its notes, release/notes/<tag>.md: once they're on main,
`tag` creates the tag on the commit that last changed them, and the release
workflow (.github/workflows/release.yml) builds and publishes the tag. The
notes mention, as #N, every pull request merged into main since the last
release, except ones that only changed release notes or changed a release's:
check-notes checks that on a pull request that changes them, and tag checks it
again before tagging. Until then they gather in release/notes/next.md, which
isn't named after a tag, so it never starts a release: each pull request adds
its line there, and check-notes --pr checks that next.md mentions it and every
pull request merged into main since the last release.

The token needs Contents read and write on this repo only, which covers
releases, tags and commits: in GitHub Actions, the workflow's own token with
`contents: write`; elsewhere, a fine-grained token. It comes from the
GITHUB_TOKEN environment variable (or GITHUB_RELEASES_TOKEN), never the
command line, so it stays out of build logs. check-notes only reads the git
history and needs no token. In GitHub Actions, tag also writes the tag it
created to the step's outputs, as `tag`.

Usage:
  python3 scripts/publish_release.py check-notes [--notes release/notes] [--main origin/main] [--pr N]
  python3 scripts/publish_release.py tag --repo OWNER/NAME [--notes release/notes]
  python3 scripts/publish_release.py fetch-source --repo OWNER/NAME --output published.json
  python3 scripts/publish_release.py release-notes --repo OWNER/NAME --tag v0.1.0 --output notes.md
  python3 scripts/publish_release.py publish --repo OWNER/NAME --tag v0.1.0 \\
      --ipa Atelier-0.1.0.ipa --source source.json [--notes notes.md] [--icon icon.png] \\
      [--screenshots release/screenshots]

tag does nothing when every release in the notes folder has its tag, and
refuses when more than one hasn't, so each release is the commit its notes
came with. fetch-source writes nothing and exits 0 when there's no source.json
yet (the first release). release-notes writes the text of the tag's GitHub
Release, for a release made on GitHub's site, whose tag has no message; nothing
when there's no release or no text. Running publish again for the same tag
reuses its release and replaces the IPA, so a failed build can be retried.
"""

import argparse
import base64
import hashlib
import json
import os
import pathlib
import re
import subprocess
import sys
import urllib.error
import urllib.parse
import urllib.request

API = "https://api.github.com"
UPLOADS = "https://uploads.github.com"
# Atelier reads its own source at SOURCE_BRANCH/SOURCE_PATH to update itself
# (SelfUpdate.sourceURL in the app, #24), and builds already installed keep
# reading it there: moving either breaks their self-updates.
SOURCE_BRANCH = "source"
SOURCE_PATH = "source.json"
# SOURCE_BRANCH, SOURCE_PATH and ICON_PATH make up the URLs in
# release/source-template.json and docs/install.md.
ICON_PATH = "icon.png"
# SOURCE_BRANCH and SCREENSHOTS_PATH make up the --screenshots-url the
# release workflow gives update_source.py.
SCREENSHOTS_PATH = "screenshots"
NOTES_DIR = "release/notes"
# The next release's notes, which pull requests add their lines to as they're
# merged, and which become release/notes/<tag>.md when it's released. Not
# being named after a tag, they never start a release themselves.
NEXT_NOTES = "next.md"
# What the release workflow accepts: vMAJOR.MINOR.PATCH, optionally with a
# pre-release suffix such as -alpha.
TAG = re.compile(r"v[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.]+)?")
# How GitHub names a pull request's merge commit, or its squashed commit.
PULL_REQUEST = re.compile(r"^Merge pull request #([0-9]+) |\(#([0-9]+)\)$")


class Error(Exception):
    pass


def request(method, url, token, body=None, content_type="application/json", accept="application/vnd.github+json"):
    data = None
    if body is not None:
        data = body if isinstance(body, bytes) else json.dumps(body).encode()
    req = urllib.request.Request(url, data=data, method=method, headers={
        "Accept": accept,
        "Authorization": f"Bearer {token}",
        "X-GitHub-Api-Version": "2022-11-28",
        "User-Agent": "atelier-release",
        **({"Content-Type": content_type} if data is not None else {}),
    })
    try:
        with urllib.request.urlopen(req) as response:
            payload = response.read()
            return response.status, payload
    except urllib.error.HTTPError as error:
        return error.code, error.read()


def checked(status, payload, what, ok=(200, 201)):
    if status not in ok:
        raise Error(f"{what}: HTTP {status}: {payload[:500].decode(errors='replace')}")
    return json.loads(payload) if payload else None


def fetch_file(repo, path, token):
    """A file on SOURCE_BRANCH and its blob SHA, or (None, None) when it or the
    branch doesn't exist."""
    status, payload = request("GET", f"{API}/repos/{repo}/contents/{path}?ref={SOURCE_BRANCH}", token)
    if status == 404:
        return None, None
    file = checked(status, payload, f"reading {path}")
    return base64.b64decode(file["content"]), file["sha"]


def put_file(repo, path, content, message, token):
    """Commits the file unless it's already there as it is."""
    current, sha = fetch_file(repo, path, token)
    if current == content:
        return
    commit_file(repo, path, content, sha, message, token)


def commit_file(repo, path, content, sha, message, token):
    """Commits the file to SOURCE_BRANCH; sha is the one it replaces, if any."""
    body = {
        "message": message,
        "content": base64.b64encode(content).decode(),
        "branch": SOURCE_BRANCH,
        **({"sha": sha} if sha else {}),
    }
    checked(*request("PUT", f"{API}/repos/{repo}/contents/{path}", token, body), f"writing {path}")


def blob_sha(content):
    """The SHA GitHub lists for a file with this content: its git blob's."""
    return hashlib.sha1(b"blob %d\0" % len(content) + content).hexdigest()


def folder(repo, path, token):
    """The files in a folder on SOURCE_BRANCH, by name, with their SHAs, or
    nothing when it or the branch doesn't exist."""
    status, payload = request("GET", f"{API}/repos/{repo}/contents/{path}?ref={SOURCE_BRANCH}", token)
    if status == 404:
        return {}
    entries = checked(status, payload, f"listing {path}")
    if not isinstance(entries, list):
        raise Error(f"{path} on {SOURCE_BRANCH} isn't a folder")
    return {entry["name"]: entry["sha"] for entry in entries if entry.get("type") == "file"}


def put_screenshots(repo, screenshots, message, token):
    """Commits the PNGs in the screenshots folder to SCREENSHOTS_PATH, each
    unless it's already there as it is, and returns the ones there the folder
    no longer has, by name, with their SHAs."""
    published = folder(repo, SCREENSHOTS_PATH, token)
    names = set()
    for path in sorted(pathlib.Path(screenshots).glob("*.png")):
        names.add(path.name)
        content = path.read_bytes()
        if published.get(path.name) != blob_sha(content):
            commit_file(repo, f"{SCREENSHOTS_PATH}/{path.name}", content, published.get(path.name), message, token)
    return {name: sha for name, sha in published.items() if name not in names}


def delete_file(repo, path, sha, message, token):
    body = {"message": message, "sha": sha, "branch": SOURCE_BRANCH}
    checked(*request("DELETE", f"{API}/repos/{repo}/contents/{path}", token, body), f"removing {path}")


def ensure_source_branch(repo, token):
    """Creates SOURCE_BRANCH as a commit with no parent, so it shares no
    history with main, unless it exists."""
    status, payload = request("GET", f"{API}/repos/{repo}/git/ref/heads/{SOURCE_BRANCH}", token)
    if status == 200:
        return
    checked(status, payload, f"looking up branch {SOURCE_BRANCH}", ok=(404,))
    readme = "Atelier's AltStore source and icon, written by each release (scripts/publish_release.py on main).\n"
    tree = checked(*request("POST", f"{API}/repos/{repo}/git/trees", token, {
        "tree": [{"path": "README.md", "mode": "100644", "type": "blob", "content": readme}],
    }), f"creating branch {SOURCE_BRANCH}")
    commit = checked(*request("POST", f"{API}/repos/{repo}/git/commits", token, {
        "message": f"Start the {SOURCE_BRANCH} branch", "tree": tree["sha"], "parents": [],
    }), f"creating branch {SOURCE_BRANCH}")
    checked(*request("POST", f"{API}/repos/{repo}/git/refs", token, {
        "ref": f"refs/heads/{SOURCE_BRANCH}", "sha": commit["sha"],
    }), f"creating branch {SOURCE_BRANCH}")


def tag_exists(repo, tag, token):
    status, payload = request("GET", f"{API}/repos/{repo}/git/ref/tags/{urllib.parse.quote(tag)}", token)
    if status == 404:
        return False
    checked(status, payload, f"looking up tag {tag}")
    return True


def git(directory, *args):
    result = subprocess.run(["git", "-C", str(directory), *args], capture_output=True, text=True)
    if result.returncode != 0:
        raise Error(f"git {' '.join(args)}: {result.stderr.strip()}")
    return result.stdout.strip()


def check_name(path):
    if not TAG.fullmatch(path.stem):
        raise Error(f"{path} isn't named after a release's tag, such as v0.2.0.md or v0.2.0-alpha.md")


def numbers(pull_requests):
    return ", ".join(f"#{number}" for number in pull_requests)


def changed_in(path):
    """The commit on the current branch that last changed the file.
    --first-parent keeps to the branch's own commits, so for a pull request
    merged into main it's the merge, not the pull request's commit."""
    path = pathlib.Path(path)
    commit = git(path.parent, "log", "--first-parent", "--format=%H", "-1", "--", path.name)
    if not commit:
        raise Error(f"{path} isn't committed")
    return commit


def only_notes(directory, files):
    """Whether `files`, paths from the repo's root as git names them, change
    nothing but release notes in `directory`, or change a release's notes:
    pull requests that do needn't be mentioned in them. One that adds a line
    to next.md with other changes does, as next.md is where it says so."""
    directory = pathlib.Path(directory).resolve()
    root = pathlib.Path(git(directory, "rev-parse", "--show-toplevel")).resolve()
    notes = [path for path in files if (root / path).resolve().parent == directory]
    releases = [path for path in notes if TAG.fullmatch(pathlib.PurePath(path).stem)]
    return bool(releases) or (bool(files) and len(notes) == len(files))


def merged_files(directory, commit):
    """The files the merge `commit` changed, as git names them."""
    return git(directory, "diff", "--name-only", "--no-renames", f"{commit}^1", commit).splitlines()


def unmentioned(notes, until):
    """The last release before `until`, and the pull requests merged since,
    up to `until`, that the notes don't mention as #N, oldest first. Pull
    requests that only changed release notes, or changed a release's, needn't
    be mentioned (only_notes). With no release before `until`, (None, []).
    Notes that don't exist yet, such as a new next.md, mention none."""
    notes = pathlib.Path(notes)
    git(notes.parent, "rev-parse", "--verify", f"{until}^{{commit}}")
    if git(notes.parent, "rev-parse", "--is-shallow-repository") == "true":
        raise Error("checking the notes needs the whole history: git fetch --unshallow --tags origin")
    try:
        since = git(notes.parent, "describe", "--tags", "--abbrev=0", "--match", "v[0-9]*.[0-9]*.[0-9]*", until)
    except Error:
        return None, []
    changed_notes = set(git(notes.parent, "log", "--first-parent", "--format=%H", f"{since}..{until}", "--", ".").split())
    mentioned = mentions(notes)
    missing = []
    for line in git(notes.parent, "log", "--first-parent", "--reverse", "--format=%H %s", f"{since}..{until}").splitlines():
        commit, _, subject = line.partition(" ")
        match = PULL_REQUEST.search(subject)
        number = int(match.group(1) or match.group(2)) if match else None
        if not number or number in mentioned:
            continue
        if commit in changed_notes and only_notes(notes.parent, merged_files(notes.parent, commit)):
            continue
        missing.append(number)
    return since, missing


def mentions(notes):
    """The pull requests the notes mention as #N; none when they don't
    exist."""
    notes = pathlib.Path(notes)
    return {int(number) for number in re.findall(r"#([0-9]+)\b", notes.read_text())} if notes.exists() else set()


def check_notes(notes_dir, main, pull_request=None):
    """Checks the notes this branch adds or changes, of releases that aren't
    tagged yet, against `main`: returns each one's path, the last release and
    the pull requests merged into `main` since that it doesn't mention. When
    it adds none, checks next.md instead, if it's there or the branch is
    `pull_request`: it has to mention the pull requests merged into `main`
    since the last release, and `pull_request` itself, unless that only
    changes release notes."""
    notes_dir = pathlib.Path(notes_dir)
    if not notes_dir.is_dir():
        return []
    results = releases_notes(notes_dir, main)
    next_notes = notes_dir / NEXT_NOTES
    if results or not (pull_request or next_notes.exists()):
        return results
    since, missing = unmentioned(next_notes, main)
    changed = git(notes_dir, "diff", "--name-only", "--no-renames", f"{main}...HEAD").splitlines()
    if pull_request and pull_request not in mentions(next_notes) and not only_notes(notes_dir, changed):
        missing.append(pull_request)
    return [(next_notes, since, missing)]


def releases_notes(notes_dir, main):
    """check_notes for the notes of releases that aren't tagged yet."""
    results = []
    for name in git(notes_dir, "diff", "--name-only", "--relative", f"{main}...HEAD", "--", ".").splitlines():
        path = notes_dir / name
        if not re.fullmatch(r"v[^/]*\.md", name) or not path.exists():
            continue
        check_name(path)
        if git(notes_dir, "tag", "--list", path.stem):
            continue
        results.append((path, *unmentioned(path, main)))
    return results


def tag_release(repo, notes_dir, token):
    """Tags the commit that last changed the notes of the release with no tag
    yet, and returns (tag, commit), or None when every release has its tag.
    Refuses when the notes don't mention a pull request merged before that
    commit."""
    untagged = []
    for path in sorted(pathlib.Path(notes_dir).glob("v*.md")):
        check_name(path)
        if not tag_exists(repo, path.stem, token):
            untagged.append(path)
    if not untagged:
        return None
    if len(untagged) > 1:
        names = ", ".join(path.name for path in untagged)
        raise Error(f"{names} have no tags yet: add one release's notes at a time, or tag all but one by hand")
    path = untagged[0]
    commit = changed_in(path)
    since, missing = unmentioned(path, f"{commit}^")
    if missing:
        raise Error(f"{path.name} doesn't mention {numbers(missing)}, merged since {since}, so {path.stem} isn't "
                    f"tagged. Mention them as #N in the notes, in a pull request: merging it tags the release.")
    checked(*request("POST", f"{API}/repos/{repo}/git/refs", token, {
        "ref": f"refs/tags/{path.stem}", "sha": commit,
    }), f"creating tag {path.stem}")
    return path.stem, commit


def release_notes(repo, tag, token):
    status, payload = request("GET", f"{API}/repos/{repo}/releases/tags/{urllib.parse.quote(tag)}", token)
    if status == 404:
        return None
    return checked(status, payload, f"looking up release {tag}").get("body") or None


def release_for(repo, tag, token, notes):
    status, payload = request("GET", f"{API}/repos/{repo}/releases/tags/{urllib.parse.quote(tag)}", token)
    if status == 200:
        return json.loads(payload)
    checked(status, payload, f"looking up release {tag}", ok=(404,))
    body = {"tag_name": tag, "name": f"Atelier {tag.removeprefix('v')}", "body": notes or "", "prerelease": "-" in tag}
    return checked(*request("POST", f"{API}/repos/{repo}/releases", token, body), f"creating release {tag}")


def upload(repo, release, ipa, token):
    name = pathlib.Path(ipa).name
    for asset in release.get("assets", []):
        if asset["name"] == name:
            checked(*request("DELETE", f"{API}/repos/{repo}/releases/assets/{asset['id']}", token),
                    f"replacing {name}", ok=(204,))
    url = f"{UPLOADS}/repos/{repo}/releases/{release['id']}/assets?name={urllib.parse.quote(name)}"
    asset = checked(*request("POST", url, token, pathlib.Path(ipa).read_bytes(), "application/octet-stream"),
                    f"uploading {name}")
    return asset["browser_download_url"]


def publish(repo, tag, ipa, source, token, notes=None, icon=None, screenshots=None):
    release = release_for(repo, tag, token, notes)
    download_url = upload(repo, release, ipa, token)
    print(f"Uploaded {download_url}")
    message = f"Atelier {tag.removeprefix('v')}"
    ensure_source_branch(repo, token)
    if icon:
        put_file(repo, ICON_PATH, pathlib.Path(icon).read_bytes(), message, token)
    removed = put_screenshots(repo, screenshots, message, token) if screenshots else {}
    put_file(repo, SOURCE_PATH, pathlib.Path(source).read_bytes(), message, token)
    for name, sha in sorted(removed.items()):
        delete_file(repo, f"{SCREENSHOTS_PATH}/{name}", sha, message, token)
    print(f"Updated {SOURCE_PATH}: https://raw.githubusercontent.com/{repo}/{SOURCE_BRANCH}/{SOURCE_PATH}")
    print(f"Release: {release['html_url']}")


def step_output(name, value):
    """Sets a GitHub Actions step output, when running in one."""
    path = os.environ.get("GITHUB_OUTPUT")
    if path:
        with open(path, "a") as outputs:
            outputs.write(f"{name}={value}\n")

def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    commands = parser.add_subparsers(dest="command", required=True)
    check = commands.add_parser("check-notes")
    check.add_argument("--notes", default=NOTES_DIR, help=f"the release notes folder (default {NOTES_DIR})")
    check.add_argument("--main", default="origin/main", help="the branch the notes have to cover (default origin/main)")
    check.add_argument("--pr", type=int, help=f"the pull request this branch is, which {NEXT_NOTES} has to mention")
    tag = commands.add_parser("tag")
    tag.add_argument("--repo", required=True)
    tag.add_argument("--notes", default=NOTES_DIR, help=f"the release notes folder (default {NOTES_DIR})")
    fetch = commands.add_parser("fetch-source")
    fetch.add_argument("--repo", required=True)
    fetch.add_argument("--output", required=True)
    notes = commands.add_parser("release-notes")
    notes.add_argument("--repo", required=True)
    notes.add_argument("--tag", required=True)
    notes.add_argument("--output", required=True)
    pub = commands.add_parser("publish")
    pub.add_argument("--repo", required=True)
    pub.add_argument("--tag", required=True)
    pub.add_argument("--ipa", required=True)
    pub.add_argument("--source", required=True)
    pub.add_argument("--notes")
    pub.add_argument("--icon", help=f"published as {ICON_PATH} when it changed")
    pub.add_argument("--screenshots", help=f"a folder whose PNGs are published in {SCREENSHOTS_PATH}/, "
                                           "where the ones it no longer has are removed")
    args = parser.parse_args(argv)

    token = os.environ.get("GITHUB_TOKEN") or os.environ.get("GITHUB_RELEASES_TOKEN")
    if not token and args.command != "check-notes":
        print("error: GITHUB_TOKEN isn't set (the release workflows set it to their own token)", file=sys.stderr)
        return 2
    try:
        if args.command == "check-notes":
            results = check_notes(args.notes, args.main, args.pr)
            for path, since, missing in results:
                if missing and path.name == NEXT_NOTES:
                    named = ", ".join(f"#{number}" + (" (this pull request)" if number == args.pr else "")
                                      for number in missing)
                    print(f"error: {path} doesn't mention {named}. Add a line for each to the "
                          f"section it belongs in, ending with its number as #N (docs/install.md).", file=sys.stderr)
                elif missing:
                    print(f"error: {path} doesn't mention {numbers(missing)}, merged into {args.main} since {since}. "
                          f"Mention them as #N in the notes.", file=sys.stderr)
                elif path.name == NEXT_NOTES:
                    covered = f"merged into {args.main} since {since}" if since else f"on {args.main}"
                    also = ", and this one" if args.pr else ""
                    print(f"{path} covers every pull request {covered}{also}.")
                elif since:
                    print(f"{path} mentions every pull request merged into {args.main} since {since}.")
                else:
                    print(f"{path} is the first release's: there's nothing before it to check.")
            if not results:
                print("This branch adds no notes for a release that isn't tagged yet.")
            return 1 if any(missing for _, _, missing in results) else 0
        if args.command == "tag":
            tagged = tag_release(args.repo, args.notes, token)
            if tagged:
                print(f"Tagged {tagged[1][:7]} as {tagged[0]}: the release workflow builds and publishes it.")
                step_output("tag", tagged[0])
            else:
                print(f"Every release in {args.notes} has its tag: nothing to release.")
        elif args.command == "fetch-source":
            content, _ = fetch_file(args.repo, SOURCE_PATH, token)
            if content is None:
                print(f"{args.repo} has no {SOURCE_PATH} yet: this is the first release.")
            else:
                pathlib.Path(args.output).write_bytes(content)
        elif args.command == "release-notes":
            text = release_notes(args.repo, args.tag, token)
            if text:
                pathlib.Path(args.output).write_text(text.replace("\r\n", "\n").strip() + "\n")
        else:
            notes = pathlib.Path(args.notes).read_text() if args.notes else None
            publish(args.repo, args.tag, args.ipa, args.source, token, notes, args.icon, args.screenshots)
    except Error as error:
        print(f"error: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
