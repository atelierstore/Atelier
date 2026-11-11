// ZIP files, read a part at a time and written whole. The Worker reads IPAs
// on other sites with this (src/ipa.js), and the certificate page opens the
// IPA it signs and the ZIP a certificate can come in, and packs the signed
// IPA, so it's here with the site's files, where both can load it. Deflate
// is the platform's own (DecompressionStream and CompressionStream, in
// Safari since 16.4). Nothing here touches a page.

export class ZipError extends Error {}

const u16 = (b, i) => b[i] | (b[i + 1] << 8);
const u32 = (b, i) => (b[i] | (b[i + 1] << 8) | (b[i + 2] << 16) | (b[i + 3] << 24)) >>> 0;
const SIGNATURES = { local: 0x04034b50, central: 0x02014b50, end: 0x06054b50 };
// The end of central directory record, and the longest comment it can have.
const TAIL = 22 + 0xffff;

/** A file in memory, as centralDirectory and extract read files:
 *  `read(start, end)` gives bytes `start` to `end`, both included. */
export function bytesFile(bytes) {
  return {
    size: bytes.length,
    read: async (start, end) => bytes.subarray(start, Math.min(end, bytes.length - 1) + 1),
  };
}

/** The entries of the ZIP's central directory: {path, flags, method,
 *  compressedSize, size, offset, crc32, modified, attributes}, `modified`
 *  being its DOS time and date (time in the low 16 bits) and `attributes`
 *  its external attributes, which keep a Unix file's mode in the high 16
 *  bits. `file` is read a part at a time: `file.read(start, end)` gives its
 *  bytes `start` to `end`, both included, and `file.size` is its size once
 *  it has read something. `name` is what errors call it, and a list of
 *  files over `maxLength` bytes is refused. Throws a ZipError. */
export async function centralDirectory(file, { name = "the ZIP", maxLength = 4 << 20 } = {}) {
  const head = await file.read(0, 3);
  if (head.length < 4 || u32(head, 0) !== SIGNATURES.local) throw new ZipError(`${name} isn't a ZIP file`);
  const tailStart = Math.max(0, file.size - TAIL);
  const tail = await file.read(tailStart, file.size - 1);

  let end = -1;
  for (let i = tail.length - 22; i >= 0; i--) {
    if (u32(tail, i) === SIGNATURES.end) {
      end = i;
      break;
    }
  }
  if (end < 0) throw new ZipError(`${name} isn't a ZIP file`);
  const count = u16(tail, end + 10);
  const length = u32(tail, end + 12);
  const offset = u32(tail, end + 16);
  if (count === 0xffff || length === 0xffffffff || offset === 0xffffffff) throw new ZipError(`${name} is a ZIP64 file`);
  if (length > maxLength) throw new ZipError(`${name}'s list of files is too long`);
  if (offset + length > tailStart + end) throw new ZipError(`${name} is damaged`);

  const directory = offset >= tailStart
    ? tail.subarray(offset - tailStart, offset - tailStart + length)
    : await file.read(offset, offset + length - 1);

  const names = new TextDecoder();
  const entries = [];
  for (let p = 0; p + 46 <= directory.length;) {
    if (u32(directory, p) !== SIGNATURES.central) throw new ZipError(`${name} is damaged`);
    const nameLength = u16(directory, p + 28);
    entries.push({
      path: names.decode(directory.subarray(p + 46, p + 46 + nameLength)),
      flags: u16(directory, p + 8),
      method: u16(directory, p + 10),
      modified: u32(directory, p + 12),
      crc32: u32(directory, p + 16),
      compressedSize: u32(directory, p + 20),
      size: u32(directory, p + 24),
      attributes: u32(directory, p + 38),
      offset: u32(directory, p + 42),
    });
    p += 46 + nameLength + u16(directory, p + 30) + u16(directory, p + 32);
  }
  return entries;
}

/** An entry's contents, refusing an entry over `limit` bytes. Throws a
 *  ZipError, `name` being what it calls the ZIP. */
export async function extract(file, entry, limit = Infinity, name = "the ZIP") {
  if (entry.offset + 30 > file.size) throw new ZipError(`${name} is damaged`);
  if (entry.flags & 1) throw new ZipError(`${entry.path} is encrypted`);
  if (entry.method !== 0 && entry.method !== 8) throw new ZipError(`${entry.path} is compressed in a way this doesn't read`);
  if (entry.size > limit || entry.compressedSize > limit) throw new ZipError(`${entry.path} is too large`);
  // The local header, with the name and an extra field, comes first. Its
  // extra field can be longer than the central directory's, so this reads a
  // little more, and the rest when that wasn't enough.
  const guess = 30 + new TextEncoder().encode(entry.path).length + 256 + entry.compressedSize;
  let bytes = await file.read(entry.offset, Math.min(file.size, entry.offset + guess) - 1);
  if (bytes.length < 30 || u32(bytes, 0) !== SIGNATURES.local) throw new ZipError(`${name} is damaged`);
  const start = 30 + u16(bytes, 26) + u16(bytes, 28);
  if (start + entry.compressedSize > bytes.length) {
    if (entry.offset + start + entry.compressedSize > file.size) throw new ZipError(`${name} is damaged`);
    const rest = await file.read(entry.offset + bytes.length, entry.offset + start + entry.compressedSize - 1);
    bytes = concat([bytes, rest]);
  }
  const data = bytes.subarray(start, start + entry.compressedSize);
  if (entry.method === 8) return inflate(data, "deflate-raw", entry.size, name);
  if (data.length !== entry.size) throw new ZipError(`${name} is damaged`);
  return data;
}

/** `data` decompressed, which has to come to `length` bytes. Throws a
 *  ZipError, `name` being what it calls what `data` is from. */
export async function inflate(data, format, length, name = "the ZIP") {
  const reader = new Blob([data]).stream().pipeThrough(new DecompressionStream(format)).getReader();
  const out = new Uint8Array(length);
  let received = 0;
  try {
    for (;;) {
      const { done, value } = await reader.read();
      if (done) break;
      if (received + value.length > length) throw new ZipError(`${name} is damaged`);
      out.set(value, received);
      received += value.length;
    }
  } catch (error) {
    reader.cancel().catch(() => {});
    // Bytes after the end of the compressed data, such as the checksum some
    // iPhone PNGs keep, do no harm once everything else is there.
    if (error instanceof ZipError || received !== length) {
      throw error instanceof ZipError ? error : new ZipError(`${name} is damaged`);
    }
  }
  if (received !== length) throw new ZipError(`${name} is damaged`);
  return out;
}

// MARK: Writing

/** A ZIP of `files`, in their order: {path, data, mode, modified}, `data`
 *  a Uint8Array (none for a folder, whose path ends in "/"), `mode` its Unix
 *  mode with the file type (0o100644 for a file, 0o40755 for a folder), and
 *  `modified` its DOS time and date, as centralDirectory reads them (now,
 *  when it's left out). Files are deflated when that makes them smaller. */
export async function writeZip(files) {
  const now = dosTime(new Date());
  const parts = [];
  const centrals = [];
  let offset = 0;
  for (const file of files) {
    const name = new TextEncoder().encode(file.path);
    const data = file.data ?? new Uint8Array(0);
    const crc = crc32(data);
    let stored = data;
    let method = 0;
    if (data.length) {
      const deflated = await deflateRaw(data);
      if (deflated.length < data.length) {
        stored = deflated;
        method = 8;
      }
    }
    if (offset > 0xffffffff - 30 - name.length - stored.length) throw new ZipError("the IPA is too large for a ZIP file");
    // Names that aren't ASCII say they're UTF-8 (bit 11).
    const flags = name.some((byte) => byte > 0x7f) ? 0x0800 : 0;
    const modified = file.modified ?? now;

    const local = new Uint8Array(30 + name.length);
    const l = new DataView(local.buffer);
    l.setUint32(0, SIGNATURES.local, true);
    l.setUint16(4, 20, true);
    l.setUint16(6, flags, true);
    l.setUint16(8, method, true);
    l.setUint32(10, modified, true);
    l.setUint32(14, crc, true);
    l.setUint32(18, stored.length, true);
    l.setUint32(22, data.length, true);
    l.setUint16(26, name.length, true);
    local.set(name, 30);

    const central = new Uint8Array(46 + name.length);
    const c = new DataView(central.buffer);
    c.setUint32(0, SIGNATURES.central, true);
    // Made by Unix (3), so the mode in the external attributes counts.
    c.setUint16(4, (3 << 8) | 20, true);
    c.setUint16(6, 20, true);
    c.setUint16(8, flags, true);
    c.setUint16(10, method, true);
    c.setUint32(12, modified, true);
    c.setUint32(16, crc, true);
    c.setUint32(20, stored.length, true);
    c.setUint32(24, data.length, true);
    c.setUint16(28, name.length, true);
    // For a folder, MS-DOS's directory bit too.
    c.setUint32(38, (((file.mode ?? 0o100644) << 16) | (file.path.endsWith("/") ? 0x10 : 0)) >>> 0, true);
    c.setUint32(42, offset, true);
    central.set(name, 46);

    parts.push(local, stored);
    centrals.push(central);
    offset += local.length + stored.length;
  }
  const directoryLength = centrals.reduce((sum, central) => sum + central.length, 0);
  if (files.length >= 0xffff || offset + directoryLength > 0xffffffff) throw new ZipError("the IPA is too large for a ZIP file");
  const end = new Uint8Array(22);
  const e = new DataView(end.buffer);
  e.setUint32(0, SIGNATURES.end, true);
  e.setUint16(8, files.length, true);
  e.setUint16(10, files.length, true);
  e.setUint32(12, directoryLength, true);
  e.setUint32(16, offset, true);
  return concat([...parts, ...centrals, end]);
}

/** A date as a ZIP's DOS time and date, in local time as DOS has it. */
export function dosTime(date) {
  const year = Math.min(Math.max(date.getFullYear(), 1980), 2107);
  const day = ((year - 1980) << 9) | ((date.getMonth() + 1) << 5) | date.getDate();
  const time = (date.getHours() << 11) | (date.getMinutes() << 5) | (date.getSeconds() >> 1);
  return ((day << 16) | time) >>> 0;
}

async function deflateRaw(data) {
  const compressed = new Blob([data]).stream().pipeThrough(new CompressionStream("deflate-raw"));
  return new Uint8Array(await new Response(compressed).arrayBuffer());
}

export function concat(chunks) {
  const out = new Uint8Array(chunks.reduce((sum, chunk) => sum + chunk.length, 0));
  let p = 0;
  for (const chunk of chunks) {
    out.set(chunk, p);
    p += chunk.length;
  }
  return out;
}

const CRC_TABLE = (() => {
  const table = new Uint32Array(256);
  for (let n = 0; n < 256; n++) {
    let c = n;
    for (let k = 0; k < 8; k++) c = c & 1 ? 0xedb88320 ^ (c >>> 1) : c >>> 1;
    table[n] = c >>> 0;
  }
  return table;
})();

/** The CRC-32 that ZIP files and PNGs use. */
export function crc32(bytes) {
  let c = 0xffffffff;
  for (let i = 0; i < bytes.length; i++) c = CRC_TABLE[(c ^ bytes[i]) & 0xff] ^ (c >>> 8);
  return (c ^ 0xffffffff) >>> 0;
}
