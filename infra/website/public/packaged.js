// The certificate Atelier opens with, when the certificate page puts it in
// (#152), as Install a Copy's Include Certificate puts it in a copy
// (PackagedCertificate in CertKit, #113): the .p12, its profile and its
// password, in AtelierCertificate.plist next to the app's Info.plist,
// written before signing, so the signature seals it with the rest. Atelier
// imports it on its first launch, once it has checked that the profile it
// was installed with lists the certificate. Nothing here touches a page.

import { writePlist } from "./plist.js";

/** The file's name, in the app's folder. */
export const PACKAGED_CERTIFICATE = "AtelierCertificate.plist";

/** Whether the app looks for the file, which its Info.plist says
 *  (AtelierTakesCertificate, in builds since 3 Nov 2026). Atelier leaves it
 *  out of a copy of a build that doesn't. */
export function takesCertificate(infoPlist) {
  return infoPlist?.AtelierTakesCertificate === true;
}

/** The file's contents: {p12, profile, password, id}, as PackagedCertificate
 *  decodes them, `id` new each time, so Atelier imports it again when it's
 *  installed again with the same certificate. No name, so Atelier keeps the
 *  certificate's own, and no UDID, which the page doesn't know. Throws a
 *  PlistError for a password XML can't hold. */
export function packagedCertificate({ p12, profile, password }) {
  return writePlist({ p12, profile, password, id: crypto.randomUUID().toUpperCase() });
}
