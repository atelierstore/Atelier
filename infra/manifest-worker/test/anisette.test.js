import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";

import worker from "../src/index.js";
import { ANISETTE_LIST } from "../src/anisette.js";

// Atelier's built-in copy, for when the Worker can't be reached.
const BUILT_IN = new URL("../../../Packages/AtelierKit/Sources/AppleIDKit/anisette.json", import.meta.url);

test("serves the list as JSON", async () => {
  const response = await worker.fetch(new Request("https://w.example/anisette"));
  assert.equal(response.status, 200);
  assert.equal(response.headers.get("Content-Type"), "application/json; charset=utf-8");
  assert.equal(response.headers.get("Cache-Control"), "no-store");
  assert.equal(response.headers.get("X-Content-Type-Options"), "nosniff");
  assert.deepEqual(await response.json(), ANISETTE_LIST);
});

test("answers HEAD with nothing, and refuses other methods", async () => {
  const head = await worker.fetch(new Request("https://w.example/anisette", { method: "HEAD" }));
  assert.equal(head.status, 200);
  assert.equal(await head.text(), "");
  const post = await worker.fetch(new Request("https://w.example/anisette", { method: "POST" }));
  assert.equal(post.status, 405);
});

test("lists HTTPS servers Atelier can use, each once", () => {
  assert.equal(ANISETTE_LIST.version, 1);
  assert.match(ANISETTE_LIST.updated, /^\d{4}-\d{2}-\d{2}$/);
  assert.ok(ANISETTE_LIST.servers.length > 0);
  const hosts = new Set();
  for (const server of ANISETTE_LIST.servers) {
    const url = new URL(server.url);
    assert.equal(url.protocol, "https:", server.url);
    // isideload adds its paths to the address, so it has none of its own.
    assert.equal(url.origin, server.url, server.url);
    assert.ok(!hosts.has(url.host), `${url.host} twice`);
    hosts.add(url.host);
    assert.ok(server.name.trim().length > 0, server.url);
    assert.ok(server.kind === undefined || ["mac", "windows", "other"].includes(server.kind), server.url);
  }
});

test("tries a few servers, and sends a client info Apple can be sent", () => {
  // Atelier tries 8 at most, whatever this says.
  assert.ok(Number.isInteger(ANISETTE_LIST.tries));
  assert.ok(ANISETTE_LIST.tries >= 1 && ANISETTE_LIST.tries <= 8);
  assert.ok(ANISETTE_LIST.tries <= ANISETTE_LIST.servers.length);
  const { clientInfo, userAgent } = ANISETTE_LIST.clientInfo;
  for (const value of [clientInfo, userAgent]) {
    assert.match(value, /^[\x20-\x7e]+$/, "a header value: printable ASCII");
  }
});

test("Atelier's built-in copy is the same list", () => {
  // Change both together; the copy is what a new install has until it
  // reaches the Worker.
  assert.deepEqual(JSON.parse(readFileSync(BUILT_IN, "utf8")), ANISETTE_LIST);
});
