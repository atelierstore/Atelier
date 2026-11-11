// The certificate page's signer: zsign and OpenSSL in WebAssembly
// (public/zsign.js, built by wasm/build.sh), and Atelier's signing steps
// around it (public/signer.js), on a small app made here and the fixtures
// Atelier's own signing tests use.

import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";

import { bytesReader, hasCMSSignature, inspect } from "../public/macho.js";
import { PACKAGED_CERTIFICATE, packagedCertificate } from "../public/packaged.js";
import { parsePlist, writePlist } from "../public/plist.js";
import { SignError, openP12, readAppInfo, signIPA } from "../public/signer.js";
import { bytesFile, centralDirectory, dosTime, extract, writeZip } from "../public/zip.js";
import createSigner from "../public/zsign.js";

const fixture = (path) => new Uint8Array(readFileSync(new URL(`../../../Packages/AtelierKit/Tests/${path}`, import.meta.url)));
// A throwaway certificate whose CA copies the name of Apple's WWDR G3, so
// zsign signs with it (SigningKitTests/make-fixtures.sh), and its profile.
const SIGNING = { p12: fixture("SigningKitTests/Fixtures/signing.p12"), profile: fixture("SigningKitTests/Fixtures/development.mobileprovision"), password: "ownstore" };
// One from a CA with another name, which zsign signs nothing with.
const OTHER_CA = { p12: fixture("CertKitTests/Fixtures/signing.p12"), profile: fixture("CertKitTests/Fixtures/development.mobileprovision"), password: "ownstore" };

const zsign = await createSigner({ print() {}, printErr() {} });

/** A small arm64 executable, as zsign reads one: __TEXT with __text, and
 *  __LINKEDIT, without a signature, or App Store-encrypted. */
function machO({ encrypted = false } = {}) {
  const bytes = new Uint8Array(0x4000 + 16);
  const view = new DataView(bytes.buffer);
  const name = (offset, text) => bytes.set(new TextEncoder().encode(text), offset);
  const commands = encrypted ? 3 : 2;
  view.setUint32(0, 0xfeedfacf, true);
  view.setUint32(4, 0x0100000c, true);
  view.setUint32(12, 2, true);
  view.setUint32(16, commands, true);
  view.setUint32(20, 152 + 72 + (encrypted ? 24 : 0), true);
  // LC_SEGMENT_64 __TEXT, with one section.
  let at = 32;
  view.setUint32(at, 0x19, true);
  view.setUint32(at + 4, 152, true);
  name(at + 8, "__TEXT");
  view.setBigUint64(at + 24, 0x100000000n, true);
  view.setBigUint64(at + 32, 0x4000n, true);
  view.setBigUint64(at + 48, 0x4000n, true);
  view.setUint32(at + 56, 5, true);
  view.setUint32(at + 60, 5, true);
  view.setUint32(at + 64, 1, true);
  name(at + 72, "__text");
  name(at + 88, "__TEXT");
  view.setBigUint64(at + 104, 0x100001000n, true);
  view.setBigUint64(at + 112, 4n, true);
  view.setUint32(at + 120, 0x1000, true);
  view.setUint32(at + 124, 2, true);
  view.setUint32(at + 136, 0x80000400, true);
  // LC_SEGMENT_64 __LINKEDIT.
  at += 152;
  view.setUint32(at, 0x19, true);
  view.setUint32(at + 4, 72, true);
  name(at + 8, "__LINKEDIT");
  view.setBigUint64(at + 24, 0x100004000n, true);
  view.setBigUint64(at + 32, 0x4000n, true);
  view.setBigUint64(at + 40, 0x4000n, true);
  view.setBigUint64(at + 48, 16n, true);
  view.setUint32(at + 56, 1, true);
  view.setUint32(at + 60, 1, true);
  if (encrypted) {
    // LC_ENCRYPTION_INFO_64, cryptid 1.
    at += 72;
    view.setUint32(at, 0x2c, true);
    view.setUint32(at + 4, 24, true);
    view.setUint32(at + 8, 0x1000, true);
    view.setUint32(at + 12, 0x1000, true);
    view.setUint32(at + 16, 1, true);
  }
  // ret
  view.setUint32(0x1000, 0xd65f03c0, true);
  return bytes;
}

const MODIFIED = dosTime(new Date(2026, 9, 1, 12, 0, 0));
const info = (values = {}) => writePlist({ CFBundleIdentifier: "com.atelier.app", CFBundleExecutable: "Atelier", CFBundleShortVersionString: "0.5.0", CFBundleVersion: "500", ...values });

/** An IPA of Atelier, as small as zsign signs: the app with a framework,
 *  and what an earlier signature leaves. */
function ipa({ executable = machO(), extra = [], infoValues = {} } = {}) {
  return writeZip([
    { path: "Payload/", mode: 0o40755, modified: MODIFIED },
    { path: "Payload/Atelier.app/", mode: 0o40755, modified: MODIFIED },
    { path: "Payload/Atelier.app/Atelier", data: executable, mode: 0o100755, modified: MODIFIED },
    { path: "Payload/Atelier.app/Info.plist", data: info(infoValues), mode: 0o100644, modified: MODIFIED },
    { path: "Payload/Atelier.app/readme.txt", data: new TextEncoder().encode("Hello"), mode: 0o100644, modified: MODIFIED },
    { path: "Payload/Atelier.app/_CodeSignature/CodeResources", data: new TextEncoder().encode("old"), mode: 0o100644, modified: MODIFIED },
    { path: "Payload/Atelier.app/embedded.mobileprovision", data: new TextEncoder().encode("old"), mode: 0o100644, modified: MODIFIED },
    { path: "Payload/Atelier.app/Frameworks/Kit.framework/Kit", data: machO(), mode: 0o100755, modified: MODIFIED },
    { path: "Payload/Atelier.app/Frameworks/Kit.framework/Info.plist", data: writePlist({ CFBundleIdentifier: "com.atelier.kit", CFBundleExecutable: "Kit" }), mode: 0o100644, modified: MODIFIED },
    { path: "Symbols/Atelier", data: new TextEncoder().encode("symbols"), mode: 0o100644, modified: MODIFIED },
    ...extra,
  ]);
}

/** The signed IPA's files, by path: {entry, data}. */
async function unzip(bytes) {
  const file = bytesFile(bytes);
  const files = new Map();
  for (const entry of await centralDirectory(file)) files.set(entry.path, { entry, data: await extract(file, entry) });
  return files;
}

// MARK: Mach-O

test("reads Mach-O files as Atelier does", () => {
  assert.deepEqual(inspect(bytesReader(machO())), { machO: true, encrypted: false });
  assert.deepEqual(inspect(bytesReader(machO({ encrypted: true }))), { machO: true, encrypted: true });
  assert.deepEqual(inspect(bytesReader(new TextEncoder().encode("#!/bin/sh\necho hi\n"))), { machO: false });
  assert.equal(hasCMSSignature(bytesReader(machO())), false);

  // A fat binary is encrypted when any slice is.
  const slices = [machO(), machO({ encrypted: true })];
  const fat = new Uint8Array(0x4000 + slices.reduce((sum, slice) => sum + slice.length, 0));
  const view = new DataView(fat.buffer);
  view.setUint32(0, 0xcafebabe);
  view.setUint32(4, slices.length);
  let offset = 0x4000;
  for (const [i, slice] of slices.entries()) {
    view.setUint32(8 + i * 20 + 8, offset);
    view.setUint32(8 + i * 20 + 12, slice.length);
    fat.set(slice, offset);
    offset += slice.length;
  }
  assert.deepEqual(inspect(bytesReader(fat)), { machO: true, encrypted: true });
  // Java class files share the fat magic, with a large count.
  view.setUint32(4, 50);
  assert.deepEqual(inspect(bytesReader(fat)), { machO: false });
});

// MARK: The .p12

test("opens a .p12 as the page's checks do", () => {
  const opened = openP12(zsign, SIGNING.p12, "ownstore");
  assert.equal(opened.status, "opened");
  // The certificate's DER: a SEQUENCE, and the profile lists it.
  assert.equal(opened.certificate[0], 0x30);
  assert.ok(opened.certificate.length > 500);
  assert.deepEqual(openP12(zsign, SIGNING.p12, "wrong"), { status: "wrongPassword" });
  assert.deepEqual(openP12(zsign, SIGNING.p12, ""), { status: "wrongPassword" });
  assert.deepEqual(openP12(zsign, new TextEncoder().encode("not a p12"), "x"), { status: "unreadable" });
  // Each kind of fixture Atelier imports: 3DES, made with -legacy.
  assert.equal(openP12(zsign, fixture("CertKitTests/Fixtures/other.p12"), "ownstore").status, "opened");
});

// MARK: Signing

test("reads the IPA's app before signing it", async () => {
  assert.deepEqual(await readAppInfo(await ipa()), { bundleID: "com.atelier.app", version: "0.5.0", takesCertificate: false });
  assert.equal((await readAppInfo(await ipa({ infoValues: { AtelierTakesCertificate: true } }))).takesCertificate, true);
  await assert.rejects(readAppInfo(new TextEncoder().encode("not a zip")), (error) => error instanceof SignError && error.reason === "corruptArchive");
});

test("signs Atelier as Atelier signs an IPA", async () => {
  const certificate = packagedCertificate(SIGNING);
  const signed = await unzip(await signIPA(zsign, { ipa: await ipa(), ...SIGNING, packagedCertificate: certificate }));
  const app = "Payload/Atelier.app/";

  // Only the app, by path.
  assert.deepEqual([...signed.keys()], [
    "Payload/",
    "Payload/Atelier.app/",
    `${app}Atelier`,
    `${app}${PACKAGED_CERTIFICATE}`,
    `${app}Frameworks/`,
    `${app}Frameworks/Kit.framework/`,
    `${app}Frameworks/Kit.framework/Info.plist`,
    `${app}Frameworks/Kit.framework/Kit`,
    `${app}Frameworks/Kit.framework/_CodeSignature/`,
    `${app}Frameworks/Kit.framework/_CodeSignature/CodeResources`,
    `${app}Info.plist`,
    `${app}_CodeSignature/`,
    `${app}_CodeSignature/CodeResources`,
    `${app}embedded.mobileprovision`,
    `${app}readme.txt`,
  ]);
  // Signed by the certificate, the app and its framework.
  for (const binary of ["Atelier", "Frameworks/Kit.framework/Kit"]) {
    assert.ok(hasCMSSignature(bytesReader(signed.get(app + binary).data)), binary);
  }
  // The profile goes in, and the old signature's files go.
  assert.deepEqual(signed.get(`${app}embedded.mobileprovision`).data, SIGNING.profile);
  const seal = parsePlist(signed.get(`${app}_CodeSignature/CodeResources`).data);
  assert.ok(seal.files2[PACKAGED_CERTIFICATE], "the signature seals the certificate");
  assert.ok(seal.files2["readme.txt"]);
  assert.deepEqual(signed.get(`${app}${PACKAGED_CERTIFICATE}`).data, certificate);

  // Executables stay executable, though zsign writes them anew, and
  // what zsign left alone keeps its date.
  assert.equal(signed.get(`${app}Atelier`).entry.attributes >>> 16, 0o100755);
  assert.equal(signed.get(`${app}Frameworks/Kit.framework/Kit`).entry.attributes >>> 16, 0o100755);
  assert.equal(signed.get(`${app}embedded.mobileprovision`).entry.attributes >>> 16, 0o100644);
  assert.equal(signed.get(`${app}_CodeSignature/`).entry.attributes >>> 16, 0o40755);
  assert.equal(signed.get(`${app}readme.txt`).entry.modified, MODIFIED);
  assert.notEqual(signed.get(`${app}Atelier`).entry.modified, MODIFIED);
});

test("leaves the certificate out when the page does, and any the IPA had", async () => {
  const extra = [{ path: `Payload/Atelier.app/${PACKAGED_CERTIFICATE}`, data: new TextEncoder().encode("someone else's"), mode: 0o100644 }];
  const signed = await unzip(await signIPA(zsign, { ipa: await ipa({ extra }), ...SIGNING }));
  assert.ok(!signed.has(`Payload/Atelier.app/${PACKAGED_CERTIFICATE}`));
  assert.ok(hasCMSSignature(bytesReader(signed.get("Payload/Atelier.app/Atelier").data)));
});

test("says when zsign would leave Atelier unsigned", async () => {
  // zsign signs nothing with a certificate it has no Apple CA for, and
  // says it did.
  await assert.rejects(signIPA(zsign, { ipa: await ipa(), ...OTHER_CA }), (error) => error.reason === "unsupportedCertificate" && /Apple didn't issue it/.test(error.message));
  await assert.rejects(signIPA(zsign, { ipa: await ipa(), ...SIGNING, password: "wrong" }), (error) => error.reason === "badCertificate");
});

test("refuses what it can't sign, as Atelier does", async () => {
  const reason = (expected) => (error) => error instanceof SignError && error.reason === expected;
  await assert.rejects(signIPA(zsign, { ipa: await ipa({ executable: machO({ encrypted: true }) }), ...SIGNING }), reason("encryptedBinary"));
  await assert.rejects(signIPA(zsign, { ipa: await ipa({ executable: new TextEncoder().encode("#!/bin/sh") }), ...SIGNING }), reason("unsupportedBinary"));
  const two = await ipa({ extra: [{ path: "Payload/Other.app/Info.plist", data: info() }] });
  await assert.rejects(signIPA(zsign, { ipa: two, ...SIGNING }), reason("corruptArchive"));
  const escaping = await ipa({ extra: [{ path: "Payload/../../escape", data: new Uint8Array(1) }] });
  await assert.rejects(signIPA(zsign, { ipa: escaping, ...SIGNING }), reason("corruptArchive"));
  await assert.rejects(signIPA(zsign, { ipa: await writeZip([{ path: "Other/", mode: 0o40755 }]), ...SIGNING }), reason("corruptArchive"));
  // Nothing is left behind for the next one.
  assert.deepEqual(zsign.FS.readdir("/").filter((name) => name === "job" || name === "p12"), []);
});
