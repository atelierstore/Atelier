// Signing in to GitHub from Atelier (#30): GitHub's web sign-in for OAuth
// apps needs the app's client secret to turn the sign-in's code into a token,
// and a secret built into the app could be read out of it. So the secret
// lives here, as the Worker secret GITHUB_CLIENT_SECRET, next to the
// GITHUB_CLIENT_ID variable. Nothing is stored or logged.
//
// 1. Atelier opens github.com/login/oauth/authorize with this Worker's
//    /github/callback as redirect_uri, a random state and a PKCE challenge.
// 2. GitHub sends the browser to /github/callback?code=…&state=…, which
//    hands both to Atelier as atelier://github-sign-in?code=…&state=….
// 3. Atelier posts the code and its PKCE verifier to /github/token, which
//    asks GitHub for the token with the secret and returns it.
// A code is useless without the verifier, which never leaves the phone
// until step 3, and GitHub accepts each code once.

export const APP_CALLBACK = "atelier://github-sign-in";
const TOKEN_URL = "https://github.com/login/oauth/access_token";
// GitHub's codes and Atelier's states and verifiers: letters, digits, - . _ ~
const SAFE = /^[A-Za-z0-9._~-]{1,256}$/;

/** GET /github/callback: passes GitHub's answer on to Atelier. */
export function callback(url) {
  const target = new URL(APP_CALLBACK);
  const error = url.searchParams.get("error");
  const code = url.searchParams.get("code");
  const state = url.searchParams.get("state");
  if (!state || !SAFE.test(state)) {
    return plain("missing or invalid state", 400);
  }
  target.searchParams.set("state", state);
  if (error) {
    target.searchParams.set("error", SAFE.test(error) ? error : "error");
  } else if (code && SAFE.test(code)) {
    target.searchParams.set("code", code);
  } else {
    return plain("missing or invalid code", 400);
  }
  return new Response(null, {
    status: 302,
    headers: { Location: target.toString(), "Cache-Control": "no-store", "Referrer-Policy": "no-referrer" },
  });
}

/** POST /github/token with JSON {code, code_verifier}: the token, from GitHub. */
export async function token(request, env, fetchImpl = fetch) {
  if (!env.GITHUB_CLIENT_ID || !env.GITHUB_CLIENT_SECRET) {
    return json({ error: "not_configured" }, 503);
  }
  let body;
  try {
    body = await request.json();
  } catch {
    return json({ error: "bad_request" }, 400);
  }
  const code = body?.code;
  const verifier = body?.code_verifier;
  if (typeof code !== "string" || !SAFE.test(code) || typeof verifier !== "string" || !/^[A-Za-z0-9._~-]{43,128}$/.test(verifier)) {
    return json({ error: "bad_request" }, 400);
  }
  const response = await fetchImpl(TOKEN_URL, {
    method: "POST",
    headers: { Accept: "application/json", "Content-Type": "application/x-www-form-urlencoded", "User-Agent": "Atelier" },
    body: new URLSearchParams({
      client_id: env.GITHUB_CLIENT_ID,
      client_secret: env.GITHUB_CLIENT_SECRET,
      code,
      code_verifier: verifier,
    }),
  });
  let answer;
  try {
    answer = await response.json();
  } catch {
    return json({ error: "github_unavailable" }, 502);
  }
  if (typeof answer.access_token === "string" && answer.access_token) {
    return json({ access_token: answer.access_token, scope: answer.scope ?? "" }, 200);
  }
  return json({ error: typeof answer.error === "string" ? answer.error : "no_token" }, 400);
}

function json(object, status) {
  return new Response(JSON.stringify(object), {
    status,
    headers: { "Content-Type": "application/json", "Cache-Control": "no-store" },
  });
}

function plain(body, status) {
  return new Response(body, { status, headers: { "Content-Type": "text/plain; charset=utf-8", "Cache-Control": "no-store" } });
}
