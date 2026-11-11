// Naming the iPhones and iPads a profile's UDIDs can be, from the chip ID
// that starts a UDID since the iPhone XS.

import { test } from "node:test";
import assert from "node:assert/strict";

import { deviceModels, profileDevices } from "../public/devices.js";

test("names the models with a UDID's chip", () => {
  assert.equal(deviceModels("00008020-001A2B3C4D5E6F70"), "iPhone XS, XS Max or XR, or iPad mini (5th gen), iPad Air (3rd gen) or iPad (8th gen)");
  assert.equal(deviceModels("00008130-001A2B3C4D5E6F70"), "iPhone 15 Pro or 15 Pro Max, or iPad mini (A17 Pro)");
  assert.equal(deviceModels("00008140-001a2b3c4d5e6f70"), "iPhone 16, 16 Plus, 16 Pro, 16 Pro Max or 16e");
  assert.equal(deviceModels("00008150-001A2B3C4D5E6F70"), "iPhone 17, 17 Pro, 17 Pro Max, 17e or Air");
});

test("says what it can when the chip is unknown or the UDID is older", () => {
  assert.equal(deviceModels("00008190-001A2B3C4D5E6F70"), "An iPhone or iPad newer than this page knows");
  assert.equal(deviceModels("a".repeat(40)), "An iPhone or iPad from 2017 or earlier");
  assert.equal(deviceModels("not a udid"), "A device this page can't name");
});

test("lists a profile's devices once each", () => {
  const profile = { provisionedDevices: ["00008120-0011223344556677", "00008120-0011223344556677".toLowerCase(), "00008030-0011223344556677"] };
  assert.deepEqual(profileDevices(profile).map((device) => device.udid), ["00008120-0011223344556677", "00008030-0011223344556677"]);
});
