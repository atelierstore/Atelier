// The app link page (viewapp.html, at /viewapp): Atelier's
// atelier://viewapp?bundleid=… link as an https:// one (see link.js).
// /viewapp?bundleid=<bundle ID>&source=<source> opens
// atelier://viewapp?bundleid=<bundle ID>&source=<source>, which shows the
// app in Atelier, as AltStore's links to an app do. The source it comes
// from is Atelier's own addition: without it, Atelier shows it to add
// first, then the app from it.
//
// The link is read as Atelier reads atelier://viewapp (StoreLink in
// SourceKit): its items' names in any case, their values percent-encoded,
// the last of each. The page doesn't judge the source: Atelier says what's
// wrong with it, if anything, when it shows it to add.
//
// Then the website's Worker reads the app from an AltStore source
// (/source/info, see src/ next to public/), and the page shows its name,
// version, size, developer and icon when they come. Without them it works
// all the same. A GitHub repo's apps are in its releases, which only
// Atelier reads.

import { ATELIER, formatSize, loadImage, offer, queryItem, readSource, readSourceInfo, refuse, showDetails, showIcon } from "./link.js";

const THEN = "Atelier adds the source first if you don't have it yet, then shows you ";

/** `parts` as the paragraph's text, a part in an array in bold. */
function say(paragraph, ...parts) {
  paragraph.replaceChildren(...parts.map((part) => {
    if (typeof part === "string") return part;
    const strong = document.createElement("strong");
    strong.textContent = part[0];
    return strong;
  }));
}

/** "From the AltStore source.", or "From SideStore Community Source." for a
 *  name that says it's one. */
function fromSource(name) {
  return [/^the\s/i.test(name) ? "From " : "From the ", [name], /\bsource$/i.test(name) ? ". " : " source. "];
}

/** The app's name, version, size, developer and icon, and its source's
 *  name, in place of its bundle ID and Atelier's icon on its own. */
async function showApp(url, bundleID, view) {
  const info = await readSourceInfo(url, bundleID);
  if (!info) return;
  const app = info.app;
  const icon = app && await loadImage(app.icon);

  if (app) {
    document.title = `Get ${app.name}`;
    view.querySelector("[data-title]").textContent = `Get ${app.name}`;
    view.querySelector("[data-meta]").textContent = [
      `Version ${app.version}`,
      Number.isFinite(app.size) && app.size > 0 ? formatSize(app.size) : null,
      app.developer,
    ].filter(Boolean).join(" · ");
    const subtitle = view.querySelector("[data-subtitle]");
    subtitle.textContent = app.subtitle ?? "";
    subtitle.hidden = !app.subtitle;
  }
  say(view.querySelector("[data-what]"), ...fromSource(info.name), THEN + (app ? `${app.name}.` : "the app."));

  if (icon) showIcon(icon, { isAtelier: bundleID.toLowerCase() === ATELIER });
  showDetails();
}

// Spaces and tabs, as Atelier trims the bundle ID.
const bundleID = queryItem(location.search, "bundleid")?.replace(/^[\t\p{Zs}]+|[\t\p{Zs}]+$/gu, "");
const source = queryItem(location.search, "source")?.trim() || null;

if (!bundleID) {
  refuse("This link doesn't say which app to show.");
} else {
  const view = document.getElementById("link-page");
  const what = view.querySelector("[data-what]");
  view.querySelector("[data-meta]").textContent = bundleID;
  const named = source ? readSource(source) : null;
  if (!named) {
    say(what, "Atelier shows you this app from your sources.");
  } else if (named.repo) {
    say(what, "From the GitHub repo ", [`${named.repo.owner}/${named.repo.name}`], ". Atelier adds it first if you don't have it yet, then shows you the app.");
  } else if (named.url) {
    say(what, "From the source at ", [named.url.hostname], ". " + THEN + "the app.");
  } else {
    say(what, THEN.replace("the source", "the source this link names") + "the app.");
  }
  offer("atelier://viewapp?bundleid=" + encodeURIComponent(bundleID) + (source ? "&source=" + encodeURIComponent(source) : ""));
  if (named?.url && !named.repo) showApp(named.url, bundleID, view);
}
