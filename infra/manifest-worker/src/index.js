// Cloudflare Worker: stateless itms-services manifest endpoint, the token
// exchange for signing in to GitHub (#30, see github.js), the slow
// answer that relaunches Atelier after it installed itself (#24, see
// relaunch.js), and the anisette servers to sign in to Apple through (#49,
// see anisette.js).
// Nothing is stored or logged; every request is answered from itself.

import { anisette } from "./anisette.js";
import { callback, token } from "./github.js";
import { buildManifest, ManifestError, paramsFromSearch } from "./manifest.js";
import { relaunch } from "./relaunch.js";

const ROUTES = new Set(["/manifest", "/genPlist"]);

export default {
  async fetch(request, env = {}) {
    const url = new URL(request.url);

    if (url.pathname === "/github/callback") {
      return request.method === "GET" ? callback(url) : text("method not allowed", 405, { Allow: "GET" });
    }
    if (url.pathname === "/github/token") {
      return request.method === "POST" ? token(request, env) : text("method not allowed", 405, { Allow: "POST" });
    }

    if (request.method !== "GET" && request.method !== "HEAD") {
      return text("method not allowed", 405, { Allow: "GET, HEAD" });
    }
    if (url.pathname === "/relaunch") {
      return relaunch(url);
    }
    if (url.pathname === "/anisette") {
      return anisette(request);
    }
    if (!ROUTES.has(url.pathname)) {
      return text("not found", 404);
    }

    try {
      const body = buildManifest(paramsFromSearch(url.searchParams));
      return new Response(request.method === "HEAD" ? null : body, {
        status: 200,
        headers: {
          "Content-Type": "application/xml; charset=utf-8",
          "Cache-Control": "no-store",
          "X-Content-Type-Options": "nosniff",
        },
      });
    } catch (error) {
      if (error instanceof ManifestError) {
        return text(error.message, 400);
      }
      throw error;
    }
  },
};

function text(body, status, extraHeaders = {}) {
  return new Response(body, {
    status,
    headers: {
      "Content-Type": "text/plain; charset=utf-8",
      "Cache-Control": "no-store",
      ...extraHeaders,
    },
  });
}
