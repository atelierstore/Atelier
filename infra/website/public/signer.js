// Atelier signed in the page (#152), as Atelier signs an IPA (SigningKit's
// IPASigner and ZsignEngine), for Atelier's own release: the app unpacked
// into zsign's in-memory file system, prepared as Feather prepares an app,
// given its packaged certificate, signed by zsign, checked as ZsignEngine
// checks zsign's work, and packed again. `zsign` is a module that
// public/zsign.js makes: zsign and OpenSSL in WebAssembly, built by
// wasm/build.sh from the fork and commit Atelier signs with. Nothing here
// touches a page; the page runs it in signing-worker.js.

import { hasCMSSignature, inspect } from "./macho.js";
import { PACKAGED_CERTIFICATE, takesCertificate } from "./packaged.js";
import { PlistError, isDictionary, parsePlist, writePlist } from "./plist.js";
import { ZipError, bytesFile, centralDirectory, dosTime, extract, writeZip } from "./zip.js";

/** Why Atelier couldn't be signed: `reason` is the SigningError case
 *  (SigningKit) it stands for, `message` what the page says, and `detail`
 *  what went wrong in zsign's and the IPA's terms, for the console. */
export class SignError extends Error {
  constructor(reason, message, detail = message) {
    super(message);
    this.name = "SignError";
    this.reason = reason;
    this.detail = detail;
  }
}

const JOB = "/job";
const PAYLOAD = `${JOB}/Payload`;
// Atelier 0.4.0 is 29 MB unpacked. Much more and Safari runs out of memory.
const MAX_UNPACKED = 256 << 20;
const FILE_TYPE = 0o170000;
const DIRECTORY = 0o040000;
const SYMLINK = 0o120000;

const fail = {
  damaged: (why) => new SignError("corruptArchive", "This IPA is damaged or isn't an app. Download it again, or choose another file.", `The IPA is damaged or isn't an app: ${why}.`),
  tooLarge: () => new SignError("corruptArchive", "This IPA is too large to sign here.", `The app is over ${MAX_UNPACKED >> 20} MB unpacked.`),
  unsupportedBinary: (path) => new SignError("unsupportedBinary", `Part of the app (${part(path)}) isn't made for iPhone, so it can't be signed.`, `${path} isn't an iOS binary.`),
  encryptedBinary: (path) => new SignError("encryptedBinary", "This IPA is still locked by the App Store, so it can't be signed.", `${path} is encrypted by the App Store.`),
  badCertificate: () => new SignError("badCertificate", "Your certificate couldn't sign Atelier. Its password may be wrong, or its .p12 and profile don't belong together.", "zsign couldn't load the certificate."),
  unsupportedCertificate: () => new SignError(
    "unsupportedCertificate",
    "Atelier can't be signed with this certificate: Apple didn't issue it for signing apps. Use a development, ad hoc or enterprise certificate.",
    "zsign only signs with certificates issued by Apple's developer CAs (WWDR G1 or G3); it would have left the app unsigned.",
  ),
  unsignedBinary: (path) => new SignError("unsignedBinary", `Part of Atelier (${part(path)}) couldn't be signed, so it wouldn't open. Try again.`, `zsign signed the app but left ${path} unsigned.`),
  signingFailed: (detail = "zsign couldn't sign the app.") => new SignError("signingFailed", "Atelier couldn't be signed. Try again.", detail),
};

/** "Foo" for "Frameworks/Foo.framework/Foo", as SigningError names parts. */
const part = (path) => path.split("/").filter(Boolean).pop() ?? path;

// MARK: Reading the IPA

/** What the page needs from the IPA before signing it: {bundleID, version,
 *  takesCertificate}, from the app's Info.plist, `bundleID` and `version`
 *  null when it has none. Throws a SignError. */
export async function readAppInfo(ipa) {
  const file = bytesFile(ipa);
  let plist;
  try {
    const entries = await centralDirectory(file, { name: "the IPA" });
    const entry = entries.find((one) => isTopLevelInfoPlist(one.path));
    if (!entry) throw fail.damaged("there's no app in its Payload folder");
    plist = parsePlist(await extract(file, entry, 1 << 20, "the IPA"), "Info.plist");
  } catch (error) {
    if (error instanceof ZipError || error instanceof PlistError) throw fail.damaged(error.message);
    throw error;
  }
  if (!isDictionary(plist)) throw fail.damaged("its Info.plist isn't a dictionary");
  const text = (key) => (typeof plist[key] === "string" && plist[key].trim() ? plist[key].trim() : null);
  return {
    bundleID: text("CFBundleIdentifier"),
    version: text("CFBundleShortVersionString") ?? text("CFBundleVersion"),
    takesCertificate: takesCertificate(plist),
  };
}

/** `Payload/<App>.app/Info.plist`, not a plug-in's or a framework's. */
function isTopLevelInfoPlist(path) {
  const parts = path.split("/");
  return parts.length === 3 && parts[0] === "Payload" && parts[1].endsWith(".app") && parts[2] === "Info.plist";
}

// MARK: The .p12

const P12_STATUS = ["opened", "unreadable", "wrongPassword", "noIdentity"];

/** Opens the .p12 with `password`, as the page's checks do before anything
 *  is signed: {status: "opened", certificate} with the certificate's DER,
 *  or {status} "unreadable", "wrongPassword" or "noIdentity". */
export function openP12(zsign, p12, password) {
  const { FS } = zsign;
  const folder = "/p12";
  remove(FS, folder);
  FS.mkdir(folder);
  try {
    FS.writeFile(`${folder}/certificate.p12`, p12);
    const code = zsign.ccall(
      "atelier_open_p12", "number", ["string", "string", "string"],
      [`${folder}/certificate.p12`, password, `${folder}/certificate.der`],
    );
    const status = P12_STATUS[code] ?? "unreadable";
    return status === "opened" ? { status, certificate: FS.readFile(`${folder}/certificate.der`) } : { status };
  } finally {
    remove(FS, folder);
  }
}

// MARK: Signing

/** Atelier from `ipa` (its bytes) signed with the .p12 `p12`, its
 *  `password` and the profile `profile`, with `packagedCertificate` (the
 *  bytes of AtelierCertificate.plist, or null) inside: the signed IPA's
 *  bytes. zsign signs with the profile's entitlements, which is what
 *  Atelier's fitting (#7) comes to for its release, whose binaries are
 *  unsigned and ask for none. Throws a SignError. */
export async function signIPA(zsign, { ipa, p12, profile, password, packagedCertificate = null }) {
  const { FS } = zsign;
  remove(FS, JOB);
  FS.mkdir(JOB);
  try {
    const modes = await unpack(FS, bytesFile(ipa));
    const app = findApp(FS);
    prepare(FS, app);
    setPackagedCertificate(FS, app, packagedCertificate);
    checkBinaries(FS, app);

    FS.writeFile(`${JOB}/certificate.p12`, p12);
    FS.writeFile(`${JOB}/profile.mobileprovision`, profile);
    const code = zsign.ccall(
      "atelier_sign", "number", ["string", "string", "string", "string"],
      [app, `${JOB}/certificate.p12`, `${JOB}/profile.mobileprovision`, password],
    );
    // zsign fails before signing anything only when the certificate is the
    // problem (ZsignEngine).
    if (code === 1) throw fail.badCertificate();
    if (code !== 0) throw fail.signingFailed();
    // zsign reports success even when it couldn't build the CMS signature.
    // For the main executable that's the certificate; for anything else, a
    // file zsign skipped.
    for (const [index, binary] of binaries(FS, app).entries()) {
      if (withReader(FS, binary, hasCMSSignature)) continue;
      throw index === 0 ? fail.unsupportedCertificate() : fail.unsignedBinary(binary.slice(app.length + 1));
    }
    return await pack(FS, modes);
  } finally {
    remove(FS, JOB);
  }
}

/** Only the app is unpacked: other top-level folders (SwiftSupport,
 *  Symbols) are for the App Store. Each file keeps its date, which zsign
 *  changes on the files it writes. The modes the IPA gives, by path. */
async function unpack(FS, file) {
  let entries;
  try {
    entries = (await centralDirectory(file, { name: "the IPA" })).filter((entry) => entry.path.startsWith("Payload/") && !entry.path.includes("__MACOSX"));
  } catch (error) {
    throw error instanceof ZipError ? fail.damaged(error.message) : error;
  }
  if (!entries.length) throw fail.damaged("there's no Payload folder");
  if (entries.reduce((sum, entry) => sum + entry.size, 0) > MAX_UNPACKED) throw fail.tooLarge();

  const modes = new Map();
  for (const entry of entries) {
    const relative = entry.path.replace(/\/+$/, "");
    if (relative.split("/").some((name) => name === "" || name === "." || name === "..")) throw fail.damaged(`it has a file named ${entry.path}`);
    // Made on a Mac or Linux, the high bits are the file's mode; else 0.
    const mode = entry.attributes >>> 16;
    const path = `${JOB}/${relative}`;
    try {
      if (entry.path.endsWith("/") || (mode & FILE_TYPE) === DIRECTORY) {
        FS.mkdirTree(path);
      } else {
        FS.mkdirTree(path.slice(0, path.lastIndexOf("/")));
        const data = await extract(file, entry, Infinity, "the IPA");
        if ((mode & FILE_TYPE) === SYMLINK) {
          FS.symlink(new TextDecoder().decode(data), path);
        } else {
          FS.writeFile(path, data);
          const date = fromDosTime(entry.modified);
          FS.utime(path, date, date);
        }
      }
    } catch (error) {
      if (error instanceof ZipError) throw fail.damaged(error.message);
      if (error?.name === "ErrnoError") throw fail.damaged(`${entry.path} can't be unpacked`);
      throw error;
    }
    modes.set(relative, mode);
  }
  return modes;
}

function findApp(FS) {
  const apps = list(FS, PAYLOAD).filter((name) => name.endsWith(".app"));
  if (apps.length !== 1) throw fail.damaged(apps.length ? "its Payload folder holds more than one app" : "there's no app in its Payload folder");
  const app = `${PAYLOAD}/${apps[0]}`;
  if (!exists(FS, `${app}/Info.plist`)) throw fail.damaged("the app has no Info.plist");
  return app;
}

/** What Feather does to every app before zsign signs it (IPASigner.prepare). */
function prepare(FS, app) {
  removeSupportedDevices(FS, `${app}/Info.plist`);
  for (const name of ["embedded.mobileprovision", "com.apple.WatchPlaceholder", "SignedByEsign"]) remove(FS, `${app}/${name}`);
  // Old signatures in every bundle; zsign writes new ones.
  const signatures = walk(FS, app).filter((path) => part(path) === "_CodeSignature").sort((a, b) => b.length - a.length);
  for (const path of signatures) remove(FS, path);
  // Watch app placeholders without an Info.plist can't be signed or installed.
  for (const name of list(FS, `${app}/Watch`)) {
    if (name.endsWith(".app") && !exists(FS, `${app}/Watch/${name}/Info.plist`)) remove(FS, `${app}/Watch/${name}`);
  }
}

/** Drops UISupportedDevices. Atelier keeps the plist's format; this writes
 *  XML, which iOS reads as well, and only when there's something to drop. */
function removeSupportedDevices(FS, path) {
  let info;
  try {
    info = parsePlist(FS.readFile(path), "Info.plist");
  } catch {
    return;
  }
  if (!isDictionary(info) || !("UISupportedDevices" in info)) return;
  delete info.UISupportedDevices;
  FS.writeFile(path, writePlist(info));
}

/** Puts the certificate Atelier imports on its first launch next to its
 *  Info.plist (#113), after removing any the app had: a link is removed,
 *  not written through (#22). Before signing, so the signature seals it. */
function setPackagedCertificate(FS, app, certificate) {
  const path = `${app}/${PACKAGED_CERTIFICATE}`;
  remove(FS, path);
  if (certificate) FS.writeFile(path, certificate);
}

/** Every bundle's executable and every dylib must be a Mach-O that isn't
 *  App Store-encrypted. zsign would fail on the first, and sign the second
 *  into an app that never launches. */
function checkBinaries(FS, app) {
  for (const binary of binaries(FS, app)) {
    const kind = withReader(FS, binary, inspect);
    if (!kind.machO) throw fail.unsupportedBinary(binary.slice(app.length + 1));
    if (kind.encrypted) throw fail.encryptedBinary(binary.slice(app.length + 1));
  }
}

/** The main executable, then every bundle's and every dylib. */
function binaries(FS, app) {
  const main = executable(FS, app);
  if (!main) throw fail.unsupportedBinary(part(app));
  const result = [main];
  for (const path of walk(FS, app)) {
    const name = part(path);
    const extension = name.includes(".") ? name.slice(name.lastIndexOf(".") + 1) : "";
    if (extension === "dylib") {
      result.push(path);
    } else if (["app", "appex", "framework", "xpc"].includes(extension) && exists(FS, `${path}/Info.plist`)) {
      const found = executable(FS, path);
      if (found) result.push(found);
      // Apps and extensions always have one; a framework can be resources only.
      else if (extension !== "framework") throw fail.unsupportedBinary(path.slice(app.length + 1));
    }
  }
  return result;
}

/** A bundle's executable, if it's there: CFBundleExecutable, or the
 *  bundle's name when its Info.plist doesn't say. */
function executable(FS, bundle) {
  let name = null;
  try {
    const info = parsePlist(FS.readFile(`${bundle}/Info.plist`), "Info.plist");
    if (isDictionary(info) && typeof info.CFBundleExecutable === "string") name = info.CFBundleExecutable;
  } catch {
    // Named after the bundle, then.
  }
  name ??= part(bundle).replace(/\.[^.]*$/, "");
  const path = `${bundle}/${name}`;
  try {
    return FS.isFile(FS.stat(path).mode) ? path : null;
  } catch {
    return null;
  }
}

/** The app packed as Atelier packs it: Payload and everything in it, by
 *  path, each file deflated when that makes it smaller. Files keep the
 *  modes the IPA gave them, executables included, which zsign's rewrite
 *  would otherwise turn into plain files; new ones are 644, folders 755. */
async function pack(FS, modes) {
  const paths = ["Payload", ...walk(FS, PAYLOAD).map((path) => path.slice(JOB.length + 1)).sort()];
  const files = paths.map((relative) => {
    const path = `${JOB}/${relative}`;
    const stat = FS.lstat(path);
    const type = stat.mode & FILE_TYPE;
    const given = modes.get(relative);
    const mode = given && (given & FILE_TYPE) === type ? given : type | (type === DIRECTORY ? 0o755 : 0o644);
    const modified = dosTime(stat.mtime);
    if (type === DIRECTORY) return { path: `${relative}/`, mode, modified };
    const data = type === SYMLINK ? new TextEncoder().encode(FS.readlink(path)) : FS.readFile(path);
    return { path: relative, data, mode, modified };
  });
  return writeZip(files);
}

// MARK: The file system

/** Runs `body` with a `read(offset, count)` on the file at `path`. */
function withReader(FS, path, body) {
  const stream = FS.open(path, "r");
  try {
    return body((offset, count) => {
      const bytes = new Uint8Array(Math.max(0, count));
      return bytes.subarray(0, FS.read(stream, bytes, 0, bytes.length, offset));
    });
  } finally {
    FS.close(stream);
  }
}

function list(FS, folder) {
  try {
    return FS.readdir(folder).filter((name) => name !== "." && name !== "..");
  } catch {
    return [];
  }
}

/** Every path under `folder`, without following links. */
function walk(FS, folder) {
  const found = [];
  for (const name of list(FS, folder)) {
    const path = `${folder}/${name}`;
    found.push(path);
    if (FS.isDir(FS.lstat(path).mode)) found.push(...walk(FS, path));
  }
  return found;
}

function exists(FS, path) {
  try {
    FS.lstat(path);
    return true;
  } catch {
    return false;
  }
}

/** Removes a file, a link or a folder with everything in it, if it's there. */
function remove(FS, path) {
  if (!exists(FS, path)) return;
  if (FS.isDir(FS.lstat(path).mode)) {
    for (const name of list(FS, path)) remove(FS, `${path}/${name}`);
    FS.rmdir(path);
  } else {
    FS.unlink(path);
  }
}

/** A ZIP's DOS time and date as a Date, in local time as dosTime writes it. */
function fromDosTime(value) {
  const day = value >>> 16;
  const time = value & 0xffff;
  return new Date(1980 + (day >> 9), ((day >> 5) & 15) - 1, day & 31, time >> 11, (time >> 5) & 63, (time & 31) * 2);
}
