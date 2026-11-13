// What the site counts, for its Stats page (src/stats.js): every page loads
// this, which tells the site the page was viewed and, for a visit, from which
// site, or none, and on what kind of device. Then what's tapped on it: links
// and buttons marked data-tally="<what>", and any Donate button. The
// certificate page adds what happens to the certificate (tallyOnce). Nothing
// else is sent: no cookies, no IDs, and of where the visitor came from, only
// the site's name.

const ENDPOINT = "/tally";

/** "iphone", "ipad", "computer" or "other", from the browser's user agent
 *  and how many touches its screen takes: iPadOS's Safari says it's a Mac. */
export function deviceKind(agent, touchPoints = 0) {
  if (/iPhone|iPod/.test(agent)) return "iphone";
  if (/iPad/.test(agent) || (/Macintosh/.test(agent) && touchPoints > 1)) return "ipad";
  if (/Android|Mobile|Tablet/i.test(agent)) return "other";
  return "computer";
}

/** Where a view came from: null from another of the site's pages, or when
 *  the page was reloaded or gone back to, as that's no new visit; otherwise
 *  the name of the site the visitor came from, without www., or "" for none
 *  (typed, an app or a bookmark). */
export function visitFrom(referrer, origin, navigation) {
  if (navigation === "reload" || navigation === "back_forward") return null;
  if (!referrer) return "";
  try {
    const from = new URL(referrer);
    if (from.origin === origin) return null;
    return from.hostname.toLowerCase().replace(/^www\./, "");
  } catch {
    return "";
  }
}

function send(report) {
  const body = JSON.stringify({ page: location.pathname, ...report });
  try {
    // A beacon is sent even when the tap leaves the page.
    if (navigator.sendBeacon?.(ENDPOINT, body)) return;
  } catch {
    // Some browsers refuse beacons; fetch below.
  }
  fetch(ENDPOINT, { method: "POST", body, keepalive: true }).catch(() => {});
}

/** Counts `events`, names src/stats.js knows. */
export function tally(...events) {
  if (events.length) send({ events });
}

const once = new Set();

/** Counts `event` once while the page is open, however often it happens. */
export function tallyOnce(event) {
  if (once.has(event)) return;
  once.add(event);
  tally(event);
}

if (typeof document !== "undefined") {
  const navigation = (performance.getEntriesByType?.("navigation") ?? [])[0]?.type;
  send({
    from: visitFrom(document.referrer, location.origin, navigation),
    device: deviceKind(navigator.userAgent, navigator.maxTouchPoints),
  });
  // Pages Safari brings back from its cache don't run this again: they're
  // not counted again either.
  document.addEventListener("click", (event) => {
    const marked = event.target.closest?.("[data-tally], a[href='/donate']");
    if (marked) tally(marked.dataset.tally ?? "donate");
  });
}
