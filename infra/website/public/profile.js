// Provisioning profiles (.mobileprovision), as Atelier reads them
// (ProvisioningProfile.swift in CertKit): the property list inside Apple's
// CMS envelope. The envelope's signature isn't checked; iOS checks it when
// it installs an app signed with the profile. Nothing here touches a page.

import { DERError, TAG, at, equal, octets, oid, parseDER } from "./der.js";
import { PlistError, isDictionary, parsePlist } from "./plist.js";

/** Why a file isn't a profile Atelier can use: `reason` is "notAProfile",
 *  or "missing" with the key that's missing as `key`. */
export class ProfileError extends Error {
  constructor(reason, key) {
    super(key ? `the profile has no ${key}` : "it isn't a provisioning profile");
    this.reason = reason;
    this.key = key;
  }
}

/** The profile in `bytes`: {name, uuid, teamID, teamName, appIDName,
 *  applicationIdentifier, creationDate, expirationDate, kind,
 *  provisionedDevices, developerCertificates, entitlements}. `kind` is
 *  "development" (lists devices and allows debugging), "adHoc" (lists
 *  devices), "enterprise" (any device) or "appStore" (no devices: only the
 *  App Store and TestFlight install with it). `developerCertificates` are
 *  the certificates (DER) allowed to sign with it, and `entitlements` its
 *  entitlements as they are. Throws a ProfileError. */
export function readProfile(bytes) {
  let plist;
  try {
    plist = parsePlist(plistData(bytes), "the profile");
  } catch (error) {
    if (error instanceof PlistError || error instanceof ProfileError) throw new ProfileError("notAProfile");
    throw error;
  }
  if (!isDictionary(plist)) throw new ProfileError("notAProfile");

  const require = (key, check) => {
    if (!check(plist[key])) throw new ProfileError("missing", key);
    return plist[key];
  };
  const isText = (value) => typeof value === "string";
  const isDate = (value) => value instanceof Date && !Number.isNaN(value.getTime());
  const entitlements = require("Entitlements", isDictionary);
  const applicationIdentifier = entitlements["application-identifier"];
  if (!isText(applicationIdentifier)) throw new ProfileError("missing", "application-identifier");
  const name = require("Name", isText);
  const uuid = require("UUID", isText);
  const expirationDate = require("ExpirationDate", isDate);
  const developerCertificates = require("DeveloperCertificates", (value) => Array.isArray(value) && value.every((item) => item instanceof Uint8Array));
  const teams = Array.isArray(plist.TeamIdentifier) && plist.TeamIdentifier.every(isText) ? plist.TeamIdentifier : [];
  const provisionedDevices = Array.isArray(plist.ProvisionedDevices) && plist.ProvisionedDevices.every(isText) ? plist.ProvisionedDevices : [];

  let kind;
  if (plist.ProvisionsAllDevices === true) kind = "enterprise";
  else if (provisionedDevices.length) kind = entitlements["get-task-allow"] === true ? "development" : "adHoc";
  else kind = "appStore";

  return {
    name,
    uuid,
    teamID: teams[0] ?? applicationIdentifier.split(".")[0] ?? "",
    teamName: isText(plist.TeamName) ? plist.TeamName : null,
    appIDName: isText(plist.AppIDName) ? plist.AppIDName : null,
    applicationIdentifier,
    creationDate: isDate(plist.CreationDate) ? plist.CreationDate : null,
    expirationDate,
    kind,
    provisionedDevices,
    developerCertificates,
    entitlements,
  };
}

/** The bundle ID part of the App ID, such as `com.example.app` or `*`. */
export function bundleIDPattern(profile) {
  const prefix = `${profile.teamID}.`;
  return profile.applicationIdentifier.startsWith(prefix)
    ? profile.applicationIdentifier.slice(prefix.length)
    : profile.applicationIdentifier;
}

/** The device an app signed with the profile runs on, when it lists only
 *  one, which iOS only installs development and ad hoc apps on: how the page
 *  knows the iPhone it's on, as apps can't read UDIDs. Null otherwise. */
export function onlyDevice(profile) {
  if (profile.kind !== "development" && profile.kind !== "adHoc") return null;
  const devices = new Set(profile.provisionedDevices.map((udid) => udid.toUpperCase()));
  return devices.size === 1 ? profile.provisionedDevices[0] : null;
}

/** Whether the profile lists the certificate `der`. */
export function allows(profile, der) {
  return profile.developerCertificates.some((certificate) => equal(certificate, der));
}

/** The plist bytes: the CMS SignedData's content, or the data itself when
 *  it's already a bare plist. */
export function plistData(bytes) {
  const start = new TextDecoder().decode(bytes.subarray(0, 6));
  if (start.startsWith("<?xml") || start === "bplist") return bytes;
  // ContentInfo ::= SEQUENCE { contentType, [0] EXPLICIT SignedData }
  // SignedData ::= SEQUENCE { version, digestAlgorithms, encapContentInfo, ... }
  // EncapsulatedContentInfo ::= SEQUENCE { eContentType, [0] EXPLICIT OCTET STRING }
  let contentInfo;
  try {
    contentInfo = parseDER(bytes);
  } catch (error) {
    if (error instanceof DERError) throw new ProfileError("notAProfile");
    throw error;
  }
  const encapsulated = at(contentInfo, 1, 0, 2);
  const content = at(encapsulated, 1, 0);
  if (
    oid(at(contentInfo, 0)) !== "1.2.840.113549.1.7.2"
    || encapsulated?.tag !== TAG.sequence
    || !content || (content.tag & 0x1f) !== TAG.octetString
  ) {
    throw new ProfileError("notAProfile");
  }
  return octets(content);
}
