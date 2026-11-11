import { test } from "node:test";
import assert from "node:assert/strict";
import { serialize } from "node:v8";

import worker, { SignedApp as exported } from "../src/index.js";
import { AFTER_DOWNLOAD, LIFETIME, MAX_SIZE, PART_SIZE, SignedApp, byteRange, manifest, ota } from "../src/ota.js";

const INFO_PLIST = `<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>com.atelier.app</string>
<key>CFBundleDisplayName</key><string>Atelier</string>
<key>CFBundleShortVersionString</key><string>0.5.0-alpha</string>
<key>CFBundleVersion</key><string>120</string>
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
  const parts = [...locals, ...centrals, end];
  const out = new Uint8Array(parts.reduce((sum, part) => sum + part.length, 0));
  let p = 0;
  for (const part of parts) {
    out.set(part, p);
    p += part.length;
  }
  return out;
}

const PLIST_PATH = "Payload/Atelier.app/Info.plist";
const FILLER_PATH = "Payload/Atelier.app/Atelier";

/** Atelier, with an executable of `filler` bytes before its Info.plist. */
function atelier(filler = 1000) {
  const executable = new Uint8Array(filler).map((_, i) => i * 7);
  return zip([FILLER_PATH, executable], [PLIST_PATH, INFO_PLIST]);
}

/** A Durable Object's storage, which keeps copies, as the real one keeps
 *  values written out, and refuses values over 2 MB. */
class Storage {
  values = new Map();
  alarm = null;

  async get(key) {
    if (Array.isArray(key)) {
      return new Map(key.filter((one) => this.values.has(one)).map((one) => [one, structuredClone(this.values.get(one))]));
    }
    return this.values.has(key) ? structuredClone(this.values.get(key)) : undefined;
  }

  async put(key, value) {
    // As the runtime writes it: a view of a larger buffer takes all of it.
    const size = key.length + serialize(value).length;
    assert.ok(size <= 2_000_000, `${key} is ${size} bytes`);
    this.values.set(key, structuredClone(value));
  }

  async deleteAll() {
    this.values.clear();
    this.alarm = null;
  }

  async setAlarm(time) {
    this.alarm = Number(time);
  }

  async getAlarm() {
    return this.alarm;
  }
}

/** SignedApp's namespace, whose objects live as long as it does. */
function namespace() {
  const objects = new Map();
  return {
    objects,
    idFromName: (name) => `id:${name}`,
    get(id) {
      if (!objects.has(id)) objects.set(id, new SignedApp({ storage: new Storage() }));
      const object = objects.get(id);
      return { fetch: (input, init) => object.fetch(new Request(input, init)) };
    },
  };
}

const SITE = "https://site.example";

async function upload(apps, body, headers = {}) {
  return ota(new Request(`${SITE}/ota`, { method: "POST", body, headers, duplex: "half" }), apps);
}

/** Uploads Atelier, and answers with the upload's object and addresses. */
async function uploaded(apps, ipa = atelier()) {
  const response = await upload(apps, ipa);
  assert.equal(response.status, 201);
  const answer = await response.json();
  const token = new URL(answer.status).pathname.split("/")[2];
  return { answer, token, object: apps.objects.get(`id:${token}`), ipa };
}

const get = (apps, path, init) => ota(new Request(`${SITE}${path}`, init), apps);

/** A body that sends `size` bytes, a megabyte at a time. */
function stream(size) {
  let sent = 0;
  return new ReadableStream({
    pull(controller) {
      if (sent >= size) return controller.close();
      const count = Math.min(PART_SIZE, size - sent);
      controller.enqueue(new Uint8Array(count));
      sent += count;
    },
  });
}

test("an upload answers with iOS's install link, and is kept until its alarm", async () => {
  const apps = namespace();
  const before = Date.now();
  const { answer, token, object } = await uploaded(apps);
  assert.match(token, /^[0-9a-f]{32}$/);
  assert.equal(answer.status, `${SITE}/ota/${token}`);
  assert.equal(
    answer.install,
    `itms-services://?action=download-manifest&url=${encodeURIComponent(`${SITE}/ota/${token}/manifest.plist`)}`,
  );
  const expires = Date.parse(answer.expires);
  assert.ok(expires >= before + LIFETIME && expires <= Date.now() + LIFETIME);
  assert.equal(object.storage.alarm, expires);

  const status = await get(apps, `/ota/${token}`);
  assert.equal(status.headers.get("Cache-Control"), "no-store");
  assert.deepEqual(await status.json(), { state: "waiting", expires: answer.expires, version: "0.5.0-alpha", size: atelier().length });

  await object.alarm();
  assert.equal(object.storage.values.size, 0);
  assert.equal((await get(apps, `/ota/${token}`)).status, 404);
  assert.equal((await get(apps, `/ota/${token}/manifest.plist`)).status, 404);
  assert.equal((await get(apps, `/ota/${token}/Atelier.ipa`)).status, 404);
});

test("each upload has its own token", async () => {
  const apps = namespace();
  const first = await uploaded(apps);
  const second = await uploaded(apps);
  assert.notEqual(first.token, second.token);
  assert.equal(apps.objects.size, 2);
});

test("the manifest names the IPA, Atelier's icon and the app in the IPA", async () => {
  const apps = namespace();
  const { token } = await uploaded(apps);
  const response = await get(apps, `/ota/${token}/manifest.plist`);
  assert.equal(response.status, 200);
  assert.equal(response.headers.get("Content-Type"), "application/xml; charset=utf-8");
  const text = await response.text();
  assert.match(text, new RegExp(`<string>${SITE}/ota/${token}/Atelier.ipa</string>`));
  assert.match(text, /<key>kind<\/key>\s*<string>display-image<\/string>\s*<key>url<\/key>\s*<string>https:\/\/site.example\/apple-touch-icon.png<\/string>/);
  assert.match(text, /<key>bundle-identifier<\/key>\s*<string>com.atelier.app<\/string>/);
  assert.match(text, /<key>bundle-version<\/key>\s*<string>0.5.0-alpha<\/string>/);
  assert.match(text, /<key>title<\/key>\s*<string>Atelier<\/string>/);
});

test("iOS reading the manifest means it asks the user, until it asks for the IPA", async () => {
  const apps = namespace();
  const { token } = await uploaded(apps);
  const state = async () => (await (await get(apps, `/ota/${token}`)).json()).state;
  assert.equal(await state(), "waiting");
  assert.equal((await get(apps, `/ota/${token}/manifest.plist`)).status, 200);
  assert.equal(await state(), "asked");
  // iOS can read it again, as when the user tries again.
  assert.equal((await get(apps, `/ota/${token}/manifest.plist`)).status, 200);
  assert.equal(await state(), "asked");
  await (await get(apps, `/ota/${token}/Atelier.ipa`)).arrayBuffer();
  assert.equal(await state(), "downloaded");
  // Not back to asked once iOS has it.
  assert.equal((await get(apps, `/ota/${token}/manifest.plist`)).status, 200);
  assert.equal(await state(), "downloaded");
});

test("an install that's asked starts downloading with the IPA's first request", async () => {
  const apps = namespace();
  const { token } = await uploaded(apps);
  await get(apps, `/ota/${token}/manifest.plist`);
  await get(apps, `/ota/${token}/Atelier.ipa`, { method: "HEAD" });
  assert.equal((await (await get(apps, `/ota/${token}`)).json()).state, "downloading");
});

test("manifests keep to XML", () => {
  const text = manifest({ ipa: "https://a.example/x?a=1&b=2", image: "https://a.example/i.png", bundleID: "com.atelier.app", version: "1<2>", name: "At\u0001elier & co" });
  assert.match(text, /<string>https:\/\/a.example\/x\?a=1&amp;b=2<\/string>/);
  assert.match(text, /<string>1&lt;2&gt;<\/string>/);
  assert.match(text, /<string>Atelier &amp; co<\/string>/);
});

test("iOS gets the IPA's size from HEAD, and HEAD starts the install", async () => {
  const apps = namespace();
  const { token, ipa } = await uploaded(apps);
  const response = await get(apps, `/ota/${token}/Atelier.ipa`, { method: "HEAD" });
  assert.equal(response.status, 200);
  assert.equal(response.headers.get("Content-Length"), String(ipa.length));
  assert.equal(response.headers.get("Content-Type"), "application/octet-stream");
  assert.equal(response.headers.get("Accept-Ranges"), "bytes");
  assert.equal(response.body, null);
  assert.equal((await (await get(apps, `/ota/${token}`)).json()).state, "downloading");
});

test("once iOS has all of the IPA, it goes a minute later", async () => {
  const apps = namespace();
  // Across parts, with Info.plist across the first two.
  const filler = PART_SIZE - 60 - FILLER_PATH.length - PLIST_PATH.length - 10;
  const { token, object, ipa } = await uploaded(apps, atelier(filler + 2 * PART_SIZE));
  assert.equal(object.storage.values.get("app").parts, Math.ceil(ipa.length / PART_SIZE));

  const response = await get(apps, `/ota/${token}/Atelier.ipa`);
  assert.equal(response.status, 200);
  assert.equal(response.headers.get("Content-Length"), String(ipa.length));
  assert.deepEqual(new Uint8Array(await response.arrayBuffer()), ipa);

  const status = await (await get(apps, `/ota/${token}`)).json();
  assert.equal(status.state, "downloaded");
  const expires = Date.parse(status.expires);
  assert.ok(expires <= Date.now() + AFTER_DOWNLOAD);
  assert.equal(object.storage.alarm, expires);
});

test("Info.plist is read across parts", async () => {
  const apps = namespace();
  const filler = PART_SIZE - 60 - FILLER_PATH.length - PLIST_PATH.length - 10;
  const { object } = await uploaded(apps, atelier(filler));
  assert.equal(object.storage.values.get("app").version, "0.5.0-alpha");
  assert.equal(object.storage.values.get("app").build, "120");
});

test("a range of the IPA is sent as asked, and doesn't count as iOS having it", async () => {
  const apps = namespace();
  const { token, ipa } = await uploaded(apps, atelier(3 * PART_SIZE));
  const start = PART_SIZE - 5;
  const end = 2 * PART_SIZE + 5;
  const response = await get(apps, `/ota/${token}/Atelier.ipa`, { headers: { Range: `bytes=${start}-${end}` } });
  assert.equal(response.status, 206);
  assert.equal(response.headers.get("Content-Range"), `bytes ${start}-${end}/${ipa.length}`);
  assert.equal(response.headers.get("Content-Length"), String(end - start + 1));
  assert.deepEqual(new Uint8Array(await response.arrayBuffer()), ipa.slice(start, end + 1));
  assert.equal((await (await get(apps, `/ota/${token}`)).json()).state, "downloading");

  const outside = await get(apps, `/ota/${token}/Atelier.ipa`, { headers: { Range: `bytes=${ipa.length}-` } });
  assert.equal(outside.status, 416);
  assert.equal(outside.headers.get("Content-Range"), `bytes */${ipa.length}`);
});

test("ranges are read as route B reads them", () => {
  assert.equal(byteRange(null, 100), null);
  assert.deepEqual(byteRange("bytes=0-9", 100), { start: 0, end: 9 });
  assert.deepEqual(byteRange("bytes=90-", 100), { start: 90, end: 99 });
  assert.deepEqual(byteRange("bytes=-10", 100), { start: 90, end: 99 });
  assert.deepEqual(byteRange("bytes=50-500", 100), { start: 50, end: 99 });
  assert.equal(byteRange("bytes=0-1,5-6", 100), null);
  assert.throws(() => byteRange("bytes=100-", 100), RangeError);
  assert.throws(() => byteRange("bytes=9-3", 100), RangeError);
  assert.throws(() => byteRange("bytes=-0", 100), RangeError);
  assert.throws(() => byteRange("bytes=x-3", 100), RangeError);
});

test("only Atelier is kept", async () => {
  const apps = namespace();
  const other = zip([PLIST_PATH, INFO_PLIST.replace("com.atelier.app", "com.example.other")]);
  const response = await upload(apps, other);
  assert.equal(response.status, 422);
  assert.deepEqual(await response.json(), { error: "This site only installs Atelier." });
  const [object] = apps.objects.values();
  assert.equal(object.storage.values.size, 0);
  assert.equal(object.storage.alarm, null);
});

test("what isn't an IPA isn't kept", async () => {
  const apps = namespace();
  const response = await upload(apps, new TextEncoder().encode("not an IPA"));
  assert.equal(response.status, 422);
  assert.match((await response.json()).error, /^The IPA can't be read: /);
  const [object] = apps.objects.values();
  assert.equal(object.storage.values.size, 0);
});

test("an IPA over the limit is refused, whether or not it says its size", async () => {
  const apps = namespace();
  const declared = await upload(apps, new Uint8Array(10), { "Content-Length": String(MAX_SIZE + 1) });
  assert.equal(declared.status, 413);
  assert.equal(apps.objects.size, 0);

  const streamed = await upload(apps, stream(MAX_SIZE + 1));
  assert.equal(streamed.status, 413);
  const [object] = apps.objects.values();
  assert.equal(object.storage.values.size, 0);
  assert.equal(object.storage.alarm, null);
});

test("an upload that stops part way isn't kept", async () => {
  const apps = namespace();
  let sent = false;
  const body = new ReadableStream({
    pull(controller) {
      if (sent) return controller.error(new Error("the connection closed"));
      controller.enqueue(new Uint8Array(PART_SIZE + 1));
      sent = true;
    },
  });
  const response = await upload(apps, body);
  assert.equal(response.status, 400);
  const [object] = apps.objects.values();
  assert.equal(object.storage.values.size, 0);
});

test("addresses that aren't an upload's are 404s, and other methods 405s", async () => {
  const apps = namespace();
  const { token } = await uploaded(apps);
  for (const path of ["/ota/nothex", `/ota/${token.toUpperCase()}`, `/ota/${token}/`, `/ota/${token}/other.ipa`, `/ota/${token}/Atelier.ipa/more`]) {
    assert.equal((await get(apps, path)).status, 404, path);
  }
  assert.equal((await get(apps, "/ota")).status, 405);
  assert.equal((await get(apps, `/ota/${token}`, { method: "DELETE" })).status, 405);
  assert.equal((await get(apps, `/ota/${token}/manifest.plist`, { method: "POST" })).status, 405);
  const put = await get(apps, `/ota/${token}/Atelier.ipa`, { method: "PUT", body: "x" });
  assert.equal(put.status, 405);
  assert.equal(put.headers.get("Allow"), "GET, HEAD");
});

test("the Worker sends /ota to SignedApp's namespace in ctx.exports", async () => {
  // ctx.exports only has what the Worker's main module exports.
  assert.equal(exported, SignedApp);
  const apps = namespace();
  const ctx = { exports: { SignedApp: apps } };
  const response = await worker.fetch(new Request(`${SITE}/ota`, { method: "POST", body: atelier() }), {}, ctx);
  assert.equal(response.status, 201);
  const { status } = await response.json();
  assert.equal((await worker.fetch(new Request(status), {}, ctx)).status, 200);
});

// MARK: Releases

const RELEASE = "https://github.com/atelierstore/Atelier/releases/download/v0.5.0-alpha/Atelier.ipa";
const releaseRequest = (address) => new Request(`${SITE}/ota/release?url=${encodeURIComponent(address)}`);

test("a release's IPA is passed on from GitHub", async () => {
  const asked = [];
  const fetchImpl = async (url, init) => {
    asked.push([url, init.headers["User-Agent"]]);
    return new Response("IPA", { headers: { "Content-Length": "3" } });
  };
  const response = await ota(releaseRequest(RELEASE), namespace(), fetchImpl);
  assert.equal(response.status, 200);
  assert.equal(await response.text(), "IPA");
  assert.equal(response.headers.get("Content-Type"), "application/octet-stream");
  assert.equal(response.headers.get("Content-Length"), "3");
  assert.equal(response.headers.get("Cache-Control"), "public, max-age=3600");
  assert.deepEqual(asked, [[RELEASE, "Atelier"]]);
});

test("only Atelier's releases are passed on", async () => {
  const fetchImpl = async () => assert.fail("asked GitHub");
  for (const address of [
    "https://github.com/someone/Atelier/releases/download/v1/Atelier.ipa",
    "https://github.com/atelierstore/Atelier/releases/download/v1/notes.txt",
    "https://github.com/atelierstore/Atelier/releases/download/v1/../../x.ipa",
    "https://github.com/atelierstore/Atelier/releases/download/../x.ipa",
    "http://github.com/atelierstore/Atelier/releases/download/v1/Atelier.ipa",
    "https://example.com/atelierstore/Atelier/releases/download/v1/Atelier.ipa",
  ]) {
    assert.equal((await ota(releaseRequest(address), namespace(), fetchImpl)).status, 400, address);
  }
});

test("GitHub's problems are 502s, and a release over the limit a 413", async () => {
  const missing = await ota(releaseRequest(RELEASE), namespace(), async () => new Response("Not Found", { status: 404 }));
  assert.equal(missing.status, 502);
  assert.deepEqual(await missing.json(), { error: "GitHub answered HTTP 404." });
  const unreachable = await ota(releaseRequest(RELEASE), namespace(), async () => {
    throw new TypeError("fetch failed");
  });
  assert.equal(unreachable.status, 502);
  const large = await ota(releaseRequest(RELEASE), namespace(), async () => new Response("x", { headers: { "Content-Length": String(MAX_SIZE + 1) } }));
  assert.equal(large.status, 413);
});
