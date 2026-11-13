// The Stats page (stats.html): the site's own counts, which /stats/data sums
// up (src/stats.js), for the last 7 days, 30 days or 12 months. The page
// asks for the stats key once and keeps it in this browser.

const $ = (id) => document.getElementById(id);
const KEY = "atelier-stats-key";
const PERIOD = "atelier-stats-days";

const PAGES = {
  "home": "Home",
  "certificate": "Certificate",
  "certificate-install": "Certificate, from a computer's code",
  "apple-id": "Apple ID",
  "sideload": "Sideload",
  "signing-services": "For signing services",
  "install": "Install links",
  "source": "Source links",
  "viewapp": "App links",
  "search": "Search links",
  "notfound": "Not found",
};
const ROUTES = [
  ["route-certificate", "With a signing service"],
  ["route-apple-id", "With your Apple ID"],
  ["route-sideload", "I already know how to sideload"],
  ["signing-services", "Run a signing service?"],
];
const SIDELOAD = [
  ["download-ipa", "Download the IPA"],
  ["copy-source", "Copy the source"],
  ["add-sidestore", "Add to SideStore"],
  ["add-altstore", "Add to AltStore"],
  ["add-feather", "Add to Feather"],
];
const HELD = [
  ["certificate-expired", "Expired"],
  ["certificate-revoked", "Revoked"],
  ["certificate-other-profile", "Profile for another certificate"],
  ["certificate-app-store", "App Store profile"],
  ["certificate-unreadable", "Can't be read"],
];
const DEVICES = [
  ["iphone", "iPhone"],
  ["computer", "Computer"],
  ["ipad", "iPad"],
  ["other", "Other phones and tablets"],
];

const number = new Intl.NumberFormat("en");
const regions = new Intl.DisplayNames(["en"], { type: "region" });

function stored(name) {
  try {
    return localStorage.getItem(name);
  } catch {
    return null;
  }
}

function store(name, value) {
  try {
    if (value === null) localStorage.removeItem(name);
    else localStorage.setItem(name, value);
  } catch {
    // Private windows can refuse it: the page asks again next time.
  }
}

let key = stored(KEY);
let days = [7, 30, 365].includes(Number(stored(PERIOD))) ? Number(stored(PERIOD)) : 30;
let loads = 0;

// MARK: The key

$("key-form").addEventListener("submit", (event) => {
  event.preventDefault();
  key = $("key").value.trim();
  if (!key) return;
  load();
});

function askForKey(problem) {
  $("stats").hidden = true;
  $("range").hidden = true;
  $("key-form").hidden = false;
  $("key-field").classList.toggle("problem", Boolean(problem));
  showProblem("key-problem", problem);
  $("key").focus();
}

function showProblem(id, message) {
  const element = $(id);
  element.querySelector("span").textContent = message ?? "";
  element.hidden = !message;
}

// MARK: The period

for (const button of $("range").querySelectorAll("button")) {
  button.addEventListener("click", () => {
    days = Number(button.dataset.days);
    store(PERIOD, String(days));
    load();
  });
}

function showPeriod() {
  for (const button of $("range").querySelectorAll("button")) {
    button.setAttribute("aria-pressed", String(Number(button.dataset.days) === days));
  }
}

// MARK: Loading

async function load() {
  const load = ++loads;
  showPeriod();
  showProblem("problem", null);
  let response;
  try {
    response = await fetch(`/stats/data?days=${days}`, { headers: { Authorization: `Bearer ${key}` }, cache: "no-store" });
  } catch {
    if (load === loads) showProblem("problem", "The stats couldn't be loaded. Check your connection and reload the page.");
    return;
  }
  if (load !== loads) return;
  if (response.status === 401) {
    store(KEY, null);
    return askForKey($("key-form").hidden ? null : "That isn't the website's stats key.");
  }
  if (!response.ok) {
    const { error } = await response.json().catch(() => ({}));
    $("key-form").hidden = true;
    return showProblem("problem", error ?? `The stats couldn't be loaded (HTTP ${response.status}). Reload the page to try again.`);
  }
  const summary = await response.json();
  if (load !== loads) return;
  store(KEY, key);
  $("key-form").hidden = true;
  $("range").hidden = false;
  $("stats").hidden = false;
  show(summary);
}

// MARK: Showing them

function show({ from, to, daily, totals }) {
  const count = (name) => totals[name] ?? 0;
  const event = (name) => count(`event:${name}`);
  const visits = count("visit");
  const views = daily.reduce((sum, [, , dayViews]) => sum + dayViews, 0);

  $("tile-visits").textContent = number.format(visits);
  $("tile-views").textContent = number.format(views);
  $("tile-installs").textContent = number.format(event("install-downloaded"));
  $("tile-downloads").textContent = number.format(event("download-ipa"));
  $("tile-donate").textContent = number.format(event("donate"));

  showChart(daily, from, to);

  const routes = ROUTES.map(([name, label]) => [label, event(name)]);
  const routeTaps = routes.reduce((sum, [, n]) => sum + n, 0);
  rows("routes", routes.map(([label, n]) => ({ label, n, share: n / routeTaps })));
  const home = count("view:home");
  const pal = count("view:home:pal");
  $("pal").replaceChildren("Saw AltStore PAL first: ", strong(number.format(pal)), ` of ${number.format(home)} home page views${home ? ` (${percent(pal / home)})` : ""}`);

  const opened = count("view:certificate");
  const signs = event("sign-iphone") + event("sign-computer");
  const funnel = [
    ["Opened the page", opened],
    ["Chose a certificate", event("certificate-chosen")],
    ["Certificate accepted", event("certificate-accepted")],
    ["Sign and Install", signs],
    ["iOS asked to install", event("install-asked")],
    ["iOS downloaded Atelier", event("install-downloaded")],
  ];
  rows("funnel", funnel.map(([label, n], index) => ({ label, n, bar: opened ? n / opened : 0, share: index && opened ? n / opened : null })));
  const held = HELD.map(([name, label]) => [label, event(name)]).filter(([, n]) => n);
  $("held").textContent = number.format(held.reduce((sum, [, n]) => sum + n, 0));
  $("reasons").replaceChildren(...held.map(([label, n]) => {
    const chip = document.createElement("span");
    chip.textContent = `${label} ${number.format(n)}`;
    return chip;
  }));
  $("reasons").hidden = !held.length;
  $("computer").replaceChildren("From a computer, by QR code: ", strong(number.format(event("sign-computer"))), ` of ${number.format(signs)}`);

  const sideloadViews = count("view:sideload");
  $("sideload-note").textContent = `Taps, out of ${number.format(sideloadViews)} ${sideloadViews === 1 ? "view" : "views"}.`;
  const sideload = SIDELOAD.map(([name, label]) => ({ label, n: event(name) })).sort((a, b) => b.n - a.n);
  rows("sideload", sideload.map((row) => ({ ...row, bar: row.n / (sideload[0].n || 1) })));

  const pages = Object.entries(PAGES).map(([name, label]) => ({ label, n: count(`view:${name}`) })).filter((row) => row.n).sort((a, b) => b.n - a.n);
  rows("pages", pages.map((row) => ({ ...row, bar: row.n / pages[0].n })));

  const sources = top(prefixed(totals, "visit:from:"), 6, (name) => (name === "none" ? "No site (typed, an app or a bookmark)" : name), "others");
  rows("from", sources.map((row) => ({ ...row, share: row.n / visits })));

  const countries = top(prefixed(totals, "visit:country:"), 7, region, null);
  rows("countries", countries.map((row) => ({ ...row, share: row.n / visits })));

  rows("devices", DEVICES.map(([name, label]) => ({ label, n: count(`visit:device:${name}`) })).filter((row) => row.n).map((row) => ({ ...row, share: row.n / visits })));
}

/** {name: count} for the totals whose names start with `prefix`, without it. */
function prefixed(totals, prefix) {
  return Object.fromEntries(Object.entries(totals).filter(([name]) => name.startsWith(prefix)).map(([name, n]) => [name.slice(prefix.length), n]));
}

/** The `size` largest of `counts`, labelled, then the rest as one row:
 *  "Others", with `othersName`'s own count, or "N others". */
function top(counts, size, label, othersName) {
  const entries = Object.entries(counts).sort((a, b) => b[1] - a[1]);
  const named = entries.filter(([name]) => name !== othersName);
  const shown = named.slice(0, size).map(([name, n]) => ({ label: label(name), n }));
  const rest = named.slice(size);
  const others = rest.reduce((sum, [, n]) => sum + n, othersName ? counts[othersName] ?? 0 : 0);
  if (others) shown.push({ label: othersName ? "Others" : `${rest.length} others`, n: others });
  return shown;
}

function region(code) {
  if (code === "XX") return "Unknown";
  try {
    return regions.of(code) ?? code;
  } catch {
    return code;
  }
}

/** Fills the list `id` with rows of {label, n, share, bar}: the count, its
 *  share as a percentage when there is one, and a bar `bar` (or `share`)
 *  of the width. */
function rows(id, items) {
  const list = $(id);
  if (!items.length || items.every((item) => !item.n)) {
    const empty = document.createElement("li");
    empty.className = "stats-empty";
    empty.textContent = "Nothing counted yet.";
    return list.replaceChildren(empty);
  }
  list.replaceChildren(...items.map(({ label, n, share, bar }) => {
    const item = document.createElement("li");
    const name = document.createElement("span");
    name.textContent = label;
    const value = document.createElement("span");
    value.className = "v";
    value.textContent = number.format(n);
    if (Number.isFinite(share)) {
      const small = document.createElement("small");
      small.textContent = percent(share);
      value.append(small);
    }
    const track = document.createElement("span");
    track.className = "b";
    const fill = document.createElement("i");
    const fraction = bar ?? share;
    fill.style.width = `${Number.isFinite(fraction) ? Math.max(0, Math.min(1, fraction)) * 100 : 0}%`;
    track.append(fill);
    item.append(name, value, track);
    return item;
  }));
}

function percent(fraction) {
  if (!Number.isFinite(fraction)) return "";
  const value = fraction * 100;
  return `${value > 0 && value < 1 ? "<1" : Math.round(value)}%`;
}

function strong(text) {
  const element = document.createElement("strong");
  element.textContent = text;
  return element;
}

// MARK: The chart

const SVG = "http://www.w3.org/2000/svg";
const shortDate = new Intl.DateTimeFormat("en-GB", { day: "numeric", month: "short", timeZone: "UTC" });
const longDate = new Intl.DateTimeFormat("en-GB", { day: "numeric", month: "short", year: "numeric", timeZone: "UTC" });
const monthName = new Intl.DateTimeFormat("en-GB", { month: "short", timeZone: "UTC" });

/** Visits per day, or per month for 12 months, today's (or this month's)
 *  bar standing out, as it isn't over yet. */
function showChart(daily, from, to) {
  const byMonth = daily.length > 60;
  let bars = daily.map(([day, visits]) => ({ day, visits }));
  if (byMonth) {
    const months = new Map();
    for (const { day, visits } of bars) months.set(day.slice(0, 7), (months.get(day.slice(0, 7)) ?? 0) + visits);
    bars = [...months].map(([month, visits]) => ({ day: `${month}-01`, visits }));
  }
  const dates = byMonth ? longDate : shortDate;
  $("chart-title").textContent = byMonth ? "Visits per month" : "Visits per day";
  $("chart-period").textContent = `${dates.format(new Date(from))} to ${dates.format(new Date(to))}.`;
  const chart = $("chart");
  const height = 190;
  const most = Math.max(1, ...bars.map((bar) => bar.visits));
  const step = niceStep(most);
  const ceiling = Math.ceil(most / step) * step;
  const width = 600 / bars.length;
  const lines = [];
  for (let y = 0; y <= ceiling; y += step) {
    const line = document.createElementNS(SVG, "line");
    const at = height - (y / ceiling) * (height - 1);
    for (const [name, value] of [["x1", 0], ["x2", 600], ["y1", at], ["y2", at]]) line.setAttribute(name, value);
    lines.push(line);
  }
  const rects = bars.map(({ visits }, index) => {
    const rect = document.createElementNS(SVG, "rect");
    const barHeight = (visits / ceiling) * (height - 1);
    for (const [name, value] of [["x", index * width + width * 0.14], ["width", width * 0.72], ["y", height - barHeight], ["height", barHeight], ["rx", 2]]) {
      rect.setAttribute(name, value);
    }
    if (index === bars.length - 1) rect.classList.add("today");
    return rect;
  });
  chart.replaceChildren(...lines, ...rects);

  // Under each bar for 7 days and by month, every other month's, counting
  // back from this one; five dates spread out for 30 days.
  const axis = $("axis");
  const perBar = byMonth || bars.length <= 7;
  const labels = perBar
    ? bars.map(({ day }, index) => {
      if (!byMonth) return shortDate.format(new Date(day));
      return (bars.length - 1 - index) % 2 ? "" : monthName.format(new Date(day));
    })
    : spaced(bars.map(({ day }) => shortDate.format(new Date(day))), 5);
  axis.classList.toggle("per-bar", perBar);
  axis.style.gridTemplateColumns = perBar ? `repeat(${bars.length}, minmax(0, 1fr))` : "";
  axis.replaceChildren(...labels.map((label) => {
    const span = document.createElement("span");
    span.textContent = label;
    return span;
  }));
}

/** 1, 2 or 5 times a power of ten, for about 3 grid lines up to `most`. */
function niceStep(most) {
  const rough = most / 3;
  const power = 10 ** Math.floor(Math.log10(rough));
  return [1, 2, 5, 10].map((m) => m * power).find((step) => step >= rough) ?? power * 10;
}

/** `count` of `labels`, evenly spaced from the first to the last. */
function spaced(labels, count) {
  return Array.from({ length: count }, (_, i) => labels[Math.round((i * (labels.length - 1)) / (count - 1))]);
}

// MARK: Starting

if (key) load();
else askForKey(null);
