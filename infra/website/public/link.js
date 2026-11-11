// What the link pages share: install.html, source.html, viewapp.html and
// search.html, each one of Atelier's atelier:// links as an https:// one,
// for the places that don't open other apps' links, such as chat apps. Swap
// atelier:// for this site's address and the link opens its page here,
// which opens the same atelier:// link: on an iPhone or iPad straight away,
// once Safari asks, with an Open in Atelier button for when it didn't.
//
// Each page reads its link from its own address as Atelier reads the
// atelier:// one (StoreLink and SourceLink in SourceKit), so it can say what's
// wrong with one in Atelier's words. Where the page can't tell, it leaves the
// link to Atelier, which says so itself.

/** Atelier's own bundle ID: a link to Atelier shows its icon alone, not an
 *  arrow from it to itself. */
export const ATELIER = "com.atelier.app";

// iPadOS's Safari says it's a Mac, but a Mac has no touch screen.
export const onIOS = /iPhone|iPad|iPod/.test(navigator.userAgent)
  || (/Macintosh/.test(navigator.userAgent) && navigator.maxTouchPoints > 1);

/** Shows the page's link, whose Open in Atelier button opens `link`, with
 *  the note for the device it's on. On an iPhone or iPad the page opens it
 *  by itself too, the first time this tab shows it. */
export function offer(link) {
  const view = document.getElementById("link-page");
  document.getElementById("link-open").href = link;
  view.querySelector('[data-on="ios"]').hidden = !onIOS;
  view.querySelector('[data-on="other"]').hidden = onIOS;
  view.hidden = false;
  // Once the page has shown, so it's behind Safari's question rather than a
  // blank one. A tab that isn't showing waits until it is.
  if (onIOS) {
    requestAnimationFrame(() => requestAnimationFrame(() => {
      if (firstVisit(link)) location.href = link;
    }));
  }
}

/** Says why Atelier can't open the link, in its words, in place of it. */
export function refuse(reason) {
  const view = document.getElementById("link-problem");
  view.querySelector("[data-reason]").textContent = reason;
  view.hidden = false;
}

/** Whether to open Atelier by itself: the first time this tab shows this
 *  link, and not when Safari brings back or reloads the page later. */
function firstVisit(link) {
  const navigation = performance.getEntriesByType?.("navigation")?.[0];
  if (navigation && navigation.type !== "navigate") return false;
  try {
    if (sessionStorage.getItem("opened") === link) return false;
    sessionStorage.setItem("opened", link);
  } catch {
    // Without storage, it opens each time.
  }
  return true;
}

// MARK: Reading the link

/** The url item of a query, as a source or install link has it: the rest
 *  of the query when the address is in it as it is, else the item up to the
 *  next &, percent-decoded. */
export function linkTarget(search) {
  const query = search.replace(/^\?/, "");
  const item = /(?:^|&)url=/i.exec(query);
  if (!item) return null;
  const rest = query.slice(item.index + item[0].length);
  if (/^[a-z][a-z0-9+.-]*:\/\//i.test(rest)) return rest;
  return decoded(rest.split("&")[0]);
}

/** The last item named `name` in a query, in any case, percent-decoded, as
 *  Atelier reads an app link's items. An item without = has no value, and
 *  doesn't count. */
export function queryItem(search, name) {
  let value = null;
  for (const part of search.replace(/^\?/, "").split("&")) {
    const equals = part.indexOf("=");
    if (equals >= 0 && decoded(part.slice(0, equals)).toLowerCase() === name) value = decoded(part.slice(equals + 1));
  }
  return value;
}

function decoded(text) {
  try {
    return decodeURIComponent(text);
  } catch {
    return text;
  }
}

const STORES = ["atelier", "altstore", "altstore-classic", "altstore-pal", "sidestore", "feather"];

/** Whether `text` is a link to Atelier or one of the stores, rather than
 *  a source's address. */
function isStoreLink(text) {
  const scheme = /^([a-z][a-z0-9+.-]*):/i.exec(text);
  return scheme !== null && STORES.includes(scheme[1].toLowerCase());
}

/** The source `text` names, as Atelier reads a source's address
 *  (SourceLink.sourceURL): {url} for an AltStore source, {url, repo} for a
 *  GitHub repo, `repo` as {owner, name} in the link's own spelling, or
 *  {problem}, in Atelier's words. A source link's own url can't be another
 *  link (`inLink`); an app link's source, Atelier reads either way, so the
 *  page leaves that to it ({}). */
export function readSource(text, { inLink = false } = {}) {
  const problems = {
    empty: "Enter a source URL.",
    notAURL: "That isn't a source URL.",
    notHTTPS: "Atelier only adds sources whose address starts with https://.",
    noSourceInLink: "This link doesn't name a source.",
  };
  if (inLink && !text) return { problem: problems.noSourceInLink };
  const trimmed = (text ?? "").trim();
  // A link wrapping another link isn't something any site sends.
  if (isStoreLink(trimmed)) return inLink ? { problem: problems.noSourceInLink } : {};
  if (!trimmed) return { problem: problems.empty };

  const shorthand = trimmed.split("/");
  if (shorthand.length === 2 && isOwner(shorthand[0]) && isRepoName(shorthand[1])) {
    return repoSource(shorthand[0], shorthand[1]);
  }
  // "example.com/apps.json" has no scheme; Atelier reads it as HTTPS.
  const address = trimmed.includes("://") ? trimmed : "https://" + trimmed;
  const scheme = /^([a-z][a-z0-9+.-]*):/i.exec(address)?.[1];
  if (!scheme) return { problem: problems.notAURL };
  if (scheme.toLowerCase() !== "https") return { problem: problems.notHTTPS };
  let url;
  try {
    url = new URL(address);
  } catch {
    return { problem: problems.notAURL };
  }
  // Some browsers take a host with a space, as "exa%20mple.com".
  if (!url.hostname || /[\s%]/.test(url.hostname) || /^[^:]+:\/\/[^/?#]*\s/.test(address)) return { problem: problems.notAURL };
  url.hash = "";

  // A repo's own address, optionally followed by /releases… or .git.
  if (url.hostname === "github.com" || url.hostname === "www.github.com") {
    const parts = url.pathname.split("/").filter(Boolean).map(decoded);
    if (parts.length === 2 || (parts.length >= 3 && parts[2].toLowerCase() === "releases")) {
      const name = parts[1].replace(/\.git$/i, "");
      if (isOwner(parts[0]) && isRepoName(name)) return repoSource(parts[0], name);
    }
  }
  return { url };
}

function repoSource(owner, name) {
  return { url: new URL(`https://github.com/${owner}/${name}`), repo: { owner, name } };
}

/** GitHub user and organization names: letters, digits and hyphens, up to
 *  39 characters. */
const isOwner = (text) => /^[A-Za-z0-9-]{1,39}$/.test(text);

/** Repository names: letters, digits, ., - and _, up to 100 characters, and
 *  not . or .. */
const isRepoName = (text) => /^[A-Za-z0-9._-]{1,100}$/.test(text) && text !== "." && text !== "..";

// MARK: What the page shows

/** "7.7 MB", in decimal units, as iOS counts. */
export function formatSize(bytes) {
  for (const [unit, scale] of [["GB", 1e9], ["MB", 1e6], ["KB", 1e3]]) {
    if (bytes < scale) continue;
    const value = bytes / scale;
    return `${value.toLocaleString("en", { maximumFractionDigits: value < 100 ? 1 : 0 })} ${unit}`;
  }
  return `${bytes} bytes`;
}

/** The source at `url`, as the website's Worker sums it up (/source/info,
 *  see src/source.js), with the app whose bundle ID is `bundleID`, or null
 *  when it can't, or not within 10 seconds. */
export async function readSourceInfo(url, bundleID = null) {
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), 10000);
  try {
    const query = "?url=" + encodeURIComponent(url.href) + (bundleID ? "&bundleid=" + encodeURIComponent(bundleID) : "");
    const response = await fetch("/source/info" + query, { signal: controller.signal });
    if (!response.ok) return null;
    const info = await response.json();
    return typeof info?.name === "string" && Number.isInteger(info.appCount) && Array.isArray(info.apps) ? info : null;
  } catch {
    return null;
  } finally {
    clearTimeout(timer);
  }
}

/** The image at `address`, an https:// one or a PNG's data: URL, decoded
 *  so it shows at once, or null when it can't be, or not within 5 seconds.
 *  It's asked for without the page's address. */
export function loadImage(address) {
  if (typeof address !== "string" || !/^(?:https:\/\/|data:image\/png;base64,)/.test(address)) return Promise.resolve(null);
  const image = new Image();
  image.referrerPolicy = "no-referrer";
  image.src = address;
  return new Promise((resolve) => {
    const timer = setTimeout(() => resolve(null), 5000);
    image.decode().then(() => image, () => null).then((loaded) => {
      clearTimeout(timer);
      resolve(loaded);
    });
  });
}

/** Shows `icon`, a loaded image, as the link's app or source, above an
 *  arrow to Atelier's icon, or in place of it for Atelier itself. */
export function showIcon(icon, { isAtelier = false } = {}) {
  const shown = document.querySelector("[data-app-icon]");
  shown.src = icon.src;
  shown.hidden = false;
  if (isAtelier) {
    document.querySelector("[data-atelier-icon]").hidden = true;
  } else {
    document.querySelector("[data-arrow]").hidden = false;
    document.querySelector(".install-icons").classList.add("has-app");
  }
}

/** Fades in what came after the page showed. */
export function showDetails() {
  document.querySelector(".install-main").classList.add("has-app");
}
