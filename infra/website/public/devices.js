// Which iPhones and iPads a profile's UDIDs can be (#152). A profile lists
// only UDIDs, but since the iPhone XS, a UDID starts with its chip's ID
// (00008120-… for the A16), so the certificate page can name the models
// with that chip, for the visitor to compare with Settings › General ›
// About. The chips and models are libimobiledevice's (libirecovery's
// irecv_devices table), for the iPhones and iPads iOS 17 runs on.

const CHIPS = new Map([
  [0x8020, "iPhone XS, XS Max or XR, or iPad mini (5th gen), iPad Air (3rd gen) or iPad (8th gen)"],
  [0x8027, "iPad Pro 11-inch (1st or 2nd gen) or iPad Pro 12.9-inch (3rd or 4th gen)"],
  [0x8030, "iPhone 11, 11 Pro, 11 Pro Max or SE (2nd gen), or iPad (9th gen)"],
  [0x8101, "iPhone 12 mini, 12, 12 Pro or 12 Pro Max, or iPad Air (4th gen) or iPad (10th gen)"],
  [0x8103, "iPad Pro 11-inch (3rd gen), iPad Pro 12.9-inch (5th gen) or iPad Air (5th gen)"],
  [0x8110, "iPhone 13 mini, 13, 13 Pro, 13 Pro Max, 14, 14 Plus or SE (3rd gen), or iPad mini (6th gen)"],
  [0x8112, "iPad Pro 11-inch (4th gen), iPad Pro 12.9-inch (6th gen) or iPad Air (M2)"],
  [0x8120, "iPhone 14 Pro, 14 Pro Max, 15 or 15 Plus, or iPad (A16)"],
  [0x8122, "iPad Air (M3)"],
  [0x8130, "iPhone 15 Pro or 15 Pro Max, or iPad mini (A17 Pro)"],
  [0x8132, "iPad Pro (M4) or iPad Air (M4)"],
  [0x8140, "iPhone 16, 16 Plus, 16 Pro, 16 Pro Max or 16e"],
  [0x8142, "iPad Pro (M5)"],
  [0x8150, "iPhone 17, 17 Pro, 17 Pro Max, 17e or Air"],
  [0x8160, "iPhone 18 Pro, 18 Pro Max or Duo, or iPad mini (A20 Pro)"],
]);

/** What `udid` can be, in words: the models with its chip, or, for the
 *  40-digit UDIDs of 2017 and earlier, that age. */
export function deviceModels(udid) {
  const newer = /^([0-9A-F]{8})-[0-9A-F]{16}$/i.exec(udid);
  if (newer) return CHIPS.get(parseInt(newer[1], 16)) ?? "An iPhone or iPad newer than this page knows";
  if (/^[0-9A-F]{40}$/i.test(udid)) return "An iPhone or iPad from 2017 or earlier";
  return "A device this page can't name";
}

/** The profile's devices, each once, as {udid, models}. */
export function profileDevices(profile) {
  const seen = new Map();
  for (const udid of profile.provisionedDevices) {
    const key = udid.toUpperCase();
    if (!seen.has(key)) seen.set(key, { udid: key, models: deviceModels(key) });
  }
  return [...seen.values()];
}
