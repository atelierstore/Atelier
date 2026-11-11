import { test } from "node:test";
import assert from "node:assert/strict";

import { PACKAGED_CERTIFICATE, packagedCertificate, takesCertificate } from "../public/packaged.js";
import { PlistError, parsePlist, writePlist } from "../public/plist.js";
import { ZipError, bytesFile, centralDirectory, dosTime, extract, writeZip } from "../public/zip.js";

const encode = (text) => new TextEncoder().encode(text);

/** Bytes deflate can't make smaller. */
function noise(length) {
  const bytes = new Uint8Array(length);
  let x = 2463534242;
  for (let i = 0; i < length; i++) {
    x ^= x << 13;
    x ^= x >>> 17;
    x ^= x << 5;
    bytes[i] = x & 0xff;
  }
  return bytes;
}

test("a ZIP it writes reads back as it was", async () => {
  const modified = dosTime(new Date(2026, 10, 5, 16, 30, 10));
  const files = [
    { path: "Payload/", mode: 0o40755, modified },
    { path: "Payload/Atelier.app/", mode: 0o40755, modified },
    { path: "Payload/Atelier.app/Atelier", data: encode("executable ".repeat(1000)), mode: 0o100755, modified },
    { path: "Payload/Atelier.app/Assets.car", data: noise(5000), mode: 0o100644, modified },
    { path: "Payload/Atelier.app/Info.plist", data: encode("<plist/>"), mode: 0o100644 },
    { path: "Payload/Atelier.app/Été.txt", data: new Uint8Array(0), mode: 0o100644, modified },
  ];
  const zip = await writeZip(files);
  const file = bytesFile(zip);
  const entries = await centralDirectory(file);
  assert.deepEqual(entries.map((entry) => entry.path), files.map((one) => one.path));
  assert.deepEqual(entries.map((entry) => entry.attributes >>> 16), files.map((one) => one.mode));
  // Deflated only when that makes it smaller.
  assert.deepEqual(entries.map((entry) => entry.method), [0, 0, 8, 0, 0, 0]);
  assert.equal(entries[0].attributes & 0x10, 0x10, "a folder has MS-DOS's directory bit too");
  assert.equal(entries[2].modified, modified);
  // Names that aren't ASCII say they're UTF-8.
  assert.equal(entries[5].flags & 0x0800, 0x0800);
  assert.equal(entries[2].flags & 0x0800, 0);
  for (const [i, entry] of entries.entries()) {
    assert.deepEqual(await extract(file, entry), files[i].data ?? new Uint8Array(0), entry.path);
  }
});

test("a ZIP's checksums are its files'", async () => {
  const zip = await writeZip([{ path: "a.txt", data: encode("The quick brown fox jumps over the lazy dog") }]);
  const [entry] = await centralDirectory(bytesFile(zip));
  assert.equal(entry.crc32, 0x414fa339);
});

test("DOS times are local, to two seconds", () => {
  const time = dosTime(new Date(2026, 10, 5, 16, 30, 11));
  assert.equal(time >>> 16, ((2026 - 1980) << 9) | (11 << 5) | 5);
  assert.equal(time & 0xffff, (16 << 11) | (30 << 5) | 5);
});

test("says what isn't a ZIP", async () => {
  await assert.rejects(centralDirectory(bytesFile(encode("not a zip"))), (error) => error instanceof ZipError && error.message === "the ZIP isn't a ZIP file");
  await assert.rejects(centralDirectory(bytesFile(encode("nope")), { name: "the certificate" }), { message: "the certificate isn't a ZIP file" });
});

// MARK: Property lists

test("writes property lists that read back as they were", () => {
  const value = {
    name: "Atelier & co <3>",
    count: 3,
    ratio: 0.5,
    on: true,
    off: false,
    data: Uint8Array.of(0, 1, 2, 255),
    when: new Date(Date.UTC(2026, 10, 5, 12, 0, 0)),
    list: ["a", ["b"], {}],
    empty: [],
    skipped: undefined,
  };
  const read = parsePlist(writePlist(value));
  assert.equal(read.name, value.name);
  assert.equal(read.count, 3);
  assert.equal(read.ratio, 0.5);
  assert.equal(read.on, true);
  assert.equal(read.off, false);
  assert.deepEqual(read.data, value.data);
  assert.deepEqual(read.when, value.when);
  assert.deepEqual(read.list[0], "a");
  assert.deepEqual(read.list[1], ["b"]);
  assert.deepEqual(Object.keys(read.list[2]), []);
  assert.deepEqual(read.empty, []);
  assert.ok(!("skipped" in read));
});

test("refuses what a property list or XML can't hold", () => {
  assert.throws(() => writePlist({ a: null }), PlistError);
  assert.throws(() => writePlist({ a: "bell\u0007" }), PlistError);
  assert.doesNotThrow(() => writePlist({ a: "tab\tand\nnew line" }));
});

// MARK: The packaged certificate

test("the packaged certificate is what Atelier decodes", () => {
  const p12 = Uint8Array.of(1, 2, 3);
  const profile = Uint8Array.of(4, 5, 6);
  const first = parsePlist(packagedCertificate({ p12, profile, password: "p<a>ss&word" }));
  assert.deepEqual(Object.keys(first), ["p12", "profile", "password", "id"]);
  assert.deepEqual(first.p12, p12);
  assert.deepEqual(first.profile, profile);
  assert.equal(first.password, "p<a>ss&word");
  // A UUID as Swift writes one, new each time.
  assert.match(first.id, /^[0-9A-F]{8}-[0-9A-F]{4}-4[0-9A-F]{3}-[89AB][0-9A-F]{3}-[0-9A-F]{12}$/);
  const second = parsePlist(packagedCertificate({ p12, profile, password: "" }));
  assert.notEqual(second.id, first.id);
  assert.equal(PACKAGED_CERTIFICATE, "AtelierCertificate.plist");
});

test("only builds that look for it take the certificate", () => {
  assert.equal(takesCertificate({ AtelierTakesCertificate: true }), true);
  assert.equal(takesCertificate({ AtelierTakesCertificate: "YES" }), false);
  assert.equal(takesCertificate({}), false);
  assert.equal(takesCertificate(null), false);
});
