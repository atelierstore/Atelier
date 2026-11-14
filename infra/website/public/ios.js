// Which iOS an iPhone has, for the Apple ID way, whose installer needs
// iOS 27: the home page, which the Worker sends with the signing service
// first to an iPhone with an older one (src/region.js), and the Apple ID
// page, which says so over You'll need (apple-id.js). Safari's user agent
// stopped counting iOS at 18 ("iPhone OS 18_6" on iOS 26), but Safari's own
// version, Version/26, is still iOS's.

/** The iOS the installer, atelier-install, needs. */
export const INSTALLER_IOS = 27;

/** iOS's version, as a whole number, on the iPhone whose Safari sent
 *  `agent`, or null: on an iPad, which says it's a Mac, on a computer, and
 *  in other browsers and apps' own, which don't give Safari's version. */
export function iPhoneIOS(agent) {
  if (typeof agent !== "string" || !agent.includes("(iPhone;")) return null;
  const version = / Version\/(\d+)[\d.]* Mobile\/\w+ Safari\/[\d.]+$/.exec(agent);
  return version ? Number(version[1]) : null;
}
