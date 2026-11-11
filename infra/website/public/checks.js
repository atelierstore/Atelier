// The certificate page's checks (#152), as Atelier checks a certificate it
// imports (CertKit's CertificateFiles, CertificateImporter and
// CertificateNotes), in Atelier's words: the files gathered from the picker
// or a ZIP, the .p12 opened with its password, the profile read and matched
// to it, and what would keep iOS from installing Atelier with them. Apple's
// answer on revocation comes after (ocsp.js). Nothing here touches a page.

import { profileDevices } from "./devices.js";
import { ProfileError, allows, readProfile } from "./profile.js";
import { formatDate } from "./release.js";
import { readCertificate, signingIdentity } from "./x509.js";
import { ZipError, bytesFile, centralDirectory, extract } from "./zip.js";

/** Why the files can't make a certificate: `field` is where the page says
 *  it, "password" or "files". */
export class CheckError extends Error {
  constructor(message, field = "files") {
    super(message);
    this.name = "CheckError";
    this.field = field;
  }
}

const P12_EXTENSIONS = ["p12", "pfx"];
const PROFILE_EXTENSIONS = ["mobileprovision", "provisionprofile"];
// A certificate's files are a few kilobytes.
const MAX_FILE = 1 << 20;
const DAY = 86_400_000;

const extension = (name) => (name.includes(".") ? name.slice(name.lastIndexOf(".") + 1).toLowerCase() : "");

/** `files` ({p12, profile}, each {name, data} or null) with the file `name`
 *  holding `data`, which replaces the one of its kind; a ZIP adds what it
 *  holds. Throws a CheckError. */
export async function addFile(files, name, data) {
  const kind = extension(name);
  if (P12_EXTENSIONS.includes(kind)) return { ...files, p12: { name, data } };
  if (PROFILE_EXTENSIONS.includes(kind)) return { ...files, profile: { name, data } };
  if (kind === "zip" || (data[0] === 0x50 && data[1] === 0x4b && data[2] === 0x03 && data[3] === 0x04)) return addZip(files, name, data);
  try {
    readProfile(data);
    return { ...files, profile: { name, data } };
  } catch {
    throw new CheckError(`${name} isn't a .p12, a .mobileprovision or a ZIP holding them.`);
  }
}

async function addZip(files, name, data) {
  const file = bytesFile(data);
  const found = { p12: [], profile: [] };
  try {
    for (const entry of await centralDirectory(file, { name })) {
      const parts = entry.path.split("/");
      const last = parts.at(-1);
      // Skip folders, macOS resource forks and other hidden files.
      if (!last || last.startsWith(".") || parts.includes("__MACOSX")) continue;
      const kind = P12_EXTENSIONS.includes(extension(last)) ? "p12" : PROFILE_EXTENSIONS.includes(extension(last)) ? "profile" : null;
      if (kind) found[kind].push({ name: last, data: await extract(file, entry, MAX_FILE, name) });
    }
  } catch (error) {
    if (error instanceof ZipError) throw new CheckError(`${name} can't be opened as a ZIP.`);
    throw error;
  }
  if (found.p12.length > 1) throw new CheckError(`${name} holds more than one .p12. Pick the files you want one by one instead.`);
  if (found.profile.length > 1) throw new CheckError(`${name} holds more than one .mobileprovision. Pick the files you want one by one instead.`);
  if (!found.p12.length && !found.profile.length) throw new CheckError(`${name} holds no .p12 or .mobileprovision.`);
  return { p12: found.p12[0] ?? files.p12, profile: found.profile[0] ?? files.profile };
}

/** The certificate `files` make with `password`, as the page shows it:
 *  {der, name, teamName, profile, kind, expiry, rows, blocked}. `rows` are
 *  the card's lines but Apple's ({state: "ok", "bad" or "note", lead, text},
 *  `lead` in bold), and `blocked` says one of them keeps iOS from
 *  installing Atelier. `openP12(p12, password)` resolves to {status,
 *  certificate} as signer.js's openP12 answers. Throws a CheckError for
 *  files that make no certificate. */
export async function examine(files, password, openP12, now = new Date()) {
  let profile;
  try {
    profile = readProfile(files.profile.data);
  } catch (error) {
    if (!(error instanceof ProfileError)) throw error;
    throw new CheckError(error.reason === "missing"
      ? "This profile is incomplete, so Atelier can't use it. Get it from your provider again."
      : `${files.profile.name} isn't a provisioning profile.`);
  }

  const opened = await openP12(files.p12.data, password);
  if (opened.status === "wrongPassword") throw new CheckError("The password is wrong.", "password");
  if (opened.status === "noIdentity") throw new CheckError("This .p12 has no certificate with its private key, so it can't sign.");
  if (opened.status !== "opened") throw new CheckError("This .p12 file can't be read. It may be damaged, or not a .p12 at all.");
  let certificate;
  try {
    certificate = readCertificate(opened.certificate);
  } catch {
    throw new CheckError("The certificate in the .p12 can't be read.");
  }
  const identity = signingIdentity(certificate);

  // A tie goes to the certificate, as in CertificateExpiry.
  const expiry = profile.expirationDate < certificate.notAfter
    ? { date: profile.expirationDate, part: "profile" }
    : { date: certificate.notAfter, part: "certificate" };
  const left = expiry.date - now;
  expiry.daysLeft = left <= 0 ? 0 : Math.ceil(left / DAY);

  const rows = [{ state: "ok", lead: "Password", text: " opens the .p12" }];
  if (!allows(profile, opened.certificate)) {
    rows.push({ state: "bad", text: `The profile “${profile.name}” wasn't made for the certificate “${identity.name}”. Pick the profile that goes with this certificate.` });
  } else if (expiry.daysLeft === 0) {
    rows.push({ state: "bad", text: `It expired on ${formatDate(expiry.date)}.` });
  } else {
    rows.push({ state: "ok", lead: "Profile", text: ` is for this certificate, until ${formatDate(expiry.date)}` });
  }
  rows.push(devicesRow(profile));

  return {
    der: opened.certificate,
    name: identity.name,
    teamName: identity.teamName ?? identity.name,
    profile,
    kind: profile.kind,
    expiry,
    rows,
    blocked: rows.some((row) => row.state === "bad"),
  };
}

/** Who the profile lets install Atelier (CertificateNotes). The page can't
 *  read the iPhone's own ID, so it says how many the profile lists, and
 *  each one's UDID and models (devices.js), for the visitor to compare. */
function devicesRow(profile) {
  if (profile.kind === "appStore") {
    return { state: "bad", text: "This certificate can only sign apps for the App Store and TestFlight, not for your iPhone." };
  }
  if (profile.kind === "enterprise") return { state: "ok", lead: "Any iPhone", text: " can install it: enterprise profiles don't list devices" };
  const devices = profileDevices(profile);
  return devices.length === 1
    ? { state: "ok", lead: "1 device", text: " in the profile: iOS installs Atelier only on that iPhone", devices }
    : { state: "ok", lead: `${devices.length} devices`, text: " in the profile: iOS installs Atelier only on those", devices };
}

/** The card's line for Apple's answer (checkRevocation's, or the error it
 *  threw): revoked blocks the install; not knowing doesn't, as Atelier asks
 *  again once it's open. */
export function revocationRow(answer) {
  if (answer?.status === "good") return { state: "ok", lead: "Apple", text: " hasn't revoked it" };
  if (answer?.status === "revoked") return { state: "bad", text: "Apple revoked this certificate, so apps signed with it won't open." };
  return { state: "note", lead: "Apple", text: " couldn't be asked whether it's revoked. You can still install; Atelier asks again once it's open." };
}

/** What the card says under the certificate's name: "Ad hoc · 296 days left". */
export function summary(result) {
  const kind = { development: "Development", adHoc: "Ad hoc", enterprise: "Enterprise", appStore: "App Store" }[result.kind];
  const days = result.expiry.daysLeft;
  return `${kind} · ${days === 0 ? "Expired" : days === 1 ? "1 day left" : `${days} days left`}`;
}
