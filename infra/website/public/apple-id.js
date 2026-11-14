// The Apple ID page (apple-id.html): step 3's line, which downloads the
// installer and installs Atelier's newest release as its own source lists
// it, with its Copy button. On an iPhone or iPad, a button also copies the
// line and opens rootshell. On a computer, a code opens the page on the
// iPhone, where the line is copied into rootshell. Until the source loads,
// step 3 says so, and when it can't, it says to reload. On an iPhone with an
// older iOS than the installer needs, a notice over You'll need says so.

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
