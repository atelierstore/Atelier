// The sideload page (sideload.html): Atelier's newest release, read from its
// own source, whose address is in the page's Copy box, and the Copy buttons.
// Until the source loads, or if it can't, the Download button opens the
// releases page and the release's version, size, date and SHA-256 stay
// hidden.

import { formatSize } from "./link.js";
import { formatDate, newestRelease, shortHash } from "./release.js";

const sourceURL = document.getElementById("source-url");
copies(document.getElementById("copy-source"), () => sourceURL.textContent.trim(), () => sourceURL);

fetch(sourceURL.textContent.trim())
  .then((response) => response.ok ? response.json() : Promise.reject(response.status))
  .then(showRelease)
  .catch(() => {});

function showRelease(source) {
  const release = newestRelease(source);
  if (!release) return;
  document.querySelector("[data-release-download]").href = release.downloadURL;
  document.querySelector("[data-release-name]").textContent = `Atelier ${release.version}`;
  const meta = [release.size && formatSize(release.size), release.date && formatDate(release.date)].filter(Boolean);
  if (meta.length) document.querySelector("[data-release-meta]").textContent = meta.join(" · ");
  if (release.sha256) {
    const row = document.querySelector("[data-release-hash]");
    const shown = row.querySelector("dd");
    shown.textContent = shortHash(release.sha256);
    shown.title = release.sha256;
    // Where the clipboard refuses, the whole hash shows, selected.
    copies(row.querySelector("button"), () => release.sha256, () => {
      shown.textContent = release.sha256;
      return shown;
    });
    row.hidden = false;
  }
}

/** Copies `text()` when `button` is tapped, and says Copied. Where the
 *  clipboard refuses, it selects the text in `node()` instead, and says
 *  Selected. */
function copies(button, text, node) {
  const label = button.textContent;
  let timer;
  button.addEventListener("click", async () => {
    try {
      await navigator.clipboard.writeText(text());
      button.textContent = "Copied";
    } catch {
      const range = document.createRange();
      range.selectNodeContents(node());
      const selection = window.getSelection();
      selection.removeAllRanges();
      selection.addRange(range);
      button.textContent = "Selected";
    }
    clearTimeout(timer);
    timer = setTimeout(() => { button.textContent = label; }, 1800);
  });
}
