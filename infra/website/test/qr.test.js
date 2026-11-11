// The certificate page's QR codes (public/qr.js), against a reference
// encoder's. qr-reference.json has its modules for four texts, from version
// 1 to 10, each with the mask given, a row per line in hex, padded to whole
// hex digits: made with Project Nayuki's qrcodegen 1.8.0 for Python,
// QrCode.encode_segments([QrSegment.make_bytes(text)], Ecc.MEDIUM, 1, 40,
// mask, False).

import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";

import { QRError, qrCode, qrPath } from "../public/qr.js";

const REFERENCE = JSON.parse(readFileSync(new URL("./qr-reference.json", import.meta.url), "utf8"));

/** `code`'s modules in the reference's form. */
function hexRows({ modules }) {
  return modules.map((row) => {
    const bits = row.map((dark) => (dark ? "1" : "0")).join("").padEnd(Math.ceil(row.length / 4) * 4, "0");
    return BigInt(`0b${bits}`).toString(16).padStart(bits.length / 4, "0");
  });
}

for (const { text, mask, version, rows } of REFERENCE) {
  test(`version ${version} with mask ${mask} matches the reference module for module`, () => {
    const code = qrCode(text, { mask });
    assert.equal(code.version, version);
    assert.equal(code.mask, mask);
    assert.equal(code.size, version * 4 + 17);
    assert.deepEqual(hexRows(code), rows);
  });
}

test("the certificate page's address fits in version 5", () => {
  const code = qrCode("https://atelierstore.app/certificate/install#6f1c09d2b84e4a7c93e5d0a1f27b8c44");
  assert.equal(code.version, 5);
  // The mask the penalty rules prefer is one of the eight, drawn as forced.
  assert.ok(code.mask >= 0 && code.mask < 8);
  assert.deepEqual(code.modules, qrCode("https://atelierstore.app/certificate/install#6f1c09d2b84e4a7c93e5d0a1f27b8c44", { mask: code.mask }).modules);
});

test("text over version 10's 213 bytes is refused", () => {
  assert.equal(qrCode("z".repeat(213)).version, 10);
  assert.throws(() => qrCode("z".repeat(214)), QRError);
  // Bytes, not characters: é is two.
  assert.throws(() => qrCode("é".repeat(107)), QRError);
});

test("the path draws exactly the dark modules", () => {
  const code = qrCode("Atelier", { mask: 2 });
  const drawn = code.modules.map((row) => row.map(() => false));
  for (const [, x, y, run] of qrPath(code).matchAll(/M(\d+) (\d+)h(\d+)v1h-\3z/g)) {
    for (let i = 0; i < Number(run); i++) {
      assert.equal(drawn[y][Number(x) + i], false);
      drawn[y][Number(x) + i] = true;
    }
  }
  assert.deepEqual(drawn, code.modules);
});
