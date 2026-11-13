// The site's own counts of what people view and tap, for the Stats page
// (public/stats.html). Each page sends what it shows and what's tapped on it
// to POST /tally (public/tally.js), and the Worker adds them to the day's
// totals, which one Durable Object keeps (SiteStats). There are no cookies,
// IP addresses or IDs, and no addresses but the name of the site a visit came
// from: only how many times each thing happened that day. So a visitor who
// comes back is counted again. GET /stats/data answers the Stats page, with
// the key in the website's STATS_KEY secret.

import { json } from "./http.js";
import { PAL_COUNTRIES } from "./region.js";

/** The pages that count their views, by path, as their names in the counts.
 *  The link pages count which kind of link it was, never its address. */
export const PAGES = Object.freeze({
  "/": "home",
  "/index.html": "home",
  "/certificate": "certificate",
  "/certificate.html": "certificate",
  "/certificate/install": "certificate-install",
  "/certificate/install.html": "certificate-install",
  "/apple-id": "apple-id",
  "/apple-id.html": "apple-id",
  "/sideload": "sideload",
  "/sideload.html": "sideload",
  "/signing-services": "signing-services",
  "/signing-services.html": "signing-services",
  "/install": "install",
  "/install.html": "install",
  "/source": "source",
  "/source.html": "source",
  "/viewapp": "viewapp",
  "/viewapp.html": "viewapp",
  "/search": "search",
  "/search.html": "search",
});

/** What pages can say happened on them, as their names in the counts:
 *  - Get Atelier's ways to install on the home page, and its link for
 *    signing services;
 *  - any Donate button;
 *  - the sideload page's buttons;
 *  - on the certificate page, a certificate chosen, accepted or held back,
 *    and why, then Sign and Install, on the iPhone or on a computer.
 *  The site counts the rest itself, which pages can't send: iOS reading the
 *  signed Atelier's manifest, which is when it asks whether to install it
 *  (event:install-asked), and downloading all of it
 *  (event:install-downloaded), in ota.js, and pages that aren't there
 *  (view:notfound), in index.js. */
export const EVENTS = Object.freeze(new Set([
  "route-certificate",
  "route-apple-id",
  "route-sideload",
  "signing-services",
  "donate",
  "download-ipa",
  "copy-source",
  "add-altstore",
  "add-sidestore",
  "add-feather",
  "certificate-chosen",
  "certificate-accepted",
  "certificate-unreadable",
  "certificate-other-profile",
  "certificate-expired",
  "certificate-app-store",
  "certificate-revoked",
  "sign-iphone",
  "sign-computer",
]));

export const DEVICES = Object.freeze(new Set(["iphone", "ipad", "computer", "other"]));

/** The most a page sends at once, in bytes, and events in it. */
const MAX_BODY = 1024;
const MAX_EVENTS = 8;
/** How many sites visits can come from in a day: past that, the day's new
 *  ones count as others, so made-up names can't fill the day. */
export const MAX_SOURCES = 200;
/** How many names a day keeps at most, whatever they are. */
export const MAX_NAMES = 1000;
/** How many days are kept, today included: the Stats page's 12 months and
 *  a little more. */
export const KEEP_DAYS = 400;
/** The periods the Stats page shows, in days. */
export const PERIODS = Object.freeze([7, 30, 365]);

const SOURCE = /^[a-z0-9](?:[a-z0-9.-]{0,98}[a-z0-9])?$/;
const COUNTRY = /^[A-Z]{2}$/;
const DAY = 24 * 60 * 60 * 1000;

/** The names a page's report adds to the day's totals, or null for one that
 *  isn't a page's. `report` is what public/tally.js sends: {page, from,
 *  device} for a view, `from` null when the visitor came from another of
 *  the site's pages and a site's name, or "" for none, when it's a visit;
 *  {page, events} for what happened on the page. `country` is where
 *  Cloudflare places the visitor (request.cf.country). */
export function namesFor(report, country) {
  if (!report || typeof report !== "object") return null;
  const page = typeof report.page === "string" && Object.hasOwn(PAGES, report.page) ? PAGES[report.page] : null;
  if (!page) return null;

  if (Array.isArray(report.events)) {
    const events = report.events.filter((event) => typeof event === "string" && EVENTS.has(event));
    return events.length && events.length <= MAX_EVENTS ? events.map((event) => `event:${event}`) : null;
  }

  const names = [`view:${page}`];
  const place = typeof country === "string" && COUNTRY.test(country) ? country : "XX";
  // The home page lists AltStore PAL first there (region.js).
  if (page === "home" && Object.hasOwn(PAL_COUNTRIES, place)) names.push("view:home:pal");
  if (report.from === null || report.from === undefined) return names;
  if (typeof report.from !== "string") return null;
  const from = report.from === "" ? "none" : sourceName(report.from);
  if (!from) return null;
  const device = DEVICES.has(report.device) ? report.device : "other";
  names.push("visit", `visit:country:${place}`, `visit:device:${device}`, `visit:from:${from}`);
  return names;
}

/** A site's name as the counts keep it, without www., or null for one that
 *  isn't a host's name. */
export function sourceName(value) {
  const name = value.trim().toLowerCase().replace(/^www\./, "");
  return SOURCE.test(name) ? name : null;
}

/** POST /tally: a page's report (namesFor) added to today's totals. Nothing
 *  else about the request is kept. Answers 204, or 400 for what isn't a
 *  page's report. */
export async function tallyReport(request, ctx) {
  if (request.method !== "POST") return json({ error: "method not allowed" }, 405, { Allow: "POST" });
  if (Number(request.headers.get("Content-Length")) > MAX_BODY) return json({ error: "too large" }, 413);
  const text = await request.text();
  if (text.length > MAX_BODY) return json({ error: "too large" }, 413);
  let report;
  try {
    report = JSON.parse(text);
  } catch {
    return json({ error: "not JSON" }, 400);
  }
  const names = namesFor(report, request.cf?.country);
  if (!names) return json({ error: "not a page's report" }, 400);
  await tally(ctx.exports.SiteStats, names);
  return new Response(null, { status: 204 });
}

/** Adds `names` to today's totals in `stats`, SiteStats' namespace. It never
 *  throws: a count that couldn't be added never keeps a page or an install
 *  from working. */
export async function tally(stats, names) {
  try {
    const response = await statsObject(stats).fetch("https://site-stats/add", {
      method: "POST",
      body: JSON.stringify({ names }),
    });
    await response.body?.cancel();
  } catch (error) {
    console.error("A count couldn't be added:", error?.message ?? error);
  }
}

/** The one object that keeps the site's counts. Each Preview has a
 *  namespace of its own, so its counts aren't the site's. */
function statsObject(stats) {
  return stats.get(stats.idFromName("site"));
}

/** GET /stats/data?days=<7, 30 or 365>: the counts of the last `days` days,
 *  today included (UTC), summed up (summarize), for the Stats page, with
 *  the key in the STATS_KEY secret as `Authorization: Bearer <key>`. A 503
 *  until there's a key, and a 401 with any other. */
export async function statsData(request, env, ctx, now = Date.now()) {
  if (request.method !== "GET") return json({ error: "method not allowed" }, 405, { Allow: "GET" });
  if (!env.STATS_KEY) return json({ error: "There's no stats key yet. Add the STATS_KEY secret to the website's Worker." }, 503);
  const given = (request.headers.get("Authorization") ?? "").replace(/^Bearer\s+/i, "");
  if (!given || !(await sameText(given, env.STATS_KEY))) {
    return json({ error: "That stats key isn't the website's." }, 401, { "WWW-Authenticate": "Bearer" });
  }
  const days = Number(new URL(request.url).searchParams.get("days"));
  if (!PERIODS.includes(days)) return json({ error: `days is one of ${PERIODS.join(", ")}` }, 400);
  const to = dayOf(now);
  const from = dayOf(now - (days - 1) * DAY);
  const response = await statsObject(ctx.exports.SiteStats).fetch(`https://site-stats/days?from=${from}&to=${to}`);
  if (!response.ok) throw new Error(`SiteStats answered HTTP ${response.status}`);
  return json(summarize(await response.json(), from, to), 200);
}

/** `days`, [{day, counts}] as SiteStats keeps them, summed up from `from`
 *  to `to` (YYYY-MM-DD): {from, to, daily: [[day, visits, views]] for every
 *  day, with no counts as 0, and totals: {name: count}}. */
export function summarize(days, from, to) {
  const byDay = new Map(days.map(({ day, counts }) => [day, counts]));
  const daily = [];
  const totals = {};
  for (let time = Date.parse(from); time <= Date.parse(to); time += DAY) {
    const day = dayOf(time);
    const counts = byDay.get(day) ?? {};
    let views = 0;
    for (const [name, count] of Object.entries(counts)) {
      totals[name] = (totals[name] ?? 0) + count;
      if (name.startsWith("view:") && name !== "view:home:pal") views += count;
    }
    daily.push([day, counts.visit ?? 0, views]);
  }
  return { from, to, daily, totals };
}

/** The UTC day of `time`, in milliseconds, as YYYY-MM-DD. */
export function dayOf(time) {
  return new Date(time).toISOString().slice(0, 10);
}

/** Whether `a` and `b` are the same text, in a time that doesn't say how
 *  much of them is. */
async function sameText(a, b) {
  const encoder = new TextEncoder();
  const [x, y] = await Promise.all([a, b].map(async (text) => new Uint8Array(await crypto.subtle.digest("SHA-256", encoder.encode(text)))));
  let differ = 0;
  for (let i = 0; i < x.length; i++) differ |= x[i] ^ y[i];
  return differ === 0;
}

/** Keeps the site's counts, one value a day: `day:<YYYY-MM-DD>`, the day's
 *  {name: count}, in UTC days, for KEEP_DAYS days. The Worker asks it:
 *  - POST /add with {names, day}: adds 1 to each of `names` on `day`, or
 *    today, and answers 204.
 *  - GET /days?from=<day>&to=<day>: [{day, counts}] for the days in between
 *    that have any, oldest first. */
export class SiteStats {
  constructor(ctx) {
    this.storage = ctx.storage;
    // The last day old days were deleted on.
    this.pruned = null;
  }

  async fetch(request) {
    const url = new URL(request.url);
    if (url.pathname === "/add" && request.method === "POST") {
      const { names, day } = await request.json();
      await this.add(names, day ?? dayOf(Date.now()));
      return new Response(null, { status: 204 });
    }
    if (url.pathname === "/days" && request.method === "GET") {
      const from = url.searchParams.get("from");
      const to = url.searchParams.get("to");
      const kept = await this.storage.list({ start: `day:${from}`, end: `day:${to}~` });
      return Response.json([...kept].map(([key, counts]) => ({ day: key.slice(4), counts })));
    }
    return new Response("Not found", { status: 404 });
  }

  async add(names, day) {
    const key = `day:${day}`;
    const counts = (await this.storage.get(key)) ?? {};
    const all = Object.keys(counts);
    let kept = all.length;
    let sources = all.filter((name) => name.startsWith("visit:from:")).length;
    for (let name of names) {
      if (!Object.hasOwn(counts, name)) {
        if (name.startsWith("visit:from:")) {
          if (sources >= MAX_SOURCES) name = "visit:from:others";
          else sources++;
        }
        if (!Object.hasOwn(counts, name)) {
          if (kept >= MAX_NAMES) continue;
          kept++;
        }
      }
      counts[name] = (counts[name] ?? 0) + 1;
    }
    await this.storage.put(key, counts);
    if (this.pruned !== day) {
      this.pruned = day;
      const old = [...(await this.storage.list({ start: "day:", end: `day:${dayOf(Date.parse(day) - (KEEP_DAYS - 1) * DAY)}` })).keys()];
      // A delete takes up to 128 keys.
      for (let i = 0; i < old.length; i += 128) await this.storage.delete(old.slice(i, i + 128));
    }
  }
}
