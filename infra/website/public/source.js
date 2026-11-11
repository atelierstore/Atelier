// The source link page (source.html, at /source): Atelier's
// atelier://source?url=… link as an https:// one (see link.js).
// /source?url=<source> opens atelier://source?url=<source>, an AltStore
// source's address or a GitHub repo as owner/repo or its address. Atelier
// shows the source and its apps before it adds it.
//
// The source is read as Atelier reads a source link (SourceLink in
// SourceKit): HTTPS only, and without a scheme it's read as HTTPS. It comes
// percent-encoded, or as it is, its own query included, when url= is last.
//
// Then the website's Worker reads the AltStore source's name, icon and apps
// (/source/info, see src/ next to public/), and the page shows them when
// they come, with the icons from where the source keeps them. Without them
// it works all the same. A GitHub repo's apps are in its releases, which
// only Atelier reads.

import { linkTarget, loadImage, offer, readSource, readSourceInfo, refuse, showDetails, showIcon } from "./link.js";

/** The source's name, icon and how many apps it has, with a few of their
 *  icons, in place of its address and Atelier's icon on its own. */
async function showSource(url, view) {
  const info = await readSourceInfo(url);
  if (!info) return;
  // The add sheet's five places, the last saying how many more there are,
  // unless one app fits there.
  const candidates = info.appCount <= 5 ? info.apps.slice(0, 5) : info.apps.slice(0, 4);
  const [icon, ...appIcons] = await Promise.all([loadImage(info.icon), ...candidates.map((app) => loadImage(app.icon))]);

  document.title = `Add ${info.name}`;
  view.querySelector("[data-title]").textContent = `Add ${info.name}`;
  view.querySelector("[data-meta]").textContent = `${apps(info.appCount)} · ${url.hostname}`;
  const strip = view.querySelector("[data-apps]");
  let shown = 0;
  candidates.forEach((app, index) => {
    const image = appIcons[index];
    if (!image) return;
    image.alt = app.name;
    image.title = app.name;
    image.width = image.height = 38;
    strip.append(image);
    shown++;
  });
  if (shown > 0 && info.appCount > shown) {
    const more = document.createElement("span");
    more.textContent = `and ${(info.appCount - shown).toLocaleString("en")} more`;
    strip.append(more);
  }
  strip.hidden = shown === 0;

  if (icon) showIcon(icon);
  showDetails();
}

/** "23 apps", "1 app". */
const apps = (count) => (count === 1 ? "1 app" : `${count.toLocaleString("en")} apps`);

const text = linkTarget(location.search);
const result = readSource(text, { inLink: true });
if (result.problem) {
  refuse(result.problem);
} else {
  const view = document.getElementById("link-page");
  const file = document.getElementById("source-file");
  if (result.repo) {
    const name = `${result.repo.owner}/${result.repo.name}`;
    document.title = `Add ${name}`;
    view.querySelector("[data-title]").textContent = `Add ${name}`;
    view.querySelector("[data-meta]").textContent = "GitHub repo";
    view.querySelector("[data-what]").textContent = "Atelier shows you the repo's apps, from its releases, before it adds it.";
    file.textContent = "See the repo on GitHub";
  } else {
    view.querySelector("[data-meta]").textContent = result.url.hostname;
  }
  file.href = result.url.href;
  // As it came: Atelier reads it again.
  offer("atelier://source?url=" + encodeURIComponent(text.trim()));
  if (!result.repo) showSource(result.url, view);
}
