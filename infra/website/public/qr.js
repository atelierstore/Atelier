// QR codes, for the certificate page (certificate.html): on a computer, it
// shows the signed Atelier's address as one, and the iPhone's camera scans
// it. Byte mode at error correction level M, versions 1 to 10 (up to 213
// bytes), as ISO/IEC 18004 sets them out. The site loads nothing from other
// sites, so it makes its own.

const MAX_VERSION = 10;
// Level M's error correction codewords in each block, and how many blocks,
// for versions 1 to 10.
const ECC_PER_BLOCK = [10, 16, 26, 18, 24, 16, 18, 22, 22, 26];
const BLOCKS = [1, 1, 1, 2, 2, 4, 4, 4, 5, 5];
// Level M's two bits in the format information.
const LEVEL_M = 0b00;

const MASKS = [
  (x, y) => (x + y) % 2 === 0,
  (x, y) => y % 2 === 0,
  (x, y) => x % 3 === 0,
  (x, y) => (x + y) % 3 === 0,
  (x, y) => (Math.floor(x / 3) + Math.floor(y / 2)) % 2 === 0,
  (x, y) => ((x * y) % 2) + ((x * y) % 3) === 0,
  (x, y) => (((x * y) % 2) + ((x * y) % 3)) % 2 === 0,
  (x, y) => (((x + y) % 2) + ((x * y) % 3)) % 2 === 0,
];

export class QRError extends Error {}

/** The QR code for `text`, in the smallest version it fits: {version, mask,
 *  size, modules}, `modules[y][x]` true for a dark module. `mask` picks the
 *  mask, 0 to 7; by default it's the one the standard's penalty rules
 *  prefer. Throws a QRError when `text` is too long. */
export function qrCode(text, { mask = null } = {}) {
  const data = new TextEncoder().encode(text);
  let version = 1;
  while (version <= MAX_VERSION && 4 + countBits(version) + data.length * 8 > dataCodewords(version) * 8) version++;
  if (version > MAX_VERSION) throw new QRError(`${data.length} bytes don't fit in a QR code this page makes.`);

  const symbol = new Matrix(version);
  symbol.place(withErrorCorrection(codewords(data, version), version));
  const masks = mask === null ? MASKS.keys() : [mask];
  let best = null;
  for (const candidate of masks) {
    const modules = symbol.masked(candidate);
    const score = mask === null ? penalty(modules) : 0;
    if (!best || score < best.score) best = { score, mask: candidate, modules };
  }
  return { version, mask: best.mask, size: symbol.size, modules: best.modules };
}

/** An SVG path that draws `code`'s dark modules, a 1 by 1 square each, in a
 *  viewBox of `0 0 size size`, rows run together where they can. */
export function qrPath({ size, modules }) {
  const parts = [];
  for (let y = 0; y < size; y++) {
    for (let x = 0; x < size; x++) {
      if (!modules[y][x]) continue;
      let run = 1;
      while (x + run < size && modules[y][x + run]) run++;
      parts.push(`M${x} ${y}h${run}v1h-${run}z`);
      x += run - 1;
    }
  }
  return parts.join("");
}

// MARK: Codewords

function countBits(version) {
  return version < 10 ? 8 : 16;
}

/** How many modules hold data and error correction, with any remainder
 *  bits: all of them but the function patterns'. */
function rawModules(version) {
  let modules = (16 * version + 128) * version + 64;
  if (version >= 2) {
    const alignments = Math.floor(version / 7) + 2;
    modules -= (25 * alignments - 10) * alignments - 55;
    if (version >= 7) modules -= 36;
  }
  return modules;
}

function dataCodewords(version) {
  return Math.floor(rawModules(version) / 8) - ECC_PER_BLOCK[version - 1] * BLOCKS[version - 1];
}

/** `data` in byte mode, ended and padded to the version's data codewords. */
function codewords(data, version) {
  const bits = [];
  const push = (value, length) => {
    for (let i = length - 1; i >= 0; i--) bits.push((value >>> i) & 1);
  };
  const capacity = dataCodewords(version) * 8;
  push(0b0100, 4);
  push(data.length, countBits(version));
  for (const byte of data) push(byte, 8);
  push(0, Math.min(4, capacity - bits.length));
  push(0, (8 - (bits.length % 8)) % 8);
  for (let pad = 0xec; bits.length < capacity; pad ^= 0xec ^ 0x11) push(pad, 8);
  const result = [];
  for (let i = 0; i < bits.length; i += 8) result.push(bits.slice(i, i + 8).reduce((byte, bit) => (byte << 1) | bit, 0));
  return result;
}

/** The data codewords in their blocks, each with its Reed-Solomon error
 *  correction, interleaved as the symbol holds them. */
function withErrorCorrection(data, version) {
  const blocks = BLOCKS[version - 1];
  const eccLength = ECC_PER_BLOCK[version - 1];
  const total = Math.floor(rawModules(version) / 8);
  // The first blocks are a codeword shorter than the rest, when the
  // codewords don't divide evenly.
  const short = blocks - (total % blocks);
  const shortData = Math.floor(total / blocks) - eccLength;
  const divisor = generator(eccLength);
  const dataBlocks = [];
  const eccBlocks = [];
  for (let block = 0, start = 0; block < blocks; block++) {
    const length = shortData + (block < short ? 0 : 1);
    const part = data.slice(start, start + length);
    start += length;
    dataBlocks.push(part);
    eccBlocks.push(remainder(part, divisor));
  }
  const result = [];
  for (let i = 0; i <= shortData; i++) {
    for (const part of dataBlocks) if (i < part.length) result.push(part[i]);
  }
  for (let i = 0; i < eccLength; i++) {
    for (const part of eccBlocks) result.push(part[i]);
  }
  return result;
}

/** x times y in GF(256), modulo x^8 + x^4 + x^3 + x^2 + 1. */
function multiply(x, y) {
  let product = 0;
  for (let i = 7; i >= 0; i--) {
    product = (product << 1) ^ ((product >>> 7) * 0x11d);
    product ^= ((y >>> i) & 1) * x;
  }
  return product;
}

/** The generator polynomial of `degree`, (x - 1)(x - 2)(x - 4)…, highest
 *  coefficient first, without the leading 1. */
function generator(degree) {
  const result = new Array(degree).fill(0);
  result[degree - 1] = 1;
  let root = 1;
  for (let i = 0; i < degree; i++) {
    for (let j = 0; j < degree; j++) {
      result[j] = multiply(result[j], root);
      if (j + 1 < degree) result[j] ^= result[j + 1];
    }
    root = multiply(root, 2);
  }
  return result;
}

/** The error correction codewords for `data`: its remainder divided by
 *  `divisor`. */
function remainder(data, divisor) {
  const result = new Array(divisor.length).fill(0);
  for (const byte of data) {
    const factor = byte ^ result.shift();
    result.push(0);
    for (let i = 0; i < divisor.length; i++) result[i] ^= multiply(divisor[i], factor);
  }
  return result;
}

// MARK: The matrix

class Matrix {
  constructor(version) {
    this.version = version;
    this.size = version * 4 + 17;
    this.modules = Array.from({ length: this.size }, () => new Array(this.size).fill(false));
    this.reserved = Array.from({ length: this.size }, () => new Array(this.size).fill(false));
    this.drawFunctionPatterns();
  }

  set(x, y, dark) {
    this.modules[y][x] = dark;
    this.reserved[y][x] = true;
  }

  drawFunctionPatterns() {
    const { size } = this;
    for (let i = 0; i < size; i++) {
      this.set(6, i, i % 2 === 0);
      this.set(i, 6, i % 2 === 0);
    }
    // The finder patterns, with their light separators.
    for (const [cx, cy] of [[3, 3], [size - 4, 3], [3, size - 4]]) {
      for (let dy = -4; dy <= 4; dy++) {
        for (let dx = -4; dx <= 4; dx++) {
          const [x, y] = [cx + dx, cy + dy];
          const ring = Math.max(Math.abs(dx), Math.abs(dy));
          if (x >= 0 && x < size && y >= 0 && y < size) this.set(x, y, ring !== 2 && ring !== 4);
        }
      }
    }
    const centers = alignmentCenters(this.version, size);
    const last = centers.length - 1;
    centers.forEach((cx, i) => centers.forEach((cy, j) => {
      // Not where the finder patterns are.
      if ((i === 0 && j === 0) || (i === 0 && j === last) || (i === last && j === 0)) return;
      for (let dy = -2; dy <= 2; dy++) {
        for (let dx = -2; dx <= 2; dx++) this.set(cx + dx, cy + dy, Math.max(Math.abs(dx), Math.abs(dy)) !== 1);
      }
    }));
    // Reserved for now, drawn with each mask.
    this.drawFormat(0);
    if (this.version >= 7) {
      let rem = this.version;
      for (let i = 0; i < 12; i++) rem = (rem << 1) ^ ((rem >>> 11) * 0x1f25);
      const bits = (this.version << 12) | rem;
      for (let i = 0; i < 18; i++) {
        const dark = ((bits >>> i) & 1) === 1;
        const [a, b] = [size - 11 + (i % 3), Math.floor(i / 3)];
        this.set(a, b, dark);
        this.set(b, a, dark);
      }
    }
  }

  /** The format information, level M and `mask`, in both its places, and
   *  the dark module. */
  drawFormat(mask) {
    const { size } = this;
    const data = (LEVEL_M << 3) | mask;
    let rem = data;
    for (let i = 0; i < 10; i++) rem = (rem << 1) ^ ((rem >>> 9) * 0x537);
    const bits = ((data << 10) | rem) ^ 0x5412;
    const bit = (i) => ((bits >>> i) & 1) === 1;
    for (let i = 0; i <= 5; i++) this.set(8, i, bit(i));
    this.set(8, 7, bit(6));
    this.set(8, 8, bit(7));
    this.set(7, 8, bit(8));
    for (let i = 9; i < 15; i++) this.set(14 - i, 8, bit(i));
    for (let i = 0; i < 8; i++) this.set(size - 1 - i, 8, bit(i));
    for (let i = 8; i < 15; i++) this.set(8, size - 15 + i, bit(i));
    this.set(8, size - 8, true);
  }

  /** Places the codewords in the two-column zigzag, right to left, skipping
   *  the vertical timing pattern. Remainder bits stay light. */
  place(codewords) {
    const { size } = this;
    let i = 0;
    for (let right = size - 1; right >= 1; right -= 2) {
      if (right === 6) right = 5;
      const upward = ((right + 1) & 2) === 0;
      for (let step = 0; step < size; step++) {
        const y = upward ? size - 1 - step : step;
        for (const x of [right, right - 1]) {
          if (this.reserved[y][x] || i >= codewords.length * 8) continue;
          this.modules[y][x] = ((codewords[i >>> 3] >>> (7 - (i & 7))) & 1) === 1;
          i++;
        }
      }
    }
  }

  /** The modules with `mask` applied and its format information. */
  masked(mask) {
    this.drawFormat(mask);
    const flip = MASKS[mask];
    return this.modules.map((row, y) => row.map((dark, x) => (this.reserved[y][x] ? dark : dark !== flip(x, y))));
  }
}

function alignmentCenters(version, size) {
  if (version === 1) return [];
  const count = Math.floor(version / 7) + 2;
  const step = Math.ceil((version * 4 + 4) / (count * 2 - 2)) * 2;
  const result = [6];
  for (let center = size - 7; result.length < count; center -= step) result.splice(1, 0, center);
  return result;
}

// MARK: Choosing the mask

/** The standard's penalty for a masked symbol: runs of five or more alike,
 *  2 by 2 blocks alike, patterns that look like a finder pattern, and how
 *  far dark modules are from half. */
function penalty(modules) {
  const size = modules.length;
  const columns = modules.map((_, x) => modules.map((row) => row[x]));
  let score = 0;
  for (const line of [...modules, ...columns]) {
    for (let start = 0; start < size;) {
      let end = start;
      while (end < size && line[end] === line[start]) end++;
      if (end - start >= 5) score += 3 + (end - start - 5);
      start = end;
    }
    score += 40 * finderLike(line);
  }
  for (let y = 0; y < size - 1; y++) {
    for (let x = 0; x < size - 1; x++) {
      const dark = modules[y][x];
      if (modules[y][x + 1] === dark && modules[y + 1][x] === dark && modules[y + 1][x + 1] === dark) score += 3;
    }
  }
  const dark = modules.reduce((count, row) => count + row.filter(Boolean).length, 0);
  score += 10 * Math.floor(Math.abs(dark * 20 - size * size * 10) / (size * size));
  return score;
}

/** How often dark, light, dark × 3, light, dark (1:1:3:1:1) comes with four
 *  light modules before or after it in `line`, outside the symbol being
 *  light. */
function finderLike(line) {
  const padded = [false, false, false, false, ...line, false, false, false, false];
  const core = [true, false, true, true, true, false, true];
  let count = 0;
  for (let i = 4; i + core.length <= padded.length - 4; i++) {
    if (!core.every((dark, k) => padded[i + k] === dark)) continue;
    const before = padded.slice(i - 4, i).every((dark) => !dark);
    const after = padded.slice(i + 7, i + 11).every((dark) => !dark);
    count += Number(before) + Number(after);
  }
  return count;
}
