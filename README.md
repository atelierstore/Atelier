# Atelier

A self-signing, AltStore-like app store for iOS: sideload and re-sign your own apps on your own devices.

Status: early development.

## Layout

- `Atelier/`: the SwiftUI app target (iOS 17 and later).
- `Packages/AtelierKit/`: everything else, one module per concern, each with its own tests:
  - `SourceKit`: AltStore source models and parsing, store links (`atelier://`, and AltStore's, SideStore's and Feather's schemes) and conditional fetching.
  - `CertKit`: certificate and provisioning profile parsing and storage.
  - `SigningKit`: on-device signing with zsign: unpacks an IPA, signs the app and everything nested in it with the user's certificate, and repacks it.
  - `InstallKit`: the install routes. Route B (the loopback server, manifest links and install tracking) is in.
  - `DownloadKit`: IPA downloads through a background `URLSession` (resumable, retried, and checked against the source's size, ZIP layout and optional `sha256`).
  - `AtelierCore`: persistence (SwiftData), the user's sources (`SourceLibrary`: add, refresh, remove, kept for offline use) and the download, sign and install pipeline.
- `project.yml`: the XcodeGen spec the Xcode project is generated from. The `.xcodeproj` isn't committed.
- `infra/manifest-worker/`: the HTTPS manifest endpoint route B installs need (a Cloudflare Worker).
- `infra/website/`: Atelier's website, static pages served by a second Cloudflare Worker: the home page, with the ways to install Atelier, the sideload page (`/sideload`) with its unsigned IPA and its source for people who sign it themselves, and `https://` pages for Atelier's install, source, app and search links (`/install?url=…`, `/source?url=…`, `/viewapp?bundleid=…`, `/search?q=…`), which open the `atelier://` links from places that don't open them, such as chat apps, and show the app or source, which the Worker reads from the IPA or the source; see [its README](infra/website/README.md).
- `scripts/sign_ipa.py`: signs a built app with a certificate and profile, the way Feather does. CI uses it.
- `scripts/update_source.py`, `scripts/publish_release.py` and `release/`: the release pipeline, with the screenshots Atelier's source lists in `release/screenshots/`. Merging a release's notes (`release/notes/<tag>.md`) tags it, and the tag builds the unsigned IPA and publishes it with Atelier's own source; see [docs/install.md](docs/install.md), which is also the first-install guide.

## Build

On a Mac with Xcode 26 or later:

```sh
brew install xcodegen
xcodegen generate
open Atelier.xcodeproj
```

Package tests: `cd Packages/AtelierKit && swift test`. Everything but the SwiftData store, the loopback server and zsign itself also builds and tests on Linux; there, SigningKit's tests run the signing pipeline with a stand-in for zsign, and the tests that sign real binaries and check them with `codesign` run only on a Mac with Xcode.

CI runs on GitHub Actions for each new commit on a pull request into main, and for each push to main (the *Atelier* workflow, `.github/workflows/atelier.yml`): it runs the Workers' and the release scripts' tests on Linux, and on a Mac the package tests, builds `Atelier-unsigned.ipa`, and signs a copy as `Atelier.ipa` with the Signulous certificate in the repo's secrets (`build.yml`, which says how to add them). Both go to the website, which keeps them for 7 days at unlisted addresses ([Builds](infra/website/README.md#builds)): the run's summary links the unsigned one and the link that installs it with Atelier, and the signed one's links, which install it from Safari, are only in the website's build records, as its profile lists the maintainer's iPhones. The run also keeps `Atelier-unsigned.ipa` for 14 days, for anyone signed in to GitHub. A build has the last release's version, and 1000 plus the number of commits as its build number, so Atelier counts it as newer than that release and than the builds made before the repo was public. A pull request that only changes docs, release notes, the Workers or the release scripts runs just their checks and builds no IPA. Builds take `IDevice.xcframework` and SwiftPM's clones from caches that main's builds keep, so a pull request that changes `Packages/IDeviceBridge` builds it from source until it's merged. Pull requests from forks get none of the repo's secrets, so their builds aren't signed, and they wait for a maintainer's approval before they run.

## License

GPL-3.0-only. See [LICENSE](LICENSE) and [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).
