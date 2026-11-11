// The home page, by where the visitor is. Get Atelier lists AltStore PAL,
// which is planned, last; for visitors where Apple allows alternative app
// marketplaces such as AltStore PAL, it comes first, recommended in their
// country. Cloudflare places each request in a country by its IP address
// (request.cf.country, the same as the CF-IPCountry header), so the page
// comes the right way round, with no script and nothing stored.

/** Where Apple allows alternative app marketplaces, by ISO 3166 code, with
 *  each one's name as the page shows it: the EU's countries and regions, as
 *  Apple lists them (support.apple.com/121575; the Azores, Madeira and the
 *  Canary Islands come as PT and ES), Japan and Brazil
 *  (support.apple.com/118110). Not Norway, Iceland or Liechtenstein, which
 *  are in the EEA but not the EU. Apple also wants the Apple Account set to
 *  one of them, which a website can't see. */
export const PAL_COUNTRIES = Object.freeze({
  AT: "Austria",
  BE: "Belgium",
  BG: "Bulgaria",
  HR: "Croatia",
  CY: "Cyprus",
  CZ: "Czechia",
  DK: "Denmark",
  EE: "Estonia",
  FI: "Finland",
  AX: "the Åland Islands",
  FR: "France",
  GF: "French Guiana",
  GP: "Guadeloupe",
  MQ: "Martinique",
  YT: "Mayotte",
  RE: "Réunion",
  MF: "Saint Martin",
  DE: "Germany",
  GR: "Greece",
  HU: "Hungary",
  IE: "Ireland",
  IT: "Italy",
  LV: "Latvia",
  LT: "Lithuania",
  LU: "Luxembourg",
  MT: "Malta",
  NL: "the Netherlands",
  PL: "Poland",
  PT: "Portugal",
  RO: "Romania",
  SK: "Slovakia",
  SI: "Slovenia",
  ES: "Spain",
  SE: "Sweden",
  JP: "Japan",
  BR: "Brazil",
});

/** The name of the country Cloudflare places `request` in, when Apple
 *  allows alternative app marketplaces there, or null: elsewhere, and when
 *  Cloudflare can't tell, as for Tor ("T1") or an unknown address ("XX"). */
export function palCountry(request) {
  const code = request.cf?.country;
  return typeof code === "string" && Object.hasOwn(PAL_COUNTRIES, code) ? PAL_COUNTRIES[code] : null;
}

/** The home page's HTML, `html`, for a visitor in `country`, where Apple
 *  allows AltStore PAL: the items marked data-pal-here shown (AltStore PAL,
 *  recommended, and Until then), the country's name in data-pal-country,
 *  and the AltStore PAL item for everyone else, between the not-pal
 *  comments, gone. */
export function palPage(html, country) {
  return html
    .replaceAll(" data-pal-here hidden>", " data-pal-here>")
    .replace(/(<span data-pal-country>)[^<]*(<\/span>)/, `$1${country}$2`)
    .replace(/\n[ \t]*<!-- not-pal -->[\s\S]*?<!-- \/not-pal -->/, "");
}

/** The response to `request` for the home page, from `assets`
 *  (env.ASSETS): public/index.html as it is, or, for a visitor where Apple
 *  allows AltStore PAL, with it first (palPage). */
export async function homePage(request, assets) {
  const country = palCountry(request);
  if (!country) return assets.fetch(request);
  // Without the browser's validators, so assets sends the page rather than
  // a 304 for the file as it is, which this visitor doesn't get.
  const headers = new Headers(request.headers);
  headers.delete("If-None-Match");
  headers.delete("If-Modified-Since");
  const page = await assets.fetch(new Request(request, { headers }));
  if (page.status !== 200) return page;
  const out = new Headers(page.headers);
  // They're the file's, and this page differs from it.
  out.delete("Content-Length");
  out.delete("ETag");
  const body = request.method === "HEAD" ? null : palPage(await page.text(), country);
  return new Response(body, { status: 200, headers: out });
}
