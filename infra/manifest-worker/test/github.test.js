import { test } from "node:test";
import assert from "node:assert/strict";

import worker from "../src/index.js";
import { token } from "../src/github.js";

const verifier = "a".repeat(43);

test("the callback hands the code and state to Atelier", async () => {
  const response = await worker.fetch(new Request("https://w.example/github/callback?code=abc123&state=s-1"));
  assert.equal(response.status, 302);
  assert.equal(response.headers.get("Location"), "atelier://github-sign-in?state=s-1&code=abc123");
});

test("the callback passes on GitHub's error", async () => {
  const response = await worker.fetch(new Request("https://w.example/github/callback?error=access_denied&state=s"));
  assert.equal(response.headers.get("Location"), "atelier://github-sign-in?state=s&error=access_denied");
});

test("the callback refuses odd values", async () => {
  for (const query of ["code=a", "code=a%22b&state=s", "state=s"]) {
    const response = await worker.fetch(new Request(`https://w.example/github/callback?${query}`));
    assert.equal(response.status, 400, query);
  }
});

test("the token exchange adds the secret and returns only the token", async () => {
  let sent;
  const fakeFetch = async (url, init) => {
    sent = { url, body: Object.fromEntries(init.body) };
    return new Response(JSON.stringify({ access_token: "gho_x", scope: "repo", token_type: "bearer" }));
  };
  const request = new Request("https://w.example/github/token", { method: "POST", body: JSON.stringify({ code: "abc", code_verifier: verifier }) });
  const response = await token(request, { GITHUB_CLIENT_ID: "id", GITHUB_CLIENT_SECRET: "secret" }, fakeFetch);
  assert.equal(response.status, 200);
  assert.deepEqual(await response.json(), { access_token: "gho_x", scope: "repo" });
  assert.equal(sent.url, "https://github.com/login/oauth/access_token");
  assert.deepEqual(sent.body, { client_id: "id", client_secret: "secret", code: "abc", code_verifier: verifier });
});

test("the token exchange passes on GitHub's error and checks its input", async () => {
  const fakeFetch = async () => new Response(JSON.stringify({ error: "bad_verification_code" }));
  const env = { GITHUB_CLIENT_ID: "id", GITHUB_CLIENT_SECRET: "secret" };
  const post = (body) => new Request("https://w.example/github/token", { method: "POST", body: JSON.stringify(body) });
  let response = await token(post({ code: "abc", code_verifier: verifier }), env, fakeFetch);
  assert.deepEqual(await response.json(), { error: "bad_verification_code" });
  response = await token(post({ code: "abc", code_verifier: "short" }), env, fakeFetch);
  assert.equal(response.status, 400);
  response = await token(post({ code: "abc", code_verifier: verifier }), {}, fakeFetch);
  assert.equal(response.status, 503);
});
