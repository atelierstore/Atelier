import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync, readdirSync } from "node:fs";

import worker, { SiteStats as exported } from "../src/index.js";
import { BuildApp } from "../src/builds.js";
import { KEEP_DAYS, MAX_NAMES, MAX_SOURCES, SiteStats, dayOf, namesFor, sourceName, statsData, summarize, tallyReport } from "../src/stats.js";
import { deviceKind, visitFrom } from "../public/tally.js";

const SITE = "https://site.example";
const DAY = 24 * 60 * 60 * 1000;

/** A Durable Object's storage, with what SiteStats uses: keys in order, as
 *  the real one lists them, and copies of values. */
class Storage {
  values = new Map();

  async get(key) {
    return this.values.has(key) ? structuredClone(this.values.get(key)) : undefined;
  }

  async put(key, value) {
    this.values.set(key, structuredClone(value));
  }

  async delete(keys) {
    assert.ok(keys.length <= 128, "a delete takes up to 128 keys");
    for (const key of keys) this.values.delete(key);
  }

  async list({ start, end }) {
    const keys = [...this.values.keys()].filter((key) => key >= start && key < end).sort();
    return new Map(keys.map((key) => [key, structuredClone(this.values.get(key))]));
  }
}

/** SiteStats' namespace, with its one object. */
function namespace() {
  const objects = new Map();
  return {
    objects,
    idFromName: (name) => `id:${name}`,
    get(id) {
      if (!objects.has(id)) objects.set(id, new SiteStats({ storage: new Storage() }));
      const object = objects.get(id);
      return { fetch: (input, init) => object.fetch(new Request(input, init)) };
    },
  };
}

/** The site's counts in `stats`, by day. */
function counts(stats) {
  const object = stats.objects.get("id:site");
  return object ? Object.fromEntries([...object.storage.values].map(([key, value]) => [key.slice(4), value])) : {};
}

function report(body, country, init = {}) {
  const request = new Request(`${SITE}/tally`, { method: "POST", body: typeof body === "string" ? body : JSON.stringify(body), ...init });
  // Workers set request.cf; Node's Request has none.
  Object.defineProperty(request, "cf", { value: country === undefined ? undefined : { country } });
  return request;
}

// MARK: What pages send

test("a view from another of the site's pages counts as a view only", () => {
  assert.deepEqual(namesFor({ page: "/sideload", from: null, device: "iphone" }, "US"), ["view:sideload"]);
  assert.deepEqual(namesFor({ page: "/certificate.html" }, "US"), ["view:certificate"]);
  assert.deepEqual(namesFor({ page: "/certificate/install", from: null }, "US"), ["view:certificate-install"]);
});

test("a visit counts where it's from, its country and its device", () => {
  assert.deepEqual(namesFor({ page: "/install", from: "reddit.com", device: "iphone" }, "US"), [
    "view:install", "visit", "visit:country:US", "visit:device:iphone", "visit:from:reddit.com",
  ]);
  assert.deepEqual(namesFor({ page: "/search", from: "", device: "computer" }, "GB"), [
    "view:search", "visit", "visit:country:GB", "visit:device:computer", "visit:from:none",
  ]);
});

test("the home page counts the views that list AltStore PAL first", () => {
  assert.deepEqual(namesFor({ page: "/", from: null }, "GR"), ["view:home", "view:home:pal"]);
  assert.deepEqual(namesFor({ page: "/", from: null }, "US"), ["view:home"]);
  assert.deepEqual(namesFor({ page: "/sideload", from: null }, "GR"), ["view:sideload"]);
});

test("a country Cloudflare can't tell, and a device that isn't known, count as unknown", () => {
  for (const country of [undefined, "T1", "xx", "USA", 7]) {
    assert.ok(namesFor({ page: "/", from: "", device: "toaster" }, country).includes("visit:country:XX"), String(country));
  }
  assert.ok(namesFor({ page: "/", from: "", device: "toaster" }, "US").includes("visit:device:other"));
});

test("only a site's name is kept of where a visit came from", () => {
  assert.equal(sourceName("WWW.Reddit.com"), "reddit.com");
  assert.equal(sourceName("com.reddit.frontpage"), "com.reddit.frontpage");
  for (const name of ["reddit.com/r/sideloaded", "https://reddit.com", "a b", "-x.com", "x".repeat(101), "[::1]"]) {
    assert.equal(sourceName(name), null, name);
    assert.equal(namesFor({ page: "/", from: name }, "US"), null, name);
  }
});

test("pages count only the events the site knows, a few at a time", () => {
  assert.deepEqual(namesFor({ page: "/sideload", events: ["download-ipa"] }, "US"), ["event:download-ipa"]);
  assert.deepEqual(namesFor({ page: "/certificate", events: ["certificate-chosen", "nope"] }, "US"), ["event:certificate-chosen"]);
  assert.equal(namesFor({ page: "/certificate", events: ["nope"] }, "US"), null);
  assert.equal(namesFor({ page: "/certificate", events: [] }, "US"), null);
  assert.equal(namesFor({ page: "/certificate", events: Array(9).fill("donate") }, "US"), null);
  // iOS's install is the site's to count, not a page's.
  assert.equal(namesFor({ page: "/certificate", events: ["install-downloaded"] }, "US"), null);
});

test("what isn't one of the site's pages counts nothing", () => {
  for (const body of [null, "view", [], {}, { page: "/stats" }, { page: "/nowhere" }, { page: "/install?url=x" }, { page: "/", from: 3 }]) {
    assert.equal(namesFor(body, "US"), null, JSON.stringify(body));
  }
});

test("the browser says what kind of device it is", () => {
  assert.equal(deviceKind("Mozilla/5.0 (iPhone; CPU iPhone OS 18_6 like Mac OS X) AppleWebKit/605.1.15"), "iphone");
  assert.equal(deviceKind("Mozilla/5.0 (iPad; CPU OS 17_0 like Mac OS X)"), "ipad");
  // iPadOS's Safari says it's a Mac, with a touch screen.
  assert.equal(deviceKind("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) Version/26.0 Safari/605.1.15", 5), "ipad");
  assert.equal(deviceKind("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) Version/26.0 Safari/605.1.15", 0), "computer");
  assert.equal(deviceKind("Mozilla/5.0 (Linux; Android 15; Pixel 9) Mobile Safari/537.36"), "other");
  assert.equal(deviceKind("Mozilla/5.0 (Windows NT 10.0; Win64; x64) Chrome/140.0"), "computer");
});

test("a visit is where the visitor came from, unless it's the site or a reload", () => {
  assert.equal(visitFrom("https://www.reddit.com/r/sideloaded/comments/x", SITE, "navigate"), "reddit.com");
  assert.equal(visitFrom("", SITE, "navigate"), "");
  assert.equal(visitFrom(`${SITE}/sideload`, SITE, "navigate"), null);
  assert.equal(visitFrom("https://github.com/", SITE, "reload"), null);
  assert.equal(visitFrom("https://github.com/", SITE, "back_forward"), null);
  assert.equal(visitFrom("android-app://com.reddit.frontpage/", SITE, "navigate"), "com.reddit.frontpage");
  assert.equal(visitFrom("not an address", SITE, undefined), "");
});

// MARK: Adding them up

test("POST /tally adds a page's report to today's counts", async () => {
  const stats = namespace();
  const ctx = { exports: { SiteStats: stats } };
  assert.equal((await tallyReport(report({ page: "/", from: "github.com", device: "iphone" }, "DE"), ctx)).status, 204);
  assert.equal((await tallyReport(report({ page: "/certificate", from: null }, "DE"), ctx)).status, 204);
  assert.equal((await tallyReport(report({ page: "/", events: ["route-certificate"] }, "DE"), ctx)).status, 204);
  assert.deepEqual(counts(stats), {
    [dayOf(Date.now())]: {
      "view:home": 1,
      "view:home:pal": 1,
      "visit": 1,
      "visit:country:DE": 1,
      "visit:device:iphone": 1,
      "visit:from:github.com": 1,
      "view:certificate": 1,
      "event:route-certificate": 1,
    },
  });
});

test("POST /tally refuses what isn't a page's report, and counts nothing", async () => {
  const stats = namespace();
  const ctx = { exports: { SiteStats: stats } };
  assert.equal((await tallyReport(report("{", "US"), ctx)).status, 400);
  assert.equal((await tallyReport(report({ page: "/nowhere" }, "US"), ctx)).status, 400);
  assert.equal((await tallyReport(report(JSON.stringify({ page: "/", pad: "x".repeat(1100) }), "US"), ctx)).status, 413);
  const get = await tallyReport(new Request(`${SITE}/tally`), ctx);
  assert.equal(get.status, 405);
  assert.equal(get.headers.get("Allow"), "POST");
  assert.deepEqual(counts(stats), {});
});

test("the Worker sends /tally to SiteStats' namespace in ctx.exports", async () => {
  // ctx.exports only has what the Worker's main module exports.
  assert.equal(exported, SiteStats);
  const stats = namespace();
  const response = await worker.fetch(report({ page: "/sideload", events: ["copy-source"] }, "US"), {}, { exports: { SiteStats: stats } });
  assert.equal(response.status, 204);
  assert.deepEqual(Object.values(counts(stats)), [{ "event:copy-source": 1 }]);
});

test("a page that isn't there counts when a browser opens it, and nothing else does", async () => {
  const stats = namespace();
  const waiting = [];
  const ctx = { exports: { SiteStats: stats }, waitUntil: (promise) => waiting.push(promise) };
  const env = { ASSETS: { fetch: async () => new Response("Not Found", { status: 404 }) } };
  const page = await worker.fetch(new Request(`${SITE}/nowhere`, { headers: { "Sec-Fetch-Dest": "document" } }), env, ctx);
  assert.equal(page.status, 404);
  await worker.fetch(new Request(`${SITE}/nowhere.png`, { headers: { "Sec-Fetch-Dest": "image" } }), env, ctx);
  await worker.fetch(new Request(`${SITE}/wp-login.php`), env, ctx);
  await Promise.all(waiting);
  assert.deepEqual(Object.values(counts(stats)), [{ "view:notfound": 1 }]);
});

test("a day keeps up to MAX_SOURCES sites visits came from, then counts them as others", async () => {
  const object = new SiteStats({ storage: new Storage() });
  for (let i = 0; i < MAX_SOURCES + 3; i++) await object.add(["visit", `visit:from:site${i}.example`], "2026-11-12");
  await object.add(["visit:from:site0.example"], "2026-11-12");
  const day = await object.storage.get("day:2026-11-12");
  assert.equal(day.visit, MAX_SOURCES + 3);
  assert.equal(day["visit:from:site0.example"], 2);
  assert.equal(day["visit:from:others"], 3);
  assert.equal(day[`visit:from:site${MAX_SOURCES}.example`], undefined);
});

test("a day keeps up to MAX_NAMES names", async () => {
  const object = new SiteStats({ storage: new Storage() });
  await object.add(Array.from({ length: MAX_NAMES + 5 }, (_, i) => `name${i}`), "2026-11-12");
  await object.add(["name0", "another"], "2026-11-12");
  const day = await object.storage.get("day:2026-11-12");
  assert.equal(Object.keys(day).length, MAX_NAMES);
  assert.equal(day.name0, 2);
  assert.equal(day.another, undefined);
});

test("days older than KEEP_DAYS go once a new day starts", async () => {
  const object = new SiteStats({ storage: new Storage() });
  const today = Date.parse("2026-11-12");
  for (let i = 0; i < 200; i++) await object.storage.put(`day:${dayOf(today - (KEEP_DAYS + i) * DAY)}`, { visit: 1 });
  await object.storage.put(`day:${dayOf(today - (KEEP_DAYS - 1) * DAY)}`, { visit: 1 });
  await object.add(["visit"], dayOf(today));
  assert.deepEqual([...object.storage.values.keys()].sort(), [`day:${dayOf(today - (KEEP_DAYS - 1) * DAY)}`, "day:2026-11-12"]);
});

test("the object answers the days asked for, oldest first", async () => {
  const stats = namespace();
  const object = stats.get(stats.idFromName("site"));
  for (const day of ["2026-11-10", "2026-11-01", "2026-11-12", "2026-10-31"]) {
    await object.fetch("https://site-stats/add", { method: "POST", body: JSON.stringify({ names: ["visit"], day }) });
  }
  const response = await object.fetch("https://site-stats/days?from=2026-11-01&to=2026-11-12");
  assert.deepEqual(await response.json(), [
    { day: "2026-11-01", counts: { visit: 1 } },
    { day: "2026-11-10", counts: { visit: 1 } },
    { day: "2026-11-12", counts: { visit: 1 } },
  ]);
});

test("CI's builds don't count", () => {
  const exports = { SiteStats: namespace() };
  assert.equal(new BuildApp({ storage: new Storage(), exports }).stats, undefined);
});

// MARK: The Stats page

test("the days are summed up, with a line for every day", () => {
  const summary = summarize([
    { day: "2026-11-10", counts: { "visit": 2, "view:home": 3, "view:home:pal": 1, "view:sideload": 1, "event:donate": 1 } },
    { day: "2026-11-12", counts: { "visit": 1, "view:home": 1 } },
  ], "2026-11-09", "2026-11-12");
  assert.deepEqual(summary, {
    from: "2026-11-09",
    to: "2026-11-12",
    daily: [["2026-11-09", 0, 0], ["2026-11-10", 2, 4], ["2026-11-11", 0, 0], ["2026-11-12", 1, 1]],
    totals: { "visit": 3, "view:home": 4, "view:home:pal": 1, "view:sideload": 1, "event:donate": 1 },
  });
});

function statsRequest(query, key) {
  return new Request(`${SITE}/stats/data${query}`, key === undefined ? {} : { headers: { Authorization: `Bearer ${key}` } });
}

test("GET /stats/data answers the last days with the stats key, today included", async () => {
  const stats = namespace();
  const ctx = { exports: { SiteStats: stats } };
  const env = { STATS_KEY: "the-key" };
  const now = Date.parse("2026-11-12T15:00:00Z");
  const object = stats.get(stats.idFromName("site"));
  for (const [day, names] of [["2026-11-05", ["visit"]], ["2026-11-06", ["visit", "view:home"]], ["2026-11-12", ["event:donate"]]]) {
    await object.fetch("https://site-stats/add", { method: "POST", body: JSON.stringify({ names, day }) });
  }
  const response = await statsData(statsRequest("?days=7", "the-key"), env, ctx, now);
  assert.equal(response.status, 200);
  assert.equal(response.headers.get("Cache-Control"), "no-store");
  const summary = await response.json();
  assert.equal(summary.from, "2026-11-06");
  assert.equal(summary.to, "2026-11-12");
  assert.equal(summary.daily.length, 7);
  assert.deepEqual(summary.totals, { "visit": 1, "view:home": 1, "event:donate": 1 });
  assert.equal((await (await statsData(statsRequest("?days=365", "the-key"), env, ctx, now)).json()).daily.length, 365);
  assert.equal((await statsData(statsRequest("?days=8", "the-key"), env, ctx, now)).status, 400);
});

test("GET /stats/data needs the stats key", async () => {
  const ctx = { exports: { SiteStats: namespace() } };
  const none = await statsData(statsRequest("?days=7", "anything"), {}, ctx);
  assert.equal(none.status, 503);
  const env = { STATS_KEY: "the-key" };
  for (const key of [undefined, "", "the-ke", "the-key2", "THE-KEY"]) {
    const response = await statsData(statsRequest("?days=7", key), env, ctx);
    assert.equal(response.status, 401, String(key));
    assert.equal(response.headers.get("WWW-Authenticate"), "Bearer");
  }
  assert.equal((await statsData(new Request(`${SITE}/stats/data?days=7`, { method: "POST" }), env, ctx)).status, 405);
  // The Worker answers it too.
  assert.equal((await worker.fetch(statsRequest("?days=30", "the-key"), env, ctx)).status, 200);
});

test("every page counts, but the Stats page", () => {
  const publicDir = new URL("../public/", import.meta.url);
  const pages = [...readdirSync(publicDir).filter((name) => name.endsWith(".html")), "certificate/install.html"];
  for (const page of pages) {
    const html = readFileSync(new URL(page, publicDir), "utf8");
    assert.equal(html.includes('<script type="module" src="/tally.js"></script>'), page !== "stats.html", page);
  }
});

test("the Stats page has what its script fills in", () => {
  const html = readFileSync(new URL("../public/stats.html", import.meta.url), "utf8");
  const script = readFileSync(new URL("../public/stats.js", import.meta.url), "utf8");
  const ids = new Set([...html.matchAll(/ id="([^"]+)"/g)].map((match) => match[1]));
  for (const [, id] of script.matchAll(/\$\("([^"]+)"\)/g)) assert.ok(ids.has(id), id);
});

test("what pages mark to count is what the site counts", () => {
  const publicDir = new URL("../public/", import.meta.url);
  for (const page of ["index.html", "sideload.html"]) {
    const html = readFileSync(new URL(page, publicDir), "utf8");
    for (const [, event] of html.matchAll(/data-tally="([^"]+)"/g)) assert.ok(namesFor({ page: "/", events: [event] }, "US"), event);
  }
  const certificate = readFileSync(new URL("certificate.js", publicDir), "utf8");
  for (const [, event] of certificate.matchAll(/tallyOnce\("([^"]+)"\)/g)) assert.ok(namesFor({ page: "/certificate", events: [event] }, "US"), event);
  for (const reason of ["other-profile", "expired", "app-store"]) assert.ok(namesFor({ page: "/certificate", events: [`certificate-${reason}`] }, "US"), reason);
  for (const sign of ["sign-iphone", "sign-computer"]) assert.ok(namesFor({ page: "/certificate", events: [sign] }, "US"), sign);
});
