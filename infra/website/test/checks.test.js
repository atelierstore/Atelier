// The certificate page's checks, on the fixtures Atelier's own tests use
// (Packages/AtelierKit/Tests/CertKitTests/Fixtures), with the same
// expectations, so the page reads certificates, profiles and Apple's
// answers as the app does.

import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";

import { CheckError, addFile, examine, revocationRow, summary } from "../public/checks.js";
import { TAG, parseDER, time } from "../public/der.js";
import { allows, bundleIDPattern, onlyDevice, readProfile, ProfileError } from "../public/profile.js";
import { APPLE_DEVELOPER_CAS, RevocationError, checkRevocation, issuerOf, ocspRequest, readOCSPResponse, revocationStatus } from "../public/ocsp.js";
import { authorityKeyIdentifier, ocspURL, publicKeyHash, readCertificate, signingIdentity, subjectKeyIdentifier } from "../public/x509.js";

const FIXTURES = new URL("../../../Packages/AtelierKit/Tests/CertKitTests/Fixtures/", import.meta.url);
const fixture = (name) => new Uint8Array(readFileSync(new URL(name, FIXTURES)));
const utc = (...parts) => new Date(Date.UTC(parts[0], parts[1] - 1, parts[2], parts[3] ?? 0, parts[4] ?? 0, parts[5] ?? 0));
const plist = (body) => new TextEncoder().encode(`<?xml version="1.0" encoding="UTF-8"?><plist version="1.0"><dict>${body}</dict></plist>`);

// MARK: Profiles

test("reads a development profile", () => {
  const profile = readProfile(fixture("development.mobileprovision"));
  assert.equal(profile.name, "OwnStore Test development");
  assert.equal(profile.teamID, "TESTTEAM01");
  assert.equal(profile.teamName, "OwnStore Test");
  assert.equal(profile.kind, "development");
  assert.equal(profile.applicationIdentifier, "TESTTEAM01.*");
  assert.equal(bundleIDPattern(profile), "*");
  assert.deepEqual(profile.expirationDate, utc(2027, 1, 1));
  assert.deepEqual(profile.creationDate, utc(2026, 1, 1));
  assert.equal(profile.provisionedDevices.length, 2);
  assert.equal(profile.developerCertificates.length, 1);
  assert.equal(profile.entitlements["get-task-allow"], true);
  assert.deepEqual(profile.entitlements["keychain-access-groups"], ["TESTTEAM01.*", "com.apple.token"]);
  assert.equal(profile.uuid.length, 36);
});

test("reads a streamed ad hoc profile, as Apple encodes them", () => {
  const bytes = fixture("adhoc.mobileprovision");
  assert.deepEqual([...bytes.subarray(0, 2)], [0x30, 0x80], "the fixture uses indefinite lengths");
  const profile = readProfile(bytes);
  assert.equal(profile.kind, "adHoc");
  assert.equal(bundleIDPattern(profile), "com.example.app");
  assert.equal(profile.entitlements["aps-environment"], "production");
});

test("tells the kinds of profile apart", () => {
  assert.equal(readProfile(fixture("enterprise.mobileprovision")).kind, "enterprise");
  assert.equal(readProfile(fixture("appstore.mobileprovision")).kind, "appStore");
});

test("knows this iPhone from a profile that lists only one device", () => {
  const development = readProfile(fixture("development.mobileprovision"));
  assert.equal(onlyDevice(development), null);
  const one = "00008120-0011223344556677";
  assert.equal(onlyDevice({ ...development, provisionedDevices: [one] }), one);
  // The same device twice, in either case, is still one.
  assert.equal(onlyDevice({ ...development, provisionedDevices: [one, one.toLowerCase()] }), one);
  assert.equal(onlyDevice({ ...development, provisionedDevices: [] }), null);
  const adHoc = readProfile(fixture("adhoc.mobileprovision"));
  assert.equal(onlyDevice({ ...adHoc, provisionedDevices: [one] }), one);
  // Enterprise and App Store profiles don't list the devices their apps run on.
  assert.equal(onlyDevice({ ...readProfile(fixture("enterprise.mobileprovision")), provisionedDevices: [one] }), null);
  assert.equal(onlyDevice({ ...readProfile(fixture("appstore.mobileprovision")), provisionedDevices: [one] }), null);
});

test("knows which certificates a profile is for", () => {
  const profile = readProfile(fixture("adhoc.mobileprovision"));
  const mismatched = readProfile(fixture("mismatched.mobileprovision"));
  assert.ok(allows(profile, profile.developerCertificates[0]));
  assert.ok(!allows(mismatched, profile.developerCertificates[0]));
});

test("reads a bare plist, and says what a profile is missing", () => {
  const bare = readProfile(plist(`<key>Name</key><string>Bare</string><key>UUID</key><string>X</string>
    <key>ExpirationDate</key><date>1970-01-01T00:00:00Z</date>
    <key>DeveloperCertificates</key><array><data>AQ==</data></array>
    <key>TeamIdentifier</key><array><string>T</string></array>
    <key>Entitlements</key><dict><key>application-identifier</key><string>T.com.x</string></dict>`));
  assert.equal(bare.kind, "appStore");
  assert.equal(bundleIDPattern(bare), "com.x");

  assert.throws(() => readProfile(plist("<key>Name</key><string>No entitlements</string><key>UUID</key><string>X</string>")),
    (error) => error instanceof ProfileError && error.reason === "missing" && error.key === "Entitlements");
  assert.throws(() => readProfile(Uint8Array.of(0x30, 0x80, 0x06)), (error) => error.reason === "notAProfile");
  assert.throws(() => readProfile(fixture("signing.p12")), (error) => error.reason === "notAProfile");
  assert.throws(() => readProfile(new TextEncoder().encode("hello")), (error) => error.reason === "notAProfile");
});

// MARK: Certificates

test("reads an Apple-style signing certificate", () => {
  const profile = readProfile(fixture("development.mobileprovision"));
  const certificate = readCertificate(profile.developerCertificates[0]);
  assert.deepEqual(signingIdentity(certificate), {
    commonName: "iPhone Distribution: OwnStore Test (TESTTEAM01)",
    name: "OwnStore Test (TESTTEAM01)",
    teamID: "TESTTEAM01",
    teamName: "OwnStore Test",
  });
  assert.deepEqual(certificate.notBefore, utc(2026, 10, 18, 15, 46, 48));
  assert.deepEqual(certificate.notAfter, utc(2036, 10, 15, 15, 46, 48));
});

test("refuses what isn't a certificate", () => {
  assert.throws(() => readCertificate(Uint8Array.of(0x30, 0x03, 0x02, 0x01, 0x01)));
  assert.throws(() => readCertificate(new Uint8Array(0)));
});

test("reads times as X.509 writes them", () => {
  const node = (tag, value) => parseDER(Uint8Array.of(tag, value.length, ...new TextEncoder().encode(value)));
  assert.deepEqual(time(node(TAG.utcTime, "491231235959Z")), utc(2049, 12, 31, 23, 59, 59));
  assert.deepEqual(time(node(TAG.utcTime, "500101000000Z")), utc(1950, 1, 1));
  assert.deepEqual(time(node(TAG.generalizedTime, "20510101000000Z")), utc(2051, 1, 1));
  assert.equal(time(node(TAG.generalizedTime, "20510101000000+0100")), undefined);
});

// MARK: Revocation

const ocspFixture = (name) => fixture(`ocsp/${name}`);
const certificate = (name) => readCertificate(ocspFixture(`${name}.der`));
const response = (name) => readOCSPResponse(ocspFixture(`${name}.ocsp`));
/** When the responder made the answer, so it's current. */
const answeredAt = (name) => response(name).singles[0].thisUpdate;

async function status(answer, leaf, ca, now) {
  return revocationStatus(response(answer), certificate(leaf), certificate(ca), now ?? answeredAt(answer));
}

async function rejects(promise, reason) {
  await assert.rejects(promise, (error) => error instanceof RevocationError && error.reason === reason);
}

test("reads what OCSP needs from certificates", async () => {
  const ca = certificate("rsa-ca");
  const leaf = certificate("rsa-good");
  assert.equal(ocspURL(leaf), "http://ocsp.ownstore.test/ocsp03-test");
  // openssl's key IDs are the SHA-1 of the key, like Apple's.
  assert.deepEqual(subjectKeyIdentifier(ca), await publicKeyHash(ca));
  assert.deepEqual(authorityKeyIdentifier(leaf), await publicKeyHash(ca));
});

test("Apple's developer CAs' key IDs are their keys' hashes", async () => {
  const cas = APPLE_DEVELOPER_CAS.map(readCertificate);
  assert.equal(cas.length, 5);
  for (const ca of cas) {
    assert.ok(subjectKeyIdentifier(ca));
    assert.deepEqual(subjectKeyIdentifier(ca), await publicKeyHash(ca));
  }
});

test("the request is the one openssl makes, byte for byte", async () => {
  assert.deepEqual(await ocspRequest(certificate("rsa-good"), certificate("rsa-ca")), ocspFixture("rsa-good.req"));
});

test("reads the responder's answers", () => {
  assert.deepEqual(response("rsa-good").singles.map((single) => single.status), ["good"]);
  assert.deepEqual(response("rsa-unknown").singles.map((single) => single.status), ["unknown"]);
  const [revoked] = response("rsa-revoked").singles;
  assert.equal(revoked.status, "revoked");
  // The fixture revokes it two days before answering.
  assert.ok(Math.abs(revoked.at - revoked.thisUpdate + 2 * 86_400_000) < 120_000);
  assert.ok(revoked.nextUpdate);
  // openssl sends the responder's certificate.
  assert.equal(response("rsa-good").certificates.length, 1);
});

test("says when the responder answered with an error, or not with OCSP", () => {
  // OCSPResponse { responseStatus tryLater (3) }
  assert.throws(() => readOCSPResponse(Uint8Array.of(0x30, 0x03, 0x0a, 0x01, 0x03)), (error) => error.reason === "responderError" && error.detail === 3);
  assert.throws(() => readOCSPResponse(new TextEncoder().encode("<html>")), (error) => error.reason === "malformedResponse");
});

test("believes answers from a responder the CA authorized", async () => {
  for (const ca of ["rsa", "ec"]) {
    assert.deepEqual(await status(`${ca}-good`, `${ca}-good`, `${ca}-ca`), { status: "good" }, ca);
    assert.deepEqual(await status(`${ca}-unknown`, `${ca}-unknown`, `${ca}-ca`), { status: "unknown" }, ca);
    const revoked = await status(`${ca}-revoked`, `${ca}-revoked`, `${ca}-ca`);
    assert.equal(revoked.status, "revoked", ca);
    assert.ok(revoked.at instanceof Date, ca);
  }
});

test("believes answers the CA signed itself", async () => {
  assert.deepEqual(await status("rsa-direct", "rsa-good", "rsa-ca"), { status: "good" });
  assert.deepEqual(await status("ec-direct", "ec-good", "ec-ca"), { status: "good" });
});

test("doesn't believe answers from anyone else", async () => {
  await rejects(status("rsa-forged", "rsa-good", "rsa-ca"), "badSignature");
  // Its signer isn't allowed to sign OCSP answers.
  await rejects(status("rsa-ca-only-responder", "rsa-good", "rsa-ca"), "badSignature");
  // It names another CA's key.
  await rejects(status("rsa-good", "rsa-good", "ec-ca"), "notAboutThisCertificate");
});

test("doesn't take an answer about another certificate", async () => {
  await rejects(status("rsa-revoked", "rsa-good", "rsa-ca"), "notAboutThisCertificate");
});

test("doesn't take old answers, or ones from the future", async () => {
  const answered = answeredAt("rsa-good").getTime();
  await rejects(status("rsa-good", "rsa-good", "rsa-ca", new Date(answered + 8 * 86_400_000)), "stale");
  await rejects(status("rsa-good", "rsa-good", "rsa-ca", new Date(answered - 3_600_000)), "stale");
});

// MARK: Asking

/** A transport that answers with `answer`'s fixture, and notes what it sent. */
function responder(answer, httpStatus = 200) {
  const sent = [];
  const transport = async (url, body) => {
    sent.push({ url, body });
    return { status: httpStatus, body: ocspFixture(`${answer}.ocsp`) };
  };
  return { sent, transport };
}

test("a revoked certificate is flagged by one check", async () => {
  const { sent, transport } = responder("rsa-revoked");
  const result = await checkRevocation(ocspFixture("rsa-revoked.der"), {
    transport,
    trustedIssuers: [ocspFixture("rsa-ca.der")],
    now: answeredAt("rsa-revoked"),
  });
  assert.equal(result.status, "revoked");
  assert.equal(sent.length, 1);
  assert.equal(sent[0].url, "http://ocsp.ownstore.test/ocsp03-test");
  assert.deepEqual(sent[0].body, await ocspRequest(certificate("rsa-revoked"), certificate("rsa-ca")));
});

test("a good certificate is good", async () => {
  const { transport } = responder("ec-good");
  const result = await checkRevocation(ocspFixture("ec-good.der"), { transport, trustedIssuers: [ocspFixture("ec-ca.der")], now: answeredAt("ec-good") });
  assert.deepEqual(result, { status: "good" });
});

test("says when the issuer isn't trusted, or the responder fails", async () => {
  const leaf = ocspFixture("rsa-good.der");
  await assert.rejects(
    checkRevocation(leaf, { transport: responder("rsa-good").transport, trustedIssuers: [ocspFixture("ec-ca.der")] }),
    (error) => error.reason === "unknownIssuer" && error.detail === "OwnStore Test Developer Relations CA",
  );
  await assert.rejects(
    checkRevocation(leaf, { transport: responder("rsa-good", 404).transport, trustedIssuers: [ocspFixture("rsa-ca.der")] }),
    (error) => error.reason === "httpStatus" && error.detail === 404,
  );
  await assert.rejects(
    checkRevocation(leaf, {
      transport: async () => {
        throw new TypeError("Load failed");
      },
      trustedIssuers: [ocspFixture("rsa-ca.der")],
    }),
    (error) => error.reason === "network",
  );
});

test("finds the issuer of a certificate Apple's developer CAs issued", async () => {
  // The fixture's leaf names its issuer by key ID, which none of Apple's has.
  await assert.rejects(issuerOf(certificate("rsa-good")), (error) => error.reason === "unknownIssuer");
  const g3 = readCertificate(APPLE_DEVELOPER_CAS[1]);
  const leaf = { ...certificate("rsa-good"), issuer: g3.subject, extensions: new Map() };
  assert.equal((await issuerOf(leaf)).der, APPLE_DEVELOPER_CAS[1]);
});

// MARK: The page's checks

/** Opens a .p12 as signer.js's openP12 answers, with "ownstore" as the
 *  password and the certificate a profile lists, as CertKit's tests do. */
const opener = (profileName) => async (data, password) => {
  if (password !== "ownstore") return { status: "wrongPassword" };
  return { status: "opened", certificate: readProfile(fixture(profileName)).developerCertificates[0] };
};
const pair = (profileName) => ({ p12: { name: "signing.p12", data: fixture("signing.p12") }, profile: { name: profileName, data: fixture(profileName) } });

test("gathers the certificate's files as Atelier does", async () => {
  let files = { p12: null, profile: null };
  files = await addFile(files, "Harbor.P12", fixture("signing.p12"));
  assert.equal(files.p12.name, "Harbor.P12");
  // A profile without its extension, as some downloads come.
  files = await addFile(files, "download", fixture("adhoc.mobileprovision"));
  assert.equal(files.profile.name, "download");

  // A ZIP holding both, without macOS's resource forks.
  const zipped = await addFile({ p12: null, profile: null }, "pair.zip", fixture("pair.zip"));
  assert.equal(zipped.p12.name, "OwnStore Test.p12");
  assert.deepEqual(zipped.p12.data, fixture("signing.p12"));
  assert.equal(zipped.profile.name, "OwnStore Test.mobileprovision");

  const refused = (name, data) => addFile(files, name, data).then(() => assert.fail(name), (error) => {
    assert.ok(error instanceof CheckError);
    return error.message;
  });
  assert.equal(await refused("notes.txt", new TextEncoder().encode("hi")), "notes.txt isn't a .p12, a .mobileprovision or a ZIP holding them.");
  assert.equal(await refused("broken.zip", new TextEncoder().encode("PK\u0003\u0004nope")), "broken.zip can't be opened as a ZIP.");
});

test("checks the certificate as Atelier checks one it imports", async () => {
  const now = utc(2026, 11, 5);
  const result = await examine(pair("development.mobileprovision"), "ownstore", opener("development.mobileprovision"), now);
  assert.equal(result.name, "OwnStore Test (TESTTEAM01)");
  assert.equal(result.teamName, "OwnStore Test");
  assert.equal(result.kind, "development");
  assert.equal(result.blocked, false);
  assert.deepEqual(result.rows.map((row) => row.state), ["ok", "ok", "ok"]);
  assert.equal(result.rows[1].text, ` is for this certificate, until ${result.expiry.date.toLocaleDateString("en-GB", { day: "numeric", month: "short", year: "numeric" })}`);
  assert.equal(result.rows[2].lead, "2 devices");
  assert.deepEqual(result.rows[2].devices, [
    { udid: "00008110-000A1B2C3D4E5F60", models: "iPhone 13 mini, 13, 13 Pro, 13 Pro Max, 14, 14 Plus or SE (3rd gen), or iPad mini (6th gen)" },
    { udid: "00008120-0011223344556677", models: "iPhone 14 Pro, 14 Pro Max, 15 or 15 Plus, or iPad (A16)" },
  ]);
  assert.match(summary(result), /^Development · \d+ days left$/);
  assert.equal(result.expiry.daysLeft, Math.ceil((result.expiry.date - now) / 86_400_000));

  const later = await examine(pair("development.mobileprovision"), "ownstore", opener("development.mobileprovision"), new Date(result.expiry.date.getTime() + 1000));
  assert.ok(later.blocked);
  assert.match(later.rows[1].text, /^It expired on /);
  assert.equal(summary(later), "Development · Expired");
});

test("says what's wrong with the files, where the page shows it", async () => {
  const failure = (promise) => promise.then(() => assert.fail("checked"), (error) => {
    assert.ok(error instanceof CheckError);
    return [error.field, error.message];
  });
  assert.deepEqual(await failure(examine(pair("adhoc.mobileprovision"), "nope", opener("adhoc.mobileprovision"))), ["password", "The password is wrong."]);
  const notAProfile = { ...pair("adhoc.mobileprovision"), profile: { name: "notes.mobileprovision", data: new TextEncoder().encode("hi") } };
  assert.deepEqual(await failure(examine(notAProfile, "ownstore", opener("adhoc.mobileprovision"))), ["files", "notes.mobileprovision isn't a provisioning profile."]);
  const unreadable = async () => ({ status: "unreadable" });
  assert.deepEqual(await failure(examine(pair("adhoc.mobileprovision"), "ownstore", unreadable)), ["files", "This .p12 file can't be read. It may be damaged, or not a .p12 at all."]);

  // Files that don't go together make a certificate the page can show,
  // with what's wrong in its card.
  const mismatched = await examine(pair("mismatched.mobileprovision"), "ownstore", opener("development.mobileprovision"));
  assert.ok(mismatched.blocked);
  assert.equal(mismatched.rows[1].text, "The profile “OwnStore Test mismatched” wasn't made for the certificate “OwnStore Test (TESTTEAM01)”. Pick the profile that goes with this certificate.");
});

test("says who can install with each kind of profile", async () => {
  const row = async (name) => (await examine(pair(name), "ownstore", opener(name))).rows[2];
  assert.deepEqual(await row("enterprise.mobileprovision"), { state: "ok", lead: "Any iPhone", text: " can install it: enterprise profiles don't list devices" });
  assert.deepEqual(await row("appstore.mobileprovision"), { state: "bad", text: "This certificate can only sign apps for the App Store and TestFlight, not for this iPhone." });
  assert.equal((await row("adhoc.mobileprovision")).state, "ok");
});

test("says what Apple answered, and that not knowing doesn't stop the install", () => {
  assert.deepEqual(revocationRow({ status: "good" }), { state: "ok", lead: "Apple", text: " hasn't revoked it" });
  assert.equal(revocationRow({ status: "revoked", at: null }).state, "bad");
  assert.equal(revocationRow({ status: "unknown" }).state, "note");
  assert.equal(revocationRow(null).state, "note");
});
