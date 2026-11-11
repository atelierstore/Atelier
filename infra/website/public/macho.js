// Mach-O files, read as Atelier reads them before and after zsign signs an
// app (SigningKit's MachO.swift): whether a file is one, whether the App
// Store still encrypts it, and whether every slice got a real signature.
// `read(offset, count)` gives up to `count` bytes from `offset`, fewer at
// the end of the file, so a large binary is read only where it matters.
// Nothing here touches a page.

const MAGIC_32 = 0xfeedface;
const MAGIC_64 = 0xfeedfacf;
const FAT = 0xcafebabe;
const FAT_64 = 0xcafebabf;
const ENCRYPTION_INFO = 0x21;
const ENCRYPTION_INFO_64 = 0x2c;
const CODE_SIGNATURE = 0x1d;
const SUPER_BLOB = 0xfade0cc0;
const BLOB_WRAPPER = 0xfade0b01;
const CMS_SLOT = 0x10000;

const be32 = (b, i) => ((b[i] << 24) | (b[i + 1] << 16) | (b[i + 2] << 8) | b[i + 3]) >>> 0;
const le32 = (b, i) => (b[i] | (b[i + 1] << 8) | (b[i + 2] << 16) | (b[i + 3] << 24)) >>> 0;

/** A `read` for bytes in memory. */
export function bytesReader(bytes) {
  return (offset, count) => bytes.subarray(offset, offset + count);
}

/** {machO: false}, or {machO: true, encrypted} when a slice is still
 *  encrypted by the App Store. */
export function inspect(read) {
  const slices = readSlices(read);
  return slices ? { machO: true, encrypted: slices.some((slice) => slice.encrypted) } : { machO: false };
}

/** Whether every slice carries a code signature with a CMS blob, which is
 *  what makes it signed by a certificate rather than ad hoc. Only the
 *  signature's index and the CMS blob's header are read. */
export function hasCMSSignature(read) {
  const slices = readSlices(read);
  if (!slices?.length) return false;
  for (const slice of slices) {
    if (!slice.codeSignature) return false;
    const base = slice.offset + slice.codeSignature.offset;
    const header = read(base, 12);
    if (header.length !== 12 || be32(header, 0) !== SUPER_BLOB) return false;
    const count = be32(header, 8);
    if (count >= 64) return false;
    const index = read(base + 12, count * 8);
    if (index.length !== count * 8) return false;
    let found = false;
    for (let entry = 0; entry < index.length; entry += 8) {
      if (be32(index, entry) !== CMS_SLOT) continue;
      const offset = be32(index, entry + 4);
      if (offset + 8 > slice.codeSignature.size) return false;
      const wrapper = read(base + offset, 8);
      if (wrapper.length !== 8) return false;
      found = be32(wrapper, 0) === BLOB_WRAPPER && be32(wrapper, 4) > 8;
    }
    if (!found) return false;
  }
  return true;
}

/** The file's thin slices, or null when it isn't Mach-O. */
function readSlices(read) {
  const head = read(0, 8);
  if (head.length !== 8) return null;
  const magic = be32(head, 0);
  if (magic !== FAT && magic !== FAT_64) {
    const slice = readSlice(read, 0);
    return slice ? [slice] : null;
  }
  const count = be32(head, 4);
  // Java class files share the fat magic; they have a large "count".
  if (count === 0 || count >= 32) return null;
  const stride = magic === FAT_64 ? 32 : 20;
  const table = read(8, count * stride);
  if (table.length !== count * stride) return null;
  const slices = [];
  for (let i = 0; i < count; i++) {
    const at = i * stride;
    const offset = magic === FAT_64 ? be32(table, at + 8) * 2 ** 32 + be32(table, at + 12) : be32(table, at + 8);
    const slice = readSlice(read, offset);
    if (!slice) return null;
    slices.push(slice);
  }
  return slices;
}

/** The thin Mach-O at `offset`, or null when it isn't one. */
function readSlice(read, offset) {
  const header = read(offset, 32);
  if (header.length < 28) return null;
  const magic = le32(header, 0);
  if (magic !== MAGIC_32 && magic !== MAGIC_64) return null;
  const commandCount = le32(header, 16);
  const commandsSize = le32(header, 20);
  if (commandsSize > 16 << 20) return null;
  const commands = read(offset + (magic === MAGIC_64 ? 32 : 28), commandsSize);
  if (commands.length !== commandsSize) return null;

  const slice = { offset, encrypted: false, codeSignature: null };
  let position = 0;
  for (let i = 0; i < commandCount; i++) {
    if (position + 8 > commands.length) return null;
    const command = le32(commands, position);
    const size = le32(commands, position + 4);
    if (size < 8 || position + size > commands.length) return null;
    if (command === ENCRYPTION_INFO || command === ENCRYPTION_INFO_64) {
      // encryption_info_command: cmd, cmdsize, cryptoff, cryptsize, cryptid
      if (size >= 20 && le32(commands, position + 16) !== 0) slice.encrypted = true;
    } else if (command === CODE_SIGNATURE && size >= 16) {
      // linkedit_data_command: cmd, cmdsize, dataoff, datasize
      slice.codeSignature = { offset: le32(commands, position + 8), size: le32(commands, position + 12) };
    }
    position += size;
  }
  return slice;
}
