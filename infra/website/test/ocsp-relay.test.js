import { test } from "node:test";
import assert from "node:assert/strict";

import worker from "../src/index.js";
import { ocspRelay } from "../src/ocsp-relay.js";

const APPLE = "http://ocsp.apple.com/ocsp03-wwdrg305";
const REQUEST = Uint8Array.of(0x30, 0x03, 0x30, 0x01, 0x00);

function relay(url, { body = REQUEST, method = "POST", type = "application/ocsp-request" } = {}) {
  return new Request(`https://site.example/ocsp?url=${encodeURIComponent(url)}`, {
    method,
    headers: type ? { "Content-Type": type } : {},
    body: method === "POST" ? body : undefined,
  });
}

test("passes the request on to Apple, and Apple's answer back", async () => {
  const sent = [];
  const fetchImpl = async (url, init) => {
    sent.push({ url, method: init.method, type: init.headers["Content-Type"], body: init.body });
    return new Response(Uint8Array.of(1, 2, 3), { headers: { "Content-Type": "application/ocsp-response" } });
  };
  const response = await ocspRelay(relay(APPLE), fetchImpl);
  assert.equal(response.status, 200);
  assert.equal(response.headers.get("Content-Type"), "application/ocsp-response");
  assert.equal(response.headers.get("Cache-Control"), "no-store");
  assert.deepEqual(new Uint8Array(await response.arrayBuffer()), Uint8Array.of(1, 2, 3));
  assert.deepEqual(sent, [{ url: APPLE, method: "POST", type: "application/ocsp-request", body: REQUEST }]);
});

test("only asks Apple's responders", async () => {
  const fetchImpl = async () => assert.fail("asked a responder");
  for (const url of [
    "http://ocsp.example.com/ocsp03-wwdrg305",
    "https://ocsp.apple.com/ocsp03-wwdrg305",
    "http://ocsp.apple.com.example.com/x",
    "http://ocsp.apple.com/a/b",
    "http://ocsp.apple.com/x?y=1",
    "http://ocsp.apple.com:8080/x",
  ]) {
    assert.equal((await ocspRelay(relay(url), fetchImpl)).status, 400, url);
  }
});

test("only passes OCSP requests on, and small ones", async () => {
  const fetchImpl = async () => assert.fail("asked Apple");
  assert.equal((await ocspRelay(relay(APPLE, { type: "text/plain" }), fetchImpl)).status, 400);
  assert.equal((await ocspRelay(relay(APPLE, { body: new Uint8Array(0) }), fetchImpl)).status, 400);
  assert.equal((await ocspRelay(relay(APPLE, { body: new Uint8Array(2000) }), fetchImpl)).status, 400);
  const get = await ocspRelay(relay(APPLE, { method: "GET" }), fetchImpl);
  assert.equal(get.status, 405);
  assert.equal(get.headers.get("Allow"), "POST");
});

test("says what Apple answered when it didn't answer with OCSP", async () => {
  const notFound = await ocspRelay(relay(APPLE), async () => new Response("Not Found", { status: 404 }));
  assert.equal(notFound.status, 502);
  assert.deepEqual(await notFound.json(), { error: "Apple answered HTTP 404.", status: 404 });
  const unreachable = await ocspRelay(relay(APPLE), async () => {
    throw new TypeError("fetch failed");
  });
  assert.equal(unreachable.status, 502);
  assert.deepEqual(await unreachable.json(), { error: "Apple can't be reached.", status: null });
  const long = await ocspRelay(relay(APPLE), async () => new Response(new Uint8Array(70_000)));
  assert.equal(long.status, 502);
});

test("the Worker answers /ocsp", async () => {
  const response = await worker.fetch(relay("http://ocsp.example.com/x"), {});
  assert.equal(response.status, 400);
});
