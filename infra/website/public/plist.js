// Property lists, binary and XML, read into plain JavaScript values. The
// Worker reads apps' Info.plist with this (src/ipa.js), and the certificate
// page provisioning profiles, so it's here with the site's files, where both
// can load it. Nothing here touches a page.

export class PlistError extends Error {}

// A binary property list's objects, counting each time one is reached.
const MAX_OBJECTS = 100_000;

/** Whether `value` is a property list's dictionary, as parsePlist returns
 *  them. */
export const isDictionary = (value) => value !== null && typeof value === "object" && Object.getPrototypeOf(value) === null;

/** A binary or XML property list as plain JavaScript values: dictionaries as
 *  objects without a prototype, so no key can be taken for something else,
 *  data as Uint8Arrays, dates as Dates, the rest as themselves. `name` is
 *  what the errors call it. */
export function parsePlist(bytes, name = "the property list") {
  try {
    if (new TextDecoder().decode(bytes.subarray(0, 8)) === "bplist00") return parseBinaryPlist(bytes, name);
    // TextDecoder drops a byte order mark.
    const text = new TextDecoder().decode(bytes);
    if (/^\s*(<\?xml|<!DOCTYPE|<plist)/.test(text)) return parseXMLPlist(text, name);
  } catch (error) {
    throw error instanceof PlistError ? error : new PlistError(`${name} is damaged`);
  }
  throw new PlistError(`${name} isn't a property list`);
}

function parseBinaryPlist(bytes, name) {
  const damaged = () => new PlistError(`${name} is damaged`);
  if (bytes.length < 8 + 1 + 32) throw damaged();
  const view = new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength);
  const trailer = bytes.length - 32;
  const offsetSize = bytes[trailer + 6];
  const refSize = bytes[trailer + 7];
  const count = Number(view.getBigUint64(trailer + 8));
  const top = Number(view.getBigUint64(trailer + 16));
  const table = Number(view.getBigUint64(trailer + 24));
  if (!offsetSize || offsetSize > 8 || !refSize || refSize > 8 || top >= count || table + count * offsetSize > trailer) {
    throw damaged();
  }
  const uint = (at, size) => {
    if (at + size > trailer) throw damaged();
    let value = 0;
    for (let i = 0; i < size; i++) value = value * 256 + bytes[at + i];
    return value;
  };
  // The length of a string, data, array or dictionary, and where its
  // contents start.
  const contents = (at, info) => {
    if (info !== 0xf) return { length: info, start: at + 1 };
    const marker = bytes[at + 1];
    if (marker >> 4 !== 0x1) throw damaged();
    const size = 1 << (marker & 0xf);
    return { length: uint(at + 2, size), start: at + 2 + size };
  };
  let budget = MAX_OBJECTS;
  const object = (ref, depth) => {
    if (depth > 32 || --budget < 0) throw new PlistError(`${name} is too complex`);
    if (ref >= count) throw damaged();
    const at = uint(table + ref * offsetSize, offsetSize);
    if (at < 8 || at >= trailer) throw damaged();
    const type = bytes[at] >> 4;
    const info = bytes[at] & 0xf;
    switch (type) {
      case 0x0:
        return info === 0x9 ? true : info === 0x8 ? false : null;
      case 0x1: {
        const size = 1 << info;
        if (at + 1 + size > trailer) throw damaged();
        // 8-byte integers are signed; a 16-byte one's value is in its lower 8.
        if (size >= 8) return Number(view.getBigInt64(at + 1 + size - 8));
        return uint(at + 1, size);
      }
      case 0x2:
        if (at + 1 + (1 << info) > trailer) throw damaged();
        return info === 2 ? view.getFloat32(at + 1) : view.getFloat64(at + 1);
      case 0x3:
        if (at + 9 > trailer) throw damaged();
        return new Date(Date.UTC(2001, 0, 1) + view.getFloat64(at + 1) * 1000);
      case 0x4: {
        const { length, start } = contents(at, info);
        if (start + length > trailer) throw damaged();
        return bytes.slice(start, start + length);
      }
      case 0x5: {
        const { length, start } = contents(at, info);
        if (start + length > trailer) throw damaged();
        let text = "";
        for (let i = start; i < start + length; i += 4096) {
          text += String.fromCharCode(...bytes.subarray(i, Math.min(i + 4096, start + length)));
        }
        return text;
      }
      case 0x6: {
        const { length, start } = contents(at, info);
        if (start + length * 2 > trailer) throw damaged();
        let text = "";
        for (let i = 0; i < length; i++) text += String.fromCharCode(view.getUint16(start + i * 2));
        return text;
      }
      case 0x8:
        return uint(at + 1, info + 1);
      case 0xa:
      case 0xc: {
        const { length, start } = contents(at, info);
        const items = [];
        for (let i = 0; i < length; i++) items.push(object(uint(start + i * refSize, refSize), depth + 1));
        return items;
      }
      case 0xd: {
        const { length, start } = contents(at, info);
        const dict = Object.create(null);
        for (let i = 0; i < length; i++) {
          const key = object(uint(start + i * refSize, refSize), depth + 1);
          const value = object(uint(start + (length + i) * refSize, refSize), depth + 1);
          if (typeof key === "string") dict[key] = value;
        }
        return dict;
      }
      default:
        throw damaged();
    }
  };
  return object(top, 0);
}

function parseXMLPlist(text, name) {
  const damaged = () => new PlistError(`${name} is damaged`);
  const body = text.replace(/<\?[\s\S]*?\?>|<!--[\s\S]*?-->|<!DOCTYPE[^>]*>/g, "");
  const entities = { amp: "&", lt: "<", gt: ">", quot: '"', apos: "'" };
  const decode = (raw) => raw.replace(/&(#x[0-9a-f]+|#[0-9]+|[a-z]+);/gi, (whole, name) => {
    if (name[0] !== "#") return entities[name] ?? whole;
    const code = name[1] === "x" || name[1] === "X" ? parseInt(name.slice(2), 16) : parseInt(name.slice(1), 10);
    return code <= 0x10ffff ? String.fromCodePoint(code) : "";
  });
  const scalar = (name, raw) => {
    const value = decode(raw);
    if (name === "integer") return parseInt(value, 10);
    if (name === "real") return parseFloat(value);
    if (name === "date") return new Date(value.trim());
    if (name === "data") return Uint8Array.from(atob(value.replace(/\s+/g, "")), (c) => c.charCodeAt(0));
    return value;
  };

  // Open dictionaries and arrays, each dictionary with the key waiting for
  // its value.
  const stack = [{ kind: "root", value: undefined }];
  const add = (value) => {
    const parent = stack[stack.length - 1];
    if (parent.kind === "array") parent.value.push(value);
    else if (parent.kind === "dict") {
      if (parent.key === null) throw damaged();
      parent.value[parent.key] = value;
      parent.key = null;
    } else if (parent.value === undefined) parent.value = value;
    else throw damaged();
  };
  let open = null; // a key or a scalar, and its text so far
  for (const [, closing, name, selfClosing, textRun] of body.matchAll(/<(\/?)([A-Za-z]+)[^>]*?(\/?)>|([^<]+)/g)) {
    if (textRun !== undefined) {
      if (open) open.text += textRun;
      continue;
    }
    if (open) {
      if (!closing || name !== open.name) throw damaged();
      if (open.name === "key") {
        const parent = stack[stack.length - 1];
        if (parent.kind !== "dict" || parent.key !== null) throw damaged();
        parent.key = decode(open.text);
      } else {
        add(scalar(open.name, open.text));
      }
      open = null;
      continue;
    }
    switch (name) {
      case "plist":
        break;
      case "dict":
      case "array":
        if (selfClosing) add(name === "dict" ? Object.create(null) : []);
        else if (closing) {
          const done = stack.pop();
          if (done.kind !== name || (name === "dict" && done.key !== null)) throw damaged();
          add(done.value);
        } else {
          if (stack.length > 32) throw new PlistError(`${name} is too complex`);
          stack.push(name === "dict" ? { kind: name, value: Object.create(null), key: null } : { kind: name, value: [] });
        }
        break;
      case "true":
      case "false":
        if (!closing) add(name === "true");
        break;
      case "key":
      case "string":
      case "integer":
      case "real":
      case "date":
      case "data":
        if (closing) throw damaged();
        if (selfClosing) {
          if (name === "key") {
            const parent = stack[stack.length - 1];
            if (parent.kind !== "dict" || parent.key !== null) throw damaged();
            parent.key = "";
          } else {
            add(scalar(name, ""));
          }
        } else {
          open = { name, text: "" };
        }
        break;
      default:
        throw damaged();
    }
  }
  if (open || stack.length !== 1) throw damaged();
  return stack[0].value;
}

// MARK: Writing

/** `value` as an XML property list's bytes: dictionaries from plain
 *  objects, in their keys' order, data from Uint8Arrays, dates from Dates,
 *  integers from whole numbers, and booleans, other numbers, strings and
 *  arrays as themselves. Throws a PlistError for text XML can't hold,
 *  such as most control characters, and for values a property list can't. */
export function writePlist(value) {
  return new TextEncoder().encode(`<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
${element(value, "")}
</plist>
`);
}

function element(value, indent) {
  if (typeof value === "string") return `${indent}<string>${escapeXML(value)}</string>`;
  if (typeof value === "boolean") return `${indent}<${value}/>`;
  if (typeof value === "number" && Number.isFinite(value)) {
    return Number.isInteger(value) ? `${indent}<integer>${value}</integer>` : `${indent}<real>${value}</real>`;
  }
  if (value instanceof Uint8Array) {
    let binary = "";
    for (let i = 0; i < value.length; i += 0x2000) binary += String.fromCharCode(...value.subarray(i, i + 0x2000));
    return `${indent}<data>${btoa(binary)}</data>`;
  }
  if (value instanceof Date && !Number.isNaN(value.getTime())) {
    return `${indent}<date>${value.toISOString().replace(/\.\d{3}Z$/, "Z")}</date>`;
  }
  if (Array.isArray(value)) {
    if (!value.length) return `${indent}<array/>`;
    return `${indent}<array>\n${value.map((item) => element(item, `${indent}  `)).join("\n")}\n${indent}</array>`;
  }
  if (value !== null && typeof value === "object") {
    const entries = Object.entries(value).filter(([, item]) => item !== undefined);
    if (!entries.length) return `${indent}<dict/>`;
    const lines = entries.map(([key, item]) => `${indent}  <key>${escapeXML(key)}</key>\n${element(item, `${indent}  `)}`);
    return `${indent}<dict>\n${lines.join("\n")}\n${indent}</dict>`;
  }
  throw new PlistError(`a property list can't hold ${value === null ? "null" : typeof value}`);
}

function escapeXML(text) {
  if (/[\u0000-\u0008\u000B\u000C\u000E-\u001F￾￿]/.test(text)) throw new PlistError("the text has characters XML can't hold");
  return text.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;");
}
