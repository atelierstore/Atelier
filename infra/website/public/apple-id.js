// The Apple ID page (apple-id.html): the Copy buttons, step 4's line, which
// installs Atelier's newest release as its own source lists it, and, on a
// computer, a code that opens the page on the iPhone, where the lines are
// copied into rootshell. Until the source loads, step 4 says so, and when
// it can't, it says to reload.

import { copies } from "./copy.js";
import { formatSize, onIOS } from "./link.js";
import { qrCode, qrPath } from "./qr.js";
import { formatDate, installLine, newestRelease } from "./release.js";

for (const box of document.querySelectorAll("[data-command]")) {
  const code = box.querySelector("code");
  copies(box.querySelector("button"), () => code.textContent.trim(), () => code);
}

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
  const line = newest && installLine(newest);
  if (!line) return Promise.reject(new Error("no release to install"));
  release.querySelector("[data-release-name]").textContent = `Atelier ${newest.version}`;
  const meta = [newest.size && formatSize(newest.size), newest.date && formatDate(newest.date)].filter(Boolean);
  if (meta.length) release.querySelector("[data-release-meta]").textContent = meta.join(" · ");
  document.querySelector("[data-install-line]").textContent = line;
  for (const node of document.querySelectorAll("[data-after-release]")) node.hidden = false;
  waiting.hidden = true;
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
