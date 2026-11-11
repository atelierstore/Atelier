import { test } from "node:test";
import assert from "node:assert/strict";

import { appInfo, iconFile, IPAError, parsePlist, plainPNG, ReachError, readApp } from "../src/ipa.js";

// MARK: Helpers: ZIPs, PNGs and a server that sends parts of a file

const encode = (text) => new TextEncoder().encode(text);

function concat(chunks) {
  const out = new Uint8Array(chunks.reduce((sum, chunk) => sum + chunk.length, 0));
  let p = 0;
  for (const chunk of chunks) {
    out.set(chunk, p);
    p += chunk.length;
  }
  return out;
}

async function compress(data, format) {
  const stream = new Blob([data]).stream().pipeThrough(new CompressionStream(format));
  return new Uint8Array(await new Response(stream).arrayBuffer());
}

async function decompress(data, format) {
  const stream = new Blob([data]).stream().pipeThrough(new DecompressionStream(format));
  return new Uint8Array(await new Response(stream).arrayBuffer());
}

// Written out here rather than shared with ipa.js, so the PNGs it writes are
// checked against something else.
function crc32(bytes) {
  let c = 0xffffffff;
  for (const byte of bytes) {
    c ^= byte;
    for (let k = 0; k < 8; k++) c = c & 1 ? 0xedb88320 ^ (c >>> 1) : c >>> 1;
  }
  return (c ^ 0xffffffff) >>> 0;
}

/** A ZIP of `files`: {path, data, deflate, localExtra}. */
async function zip(files) {
  const locals = [];
  const centrals = [];
  let offset = 0;
  for (const file of files) {
    const name = encode(file.path);
    const data = typeof file.data === "string" ? encode(file.data) : file.data;
    const body = file.deflate ? await compress(data, "deflate-raw") : data;
    const extra = file.localExtra ?? new Uint8Array(0);
    const local = new Uint8Array(30 + name.length + extra.length + body.length);
    const l = new DataView(local.buffer);
    l.setUint32(0, 0x04034b50, true);
    l.setUint16(4, 20, true);
    l.setUint16(8, file.deflate ? 8 : 0, true);
    l.setUint32(14, crc32(data), true);
    l.setUint32(18, body.length, true);
    l.setUint32(22, data.length, true);
    l.setUint16(26, name.length, true);
    l.setUint16(28, extra.length, true);
    local.set(name, 30);
    local.set(extra, 30 + name.length);
    local.set(body, 30 + name.length + extra.length);

    const central = new Uint8Array(46 + name.length);
    const c = new DataView(central.buffer);
    c.setUint32(0, 0x02014b50, true);
    c.setUint16(4, 20, true);
    c.setUint16(6, 20, true);
    c.setUint16(10, file.deflate ? 8 : 0, true);
    c.setUint32(16, crc32(data), true);
    c.setUint32(20, body.length, true);
    c.setUint32(24, data.length, true);
    c.setUint16(28, name.length, true);
    c.setUint32(42, offset, true);
    central.set(name, 46);

    locals.push(local);
    centrals.push(central);
    offset += local.length;
  }
  const directory = concat(centrals);
  const end = new Uint8Array(22);
  const e = new DataView(end.buffer);
  e.setUint32(0, 0x06054b50, true);
  e.setUint16(8, files.length, true);
  e.setUint16(10, files.length, true);
  e.setUint32(12, directory.length, true);
  e.setUint32(16, offset, true);
  return concat([...locals, directory, end]);
}

const PNG_SIGNATURE = Uint8Array.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]);

function chunk(type, data) {
  const out = new Uint8Array(12 + data.length);
  const view = new DataView(out.buffer);
  view.setUint32(0, data.length);
  out.set(encode(type), 4);
  out.set(data, 8);
  view.setUint32(8 + data.length, crc32(out.subarray(4, 8 + data.length)));
  return out;
}

function header(width, height, colorType) {
  const data = new Uint8Array(13);
  const view = new DataView(data.buffer);
  view.setUint32(0, width);
  view.setUint32(4, height);
  data[8] = 8;
  data[9] = colorType;
  return data;
}

/** A row filtered with PNG filter `type`, the row above being `previous`. */
function filterRow(type, row, previous, bytesPerPixel) {
  const out = new Uint8Array(row.length);
  for (let x = 0; x < row.length; x++) {
    const left = x >= bytesPerPixel ? row[x - bytesPerPixel] : 0;
    const up = previous[x];
    const upLeft = x >= bytesPerPixel ? previous[x - bytesPerPixel] : 0;
    let predictor = 0;
    if (type === 1) predictor = left;
    if (type === 2) predictor = up;
    if (type === 3) predictor = (left + up) >> 1;
    if (type === 4) {
      const estimate = left + up - upLeft;
      const [a, b, c] = [Math.abs(estimate - left), Math.abs(estimate - up), Math.abs(estimate - upLeft)];
      predictor = a <= b && a <= c ? left : b <= c ? up : upLeft;
    }
    out[x] = (row[x] - predictor) & 0xff;
  }
  return out;
}

/** An iPhone PNG (CgBI) of `pixels`, [r, g, b, a] rows, as Xcode writes
 *  them: BGRA with premultiplied alpha, raw deflate, every filter in turn.
 *  `trailer` goes after the compressed data, and `cut` leaves half of it
 *  out. */
async function iPhonePNG(pixels, { alpha = true, trailer = new Uint8Array(0), cut = false } = {}) {
  const height = pixels.length;
  const width = pixels[0].length;
  const channels = alpha ? 4 : 3;
  const rows = [];
  let previous = new Uint8Array(width * channels);
  pixels.forEach((line, y) => {
    const row = new Uint8Array(width * channels);
    line.forEach(([r, g, b, a = 255], x) => {
      const at = x * channels;
      row[at] = Math.round((b * a) / 255);
      row[at + 1] = Math.round((g * a) / 255);
      row[at + 2] = Math.round((r * a) / 255);
      if (alpha) row[at + 3] = a;
    });
    const filter = y % 5;
    rows.push(Uint8Array.of(filter), filterRow(filter, row, previous, channels));
    previous = row;
  });
  let data = concat([await compress(concat(rows), "deflate-raw"), trailer]);
  if (cut) data = data.subarray(0, data.length >> 1);
  return concat([
    PNG_SIGNATURE,
    chunk("CgBI", Uint8Array.of(0x50, 0x00, 0x20, 0x06)),
    chunk("IHDR", header(width, height, alpha ? 6 : 2)),
    chunk("IDAT", data.subarray(0, 7)),
    chunk("IDAT", data.subarray(7)),
    chunk("IEND", new Uint8Array(0)),
  ]);
}

/** A plain PNG's chunks, checking each one's CRC, and its pixels as
 *  [r, g, b, a] rows, for unfiltered RGBA or RGB. */
async function readPNG(png) {
  assert.deepEqual(png.subarray(0, 8), PNG_SIGNATURE);
  const chunks = [];
  const view = new DataView(png.buffer, png.byteOffset, png.byteLength);
  for (let p = 8; p < png.length;) {
    const length = view.getUint32(p);
    const type = new TextDecoder().decode(png.subarray(p + 4, p + 8));
    assert.equal(view.getUint32(p + 8 + length), crc32(png.subarray(p + 4, p + 8 + length)), `${type}'s CRC`);
    chunks.push({ type, data: png.subarray(p + 8, p + 8 + length) });
    p += 12 + length;
  }
  const ihdr = new DataView(chunks[0].data.buffer, chunks[0].data.byteOffset);
  const width = ihdr.getUint32(0);
  const height = ihdr.getUint32(4);
  const channels = chunks[0].data[9] === 6 ? 4 : 3;
  const raw = await decompress(concat(chunks.filter((c) => c.type === "IDAT").map((c) => c.data)), "deflate");
  const pixels = [];
  for (let y = 0; y < height; y++) {
    const at = y * (width * channels + 1);
    assert.equal(raw[at], 0, "rows aren't filtered");
    const line = [];
    for (let x = 0; x < width; x++) {
      const p = at + 1 + x * channels;
      line.push(channels === 4 ? [...raw.subarray(p, p + 4)] : [...raw.subarray(p, p + 3), 255]);
    }
    pixels.push(line);
  }
  return { types: chunks.map((c) => c.type), width, height, pixels };
}

/** A fetch that answers like a file server, with parts of `bytes`. `mode`
 *  "whole" ignores ranges, "missing" answers 404, and `redirect` is where
 *  the answers say they came from, as after a redirect. */
function server(bytes, { mode = "parts", redirect } = {}) {
  const requests = [];
  // Like Workers' own fetch, which can't be called as another object's
  // method.
  const fetch = async function (url, init) {
    if (this !== undefined && this !== globalThis) throw new TypeError("Illegal invocation");
    requests.push({ url, range: init.headers.Range });
    if (mode === "missing") return new Response("Not Found", { status: 404 });
    if (mode === "whole") return new Response(bytes, { status: 200 });
    const [, from, to] = /^bytes=(\d+)-(\d+)$/.exec(init.headers.Range);
    const start = Number(from);
    const end = Math.min(Number(to), bytes.length - 1);
    const response = new Response(bytes.slice(start, end + 1), {
      status: 206,
      headers: { "Content-Range": `bytes ${start}-${end}/${bytes.length}` },
    });
    if (redirect) Object.defineProperty(response, "url", { value: redirect });
    return response;
  };
  return { fetch, requests };
}

// Python's plistlib.dumps(info, fmt=plistlib.FMT_BINARY) of an Info.plist
// with a non-ASCII display name (so UTF-16), CFBundleIcons for iPhone and
// iPad, and one of each other kind of value: true, false, an array, a 40-bit
// and a negative integer, a real, a date and data.
const BINARY_INFO_PLIST = Uint8Array.from(atob(`
YnBsaXN0MDDfEBEBAgMEBQYHCAkKCwwNDg8QERITFBUWHiIjJCUmJygpKi0uU0JpZ1RCbG9iVUJ1aWx0XxATQ0ZCdW5kbGVEaXNw
bGF5TmFtZV1DRkJ1bmRsZUljb25zXxASQ0ZCdW5kbGVJY29uc35pcGFkXxASQ0ZCdW5kbGVJZGVudGlmaWVyXENGQnVuZGxlTmFt
ZV8QGkNGQnVuZGxlU2hvcnRWZXJzaW9uU3RyaW5nXxAPQ0ZCdW5kbGVWZXJzaW9uXxASTFNSZXF1aXJlc0lQaG9uZU9TXxAQTWlu
aW11bU9TVmVyc2lvblhOZWdhdGl2ZVVSYXRpb15VSURldmljZUZhbWlseV8QFFVJRmlsZVNoYXJpbmdFbmFibGVkXxAcVUlSZXF1
aXJlZERldmljZUNhcGFiaWxpdGllcxMAAAEAAAAAAEMAAf4zQceDtpKAAABtAFMAawBlAHQAYwBoAGIAbwBvAGsAICcP/g/RFxhf
EBNDRkJ1bmRsZVByaW1hcnlJY29u0hkaGx1fEBFDRkJ1bmRsZUljb25GaWxlc18QEENGQnVuZGxlSWNvbk5hbWWhHFxBcHBJY29u
NjB4NjBXQXBwSWNvbtEXH9IZGiAdohwhXEFwcEljb243Nng3Nl8QEmNvbS5leGFtcGxlLlNrZXRjaFZTa2V0Y2hTMi4xUjQ1CVQx
Ny4wE//////////7Iz/4AAAAAAAAoissEAEQAgihL1Vhcm02NAAIAC0AMQA2ADwAUgBgAHUAigCXALQAxgDbAO4A9wD9AQwBIwFC
AUsBTwFYAXMBdgGMAZEBpQG4AboBxwHPAdIB1wHaAecB/AIDAgcCCgILAhACGQIiAiUCJwIpAioCLAAAAAAAAAIBAAAAAAAAADAA
AAAAAAAAAAAAAAAAAAIy`.replace(/\s+/g, "")), (c) => c.charCodeAt(0));

const XML_INFO_PLIST = `<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<!-- A comment, which isn't a value. -->
	<key>CFBundleIdentifier</key>
	<string>org.example.notes</string>
	<key>CFBundleName</key>
	<string>Notes &amp; Lists</string>
	<key>CFBundleShortVersionString</key>
	<string>3.0</string>
	<key>CFBundleVersion</key>
	<string>3.0</string>
	<key>CFBundleIcons</key>
	<dict>
		<key>CFBundlePrimaryIcon</key>
		<dict>
			<key>CFBundleIconFiles</key>
			<array>
				<string>Icon-60</string>
			</array>
		</dict>
	</dict>
	<key>UIDeviceFamily</key>
	<array>
		<integer>1</integer>
		<integer>2</integer>
	</array>
	<key>LSRequiresIPhoneOS</key>
	<true/>
	<key>Empty</key>
	<string/>
	<key>Blob</key>
	<data>
	AAH+
	</data>
</dict>
</plist>
`;

// Each kind of pixel: opaque, half see-through, nearly see-through and see-
// through, in every colour channel.
const PIXELS = [
  [[255, 0, 0, 255], [0, 255, 0, 255], [0, 0, 255, 255], [10, 20, 30, 255]],
  [[200, 100, 50, 128], [255, 255, 255, 128], [40, 80, 120, 200], [90, 60, 30, 64]],
  [[255, 128, 0, 3], [0, 0, 0, 0], [12, 34, 56, 255], [255, 255, 255, 255]],
];

// MARK: Property lists

test("reads a binary Info.plist", () => {
  const plist = parsePlist(BINARY_INFO_PLIST);
  assert.equal(plist.CFBundleIdentifier, "com.example.Sketch");
  assert.equal(plist.CFBundleDisplayName, "Sketchbook ✏️");
  assert.deepEqual(plist.CFBundleIcons.CFBundlePrimaryIcon.CFBundleIconFiles, ["AppIcon60x60"]);
  assert.deepEqual(plist["CFBundleIcons~ipad"].CFBundlePrimaryIcon.CFBundleIconFiles, ["AppIcon60x60", "AppIcon76x76"]);
  assert.equal(plist.LSRequiresIPhoneOS, true);
  assert.equal(plist.UIFileSharingEnabled, false);
  assert.deepEqual(plist.UIDeviceFamily, [1, 2]);
  assert.equal(plist.Big, 2 ** 40);
  assert.equal(plist.Negative, -5);
  assert.equal(plist.Ratio, 1.5);
  assert.equal(plist.Built.toISOString(), "2026-01-02T03:04:05.000Z");
  assert.deepEqual(plist.Blob, Uint8Array.of(0, 1, 0xfe));
});

test("reads an XML Info.plist, dictionaries in dictionaries too", () => {
  const plist = parsePlist(encode(XML_INFO_PLIST));
  assert.equal(plist.CFBundleIdentifier, "org.example.notes");
  assert.equal(plist.CFBundleName, "Notes & Lists");
  assert.deepEqual(plist.CFBundleIcons.CFBundlePrimaryIcon.CFBundleIconFiles, ["Icon-60"]);
  assert.deepEqual(plist.UIDeviceFamily, [1, 2]);
  assert.equal(plist.LSRequiresIPhoneOS, true);
  assert.equal(plist.Empty, "");
  assert.deepEqual(plist.Blob, Uint8Array.of(0, 1, 0xfe));
});

test("a key can't be taken for something else", () => {
  const plist = parsePlist(encode("<plist><dict><key>__proto__</key><dict><key>CFBundleIdentifier</key><string>x</string></dict></dict></plist>"));
  assert.equal(Object.getPrototypeOf(plist), null);
  assert.equal(plist.CFBundleIdentifier, undefined);
  assert.equal(plist.__proto__.CFBundleIdentifier, "x");
});

test("refuses what isn't a property list, or is damaged", () => {
  const damaged = [
    encode("{}"),
    encode("<plist><dict><string>no key</string></dict></plist>"),
    encode("<plist><dict><key>a</key><string>unclosed</dict></plist>"),
    encode("<plist><array></dict></plist>"),
    encode("<plist><dict><key>a</key><blink/></dict></plist>"),
    BINARY_INFO_PLIST.slice(0, 200),
    concat([BINARY_INFO_PLIST.slice(0, -32), new Uint8Array(32).fill(0xff)]),
  ];
  for (const bytes of damaged) assert.throws(() => parsePlist(bytes), IPAError);
});

test("refuses a binary property list that refers to itself", () => {
  // bplist00, an array at offset 8 holding itself, its offset table and the
  // trailer: 1-byte offsets and references, 1 object, the top one 0.
  const bytes = concat([encode("bplist00"), Uint8Array.of(0xa1, 0x00), Uint8Array.of(8), new Uint8Array(32)]);
  const trailer = new DataView(bytes.buffer, bytes.length - 32);
  trailer.setUint8(6, 1);
  trailer.setUint8(7, 1);
  trailer.setBigUint64(8, 1n);
  trailer.setBigUint64(16, 0n);
  trailer.setBigUint64(24, 10n);
  assert.throws(() => parsePlist(bytes), /too complex/);
});

test("names and versions as Atelier reads them", () => {
  assert.deepEqual(appInfo(parsePlist(BINARY_INFO_PLIST)), {
    name: "Sketchbook ✏️", version: "2.1", build: "45", bundleID: "com.example.Sketch",
  });
  // No display name: the bundle's name.
  assert.deepEqual(appInfo(parsePlist(encode(XML_INFO_PLIST))), {
    name: "Notes & Lists", version: "3.0", build: "3.0", bundleID: "org.example.notes",
  });
  // Only CFBundleVersion: it's the version, not a build.
  assert.deepEqual(appInfo({ CFBundleIdentifier: "a.b", CFBundleVersion: "12" }), {
    name: "a.b", version: "12", build: null, bundleID: "a.b",
  });
  assert.deepEqual(appInfo({ CFBundleIdentifier: "a.b", CFBundleDisplayName: "  ", CFBundleName: "B" }), {
    name: "B", version: "1.0", build: null, bundleID: "a.b",
  });
  assert.throws(() => appInfo({ CFBundleName: "No ID" }), IPAError);
});

// MARK: Icons

test("picks the icon as Atelier does", () => {
  const folder = "Payload/Sketch.app/";
  const entries = (...files) => files.map(([path, size]) => ({ path: folder + path, size }));
  const plist = parsePlist(BINARY_INFO_PLIST);
  const files = entries(
    ["AppIcon60x60@2x.png", 9000],
    ["AppIcon60x60@3x.png", 15000],
    ["AppIcon76x76@2x~ipad.png", 12000],
    ["Background.png", 90000],
    ["Frameworks/AppIcon60x60@3x.png", 99000],
  );
  assert.equal(iconFile(plist, folder, files).path, folder + "AppIcon60x60@3x.png");
  // Only those up to a size.
  assert.equal(iconFile(plist, folder, files, 14000).path, folder + "AppIcon76x76@2x~ipad.png");
  // Info.plist names none: any AppIcon*.png, the largest.
  assert.equal(iconFile({}, folder, entries(["AppIcon20x20.png", 10], ["AppIcon40x40.PNG", 20], ["Logo.png", 30])).path, folder + "AppIcon40x40.PNG");
  // The old top-level CFBundleIconFiles.
  assert.equal(iconFile({ CFBundleIconFiles: ["Icon"] }, folder, entries(["Icon.png", 1], ["Icon@2x.png", 2], ["AppIcon.png", 3])).path, folder + "Icon@2x.png");
  assert.equal(iconFile(plist, folder, entries(["Background.png", 5])), null);
});

test("turns an iPhone PNG into a plain one", async () => {
  const png = await plainPNG(await iPhonePNG(PIXELS));
  const { types, width, height, pixels } = await readPNG(png);
  assert.deepEqual(types, ["IHDR", "IDAT", "IEND"]);
  assert.equal(width, 4);
  assert.equal(height, 3);
  PIXELS.forEach((line, y) => line.forEach(([r, g, b, a], x) => {
    const [r2, g2, b2, a2] = pixels[y][x];
    assert.equal(a2, a, `alpha at ${x},${y}`);
    // Premultiplying loses some precision, the more the more see-through.
    const tolerance = a === 0 ? 255 : a === 255 ? 0 : Math.ceil(255 / a);
    for (const [got, want] of [[r2, r], [g2, g], [b2, b]]) {
      assert.ok(Math.abs(got - want) <= tolerance, `${got} for ${want} at ${x},${y}`);
    }
  }));
});

test("turns an iPhone PNG without alpha, or with a checksum after its data, into a plain one", async () => {
  const opaque = PIXELS.map((line) => line.map(([r, g, b]) => [r, g, b, 255]));
  let { pixels } = await readPNG(await plainPNG(await iPhonePNG(opaque, { alpha: false })));
  assert.deepEqual(pixels, opaque);
  ({ pixels } = await readPNG(await plainPNG(await iPhonePNG(opaque, { trailer: Uint8Array.of(1, 2, 3, 4) }))));
  assert.deepEqual(pixels, opaque);
});

test("leaves a plain PNG as it is, and refuses what isn't one", async () => {
  const plain = concat([PNG_SIGNATURE, chunk("IHDR", header(1, 1, 6)), chunk("IEND", new Uint8Array(0))]);
  assert.equal(await plainPNG(plain), plain);
  await assert.rejects(plainPNG(encode("GIF89a")), IPAError);
  const big = concat([PNG_SIGNATURE, chunk("CgBI", new Uint8Array(4)), chunk("IHDR", header(4096, 4096, 6)), chunk("IEND", new Uint8Array(0))]);
  await assert.rejects(plainPNG(big), /too large/);
  await assert.rejects(plainPNG(await iPhonePNG(PIXELS, { cut: true })), IPAError);
});

// MARK: IPAs

async function sketchIPA(extra = []) {
  return zip([
    { path: "Payload/", data: "" },
    { path: "Payload/Sketch.app/", data: "" },
    { path: "Payload/Sketch.app/Info.plist", data: BINARY_INFO_PLIST, deflate: true },
    { path: "Payload/Sketch.app/PlugIns/Share.appex/Info.plist", data: encode("<plist><dict><key>CFBundleIdentifier</key><string>share</string></dict></plist>") },
    { path: "Payload/Sketch.app/AppIcon60x60@2x.png", data: await iPhonePNG([[[1, 2, 3, 255]]]) },
    { path: "Payload/Sketch.app/AppIcon60x60@3x.png", data: await iPhonePNG(PIXELS), deflate: true, localExtra: new Uint8Array(600) },
    { path: "Payload/Sketch.app/Sketch", data: new Uint8Array(5000).fill(7), deflate: true },
    ...extra,
  ]);
}

test("reads an app from an IPA in a few parts", async () => {
  const ipa = await sketchIPA();
  const { fetch, requests } = server(ipa, { redirect: "https://files.example/signed/Sketch.ipa?token=1" });
  const app = await readApp("https://example.com/Sketch.ipa", { fetch });
  assert.equal(app.name, "Sketchbook ✏️");
  assert.equal(app.version, "2.1");
  assert.equal(app.build, "45");
  assert.equal(app.bundleID, "com.example.Sketch");
  assert.equal(app.size, ipa.length);
  assert.deepEqual((await readPNG(app.icon)).types, ["IHDR", "IDAT", "IEND"]);
  // The start, the end, Info.plist, and the icon in two goes, its local
  // extra field being longer than was guessed.
  assert.equal(requests.length, 5);
  assert.equal(requests[0].url, "https://example.com/Sketch.ipa");
  assert.equal(requests[0].range, "bytes=0-3");
  // After a redirect, straight from where it led.
  assert.ok(requests.slice(1).every((request) => request.url === "https://files.example/signed/Sketch.ipa?token=1"));
});

test("reads a central directory that isn't in the IPA's last 64 KB", async () => {
  const many = Array.from({ length: 1500 }, (_, i) => ({ path: `Payload/Sketch.app/Assets/picture-${String(i).padStart(4, "0")}.dat`, data: "x" }));
  const ipa = await sketchIPA(many);
  const { fetch, requests } = server(ipa);
  const app = await readApp("https://example.com/Sketch.ipa", { fetch });
  assert.equal(app.bundleID, "com.example.Sketch");
  assert.ok(app.icon);
  assert.equal(requests.length, 6);
});

test("an app without an icon it can read still has its name", async () => {
  const ipa = await zip([
    { path: "Payload/Notes.app/Info.plist", data: XML_INFO_PLIST },
    { path: "Payload/Notes.app/Icon-60@2x.png", data: "not a PNG" },
  ]);
  const app = await readApp("https://example.com/Notes.ipa", { fetch: server(ipa).fetch });
  assert.equal(app.name, "Notes & Lists");
  assert.equal(app.icon, null);
});

test("refuses IPAs it can't read", async () => {
  const cases = [
    ["a server that doesn't send parts", server(await sketchIPA(), { mode: "whole" }).fetch, /doesn't send parts/],
    ["a missing file", server(new Uint8Array(0), { mode: "missing" }).fetch, /HTTP 404/],
    ["not a ZIP", server(encode("<html>Sign in</html>")).fetch, /isn't a ZIP/],
    ["no app", server(await zip([{ path: "Payload/readme.txt", data: "hi" }])).fetch, /no app/],
    ["only a plug-in's Info.plist", server(await zip([{ path: "Payload/A.app/PlugIns/B.appex/Info.plist", data: XML_INFO_PLIST }])).fetch, /no app/],
    ["Info.plist without a bundle ID", server(await zip([{ path: "Payload/A.app/Info.plist", data: "<plist><dict/></plist>" }])).fetch, /bundle ID/],
    ["Info.plist that's an array", server(await zip([{ path: "Payload/A.app/Info.plist", data: "<plist><array/></plist>" }])).fetch, /isn't a dictionary/],
    ["an Info.plist too large", server(await zip([{ path: "Payload/A.app/Info.plist", data: new Uint8Array(2 << 20), deflate: true }])).fetch, /too large/],
  ];
  for (const [name, fetch, message] of cases) {
    await assert.rejects(readApp("https://example.com/App.ipa", { fetch }), (error) => error instanceof IPAError && message.test(error.message), name);
  }
});

test("a server that can't be reached, or not in time, isn't one that sent something wrong", async () => {
  const offline = async () => {
    throw new TypeError("Network connection lost.");
  };
  await assert.rejects(readApp("https://example.com/App.ipa", { fetch: offline }), (error) => error instanceof ReachError && error.message === "Network connection lost.");
  // One that never answers. (Node's timeouts don't keep it running, so this
  // one does until then.)
  const silent = (url, init) => new Promise((resolve, reject) => init.signal.addEventListener("abort", () => reject(init.signal.reason)));
  const running = setTimeout(() => {}, 5000);
  await assert.rejects(readApp("https://example.com/App.ipa", { fetch: silent, timeout: 50 }), (error) => error instanceof ReachError && error.cause?.name === "TimeoutError");
  clearTimeout(running);
});

test("refuses a server that sends something else than the part it asked for", async () => {
  const ipa = await sketchIPA();
  let answers = 0;
  // The start, then a part from somewhere else.
  const lying = async () => (answers++ === 0
    ? new Response(ipa.slice(0, 4), { status: 206, headers: { "Content-Range": `bytes 0-3/${ipa.length}` } })
    : new Response(ipa.slice(5, 9), { status: 206, headers: { "Content-Range": `bytes 5-8/${ipa.length}` } }));
  await assert.rejects(readApp("https://example.com/App.ipa", { fetch: lying }), /another part/);
  const tooLong = async () => new Response(new Uint8Array(10), { status: 206, headers: { "Content-Range": `bytes 0-3/${ipa.length}` } });
  await assert.rejects(readApp("https://example.com/App.ipa", { fetch: tooLong }), /more than the part/);
});
