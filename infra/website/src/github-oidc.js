// Checks the tokens GitHub Actions gives a job to prove which repo, workflow
// and run it is (OpenID Connect): a JWT that GitHub signs with RS256, with one
// of the keys it publishes at https://token.actions.githubusercontent.com/
// .well-known/jwks. The job asks for one with the audience it's for, here the
// site's origin, and sends it as a bearer token (scripts/share_build.py).

/** Who issues the tokens, as their `iss` says. */
export const ISSUER = "https://token.actions.githubusercontent.com";
/** How far the site's clock and GitHub's may differ, in seconds. */
const LEEWAY = 60;
/** How long GitHub's keys are kept before they're fetched again. */
const KEYS_LIFETIME = 60 * 60 * 1000;
/** A token signed with a key the site doesn't have fetches GitHub's keys
 *  again, as GitHub adds new keys before signing with them, but at most once
 *  a minute, so made-up key IDs can't make the site ask GitHub all the time. */
const REFETCH_AFTER = 60 * 1000;

/** The token isn't one of GitHub's, or isn't for here or now. */
export class TokenError extends Error {}

/** GitHub's keys can't be read, so no token can be checked for now. */
export class KeysError extends Error {}

/** GitHub's signing keys, fetched when needed and kept for an hour. One set
 *  per Worker instance is enough; tests make their own with a fetch of their
 *  own. */
export class GitHubKeys {
  // fetch through a function of its own: refresh() calls this.fetchImpl as
  // a method, and the Workers runtime's fetch throws "Illegal invocation"
  // when it's called on anything but the global scope.
  constructor(fetchImpl = (input, init) => fetch(input, init)) {
    this.fetchImpl = fetchImpl;
    this.keys = new Map();
    this.fetched = -Infinity;
  }

  async key(kid) {
    const age = Date.now() - this.fetched;
    if (age > KEYS_LIFETIME || (!this.keys.has(kid) && age > REFETCH_AFTER)) {
      try {
        await this.refresh();
      } catch (error) {
        // An hour-old key still checks a token while GitHub can't be asked.
        if (!this.keys.has(kid)) throw error;
      }
    }
    const key = this.keys.get(kid);
    if (!key) throw new TokenError("it's signed with a key GitHub doesn't have");
    return key;
  }

  async refresh() {
    let response;
    try {
      response = await this.fetchImpl(`${ISSUER}/.well-known/jwks`, {
        headers: { Accept: "application/json", "User-Agent": "Atelier" },
        signal: AbortSignal.timeout(10_000),
      });
    } catch {
      throw new KeysError("GitHub's keys can't be reached");
    }
    if (!response.ok) throw new KeysError(`GitHub's keys: HTTP ${response.status}`);
    let list;
    try {
      ({ keys: list } = await response.json());
    } catch {
      throw new KeysError("GitHub's keys aren't JSON");
    }
    const keys = new Map();
    for (const jwk of Array.isArray(list) ? list : []) {
      if (jwk?.kty !== "RSA" || typeof jwk.kid !== "string") continue;
      try {
        keys.set(jwk.kid, await crypto.subtle.importKey(
          "jwk",
          // Only what makes the key: its `use`, `x5c` and the rest aren't
          // needed, and some runtimes refuse fields they don't expect.
          { kty: "RSA", n: jwk.n, e: jwk.e, alg: "RS256", ext: true },
          { name: "RSASSA-PKCS1-v1_5", hash: "SHA-256" },
          false,
          ["verify"],
        ));
      } catch {
        // A key that can't be read signs nothing that's checked here.
      }
    }
    this.keys = keys;
    this.fetched = Date.now();
  }
}

/** The claims of `token`, once it's checked as one of GitHub's, for
 *  `audience`, and current. Throws a TokenError when it isn't, and a
 *  KeysError when GitHub's keys can't be read. */
export async function verifyToken(token, { audience, keys, now = Date.now() }) {
  const parts = typeof token === "string" ? token.split(".") : [];
  if (parts.length !== 3) throw new TokenError("it isn't a JWT");
  const [header, claims, signature] = [decodeJSON(parts[0]), decodeJSON(parts[1]), decode(parts[2])];
  if (header?.alg !== "RS256" || typeof header.kid !== "string") throw new TokenError("it isn't signed with RS256");
  const signed = new TextEncoder().encode(`${parts[0]}.${parts[1]}`);
  const key = await keys.key(header.kid);
  if (!(await crypto.subtle.verify("RSASSA-PKCS1-v1_5", key, signature, signed))) throw new TokenError("its signature isn't GitHub's");

  if (!claims || typeof claims !== "object") throw new TokenError("its claims can't be read");
  if (claims.iss !== ISSUER) throw new TokenError("GitHub Actions didn't issue it");
  const audiences = Array.isArray(claims.aud) ? claims.aud : [claims.aud];
  if (!audiences.includes(audience)) throw new TokenError(`it's for another audience than ${audience}`);
  const seconds = now / 1000;
  if (!(typeof claims.exp === "number" && claims.exp + LEEWAY > seconds)) throw new TokenError("it has expired");
  if (typeof claims.nbf === "number" && claims.nbf - LEEWAY > seconds) throw new TokenError("it isn't valid yet");
  return claims;
}

/** The bytes of a base64url part, or a TokenError. */
function decode(part) {
  if (!/^[A-Za-z0-9_-]*$/.test(part)) throw new TokenError("it isn't a JWT");
  try {
    const base64 = part.replace(/-/g, "+").replace(/_/g, "/") + "===".slice((part.length + 3) % 4);
    return Uint8Array.from(atob(base64), (character) => character.charCodeAt(0));
  } catch {
    throw new TokenError("it isn't a JWT");
  }
}

function decodeJSON(part) {
  try {
    return JSON.parse(new TextDecoder().decode(decode(part)));
  } catch {
    throw new TokenError("it isn't a JWT");
  }
}
