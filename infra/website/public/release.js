// Atelier's newest release, as its own source lists it (source.json on the
// source branch, which scripts/update_source.py writes, newest version
// first), for the sideload page (sideload.js). Nothing here touches the
// page, so the tests read it too.

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
