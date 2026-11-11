# Source fixtures

Real sources, fetched on 18 Oct 2026, unless noted.

| File | From | Shape |
|---|---|---|
| `altstore-classic.json` | AltStore's own source, `https://apps.altstore.io`. Trimmed to 3 versions per app and 4 news items; its `userInfo` (a Patreon token) removed. | Classic v2, with v1 fields alongside, object-form `appPermissions`, split iPhone/iPad screenshots, Patreon apps |
| `utm.json` | `https://alt.getutm.app`, unchanged. | Classic v2, `screenshotURLs` |
| `quantum.json` | Quantum Source, `https://quarksources.github.io/dist/quantumsource.min.json`. Trimmed to 5 apps. | Classic v2 aggregator: `maxOSVersion`, 7-digit fractional seconds, a non-padded date, empty-list permissions |
| `flycast-v1.json` | `https://flyinghead.github.io/flycast-builds/altstore.json`, unchanged. | Legacy v1: no `versions` |
| `thatstella-v1-trailing-comma.json` | `https://alt.thatstel.la`, unchanged. | Has a trailing comma, so it isn't strict JSON |
| `pal.json` | AltStore's PAL example source from the spec (`PALSource.json`). Its `.ipa` placeholder URLs were replaced with ADP URLs as the spec describes them (manifest, directory, `assetURLs`). No real PAL source was reachable to copy. | AltStore PAL |
| `malformed.json` | Written by hand. | Broken apps, versions, screenshots, permissions and news |
