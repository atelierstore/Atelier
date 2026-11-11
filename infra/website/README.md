# Website

Atelier's website: static pages in `public/`, served by a Cloudflare Worker ([Workers static assets](https://developers.cloudflare.com/workers/static-assets/)), next to the manifest Worker. The home page says what Atelier does and the ways to install it the first time, the certificate page signs Atelier with the visitor's certificate in Safari or on a computer and installs it, the sideload page has what people who sign it themselves need: the unsigned IPA, Atelier's source for AltStore, SideStore or Feather, and the steps, and the signing services page tells signing services how to offer Atelier to their customers, signed and with their certificate inside (below). The same Worker serves Atelier's links as `https://` ones (below). Its code, in `src/`, reads the app an install link installs and the source a source or app link names, and keeps the certificate page's signed Atelier until iOS has installed it.

- `public/index.html` is the home page, `public/certificate.html` the certificate page, with `public/certificate/install.html` (and `certificate-install.js`) for the code it shows on a computer, `public/sideload.html` the sideload page and `public/signing-services.html` the signing services page, with `site.css` beside them and the pages' scripts, `certificate.js` and `sideload.js`, which the signing services page uses too. There's no build step and no framework, and the pages load nothing from other sites but Atelier's own source.
- The certificate page's other modules check the certificate (`checks.js`, with `profile.js`, `x509.js`, `der.js`, `plist.js` and `zip.js`), ask Apple whether it was revoked (`ocsp.js`), sign Atelier (`signer.js`, `macho.js` and `packaged.js`, run by `signing-worker.js`) and draw the code a computer shows (`qr.js`) with zsign and OpenSSL in WebAssembly (`zsign.js` and `zsign.wasm`, built by `wasm/build.sh`, below). `public/licenses/` has zsign's and OpenSSL's licenses, which the page links.
- `public/install.html`, `source.html`, `viewapp.html` and `search.html`, each with its own script, are the link pages (below). Their scripts share `link.js`, and the pages share `site.css`.
- `src/index.js` answers `/install/app` and `/source/info` for them (below), with `src/ipa.js` and `src/source.js`, and `/ota` and `/ocsp` for the certificate page (below), with `src/ota.js` and `src/ocsp-relay.js`, and `/builds` for CI's builds (below), with `src/builds.js` and `src/github-oidc.js`. It passes every other request static assets don't match, such as a 404, back to them. Requests for the site's files don't run it.
- `public/img/` holds the icon, the screenshots (`screens/`) and `og.png`, the picture apps show when a link to the site is shared. `og:url` and `og:image` in `index.html`, `certificate.html`, `sideload.html` and `signing-services.html` name the site's address, so they change with it.
- `public/fonts/` holds Bricolage Grotesque, the headings' typeface, under the SIL Open Font License 1.1 (`OFL.txt` beside it). Everything else is in the system font.
- `public/_headers` sets the static files' response headers: a content security policy that only allows the site's own files, `data:` images (an app's icon on the install link page) and fetching the source from GitHub, long caching for the fonts, and `noindex`, which keeps the site out of search results until the repo goes public. Remove that line then. The source and app link pages have their own policy, which allows images from any `https://` address too, for the icons sources list. The certificate page and its signing worker have theirs, which let them run WebAssembly (`'wasm-unsafe-eval'`).
- `public/_redirects` sends `/donate`, which every Donate button opens, on to Atelier's page on Ko-fi (below).

## Installing Atelier

The home page's Get Atelier lists the ways to install Atelier the first time, one row each (#152):

- **With a signing service** opens the certificate page, `/certificate` (below).
- **With your Apple ID**, which is to make a certificate with the visitor's Apple ID, sign Atelier with it and install it, says Coming soon until it's built.
- **I already know how to sideload** opens the sideload page, `/sideload`, for people with a signer of their own: the newest release's unsigned IPA, with its size, date and SHA-256, then Atelier's source with Copy and Add to AltStore, SideStore and Feather, and the steps. They say to sign Atelier with the certificate the user will add to it, since Atelier signs its own updates with it and iOS only installs them for the App ID it was installed with (#24). The hero's Add the source button opens the page at the source (`/sideload#source`).

`sideload.js` reads Atelier's source (`source.json` on the `source` branch) for its newest release, with `release.js`, so releases need no change here. When it can't, the Download button opens the releases page, and the release's version, size, date and SHA-256 stay hidden.

## For signing services

`/signing-services` is for signing services that want to offer Atelier preconfigured for their customers, signed with each customer's certificate, as they offer other apps. Get Atelier on the home page links to it (Run a signing service?), and so does every page's footer. It has four steps, in Atelier's terms:

1. **Get the newest release:** the newest release's unsigned IPA, as on the sideload page (`sideload.js` fills it in from the same markup), and Atelier's source, to follow new releases: the first of its app's `versions`, with `downloadURL`, `size` and `sha256` (`scripts/update_source.py`).
2. **Put the certificate inside:** `AtelierCertificate.plist` next to the app's `Info.plist`, before signing, as the certificate page and Install a Copy put it in (`PackagedCertificate` in CertKit, #113, and `packaged.js`), key by key: `p12`, `profile`, `password` and `id`, and the optional `name` and `udid`. Atelier imports it on its first launch, once the profile it was installed with lists the certificate (`CertificatesModel.importPackagedCertificate`). Releases that look for it have `AtelierTakesCertificate` in their `Info.plist`.
3. **Sign it with the same certificate:** the customer's, whose profile is for the App ID Atelier will sign its updates for (`OwnAppSigning`, #24), keeping the bundle ID, with the profile's entitlements, and the Live Activity extension signed with the same profile (`scripts/sign_ipa.py` signs it the same way).
4. **Install it**, with Developer Mode or trusting the developer, as the certificate page says.

Then what happens once it's installed: Atelier updates itself from its own source (`SelfUpdate`), the customers can add the service's source with a source link, a revoked certificate needs Atelier signed again for the same App ID, iOS won't install over an Atelier signed for another App ID (`SignedAppIdentity.upgradeProblem`), a changed bundle ID is another app and copies' bundle IDs are Atelier's (`InstallTarget`), and the license.

## The certificate page

`/certificate` installs Atelier with the visitor's own certificate, in Safari on their iPhone, or on a computer that shows a code the iPhone scans, with nothing to install first (#152).

1. **Choose your certificate.** The visitor chooses their `.p12` and `.mobileprovision`, or a ZIP that holds both, and types the password. The page checks them as Atelier checks a certificate it imports (`CertificateFiles`, `CertificateImporter`, `CertificateExpiry` and `CertificateNotes` in CertKit), in Atelier's words: it opens the `.p12` with the password, reads the profile, and says whether the profile was made for the certificate, until when, and which iPhones it lets install Atelier. Then it asks Apple whether the certificate was revoked, as Atelier does (`OCSP.swift`). Apple's responders only answer over plain HTTP and to no other site's pages, so the Worker passes the request on (`/ocsp`), and the page only believes an answer Apple signed. Sign and Install stays off while something would keep iOS from installing Atelier: a profile made for another certificate, an expired certificate or profile, an App Store profile, or a revoked certificate. When Apple can't be asked, the visitor can still install, as Atelier asks again once it's open.
2. **Sign and install Atelier.** The page downloads Atelier's newest release, as its source lists it, through the Worker (`/ota/release?url=<the release's IPA>`), as GitHub's downloads can't be read by other sites' pages, and checks its SHA-256. When it can't download it, the page asks for the IPA as a file instead. A worker then signs it as Atelier signs an IPA (`IPASigner` and `ZsignEngine` in SigningKit), with zsign from the fork and commit Atelier signs with: it prepares the app as Feather does, signs it with the profile's entitlements, which is what Atelier's entitlement fitting comes to for its own release, and checks every binary has a signature. With Include Certificate on, the certificate goes in the app first, as Install a Copy puts it in a copy (`AtelierCertificate.plist`, #113), and Atelier imports it when it first opens. Releases built before 3 Nov 2026 don't look for it, so for them the switch turns off. The page uploads the signed Atelier (`POST /ota`) and opens the `itms-services://` link it gets back, so iOS asks whether to install Atelier, with an Install Atelier button for when it didn't. It follows the install (`GET /ota/<token>`) until iOS has downloaded Atelier.
3. **Open Atelier.** With a development or ad hoc certificate, iOS opens it once Developer Mode is on, and with an enterprise one once the visitor trusts it, which the step says.

### From a computer

On a computer (any browser that isn't on an iPhone or iPad), the page checks the certificate and signs Atelier the same way, and Sign and Install is Sign and Show Code. Once it has uploaded the signed Atelier, it shows a QR code of `/certificate/install#<token>` instead of opening iOS's alert. The iPhone's Camera opens that page in Safari, and it opens the `itms-services://` link by itself the first time a tab shows it, as the link pages do, with an Install Atelier button for when it didn't. The token is after the `#`, so it stays in the browser until the page asks `/ota/<token>`.

- **The code** is drawn on the page by `qr.js`: byte mode, error correction level M, versions 1 to 10, as ISO/IEC 18004 sets them out, with the mask its penalty rules prefer. The site's address and a token make version 5. `test/qr.test.js` checks it module for module against Project Nayuki's qrcodegen. It stays dark on white in dark mode.
- **Both pages follow the install** (`GET /ota/<token>`): `waiting` until iOS reads the manifest, then `asked` while iOS asks whether to install Atelier, `downloading` once it asks for the IPA, and `downloaded`. The computer says Waiting for your iPhone, Your iPhone asks whether to install it, Installing on your iPhone, then Downloaded by your iPhone, and step 3 opens. The iPhone's page shows Atelier's version and size, which the same answer has.
- **After 10 minutes** the upload goes, the code fades, and Show a New Code uploads the same signed Atelier again, without signing it again. The page keeps it until the certificate, the IPA or Include Certificate changes.
- **The code holds the upload's address,** so whoever has it can download the IPA, with the visitor's certificate and its password inside when Include Certificate is on. The page says so under the code, and the page's column on where the certificate goes says it too.
- **On the iPhone,** the page says to open it in Safari, with Copy Link, in another browser, and that Atelier needs iOS 17 or later on an older iOS. On a computer, it says to scan the code with the iPhone. When the upload has gone, it says the code no longer works.

The Worker keeps each upload in a Durable Object of its own (`SignedApp` in `src/ota.js`), named by a random 128-bit token in its addresses, with the manifest iOS reads (`/ota/<token>/manifest.plist`), the IPA (`/ota/<token>/Atelier.ipa`), and the install's state, Atelier's version and the IPA's size (`/ota/<token>`). It keeps only Atelier (`com.atelier.app`), up to 64 MB, and deletes it a minute after iOS has downloaded all of it, or 10 minutes after it came, whichever is first. The `.p12`, its password and the profile never leave the page otherwise, and nothing is logged: `observability` is off in `wrangler.toml`. The signed IPA has the profile in it (`embedded.mobileprovision`), as every signed app does, and with Include Certificate on, the `.p12` and its password too.

iOS only installs from Safari, and only over HTTPS, so try installs on a Preview or the deployed site, in Safari on an iPhone. On other devices and browsers the page still checks the certificate, and says to open it in Safari on the iPhone.

### zsign in WebAssembly

`public/zsign.js` and `public/zsign.wasm` are zsign, from the fork and commit of Zsign-Package that Atelier signs with, and OpenSSL's libcrypto, compiled to WebAssembly with Emscripten, with `wasm/signer.cpp`: the two functions the page calls, to open a `.p12` and to sign an app. They're committed, so the site deploys without a build step. To build them again, as when Atelier moves to another zsign commit, change the pins at the top of `wasm/build.sh` and run it, from any folder:

```sh
infra/website/wasm/build.sh
```

It needs git, curl, Python 3, Perl and make, and a few GB of disk in its work folder (`wasm/.build` unless it's given another, ignored by git). It downloads Emscripten and OpenSSL, checks OpenSSL's SHA-256, builds libcrypto, fetches zsign, applies `wasm/zsign-emscripten.patch`, and compiles them into `public/`. The same pins build the same files. The patch keeps a file zsign maps open until it unmaps it: Emscripten writes a mapping back through the file it was mapped from, and zsign closes it straight away, which lost its signatures.

## Links

Atelier's links open the app from a web page or another app, but chat apps and many others only open `https://` links. So each has an `https://` one here: swap `atelier://` for `https://atelierstore.app/`, and the link opens its page, which opens the `atelier://` link.

| Link | Page | Opens |
| --- | --- | --- |
| `atelier://install?url=<IPA address>&source=<source>` | `/install?url=…` | Atelier's question before it installs the app |
| `atelier://source?url=<source>` | `/source?url=…` | The source and its apps, to add |
| `atelier://viewapp?bundleid=<bundle ID>&source=<source>` | `/viewapp?bundleid=…` | The app's page, adding its source first if needed |
| `atelier://search?q=<text>` | `/search?q=…` | A search of the apps in all the user's sources |

On an iPhone or iPad each page opens its `atelier://` link straight away, once Safari asks, and keeps an Open in Atelier button for when that didn't happen. It opens Atelier by itself only the first time a tab shows the link, not when Safari reloads the page or comes back to it. On other devices it only shows the button. Each page reads its link as Atelier reads the `atelier://` one (`StoreLink` and `SourceLink` in SourceKit), and for one Atelier wouldn't take, says why, in Atelier's words. Where a page can't tell, it leaves the link to Atelier, which says so itself. The pages have their own `noindex`, so links stay out of search results once the rest of the site no longer does. Certificate links, which only apps send each other, have no page.

### Install links

`/install?url=<IPA address>` opens `atelier://install?url=<the same address>`, and Atelier asks before it installs anything. For example:

```
https://atelierstore.app/install?url=https%3A%2F%2Fexample.com%2FApp.ipa
```

- Percent-encode the address, as `encodeURIComponent` or Python's `urllib.parse.quote(address, safe="")` do. One that isn't encoded works too when `url=` is the last item, its own query included.
- The address is read as Atelier reads its install links (`StoreLink` in SourceKit): HTTPS only, and without a scheme it's read as HTTPS. For one Atelier wouldn't take, the page says why, in Atelier's words.
- `&source=<source>` names the source the app comes from, an AltStore source's address or a GitHub repo as `owner/repo`, percent-encoded too, and the page passes it on to Atelier: without that source, Atelier shows it to add first, then installs the app as the source lists it, so its updates come from there.
- The page shows the app's icon, above an arrow to Atelier's, with its name, version and size. The Worker reads them from the IPA (`/install/app?url=<IPA address>`, `src/ipa.js`) as Atelier reads GitHub sources' IPAs: the end of the ZIP, its list of files, `Info.plist` and the icon, a few small range requests rather than the whole IPA, by Atelier's rules for which name, version and icon are the app's. It turns the icon from Apple's iPhone PNG variant, which only Apple's systems draw, into a plain PNG. Until they come, and when the IPA's server doesn't send parts of files or the IPA can't be read, the page shows the file's name and Atelier's icon, and opening Atelier never waits for them. Nothing is stored or logged.
- The page's address is only read in the browser, by `install.js`, which sends the Worker just the IPA's.

### Source links

`/source?url=<source>` opens `atelier://source?url=<the same source>`: an AltStore source's address, or a GitHub repo as `owner/repo` or its address. For example:

```
https://atelierstore.app/source?url=https%3A%2F%2Fcdn.altstore.io%2Ffile%2Faltstore%2Fapps.json
https://atelierstore.app/source?url=StikDebug%2FStikPair
```

- Percent-encode the source, as for install links. One that isn't encoded works too when `url=` is the last item, its own query included.
- For an AltStore source, the page shows its icon, above an arrow to Atelier's, with its name, how many apps it has and the icons of the first few, as Atelier's add sheet shows them. The Worker reads them from the source (`/source/info?url=<source>`, `src/source.js`) by Atelier's rules: the apps Atelier can use, a source's listings of one app as one app, and without betas, unless all it has are betas. It reads sources of up to 4 MB, within 8 seconds. Until they come, and when it can't, the page shows the source's address and Atelier's icon, and opening Atelier never waits for them. The icons load in the browser from where the source keeps them, without the page's address. Nothing is stored or logged.
- For a GitHub repo, it shows the repo's name. Its apps are in its releases, which only Atelier reads.

### App links

`/viewapp?bundleid=<bundle ID>&source=<source>` opens `atelier://viewapp?bundleid=<the same bundle ID>&source=<the same source>`, which opens the app's page in Atelier. `source` is optional, and Atelier's own addition to AltStore's links: when the user doesn't have that source, Atelier shows it to add first, then the app from it. For example:

```
https://atelierstore.app/viewapp?bundleid=com.rileytestut.Delta&source=https%3A%2F%2Fcdn.altstore.io%2Ffile%2Faltstore%2Fapps.json
```

- Percent-encode both. Their names can be in any case (`bundleID`), as in AltStore's links, and the last of each counts.
- With an AltStore source, the page shows the app's icon, above an arrow to Atelier's, with its name, version, size, developer and subtitle, and the source's name, which the Worker reads from the source as for source links (`/source/info?url=<source>&bundleid=<bundle ID>`). Until they come, the page shows the bundle ID and the source's address, and when the source doesn't list the app, the bundle ID and the source's name.
- The page doesn't judge the source: Atelier says what's wrong with it, if anything, when it shows it to add.

### Search links

`/search?q=<text>` opens `atelier://search?q=<the same text>`, which searches Browse. For example:

```
https://atelierstore.app/search?q=emulator
```

- `+` is a space, as AltStore reads these links, and the first `q` counts.

## Donate

Every page with a nav ends it with a Donate pill, after GitHub, and has a Donate link in its footer, and the home page's last section, after the FAQ, asks for donations (*Help keep Atelier going*), with the next milestone, which donations go to first, on a card of its own: change it in `index.html` once it's reached. They all open `/donate`, which `public/_redirects` sends on to Atelier's page on Ko-fi with a 302, so its address is only there. To move to another service, change that line and the section's note, which names Ko-fi. The buttons open Ko-fi's own page rather than embedding its widget, so the site still loads nothing from other sites. On a phone, GitHub in the nav shows just its mark, to leave room for the pill.

## Builds

GitHub Actions keeps a run's files behind a GitHub sign-in, which Safari and Atelier's install links don't have, so the builds of pull requests and main (`.github/workflows/build.yml`) upload their IPAs here (`scripts/share_build.py`). The site keeps each for 7 days, as long as Codemagic's links to its builds lasted, in a Durable Object of its own (`BuildApp` in `src/builds.js`, kept like the certificate page's uploads), named by a random 128-bit token in its addresses: `/builds/<token>/Atelier-unsigned.ipa`, or `/builds/<token>/Atelier.ipa` for the copy signed with the Signulous profile, with `/builds/<token>/manifest.plist` for iOS's install alert, so Safari installs it straight away. `/builds/<token>/install` redirects to the signed IPA's `itms-services://` link, so a link to it opens that alert in Safari, as Codemagic's links to its builds did; chats and other places that only link `https://` addresses can link it.

The build job proves which repo, workflow and run it is with the OpenID Connect token GitHub gives a job with `id-token: write`, which GitHub signs for the site's origin (`src/github-oidc.js`), so there's no key to keep. The Worker only takes builds from `build.yml` in `BUILDS_REPOSITORY`, with the ID `BUILDS_REPOSITORY_ID` (`wrangler.toml`), on GitHub's own runners, for pushes, pull requests and runs started by hand. Pull requests from forks get no token, so theirs aren't kept.

The job uploads each IPA (`POST /builds/<file>`), then records the build (`POST /builds`): its commit, branch, pull request, version, build number, run, files and when they go, with the signed one's `itms-services://` link (`install`) and its `/install` address (`safari`), and the `https://` link that installs the unsigned one with Atelier. Anyone can read a public repo's run logs, so the run only shows the unsigned IPA's links: the signed one's profile lists the maintainer's iPhones. The whole record goes to the `BUILDS` KV namespace instead, which only Cloudflare API tokens for the account can read, under `commit/<commit>` (a pull request's own commit, not its merge), `branch/<branch>` and `pr/<number>`, the last two for the newest run, until the files go:

```sh
curl -H "Authorization: Bearer $CLOUDFLARE_API_TOKEN" \
  "https://api.cloudflare.com/client/v4/accounts/<account ID>/storage/kv/namespaces/<BUILDS' ID>/values/branch%2Fmain"
```

`wrangler.toml` binds `BUILDS` without an ID, so the first deploy makes the namespace, named after the Worker; its ID is in the dashboard (Storage & databases › Workers KV) and in `GET /accounts/<account ID>/storage/kv/namespaces`. Without the binding, builds are kept but not recorded. The builds' workflow sends them to `https://atelierstore.app`, or to the Actions variable `BUILDS_SITE` when it's set, such as a Preview's address.

## Try it locally

```sh
npx wrangler dev
```

and open http://localhost:8787. The tests (`npm test`, Node 20.12 or later) cover reading IPAs and sources, `/install/app`, `/source/info`, `/ota`, `/ocsp` and `/builds`, with tokens signed like GitHub's, the sideload page's newest release (`release.js`), and the certificate page's checks, Apple's answer and signing, with the WebAssembly zsign, on the fixtures Atelier's own tests use, and its QR codes; the *Atelier* workflow (`.github/workflows/atelier.yml`) runs them for each pull request.

## Deploy

Needs the Cloudflare account the manifest Worker is on.

Automatically, once set up: in Cloudflare's dashboard, under Workers & Pages, create an application by importing a Git repository. Let Cloudflare's GitHub app see `atelierstore/Atelier`, pick it, and set:

- Project name: `atelier-website`, as `name` in `wrangler.toml` (the build fails if they differ)
- Root directory: `infra/website`
- Build command: none
- Deploy command: `npx wrangler deploy` (the default)

Then in the Worker's Settings › Build › Build watch paths, include `infra/website/*`, so other changes to the repo don't build it. From then on every merge into `main` deploys the site. A pull request that changes it gets a Preview named after its branch, at `https://<branch>-atelier-website.<your-subdomain>.workers.dev`, and Cloudflare comments on the pull request with it. Its build runs `npx wrangler preview`, which needs the `[previews]` block in `wrangler.toml`.

By hand, from this folder:

```sh
npx wrangler deploy
```

Either way the site is at `https://atelier-website.<your-subdomain>.workers.dev`.

## A domain

Atelier's site is at `https://atelierstore.app`, a custom domain of this Worker, and the manifest Worker is at `https://api.atelierstore.app`; older builds' `workers.dev` addresses no longer work. For another domain, add it in the Worker's Settings › Domains & Routes › Add › Custom domain. The domain needs to be on Cloudflare, which it is when it was bought there. Then change `og:url` and `og:image` in `index.html`, `certificate.html`, `sideload.html` and `signing-services.html` to the new address, and the source link address on the signing services page.
