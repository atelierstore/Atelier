// Cloudflare Worker for Atelier's website. The files in public/ are served
// as static assets without running this. It answers the requests they
// can't. For the link pages: /install/app?url=<IPA address>, the app an
// install link installs (public/install.js), and /source/info?url=<source
// address>, the source a source or app link names (public/source.js and
// public/viewapp.js). The IPA is read in a few small parts (see ipa.js), the
// source as a whole (see source.js), and neither is stored or logged. For
// the certificate page, /ota and what's under it: the signed Atelier the
// page uploads, which iOS installs from here, kept for 10 minutes at most
// (see ota.js), and /ocsp, which asks Apple whether a certificate was
// revoked (see ocsp-relay.js). For CI, /builds and what's under it: the
// IPAs GitHub Actions builds, kept for 7 days for Safari and Atelier's install
// links (see builds.js).

import { builds } from "./builds.js";
import { json } from "./http.js";
import { IPAError, ReachError, readApp } from "./ipa.js";
import { ocspRelay } from "./ocsp-relay.js";
import { ota } from "./ota.js";
import { SourceError, readSource } from "./source.js";

// The Durable Objects that keep what the certificate page uploads (ota.js)
// and CI's builds (builds.js).
export { SignedApp } from "./ota.js";
export { BuildApp } from "./builds.js";

export default {
  async fetch(request, env, ctx) {
    const url = new URL(request.url);
    if (url.pathname === "/install/app") return installApp(request, { fetch: withOwnBuilds(request, env, ctx) });
    if (url.pathname === "/source/info") return sourceInfo(request);
    // ctx.exports has the Durable Objects this file exports, with no binding
    // to set up, in Previews too.
    if (url.pathname === "/ota" || url.pathname.startsWith("/ota/")) return ota(request, ctx.exports.SignedApp);
    if (url.pathname === "/builds" || url.pathname.startsWith("/builds/")) return builds(request, env, ctx.exports.BuildApp);
    if (url.pathname === "/ocsp") return ocspRelay(request);
    // Whatever else static assets didn't match, such as a 404.
    return env.ASSETS.fetch(request);
  },
};

/** The app at the address in `url`, as JSON: {name, version, build,
 *  bundleID, size, icon}, `icon` a PNG's data: URL or null. An address that
 *  isn't HTTPS gets a 400, an IPA that can't be read a 422, and one that
 *  can't be reached a 502, each with {error}. `options` go to readApp. */
export async function installApp(request, options = {}) {
  if (request.method !== "GET") return json({ error: "method not allowed" }, 405, { Allow: "GET" });
  const address = httpsAddress(new URL(request.url).searchParams.get("url"));
  if (!address) return json({ error: "url isn't an https:// address" }, 400);
  try {
    const app = await readApp(address, options);
    return json({
      name: app.name,
      version: app.version,
      build: app.build,
      bundleID: app.bundleID,
      size: app.size,
      icon: app.icon && `data:image/png;base64,${base64(app.icon)}`,
    }, 200, {
      // For coming back to the page; the IPA at an address can change.
      "Cache-Control": "public, max-age=600",
    });
  } catch (error) {
    if (error instanceof IPAError) return json({ error: `The IPA can't be read: ${error.message}.` }, 422);
    if (error instanceof ReachError) return json({ error: `The IPA can't be reached: ${error.message}` }, 502);
    throw error;
  }
}

/** The source at the address in `url`, summed up as JSON: {name, icon,
 *  appCount, apps, app}, as source.js sums it up, `app` the one whose bundle
 *  ID is `bundleid`, when that's given and the source lists it. An address
 *  that isn't HTTPS gets a 400, a source that can't be read a 422, and one
 *  that can't be reached a 502, each with {error}. `options` go to
 *  readSource. */
export async function sourceInfo(request, options = {}) {
  if (request.method !== "GET") return json({ error: "method not allowed" }, 405, { Allow: "GET" });
  const query = new URL(request.url).searchParams;
  const address = httpsAddress(query.get("url"));
  if (!address) return json({ error: "url isn't an https:// address" }, 400);
  const bundleID = query.get("bundleid")?.trim() || null;
  try {
    return json(await readSource(address, { ...options, bundleID }), 200, {
      // For coming back to the page; the source can change.
      "Cache-Control": "public, max-age=600",
    });
  } catch (error) {
    if (error instanceof SourceError) return json({ error: `The source can't be read: ${error.message}.` }, 422);
    if (error instanceof ReachError) return json({ error: `The source can't be reached: ${error.message}` }, 502);
    throw error;
  }
}

/** fetch, except that the site's own builds, which an install link of a
 *  build names, are read from their Durable Objects rather than over the
 *  network, which would bring the request back to this Worker. */
export function withOwnBuilds(request, env, ctx) {
  const origin = new URL(request.url).origin;
  return async (input, init) => {
    const url = new URL(input instanceof Request ? input.url : input);
    if (url.origin !== origin || !url.pathname.startsWith("/builds/")) return fetch(input, init);
    const response = await builds(new Request(input, init), env, ctx.exports.BuildApp);
    // Without the address the object was asked at (https://build-app/…),
    // which the runtime gives as the answer's url: ipa.js takes a url other
    // than its own for a redirect, and would read the rest from there.
    return new Response(response.body, response);
  };
}

/** The IPA's or the source's address, which the page sends as Atelier
 *  would download it (HTTPS, with a host), or null. */
function httpsAddress(value) {
  if (!value || value.length > 4096) return null;
  let url;
  try {
    url = new URL(value);
  } catch {
    return null;
  }
  return url.protocol === "https:" && url.hostname ? url.href : null;
}

function base64(bytes) {
  let binary = "";
  for (let i = 0; i < bytes.length; i += 0x2000) binary += String.fromCharCode(...bytes.subarray(i, i + 0x2000));
  return btoa(binary);
}
