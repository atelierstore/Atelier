import { test } from "node:test";
import assert from "node:assert/strict";
import { serialize } from "node:v8";

import worker, { BuildApp as exported, withOwnBuilds } from "../src/index.js";
import { BuildApp, LIFETIME, builds } from "../src/builds.js";
import { MAX_SIZE } from "../src/ota.js";
import { buildClaims, githubSigner } from "./github-token.js";

const SITE = "https://site.example";
const INFO_PLIST = `<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>com.atelier.app</string>
<key>CFBundleDisplayName</key><string>Atelier</string>
<key>CFBundleShortVersionString</key><string>0.5.1</string>
<key>CFBundleVersion</key><string>1042</string>
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

/** Atelier, with an executable of `filler` bytes before its Info.plist. */
function atelier(filler = 1000, plist = INFO_PLIST) {
  return zip(["Payload/Atelier.app/Atelier", new Uint8Array(filler).map((_, i) => i * 7)], ["Payload/Atelier.app/Info.plist", plist]);
}

/** A Durable Object's storage, as in ota.test.js. */
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
    assert.ok(key.length + serialize(value).length <= 2_000_000, `${key} is too large`);
    this.values.set(key, structuredClone(value));
  }

  async deleteAll() {
    this.values.clear();
    this.alarm = null;
  }

  async setAlarm(time) {
    this.alarm = Number(time);
  }
}

/** BuildApp's namespace, whose objects live as long as it does. */
function namespace() {
  const objects = new Map();
  return {
    objects,
    idFromName: (name) => `id:${name}`,
    get(id) {
      if (!objects.has(id)) objects.set(id, new BuildApp({ storage: new Storage() }));
      const object = objects.get(id);
      return { fetch: (input, init) => object.fetch(new Request(input, init)) };
    },
  };
}

/** A KV namespace, with the options each value was put with. */
class KV {
  values = new Map();
  options = new Map();

  async get(key, type) {
    const value = this.values.get(key) ?? null;
    return type === "json" && value !== null ? JSON.parse(value) : value;
  }

  async put(key, value, options) {
    assert.equal(typeof value, "string");
    this.values.set(key, value);
    this.options.set(key, options);
  }
}

/** What a test needs: BuildApp's namespace, the env, GitHub and a token. */
async function setUp() {
  const github = await githubSigner();
  const env = { BUILDS_REPOSITORY: "atelierstore/Atelier", BUILDS_REPOSITORY_ID: "1453990179", BUILDS: new KV() };
  return {
    github,
    env,
    apps: namespace(),
    token: (changes) => github.sign(buildClaims(SITE, changes)),
  };
}

function request(t, path, { method = "GET", token, body, headers = {} } = {}) {
  const init = { method, headers: { ...headers, ...(token ? { Authorization: `Bearer ${token}` } : {}) } };
  if (body !== undefined) {
    init.body = body;
    init.duplex = "half";
  }
  return builds(new Request(`${SITE}${path}`, init), t.env, t.apps, { keys: t.github.keys });
}

async function upload(t, file, ipa = atelier(), token) {
  const response = await request(t, `/builds/${file}`, { method: "POST", token: token ?? (await t.token()), body: ipa });
  assert.equal(response.status, 201, await response.clone().text());
  return response.json();
}

async function record(t, files, { commit = "b".repeat(40), changes } = {}) {
  return request(t, "/builds", {
    method: "POST",
    token: await t.token(changes),
    body: JSON.stringify({ commit, files }),
    headers: { "Content-Type": "application/json" },
  });
}

test("a build's IPA is kept for 7 days, at an address of its own", async () => {
  const t = await setUp();
  const before = Date.now();
  const ipa = atelier();
  const { url, expires } = await upload(t, "Atelier-unsigned.ipa", ipa);
  const [, token] = /^https:\/\/site\.example\/builds\/([0-9a-f]{32})\/Atelier-unsigned\.ipa$/.exec(url);
  const expiry = Date.parse(expires);
  assert.ok(expiry >= before + LIFETIME && expiry <= Date.now() + LIFETIME);
  const object = t.apps.objects.get(`id:${token}`);
  assert.equal(object.storage.alarm, expiry);

  const head = await request(t, `/builds/${token}/Atelier-unsigned.ipa`, { method: "HEAD" });
  assert.equal(head.status, 200);
  assert.equal(head.headers.get("Content-Length"), String(ipa.length));
  const response = await request(t, `/builds/${token}/Atelier-unsigned.ipa`);
  assert.equal(response.status, 200);
  assert.deepEqual(new Uint8Array(await response.arrayBuffer()), ipa);
  const range = await request(t, `/builds/${token}/Atelier-unsigned.ipa`, { headers: { Range: "bytes=10-19" } });
  assert.equal(range.status, 206);
  assert.deepEqual(new Uint8Array(await range.arrayBuffer()), ipa.slice(10, 20));

  // Downloading it, however often, doesn't shorten its 7 days.
  assert.equal(object.storage.alarm, expiry);
  assert.equal(object.storage.values.get("app").expires, expiry);

  await object.alarm();
  assert.equal((await request(t, `/builds/${token}/Atelier-unsigned.ipa`)).status, 404);
});

test("an IPA's address only works with its own file name", async () => {
  const t = await setUp();
  const { url } = await upload(t, "Atelier.ipa");
  const token = url.split("/")[4];
  assert.equal((await request(t, `/builds/${token}/Atelier.ipa`)).status, 200);
  assert.equal((await request(t, `/builds/${token}/Atelier-unsigned.ipa`)).status, 404);
  for (const path of [`/builds/${token}/other.ipa`, `/builds/${token.toUpperCase()}/Atelier.ipa`, `/builds/${token}/Atelier.ipa/x`, "/builds/nothex/Atelier.ipa"]) {
    assert.equal((await request(t, path)).status, 404, path);
  }
});

test("a signed build has the manifest iOS's install alert reads", async () => {
  const t = await setUp();
  const { url } = await upload(t, "Atelier.ipa");
  const token = url.split("/")[4];
  const response = await request(t, `/builds/${token}/manifest.plist`);
  assert.equal(response.status, 200);
  assert.equal(response.headers.get("Content-Type"), "application/xml; charset=utf-8");
  const text = await response.text();
  assert.ok(text.includes(`<string>${url}</string>`), text);
  assert.match(text, /<key>bundle-identifier<\/key>\s*<string>com.atelier.app<\/string>/);
  assert.equal((await request(t, `/builds/${"0".repeat(32)}/manifest.plist`)).status, 404);
});

test("the build's record lists its files and links, and goes to KV under its commit, branch and pull request", async () => {
  const t = await setUp();
  const signed = await upload(t, "Atelier.ipa");
  const unsigned = await upload(t, "Atelier-unsigned.ipa", atelier(2000));
  const response = await record(t, [{ url: signed.url, signed: true }, { url: unsigned.url, signed: false }]);
  assert.equal(response.status, 201);
  const build = await response.json();
  const signedToken = signed.url.split("/")[4];
  assert.deepEqual({ ...build, created: undefined, expires: undefined }, {
    repository: "atelierstore/Atelier",
    commit: "b".repeat(40),
    branch: "github-actions",
    pr: 12,
    version: "0.5.1",
    build: "1042",
    run: "https://github.com/atelierstore/Atelier/actions/runs/1000",
    runID: 1000,
    created: undefined,
    expires: undefined,
    files: [
      {
        name: "Atelier.ipa",
        url: signed.url,
        signed: true,
        size: atelier().length,
        install: `itms-services://?action=download-manifest&url=${encodeURIComponent(`${SITE}/builds/${signedToken}/manifest.plist`)}`,
      },
      { name: "Atelier-unsigned.ipa", url: unsigned.url, signed: false, size: atelier(2000).length },
    ],
    install: `${SITE}/install?url=${encodeURIComponent(unsigned.url)}`,
  });
  assert.equal(build.expires, signed.expires < unsigned.expires ? signed.expires : unsigned.expires);

  const kv = t.env.BUILDS;
  assert.deepEqual([...kv.values.keys()].sort(), [`branch/github-actions`, `commit/${"b".repeat(40)}`, "pr/12"]);
  for (const [key, value] of kv.values) {
    assert.deepEqual(JSON.parse(value), build, key);
    assert.equal(kv.options.get(key).expiration, Math.floor(Date.parse(build.expires) / 1000));
  }
});

test("main's builds are recorded under main, with the commit pushed", async () => {
  const t = await setUp();
  const unsigned = await upload(t, "Atelier-unsigned.ipa");
  const sha = "c".repeat(40);
  // A push's build is of the commit pushed, which the token says.
  const response = await record(t, [{ url: unsigned.url }], {
    commit: null,
    changes: { event_name: "push", ref: "refs/heads/main", head_ref: "", sha, job_workflow_ref: "atelierstore/Atelier/.github/workflows/build.yml@refs/heads/main" },
  });
  assert.equal(response.status, 201);
  const build = await response.json();
  assert.equal(build.branch, "main");
  assert.equal(build.pr, null);
  assert.equal(build.commit, sha);
  assert.equal(build.files[0].signed, false);
  assert.equal(build.files[0].install, undefined);
  assert.deepEqual([...t.env.BUILDS.values.keys()].sort(), ["branch/main", `commit/${sha}`]);
});

test("an earlier run's build doesn't replace a later run's as the branch's", async () => {
  const t = await setUp();
  const later = await upload(t, "Atelier-unsigned.ipa");
  assert.equal((await record(t, [{ url: later.url }], { commit: "d".repeat(40), changes: { run_id: "2000" } })).status, 201);
  const earlier = await upload(t, "Atelier-unsigned.ipa");
  assert.equal((await record(t, [{ url: earlier.url }], { commit: "e".repeat(40), changes: { run_id: "1999" } })).status, 201);

  const kv = t.env.BUILDS;
  assert.equal((await kv.get("branch/github-actions", "json")).commit, "d".repeat(40));
  assert.equal((await kv.get("pr/12", "json")).commit, "d".repeat(40));
  assert.equal((await kv.get(`commit/${"e".repeat(40)}`, "json")).runID, 1999);

  // A run's next attempt has the same run ID, and replaces it.
  const again = await upload(t, "Atelier-unsigned.ipa");
  assert.equal((await record(t, [{ url: again.url }], { commit: "f".repeat(40), changes: { run_id: "2000", run_attempt: "2" } })).status, 201);
  assert.equal((await kv.get("branch/github-actions", "json")).commit, "f".repeat(40));
});

test("without the KV namespace, builds are kept but not recorded", async () => {
  const t = await setUp();
  delete t.env.BUILDS;
  const unsigned = await upload(t, "Atelier-unsigned.ipa");
  assert.equal((await record(t, [{ url: unsigned.url }])).status, 201);
});

test("a record only names this site's builds, each once", async () => {
  const t = await setUp();
  const { url } = await upload(t, "Atelier-unsigned.ipa");
  const token = url.split("/")[4];
  const refused = async (files, status) => {
    const response = await record(t, files);
    assert.equal(response.status, status, JSON.stringify(files));
    assert.ok((await response.json()).error);
  };
  await refused([], 400);
  await refused([{ url }, { url }, { url }], 400);
  await refused([{ url }, { url }], 400);
  await refused([{ url: url.replace(SITE, "https://other.example") }], 422);
  await refused([{ url: `${SITE}/builds/${token}/Atelier.ipa` }], 422);
  await refused([{ url: `${SITE}/builds/${"0".repeat(32)}/Atelier-unsigned.ipa` }], 422);
  await refused([{ url: `${url}?x=1` }], 422);
  await refused([{ url: 42 }], 422);
  const notJSON = await request(t, "/builds", { method: "POST", token: await t.token(), body: "{" });
  assert.equal(notJSON.status, 400);
  assert.equal(t.env.BUILDS.values.size, 0);
});

test("only the repo's build workflow, on GitHub's runners, can send builds", async () => {
  const t = await setUp();
  const refused = async (token, status, message) => {
    const response = await request(t, "/builds/Atelier-unsigned.ipa", { method: "POST", token, body: atelier() });
    assert.equal(response.status, status);
    assert.match((await response.json()).error, message);
  };
  await refused(undefined, 401, /no GitHub Actions token/);
  await refused("not-a-token", 401, /isn't accepted: it isn't a JWT/);
  await refused(await t.github.sign(buildClaims("https://other.example")), 401, /another audience/);
  await refused(await t.token({ repository: "someone/Atelier" }), 403, /Only atelierstore\/Atelier's builds/);
  await refused(await t.token({ repository_id: "1" }), 403, /Only atelierstore\/Atelier's builds/);
  await refused(await t.token({ job_workflow_ref: "atelierstore/Atelier/.github/workflows/other.yml@refs/heads/main" }), 403, /build.yml/);
  await refused(await t.token({ job_workflow_ref: "someone/Atelier/.github/workflows/build.yml@refs/heads/main" }), 403, /build.yml/);
  await refused(await t.token({ runner_environment: "self-hosted" }), 403, /GitHub's own runners/);
  await refused(await t.token({ event_name: "schedule" }), 403, /schedule/);
  assert.equal(t.apps.objects.size, 0, "nothing was kept");

  // GitHub's names ignore case.
  await upload(t, "Atelier-unsigned.ipa", atelier(), await t.token({ repository: "AtelierStore/atelier", job_workflow_ref: "AtelierStore/atelier/.github/workflows/build.yml@refs/heads/main" }));

  delete t.env.BUILDS_REPOSITORY;
  await refused(await t.token(), 403, /doesn't keep builds/);
});

test("without a repository ID set, any repo of that name is accepted", async () => {
  const t = await setUp();
  delete t.env.BUILDS_REPOSITORY_ID;
  await upload(t, "Atelier-unsigned.ipa", atelier(), await t.token({ repository_id: "1" }));
});

test("GitHub's keys being out of reach is a 503", async () => {
  const t = await setUp();
  const token = await t.token();
  t.github.answer = () => new Response("", { status: 502 });
  const response = await request(t, "/builds/Atelier-unsigned.ipa", { method: "POST", token, body: atelier() });
  assert.equal(response.status, 503);
});

test("builds are Atelier, up to the size limit", async () => {
  const t = await setUp();
  const other = await request(t, "/builds/Atelier-unsigned.ipa", {
    method: "POST",
    token: await t.token(),
    body: atelier(10, INFO_PLIST.replace("com.atelier.app", "com.example.other")),
  });
  assert.equal(other.status, 422);
  const large = await request(t, "/builds/Atelier-unsigned.ipa", {
    method: "POST",
    token: await t.token(),
    body: new Uint8Array(10),
    headers: { "Content-Length": String(MAX_SIZE + 1) },
  });
  assert.equal(large.status, 413);
});

test("other files and methods are 404s and 405s", async () => {
  const t = await setUp();
  const token = await t.token();
  assert.equal((await request(t, "/builds/other.ipa", { method: "POST", token, body: atelier() })).status, 404);
  assert.equal((await request(t, "/builds")).status, 405);
  assert.equal((await request(t, "/builds/Atelier.ipa")).status, 405);
  const { url } = await upload(t, "Atelier.ipa");
  const path = new URL(url).pathname;
  const put = await request(t, path, { method: "PUT", body: "x" });
  assert.equal(put.status, 405);
  assert.equal(put.headers.get("Allow"), "GET, HEAD");
  assert.equal((await request(t, path.replace("Atelier.ipa", "manifest.plist"), { method: "POST", body: "x" })).status, 405);
});

test("the Worker sends /builds to BuildApp's namespace, and reads its own builds for install links", async () => {
  // ctx.exports only has what the Worker's main module exports.
  assert.equal(exported, BuildApp);
  const t = await setUp();
  const { url } = await upload(t, "Atelier-unsigned.ipa");
  const ctx = { exports: { BuildApp: t.apps } };
  assert.equal((await worker.fetch(new Request(url), t.env, ctx)).status, 200);

  // The install link page's request reads the build from its object, not
  // over the network.
  const original = globalThis.fetch;
  globalThis.fetch = async () => assert.fail("fetched over the network");
  try {
    const fetchImpl = withOwnBuilds(new Request(`${SITE}/install/app`), t.env, ctx);
    const response = await fetchImpl(url, { headers: { Range: "bytes=0-9" } });
    assert.equal(response.status, 206);
    const app = await worker.fetch(new Request(`${SITE}/install/app?url=${encodeURIComponent(url)}`), t.env, ctx);
    assert.equal(app.status, 200);
    const info = await app.json();
    assert.equal(info.bundleID, "com.atelier.app");
    assert.equal(info.version, "0.5.1");
    assert.equal(info.build, "1042");
  } finally {
    globalThis.fetch = original;
  }
});
