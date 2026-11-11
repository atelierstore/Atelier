# Manifest endpoint

Atelier's itms-services manifest endpoint, a stateless Cloudflare Worker. Route B (#10) needs it because iOS only installs from a manifest served over HTTPS with a publicly trusted certificate, which Atelier's loopback server can't have. It replaces the third-party `api.palera.in/genPlist` that Feather uses.

- It answers `GET /manifest?bundleid=…&name=…&version=…&url=…` with an install manifest. The four parameters can repeat, once per app, for up to 10 apps in one manifest (one iOS alert for all of them). palera.in's names (`fetchurl`, and `/genPlist`) work too.
- It only accepts `http://` loopback package URLs (127.0.0.1, localhost, ::1), so it can't point iOS at IPAs hosted anywhere else.
- It escapes every value, and checks the bundle ID and version.
- It stores and logs nothing (`observability` is off in `wrangler.toml`). It sees each app's bundle ID, name and version, and never the IPA or any certificate.

The app uses `https://api.atelierstore.app/manifest` unless the user enters another endpoint in Settings (`ManifestEndpoint.defaultURL` in InstallKit). This code ran there through the install spike; it moved here from `spike/manifest-worker` unchanged.

## GitHub sign-in (#30)

The same Worker lets Atelier sign in to GitHub without the OAuth app's client secret being in the app (`src/github.js`):

- `GET /github/callback` is the OAuth app's callback URL. It passes GitHub's code and state on to `atelier://github-sign-in`.
- `POST /github/token` takes `{code, code_verifier}` and answers with the token from GitHub, adding the client secret. A code is useless without the PKCE verifier, which only the phone that started the sign-in has.

It needs the OAuth app's client ID as the `GITHUB_CLIENT_ID` variable in `wrangler.toml` and its secret as a Worker secret, set once with `npx wrangler secret put GITHUB_CLIENT_SECRET`. Without them `/github/token` answers 503 and Atelier says sign-in isn't set up. Nothing is stored or logged here either.

## Relaunch after Atelier installs itself (#24)

`GET /relaunch?delay=15` answers 204, with nothing, after `delay` seconds (at most 60), which Atelier gives it. iOS only installs over Atelier once it has closed, and doesn't open it again, so while Atelier is in front it leaves a background download of this URL with iOS, next to its manifest endpoint. When the answer comes, iOS relaunches Atelier in the background to hand it over, as the build it installed, which then says it was installed. iOS starts such a download at once, whereas it put off one timed on the phone for over half a minute. Nothing is stored or logged.

## Anisette servers (#49)

`GET /anisette` answers with the anisette servers Atelier signs in to Apple through, for free Apple ID signing, and the client info it sends Apple in place of theirs (`src/anisette.js`). Apple's sign-in wants anisette data, which vouches for the device signing in, and which public servers Apple takes changes with Apple's own changes: iloader needed four fixes in October 2026. So Atelier asks here before each sign-in, and following Apple's next change only needs this list edited and the Worker deployed, with no Atelier update.

- **The list:** iloader's servers in its order, its default first, then SideStore's public list, HTTPS only. One sign-in tries `tries` of them at most (4), starting with the one the last sign-in worked through.
- **`clientInfo`:** iloader's override while the servers catch up with Apple. Without it, Atelier sends what each server says.
- **A copy is built into Atelier,** `Packages/AtelierKit/Sources/AppleIDKit/anisette.json`, for when this can't be reached. `npm test` checks it's the same list, so change both together. Atelier also keeps the last list it got.
- **`version`** is the format, 1. A change older Ateliers can't read gets another address, so this one keeps answering them.
- Nothing is stored or logged, and the request carries nothing.

## Test

```sh
npm test
```

The *Atelier* workflow (`.github/workflows/atelier.yml`) runs this for every pull request and push to main.

## Deploy

Needs a free Cloudflare account.

```sh
npx wrangler login
npx wrangler deploy
```

Wrangler prints the URL, e.g. `https://atelier-manifest.<your-subdomain>.workers.dev`. The endpoint is that URL plus `/manifest`. Check it with:

```sh
curl "https://atelier-manifest.<your-subdomain>.workers.dev/manifest?bundleid=com.example.app&name=Test&version=1.0&url=http%3A%2F%2F127.0.0.1%3A4567%2Fx.ipa"
```

Atelier's own is also at `https://api.atelierstore.app`, a custom domain added in the Worker's Settings › Domains & Routes, which the app uses. Its GitHub OAuth app's callback URL is `https://api.atelierstore.app/github/callback`.

Anyone can deploy their own and enter it in Atelier's Settings.
