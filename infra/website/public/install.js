// The install link page (install.html, at /install): Atelier's
// atelier://install?url=… link as an https:// one (see link.js).
// /install?url=<IPA address> opens atelier://install?url=<IPA address>.
// Atelier asks before it installs anything.
//
// The link can also name the source the app comes from, &source=<source>,
// as Atelier's own links do, and Atelier gets it too: without that source,
// Atelier shows it to add first, then installs the app as it lists it.
//
// The address is read as Atelier reads atelier://install (StoreLink in
// SourceKit): HTTPS only, and without a scheme it's read as HTTPS. It comes
// percent-encoded, or as it is, its own query included, when url= is last.
//
// Then the website's Worker reads the app's name, version, size and icon from
// the IPA (/install/app, see src/ next to public/), and the page shows them
// when they come. Without them it works all the same.

import { ATELIER, formatSize, linkTarget, loadImage, offer, refuse, showDetails, showIcon } from "./link.js";

const PROBLEMS = {
  noApp: "This link doesn't name an app to install.",
  notAWebAddress: "This link's app isn't at a web address Atelier can download from.",
  notHTTPS: "Atelier only downloads apps whose address starts with https://.",
};

/** The source the link names, as Atelier reads its source item: not one
 *  in the IPA's own query, when the IPA's address comes as it is. */
function sourceTarget(search) {
  let query = search.replace(/^\?/, "");
  const item = /(?:^|&)url=/i.exec(query);
  if (item && /^[a-z][a-z0-9+.-]*:\/\//i.test(query.slice(item.index + item[0].length))) {
    query = query.slice(0, item.index);
  }
  // The last one, as Atelier keeps.
  const found = query.split("&").filter((part) => /^source=/i.test(part)).pop();
  if (found === undefined) return null;
  let value = found.slice("source=".length);
  try {
    value = decodeURIComponent(value);
  } catch {
    // As it is.
  }
  return value.trim() || null;
}

/** The IPA's address, or the reason Atelier wouldn't take it. */
function read(search) {
  let text = (linkTarget(search) ?? "").trim();
  if (!text) return { problem: PROBLEMS.noApp };
  if (/\s/.test(text)) return { problem: PROBLEMS.notAWebAddress };
  if (!text.includes("://")) text = "https://" + text;
  let url;
  try {
    url = new URL(text);
  } catch {
    return { problem: PROBLEMS.notAWebAddress };
  }
  if (url.protocol === "http:") return { problem: PROBLEMS.notHTTPS };
  if (url.protocol !== "https:" || !url.hostname) return { problem: PROBLEMS.notAWebAddress };
  return { ipa: url };
}

/** "Nimbus.ipa", or "the app" when the address doesn't end with the file's
 *  name, as Atelier's own question says. */
function fileName(url) {
  const last = url.pathname.split("/").pop() ?? "";
  let name;
  try {
    name = decodeURIComponent(last);
  } catch {
    name = last;
  }
  return /\.t?ipa$/i.test(name) ? name : "the app";
}

/** The app the IPA at `ipa` holds, as the Worker reads it, or null when it
 *  can't, or not within 10 seconds. */
async function readApp(ipa) {
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), 10000);
  try {
    const response = await fetch("/install/app?url=" + encodeURIComponent(ipa.href), { signal: controller.signal });
    if (!response.ok) return null;
    const app = await response.json();
    return typeof app?.name === "string" && typeof app.version === "string" ? app : null;
  } catch {
    return null;
  } finally {
    clearTimeout(timer);
  }
}

/** The app's name, version, size and icon, in place of the file's name and
 *  Atelier's icon on its own. */
async function showApp(ipa, view) {
  const app = await readApp(ipa);
  if (!app) return;
  const icon = await loadImage(app.icon);

  document.title = `Install ${app.name}`;
  view.querySelector("[data-title]").textContent = `Install ${app.name}`;
  const meta = view.querySelector("[data-meta]");
  meta.textContent = [
    app.build && app.build !== app.version ? `Version ${app.version} (${app.build})` : `Version ${app.version}`,
    Number.isFinite(app.size) && app.size > 0 ? formatSize(app.size) : null,
  ].filter(Boolean).join(" · ");
  meta.hidden = false;
  // "Atelier downloads it from github.com", the app the title names.
  view.querySelector("[data-file]").replaceWith("it");

  if (icon) showIcon(icon, { isAtelier: app.bundleID === ATELIER });
  showDetails();
}

const result = read(location.search);
if (result.problem) {
  refuse(result.problem);
} else {
  const ipa = result.ipa;
  // Atelier says what's wrong with the source, if anything.
  const source = sourceTarget(location.search);
  const view = document.getElementById("link-page");
  view.querySelector("[data-file]").textContent = fileName(ipa);
  view.querySelector("[data-host]").textContent = ipa.hostname;
  document.getElementById("install-ipa").href = ipa.href;
  offer("atelier://install?url=" + encodeURIComponent(ipa.href) + (source ? "&source=" + encodeURIComponent(source) : ""));
  showApp(ipa, view);
}
