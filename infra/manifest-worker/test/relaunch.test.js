import { test } from "node:test";
import assert from "node:assert/strict";

import worker from "../src/index.js";
import { MAX_DELAY, relaunch } from "../src/relaunch.js";

test("answers, with nothing, once the delay is over", async () => {
  let waited;
  const response = await relaunch(new URL("https://w.example/relaunch?delay=15"), async (ms) => {
    waited = ms;
  });
  assert.equal(waited, 15_000);
  assert.equal(response.status, 204);
  assert.equal(response.headers.get("Cache-Control"), "no-store");
  assert.equal(await response.text(), "");
});

test("waits as long as it's told, up to the most", async () => {
  const waits = [];
  const record = async (ms) => {
    waits.push(ms);
  };
  for (const delay of [0, 20, MAX_DELAY]) {
    const response = await relaunch(new URL(`https://w.example/relaunch?delay=${delay}`), record);
    assert.equal(response.status, 204);
  }
  assert.deepEqual(waits, [0, 20_000, MAX_DELAY * 1000]);
});

test("refuses a missing or odd delay without waiting", async () => {
  for (const query of ["", "?delay=", "?delay=-1", `?delay=${MAX_DELAY + 1}`, "?delay=1.5", "?delay=abc", "?delay=1e1", "?delay=%205", "?wait=15"]) {
    let waited = false;
    const response = await relaunch(new URL(`https://w.example/relaunch${query}`), async () => {
      waited = true;
    });
    assert.equal(response.status, 400, query);
    assert.equal(waited, false, query);
  }
});

test("the worker routes /relaunch and refuses other methods", async () => {
  const response = await worker.fetch(new Request("https://w.example/relaunch?delay=0"));
  assert.equal(response.status, 204);
  const post = await worker.fetch(new Request("https://w.example/relaunch?delay=0", { method: "POST" }));
  assert.equal(post.status, 405);
});
