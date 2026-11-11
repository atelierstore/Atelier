// A small BER/DER reader and writer, as Atelier's own (ASN1.swift in
// CertKit): enough for certificates, the envelope around provisioning
// profiles, and OCSP, for the certificate page. Apple writes profiles with
// indefinite lengths and chunked OCTET STRINGs, so both are read. Nothing
// here touches a page.

export class DERError extends Error {}

export const TAG = {
  boolean: 0x01,
  integer: 0x02,
  bitString: 0x03,
  octetString: 0x04,
  null: 0x05,
  objectIdentifier: 0x06,
  enumerated: 0x0a,
  utcTime: 0x17,
  generalizedTime: 0x18,
  sequence: 0x30,
  set: 0x31,
};

/** A context-specific constructed tag, [number]. */
export const context = (number) => 0xa0 | number;

/** The first node in `bytes`, trailing bytes ignored: {tag, content,
 *  children, encoded}. `content` is a primitive node's contents, `children`
 *  a constructed one's nodes, and `encoded` the whole node as it was read,
 *  which is what hashes and signatures cover. Throws a DERError. */
export function parseDER(bytes) {
  let position = 0;
  const byte = () => {
    if (position >= bytes.length) throw new DERError("truncated");
    return bytes[position++];
  };
  const node = (depth) => {
    if (depth >= 32) throw new DERError("too deep");
    const start = position;
    const tag = byte();
    // High tag numbers: skip their continuation octets. Nothing read here
    // uses them.
    if ((tag & 0x1f) === 0x1f) while (byte() & 0x80);
    const constructed = (tag & 0x20) !== 0;

    const first = byte();
    let length = null;
    if (first < 0x80) {
      length = first;
    } else if (first === 0x80) {
      if (!constructed) throw new DERError("unsupported length");
    } else {
      const count = first & 0x7f;
      if (count > 4) throw new DERError("unsupported length");
      length = 0;
      for (let i = 0; i < count; i++) length = length * 256 + byte();
    }

    if (!constructed) {
      if (length > bytes.length - position) throw new DERError("truncated");
      position += length;
      return { tag, content: bytes.subarray(position - length, position), children: [], encoded: bytes.subarray(start, position) };
    }
    const children = [];
    if (length !== null) {
      if (length > bytes.length - position) throw new DERError("truncated");
      const end = position + length;
      while (position < end) children.push(node(depth + 1));
      if (position !== end) throw new DERError("truncated");
    } else {
      // Indefinite length: children run until an end-of-contents marker.
      for (;;) {
        if (position + 2 > bytes.length) throw new DERError("truncated");
        if (bytes[position] === 0 && bytes[position + 1] === 0) {
          position += 2;
          break;
        }
        children.push(node(depth + 1));
      }
    }
    return { tag, content: new Uint8Array(0), children, encoded: bytes.subarray(start, position) };
  };
  return node(0);
}

/** The node at `path`, a child's index at each step, or undefined. */
export function at(node, ...path) {
  for (const index of path) node = node?.children[index];
  return node;
}

/** An OCTET STRING's bytes, joining the chunks of a constructed one. */
export function octets(node) {
  if (!(node.tag & 0x20)) return node.content;
  return concat(node.children.map(octets));
}

/** A BIT STRING's bytes, without its unused-bits octet, or undefined. Keys
 *  and signatures are whole bytes, so that octet is always 0 for them. */
export function bits(node) {
  if (node?.tag !== TAG.bitString || node.content[0] !== 0) return undefined;
  return node.content.subarray(1);
}

/** An OBJECT IDENTIFIER in dotted form, such as "2.5.4.3", or undefined. */
export function oid(node) {
  if (node?.tag !== TAG.objectIdentifier || !node.content.length) return undefined;
  const first = node.content[0];
  const parts = [Math.floor(first / 40), first % 40];
  let value = 0;
  for (const byte of node.content.subarray(1)) {
    value = value * 128 + (byte & 0x7f);
    if (!(byte & 0x80)) {
      parts.push(value);
      value = 0;
    }
  }
  return parts.join(".");
}

/** The text of any of the string types X.509 names use, or undefined. */
export function text(node) {
  switch (node?.tag) {
    case 0x0c: // UTF8String
    case 0x13: // PrintableString
    case 0x16: // IA5String
    case 0x1a: // VisibleString
      return new TextDecoder().decode(node.content);
    case 0x14: // T61String, which holds Latin-1 in practice
      return String.fromCharCode(...node.content);
    case 0x1e: { // BMPString: UTF-16BE
      if (node.content.length % 2) return undefined;
      let result = "";
      for (let i = 0; i < node.content.length; i += 2) result += String.fromCharCode((node.content[i] << 8) | node.content[i + 1]);
      return result;
    }
    default:
      return undefined;
  }
}

/** A UTCTime or GeneralizedTime in UTC ("Z") form, the only form X.509
 *  allows, as a Date, or undefined. */
export function time(node) {
  if (node?.tag !== TAG.utcTime && node?.tag !== TAG.generalizedTime) return undefined;
  const value = new TextDecoder().decode(node.content);
  if (!value.endsWith("Z")) return undefined;
  let digits = value.slice(0, -1);
  // UTCTime: a two-digit year, 50 to 99 meaning 19xx (RFC 5280).
  if (node.tag === TAG.utcTime) digits = (Number(digits.slice(0, 2)) >= 50 ? "19" : "20") + digits;
  // Fractional seconds, which DER certificates don't use anyway.
  digits = digits.split(".")[0];
  if (!/^\d{14}$/.test(digits)) return undefined;
  const n = (from, count) => Number(digits.slice(from, from + count));
  return new Date(Date.UTC(n(0, 4), n(4, 2) - 1, n(6, 2), n(8, 2), n(10, 2), n(12, 2)));
}

export function equal(a, b) {
  return a.length === b.length && a.every((byte, i) => byte === b[i]);
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

// MARK: Writing, the little that's sent: an OCSP request

export function encode(tag, content) {
  let length;
  if (content.length < 0x80) {
    length = [content.length];
  } else {
    length = [];
    for (let count = content.length; count > 0; count = Math.floor(count / 256)) length.unshift(count & 0xff);
    length.unshift(0x80 | length.length);
  }
  return concat([Uint8Array.of(tag, ...length), content]);
}

export const sequence = (...children) => encode(TAG.sequence, concat(children));
export const octetString = (bytes) => encode(TAG.octetString, bytes);
export const NULL = Uint8Array.of(TAG.null, 0);
/** An INTEGER from its content octets, as read from a certificate. */
export const integer = (content) => encode(TAG.integer, content);

/** An OBJECT IDENTIFIER from its dotted form. */
export function objectIdentifier(dotted) {
  const parts = dotted.split(".").map(Number);
  const content = [parts[0] * 40 + parts[1]];
  for (let part of parts.slice(2)) {
    const chunk = [part & 0x7f];
    for (part = Math.floor(part / 128); part > 0; part = Math.floor(part / 128)) chunk.unshift((part & 0x7f) | 0x80);
    content.push(...chunk);
  }
  return encode(TAG.objectIdentifier, Uint8Array.from(content));
}
