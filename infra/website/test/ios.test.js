import { test } from "node:test";
import assert from "node:assert/strict";

import { INSTALLER_IOS, iPhoneIOS } from "../public/ios.js";

// Safari's user agent stopped counting iOS at 18: iOS 26's says 18_6.
const SAFARI_26 = "Mozilla/5.0 (iPhone; CPU iPhone OS 18_6 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/26.0 Mobile/15E148 Safari/604.1";
const SAFARI_26_1 = "Mozilla/5.0 (iPhone; CPU iPhone OS 18_6 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/26.1 Mobile/15E148 Safari/604.1";
const SAFARI_27 = "Mozilla/5.0 (iPhone; CPU iPhone OS 18_6 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/27.0 Mobile/15E148 Safari/604.1";
const SAFARI_18 = "Mozilla/5.0 (iPhone; CPU iPhone OS 18_5 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.5 Mobile/15E148 Safari/604.1";

test("the installer needs iOS 27", () => {
  assert.equal(INSTALLER_IOS, 27);
});

test("Safari on an iPhone gives iOS's version as its own", () => {
  assert.equal(iPhoneIOS(SAFARI_26), 26);
  assert.equal(iPhoneIOS(SAFARI_26_1), 26);
  assert.equal(iPhoneIOS(SAFARI_27), 27);
  assert.equal(iPhoneIOS(SAFARI_18), 18);
});

test("an iPad, a computer, other browsers and apps' own don't say", () => {
  for (const agent of [
    // iPadOS's Safari says it's a Mac.
    "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/26.0 Safari/605.1.15",
    "Mozilla/5.0 (iPad; CPU OS 18_6 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/26.0 Mobile/15E148 Safari/604.1",
    "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/142.0.0.0 Safari/537.36",
    "Mozilla/5.0 (iPhone; CPU iPhone OS 18_6 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) CriOS/142.0.7444.77 Mobile/15E148 Safari/604.1",
    "Mozilla/5.0 (iPhone; CPU iPhone OS 18_6 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) FxiOS/145.0 Mobile/15E148 Safari/605.1.15",
    "Mozilla/5.0 (iPhone; CPU iPhone OS 18_6 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/26.0 EdgiOS/142.0.3595.53 Mobile/15E148 Safari/605.1.15",
    "Mozilla/5.0 (iPhone; CPU iPhone OS 18_6 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Mobile/15E148 Instagram 400.0.0.0.0",
    "",
  ]) {
    assert.equal(iPhoneIOS(agent), null, agent);
  }
  assert.equal(iPhoneIOS(null), null);
  assert.equal(iPhoneIOS(undefined), null);
});
