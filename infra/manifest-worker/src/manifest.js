// Builds the itms-services install manifest for an IPA served from the
// device's own loopback server. Pure function: no I/O, so it is easy to test
// and to port into another host later.

const BUNDLE_ID = /^[A-Za-z0-9.-]{1,255}$/;
const VERSION = /^[A-Za-z0-9._+-]{1,64}$/;
const MAX_NAME = 256;
const MAX_URL = 2048;
const LOOPBACK_HOSTS = new Set(["127.0.0.1", "localhost", "[::1]"]);

export class ManifestError extends Error {}

export function escapeXml(value) {
  return value
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;")
    .replace(/'/g, "&apos;");
}

// Only loopback URLs are accepted. The endpoint exists to point iOS back at
// the app's own server; refusing other hosts keeps it from becoming a
// general-purpose manifest generator for IPAs hosted anywhere.
export function validatePackageUrl(raw) {
  if (typeof raw !== "string" || raw.length === 0) {
    throw new ManifestError("missing url");
  }
  if (raw.length > MAX_URL) {
    throw new ManifestError("url too long");
  }
  let url;
  try {
    url = new URL(raw);
  } catch {
    throw new ManifestError("url is not a valid URL");
  }
  if (url.protocol !== "http:") {
    throw new ManifestError("url must use http");
  }
  if (!LOOPBACK_HOSTS.has(url.hostname)) {
    throw new ManifestError("url must point at a loopback address");
  }
  if (url.username || url.password) {
    throw new ManifestError("url must not carry credentials");
  }
  return url.toString();
}

// Several apps can share one manifest (repeat the parameters once per app).
// Whether iOS installs them all behind one alert is what the spike tests.
export const MAX_ITEMS = 10;

// Accepts one item, or an array of items for a multi-app manifest.
export function buildManifest(input) {
  const items = Array.isArray(input) ? input : [input];
  if (items.length === 0 || items.length > MAX_ITEMS) {
    throw new ManifestError(`a manifest takes 1 to ${MAX_ITEMS} apps`);
  }
  const entries = items.map(itemXml).join("");

  return `<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>items</key>
  <array>
${entries}  </array>
</dict>
</plist>
`;
}

function itemXml({ bundleId, version, name, url }) {
  if (typeof bundleId !== "string" || !BUNDLE_ID.test(bundleId)) {
    throw new ManifestError("invalid bundleid");
  }
  if (typeof version !== "string" || !VERSION.test(version)) {
    throw new ManifestError("invalid version");
  }
  if (typeof name !== "string" || name.length === 0 || name.length > MAX_NAME) {
    throw new ManifestError("invalid name");
  }
  // Control characters are not allowed in XML 1.0 and would break the plist.
  if (/[\u0000-\u0008\u000B\u000C\u000E-\u001F]/.test(name)) {
    throw new ManifestError("invalid name");
  }
  const packageUrl = validatePackageUrl(url);

  return `    <dict>
      <key>assets</key>
      <array>
        <dict>
          <key>kind</key>
          <string>software-package</string>
          <key>url</key>
          <string>${escapeXml(packageUrl)}</string>
        </dict>
      </array>
      <key>metadata</key>
      <dict>
        <key>bundle-identifier</key>
        <string>${escapeXml(bundleId)}</string>
        <key>bundle-version</key>
        <string>${escapeXml(version)}</string>
        <key>kind</key>
        <string>software</string>
        <key>title</key>
        <string>${escapeXml(name)}</string>
      </dict>
    </dict>
`;
}

// Accepts Atelier's parameter names and the api.palera.in ones
// (bundleid, name, version, fetchurl) so Feather-style URLs work unchanged.
// For several apps, repeat all four parameters once per app, in the same
// order; a single app returns one item, as before.
export function paramsFromSearch(searchParams) {
  const bundleIds = searchParams.getAll("bundleid");
  const versions = searchParams.getAll("version");
  const names = searchParams.getAll("name");
  const urls = searchParams.has("url") ? searchParams.getAll("url") : searchParams.getAll("fetchurl");

  const lists = [bundleIds, versions, names, urls];
  const count = Math.max(...lists.map((list) => list.length));
  if (count <= 1) {
    return {
      bundleId: bundleIds[0],
      version: versions[0],
      name: names[0],
      url: urls[0],
    };
  }
  if (count > MAX_ITEMS) {
    throw new ManifestError(`a manifest takes 1 to ${MAX_ITEMS} apps`);
  }
  if (!lists.every((list) => list.length === count)) {
    throw new ManifestError("repeat bundleid, name, version and url once per app");
  }
  return bundleIds.map((bundleId, i) => ({
    bundleId,
    version: versions[i],
    name: names[i],
    url: urls[i],
  }));
}
