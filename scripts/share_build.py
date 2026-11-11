#!/usr/bin/env python3
"""Shares a build's IPAs: uploads them to Atelier's website, which keeps them
for 7 days for Safari and Atelier's install links, and records the build
there (infra/website/src/builds.js). Runs in the build job of
.github/workflows/build.yml, and proves to the website which repo, workflow
and run it is with the OpenID Connect token GitHub gives a job that has
`id-token: write`, so there's no key to keep. Pull requests from forks get
no such token, so their builds aren't shared, which isn't an error.

The run's log and summary show the unsigned IPA's links only, as anyone can
read a public repo's logs, and the signed IPA's profile lists the
maintainer's iPhones. The website's KV namespace, BUILDS, has the whole
record, signed IPA included, under commit/<commit>, branch/<branch> and
pr/<number>.

Usage:
  python3 scripts/share_build.py --site https://atelierstore.app --commit <sha> \\
      [--signed Atelier.ipa] [--unsigned Atelier-unsigned.ipa]

A file that doesn't exist is left out, as the signed IPA is when the run
has no signing secrets. Exits 1 when sharing failed.
"""

import argparse
import json
import os
import pathlib
import sys
import urllib.error
import urllib.parse
import urllib.request

# The names the website keeps a build's files under.
SIGNED = "Atelier.ipa"
UNSIGNED = "Atelier-unsigned.ipa"


class Error(Exception):
    pass


def send(method, url, headers, data=None, timeout=60):
    """The answer to one request, as (status, body)."""
    request = urllib.request.Request(url, data=data, method=method, headers={"User-Agent": "atelier-ci", **headers})
    try:
        with urllib.request.urlopen(request, timeout=timeout) as response:
            return response.status, response.read()
    except urllib.error.HTTPError as error:
        return error.code, error.read()
    except (urllib.error.URLError, TimeoutError) as error:
        raise Error(f"{url} can't be reached: {getattr(error, 'reason', error)}") from None


def answer(status, body, what):
    """The JSON of a 200 or 201, or an Error that says what the site said."""
    try:
        value = json.loads(body) if body else None
    except ValueError:
        value = None
    if status not in (200, 201):
        said = value.get("error") if isinstance(value, dict) else body[:200].decode(errors="replace")
        raise Error(f"{what}: HTTP {status}: {said}")
    if value is None:
        raise Error(f"{what}: the answer isn't JSON")
    return value


def oidc_token(audience):
    """A token GitHub signed for this job and `audience`, or None when the job
    can't have one."""
    url = os.environ.get("ACTIONS_ID_TOKEN_REQUEST_URL")
    request_token = os.environ.get("ACTIONS_ID_TOKEN_REQUEST_TOKEN")
    if not url or not request_token:
        return None
    separator = "&" if urllib.parse.urlsplit(url).query else "?"
    status, body = send("GET", f"{url}{separator}audience={urllib.parse.quote(audience, safe='')}",
                        {"Authorization": f"bearer {request_token}", "Accept": "application/json"})
    token = answer(status, body, "Asking GitHub for the job's token").get("value")
    if not token:
        raise Error("GitHub gave no token")
    return token


def upload(site, token, path, name):
    """Uploads the IPA at `path` as `name`, and returns the site's {url,
    expires}."""
    with open(path, "rb") as file:
        status, body = send("POST", f"{site}/builds/{name}", {
            "Authorization": f"Bearer {token}",
            "Content-Type": "application/octet-stream",
            "Content-Length": str(os.fstat(file.fileno()).st_size),
        }, data=file, timeout=300)
    return answer(status, body, f"Uploading {name}")


def record(site, token, commit, files):
    """Records the build, `files` being (name, url, signed) for each, and
    returns the site's record of it."""
    body = json.dumps({"commit": commit, "files": [{"url": url, "signed": signed} for _, url, signed in files]}).encode()
    status, payload = send("POST", f"{site}/builds", {
        "Authorization": f"Bearer {token}",
        "Content-Type": "application/json",
    }, data=body)
    return answer(status, payload, "Recording the build")


def public_summary(build):
    """What the run's log and summary show of the build: never the signed
    IPA's links."""
    lines = [f"Atelier {build.get('version') or '?'} ({build.get('build') or '?'}), "
             f"kept on the website until {build.get('expires', '?')}."]
    for file in build.get("files", []):
        if file.get("signed"):
            lines.append(f"- {file['name']}, signed: its links are only in the website's build records, "
                         "as its profile lists the maintainer's iPhones.")
        else:
            lines.append(f"- {file['name']}: {file['url']}")
    if build.get("install"):
        lines.append(f"- Install it with Atelier: {build['install']}")
    return lines


def site_origin(site):
    parts = urllib.parse.urlsplit(site)
    if parts.scheme != "https" or not parts.netloc or parts.path not in ("", "/") or parts.query or parts.fragment:
        raise Error(f"--site isn't a site's https:// address: {site}")
    return f"{parts.scheme}://{parts.netloc}"


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument("--site", required=True)
    parser.add_argument("--commit", required=True)
    parser.add_argument("--signed", default=SIGNED)
    parser.add_argument("--unsigned", default=UNSIGNED)
    args = parser.parse_args(argv)
    try:
        site = site_origin(args.site)
        files = [(path, name, signed) for path, name, signed in [
            (pathlib.Path(args.signed), SIGNED, True),
            (pathlib.Path(args.unsigned), UNSIGNED, False),
        ] if path.is_file()]
        if not files:
            raise Error("there's no IPA to share")
        token = oidc_token(site)
        if token is None:
            print("This job can't prove which repo it's from (a pull request from a fork has no GitHub token for it), "
                  "so its IPAs aren't shared.")
            return 0
        uploaded = [(name, upload(site, token, path, name)["url"], signed) for path, name, signed in files]
        build = record(site, token, args.commit, uploaded)
    except Error as error:
        print(f"::warning::The IPAs weren't shared: {error}")
        return 1

    lines = public_summary(build)
    print("\n".join(lines))
    summary = os.environ.get("GITHUB_STEP_SUMMARY")
    if summary:
        with open(summary, "a") as out:
            out.write("### Build links\n\n" + "\n".join(lines) + "\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())
