// The Apple ID page (apple-id.html). On an iPhone or iPad, step 3's
// Install Atelier button adds the Install Atelier Shortcut the first time
// and runs it after. Without the Shortcut, step 3's line downloads the
// installer and installs Atelier's newest release as its own source lists
// it, with its Copy button, and on an iPhone or iPad a button also copies
// the line and opens rootshell. On a computer, a code opens the page on the
// iPhone. Until the source loads, step 3 says so, and when it can't, it says
// to reload. On an iPhone with an older iOS than the installer needs, a
// notice over You'll need says so.

import { copies, copy } from "./copy.js";
import { INSTALLER_IOS, iPhoneIOS } from "./ios.js";
import { formatSize, onIOS } from "./link.js";
import { qrCode, qrPath } from "./qr.js";
import { formatDate, installLine, newestRelease } from "./release.js";

const ios = iPhoneIOS(navigator.userAgent);
if (ios !== null && ios < INSTALLER_IOS) {
  const notice = document.getElementById("old-ios");
  notice.querySelector("[data-ios-version]").textContent = ios;
  notice.hidden = false;
}

const box = document.querySelector("[data-command]");
const line = box.querySelector("[data-install-line]");
copies(box.querySelector("button"), () => line.textContent.trim(), () => line);

const release = document.querySelector("[data-release]");
const waiting = document.querySelector("[data-release-wait]");

fetch(release.dataset.source)
  .then((response) => response.ok ? response.json() : Promise.reject(response.status))
  .then(showRelease)
  .catch(() => {
    waiting.textContent = "This page couldn't read Atelier's newest release. Reload it to try again.";
  });

function showRelease(source) {
  const newest = newestRelease(source);
  const command = newest && installLine(newest);
  if (!command) return Promise.reject(new Error("no release to install"));
  release.querySelector("[data-release-name]").textContent = `Atelier ${newest.version}`;
  const meta = [newest.size && formatSize(newest.size), newest.date && formatDate(newest.date)].filter(Boolean);
  if (meta.length) release.querySelector("[data-release-meta]").textContent = meta.join(" · ");
  line.textContent = command;
  for (const node of document.querySelectorAll("[data-after-release]")) node.hidden = false;
  waiting.hidden = true;
  if (onIOS) offerRootshell();
}

/** Shows the button that copies the line and opens rootshell, which
 *  becomes the step's main button in place of Copy. Its link is
 *  LocalDevVPN's: it connects, then opens rootshell. The line is copied
 *  before Safari asks to open it. Where the clipboard refuses, the line is
 *  selected instead, the button says so as Copy does, and nothing opens:
 *  there'd be nothing to paste. */
function offerRootshell() {
  const open = document.querySelector("[data-open-rootshell]");
  const label = open.textContent;
  let timer;
  open.addEventListener("click", async (event) => {
    event.preventDefault();
    if (await copy(line.textContent.trim(), line)) {
      location.href = open.href;
      return;
    }
    open.textContent = "Selected";
    clearTimeout(timer);
    timer = setTimeout(() => { open.textContent = label; }, 1800);
  });
  box.querySelector("button").classList.replace("btn-primary", "btn-secondary");
  for (const node of document.querySelectorAll("[data-on-ios]")) node.hidden = false;
}

// MARK: The Install Atelier Shortcut

/** The Shortcut's name, as Shortcuts' link that runs it names it. */
const SHORTCUT = "Install Atelier";
/** What the page keeps once the first tap has opened the Shortcut's
 *  iCloud link, so later taps run it. */
const ADDED = "shortcut-added";
/** The address Shortcuts comes back to when it can't run the Shortcut, as
 *  when it was never added: the button then adds it again. */
const NOT_ADDED = "#add-shortcut";

/** Whether the first tap has opened the Shortcut's iCloud link. Without
 *  storage, it lasts while the page is open. */
let added = (() => {
  try {
    return localStorage.getItem(ADDED) === "1";
  } catch {
    return false;
  }
})();

function rememberAdded(value) {
  added = value;
  try {
    if (value) localStorage.setItem(ADDED, "1");
    else localStorage.removeItem(ADDED);
  } catch {
    // It lasts while the page is open.
  }
}

/** Shortcuts' link that runs the Shortcut, coming back here if it can't.
 *  Nothing comes back when it runs: it ends by opening the installer's page
 *  in Safari, which should stay in front. */
function runLink(name, back) {
  return `shortcuts://x-callback-url/run-shortcut?name=${encodeURIComponent(name)}&x-error=${encodeURIComponent(back)}`;
}

/** Shows the Install Atelier button: its link, the Shortcut's iCloud link,
 *  the first time, and Shortcuts' link that runs it after. */
function offerShortcut() {
  // In a new tab, or this one, which then only changes its hash.
  notAdded();
  addEventListener("hashchange", notAdded);
  const button = document.querySelector("[data-shortcut-button]");
  button.addEventListener("click", (event) => {
    if (!added) {
      rememberAdded(true);
      return;
    }
    event.preventDefault();
    location.href = runLink(SHORTCUT, new URL(NOT_ADDED, location.href).href);
  });
  for (const node of document.querySelectorAll("[data-shortcut]")) node.hidden = false;
}

/** When Shortcuts came back because it couldn't run the Shortcut: the next
 *  tap adds it again. */
function notAdded() {
  if (location.hash !== NOT_ADDED) return;
  rememberAdded(false);
  history.replaceState(null, "", location.pathname);
}

if (onIOS) offerShortcut();

if (!onIOS) {
  const notice = document.getElementById("on-computer");
  const code = qrCode(new URL("/apple-id", location.origin).href);
  const svg = document.createElementNS("http://www.w3.org/2000/svg", "svg");
  svg.setAttribute("viewBox", `-4 -4 ${code.size + 8} ${code.size + 8}`);
  svg.setAttribute("shape-rendering", "crispEdges");
  svg.setAttribute("aria-hidden", "true");
  const path = document.createElementNS("http://www.w3.org/2000/svg", "path");
  path.setAttribute("d", qrPath(code));
  svg.append(path);
  notice.querySelector(".qr").append(svg);
  notice.hidden = false;
}
