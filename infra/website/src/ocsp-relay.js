// Passes the certificate page's OCSP requests on to Apple (#152). Apple's
// responders only answer over plain HTTP and to no other site's pages, so
// the page (public/ocsp.js) can't ask them itself. Only Apple's responders
// are asked, and the answers aren't read here: the page checks they're
// signed by Apple. Nothing is stored or logged.

import { HEADERS, json } from "./http.js";

// Apple's responders, as developer certificates name them, such as
// http://ocsp.apple.com/ocsp03-wwdrg305.
const RESPONDER = /^http:\/\/ocsp\.apple\.com\/[A-Za-z0-9._-]+$/;
// A request about one certificate is about 100 bytes, and Apple's answers
// a few kilobytes.
const MAX_REQUEST = 1024;
const MAX_ANSWER = 64 << 10;

/** POST /ocsp?url=<responder>, with an OCSP request as the body: Apple's
 *  answer, as application/ocsp-response. A responder that isn't Apple's, or
 *  a request that isn't one, gets a 400, and when Apple can't be reached or
 *  answers with an error, a 502 with {error, status}, `status` being Apple's
 *  HTTP status, or null. `fetchImpl` is for tests. */
export async function ocspRelay(request, fetchImpl = fetch) {
  if (request.method !== "POST") return json({ error: "method not allowed" }, 405, { Allow: "POST" });
  const url = new URL(request.url).searchParams.get("url");
  if (!url || !RESPONDER.test(url)) return json({ error: "url isn't one of Apple's OCSP responders" }, 400);
  if (request.headers.get("Content-Type") !== "application/ocsp-request") return json({ error: "the body isn't an OCSP request" }, 400);
  const body = await read(request, MAX_REQUEST);
  if (!body?.length) return json({ error: "the body isn't an OCSP request" }, 400);

  let response;
  try {
    response = await fetchImpl(url, {
      method: "POST",
      headers: { "Content-Type": "application/ocsp-request", Accept: "application/ocsp-response" },
      body,
      signal: AbortSignal.timeout(10_000),
    });
  } catch {
    return json({ error: "Apple can't be reached.", status: null }, 502);
  }
  if (response.status !== 200) {
    response.body?.cancel().catch(() => {});
    return json({ error: `Apple answered HTTP ${response.status}.`, status: response.status }, 502);
  }
  let answer;
  try {
    answer = await read(response, MAX_ANSWER);
  } catch {
    return json({ error: "Apple can't be reached.", status: null }, 502);
  }
  if (!answer) return json({ error: "Apple's answer is too long.", status: 200 }, 502);
  return new Response(answer, { headers: { "Content-Type": "application/ocsp-response", ...HEADERS } });
}

/** A request's or response's body, or null when it's over `limit` bytes. */
async function read(message, limit) {
  if (Number(message.headers.get("Content-Length")) > limit) {
    message.body?.cancel().catch(() => {});
    return null;
  }
  const chunks = [];
  let size = 0;
  const reader = message.body?.getReader();
  for (;;) {
    const { done, value } = reader ? await reader.read() : { done: true };
    if (done) break;
    size += value.length;
    if (size > limit) {
      reader.cancel().catch(() => {});
      return null;
    }
    chunks.push(value);
  }
  const bytes = new Uint8Array(size);
  let p = 0;
  for (const chunk of chunks) {
    bytes.set(chunk, p);
    p += chunk.length;
  }
  return bytes;
}
