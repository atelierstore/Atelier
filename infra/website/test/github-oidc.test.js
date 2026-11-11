import { test } from "node:test";
import assert from "node:assert/strict";

import { GitHubKeys, ISSUER, KeysError, TokenError, verifyToken } from "../src/github-oidc.js";
import { base64url, buildClaims, githubSigner } from "./github-token.js";

const AUDIENCE = "https://site.example";

test("a token GitHub signed for the site is accepted, with its claims", async () => {
  const github = await githubSigner();
  const claims = buildClaims(AUDIENCE);
  assert.deepEqual(await verifyToken(await github.sign(claims), { audience: AUDIENCE, keys: github.keys }), claims);
  // An audience among others is the site's too.
  const several = buildClaims([AUDIENCE, "https://other.example"]);
  assert.deepEqual(await verifyToken(await github.sign(several), { audience: AUDIENCE, keys: github.keys }), several);
});

test("tokens that aren't GitHub's, or aren't for here and now, are refused", async () => {
  const github = await githubSigner();
  const refused = async (token, message) => {
    await assert.rejects(verifyToken(token, { audience: AUDIENCE, keys: github.keys }), (error) => {
      assert.ok(error instanceof TokenError, `${error}`);
      assert.match(error.message, message);
      return true;
    });
  };
  const now = Math.floor(Date.now() / 1000);
  await refused(await github.sign(buildClaims("https://other.example")), /another audience/);
  await refused(await github.sign(buildClaims(AUDIENCE, { iss: "https://example.com" })), /didn't issue/);
  await refused(await github.sign(buildClaims(AUDIENCE, { exp: now - 120 })), /expired/);
  await refused(await github.sign(buildClaims(AUDIENCE, { exp: undefined })), /expired/);
  await refused(await github.sign(buildClaims(AUDIENCE, { nbf: now + 120 })), /isn't valid yet/);
  await refused(await github.sign(buildClaims(AUDIENCE), { alg: "HS256" }), /RS256/);
  await refused(await github.sign(buildClaims(AUDIENCE), { kid: undefined }), /RS256/);

  // Claims changed after signing.
  const [head, , signature] = (await github.sign(buildClaims(AUDIENCE))).split(".");
  const changed = base64url(JSON.stringify(buildClaims(AUDIENCE, { repository: "someone/Atelier" })));
  await refused(`${head}.${changed}.${signature}`, /signature/);
  // Signed by someone else, with GitHub's key ID.
  const impostor = await githubSigner();
  await refused(await impostor.sign(buildClaims(AUDIENCE)), /signature/);

  for (const token of [undefined, "", "a.b", "a.b.c.d", "***.e30.e30", `${head}.e30`]) await refused(token, /JWT/);
  const none = `${base64url(JSON.stringify({ alg: "none", kid: "key-1" }))}.${base64url(JSON.stringify(buildClaims(AUDIENCE)))}.`;
  await refused(none, /RS256/);
});

test("a key GitHub doesn't have fetches its keys again, at most once a minute", async () => {
  const github = await githubSigner();
  const token = await github.sign(buildClaims(AUDIENCE));
  await verifyToken(token, { audience: AUDIENCE, keys: github.keys });
  await verifyToken(token, { audience: AUDIENCE, keys: github.keys });
  assert.equal(github.fetches, 1, "the keys are kept");

  const unknown = await github.sign(buildClaims(AUDIENCE), { kid: "key-2" });
  for (let i = 0; i < 3; i++) {
    await assert.rejects(verifyToken(unknown, { audience: AUDIENCE, keys: github.keys }), /key GitHub doesn't have/);
  }
  assert.equal(github.fetches, 1, "not within a minute of the last fetch");
  github.keys.fetched -= 61_000;
  await assert.rejects(verifyToken(unknown, { audience: AUDIENCE, keys: github.keys }), TokenError);
  assert.equal(github.fetches, 2);
});

test("GitHub's keys are fetched again after an hour, and kept while GitHub can't be reached", async () => {
  const github = await githubSigner();
  const token = await github.sign(buildClaims(AUDIENCE));
  await verifyToken(token, { audience: AUDIENCE, keys: github.keys });
  github.keys.fetched -= 61 * 60_000;
  github.answer = () => new Response("unavailable", { status: 503 });
  assert.ok(await verifyToken(token, { audience: AUDIENCE, keys: github.keys }));
  assert.equal(github.fetches, 2);
});

test("with no keys and GitHub out of reach, tokens can't be checked", async () => {
  const unreachable = new GitHubKeys(async () => {
    throw new TypeError("fetch failed");
  });
  const github = await githubSigner();
  await assert.rejects(verifyToken(await github.sign(buildClaims(AUDIENCE)), { audience: AUDIENCE, keys: unreachable }), KeysError);
  const broken = new GitHubKeys(async () => new Response("<html>", { status: 200 }));
  await assert.rejects(verifyToken(await github.sign(buildClaims(AUDIENCE)), { audience: AUDIENCE, keys: broken }), KeysError);
  const failing = new GitHubKeys(async () => new Response("", { status: 500 }));
  await assert.rejects(verifyToken(await github.sign(buildClaims(AUDIENCE)), { audience: AUDIENCE, keys: failing }), /HTTP 500/);
});

test("the site's own GitHubKeys calls fetch as the Workers runtime needs", async () => {
  // The runtime's fetch throws when it's called as a method of anything but
  // the global scope, which Node's doesn't check: this one does as it does.
  const github = await githubSigner();
  const fetched = [];
  const nodeFetch = globalThis.fetch;
  globalThis.fetch = function (input) {
    if (this !== undefined && this !== globalThis) {
      throw new TypeError("Illegal invocation: function called with incorrect `this` reference.");
    }
    fetched.push(String(input));
    return github.answer();
  };
  try {
    const claims = buildClaims(AUDIENCE);
    assert.deepEqual(await verifyToken(await github.sign(claims), { audience: AUDIENCE, keys: new GitHubKeys() }), claims);
    assert.deepEqual(fetched, [`${ISSUER}/.well-known/jwks`]);
  } finally {
    globalThis.fetch = nodeFetch;
  }
});

test("GitHub's issuer is token.actions.githubusercontent.com", () => {
  assert.equal(ISSUER, "https://token.actions.githubusercontent.com");
});
