// Tokens like the ones GitHub Actions gives a job (OpenID Connect), signed
// with a key made for the tests, which a GitHubKeys of the tests' own serves.

import { GitHubKeys, ISSUER } from "../src/github-oidc.js";

const encoder = new TextEncoder();

export function base64url(bytes) {
  const data = typeof bytes === "string" ? encoder.encode(bytes) : new Uint8Array(bytes);
  let binary = "";
  for (const byte of data) binary += String.fromCharCode(byte);
  return btoa(binary).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

/** A signing key, `kid`, served as GitHub serves its keys: {sign, keys,
 *  fetches}, where sign(claims, header) makes a token, `keys` is a
 *  GitHubKeys that fetches the key from a fake GitHub, and `fetches` counts
 *  its fetches. `answer` can change what the fake GitHub answers. */
export async function githubSigner(kid = "key-1") {
  const pair = await crypto.subtle.generateKey(
    { name: "RSASSA-PKCS1-v1_5", modulusLength: 2048, publicExponent: new Uint8Array([1, 0, 1]), hash: "SHA-256" },
    true,
    ["sign", "verify"],
  );
  const jwk = await crypto.subtle.exportKey("jwk", pair.publicKey);
  const signer = {
    fetches: 0,
    answer: () => Response.json({ keys: [{ ...jwk, kid, use: "sig", alg: "RS256", x5t: "x", x5c: ["y"] }] }),
    async sign(claims, header = {}) {
      const head = base64url(JSON.stringify({ typ: "JWT", alg: "RS256", kid, ...header }));
      const body = base64url(JSON.stringify(claims));
      const signature = await crypto.subtle.sign("RSASSA-PKCS1-v1_5", pair.privateKey, encoder.encode(`${head}.${body}`));
      return `${head}.${body}.${base64url(signature)}`;
    },
  };
  signer.keys = new GitHubKeys(async (url) => {
    signer.fetches += 1;
    if (url !== `${ISSUER}/.well-known/jwks`) throw new Error(`fetched ${url}`);
    return signer.answer();
  });
  return signer;
}

/** The claims of a token GitHub gives build.yml's job in a pull request's
 *  run of atelier.yml, for `audience`, with `changes`. */
export function buildClaims(audience, changes = {}) {
  const now = Math.floor(Date.now() / 1000);
  return {
    iss: ISSUER,
    aud: audience,
    iat: now,
    nbf: now - 5,
    exp: now + 300,
    repository: "atelierstore/Atelier",
    repository_id: "1453990179",
    repository_owner: "atelierstore",
    workflow_ref: "atelierstore/Atelier/.github/workflows/atelier.yml@refs/pull/12/merge",
    job_workflow_ref: "atelierstore/Atelier/.github/workflows/build.yml@refs/pull/12/merge",
    runner_environment: "github-hosted",
    event_name: "pull_request",
    ref: "refs/pull/12/merge",
    sha: "a".repeat(40),
    head_ref: "github-actions",
    base_ref: "main",
    run_id: "1000",
    run_attempt: "1",
    ...changes,
  };
}
