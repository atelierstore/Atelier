// Installing Atelier from the certificate page (#152), which signs it in
// Safari, or on a computer, which shows a code the iPhone scans to install it
// (public/certificate/install.html). The page uploads the signed IPA here, and iOS's install alert reads
// its manifest and downloads it from here, as route B serves them from
// Atelier itself (docs/route-b.md). Each upload is kept by a Durable Object
// of its own (SignedApp), named by a random token in its addresses, and goes
// a minute after iOS has downloaded it, or 10 minutes after it came,
// whichever is first. The IPA can have the visitor's certificate in it
// (AtelierCertificate.plist), so nothing else keeps it and nothing is
// logged.
//
// The page also downloads the release it signs through here, as GitHub's
// downloads can't be read by other sites' pages.

import { HEADERS, json } from "./http.js";
import { IPAError, readInfo } from "./ipa.js";

/** How long an upload is kept at most, in milliseconds. */
export const LIFETIME = 10 * 60 * 1000;
/** How long it stays once iOS has downloaded it, for iOS to download it
 *  again when the user retries an install that failed. */
export const AFTER_DOWNLOAD = 60 * 1000;
/** The largest IPA that can be uploaded. Atelier is about 9 MB. */
export const MAX_SIZE = 64 << 20;
/** The only app the site keeps: it installs Atelier, not other apps. */
export const BUNDLE_ID = "com.atelier.app";
/** An IPA is kept in parts, as a Durable Object keeps values of up to 2 MB. */
export const PART_SIZE = 1 << 20;

const TOKEN = /^[0-9a-f]{32}$/;
// The IPAs of Atelier's releases, which redirect to where GitHub keeps them.
const RELEASE_IPA = /^https:\/\/github\.com\/atelierstore\/atelier\/releases\/download\/[^/?#]+\/[^/?#]+\.ipa$/i;

/** Answers the certificate page and iOS, `apps` being SignedApp's
 *  namespace:
 *  - POST /ota, with the signed IPA as the body, keeps it, and answers 201
 *    with {install, status, expires}: the itms-services link that opens
 *    iOS's install alert, where the page follows the install, and when the
 *    IPA goes (an ISO date). An IPA over MAX_SIZE gets a 413, and one that
 *    can't be read or isn't Atelier a 422, each with {error}.
 *  - GET /ota/<token> is that install as {state, expires, version, size}:
 *    `waiting` until iOS reads the manifest, `asked` while iOS asks the user
 *    whether to install it, `downloading` once iOS asks for the IPA, and
 *    `downloaded` once it has had all of it, with the app's version and the
 *    IPA's size. A 404 once it's gone.
 *  - GET /ota/<token>/manifest.plist is the manifest iOS reads, and GET or
 *    HEAD /ota/<token>/Atelier.ipa the IPA.
 *  - GET /ota/release?url=<one of Atelier's releases' IPAs> passes that IPA
 *    on from GitHub. `fetchImpl` is for tests. */
export async function ota(request, apps, fetchImpl = fetch) {
  const url = new URL(request.url);
  if (url.pathname === "/ota") return upload(request, apps);
  if (url.pathname === "/ota/release") return release(request, fetchImpl);

  const [, , token, file, ...rest] = url.pathname.split("/");
  if (!TOKEN.test(token) || rest.length) return notFound();
  const app = apps.get(apps.idFromName(token));
  const base = `${url.origin}/ota/${token}`;
  switch (file) {
    case undefined: {
      if (request.method !== "GET") return notAllowed("GET");
      const info = await kept(app);
      if (!info) return notFound();
      return json({ state: info.state, expires: new Date(info.expires).toISOString(), version: info.version, size: info.size }, 200);
    }
    case "manifest.plist": {
      if (request.method !== "GET") return notAllowed("GET");
      const info = await kept(app);
      if (!info) return notFound();
      // iOS reads it before it asks whether to install the app.
      if (info.state === "waiting") await app.fetch("https://signed-app/asked", { method: "POST" });
      return new Response(manifest({ ...info, ipa: `${base}/Atelier.ipa`, image: `${url.origin}/apple-touch-icon.png` }), {
        headers: { "Content-Type": "application/xml; charset=utf-8", ...HEADERS },
      });
    }
    case "Atelier.ipa":
      if (request.method !== "GET" && request.method !== "HEAD") return notAllowed("GET, HEAD");
      return app.fetch("https://signed-app/ipa", { method: request.method, headers: rangeOnly(request) });
    default:
      return notFound();
  }
}

async function upload(request, apps) {
  if (request.method !== "POST") return notAllowed("POST");
  // The object checks the size too, as a body needn't say it.
  if (Number(request.headers.get("Content-Length")) > MAX_SIZE) return tooLarge();
  if (!request.body) return json({ error: "There's no IPA." }, 400);
  const token = newToken();
  const response = await apps.get(apps.idFromName(token)).fetch("https://signed-app/ipa", {
    method: "PUT",
    body: request.body,
    // For Node, where the tests run; the Workers runtime ignores it.
    duplex: "half",
  });
  if (!response.ok) return response;
  const { expires } = await response.json();
  const base = `${new URL(request.url).origin}/ota/${token}`;
  return json({
    install: `itms-services://?action=download-manifest&url=${encodeURIComponent(`${base}/manifest.plist`)}`,
    status: base,
    expires: new Date(expires).toISOString(),
  }, 201);
}

/** What the object keeps about its app, or null once it's gone. */
export async function kept(app) {
  const response = await app.fetch("https://signed-app/app");
  if (response.status === 404) return null;
  if (!response.ok) throw new Error(`SignedApp answered HTTP ${response.status}`);
  return response.json();
}

/** The request's Range header, the only one of its headers the object
 *  needs. */
export function rangeOnly(request) {
  const range = request.headers.get("Range");
  return range ? { Range: range } : {};
}

/** Whether `address` is one of Atelier's releases' IPAs, as fetch would
 *  ask for it: a tag of `..` would take it somewhere else. */
function isRelease(address) {
  if (!address || !RELEASE_IPA.test(address)) return false;
  try {
    return new URL(address).href === address;
  } catch {
    return false;
  }
}

/** A token no one can guess: 128 random bits, in hex. */
export function newToken() {
  return Array.from(crypto.getRandomValues(new Uint8Array(16)), (byte) => byte.toString(16).padStart(2, "0")).join("");
}

async function release(request, fetchImpl) {
  if (request.method !== "GET") return notAllowed("GET");
  const address = new URL(request.url).searchParams.get("url");
  if (!isRelease(address)) return json({ error: "url isn't one of Atelier's releases" }, 400);
  // A time limit for GitHub's answer, not for its body, which comes as fast
  // as the page takes it.
  const abort = new AbortController();
  const timer = setTimeout(() => abort.abort(), 15_000);
  let response;
  try {
    response = await fetchImpl(address, { headers: { "User-Agent": "Atelier" }, signal: abort.signal });
  } catch {
    return json({ error: "GitHub can't be reached." }, 502);
  } finally {
    clearTimeout(timer);
  }
  if (!response.ok) {
    response.body?.cancel().catch(() => {});
    return json({ error: `GitHub answered HTTP ${response.status}.` }, 502);
  }
  const length = response.headers.get("Content-Length");
  if (Number(length) > MAX_SIZE) {
    response.body?.cancel().catch(() => {});
    return tooLarge();
  }
  return new Response(response.body, {
    headers: {
      "Content-Type": "application/octet-stream",
      ...(length ? { "Content-Length": length } : {}),
      ...HEADERS,
      // A release's files don't change.
      "Cache-Control": "public, max-age=3600",
    },
  });
}

// MARK: The manifest

/** The itms-services manifest for one app: `ipa` and `image` are its IPA's
 *  and its icon's addresses, and the rest is what readInfo read from its
 *  Info.plist. */
export function manifest({ ipa, image, bundleID, version, name }) {
  return `<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>items</key>
  <array>
    <dict>
      <key>assets</key>
      <array>
        <dict>
          <key>kind</key>
          <string>software-package</string>
          <key>url</key>
          <string>${xml(ipa)}</string>
        </dict>
        <dict>
          <key>kind</key>
          <string>display-image</string>
          <key>url</key>
          <string>${xml(image)}</string>
        </dict>
      </array>
      <key>metadata</key>
      <dict>
        <key>bundle-identifier</key>
        <string>${xml(bundleID)}</string>
        <key>bundle-version</key>
        <string>${xml(version)}</string>
        <key>kind</key>
        <string>software</string>
        <key>title</key>
        <string>${xml(name)}</string>
      </dict>
    </dict>
  </array>
</dict>
</plist>
`;
}

/** Text for an XML element, without the characters XML 1.0 doesn't allow. */
function xml(text) {
  return String(text)
    .replace(/[\u0000-\u0008\u000B\u000C\u000E-\u001F￾￿]/g, "")
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;");
}

// MARK: Ranges

/** The part of a file of `size` bytes that a Range header asks for, as
 *  route B reads it (ByteRange in InstallKit): {start, end}, `end` included,
 *  or null for the whole file when there's no header or it isn't one range
 *  of bytes. Throws a RangeError when the range is outside the file. */
export function byteRange(header, size) {
  if (!header?.startsWith("bytes=") || header.includes(",")) return null;
  const spec = header.slice("bytes=".length);
  const dash = spec.indexOf("-");
  if (dash < 0) return null;
  const [first, last] = [spec.slice(0, dash), spec.slice(dash + 1)];
  const number = (text) => (/^\d+$/.test(text) ? Number(text) : null);
  if (first === "") {
    const suffix = number(last);
    if (!suffix) throw new RangeError("unsatisfiable");
    return { start: Math.max(0, size - suffix), end: size - 1 };
  }
  const start = number(first);
  if (start === null || start >= size) throw new RangeError("unsatisfiable");
  const end = last === "" ? size - 1 : Math.min(number(last) ?? -1, size - 1);
  if (end < start) throw new RangeError("unsatisfiable");
  return { start, end };
}

// MARK: The Durable Object

/** Keeps one uploaded IPA, until its alarm. It keeps the IPA in parts
 *  (`part0`, `part1`, …) and what it knows about it under `app`: {bundleID,
 *  name, version, build, size, parts, state, expires}, and `file`, the IPA's
 *  file name, when the upload gave one. The Worker asks it:
 *  - PUT /ipa, with the IPA as the body, and optionally ?file=<its name>:
 *    keeps it, and answers 201 with `app`, or 413 or 422 with {error}.
 *  - GET /app: `app`, or a 404 once it's gone.
 *  - POST /asked: iOS has read the manifest, so the state goes from
 *    `waiting` to `asked`.
 *  - GET or HEAD /ipa: the IPA, or the part a Range header asks for; with
 *    ?file=<name>, a 404 unless that's the upload's file name.
 *  BuildApp (builds.js) keeps builds the same way, for longer. */
export class SignedApp {
  /** How long an upload is kept at most, in milliseconds. */
  static lifetime = LIFETIME;

  constructor(ctx) {
    this.storage = ctx.storage;
  }

  async fetch(request) {
    const { pathname } = new URL(request.url);
    if (pathname === "/ipa" && request.method === "PUT") return this.keep(request);
    const app = await this.storage.get("app");
    if (!app) return notFound();
    if (pathname === "/app") return Response.json(app);
    if (pathname === "/asked" && request.method === "POST") {
      if (app.state === "waiting") {
        app.state = "asked";
        await this.storage.put("app", app);
      }
      return new Response(null, { status: 204 });
    }
    if (pathname === "/ipa") {
      // An address with another file name than the upload's isn't its.
      const file = new URL(request.url).searchParams.get("file");
      if (file && file !== app.file) return notFound();
      return this.send(request, app);
    }
    return notFound();
  }

  async alarm() {
    // With the compatibility date in wrangler.toml, this takes the alarm too.
    await this.storage.deleteAll();
  }

  async keep(request) {
    if (await this.storage.get("app")) return json({ error: "There's an IPA here already." }, 409);
    // Set first, so the parts go even when the upload stops part way.
    const expires = Date.now() + this.constructor.lifetime;
    await this.storage.setAlarm(expires);

    let size = 0;
    let parts = 0;
    let part = new Uint8Array(PART_SIZE);
    let filled = 0;
    const reader = request.body.getReader();
    try {
      for (;;) {
        const { done, value } = await reader.read();
        if (done) break;
        size += value.length;
        if (size > MAX_SIZE) {
          reader.cancel().catch(() => {});
          await this.storage.deleteAll();
          return tooLarge();
        }
        for (let offset = 0; offset < value.length;) {
          const count = Math.min(PART_SIZE - filled, value.length - offset);
          part.set(value.subarray(offset, offset + count), filled);
          filled += count;
          offset += count;
          if (filled === PART_SIZE) {
            await this.storage.put(`part${parts++}`, part);
            part = new Uint8Array(PART_SIZE);
            filled = 0;
          }
        }
      }
    } catch {
      await this.storage.deleteAll();
      return json({ error: "The upload stopped part way." }, 400);
    }
    // A copy of its own: storage would keep the rest of the buffer too.
    if (filled) await this.storage.put(`part${parts++}`, part.slice(0, filled));

    let info;
    try {
      info = await readInfo(new StoredFile(this.storage, size));
    } catch (error) {
      await this.storage.deleteAll();
      if (error instanceof IPAError) return json({ error: `The IPA can't be read: ${error.message}.` }, 422);
      throw error;
    }
    if (info.bundleID !== BUNDLE_ID) {
      await this.storage.deleteAll();
      return json({ error: "This site only installs Atelier." }, 422);
    }
    const file = new URL(request.url).searchParams.get("file");
    const app = { ...info, size, parts, state: "waiting", expires, ...(file ? { file } : {}) };
    await this.storage.put("app", app);
    return Response.json(app, { status: 201 });
  }

  async send(request, app) {
    if (app.state === "waiting" || app.state === "asked") {
      app.state = "downloading";
      await this.storage.put("app", app);
    }
    let range;
    try {
      range = byteRange(request.headers.get("Range"), app.size);
    } catch {
      return new Response(null, { status: 416, headers: { "Content-Range": `bytes */${app.size}`, ...HEADERS } });
    }
    const { start, end } = range ?? { start: 0, end: app.size - 1 };
    const headers = {
      "Content-Type": "application/octet-stream",
      "Content-Length": String(end - start + 1),
      "Accept-Ranges": "bytes",
      ...(range ? { "Content-Range": `bytes ${start}-${end}/${app.size}` } : {}),
      ...HEADERS,
    };
    const status = range ? 206 : 200;
    // The Workers runtime keeps a HEAD answer's Content-Length only when it
    // has no body, and reads a body it's given, which would count as a
    // download.
    if (request.method === "HEAD") return new Response(null, { status, headers });
    // Only all of it counts as iOS having it, as for route B.
    const body = this.read(start, end, range ? null : () => this.downloaded());
    return new Response(withLength(body, end - start + 1), { status, headers });
  }

  /** Bytes `start` to `end` of the IPA, a part at a time, as they're read.
   *  `ended` runs once all of them have been read. */
  read(start, end, ended) {
    const storage = this.storage;
    let at = start;
    return new ReadableStream({
      async pull(controller) {
        if (at > end) {
          // Before the end, so the install's state says so by the time iOS
          // has all of it.
          try {
            await ended?.();
          } finally {
            controller.close();
          }
          return;
        }
        const index = Math.floor(at / PART_SIZE);
        const part = await storage.get(`part${index}`);
        if (!part) {
          controller.error(new Error("the IPA has gone"));
          return;
        }
        const to = Math.min(part.length, end - index * PART_SIZE + 1);
        controller.enqueue(part.subarray(at - index * PART_SIZE, to));
        at = index * PART_SIZE + to;
      },
    }, { highWaterMark: 0 });
  }

  /** iOS has the whole IPA: the object goes a minute later, at the latest. */
  async downloaded() {
    const app = await this.storage.get("app");
    if (!app) return;
    app.expires = Math.min(app.expires, Date.now() + AFTER_DOWNLOAD);
    app.state = "downloaded";
    await this.storage.put("app", app);
    await this.storage.setAlarm(app.expires);
  }
}

/** The Workers runtime sends a body's length, rather than sending it in
 *  chunks, only for a FixedLengthStream, which Node doesn't have. */
function withLength(stream, length) {
  if (typeof FixedLengthStream !== "function") return stream;
  const { readable, writable } = new FixedLengthStream(length);
  stream.pipeTo(writable).catch(() => {});
  return readable;
}

/** The IPA as readInfo reads it: a few parts, from storage. */
class StoredFile {
  constructor(storage, size) {
    this.storage = storage;
    this.size = size;
  }

  async read(start, end) {
    end = Math.min(end, this.size - 1);
    if (start > end) return new Uint8Array(0);
    const first = Math.floor(start / PART_SIZE);
    const last = Math.floor(end / PART_SIZE);
    const keys = [];
    for (let index = first; index <= last; index++) keys.push(`part${index}`);
    const parts = await this.storage.get(keys);
    const bytes = new Uint8Array(end - start + 1);
    for (let index = first; index <= last; index++) {
      const part = parts.get(`part${index}`);
      const from = Math.max(start - index * PART_SIZE, 0);
      const to = Math.min(end - index * PART_SIZE + 1, PART_SIZE);
      bytes.set(part.subarray(from, to), index * PART_SIZE + from - start);
    }
    return bytes;
  }
}

function notFound() {
  return json({ error: "There's nothing here, or it has gone." }, 404);
}

function notAllowed(methods) {
  return json({ error: "method not allowed" }, 405, { Allow: methods });
}

function tooLarge() {
  return json({ error: `The IPA is over ${MAX_SIZE >> 20} MB.` }, 413);
}
