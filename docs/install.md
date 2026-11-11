# Installing Atelier

Issue #23. Atelier signs and installs other apps, but it has to be signed and installed itself first. It can't be on the App Store or be an EU alternative marketplace, so the first install always happens outside Atelier, with a certificate of your own. After that, Atelier can update itself from its own source (#24), and with a free Apple ID it renews itself too once that Apple ID is signed in to it (#152).

## What you need

- **The IPA.** Each release is on [Atelier's releases page](https://github.com/atelierstore/Atelier/releases) as `Atelier-<version>.ipa`, and the website's [sideload page](https://atelierstore.app/sideload) has the newest one, with Atelier's source. It's unsigned: every method below signs it with your certificate.
- **A certificate**, one of:
  - a paid Apple Developer account (apps stay signed for a year, or until Apple revokes the certificate);
  - a certificate from a signing service (a `.p12` file, its password and a `.mobileprovision` that lists your device);
  - a free Apple ID (apps expire after 7 days and a free account can only have a few sideloaded apps at once).
- **iOS 17 or later.**

## Install with a computer

### Sideloadly (macOS, Windows)

Sideloadly signs with an Apple ID, free or paid.

1. Install [Sideloadly](https://sideloadly.io) and connect the iPhone with a cable. Trust the computer on the phone if it asks.
2. Drag `Atelier-<version>.ipa` into Sideloadly and enter your Apple ID.
3. Press Start.

Apple has been refusing some free Apple ID sign-ins from sideloading tools since about 14 October 2026 (error -80045). If yours is refused, use a certificate with an on-device signer below.

## Install on the phone

These need an app that can sign on the device and is already installed.

### Feather

1. Import your `.p12` and `.mobileprovision` in Feather's certificates.
2. Download `Atelier-<version>.ipa` in Safari and open it with Feather, or add the source below and download it there.
3. Sign it and install it.

### AltStore or SideStore

Add Atelier's source (below) and install Atelier from it, or open the IPA with AltStore or SideStore. They sign with the Apple ID they are set up with.

## Atelier's source

```
https://raw.githubusercontent.com/atelierstore/Atelier/source/source.json
```

Add it in any AltStore-compatible app to see new releases. Atelier lists itself from it once you add it in Browse.

## After installing

- iOS may ask you to trust the developer (Settings › General › VPN & Device Management) or to turn on Developer Mode (Settings › Privacy & Security › Developer Mode), depending on the certificate.
- Then set up Atelier with your certificate in Settings, so it can sign other apps.
- Installed with a free Apple ID, Atelier's own profile ends after 7 days like any app's. Sign in with that Apple ID in Atelier, and Atelier renews itself every week and signs its own updates with it. Until then, its row is in the Library's Renew section with Sign In.

## Publishing a release (maintainers)

The next release's notes gather in `release/notes/next.md` as pull requests are merged: each pull request adds a line about itself there, under the heading it belongs to (New, Fixes or Behind the scenes), ending with its number as `#N`, even when it has nothing to tell users. Its build checks that (Check the release notes cover main): `next.md` has to mention the pull request and every one merged into `main` since the last release. Pull requests that only change release notes, such as one adding a line that was missed, needn't mention themselves. `next.md` isn't named after a tag, so it never starts a release.

A release starts when those notes become its own: in a pull request, rename `next.md` to `release/notes/<tag>.md`, named after the release's tag `vMAJOR.MINOR.PATCH`, e.g. `release/notes/v0.2.0.md`, open it with a one-paragraph summary, since the source's "What's New" gets only that paragraph, as plain text (the GitHub Release gets all of them), add the sections each release has, such as Installing and Known limits, drop the headings with nothing under them, and start a new `next.md` with just the headings. Merging it is the release: the *Tag a release* workflow (`.github/workflows/tag.yml`) tags the merge, and starts the *Release* workflow (`release.yml`) on the tag. Add one release's notes at a time, and only when you mean to release it: *Tag a release* refuses when more than one release has no tag yet. It runs for each push to `main` that changes `release/notes/`, but for `next.md` alone, or the workflow itself. If it fails, run it again on `main`: Actions › Tag a release › Run workflow.

A release's notes mention every pull request merged into `main` since the last release, as `#N`; pull requests that only change release notes, or change a release's, are left out. The release's pull request checks that against `main`, and *Tag a release* checks it again before tagging, since `main` may have moved on before the merge. If a pull request is missing then, nothing is tagged and the build names it: mention it in the notes in another pull request, and merging that one tags the release.

*Release* runs the tests, builds the app with the tag's version and 1000 plus the number of commits up to the tag as its build number (so build numbers only go up, and stay above those of the builds made before the repo was public), publishes `Atelier-<version>.ipa` as this repo's GitHub Release for the tag, and commits the updated `source.json`, `icon.png` and the screenshots to the `source` branch (created by the first release, with no history shared with `main`, so release commits never land on `main`). A pre-release tag such as `v0.1.0-alpha` works too: the app's version is `0.1.0` (iOS wants plain numbers), the release is marked as a pre-release, and the source shows `0.1.0-alpha` with a beta tag. If the build fails after the release was created, running it again on the tag replaces the IPA: Actions › Release › Run workflow, with the tag picked instead of a branch. Its dry run builds the release and writes its `source.json`, which the run keeps, without publishing them.

A tag pushed by hand releases too, e.g. `git tag -a v0.2.0 -m "Notes." && git push origin v0.2.0`. Without a notes file for it, the notes are the tag's message, or else the text of a release you made for the tag on GitHub's site.

The source's own text and the app's description are in [`release/source-template.json`](../release/source-template.json); the script that adds each version is [`scripts/update_source.py`](../scripts/update_source.py), and [`scripts/publish_release.py`](../scripts/publish_release.py) tags and publishes it.

Each release in the source also gets a news item, "Atelier 0.2.0 is out" with its "What's New", which Browse shows with Atelier's button to get or open it. News of your own goes in the template's `news`; an item there with a release's identifier, such as `release-0.2.0`, replaces that release's.

The app's screenshots go in `release/screenshots/`, as PNGs shown in the order of their names (`1-browse.png`, `2-sources.png` and so on). Each release publishes them to the `source` branch's `screenshots/` folder, lists them in `source.json` with their sizes, and removes the ones `main` no longer has, so a change to them shows from the next release. Use full-screen iPhone screenshots as the phone takes them, without rounding their corners or adding a frame: AltStore and Atelier round the corners themselves. A screenshot's URL ends in a hash of its file, so apps that keep images, as Atelier does, load a replaced screenshot again.

There's no token to set up: the workflows publish with their own (`GITHUB_TOKEN`), and only *Tag a release* and *Release*'s last job can write to the repo with it. Releases come from the public repo only, so a private copy of it doesn't publish them.
