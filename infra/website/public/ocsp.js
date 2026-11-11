// Asks Apple whether a certificate was revoked, for the certificate page, as
// Atelier asks (OCSP.swift in CertKit, #5): an OCSP request about it to the
// responder it names, and the answer only believed when its issuer, one of
// Apple's developer CAs, or a responder the issuer authorized, signed it.
// Apple's responders only answer over plain HTTP and to no other site's
// pages, so the page asks through the Worker (/ocsp), and the signature is
// what makes the answer trustworthy. Nothing here touches a page.

import { DERError, NULL, TAG, at, bits, context, equal, integer, octetString, objectIdentifier, oid, parseDER, sequence, time } from "./der.js";
import { OID, authorityKeyIdentifier, extendedKeyUsages, nameAttributes, ocspURL, publicKeyHash, readCertificate, subjectKeyIdentifier } from "./x509.js";

/** Why a check couldn't say, as RevocationCheckError's cases: `reason` is
 *  noResponder, unknownIssuer, responderError, httpStatus, network,
 *  malformedResponse, badSignature, notAboutThisCertificate or stale. */
export class RevocationError extends Error {
  constructor(reason, detail) {
    super(detail === undefined ? reason : `${reason}: ${detail}`);
    this.reason = reason;
    this.detail = detail;
  }
}

/** How far the device's clock may be from the responder's, in ms. */
const CLOCK_SKEW = 5 * 60 * 1000;
const SHA1_OID = "1.3.14.3.2.26";
const BASIC_RESPONSE_OID = "1.3.6.1.5.5.7.48.1.1";

/** What Apple says about the certificate `der`: {status: "good"}, {status:
 *  "revoked", at} (a Date, or null) or {status: "unknown"}. `transport(url,
 *  body)` sends the request to the responder at `url`, by default through
 *  the Worker, and answers {status, body}. Throws a RevocationError. */
export async function checkRevocation(der, { transport = throughWorker, trustedIssuers = APPLE_DEVELOPER_CAS, now = new Date() } = {}) {
  let leaf;
  try {
    leaf = readCertificate(der);
  } catch {
    throw new RevocationError("malformedResponse");
  }
  const issuer = await issuerOf(leaf, trustedIssuers);
  const url = ocspURL(leaf);
  if (!url) throw new RevocationError("noResponder");
  const body = await ocspRequest(leaf, issuer);
  let answer;
  try {
    answer = await transport(url, body);
  } catch (error) {
    throw new RevocationError("network", error?.message);
  }
  if (answer.status !== 200) throw new RevocationError("httpStatus", answer.status);
  return revocationStatus(readOCSPResponse(answer.body), leaf, issuer, now);
}

/** Sends the request through the Worker, which passes it on to Apple. */
async function throughWorker(url, body) {
  const response = await fetch(`/ocsp?url=${encodeURIComponent(url)}`, {
    method: "POST",
    headers: { "Content-Type": "application/ocsp-request" },
    body,
  });
  if (!response.ok) {
    // The Worker says what Apple answered when it answered at all.
    const { status } = await response.json().catch(() => ({}));
    return { status: status ?? response.status, body: new Uint8Array(0) };
  }
  return { status: 200, body: new Uint8Array(await response.arrayBuffer()) };
}

/** The trusted CA that issued `leaf`, by its key ID or else its name. */
export async function issuerOf(leaf, trustedIssuers = APPLE_DEVELOPER_CAS) {
  const issuers = trustedIssuers.flatMap((der) => {
    try {
      return [readCertificate(der)];
    } catch {
      return [];
    }
  });
  const keyID = authorityKeyIdentifier(leaf);
  if (keyID) {
    for (const issuer of issuers) {
      const id = subjectKeyIdentifier(issuer) ?? (await publicKeyHash(issuer));
      if (id && equal(id, keyID)) return issuer;
    }
  }
  const named = issuers.find((issuer) => equal(issuer.subject.encoded, leaf.issuer.encoded));
  if (named) return named;
  throw new RevocationError("unknownIssuer", nameAttributes(leaf.issuer).get(OID.commonName) ?? "unnamed");
}

/** An OCSP request about one certificate (RFC 6960 4.1), without a nonce:
 *  Apple's responders send cached answers and ignore nonces. */
export async function ocspRequest(leaf, issuer) {
  const keyHash = await publicKeyHash(issuer);
  if (!keyHash) throw new RevocationError("malformedResponse");
  const nameHash = new Uint8Array(await crypto.subtle.digest("SHA-1", leaf.issuer.encoded));
  // CertID ::= SEQUENCE { hashAlgorithm, issuerNameHash, issuerKeyHash, serialNumber }
  const certID = sequence(sequence(objectIdentifier(SHA1_OID), NULL), octetString(nameHash), octetString(keyHash), integer(leaf.serial));
  // OCSPRequest ::= SEQUENCE { tbsRequest SEQUENCE { requestList SEQUENCE OF Request SEQUENCE { reqCert } } }
  return sequence(sequence(sequence(sequence(certID))));
}

/** A responder's answer (RFC 6960 4.2), as far as checking one certificate
 *  needs: {responseData, singles, signatureAlgorithm, signature,
 *  certificates}. Throws a RevocationError. */
export function readOCSPResponse(der) {
  const malformed = () => new RevocationError("malformedResponse");
  let response;
  try {
    response = parseDER(der);
  } catch {
    throw malformed();
  }
  // OCSPResponse ::= SEQUENCE { responseStatus ENUMERATED,
  //   responseBytes [0] EXPLICIT SEQUENCE { responseType OID, response OCTET STRING } OPTIONAL }
  const status = at(response, 0);
  if (response.tag !== TAG.sequence || status?.tag !== TAG.enumerated || status.content.length !== 1) throw malformed();
  if (status.content[0] !== 0) throw new RevocationError("responderError", status.content[0]);
  const responseBytes = at(response, 1, 0);
  const inner = at(responseBytes, 1);
  if (oid(at(responseBytes, 0)) !== BASIC_RESPONSE_OID || inner?.tag !== TAG.octetString) throw malformed();
  let basic;
  try {
    basic = parseDER(inner.content);
  } catch {
    throw malformed();
  }
  // BasicOCSPResponse ::= SEQUENCE { tbsResponseData, signatureAlgorithm,
  //   signature BIT STRING, certs [0] EXPLICIT SEQUENCE OF Certificate OPTIONAL }
  const data = at(basic, 0);
  const signatureAlgorithm = oid(at(basic, 1, 0));
  const signature = bits(at(basic, 2));
  if (basic.tag !== TAG.sequence || data?.tag !== TAG.sequence || !signatureAlgorithm || !signature) throw malformed();

  // ResponseData ::= SEQUENCE { version [0] EXPLICIT DEFAULT v1, responderID,
  //   producedAt, responses SEQUENCE OF SingleResponse, responseExtensions [1] OPTIONAL }
  const parts = data.children[0]?.tag === context(0) ? data.children.slice(1) : data.children;
  if (parts.length < 3 || parts[2].tag !== TAG.sequence) throw malformed();
  const certificates = [];
  for (const node of at(basic.children.find((child) => child.tag === context(0)), 0)?.children ?? []) {
    try {
      certificates.push(readCertificate(node.encoded));
    } catch (error) {
      if (!(error instanceof DERError)) throw error;
    }
  }
  return { responseData: data, singles: parts[2].children.map(single), signatureAlgorithm, signature, certificates };
}

function single(node) {
  // SingleResponse ::= SEQUENCE { certID, certStatus, thisUpdate GeneralizedTime,
  //   nextUpdate [0] EXPLICIT GeneralizedTime OPTIONAL, singleExtensions [1] OPTIONAL }
  // CertStatus ::= CHOICE { good [0] IMPLICIT NULL,
  //   revoked [1] IMPLICIT SEQUENCE { revocationTime, revocationReason [0] OPTIONAL },
  //   unknown [2] IMPLICIT NULL }
  const certID = at(node, 0);
  const certStatus = at(node, 1);
  const thisUpdate = time(at(node, 2));
  if (certID?.children.length !== 4 || !certStatus || !thisUpdate) throw new RevocationError("malformedResponse");
  let status;
  switch (certStatus.tag) {
    case 0x80:
      status = { status: "good" };
      break;
    case 0xa1:
      status = { status: "revoked", at: time(at(certStatus, 0)) ?? null };
      break;
    case 0x82:
      status = { status: "unknown" };
      break;
    default:
      throw new RevocationError("malformedResponse");
  }
  return {
    issuerNameHash: at(certID, 1).content,
    issuerKeyHash: at(certID, 2).content,
    serial: at(certID, 3).content,
    ...status,
    thisUpdate,
    nextUpdate: time(at(node.children.find((child) => child.tag === context(0)), 0)) ?? null,
  };
}

/** The status of `leaf`, once the answer is shown to be current and to come
 *  from `issuer`. Currency comes first: a wrong clock also makes the
 *  responder's certificate look invalid, and "stale" says what's wrong. */
export async function revocationStatus(response, leaf, issuer, now) {
  const keyHash = await publicKeyHash(issuer);
  if (!keyHash) throw new RevocationError("malformedResponse");
  const nameHash = new Uint8Array(await crypto.subtle.digest("SHA-1", leaf.issuer.encoded));
  const answer = response.singles.find((one) => equal(one.serial, leaf.serial)
    && equal(one.issuerKeyHash, keyHash) && equal(one.issuerNameHash, nameHash));
  if (!answer) throw new RevocationError("notAboutThisCertificate");
  if (answer.thisUpdate > now.getTime() + CLOCK_SKEW) throw new RevocationError("stale");
  if (answer.nextUpdate && answer.nextUpdate < now.getTime() - CLOCK_SKEW) throw new RevocationError("stale");
  await verifyAnswer(response, issuer, now);
  return answer.status === "revoked" ? { status: "revoked", at: answer.at } : { status: answer.status };
}

/** Checks the answer is signed by the issuer itself, or by a certificate
 *  the issuer signed for OCSP Signing that's valid now. */
async function verifyAnswer(response, issuer, now) {
  const message = response.responseData.encoded;
  if (await verifySignature(response.signature, message, response.signatureAlgorithm, issuer.publicKeyInfo)) return;
  for (const responder of response.certificates) {
    if (
      equal(responder.issuer.encoded, issuer.subject.encoded)
      && extendedKeyUsages(responder).includes(OID.ocspSigning)
      && responder.notBefore <= now.getTime() + CLOCK_SKEW && now.getTime() - CLOCK_SKEW <= responder.notAfter
      && await verifySignature(responder.signature, responder.tbs.encoded, responder.signatureAlgorithm, issuer.publicKeyInfo)
      && await verifySignature(response.signature, message, response.signatureAlgorithm, responder.publicKeyInfo)
    ) {
      return;
    }
  }
  throw new RevocationError("badSignature");
}

const RSA_KEY = "1.2.840.113549.1.1.1";
const EC_KEY = "1.2.840.10045.2.1";
const ALGORITHMS = {
  "1.2.840.113549.1.1.5": [RSA_KEY, "SHA-1"],
  "1.2.840.113549.1.1.11": [RSA_KEY, "SHA-256"],
  "1.2.840.113549.1.1.12": [RSA_KEY, "SHA-384"],
  "1.2.840.113549.1.1.13": [RSA_KEY, "SHA-512"],
  "1.2.840.10045.4.3.2": [EC_KEY, "SHA-256"],
  "1.2.840.10045.4.3.3": [EC_KEY, "SHA-384"],
  "1.2.840.10045.4.3.4": [EC_KEY, "SHA-512"],
};
const CURVES = { "1.2.840.10045.3.1.7": "P-256", "1.3.132.0.34": "P-384", "1.3.132.0.35": "P-521" };

/** RSA (PKCS #1 v1.5) and ECDSA signature checks, with Web Crypto. False
 *  for a signature that doesn't match, or an algorithm or key Atelier
 *  doesn't know. */
export async function verifySignature(signature, message, algorithm, publicKeyInfo) {
  // SubjectPublicKeyInfo ::= SEQUENCE { algorithm AlgorithmIdentifier, subjectPublicKey BIT STRING }
  const keyType = oid(at(publicKeyInfo, 0, 0));
  const [expected, hash] = ALGORITHMS[algorithm] ?? [];
  if (!keyType || keyType !== expected) return false;
  try {
    if (keyType === RSA_KEY) {
      const key = await crypto.subtle.importKey("spki", publicKeyInfo.encoded, { name: "RSASSA-PKCS1-v1_5", hash }, false, ["verify"]);
      return await crypto.subtle.verify("RSASSA-PKCS1-v1_5", key, signature, message);
    }
    const namedCurve = CURVES[oid(at(publicKeyInfo, 0, 1))];
    if (!namedCurve) return false;
    const key = await crypto.subtle.importKey("spki", publicKeyInfo.encoded, { name: "ECDSA", namedCurve }, false, ["verify"]);
    const raw = rawECDSASignature(signature, { "P-256": 32, "P-384": 48, "P-521": 66 }[namedCurve]);
    return raw ? await crypto.subtle.verify({ name: "ECDSA", hash }, key, raw, message) : false;
  } catch {
    // A key Web Crypto can't import.
    return false;
  }
}

/** An ECDSA signature as Web Crypto takes it, r then s at `size` bytes
 *  each, from X9.62's SEQUENCE { r INTEGER, s INTEGER }, or null. */
function rawECDSASignature(der, size) {
  let node;
  try {
    node = parseDER(der);
  } catch {
    return null;
  }
  const values = node.children.map((child) => {
    let bytes = child.content;
    while (bytes.length > size && bytes[0] === 0) bytes = bytes.subarray(1);
    return child.tag === TAG.integer && bytes.length <= size ? bytes : null;
  });
  if (node.tag !== TAG.sequence || values.length !== 2 || values.includes(null)) return null;
  const raw = new Uint8Array(2 * size);
  raw.set(values[0], size - values[0].length);
  raw.set(values[1], 2 * size - values[1].length);
  return raw;
}

// MARK: Apple's developer CAs

// Apple's Worldwide Developer Relations intermediate CAs, which issue
// development, distribution and enterprise signing certificates, as
// Atelier has them (AppleDeveloperCAs.swift), from
// https://www.apple.com/certificateauthority/. Answers are only believed
// when these signed them, or a responder they authorized.

const base64 = (text) => Uint8Array.from(atob(text.replace(/\s+/g, "")), (c) => c.charCodeAt(0));

export const APPLE_DEVELOPER_CAS = [
  // CN = Apple Worldwide Developer Relations CA - G2, OU = Apple Certification Authority, O = Apple Inc., C = US, until May  6 23:43:24 2029 GMT.
  base64(`
    MIIC9zCCAnygAwIBAgIIb+/Y9emjp+4wCgYIKoZIzj0EAwIwZzEbMBkGA1UEAwwSQXBwbGUgUm9vdCBDQSAtIEczMSYwJAYDVQQL
    DB1BcHBsZSBDZXJ0aWZpY2F0aW9uIEF1dGhvcml0eTETMBEGA1UECgwKQXBwbGUgSW5jLjELMAkGA1UEBhMCVVMwHhcNMTQwNTA2
    MjM0MzI0WhcNMjkwNTA2MjM0MzI0WjCBgDE0MDIGA1UEAwwrQXBwbGUgV29ybGR3aWRlIERldmVsb3BlciBSZWxhdGlvbnMgQ0Eg
    LSBHMjEmMCQGA1UECwwdQXBwbGUgQ2VydGlmaWNhdGlvbiBBdXRob3JpdHkxEzARBgNVBAoMCkFwcGxlIEluYy4xCzAJBgNVBAYT
    AlVTMFkwEwYHKoZIzj0CAQYIKoZIzj0DAQcDQgAE3fC3BkvP3XMEE8RDiQOTgPte9nStQmFSWAImUxnIYyIHCVJhysTZV+9tJmiL
    dJGMxPmAaCj8CWjwENrp0C7JGqOB9zCB9DBGBggrBgEFBQcBAQQ6MDgwNgYIKwYBBQUHMAGGKmh0dHA6Ly9vY3NwLmFwcGxlLmNv
    bS9vY3NwMDQtYXBwbGVyb290Y2FnMzAdBgNVHQ4EFgQUhLaEzDqGYnIWWZToGqO9SN863wswDwYDVR0TAQH/BAUwAwEB/zAfBgNV
    HSMEGDAWgBS7sN6hWDOImqSKmd6+veuv2sskqzA3BgNVHR8EMDAuMCygKqAohiZodHRwOi8vY3JsLmFwcGxlLmNvbS9hcHBsZXJv
    b3RjYWczLmNybDAOBgNVHQ8BAf8EBAMCAQYwEAYKKoZIhvdjZAYCDwQCBQAwCgYIKoZIzj0EAwIDaQAwZgIxANmxxzHGI/ZPTdDZ
    R8V9GGkRh3En02it4Jtlmr5s3z9GppAJvm6hOyywUYlBPIfSvwIxAPxkUolLPF2/axzCiZgvcq61m6oaCyNUd1ToFUOixRLal1Bz
    fF7QbrJcYlDXUfE6Wg==
  `),
  // CN = Apple Worldwide Developer Relations Certification Authority, OU = G3, O = Apple Inc., C = US, until Feb 20 00:00:00 2030 GMT.
  base64(`
    MIIEUTCCAzmgAwIBAgIQfK9pCiW3Of57m0R6wXjF7jANBgkqhkiG9w0BAQsFADBiMQswCQYDVQQGEwJVUzETMBEGA1UEChMKQXBw
    bGUgSW5jLjEmMCQGA1UECxMdQXBwbGUgQ2VydGlmaWNhdGlvbiBBdXRob3JpdHkxFjAUBgNVBAMTDUFwcGxlIFJvb3QgQ0EwHhcN
    MjAwMjE5MTgxMzQ3WhcNMzAwMjIwMDAwMDAwWjB1MUQwQgYDVQQDDDtBcHBsZSBXb3JsZHdpZGUgRGV2ZWxvcGVyIFJlbGF0aW9u
    cyBDZXJ0aWZpY2F0aW9uIEF1dGhvcml0eTELMAkGA1UECwwCRzMxEzARBgNVBAoMCkFwcGxlIEluYy4xCzAJBgNVBAYTAlVTMIIB
    IjANBgkqhkiG9w0BAQEFAAOCAQ8AMIIBCgKCAQEA2PWJ/KhZC4fHTJEuLVaQ03gdpDDppUjvC0O/LYT7JF1FG+XrWTYSXFRknmxi
    LbTGl8rMPPbWBpH85QKmHGq0edVny6zpPwcR4YS8Rx1mjjmi6LRJ7TrS4RBgeo6TjMrA2gzAg9Dj+ZHWp4zIwXPirkbRYp2SqJBg
    N31ols2N4Pyb+ni743uvLRfdW/6AWSN1F7gSwe0b5TTO/iK1nkmw5VW/j4SiPKi6xYaVFuQAyZ8D0MyzOhZ71gVcnetHrg21LYwO
    aU1A0EtMOwSejSGxrC5DVDDOwYqGlJhL32oNP/77HK6XF8J4CjDgXx9UO0m3JQAaN4LSVpelUkl8YDib7wIDAQABo4HvMIHsMBIG
    A1UdEwEB/wQIMAYBAf8CAQAwHwYDVR0jBBgwFoAUK9BpR5R2Cf70a40uQKb3R01/CF4wRAYIKwYBBQUHAQEEODA2MDQGCCsGAQUF
    BzABhihodHRwOi8vb2NzcC5hcHBsZS5jb20vb2NzcDAzLWFwcGxlcm9vdGNhMC4GA1UdHwQnMCUwI6AhoB+GHWh0dHA6Ly9jcmwu
    YXBwbGUuY29tL3Jvb3QuY3JsMB0GA1UdDgQWBBQJ/sAVkPmvZAqSErkmKGMMl+ynsjAOBgNVHQ8BAf8EBAMCAQYwEAYKKoZIhvdj
    ZAYCAQQCBQAwDQYJKoZIhvcNAQELBQADggEBAK1lE+j24IF3RAJHQr5fpTkg6mKp/cWQyXMT1Z6b0KoPjY3L7QHPbChAW8dVJEH4
    /M/BtSPp3Ozxb8qAHXfCxGFJJWevD8o5Ja3T43rMMygNDi6hV0Bz+uZcrgZRKe3jhQxPYdwyFot30ETKXXIDMUacrptAGvr04NM+
    +i+MZp+XxFRZ79JI9AeZSWBZGcfdlNHAwWx/eCHvDOs7bJmCS1JgOLU5gm3sUjFTvg+RTElJdI+mUcuER04ddSduvfnSXPN/wmwL
    CTbiZOTCNwMUGdXqapSqqdv+9poIZ4vvK7iqF0mDr8/LvOnP6pVxsLRFoszlh6oKw0E6eVzaUDSdlTs=
  `),
  // CN = Apple Worldwide Developer Relations Certification Authority, OU = G4, O = Apple Inc., C = US, until Dec 10 00:00:00 2030 GMT.
  base64(`
    MIIEVTCCAz2gAwIBAgIUE9x3lVJx5T3GMujM/+Uh88zFztIwDQYJKoZIhvcNAQELBQAwYjELMAkGA1UEBhMCVVMxEzARBgNVBAoT
    CkFwcGxlIEluYy4xJjAkBgNVBAsTHUFwcGxlIENlcnRpZmljYXRpb24gQXV0aG9yaXR5MRYwFAYDVQQDEw1BcHBsZSBSb290IENB
    MB4XDTIwMTIxNjE5MzYwNFoXDTMwMTIxMDAwMDAwMFowdTFEMEIGA1UEAww7QXBwbGUgV29ybGR3aWRlIERldmVsb3BlciBSZWxh
    dGlvbnMgQ2VydGlmaWNhdGlvbiBBdXRob3JpdHkxCzAJBgNVBAsMAkc0MRMwEQYDVQQKDApBcHBsZSBJbmMuMQswCQYDVQQGEwJV
    UzCCASIwDQYJKoZIhvcNAQEBBQADggEPADCCAQoCggEBANAfeKp6JzKwRl/nF3bYoJ0OKY6tPTKlxGs3yeRBkWq3eXFdDDQEYHX3
    rkOPR8SGHgjov9Y5Ui8eZ/xx8YJtPH4GUnadLLzVQ+mxtLxAOnhRXVGhJeG+bJGdayFZGEHVD41tQSo5SiHgkJ9OE0/QjJoyuNdq
    kh4laqQyziIZhQVg3AJK8lrrd3kCfcCXVGySjnYB5kaP5eYq+6KwrRitbTOFOCOL6oqW7Z+uZk+jDEAnbZXQYojZQykn/e2kv1Mu
    kBVlPNkuYmQzHWxq3Y4hqqRfFcYw7V/mjDaSlLfcOQIA+2SM1AyB8j/VNJeHdSbCb64DYyEMe9QbsWLFApy9/a8CAwEAAaOB7zCB
    7DASBgNVHRMBAf8ECDAGAQH/AgEAMB8GA1UdIwQYMBaAFCvQaUeUdgn+9GuNLkCm90dNfwheMEQGCCsGAQUFBwEBBDgwNjA0Bggr
    BgEFBQcwAYYoaHR0cDovL29jc3AuYXBwbGUuY29tL29jc3AwMy1hcHBsZXJvb3RjYTAuBgNVHR8EJzAlMCOgIaAfhh1odHRwOi8v
    Y3JsLmFwcGxlLmNvbS9yb290LmNybDAdBgNVHQ4EFgQUW9n6HeeaGgujmXYiUIY+kchbd6gwDgYDVR0PAQH/BAQDAgEGMBAGCiqG
    SIb3Y2QGAgEEAgUAMA0GCSqGSIb3DQEBCwUAA4IBAQA/Vj2e5bbDeeZFIGi9v3OLLBKeAuOugCKMBB7DUshwgKj7zqew1UJEggOC
    Twb8O0kU+9h0UoWvp50h5wESA5/NQFjQAde/MoMrU1goPO6cn1R2PWQnxn6NHThNLa6B5rmluJyJlPefx4elUWY0GzlxOSTjh2fv
    pbFoe4zuPfeutnvi0v/fYcZqdUmVIkSoBPyUuAsuORFJEtHlgepZAE9bPFo22noicwkJac3AfOriJP6YRLj477JxPxpd1F1+M02c
    HSS+APCQA1iZQT0xWmJArzmoUUOSqwSonMJNsUvSq3xKX+udO7xPiEAGE/+QF4oIRynoYpgppU8RBWk6z/Kf
  `),
  // CN = Apple Worldwide Developer Relations Certification Authority, OU = G5, O = Apple Inc., C = US, until Dec 10 00:00:00 2030 GMT.
  base64(`
    MIIEVTCCAz2gAwIBAgIUO36ACu7TAqHm7NuX2cqsKJzxaZQwDQYJKoZIhvcNAQELBQAwYjELMAkGA1UEBhMCVVMxEzARBgNVBAoT
    CkFwcGxlIEluYy4xJjAkBgNVBAsTHUFwcGxlIENlcnRpZmljYXRpb24gQXV0aG9yaXR5MRYwFAYDVQQDEw1BcHBsZSBSb290IENB
    MB4XDTIwMTIxNjE5Mzg1NloXDTMwMTIxMDAwMDAwMFowdTFEMEIGA1UEAww7QXBwbGUgV29ybGR3aWRlIERldmVsb3BlciBSZWxh
    dGlvbnMgQ2VydGlmaWNhdGlvbiBBdXRob3JpdHkxCzAJBgNVBAsMAkc1MRMwEQYDVQQKDApBcHBsZSBJbmMuMQswCQYDVQQGEwJV
    UzCCASIwDQYJKoZIhvcNAQEBBQADggEPADCCAQoCggEBAJ9d2h/7+rzQSyI8x9Ym+hf39J8ePmQRZprvXr6rNL2qLCFu1h6UIYUs
    dMEOEGGqPGNKfkrjyHXWz8KcCEh7arkpsclm/ciKFtGyBDyCuoBs4v8Kcuus/jtvSL6eixFNlX2ye5AvAhxO/Em+12+1T754xtre
    ss3J2WYRO1rpCUVziVDUTuJoBX7adZxLAa7a489tdE3eU9DVGjiCOtCd410pe7GB6iknC/tgfIYS+/BiTwbnTNEf2W2e7XPaeCEN
    nXDZRleQX2eEwXN3CqhiYraucIa7dSOJrXn25qTU/YMmMgo7JJJbIKGc0S+AGJvdPAvntf3sgFcPF54/K4cnu/cCAwEAAaOB7zCB
    7DASBgNVHRMBAf8ECDAGAQH/AgEAMB8GA1UdIwQYMBaAFCvQaUeUdgn+9GuNLkCm90dNfwheMEQGCCsGAQUFBwEBBDgwNjA0Bggr
    BgEFBQcwAYYoaHR0cDovL29jc3AuYXBwbGUuY29tL29jc3AwMy1hcHBsZXJvb3RjYTAuBgNVHR8EJzAlMCOgIaAfhh1odHRwOi8v
    Y3JsLmFwcGxlLmNvbS9yb290LmNybDAdBgNVHQ4EFgQUGYuXjUpbYXhX9KVcNRKKOQjjsHUwDgYDVR0PAQH/BAQDAgEGMBAGCiqG
    SIb3Y2QGAgEEAgUAMA0GCSqGSIb3DQEBCwUAA4IBAQBaxDWi2eYKnlKiAIIid81yL5D5Iq8UJcyqCkJgksK9dR3rTMoV5X5rQBBe
    +1tFdA3wen2Ikc7eY4tCidIY30GzWJ4GCIdI3UCvI9Xt6yxg5eukfxzpnIPWlF9MYjmKTq4TjX1DuNxerL4YQPLmDyxdE5Pxe2Wo
    wmhI3v+0lpsM+zI2np4NlV84CouW0hJst4sLjtc+7G8Bqs5NRWDbhHFmYuUZZTDNiv9FU/tu+4h3Q8NIY/n3UbNyXnniVs+8u4S5
    OFp4rhFIUrsNNYuU3sx0mmj1SWCUrPKosxWGkNDMMEOG0+VwAlG0gcCol9Tq6rCMCUDvOJOyzSID62dDZchF
  `),
  // CN = Apple Worldwide Developer Relations Certification Authority, OU = G6, O = Apple Inc., C = US, until Mar 19 00:00:00 2036 GMT.
  base64(`
    MIIDFjCCApygAwIBAgIUIsGhRwp0c2nvU4YSycafPTjzbNcwCgYIKoZIzj0EAwMwZzEbMBkGA1UEAwwSQXBwbGUgUm9vdCBDQSAt
    IEczMSYwJAYDVQQLDB1BcHBsZSBDZXJ0aWZpY2F0aW9uIEF1dGhvcml0eTETMBEGA1UECgwKQXBwbGUgSW5jLjELMAkGA1UEBhMC
    VVMwHhcNMjEwMzE3MjAzNzEwWhcNMzYwMzE5MDAwMDAwWjB1MUQwQgYDVQQDDDtBcHBsZSBXb3JsZHdpZGUgRGV2ZWxvcGVyIFJl
    bGF0aW9ucyBDZXJ0aWZpY2F0aW9uIEF1dGhvcml0eTELMAkGA1UECwwCRzYxEzARBgNVBAoMCkFwcGxlIEluYy4xCzAJBgNVBAYT
    AlVTMHYwEAYHKoZIzj0CAQYFK4EEACIDYgAEbsQKC94PrlWmZXnXgtxzdVJL8T0SGYngDRGpngn3N6PT8JMEb7FDi4bBmPhCnZ3/
    sq6PF/cGcKXWsL5vOteRhyJ45x3ASP7cOB+aao90fcpxSv/EZFbniAbNgZGhIhpIo4H6MIH3MBIGA1UdEwEB/wQIMAYBAf8CAQAw
    HwYDVR0jBBgwFoAUu7DeoVgziJqkipnevr3rr9rLJKswRgYIKwYBBQUHAQEEOjA4MDYGCCsGAQUFBzABhipodHRwOi8vb2NzcC5h
    cHBsZS5jb20vb2NzcDAzLWFwcGxlcm9vdGNhZzMwNwYDVR0fBDAwLjAsoCqgKIYmaHR0cDovL2NybC5hcHBsZS5jb20vYXBwbGVy
    b290Y2FnMy5jcmwwHQYDVR0OBBYEFD8vlCNR01DJmig97bB85c+lkGKZMA4GA1UdDwEB/wQEAwIBBjAQBgoqhkiG92NkBgIBBAIF
    ADAKBggqhkjOPQQDAwNoADBlAjBAXhSq5IyKogMCPtw490BaB677CaEGJXufQB/EqZGd6CSjiCtOnuMTbXVXmxxcxfkCMQDTSPxa
    rZXvNrkxU3TkUMI33yzvFVVRT4wxWJC994OsdcZ4+RGNsYDyR5gmdr0nDGg=
  `),
];
