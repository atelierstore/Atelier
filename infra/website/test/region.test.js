import { test } from "node:test";
import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";

import worker from "../src/index.js";
import { PAL_COUNTRIES, homePage, palCountry, palPage } from "../src/region.js";

const HOME = await readFile(new URL("../public/index.html", import.meta.url), "utf8");

/** A request for the home page from `country`, as Cloudflare places it. */
function from(country, init = {}) {
  const request = new Request("https://atelierstore.app/", init);
  // Workers set request.cf; Node's Request has none.
  Object.defineProperty(request, "cf", { value: country === undefined ? undefined : { country } });
  return request;
}

/** env.ASSETS with the home page as Workers static assets serves it, and
 *  the requests it got. */
function assets(status = 200, body = HOME) {
  const requests = [];
  return {
    requests,
    async fetch(request) {
      requests.push(request);
      return new Response(status === 304 ? null : body, {
        status,
        headers: { "Content-Type": "text/html", ETag: '"file"', "Content-Length": String(body.length), "Cache-Control": "public, max-age=0, must-revalidate" },
      });
    },
  };
}

test("the EU's countries and regions, Japan and Brazil are where Apple allows AltStore PAL", () => {
  assert.equal(Object.keys(PAL_COUNTRIES).length, 27 + 7 + 2);
  assert.equal(palCountry(from("GR")), "Greece");
  assert.equal(palCountry(from("NL")), "the Netherlands");
  assert.equal(palCountry(from("RE")), "Réunion");
  assert.equal(palCountry(from("AX")), "the Åland Islands");
  assert.equal(palCountry(from("JP")), "Japan");
  assert.equal(palCountry(from("BR")), "Brazil");
});

test("elsewhere, and when Cloudflare can't tell, isn't", () => {
  for (const country of ["GB", "US", "AU", "CH", "NO", "IS", "LI", "XX", "T1", "", "gr", "constructor", "toString"]) {
    assert.equal(palCountry(from(country)), null, country);
  }
  assert.equal(palCountry(from(undefined)), null);
  assert.equal(palCountry(new Request("https://atelierstore.app/")), null);
});

test("the home page lists AltStore PAL last, until the Worker says where the visitor is", () => {
  const routes = HOME.slice(HOME.indexOf('<ul class="routes"'), HOME.indexOf("</ul>", HOME.indexOf('<ul class="routes"')));
  assert.equal(routes.match(/From AltStore PAL/g).length, 2);
  // The recommended one and Until then are hidden.
  assert.equal(routes.match(/ data-pal-here hidden>/g).length, 2);
  assert.ok(routes.indexOf("<!-- not-pal -->") > routes.indexOf('href="/sideload"'));
  assert.match(routes, /<!-- not-pal -->\s*<li class="route">[\s\S]*From AltStore PAL[\s\S]*<!-- \/not-pal -->\s*$/);
});

test("where Apple allows it, the home page has AltStore PAL first, recommended in the visitor's country", () => {
  const page = palPage(HOME, "Greece");
  assert.equal(page.match(/From AltStore PAL/g).length, 1);
  assert.doesNotMatch(page, /data-pal-here hidden/);
  assert.doesNotMatch(page, /<!-- \/?not-pal -->/);
  assert.match(page, /Recommended in <span data-pal-country>Greece<\/span>/);
  const pal = page.indexOf("From AltStore PAL");
  const untilThen = page.indexOf(">Until then<");
  assert.ok(pal < untilThen && untilThen < page.indexOf('href="/certificate"'));
  // Only the list changed.
  assert.equal(page.slice(0, page.indexOf('<ul class="routes"')), HOME.slice(0, HOME.indexOf('<ul class="routes"')));
  assert.equal(page.slice(page.indexOf("</ul>", pal)), HOME.slice(HOME.indexOf("</ul>", HOME.indexOf("<!-- /not-pal -->"))));
});

test("elsewhere the Worker passes the home page on as it is", async () => {
  const files = assets();
  const request = from("US", { headers: { "If-None-Match": '"file"' } });
  const response = await homePage(request, files);
  assert.equal(files.requests[0], request);
  assert.equal(response.headers.get("ETag"), '"file"');
  assert.equal(await response.text(), HOME);
});

test("where Apple allows AltStore PAL, the Worker sends the page with it first, without the file's validators", async () => {
  const files = assets();
  const response = await homePage(from("JP", { headers: { "If-None-Match": '"file"', "If-Modified-Since": "Wed, 11 Nov 2026 10:00:00 GMT", Accept: "text/html" } }), files);
  assert.equal(files.requests[0].headers.get("If-None-Match"), null);
  assert.equal(files.requests[0].headers.get("If-Modified-Since"), null);
  assert.equal(files.requests[0].headers.get("Accept"), "text/html");
  assert.equal(response.status, 200);
  assert.equal(response.headers.get("ETag"), null);
  assert.equal(response.headers.get("Content-Type"), "text/html");
  assert.equal(response.headers.get("Cache-Control"), "public, max-age=0, must-revalidate");
  assert.equal(await response.text(), palPage(HOME, "Japan"));
});

test("a HEAD request gets the headers alone, and what isn't a 200 goes back as it is", async () => {
  const head = await homePage(from("FR", { method: "HEAD" }), assets());
  assert.equal(head.status, 200);
  assert.equal(head.body, null);
  const missing = await homePage(from("FR"), assets(404, "Not found"));
  assert.equal(missing.status, 404);
  assert.equal(await missing.text(), "Not found");
});

test("the Worker serves the home page", async () => {
  const files = assets();
  const response = await worker.fetch(from("BR"), { ASSETS: files }, {});
  assert.match(await response.text(), /Recommended in <span data-pal-country>Brazil<\/span>/);
});
