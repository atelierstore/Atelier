// What the Worker's own answers have in common. public/_headers covers
// static assets only.

/** The headers every answer of the Worker's has: nothing cached, nothing a
 *  page could load, and kept out of search results. */
export const HEADERS = {
  "Cache-Control": "no-store",
  "Content-Security-Policy": "default-src 'none'; frame-ancestors 'none'",
  "X-Content-Type-Options": "nosniff",
  "X-Robots-Tag": "noindex",
};

export function json(body, status, headers = {}) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "Content-Type": "application/json; charset=utf-8", ...HEADERS, ...headers },
  });
}
