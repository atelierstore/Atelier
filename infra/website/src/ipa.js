// Reads an app's name, version and icon out of an IPA on another site, for
// the install link page (/install): the ZIP's end, its central directory,
// Info.plist and the icon, a few small range requests rather than the whole
// IPA, as Atelier reads GitHub sources' IPAs (RemoteIPA in GitHubKit). What's
// what follows Atelier's own rules: IPAInfo's for the name and version,
// IPAIcon's for the icon.
//
// Apps keep their icons in Apple's iPhone PNG variant (a CgBI chunk first,
// pixels in premultiplied BGRA, no zlib header), which only Apple's systems
// draw, so the icon is turned into a plain PNG.

import { PlistError, isDictionary, parsePlist as readPlist } from "../public/plist.js";
import { ZipError, concat, crc32, centralDirectory as readDirectory, extract as readEntry, inflate as inflateData } from "../public/zip.js";

export { isDictionary };

export class IPAError extends Error {}

/** The IPA's server couldn't be reached, or not in time. */
export class ReachError extends Error {}

const LIMITS = {
  directory: 4 << 20, // the central directory
  plist: 1 << 20, // Info.plist
  icon: 1 << 20, // the icon's PNG
  // An icon's width and height. The largest loose icon an app has is
  // usually 180 pixels square; turning a larger one into a plain PNG takes
  // longer than a free Worker may.
  iconSide: 512,
};

/** The app in the IPA at `url`: {name, version, build, bundleID, size,
 *  icon}, with `icon` a plain PNG's bytes, or null when it has none that can
 *  be read. Throws an IPAError when the IPA can't be read, and a ReachError
 *  when it can't be reached in `timeout` milliseconds. */
export async function readApp(url, { fetch: fetchImpl = fetch, timeout = 8000 } = {}) {
  const file = new RemoteFile(url, fetchImpl, AbortSignal.timeout(timeout));
  const { entries, plistEntry, plist, info } = await readInfoPlist(file);

  let icon = null;
  const appFolder = plistEntry.path.slice(0, -"Info.plist".length);
  const iconEntry = iconFile(plist, appFolder, entries, LIMITS.icon);
  if (iconEntry) {
    try {
      icon = await plainPNG(await extract(file, iconEntry, LIMITS.icon));
    } catch (error) {
      // The rest is worth showing without it.
      if (!(error instanceof IPAError)) throw error;
    }
  }
  return { ...info, size: file.size, icon };
}

/** The app in an IPA kept somewhere else, such as the one the certificate
 *  page uploads (ota.js): {name, version, build, bundleID}, as readApp reads
 *  them. `file.read(start, end)` gives bytes `start` to `end`, both included,
 *  and `file.size` is the IPA's size. Throws an IPAError when the IPA can't
 *  be read. */
export async function readInfo(file) {
  return (await readInfoPlist(file)).info;
}

/** The IPA's entries, the app's Info.plist and what appInfo reads from it. */
async function readInfoPlist(file) {
  const entries = await centralDirectory(file);
  const plistEntry = entries.find((entry) => isTopLevelInfoPlist(entry.path));
  if (!plistEntry) throw new IPAError("there's no app in the IPA");
  const plist = parsePlist(await extract(file, plistEntry, LIMITS.plist));
  if (!isDictionary(plist)) throw new IPAError("Info.plist isn't a dictionary");
  return { entries, plistEntry, plist, info: appInfo(plist) };
}

/** `Payload/<App>.app/Info.plist`, not a plug-in's or a framework's. */
export function isTopLevelInfoPlist(path) {
  const parts = path.split("/");
  return parts.length === 3 && parts[0] === "Payload" && parts[1].endsWith(".app") && parts[2] === "Info.plist";
}

/** The name, version and build, as IPAInfo reads them, but passing over
 *  blank ones, as a page can't show a blank name. */
export function appInfo(plist) {
  const text = (key) => (typeof plist[key] === "string" && plist[key].trim() ? plist[key].trim() : null);
  const bundleID = text("CFBundleIdentifier");
  if (!bundleID) throw new IPAError("Info.plist has no bundle ID");
  const shortVersion = text("CFBundleShortVersionString");
  const bundleVersion = text("CFBundleVersion");
  return {
    name: text("CFBundleDisplayName") ?? text("CFBundleName") ?? bundleID,
    version: shortVersion ?? bundleVersion ?? "1.0",
    // Only a build number when it isn't standing in for the version.
    build: shortVersion ? bundleVersion : null,
    bundleID,
  };
}

/** The icon among the IPA's entries, as IPAIcon picks it: the largest PNG
 *  next to Info.plist (in `appFolder`, `Payload/<App>.app/`) that Info.plist
 *  names as its primary icon, or failing that the largest AppIcon*.png there.
 *  Only PNGs up to `maxSize` bytes count. */
export function iconFile(plist, appFolder, entries, maxSize = Infinity) {
  const names = [];
  for (const key of ["CFBundleIcons", "CFBundleIcons~ipad"]) {
    const files = plist[key]?.CFBundlePrimaryIcon?.CFBundleIconFiles;
    if (Array.isArray(files)) names.push(...files);
  }
  if (Array.isArray(plist.CFBundleIconFiles)) names.push(...plist.CFBundleIconFiles);
  const prefixes = names.filter((name) => typeof name === "string");

  const name = (entry) => entry.path.slice(appFolder.length);
  const topLevel = entries.filter((entry) => entry.path.startsWith(appFolder)
    && !name(entry).includes("/") && entry.path.toLowerCase().endsWith(".png"));
  const named = topLevel.filter((entry) => prefixes.some((prefix) => name(entry).startsWith(prefix)));
  const candidates = named.length ? named : topLevel.filter((entry) => name(entry).startsWith("AppIcon"));
  // The largest is the sharpest.
  return candidates
    .filter((entry) => entry.size <= maxSize)
    .reduce((best, entry) => (!best || entry.size > best.size ? entry : best), null);
}

// MARK: The file, a part at a time

class RemoteFile {
  constructor(url, fetchImpl, signal) {
    this.url = url;
    // Called on its own: Workers' fetch throws when it's called as another
    // object's method.
    this.fetch = (...request) => fetchImpl(...request);
    this.signal = signal;
    this.size = null;
  }

  /** Bytes `start` to `end`, both included, or to the end of the file. The
   *  size comes from the first answer: github.com refuses ranges from the
   *  end (bytes=-n) with HTTP 501. */
  async read(start, end) {
    const response = await reach(this.fetch(this.url, {
      headers: { Range: `bytes=${start}-${end}`, "User-Agent": "Atelier" },
      signal: this.signal,
    }));
    // Where a redirect led, such as a GitHub release's file, which is kept
    // somewhere else: the other parts come straight from there.
    if (response.url && response.url !== this.url) this.url = response.url;
    const range = /^bytes (\d+)-(\d+)\/(\d+)$/.exec(response.headers.get("Content-Range") ?? "");
    if (response.status !== 206 || !range) {
      response.body?.cancel().catch(() => {});
      // A 200 is the whole IPA, which this doesn't download.
      throw new IPAError(response.status === 200 || response.status === 206
        ? "the server doesn't send parts of files"
        : `the server answered HTTP ${response.status}`);
    }
    const size = Number(range[3]);
    const length = Math.min(end, size - 1) - start + 1;
    if (Number(range[1]) !== start || Number(range[2]) !== start + length - 1 || (this.size !== null && size !== this.size)) {
      response.body?.cancel().catch(() => {});
      throw new IPAError("the server sent another part of the file");
    }
    this.size = size;
    return body(response, length);
  }
}

/** What `promise` gives, with the network's errors, a timeout's included,
 *  as ReachErrors. */
export async function reach(promise) {
  try {
    return await promise;
  } catch (error) {
    throw new ReachError(error?.message || "the server can't be reached", { cause: error });
  }
}

/** A response's body, which has to be `length` bytes. */
async function body(response, length) {
  const bytes = new Uint8Array(length);
  let received = 0;
  const reader = response.body?.getReader();
  for (;;) {
    const { done, value } = reader ? await reach(reader.read()) : { done: true };
    if (done) break;
    if (received + value.length > length) {
      reader.cancel().catch(() => {});
      throw new IPAError("the server sent more than the part");
    }
    bytes.set(value, received);
    received += value.length;
  }
  if (received !== length) throw new IPAError("the server sent less than the part");
  return bytes;
}

// MARK: ZIP

// public/zip.js reads the IPA, with its errors as IPAErrors.
const centralDirectory = (file) => asIPAError(readDirectory(file, { name: "the IPA", maxLength: LIMITS.directory }));
const extract = (file, entry, limit) => asIPAError(readEntry(file, entry, limit, "the IPA"));
const inflate = (data, format, length) => asIPAError(inflateData(data, format, length, "the IPA"));

async function asIPAError(promise) {
  try {
    return await promise;
  } catch (error) {
    throw error instanceof ZipError ? new IPAError(error.message) : error;
  }
}

async function deflate(data) {
  const compressed = new Blob([data]).stream().pipeThrough(new CompressionStream("deflate"));
  return new Uint8Array(await new Response(compressed).arrayBuffer());
}

// MARK: Property lists

/** Info.plist, as parsePlist in public/plist.js reads it, with its errors as
 *  IPAErrors. */
export function parsePlist(bytes) {
  try {
    return readPlist(bytes, "Info.plist");
  } catch (error) {
    throw error instanceof PlistError ? new IPAError(error.message) : error;
  }
}

// MARK: PNG

const PNG_SIGNATURE = [0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a];

/** The icon as a plain PNG: as it is, or turned from Apple's iPhone PNG
 *  variant (CgBI) into an ordinary one. */
export async function plainPNG(png) {
  if (png.length < 8 || PNG_SIGNATURE.some((byte, i) => png[i] !== byte)) throw new IPAError("the icon isn't a PNG");
  const chunks = [];
  for (let p = 8; p + 12 <= png.length;) {
    const length = u32be(png, p);
    const type = String.fromCharCode(...png.subarray(p + 4, p + 8));
    if (p + 12 + length > png.length) throw new IPAError("the icon is damaged");
    chunks.push({ type, data: png.subarray(p + 8, p + 8 + length) });
    p += 12 + length;
    if (type === "IEND") break;
  }
  if (chunks[0]?.type !== "CgBI") return png;

  const header = chunks.find((chunk) => chunk.type === "IHDR")?.data;
  if (header?.length !== 13) throw new IPAError("the icon is damaged");
  const width = u32be(header, 0);
  const height = u32be(header, 4);
  // 8 bits a channel, RGB with alpha or without, not interlaced: what Xcode
  // writes.
  const channels = { 6: 4, 2: 3 }[header[9]];
  if (header[8] !== 8 || !channels || header[12] !== 0) throw new IPAError("the icon's kind of PNG isn't supported");
  if (!width || !height || width > LIMITS.iconSide || height > LIMITS.iconSide) throw new IPAError("the icon is too large");

  const stride = width * channels;
  const rows = await inflate(concat(chunks.filter((chunk) => chunk.type === "IDAT").map((chunk) => chunk.data)), "deflate-raw", height * (stride + 1));

  // Each row: its filter, undone into `row`, then BGR(A) to RGB(A) with
  // alpha that isn't premultiplied, written out unfiltered.
  const out = new Uint8Array(rows.length);
  let previous = new Uint8Array(stride);
  for (let y = 0; y < height; y++) {
    const at = y * (stride + 1);
    const row = rows.subarray(at + 1, at + 1 + stride);
    unfilter(rows[at], row, previous, channels);
    out[at] = 0;
    for (let x = 0; x < stride; x += channels) {
      const alpha = channels === 4 ? row[x + 3] : 255;
      let red = row[x + 2];
      let green = row[x + 1];
      let blue = row[x];
      if (alpha > 0 && alpha < 255) {
        red = Math.min(255, Math.round((red * 255) / alpha));
        green = Math.min(255, Math.round((green * 255) / alpha));
        blue = Math.min(255, Math.round((blue * 255) / alpha));
      }
      out[at + 1 + x] = red;
      out[at + 2 + x] = green;
      out[at + 3 + x] = blue;
      if (channels === 4) out[at + 4 + x] = alpha;
    }
    previous = row;
  }

  return concat([
    Uint8Array.from(PNG_SIGNATURE),
    pngChunk("IHDR", header),
    pngChunk("IDAT", await deflate(out)),
    pngChunk("IEND", new Uint8Array(0)),
  ]);
}

/** Undoes a PNG row's filter in place, with the row above it unfiltered. */
function unfilter(filter, row, previous, bytesPerPixel) {
  for (let x = 0; x < row.length; x++) {
    const left = x >= bytesPerPixel ? row[x - bytesPerPixel] : 0;
    const up = previous[x];
    const upLeft = x >= bytesPerPixel ? previous[x - bytesPerPixel] : 0;
    switch (filter) {
      case 0:
        return;
      case 1:
        row[x] = (row[x] + left) & 0xff;
        break;
      case 2:
        row[x] = (row[x] + up) & 0xff;
        break;
      case 3:
        row[x] = (row[x] + ((left + up) >> 1)) & 0xff;
        break;
      case 4: {
        const estimate = left + up - upLeft;
        const toLeft = Math.abs(estimate - left);
        const toUp = Math.abs(estimate - up);
        const toUpLeft = Math.abs(estimate - upLeft);
        row[x] = (row[x] + (toLeft <= toUp && toLeft <= toUpLeft ? left : toUp <= toUpLeft ? up : upLeft)) & 0xff;
        break;
      }
      default:
        throw new IPAError("the icon is damaged");
    }
  }
}

const u32be = (b, i) => ((b[i] << 24) | (b[i + 1] << 16) | (b[i + 2] << 8) | b[i + 3]) >>> 0;

function pngChunk(type, data) {
  const chunk = new Uint8Array(12 + data.length);
  const view = new DataView(chunk.buffer);
  view.setUint32(0, data.length);
  for (let i = 0; i < 4; i++) chunk[4 + i] = type.charCodeAt(i);
  chunk.set(data, 8);
  view.setUint32(8 + data.length, crc32(chunk.subarray(4, 8 + data.length)));
  return chunk;
}
