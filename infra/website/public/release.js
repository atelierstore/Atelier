// Atelier's newest release, as its own source lists it (source.json on the
// source branch, which scripts/update_source.py writes, newest version
// first), for the sideload page (sideload.js) and the Apple ID page
// (apple-id.js). Nothing here touches the page, so the tests read it too.

/** Atelier's bundle ID, as its source lists it. */
export const ATELIER_BUNDLE_ID = "com.atelier.app";

/** The newest version of Atelier in `source`, an AltStore source, as
 *  {version, downloadURL, size, date, sha256}, or null when the source
 *  doesn't list one to download over HTTPS. `size` (in bytes), `date` (a
 *  Date) and `sha256` (lowercase) are null when the source doesn't give
 *  them as they should be. */
export function newestRelease(source) {
  const apps = Array.isArray(source?.apps) ? source.apps : [];
  const app = apps.find((candidate) => candidate?.bundleIdentifier === ATELIER_BUNDLE_ID);
  const latest = Array.isArray(app?.versions) ? app.versions[0] : null;
  if (!latest || typeof latest !== "object") return null;
  const version = [latest.marketingVersion, latest.version].find((value) => typeof value === "string" && value.trim());
  const downloadURL = httpsAddress(latest.downloadURL);
  if (!version || !downloadURL) return null;
  const date = typeof latest.date === "string" ? new Date(latest.date) : null;
  return {
    version: version.trim(),
    downloadURL,
    size: Number.isSafeInteger(latest.size) && latest.size > 0 ? latest.size : null,
    date: date && !Number.isNaN(date.getTime()) ? date : null,
    sha256: typeof latest.sha256 === "string" && /^[0-9a-f]{64}$/i.test(latest.sha256) ? latest.sha256.toLowerCase() : null,
  };
}

/** Where rootshell downloads atelier-install from: its newest release. */
const INSTALLER = "https://github.com/atelierstore/atelier-install/releases/latest/download/atelier-install.wasm";

/** The line that installs `release` in rootshell, as the Apple ID page
 *  gives it to copy. It downloads atelier-install, saves the iPhone's Wi-Fi
 *  address, which the installer pairs with, and runs the installer on the
 *  release's IPA, checked against its SHA-256 when the source gives one.
 *  What's added after it, such as --port, goes to the installer.
 *
 *  It starts with `true` because rootshell only runs a .wasm program that
 *  comes after && in a line its own shell reads, and it hands any line to
 *  ios_system, which answers "wasm: command not found", unless the line
 *  starts with one of its shell's own commands, as `true` is.
 *
 *  null when the IPA's address has more than letters, digits and `._~/%+-`
 *  after https://, which a shell could read as something else (GitHub's
 *  release addresses don't). */
export function installLine(release) {
  if (!/^https:\/\/[A-Za-z0-9._~\/%+-]+$/.test(release.downloadURL)) return null;
  const install = `./atelier-install.wasm --ipa ${release.downloadURL}` + (release.sha256 ? ` --sha256 ${release.sha256}` : "");
  return `true && curl -fsSLO ${INSTALLER} && ifconfig en0 > ifconfig.txt && ${install}`;
}

/** "1 Nov 2026", in the viewer's time zone. */
export function formatDate(date) {
  return date.toLocaleDateString("en-GB", { day: "numeric", month: "short", year: "numeric" });
}

/** A SHA-256's first and last 8 digits, enough to tell it at a glance. */
export function shortHash(sha256) {
  return `${sha256.slice(0, 8)}…${sha256.slice(-8)}`;
}

function httpsAddress(text) {
  if (typeof text !== "string") return null;
  try {
    const url = new URL(text);
    return url.protocol === "https:" ? url.href : null;
  } catch {
    return null;
  }
}
