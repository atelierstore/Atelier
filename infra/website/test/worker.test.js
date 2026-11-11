import { test } from "node:test";
import assert from "node:assert/strict";

import worker, { installApp, sourceInfo } from "../src/index.js";

const INFO_PLIST = `<plist><dict>
<key>CFBundleIdentifier</key><string>org.example.notes</string>
<key>CFBundleName</key><string>Notes</string>
<key>CFBundleShortVersionString</key><string>3.0</string>
<key>CFBundleVersion</key><string>12</string>
</dict></plist>`;

/** A ZIP of `files`, [path, text or bytes] pairs, stored. */
function zip(...files) {
  const encode = (value) => (typeof value === "string" ? new TextEncoder().encode(value) : value);
  const locals = [];
  const centrals = [];
  let offset = 0;
  for (const [path, contents] of files) {
    const name = encode(path);
    const data = encode(contents);
    const local = new Uint8Array(30 + name.length + data.length);
    const l = new DataView(local.buffer);
    l.setUint32(0, 0x04034b50, true);
    l.setUint32(18, data.length, true);
    l.setUint32(22, data.length, true);
    l.setUint16(26, name.length, true);
    local.set(name, 30);
    local.set(data, 30 + name.length);
    const central = new Uint8Array(46 + name.length);
    const c = new DataView(central.buffer);
    c.setUint32(0, 0x02014b50, true);
    c.setUint32(20, data.length, true);
    c.setUint32(24, data.length, true);
    c.setUint16(28, name.length, true);
    c.setUint32(42, offset, true);
    central.set(name, 46);
    locals.push(local);
    centrals.push(central);
    offset += local.length;
  }
  const end = new Uint8Array(22);
  const e = new DataView(end.buffer);
  e.setUint32(0, 0x06054b50, true);
  e.setUint16(8, files.length, true);
  e.setUint16(10, files.length, true);
  e.setUint32(12, centrals.reduce((sum, central) => sum + central.length, 0), true);
  e.setUint32(16, offset, true);
  const out = new Uint8Array([...locals, ...centrals, end].reduce((sum, part) => sum + part.length, 0));
  let p = 0;
  for (const part of [...locals, ...centrals, end]) {
    out.set(part, p);
    p += part.length;
  }
  return out;
}

/** A fetch that answers with parts of `bytes`, and like Workers' own, can't
 *  be called as another object's method. */
function partsOf(bytes) {
  return async function (url, init) {
    if (this !== undefined && this !== globalThis) throw new TypeError("Illegal invocation");
    const [, from, to] = /^bytes=(\d+)-(\d+)$/.exec(init.headers.Range);
    const end = Math.min(Number(to), bytes.length - 1);
    return new Response(bytes.slice(Number(from), end + 1), {
      status: 206,
      headers: { "Content-Range": `bytes ${from}-${end}/${bytes.length}` },
    });
  };
}

const request = (query, init) => new Request(`https://site.example/install/app${query}`, init);
const address = (ipa) => "?url=" + encodeURIComponent(ipa);

test("answers with the app as JSON", async () => {
  const ipa = zip(["Payload/Notes.app/Info.plist", INFO_PLIST]);
  const response = await installApp(request(address("https://example.com/Notes.ipa")), { fetch: partsOf(ipa) });
  assert.equal(response.status, 200);
  assert.equal(response.headers.get("Content-Type"), "application/json; charset=utf-8");
  assert.equal(response.headers.get("Cache-Control"), "public, max-age=600");
  assert.equal(response.headers.get("X-Content-Type-Options"), "nosniff");
  assert.deepEqual(await response.json(), {
    name: "Notes", version: "3.0", build: "12", bundleID: "org.example.notes", size: ipa.length, icon: null,
  });
});

test("the icon is a PNG's data: URL", async () => {
  // The smallest plain PNG there is: one see-through pixel.
  const png = Uint8Array.from(atob("iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg=="), (c) => c.charCodeAt(0));
  const plist = INFO_PLIST.replace("</dict>", "<key>CFBundleIconFiles</key><array><string>Icon</string></array></dict>");
  const ipa = zip(["Payload/Notes.app/Info.plist", plist], ["Payload/Notes.app/Icon.png", png]);
  const response = await installApp(request(address("https://example.com/Notes.ipa")), { fetch: partsOf(ipa) });
  const { icon } = await response.json();
  assert.equal(icon, `data:image/png;base64,${btoa(String.fromCharCode(...png))}`);
});

test("refuses addresses Atelier wouldn't download from", async () => {
  let fetched = false;
  const fetch = async () => {
    fetched = true;
    throw new Error("not expected");
  };
  for (const query of ["", "?url=", address("http://example.com/App.ipa"), address("javascript:alert(1)"), address("example.com/App.ipa"), address("https://")]) {
    const response = await installApp(request(query), { fetch });
    assert.equal(response.status, 400, query);
    assert.equal(response.headers.get("Cache-Control"), "no-store");
    assert.ok((await response.json()).error);
  }
  assert.equal(fetched, false);
});

test("says when the IPA can't be read, or reached", async () => {
  // A sign-in page rather than the IPA.
  const notAZip = async () => new Response("<htm", { status: 206, headers: { "Content-Range": "bytes 0-3/6" } });
  let response = await installApp(request(address("https://example.com/App.ipa")), { fetch: notAZip });
  assert.equal(response.status, 422);
  assert.equal(response.headers.get("Cache-Control"), "no-store");
  assert.deepEqual(await response.json(), { error: "The IPA can't be read: the IPA isn't a ZIP file." });

  const offline = async () => {
    throw new TypeError("Network connection lost.");
  };
  response = await installApp(request(address("https://example.com/App.ipa")), { fetch: offline });
  assert.equal(response.status, 502);
  assert.deepEqual(await response.json(), { error: "The IPA can't be reached: Network connection lost." });
});

test("only GET", async () => {
  const response = await installApp(request(address("https://example.com/App.ipa"), { method: "POST" }));
  assert.equal(response.status, 405);
  assert.equal(response.headers.get("Allow"), "GET");
});

test("everything else is the static files'", async () => {
  const asked = [];
  const env = { ASSETS: { fetch: async (request) => (asked.push(request.url), new Response("Not Found", { status: 404 })) } };
  const response = await worker.fetch(new Request("https://site.example/nowhere"), env);
  assert.equal(response.status, 404);
  assert.deepEqual(asked, ["https://site.example/nowhere"]);
  // /install/app and /source/info are the Worker's own, and checked before
  // anything is fetched.
  assert.equal((await worker.fetch(request("?url=nope"), env)).status, 400);
  assert.equal((await worker.fetch(sourceRequest("?url=nope"), env)).status, 400);
  assert.equal(asked.length, 1);
});

// MARK: /source/info

const sourceRequest = (query, init) => new Request(`https://site.example/source/info${query}`, init);
const SOURCE = {
  name: "Notes Source",
  iconURL: "https://example.com/source.png",
  apps: [{
    bundleIdentifier: "org.example.notes",
    name: "Notes",
    developerName: "Someone",
    iconURL: "https://example.com/notes.png",
    versions: [{ version: "3.0", buildVersion: "12", downloadURL: "https://example.com/Notes.ipa", size: 1000 }],
  }],
};

/** A fetch that answers with `body` as JSON, and like Workers' own, can't
 *  be called as another object's method. */
function answering(body, init) {
  return async function (url, options) {
    if (this !== undefined && this !== globalThis) throw new TypeError("Illegal invocation");
    answering.asked = { url, options };
    return new Response(JSON.stringify(body), init);
  };
}

test("answers with the source, and an app link's app, as JSON", async () => {
  let response = await sourceInfo(sourceRequest(address("https://example.com/apps.json")), { fetch: answering(SOURCE) });
  assert.equal(response.status, 200);
  assert.equal(response.headers.get("Content-Type"), "application/json; charset=utf-8");
  assert.equal(response.headers.get("Cache-Control"), "public, max-age=600");
  assert.equal(response.headers.get("X-Content-Type-Options"), "nosniff");
  assert.equal(answering.asked.url, "https://example.com/apps.json");
  assert.equal(answering.asked.options.headers.Accept, "application/json");
  assert.deepEqual(await response.json(), {
    name: "Notes Source",
    icon: "https://example.com/source.png",
    appCount: 1,
    apps: [{ name: "Notes", icon: "https://example.com/notes.png" }],
    app: null,
  });

  response = await sourceInfo(sourceRequest(address("https://example.com/apps.json") + "&bundleid=%20org.example.notes%20"), { fetch: answering(SOURCE) });
  assert.deepEqual((await response.json()).app, {
    name: "Notes", subtitle: null, developer: "Someone", version: "3.0 (12)", size: 1000, icon: "https://example.com/notes.png",
  });
});

test("refuses sources Atelier wouldn't add", async () => {
  let fetched = false;
  const fetch = async () => {
    fetched = true;
    throw new Error("not expected");
  };
  for (const query of ["", "?url=", address("http://example.com/apps.json"), address("javascript:alert(1)"), address("example.com/apps.json"), address("https://")]) {
    const response = await sourceInfo(sourceRequest(query), { fetch });
    assert.equal(response.status, 400, query);
    assert.equal(response.headers.get("Cache-Control"), "no-store");
    assert.ok((await response.json()).error);
  }
  assert.equal(fetched, false);
});

test("says when the source can't be read, or reached", async () => {
  let response = await sourceInfo(sourceRequest(address("https://example.com/apps.json")), { fetch: answering("Not Found", { status: 404 }) });
  assert.equal(response.status, 422);
  assert.equal(response.headers.get("Cache-Control"), "no-store");
  assert.deepEqual(await response.json(), { error: "The source can't be read: the server answered HTTP 404." });

  response = await sourceInfo(sourceRequest(address("https://example.com/apps.json")), { fetch: answering([1, 2]) });
  assert.equal(response.status, 422);
  assert.deepEqual(await response.json(), { error: "The source can't be read: the source isn't a JSON object." });

  const offline = async () => {
    throw new TypeError("Network connection lost.");
  };
  response = await sourceInfo(sourceRequest(address("https://example.com/apps.json")), { fetch: offline });
  assert.equal(response.status, 502);
  assert.deepEqual(await response.json(), { error: "The source can't be reached: Network connection lost." });
});

test("only GET for sources too", async () => {
  const response = await sourceInfo(sourceRequest(address("https://example.com/apps.json"), { method: "POST" }));
  assert.equal(response.status, 405);
  assert.equal(response.headers.get("Allow"), "GET");
});
