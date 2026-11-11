// The search link page (search.html, at /search): Atelier's
// atelier://search?q=… link as an https:// one (see link.js).
// /search?q=<text> opens atelier://search?q=<text>, which searches Browse,
// as AltStore's search links do.

import { offer, refuse } from "./link.js";

/** What to search for, as Atelier reads it, as AltStore does: the first q,
 *  + as a space, then percent-decoded, without spaces around it. */
function searchText(search) {
  const item = search.replace(/^\?/, "").split("&").find((part) => part.split("=")[0].toLowerCase() === "q");
  if (item === undefined || !item.includes("=")) return null;
  let text;
  try {
    text = decodeURIComponent(item.slice(item.indexOf("=") + 1).replace(/\+/g, " "));
  } catch {
    return null;
  }
  return text.replace(/^[\t\p{Zs}]+|[\t\p{Zs}]+$/gu, "") || null;
}

const text = searchText(location.search);
if (!text) {
  refuse("This link doesn't say what to search for.");
} else {
  document.title = `Search Atelier for “${text}”`;
  document.querySelector("[data-meta]").textContent = `for “${text}”`;
  offer("atelier://search?q=" + encodeURIComponent(text));
}
