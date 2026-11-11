import { test } from "node:test";
import assert from "node:assert/strict";

import worker from "../src/index.js";
import { buildManifest, ManifestError, MAX_ITEMS, validatePackageUrl } from "../src/manifest.js";

const valid = {
  bundleId: "com.example.app",
  version: "1.2.3",
  name: "Example",
  url: "http://127.0.0.1:4567/abc.ipa",
};

test("builds a manifest pointing at the loopback IPA", () => {
  const xml = buildManifest(valid);
  assert.match(xml, /<string>software-package<\/string>/);
  assert.match(xml, /<string>http:\/\/127\.0\.0\.1:4567\/abc\.ipa<\/string>/);
  assert.match(xml, /<key>bundle-identifier<\/key>\s*<string>com\.example\.app<\/string>/);
  assert.match(xml, /<key>bundle-version<\/key>\s*<string>1\.2\.3<\/string>/);
  assert.match(xml, /<key>title<\/key>\s*<string>Example<\/string>/);
});

test("escapes the app name so the plist stays valid", () => {
  const xml = buildManifest({ ...valid, name: `A<b> & "c"` });
  assert.match(xml, /<string>A&lt;b&gt; &amp; &quot;c&quot;<\/string>/);
});

test("escapes query strings in the package URL", () => {
  const xml = buildManifest({ ...valid, url: "http://127.0.0.1:4567/a.ipa?x=1&y=2" });
  assert.match(xml, /a\.ipa\?x=1&amp;y=2/);
});

test("accepts localhost and IPv6 loopback", () => {
  assert.equal(validatePackageUrl("http://localhost:8080/a.ipa"), "http://localhost:8080/a.ipa");
  assert.equal(validatePackageUrl("http://[::1]:8080/a.ipa"), "http://[::1]:8080/a.ipa");
});

test("rejects non-loopback, non-http and credentialed URLs", () => {
  for (const url of [
    "http://evil.example/a.ipa",
    "http://127.0.0.1.evil.example/a.ipa",
    "http://192.168.1.10:8080/a.ipa",
    "https://127.0.0.1:8080/a.ipa",
    "ftp://127.0.0.1/a.ipa",
    "http://user:pw@127.0.0.1/a.ipa",
    "not a url",
    "",
  ]) {
    assert.throws(() => validatePackageUrl(url), ManifestError, url);
  }
});

test("rejects bad metadata", () => {
  assert.throws(() => buildManifest({ ...valid, bundleId: "com.example/../x" }), ManifestError);
  assert.throws(() => buildManifest({ ...valid, bundleId: "" }), ManifestError);
  assert.throws(() => buildManifest({ ...valid, version: "1 2" }), ManifestError);
  assert.throws(() => buildManifest({ ...valid, name: "" }), ManifestError);
  assert.throws(() => buildManifest({ ...valid, name: "x".repeat(257) }), ManifestError);
  assert.throws(() => buildManifest({ ...valid, name: "bad\u0001name" }), ManifestError);
});

function request(path, init) {
  return worker.fetch(new Request(`https://manifest.example${path}`, init));
}

test("worker serves /manifest", async () => {
  const qs = new URLSearchParams({
    bundleid: valid.bundleId,
    version: valid.version,
    name: valid.name,
    url: valid.url,
  });
  const res = await request(`/manifest?${qs}`);
  assert.equal(res.status, 200);
  assert.equal(res.headers.get("Content-Type"), "application/xml; charset=utf-8");
  assert.equal(res.headers.get("Cache-Control"), "no-store");
  assert.match(await res.text(), /com\.example\.app/);
});

test("worker accepts api.palera.in parameter names on /genPlist", async () => {
  const qs = new URLSearchParams({
    bundleid: valid.bundleId,
    version: valid.version,
    name: valid.name,
    fetchurl: valid.url,
  });
  const res = await request(`/genPlist?${qs}`);
  assert.equal(res.status, 200);
  assert.match(await res.text(), /127\.0\.0\.1:4567/);
});

test("worker returns 400 for invalid input, 404 and 405 otherwise", async () => {
  assert.equal((await request("/manifest?bundleid=x")).status, 400);
  assert.equal((await request("/")).status, 404);
  assert.equal((await request("/manifest", { method: "POST" })).status, 405);
});

const second = {
  bundleId: "org.example.other",
  version: "2.0",
  name: "Other",
  url: "http://127.0.0.1:4567/def.ipa",
};

test("builds one item per app, in order, for a multi-app manifest", () => {
  const xml = buildManifest([valid, second]);
  assert.equal(xml.match(/<string>software-package<\/string>/g).length, 2);
  assert.ok(xml.indexOf("com.example.app") < xml.indexOf("org.example.other"));
  assert.match(xml, /def\.ipa/);
});

test("a one-item array gives the same manifest as a single item", () => {
  assert.equal(buildManifest([valid]), buildManifest(valid));
});

test("rejects empty, oversized or invalid multi-app manifests", () => {
  assert.throws(() => buildManifest([]), ManifestError);
  assert.throws(() => buildManifest(Array(MAX_ITEMS + 1).fill(valid)), ManifestError);
  assert.throws(() => buildManifest([valid, { ...second, url: "http://evil.example/x.ipa" }]), ManifestError);
});

test("worker builds a multi-app manifest from repeated parameters", async () => {
  const qs = new URLSearchParams();
  for (const app of [valid, second]) {
    qs.append("bundleid", app.bundleId);
    qs.append("name", app.name);
    qs.append("version", app.version);
    qs.append("url", app.url);
  }
  const res = await request(`/manifest?${qs}`);
  assert.equal(res.status, 200);
  const xml = await res.text();
  assert.equal(xml.match(/<key>bundle-identifier<\/key>/g).length, 2);
  assert.match(xml, /org\.example\.other/);
});

test("worker rejects repeated parameters that don't line up", async () => {
  const qs = new URLSearchParams();
  qs.append("bundleid", valid.bundleId);
  qs.append("bundleid", second.bundleId);
  qs.append("name", valid.name);
  qs.append("version", valid.version);
  qs.append("url", valid.url);
  qs.append("url", second.url);
  assert.equal((await request(`/manifest?${qs}`)).status, 400);
});
