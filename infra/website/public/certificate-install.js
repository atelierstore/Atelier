// The page the certificate page's code opens (certificate/install.html). On
// a computer, the certificate page signs Atelier and uploads it to this site
// (/ota, see src/ota.js), then shows a QR code of this page's address, with
// the upload's token after the #, so it stays in the browser. The iPhone's
// camera opens it in Safari, and the page opens iOS's install alert
// (itms-services://), by itself the first time and then with Install
// Atelier, and follows the install until iOS has downloaded Atelier, as the
// certificate page does on the iPhone.

import { firstVisit, formatSize, isSafari, onIOS } from "./link.js";

const POLL_INTERVAL = 2000;
const $ = (id) => document.getElementById(id);

const token = location.hash.slice(1).toLowerCase();
const status = `/ota/${token}`;
const install = `itms-services://?action=download-manifest&url=${encodeURIComponent(new URL(`${status}/manifest.plist`, location.origin).href)}`;

/** "ready" in Safari on an iPhone or iPad with iOS 17 or later, "old" with
 *  an older iOS, "browser" in another browser on one, and "elsewhere"
 *  anywhere else, as on the certificate page. */
const device = (() => {
  if (!onIOS) return "elsewhere";
  const agent = navigator.userAgent;
  if (!isSafari(agent)) return "browser";
  return Number(agent.match(/Version\/(\d+)/)[1]) >= 17 ? "ready" : "old";
})();

/** Shows the page's texts, each one hidden when it's null: `title`, the
 *  app's `meta`, a `notice` over `what`, and the button, Install Atelier
 *  or Copy Link, with a `note` under it. */
function show({ title = "Install Atelier", meta = null, notice = null, what = null, button = null, note = null }) {
  $("scan-title").textContent = title;
  for (const [id, text] of [["scan-meta", meta], ["scan-what", what], ["scan-note", note]]) {
    $(id).textContent = text ?? "";
    $(id).hidden = !text;
  }
  $("scan-notice").hidden = !notice;
  if (notice) {
    $("scan-notice-title").textContent = notice.title;
    $("scan-notice-text").textContent = notice.text;
  }
  $("scan-install").hidden = button !== "install";
  $("scan-copy").hidden = button !== "copy";
}

/** Atelier's version and size, as this site read them from the IPA. */
function metaOf(app) {
  const parts = [app?.version && `Version ${app.version}`, app?.size && formatSize(app.size)].filter(Boolean);
  return parts.length ? parts.join(" · ") : null;
}

const GONE = {
  title: "This code no longer works",
  what: "This site deletes the signed Atelier 10 minutes after it's ready, or a minute after iOS has downloaded it. To install it again, show a new code on your computer.",
};

/** What the page says for the upload, `app` being /ota/<token>'s answer, or
 *  null when it couldn't be read. */
function showApp(app) {
  const meta = metaOf(app);
  if (app?.state === "downloaded") {
    return show({
      title: "iOS is installing Atelier",
      meta,
      what: "It shows up on your Home Screen in a moment. This site deletes its copy within a minute.",
      note: "If Atelier doesn't open yet, step 3 on your computer says what iOS needs first.",
    });
  }
  if (app?.state === "downloading") {
    return show({ title: "Installing Atelier", meta, what: "iOS is downloading it, then it shows up on your Home Screen." });
  }
  switch (device) {
    case "ready": {
      const until = app && new Date(app.expires).toLocaleTimeString([], { hour: "numeric", minute: "2-digit" });
      return show({
        meta,
        what: "Signed with your certificate on your computer. iOS asks whether to install it. Tap Install.",
        button: "install",
        note: `Tap it if iOS didn't ask, or you tapped Cancel.${until ? ` This site deletes this Atelier at ${until}.` : ""}`,
      });
    }
    case "browser":
      return show({
        meta,
        notice: { title: "Open this page in Safari", text: "iOS only installs Atelier from Safari. Copy the link, then paste it in Safari's address bar." },
        button: "copy",
      });
    case "old":
      return show({
        meta,
        notice: { title: "Atelier needs iOS 17 or later", text: "Update this iPhone in Settings › General › Software Update, then scan the code again." },
      });
    default:
      return show({ meta, what: "Scan the code on your computer with your iPhone's camera. This page installs Atelier on the iPhone or iPad that opens it." });
  }
}

/** /ota/<token>'s answer: {state, expires, version, size}, "gone" once
 *  it's a 404, or null when it can't be read. */
async function read() {
  try {
    const response = await fetch(status, { cache: "no-store" });
    if (response.status === 404) return "gone";
    return response.ok ? await response.json() : null;
  } catch {
    return null;
  }
}

$("scan-install").href = install;
$("scan-copy").addEventListener("click", async () => {
  try {
    await navigator.clipboard.writeText(location.href);
    $("scan-copy").textContent = "Copied";
    setTimeout(() => { $("scan-copy").textContent = "Copy Link"; }, 2000);
  } catch {
    // Safari's own address bar has it to copy.
  }
});

if (!/^[0-9a-f]{32}$/.test(token)) {
  show({ title: "This link is incomplete", what: "Scan the code on your computer again, with your iPhone's camera." });
} else {
  // What the device allows straight away, then Atelier's details.
  showApp(null);
  let app = await read();
  if (app === "gone") {
    show(GONE);
  } else {
    showApp(app);
    // Once the page has shown, so it's behind iOS's alert rather than a
    // blank one, as the link pages do.
    if (device === "ready" && !["downloading", "downloaded"].includes(app?.state)) {
      requestAnimationFrame(() => requestAnimationFrame(() => {
        if (firstVisit(install)) location.href = install;
      }));
    }
    while (app?.state !== "downloaded") {
      await new Promise((resolve) => setTimeout(resolve, POLL_INTERVAL));
      const answer = await read();
      if (answer === "gone") {
        // Gone before its time means iOS downloaded it a minute ago, while
        // Safari was in the background and asked nothing.
        const early = app && Date.now() < Date.parse(app.expires) - 15_000;
        if (early) showApp({ ...app, state: "downloaded" });
        else show(GONE);
        break;
      }
      if (answer && answer.state !== app?.state) showApp(answer);
      app = answer ?? app;
    }
  }
}
