import { test } from "node:test";
import assert from "node:assert/strict";

import { formatDate, newestRelease, shortHash } from "../public/release.js";

const SHA256 = "0fa41806dc1998446826a9229eb73309f8cc360b4976728b6e8520ed5a09ae5b";

/** Atelier's source as scripts/update_source.py writes it, newest version
 *  first, with `fields` in place of the newest version's. */
function source(fields = {}) {
  return {
    name: "Atelier",
    apps: [
      { bundleIdentifier: "com.example.other", versions: [{ version: "9.0", downloadURL: "https://example.com/Other.ipa" }] },
      {
        bundleIdentifier: "com.atelier.app",
        versions: [
          {
            version: "0.4.0",
            marketingVersion: "0.4.0-alpha",
            buildVersion: "438",
            date: "2026-11-01T22:22:56Z",
            downloadURL: "https://github.com/atelierstore/Atelier/releases/download/v0.4.0-alpha/Atelier-0.4.0-alpha.ipa",
            size: 8218086,
            sha256: SHA256,
            minOSVersion: "17.0",
            ...fields,
          },
          { version: "0.3.0", marketingVersion: "0.3.0-alpha", downloadURL: "https://example.com/Atelier-0.3.0-alpha.ipa" },
        ],
      },
    ],
  };
}

test("reads Atelier's newest version, not another app's", () => {
  assert.deepEqual(newestRelease(source()), {
    version: "0.4.0-alpha",
    downloadURL: "https://github.com/atelierstore/Atelier/releases/download/v0.4.0-alpha/Atelier-0.4.0-alpha.ipa",
    size: 8218086,
    date: new Date("2026-11-01T22:22:56Z"),
    sha256: SHA256,
  });
});

test("names the version as the source shows it, else by its version", () => {
  assert.equal(newestRelease(source({ marketingVersion: undefined })).version, "0.4.0");
  assert.equal(newestRelease(source({ marketingVersion: "  " })).version, "0.4.0");
  assert.equal(newestRelease(source({ marketingVersion: " 0.4.0-alpha " })).version, "0.4.0-alpha");
});

test("leaves out a size, date or hash the source doesn't give as it should", () => {
  const release = newestRelease(source({ size: "8 MB", date: "yesterday", sha256: "0fa41806" }));
  assert.equal(release.size, null);
  assert.equal(release.date, null);
  assert.equal(release.sha256, null);
  assert.equal(newestRelease(source({ size: 0, date: undefined, sha256: undefined })).size, null);
  assert.equal(newestRelease(source({ sha256: SHA256.toUpperCase() })).sha256, SHA256);
});

test("only offers a download over HTTPS", () => {
  assert.equal(newestRelease(source({ downloadURL: "http://example.com/Atelier.ipa" })), null);
  assert.equal(newestRelease(source({ downloadURL: "Atelier.ipa" })), null);
  assert.equal(newestRelease(source({ downloadURL: undefined })), null);
});

test("finds nothing in a source without Atelier or its versions", () => {
  assert.equal(newestRelease(null), null);
  assert.equal(newestRelease({}), null);
  assert.equal(newestRelease({ apps: "none" }), null);
  assert.equal(newestRelease({ apps: [null, { bundleIdentifier: "com.atelier.app" }] }), null);
  assert.equal(newestRelease({ apps: [{ bundleIdentifier: "com.atelier.app", versions: [] }] }), null);
  assert.equal(newestRelease({ apps: [{ bundleIdentifier: "com.atelier.app", versions: [{ downloadURL: "https://example.com/Atelier.ipa" }] }] }), null);
});

test("shows the date as day, month and year", () => {
  // Midday, so it's the same day in any time zone the tests run in.
  assert.equal(formatDate(new Date("2026-11-01T12:00:00Z")), "1 Nov 2026");
});

test("shortens a SHA-256 to its first and last 8 digits", () => {
  assert.equal(shortHash(SHA256), "0fa41806…5a09ae5b");
});
