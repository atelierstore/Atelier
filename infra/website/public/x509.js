// The parts of an X.509 certificate that the certificate page shows and
// checks, as Atelier reads them (X509.swift and SigningCertificate.swift in
// CertKit). Nothing here touches a page.

import { DERError, TAG, at, bits, context, octets, oid, parseDER, text, time } from "./der.js";

export const OID = {
  commonName: "2.5.4.3",
  organization: "2.5.4.10",
  organizationalUnit: "2.5.4.11",
  subjectKeyIdentifier: "2.5.29.14",
  authorityKeyIdentifier: "2.5.29.35",
  extendedKeyUsage: "2.5.29.37",
  authorityInfoAccess: "1.3.6.1.5.5.7.1.1",
  ocspAccessMethod: "1.3.6.1.5.5.7.48.1",
  ocspSigning: "1.3.6.1.5.5.7.3.9",
};

/** A certificate from its DER: {der, tbs, serial, issuer, subject,
 *  notBefore, notAfter, publicKeyInfo, extensions, signatureAlgorithm,
 *  signature}, the names and the key as nodes (der.js), `serial` the
 *  INTEGER's contents with any leading zero, and `extensions` each
 *  extension's value by OID. Throws a DERError when it isn't one. */
export function readCertificate(der) {
  const certificate = parseDER(der);
  // Certificate ::= SEQUENCE { tbsCertificate, signatureAlgorithm, signature }
  const tbs = at(certificate, 0);
  const signatureAlgorithm = oid(at(certificate, 1, 0));
  const signature = bits(at(certificate, 2));
  if (certificate.tag !== TAG.sequence || tbs?.tag !== TAG.sequence || !signatureAlgorithm || !signature) {
    throw new DERError("not a certificate");
  }
  // TBSCertificate ::= SEQUENCE { [0] version OPTIONAL, serialNumber,
  //   signature, issuer, validity, subject, subjectPublicKeyInfo,
  //   [1] issuerUniqueID OPTIONAL, [2] subjectUniqueID OPTIONAL,
  //   [3] extensions OPTIONAL }
  const parts = tbs.children[0]?.tag === context(0) ? tbs.children.slice(1) : tbs.children;
  const notBefore = time(at(parts[3], 0));
  const notAfter = time(at(parts[3], 1));
  if (
    parts.length < 6 || parts[0].tag !== TAG.integer || parts[2].tag !== TAG.sequence
    || parts[3].tag !== TAG.sequence || !notBefore || !notAfter
    || parts[4].tag !== TAG.sequence || parts[5].tag !== TAG.sequence
  ) {
    throw new DERError("not a certificate");
  }
  const extensions = new Map();
  // Extension ::= SEQUENCE { extnID, critical BOOLEAN DEFAULT FALSE, extnValue OCTET STRING }
  for (const item of at(parts.find((part) => part.tag === context(3)), 0)?.children ?? []) {
    const id = oid(item.children[0]);
    const value = item.children[item.children.length - 1];
    if (id && value?.tag === TAG.octetString) extensions.set(id, value.content);
  }
  return {
    der,
    tbs,
    serial: parts[0].content,
    issuer: parts[2],
    subject: parts[4],
    notBefore,
    notAfter,
    publicKeyInfo: parts[5],
    extensions,
    signatureAlgorithm,
    signature,
  };
}

/** A name's attributes by OID; the first value of each wins. */
export function nameAttributes(name) {
  const result = new Map();
  for (const rdn of name.children) {
    for (const attribute of rdn.children) {
      const id = oid(attribute.children[0]);
      const value = text(attribute.children[1]);
      if (id && value !== undefined && !result.has(id)) result.set(id, value);
    }
  }
  return result;
}

/** What Atelier shows of a signing certificate (SigningCertificate):
 *  {commonName, name, teamID, teamName}, `name` being the common name
 *  without Apple's "Apple Distribution: " style prefix. */
export function signingIdentity(certificate) {
  const subject = nameAttributes(certificate.subject);
  const commonName = subject.get(OID.commonName) ?? "Unnamed certificate";
  const colon = commonName.indexOf(":");
  return {
    commonName,
    name: colon < 0 ? commonName : commonName.slice(colon + 1).trim(),
    teamID: subject.get(OID.organizationalUnit) ?? null,
    teamName: subject.get(OID.organization) ?? null,
  };
}

/** The SHA-1 of the certificate's public key, as RFC 5280 defines key IDs,
 *  and which OCSP's issuerKeyHash is. */
export async function publicKeyHash(certificate) {
  const key = bits(at(certificate.publicKeyInfo, 1));
  return key && new Uint8Array(await crypto.subtle.digest("SHA-1", key));
}

export function subjectKeyIdentifier(certificate) {
  const node = extension(certificate, OID.subjectKeyIdentifier);
  return node?.tag === TAG.octetString ? node.content : undefined;
}

/** The key ID of the CA that issued it. Apple's CAs make theirs the SHA-1
 *  of their key. */
export function authorityKeyIdentifier(certificate) {
  // AuthorityKeyIdentifier ::= SEQUENCE { keyIdentifier [0] IMPLICIT OCTET STRING OPTIONAL, ... }
  return extension(certificate, OID.authorityKeyIdentifier)?.children.find((child) => child.tag === 0x80)?.content;
}

/** Where its issuer answers OCSP requests about it, or undefined. */
export function ocspURL(certificate) {
  // AuthorityInfoAccessSyntax ::= SEQUENCE OF AccessDescription
  // AccessDescription ::= SEQUENCE { accessMethod OID, accessLocation GeneralName }
  for (const description of extension(certificate, OID.authorityInfoAccess)?.children ?? []) {
    const location = description.children[1];
    // uniformResourceIdentifier [6] IMPLICIT IA5String
    if (oid(description.children[0]) !== OID.ocspAccessMethod || location?.tag !== 0x86) continue;
    try {
      return new URL(new TextDecoder().decode(octets(location))).href;
    } catch {
      continue;
    }
  }
  return undefined;
}

export function extendedKeyUsages(certificate) {
  return (extension(certificate, OID.extendedKeyUsage)?.children ?? []).map(oid).filter(Boolean);
}

/** An extension's value, read, or undefined. */
function extension(certificate, id) {
  const value = certificate.extensions.get(id);
  if (!value) return undefined;
  try {
    return parseDER(value);
  } catch {
    return undefined;
  }
}
