import { test } from "node:test";
import assert from "node:assert/strict";

import { ReachError } from "../src/ipa.js";
import { SourceError, cleanName, compareVersions, parseSource, readSource, summarize } from "../src/source.js";

/** An app as a source lists it, with one version. */
function app(bundleID, name, { version = "1.0", ...fields } = {}) {
  return { bundleIdentifier: bundleID, name, versions: [{ version, downloadURL: `https://example.com/${name}.ipa` }], ...fields };
}

/** A fetch that answers with `body`, and like Workers' own, can't be
 *  called as another object's method. */
function answering(body, init = {}) {
  return async function () {
    if (this !== undefined && this !== globalThis) throw new TypeError("Illegal invocation");
    return new Response(typeof body === "string" ? body : JSON.stringify(body), init);
  };
}

test("sums up a source as the add sheet shows it", () => {
  const source = {
    name: "  Team Picks ",
    iconURL: "https://example.com/source.png",
    apps: [
      app("com.example.one", "One", { iconURL: "https://example.com/one.png" }),
      app("com.example.two", "Two", { iconURL: "https://example.com/two.png" }),
      app("com.example.three", "Three", { iconURL: "https://example.com/three.png" }),
    ],
    // Featured ones first, once each; one the source doesn't list is left out.
    featuredApps: ["com.example.three", "com.example.missing", "com.example.three"],
  };
  assert.deepEqual(summarize(source), {
    name: "Team Picks",
    icon: "https://example.com/source.png",
    appCount: 3,
    apps: [
      { name: "Three", icon: "https://example.com/three.png" },
      { name: "One", icon: "https://example.com/one.png" },
      { name: "Two", icon: "https://example.com/two.png" },
    ],
    app: null,
  });
});

test("names a source as Atelier does, and takes its first app's icon when it has none", () => {
  assert.equal(summarize({ identifier: "com.example.source", apps: [] }).name, "com.example.source");
  assert.equal(summarize({ name: " ", apps: [] }).name, "Untitled Source");
  const source = { name: "S", apps: [app("com.example.one", "One", { iconURL: "https://example.com/one.png" })] };
  assert.equal(summarize(source).icon, "https://example.com/one.png");
  // An http:// icon wouldn't show on an https:// page.
  assert.equal(summarize({ ...source, iconURL: "http://example.com/source.png" }).icon, null);
  assert.equal(summarize({ ...source, iconURL: "not a URL" }).icon, "https://example.com/one.png");
});

test("counts the apps Atelier can use, without betas, but shows a few with icons", () => {
  const source = {
    name: "S",
    apps: [
      app("com.example.plain", "Plain", { iconURL: "https://example.com/plain.png" }),
      // Without an icon: counted, not shown.
      app("com.example.iconless", "Iconless"),
      app("com.example.http", "HTTP", { iconURL: "http://example.com/http.png" }),
      // A beta app, and an app whose only version is a beta.
      app("com.example.beta", "Beta", { beta: true, iconURL: "https://example.com/beta.png" }),
      { ...app("com.example.prerelease", "Prerelease"), versions: [{ version: "2.0", downloadURL: "https://example.com/p.ipa", atelierPrerelease: true }] },
      // What Atelier can't use: no bundle ID, no name, no version it can download.
      { name: "No ID", versions: [{ version: "1", downloadURL: "https://example.com/a.ipa" }] },
      { bundleIdentifier: "com.example.noname", versions: [{ version: "1", downloadURL: "https://example.com/a.ipa" }] },
      { bundleIdentifier: "com.example.ftp", name: "FTP", versions: [{ version: "1", downloadURL: "ftp://example.com/a.ipa" }] },
      { bundleIdentifier: "com.example.none", name: "None", versions: [{ downloadURL: "https://example.com/a.ipa" }] },
      "not an app",
    ],
  };
  const summary = summarize(source);
  assert.equal(summary.appCount, 3);
  assert.deepEqual(summary.apps, [{ name: "Plain", icon: "https://example.com/plain.png" }]);
  // Five at most.
  const many = { name: "S", apps: Array.from({ length: 8 }, (_, i) => app(`com.example.app${i}`, `App ${i}`, { iconURL: `https://example.com/${i}.png` })) };
  assert.equal(summarize(many).apps.length, 5);
  assert.equal(summarize(many).appCount, 8);
});

test("a source of nothing but betas is counted with them, as it's added with them", () => {
  const source = { name: "S", apps: [app("com.example.beta", "Beta", { beta: "yes" }), app("com.example.next", "Next", { beta: 1 })] };
  assert.equal(summarize(source).appCount, 2);
  assert.equal(summarize({ name: "S", apps: "not a list" }).appCount, 0);
});

test("finds an app link's app, in any case, as the add sheet does", () => {
  const source = {
    name: "S",
    apps: [
      app("com.example.Notes", "Notes_2.1", {
        developerName: " Someone_1.0 ",
        subtitle: "Takes notes.",
        iconURL: "https://example.com/notes.png",
        versions: [
          { version: "2.1", buildVersion: "40", downloadURL: "https://example.com/2.1.ipa", size: "1234567" },
          { version: "2.0", downloadURL: "https://example.com/2.0.ipa" },
        ],
      }),
    ],
  };
  const expected = { name: "Notes", subtitle: "Takes notes.", developer: "Someone", version: "2.1 (40)", size: 1234567, icon: "https://example.com/notes.png" };
  assert.deepEqual(summarize(source, "com.example.Notes").app, expected);
  assert.deepEqual(summarize(source, "com.example.notes").app, expected);
  assert.equal(summarize(source, "com.example.missing").app, null);
});

test("an app's version as the store shows it, and its legacy version", () => {
  const versions = (version) => ({ name: "S", apps: [{ bundleIdentifier: "com.example.app", name: "App", versions: [{ downloadURL: "https://example.com/a.ipa", ...version }] }] });
  const shown = (version) => summarize(versions(version), "com.example.app").app;
  assert.equal(shown({ version: "1.2", buildVersion: "7", marketingVersion: "1.2 Beta" }).version, "1.2 Beta");
  assert.equal(shown({ version: "1.2", buildVersion: "1.2" }).version, "1.2");
  assert.equal(shown({ version: 1.5 }).version, "1.5");
  assert.equal(shown({ version: "1", size: 0 }).size, null);
  assert.equal(shown({ version: "1", size: 12.9 }).size, 12);
  assert.equal(shown({ version: "1", size: "big" }).size, null);
  const legacy = { name: "S", apps: [{ bundleIdentifier: "com.example.old", name: "Old", version: "0.9", downloadURL: "https://example.com/old.ipa", size: 99 }] };
  assert.deepEqual(summarize(legacy, "com.example.old").app, { name: "Old", subtitle: null, developer: null, version: "0.9", size: 99, icon: null });
});

test("listings of one app are one app, its newest version first", () => {
  // As Atelier's own test of this has it.
  const source = parseSource(`{"name": "S", "apps": [
    {"name": "Spotify_9.1.50", "bundleIdentifier": "com.spotify.client", "versions": [{"version": "9.1.50", "date": "2026-06-12", "downloadURL": "https://e.com/50.ipa"}]},
    {"name": "EeveeSpotify", "bundleIdentifier": "com.spotify.client", "versions": [{"version": "9.1.56", "date": "2026-06-16", "downloadURL": "https://e.com/e56.ipa"}]},
    {"name": "Spotify 9.1.56", "bundleIdentifier": "com.spotify.client", "versions": [{"version": "9.1.56", "date": "2026-06-16", "downloadURL": "https://e.com/56.ipa"}]},
    {"name": "spotify", "bundleIdentifier": "com.spotify.client", "versions": [{"version": "9.1.50", "date": "2026-06-12", "downloadURL": "https://e.com/50.ipa"}]}
  ]}`);
  const summary = summarize(source, "com.spotify.client");
  assert.equal(summary.appCount, 2);
  assert.equal(summary.app.name, "Spotify");
  assert.equal(summary.app.version, "9.1.56");
  // Accents don't make another app.
  const accented = { name: "S", apps: [app("com.example.cafe", "Café", { version: "1.0" }), app("com.example.cafe", "cafe", { version: "1.1" })] };
  assert.equal(summarize(accented, "com.example.cafe").appCount, 1);
  assert.equal(summarize(accented, "com.example.cafe").app.version, "1.1");
});

test("names lose their versions, as Atelier cleans them", () => {
  const names = {
    "Alarmy_6.68.0+Satella": "Alarmy +Satella",
    "DuolingoMax_7.37.1": "DuolingoMax",
    "EeveeSpotify-5.9.5-9.0.36": "EeveeSpotify",
    "Spotify++8.6.94_CyPwn": "Spotify++ CyPwn",
    "Regram_1.0-b7_335.0.8": "Regram",
    "YTMusicUltimate_v1.4.1_YTM6.03.1": "YTMusicUltimate YTM",
    "Delta (1.7.1)": "Delta",
    "Deltarune v727": "Deltarune",
    "EeveeSpotify-5.9.5-9.0.36 x CyPwn": "EeveeSpotify x CyPwn",
    "Violyn_1_4_4-2": "Violyn",
    "Infuse 7": "Infuse 7",
    "2048": "2048",
    "1.2.3": "1.2.3",
  };
  for (const [raw, clean] of Object.entries(names)) assert.equal(cleanName(raw), clean, raw);
});

test("compares versions part by part, as Atelier does", () => {
  assert.equal(compareVersions("1.10", "1.9.2"), 1);
  assert.equal(compareVersions("1.7", "1.7.0"), 0);
  assert.equal(compareVersions("2.0", "2.0b3"), -1);
  assert.equal(compareVersions("v2", "V2"), 0);
  assert.equal(compareVersions("1.010", "1.9"), 1);
});

test("reads JSON as leniently as Atelier", () => {
  assert.equal(parseSource('﻿{"name": "S", "apps": [],}').name, "S");
  // A comma in a string stays.
  assert.equal(parseSource('{"name": "A, ]", "apps": [{"name": "x",},],}').name, "A, ]");
  assert.throws(() => parseSource("<html>"), (error) => error instanceof SourceError && error.message === "the source isn't JSON");
  assert.throws(() => parseSource("[1, 2]"), (error) => error instanceof SourceError && error.message === "the source isn't a JSON object");
});

test("reads a source from its server, and finds the app", async () => {
  const source = { name: "S", apps: [app("com.example.one", "One")] };
  const summary = await readSource("https://example.com/apps.json", { fetch: answering(source), bundleID: "com.example.one" });
  assert.equal(summary.name, "S");
  assert.equal(summary.app.name, "One");
});

test("refuses what isn't a source it can read", async () => {
  const read = (fetch) => readSource("https://example.com/apps.json", { fetch });
  await assert.rejects(read(answering("Not Found", { status: 404 })), (error) => error instanceof SourceError && error.message === "the server answered HTTP 404");
  await assert.rejects(read(answering("<html>")), /isn't JSON/);
  // Too large, whether it says so or not.
  const large = "x".repeat((4 << 20) + 1);
  await assert.rejects(read(answering(large)), /too large/);
  await assert.rejects(read(answering("{}", { headers: { "Content-Length": String(large.length) } })), /too large/);
  // A redirect to an address that isn't HTTPS, which Atelier stops at.
  const redirected = async () => {
    const response = new Response("{}");
    Object.defineProperty(response, "url", { value: "http://example.com/apps.json" });
    return response;
  };
  await assert.rejects(read(redirected), /isn't HTTPS/);
});

test("a server that can't be reached, or not in time, isn't a source that's wrong", async () => {
  const offline = async () => {
    throw new TypeError("Network connection lost.");
  };
  await assert.rejects(readSource("https://example.com/apps.json", { fetch: offline }), (error) => error instanceof ReachError && error.message === "Network connection lost.");
  // One that never answers. (Node's timeouts don't keep it running, so this
  // one does until then.)
  const silent = (url, init) => new Promise((resolve, reject) => init.signal.addEventListener("abort", () => reject(init.signal.reason)));
  const running = setTimeout(() => {}, 5000);
  await assert.rejects(readSource("https://example.com/apps.json", { fetch: silent, timeout: 50 }), (error) => error instanceof ReachError && error.cause?.name === "TimeoutError");
  clearTimeout(running);
});
