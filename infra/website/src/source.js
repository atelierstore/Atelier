// Reads an AltStore source on another site, for the source and app link
// pages (/source and /viewapp): its name and icon, how many apps it lists, a
// few of them, and the app an app link is for. What counts follows Atelier's
// own rules, so the page says what Atelier's add sheet will: SourceParser's
// for which apps and versions can be used, AppName's for their names and
// for listings of one app, which become one app, and Prereleases' for
// leaving betas out, as a source being added is listed.

import { reach } from "./ipa.js";

/** The source isn't one Atelier can read. */
export class SourceError extends Error {}

// Sources are JSON, and even large ones are a few megabytes. Reading one
// takes about 3 ms a megabyte, and its apps about 2 ms a thousand, and a
// free Worker has 10 ms, so a larger one may fail; the page works all the
// same without it.
const MAXIMUM_SIZE = 4 << 20;
// The apps whose icons the source page shows, as many as the add sheet.
const SHOWN_APPS = 5;

/** The source at `url`, summed up as `summarize` does, with the app whose
 *  bundle ID is `bundleID`. Throws a SourceError when it isn't a source
 *  Atelier can read, or its server doesn't send it, and a ReachError when
 *  it can't be reached in `timeout` milliseconds. */
export async function readSource(url, { bundleID = null, fetch: fetchImpl = fetch, timeout = 8000 } = {}) {
  const signal = AbortSignal.timeout(timeout);
  const response = await reach(fetchImpl(url, {
    headers: { Accept: "application/json", "User-Agent": "Atelier" },
    signal,
  }));
  // Atelier stops at a redirect to an address that isn't HTTPS.
  if (response.url && !response.url.startsWith("https:")) {
    response.body?.cancel().catch(() => {});
    throw new SourceError("the server sent it to an address that isn't HTTPS");
  }
  if (!response.ok) {
    response.body?.cancel().catch(() => {});
    throw new SourceError(`the server answered HTTP ${response.status}`);
  }
  return summarize(parseSource(await text(response, MAXIMUM_SIZE)), bundleID);
}

/** A response's body as text, which can't be longer than `limit` bytes. */
async function text(response, limit) {
  if (Number(response.headers.get("Content-Length")) > limit) {
    response.body?.cancel().catch(() => {});
    throw new SourceError("the source is too large");
  }
  const chunks = [];
  let size = 0;
  const reader = response.body?.getReader();
  for (;;) {
    const { done, value } = reader ? await reach(reader.read()) : { done: true };
    if (done) break;
    size += value.length;
    if (size > limit) {
      reader.cancel().catch(() => {});
      throw new SourceError("the source is too large");
    }
    chunks.push(value);
  }
  const bytes = new Uint8Array(size);
  let offset = 0;
  for (const chunk of chunks) {
    bytes.set(chunk, offset);
    offset += chunk.length;
  }
  // Without a byte order mark.
  return new TextDecoder().decode(bytes);
}

/** The source's JSON object. Trailing commas, which the spec's own
 *  examples have, are let through, as Atelier lets them. */
export function parseSource(text) {
  text = text.replace(/^﻿/, "");
  let json;
  try {
    json = JSON.parse(text);
  } catch {
    try {
      json = JSON.parse(withoutTrailingCommas(text));
    } catch {
      throw new SourceError("the source isn't JSON");
    }
  }
  if (!isObject(json)) throw new SourceError("the source isn't a JSON object");
  return json;
}

/** Each comma followed only by whitespace and ] or }, but not in strings. */
const withoutTrailingCommas = (text) =>
  text.replace(/("[^"\\]*(?:\\[\s\S][^"\\]*)*")|,(?=[ \t\n\r]*[\]}])/g, (match, string) => string ?? "");

/** What the link pages show of a source: {name, icon, appCount, apps,
 *  app}. `icon` is the source's icon, or else its first app's, as Atelier
 *  shows it. `appCount` is how many apps it lists without its betas, unless
 *  all it lists are betas, as the add sheet lists it, and `apps` the first
 *  few of them with an icon, {name, icon}, featured ones first, as the add
 *  sheet shows them. `app` is the one whose bundle ID is `bundleID`, as an
 *  app link finds it, {name, subtitle, developer, version, size, icon}, or
 *  null. Icons are https:// addresses or null; others won't show on an
 *  https:// page. */
export function summarize(json, bundleID = null) {
  const apps = sourceApps(json.apps);
  const released = withoutPrereleases(apps);
  const listed = apps.length > 0 && released.length === 0 ? apps : released;

  // An app by its bundle ID: the first that has it.
  const byBundleID = new Map();
  for (const app of listed) if (!byBundleID.has(app.bundleID)) byBundleID.set(app.bundleID, app);
  const featured = (Array.isArray(json.featuredApps) ? json.featuredApps : [])
    .map((id) => byBundleID.get(string(id)))
    .filter(Boolean);
  const seen = new Set();
  const shown = [];
  for (const app of [...featured, ...listed]) {
    if (shown.length === SHOWN_APPS) break;
    if (seen.has(app.id)) continue;
    seen.add(app.id);
    const icon = https(app.icon);
    if (icon) shown.push({ name: app.name, icon });
  }

  let app = null;
  if (bundleID) {
    const lowercased = bundleID.toLowerCase();
    app = byBundleID.get(bundleID)
      ?? listed.find((candidate) => candidate.bundleID.toLowerCase() === lowercased)
      ?? null;
  }

  const latest = app && latestVersion(app);
  return {
    name: string(json.name) ?? string(json.identifier) ?? "Untitled Source",
    icon: https(absolute(json.iconURL) ?? apps[0]?.icon),
    appCount: listed.length,
    apps: shown,
    app: app && {
      name: app.name,
      subtitle: app.subtitle,
      developer: app.developer,
      version: displayVersion(latest),
      size: latest.size > 0 ? latest.size : null,
      icon: https(app.icon),
    },
  };
}

// MARK: Apps, as SourceParser reads them

/** The source's apps, each listing of one app (the same bundle ID and
 *  name) merged into one, with all their versions. */
function sourceApps(list) {
  const apps = [];
  const positions = new Map();
  for (const element of Array.isArray(list) ? list : []) {
    const app = sourceApp(element);
    if (!app) continue;
    const position = positions.get(app.id);
    if (position === undefined) {
      positions.set(app.id, apps.length);
      apps.push(app);
    } else {
      for (const version of app.versions) apps[position].versions.push(version);
      apps[position].merged = true;
    }
  }
  return apps;
}

/** The version Atelier shows for an app: the source's first, or for
 *  listings merged into one app, the newest, the first of equal ones, as
 *  Atelier orders their versions. Only the app a link is for needs it. */
function latestVersion(app) {
  if (!app.merged) return app.versions[0];
  return app.versions.reduce((latest, version) => (compareRelease(version, latest) > 0 ? version : latest));
}

/** An app with a bundle ID, a name and a version Atelier can download, or
 *  null. */
function sourceApp(json) {
  if (!isObject(json)) return null;
  const bundleID = string(json.bundleIdentifier);
  const rawName = string(json.name);
  if (!bundleID || !rawName) return null;
  let versions = (Array.isArray(json.versions) ? json.versions : []).map(appVersion).filter(Boolean);
  if (versions.length === 0 && (json.downloadURL !== undefined || json.version !== undefined)) {
    // Legacy v1: the one version is on the app itself.
    const legacy = appVersion({
      version: json.version,
      buildVersion: json.buildVersion,
      date: json.versionDate,
      downloadURL: json.downloadURL,
      size: json.size,
    });
    if (legacy) versions = [legacy];
  }
  if (versions.length === 0) return null;
  const name = cleanName(rawName);
  const developer = string(json.developerName);
  return {
    id: identity(bundleID, name),
    bundleID,
    name,
    developer: developer && cleanName(developer),
    subtitle: string(json.subtitle),
    // Read once it's shown.
    icon: absolute(json.iconURL),
    isBeta: bool(json.beta) ?? false,
    versions,
    merged: false,
  };
}

/** A version with a number and an http(s) address to download it from,
 *  or null. */
function appVersion(json) {
  if (!isObject(json)) return null;
  const version = versionString(json.version);
  if (!version || !/^https?:\/\/[^/?#\s]/i.test(string(json.downloadURL) ?? "")) return null;
  const date = string(json.date) && Date.parse(string(json.date));
  return {
    version,
    build: versionString(json.buildVersion),
    marketing: versionString(json.marketingVersion),
    date: Number.isFinite(date) ? date : null,
    size: integer(json.size),
    isPrerelease: bool(json.atelierPrerelease) ?? false,
  };
}

/** The source as Include Pre-releases off lists it: without its beta apps
 *  and beta versions, and an app left without versions with them. */
function withoutPrereleases(apps) {
  return apps.flatMap((app) => {
    if (app.isBeta) return [];
    const versions = app.versions.filter((version) => !version.isPrerelease);
    return versions.length > 0 ? [{ ...app, versions }] : [];
  });
}

/** `marketingVersion`, or else "version (build)", or just the version. */
function displayVersion(version) {
  if (version.marketing) return version.marketing;
  return version.build && version.build !== version.version ? `${version.version} (${version.build})` : version.version;
}

/** By version, then build, then date, as Atelier orders releases. */
function compareRelease(a, b) {
  return compareVersions(a.version, b.version)
    || (a.build !== null && b.build !== null ? compareVersions(a.build, b.build) : 0)
    || (a.date !== null && b.date !== null ? Math.sign(a.date - b.date) : 0);
}

/** "1.10" after "1.9.2", part by part, numbers as numbers and missing parts
 *  as zero, as VersionNumber compares them. */
export function compareVersions(a, b) {
  const left = a.trim().split(".");
  const right = b.trim().split(".");
  for (let i = 0; i < Math.max(left.length, right.length); i++) {
    const order = compareNumerically(left[i] ?? "0", right[i] ?? "0");
    if (order !== 0) return order;
  }
  return 0;
}

/** Two strings, their digits as numbers, ignoring case. */
function compareNumerically(a, b) {
  const left = a.toLowerCase().match(/\d+|\D+/g) ?? [];
  const right = b.toLowerCase().match(/\d+|\D+/g) ?? [];
  for (let i = 0; i < Math.min(left.length, right.length); i++) {
    let x = left[i];
    let y = right[i];
    if (/^\d/.test(x) && /^\d/.test(y)) {
      x = x.replace(/^0+(?=\d)/, "");
      y = y.replace(/^0+(?=\d)/, "");
      if (x.length !== y.length) return Math.sign(x.length - y.length);
    }
    if (x !== y) return x < y ? -1 : 1;
  }
  return Math.sign(left.length - right.length);
}

// MARK: Names, as AppName cleans them

/** `raw` without version numbers such as "6.68.0", "v1.4.1" or "1.0-b7",
 *  with underscores as spaces, so the listings of one app have one name.
 *  The raw name when nothing but a version would be left. */
export function cleanName(raw) {
  // Most names have no version in them, and the rest is only for those.
  if (!/[\d_]/.test(raw)) return raw.replace(/\s+/g, " ").replace(/^[ \-+·|]+|[ \-+·|]+$/g, "") || raw.trim();
  const name = raw
    .replace(/_/g, " ")
    // Numbers glued to a word first, as in "YTM6.03.1".
    .replace(/(?<=[A-Za-z]{2})\d+(?:\.\d+)+/g, "")
    .replace(/[\s-]*\(?\b[vV]?\d+(?:\.\d+)+(?:[-.]?(?:b|beta|rc|alpha)\d*)?\)?/g, " ")
    // "v727", and "1 4 4-2" from "1_4_4-2".
    .replace(/\b[vV]\d+\b/g, " ")
    .replace(/(?:\s+\d+){2,}(?:-\d+)?\s*$/, "")
    .replace(/\s+/g, " ")
    .replace(/^[ \-+·|]+|[ \-+·|]+$/g, "");
  return name || raw.trim();
}

/** What makes two listings one app: the bundle ID, and the name, ignoring
 *  case and accents. */
function identity(bundleID, name) {
  const folded = /^[\x00-\x7f]*$/.test(name) ? name : name.normalize("NFD").replace(/\p{Mn}/gu, "");
  return `${bundleID}#${folded.toLowerCase()}`;
}

// MARK: Values, as leniently as SourceParser reads them

const isObject = (value) => value !== null && typeof value === "object" && !Array.isArray(value);

/** A string that isn't blank, trimmed. */
function string(value) {
  return typeof value === "string" && value.trim() ? value.trim() : null;
}

/** A string, or a number written out, as a version given as 1.5. */
function versionString(value) {
  return typeof value === "number" && Number.isFinite(value) ? String(value) : string(value);
}

/** A number, or a string of one, as a size given as "1234". */
function integer(value) {
  if (typeof value === "number") return Number.isFinite(value) ? Math.trunc(value) : null;
  if (typeof value !== "string" || !/^[+-]?\d+$/.test(value.trim())) return null;
  return Number(value.trim());
}

function bool(value) {
  if (typeof value === "boolean") return value;
  if (value === 0 || value === 1) return value === 1;
  if (typeof value !== "string") return null;
  const lowercased = value.toLowerCase();
  if (["true", "yes", "1"].includes(lowercased)) return true;
  if (["false", "no", "0"].includes(lowercased)) return false;
  return null;
}

/** A string with a scheme, as a URL Atelier reads, or null. */
function absolute(value) {
  const text = string(value);
  return text && /^[a-z][a-z0-9+.-]*:/i.test(text) ? text : null;
}

/** The address `text` is, when it's an https:// one, or null. */
function https(text) {
  if (!text) return null;
  try {
    const url = new URL(text);
    return url.protocol === "https:" && url.hostname ? url.href : null;
  } catch {
    return null;
  }
}
