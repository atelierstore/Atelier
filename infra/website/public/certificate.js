// The certificate page (certificate.html, #152). The visitor's .p12, its
// password and its profile are checked as Atelier checks a certificate it
// imports (checks.js), and Apple is asked whether it was revoked (ocsp.js).
// Then Atelier, its newest release or an IPA the visitor chooses, is signed
// with them in a background worker (signing-worker.js), uploaded to this
// site, and iOS installs it from there (/ota, see src/ota.js) once the
// visitor taps Install in its alert. Only the signed Atelier leaves the
// page, with the certificate inside when Include Certificate is on.

import { CheckError, addFile, examine, revocationRow, summary } from "./checks.js";
import { formatSize, onIOS } from "./link.js";
import { checkRevocation } from "./ocsp.js";
import { packagedCertificate } from "./packaged.js";
import { PlistError } from "./plist.js";
import { ATELIER_BUNDLE_ID, newestRelease } from "./release.js";
import { SignError, readAppInfo } from "./signer.js";
import { concat } from "./zip.js";

const SOURCE_URL = "https://raw.githubusercontent.com/atelierstore/Atelier/source/source.json";
// A certificate's files are a few kilobytes, and a ZIP of them not much
// more.
const MAX_PICKED = 32 << 20;
// The largest IPA this site keeps (MAX_SIZE in src/ota.js).
const MAX_IPA = 64 << 20;
// How long this site keeps the signed Atelier (LIFETIME in src/ota.js).
const LIFETIME = 10 * 60 * 1000;
const POLL_INTERVAL = 2000;

const $ = (id) => document.getElementById(id);

/** What the page says when something fails, and what the console gets. */
class Failure extends Error {
  constructor(message, detail = null) {
    super(message);
    this.detail = detail;
  }
}

// MARK: Where the page is open

/** "ready" in Safari on an iPhone or iPad with iOS 17 or later, "old" with
 *  an older iOS, and "elsewhere" anywhere else: iOS's install alert only
 *  opens in Safari, not in other browsers or apps' own. */
const device = (() => {
  const agent = navigator.userAgent;
  const safari = /Version\/[\d.]+ .*Safari\//.test(agent)
    && !/(CriOS|FxiOS|EdgiOS|OPiOS|OPT|GSA|YaBrowser|DuckDuckGo|Brave)\/|FBAN|FBAV|Instagram|Line\/|MicroMessenger|Snapchat|musical_ly|Bytedance/.test(agent);
  if (!onIOS || !safari) return "elsewhere";
  // Safari's version is iOS's.
  return Number(agent.match(/Version\/(\d+)/)[1]) >= 17 ? "ready" : "old";
})();

if (device !== "ready") {
  const notice = $("not-here");
  if (device === "old") {
    notice.querySelector("strong").textContent = "Atelier needs iOS 17 or later";
    notice.querySelector("p").textContent = "Update this iPhone in Settings › General › Software Update, then come back. You can still check your certificate here.";
  }
  notice.hidden = false;
}

// MARK: State

const state = {
  files: { p12: null, profile: null },
  // Why the files picked last can't be used, and why the check can't make
  // a certificate of them.
  pickProblem: null,
  checkProblem: null,
  checking: false,
  // The certificate the newest check made (examine's), and Apple's row for
  // it once Apple has answered or couldn't.
  certificate: null,
  apple: null,
  // Atelier's newest release (newestRelease's), and whether its source
  // could be read: "loading", "loaded" or "missing".
  release: null,
  source: "loading",
  downloadFailed: false,
  // The IPA the visitor chose, and the release's once downloaded, each
  // {bytes, info}, `info` being readAppInfo's.
  chosen: null,
  downloaded: null,
  wantsCertificate: true,
  // "idle", "working" (downloading, signing or uploading), "installing"
  // (iOS asks, then downloads it), "done" or "failed".
  stage: "idle",
};
// The newest check's number, and the newest Sign and Install's, so an
// older one that finishes late shows nothing.
let checks = 0;
let runs = 0;

const OPEN_WITH = $("open-text").textContent;
const OPEN_WITHOUT = "Open it from your Home Screen, and add your certificate in Get Ready.";
const INCLUDE_TEXT = $("include-text").textContent;

// MARK: The signer

let worker = null;
let calls = 0;
const pending = new Map();

/** The worker that opens the .p12 and signs (signing-worker.js), started
 *  when it's first needed. */
function signer() {
  if (worker) return worker;
  worker = new Worker("/signing-worker.js", { type: "module" });
  worker.onmessage = ({ data }) => {
    const call = pending.get(data.id);
    if (!call) return;
    pending.delete(data.id);
    if (data.error) call.reject(new Failure(data.error.message, data.error.detail));
    else call.resolve(data.result);
  };
  worker.onerror = (event) => {
    event.preventDefault();
    endSigner(`The signer couldn't start: ${event.message ?? "no reason given"}.`);
  };
  return worker;
}

/** Asks the signer, and resolves to its answer. Throws a Failure. */
function ask(message) {
  const id = ++calls;
  return new Promise((resolve, reject) => {
    pending.set(id, { resolve, reject });
    signer().postMessage({ id, ...message });
  });
}

/** Ends the signer, which frees the memory signing took. */
function endSigner(why = "The signer was ended.") {
  worker?.terminate();
  worker = null;
  for (const call of pending.values()) call.reject(new Failure("Atelier couldn't be signed. Try again.", why));
  pending.clear();
}

// MARK: Step 1: the certificate

$("choose-files").addEventListener("click", () => {
  // zsign loads while the visitor picks, so the check doesn't wait for it.
  signer().postMessage({ type: "load" });
  $("files-input").click();
});

$("files-input").addEventListener("change", async (event) => {
  const picked = [...event.target.files];
  event.target.value = "";
  if (!picked.length) return;
  reset();
  let files = state.files;
  let problem = null;
  for (const file of picked) {
    try {
      if (file.size > MAX_PICKED) throw new CheckError(`${file.name} is too large to be a certificate's file.`);
      files = await addFile(files, file.name, new Uint8Array(await file.arrayBuffer()));
    } catch (error) {
      if (!(error instanceof CheckError)) console.error(error);
      problem ??= error instanceof CheckError ? error.message : `${file.name} can't be read.`;
    }
  }
  state.files = files;
  state.pickProblem = problem;
  showFiles();
  check();
});

let typing;
const password = $("password");
password.addEventListener("input", () => {
  reset();
  clearTimeout(typing);
  // What was checked is out of date until what's typed is checked.
  checks++;
  Object.assign(state, { certificate: null, apple: null, checking: false });
  showPasswordProblem(null);
  showCertificate();
  update();
  typing = setTimeout(check, 450);
});
password.addEventListener("keydown", (event) => {
  if (event.key === "Enter") check();
});

function showFiles() {
  for (const [kind, id] of [["p12", "p12-row"], ["profile", "profile-row"]]) {
    const row = $(id);
    const file = state.files[kind];
    row.classList.toggle("chosen", Boolean(file));
    row.querySelector(".what span").textContent = file ? file.name : "Not chosen yet";
    row.querySelector(".tick").hidden = !file;
  }
}

/** Checks the files with the password, once there are both, then asks
 *  Apple whether the certificate was revoked. */
async function check() {
  clearTimeout(typing);
  const number = ++checks;
  const stale = () => number !== checks;
  Object.assign(state, { certificate: null, apple: null, checkProblem: null, checking: false });
  showPasswordProblem(null);
  showCertificate();
  const { files } = state;
  const key = password.value;
  if (!files.p12 || !files.profile) return update();

  state.checking = true;
  update();
  let certificate;
  try {
    certificate = await examine(files, key, (p12, secret) => ask({ type: "open", p12, password: secret }));
  } catch (error) {
    if (stale()) return;
    state.checking = false;
    if (error instanceof CheckError && error.field === "password") {
      // Not before there's a password: the .p12 may have none.
      if (key) showPasswordProblem(error.message);
    } else if (error instanceof CheckError) {
      state.checkProblem = error.message;
    } else {
      // The signer couldn't load or ran out of memory: the next check starts
      // another.
      console.error(error.detail ?? error);
      endSigner();
      state.checkProblem = "Your certificate couldn't be checked here. Reload the page and try again.";
    }
    return update();
  }
  if (stale()) return;
  state.checking = false;
  state.certificate = certificate;
  showCertificate();
  update();

  let answer = null;
  try {
    answer = await Promise.race([
      checkRevocation(certificate.der),
      new Promise((_, reject) => setTimeout(() => reject(new Error("Apple took too long")), 20_000)),
    ]);
  } catch (error) {
    console.info("Apple couldn't be asked whether the certificate was revoked:", error?.message ?? error);
  }
  if (stale()) return;
  state.apple = revocationRow(answer);
  showCertificate();
  update();
}

function showPasswordProblem(message) {
  $("password-field").classList.toggle("problem", Boolean(message));
  if (message) password.setAttribute("aria-invalid", "true");
  else password.removeAttribute("aria-invalid");
  showProblem("password-problem", message);
}

/** The certificate's card: its name, kind and days left, and each check,
 *  Apple's in the third row as Atelier lists them. */
function showCertificate() {
  const { certificate, apple } = state;
  $("certificate").hidden = !certificate;
  if (!certificate) return;
  $("certificate-name").textContent = certificate.name;
  $("certificate-summary").textContent = summary(certificate);
  const rows = [...certificate.rows];
  rows.splice(2, 0, apple ?? { state: "note", text: "Asking Apple whether it's revoked…" });
  $("certificate-checks").replaceChildren(...rows.map((row) => {
    const item = document.createElement("li");
    if (row.state !== "ok") item.className = row.state;
    const text = document.createElement("div");
    if (row.lead) {
      const lead = document.createElement("strong");
      lead.textContent = row.lead;
      text.append(lead);
    }
    text.append(...withFileNames(row.text));
    if (row.devices?.length) text.append(deviceList(row.devices));
    item.append(text);
    return item;
  }));
}

/** The profile's devices under its line, each with the models it can be
 *  and its UDID, then where the visitor finds this iPhone's model. More
 *  than 3 fold away, as a signing service's profile can list many. */
function deviceList(devices) {
  const list = document.createElement("ul");
  list.className = "cert-devices";
  list.append(...devices.map(({ udid, models }) => {
    const item = document.createElement("li");
    const name = document.createElement("span");
    name.textContent = models;
    const id = document.createElement("span");
    id.className = "udid";
    id.textContent = udid;
    item.append(name, id);
    return item;
  }));
  const hint = document.createElement("p");
  hint.className = "cert-hint";
  hint.textContent = "Settings › General › About shows this iPhone's model.";
  if (devices.length <= 3) {
    const both = document.createDocumentFragment();
    both.append(list, hint);
    return both;
  }
  const fold = document.createElement("details");
  fold.className = "cert-fold";
  const summary = document.createElement("summary");
  summary.textContent = `Show the ${devices.length} devices`;
  fold.append(summary, list, hint);
  return fold;
}

/** `text` with .p12 and .mobileprovision set as file names. */
function withFileNames(text) {
  return text.split(/(\.p12|\.mobileprovision)\b/).map((part, index) => {
    if (index % 2 === 0) return part;
    const name = document.createElement("span");
    name.className = "file";
    name.textContent = part;
    return name;
  });
}

const blocked = () => Boolean(state.certificate?.blocked || state.apple?.state === "bad");

// MARK: Step 2: Atelier

fetch(SOURCE_URL)
  .then((response) => (response.ok ? response.json() : Promise.reject(new Error(`HTTP ${response.status}`))))
  .then((source) => {
    state.release = newestRelease(source);
    state.source = state.release ? "loaded" : "missing";
  })
  // Unreachable or unreadable: the page asks for the IPA as a file.
  .catch(() => { state.source = "missing"; })
  .finally(update);

$("choose-ipa").addEventListener("click", () => $("ipa-input").click());

$("ipa-input").addEventListener("change", async (event) => {
  const [file] = event.target.files;
  event.target.value = "";
  if (!file) return;
  reset();
  showProblem("ipa-problem", null);
  try {
    if (file.size > MAX_IPA) throw new Failure("This IPA is too large to sign here.");
    const bytes = new Uint8Array(await file.arrayBuffer());
    const info = await readAppInfo(bytes);
    if (info.bundleID !== ATELIER_BUNDLE_ID) throw new Failure("This IPA isn't Atelier. Choose Atelier's IPA from its releases.");
    state.chosen = { bytes, info };
  } catch (error) {
    showProblem("ipa-problem", messageOf(error));
  }
  update();
});

const include = $("include-certificate");
include.addEventListener("change", () => {
  // Before reset, which shows the switch as the state has it.
  state.wantsCertificate = include.checked;
  reset();
  update();
});

/** The IPA that's signed: the one the visitor chose, else the newest
 *  release's, once downloaded. */
const ipaInfo = () => state.chosen?.info ?? (state.downloaded?.url === state.release?.downloadURL ? state.downloaded?.info : null);

/** Whether the certificate goes in: Include Certificate is on, and the
 *  IPA reads it, which builds since 3 Nov 2026 do. Until the newest
 *  release is downloaded, the page can't tell, so it says it will. */
const includesCertificate = () => state.wantsCertificate && (ipaInfo()?.takesCertificate ?? true);

function showRelease() {
  const name = $("release-name");
  const meta = $("release-meta");
  if (state.chosen) {
    name.textContent = state.chosen.info.version ? `Atelier ${state.chosen.info.version}` : "Atelier";
    meta.textContent = `${formatSize(state.chosen.bytes.length)} · From your file`;
  } else if (state.release) {
    name.textContent = `Atelier ${state.release.version}`;
    meta.textContent = state.release.size ? `${formatSize(state.release.size)} · Newest release` : "Newest release";
  } else if (state.source === "missing") {
    name.textContent = "Atelier";
    meta.textContent = "The newest release can't be downloaded here right now";
  }
  $("release-file").hidden = !(state.chosen || state.source === "missing" || state.downloadFailed);

  const info = ipaInfo();
  const cannot = Boolean(info && !info.takesCertificate);
  include.checked = includesCertificate();
  $("include-text").textContent = cannot
    ? `${info.version ? `Atelier ${info.version}` : "This Atelier"} can't take a certificate this way, so you'll add it in Atelier's Get Ready.`
    : INCLUDE_TEXT;
}

// MARK: Signing and installing

$("sign-install").addEventListener("click", signAndInstall);
$("try-again").addEventListener("click", signAndInstall);

// Nothing on the page can change while it works, so only the install that
// follows can be left behind by a newer one.
async function signAndInstall() {
  const run = ++runs;
  const { files, certificate } = state;
  const secret = password.value;
  setStage("working");
  try {
    const ipa = state.chosen ?? await download(state.release);
    if (ipa.info.bundleID !== ATELIER_BUNDLE_ID) throw new Failure("This IPA isn't Atelier. Choose Atelier's IPA from its releases.");
    update();

    let packaged = null;
    if (includesCertificate()) {
      try {
        packaged = packagedCertificate({ p12: files.p12.data, profile: files.profile.data, password: secret });
      } catch (error) {
        if (!(error instanceof PlistError)) throw error;
        throw new Failure("Your certificate's password has a character Atelier can't keep with it. Turn off Include Certificate, and add your certificate in Atelier's Get Ready.");
      }
    }

    showProgress(`Signing with ${certificate.teamName}`);
    let signed;
    try {
      ({ ipa: signed } = await ask({ type: "sign", ipa: ipa.bytes, p12: files.p12.data, profile: files.profile.data, password: secret, packagedCertificate: packaged }));
    } finally {
      endSigner();
    }

    showProgress("Uploading", ofSize(0, signed.length), 0);
    const install = await upload(signed, (sent, total) => showProgress("Uploading", ofSize(sent, total), sent / total));

    $("install-link").href = install.install;
    $("open-text").textContent = packaged ? OPEN_WITH : OPEN_WITHOUT;
    setStage("installing");
    showProgress("Waiting for you to tap Install");
    // iOS's install alert. If Safari doesn't open it without a tap, the
    // Install Atelier button does.
    location.href = install.install;
    follow(install, Date.now(), () => run !== runs);
  } catch (error) {
    fail(error);
  }
}

/** The newest release's IPA, through this site (/ota/release), as
 *  GitHub's downloads can't be read by other sites' pages: {url, bytes,
 *  info}. Kept for signing it again. Throws a Failure. */
async function download(release) {
  if (state.downloaded?.url === release.downloadURL) return state.downloaded;
  const failure = (why) => {
    state.downloadFailed = true;
    return new Failure(`Atelier couldn't be downloaded: ${why}`);
  };
  showProgress("Downloading", release.size ? ofSize(0, release.size) : null, 0);
  let response;
  try {
    response = await fetch(`/ota/release?url=${encodeURIComponent(release.downloadURL)}`);
  } catch {
    throw failure("the connection was lost.");
  }
  if (!response.ok) {
    const { error } = await response.json().catch(() => ({}));
    // GitHub answered HTTP 404, or GitHub can't be reached.
    if (response.status === 502 && error) throw failure(error);
    if (response.status === 413) throw failure(`it's over ${MAX_IPA >> 20} MB.`);
    throw failure(`this site answered HTTP ${response.status}.`);
  }

  const total = Number(response.headers.get("Content-Length")) || release.size;
  const chunks = [];
  let received = 0;
  try {
    const reader = response.body.getReader();
    for (;;) {
      const { done, value } = await reader.read();
      if (done) break;
      chunks.push(value);
      received += value.length;
      if (received > MAX_IPA) {
        reader.cancel().catch(() => {});
        throw failure(`it's over ${MAX_IPA >> 20} MB.`);
      }
      showProgress("Downloading", total ? ofSize(received, total) : formatSize(received), total ? received / total : null);
    }
  } catch (error) {
    if (error instanceof Failure) throw error;
    throw failure("the connection was lost.");
  }
  const bytes = concat(chunks);
  if (release.sha256) {
    const digest = new Uint8Array(await crypto.subtle.digest("SHA-256", bytes));
    const hex = Array.from(digest, (byte) => byte.toString(16).padStart(2, "0")).join("");
    if (hex !== release.sha256) throw failure("it doesn't match the SHA-256 its source lists. Try again.");
  }
  const info = await readAppInfo(bytes);
  state.downloaded = { url: release.downloadURL, bytes, info };
  return state.downloaded;
}

/** Uploads the signed Atelier for iOS to install, telling `progress(sent,
 *  total)` how far it is, and resolves to this site's answer: {install,
 *  status, expires}. Throws a Failure. */
function upload(ipa, progress) {
  return new Promise((resolve, reject) => {
    const request = new XMLHttpRequest();
    request.open("POST", "/ota");
    request.responseType = "json";
    request.upload.onprogress = (event) => progress(event.loaded, event.lengthComputable ? event.total : ipa.length);
    request.onload = () => {
      const answer = request.response;
      if (request.status === 201 && typeof answer?.install === "string" && typeof answer?.status === "string") return resolve(answer);
      reject(new Failure(answer?.error
        ? `The signed Atelier couldn't be uploaded. ${answer.error}`
        : `The signed Atelier couldn't be uploaded: this site answered HTTP ${request.status}.`));
    };
    request.onerror = () => reject(new Failure("The signed Atelier couldn't be uploaded: the connection was lost."));
    request.send(new Blob([ipa], { type: "application/octet-stream" }));
  });
}

/** Follows the install until iOS has downloaded Atelier, as this site
 *  sees it: `waiting` until the visitor taps Install, then `downloading`,
 *  then `downloaded`. `uploaded` is when the upload ended, by this
 *  device's clock. */
async function follow({ status }, uploaded, stale) {
  for (;;) {
    await new Promise((resolve) => setTimeout(resolve, POLL_INTERVAL));
    if (stale()) return;
    let answer = null;
    let gone = false;
    try {
      const response = await fetch(status, { cache: "no-store" });
      gone = response.status === 404;
      if (response.ok) answer = await response.json();
    } catch {
      // Asked again in a moment.
    }
    if (stale()) return;
    // Gone before its 10 minutes means iOS downloaded it a minute ago, while
    // Safari was in the background and asked nothing.
    if (answer?.state === "downloaded" || (gone && Date.now() - uploaded < LIFETIME - 15_000)) return setStage("done");
    if (gone || Date.now() - uploaded > LIFETIME + 60_000) {
      return fail(new Failure("The signed Atelier was deleted after 10 minutes. Sign and install it again."), "Sign and Install");
    }
    if (answer?.state === "downloading") showProgress("Installing");
  }
}

function fail(error, again = "Try Again") {
  if (error?.detail) console.error(error.detail);
  else if (!(error instanceof Failure)) console.error(error);
  $("failed-text").textContent = messageOf(error);
  $("try-again").textContent = again;
  setStage("failed");
}

function messageOf(error) {
  return error instanceof Failure || error instanceof SignError ? error.message : "Atelier couldn't be installed. Try again.";
}

/** Back to Sign and Install, when the visitor changes the certificate or
 *  Atelier after an install began. Nothing changes while one is working,
 *  as the page doesn't let it. */
function reset() {
  if (state.stage === "idle" || state.stage === "working") return;
  runs++;
  setStage("idle");
}

// MARK: What the page shows

function setStage(stage) {
  state.stage = stage;
  $("start").hidden = stage !== "idle";
  $("progress").hidden = stage !== "working" && stage !== "installing";
  $("install-again").hidden = stage !== "installing";
  $("done").hidden = stage !== "done";
  $("failed").hidden = stage !== "failed";
  update();
}

// The bar's text: what's happening, read out, then how far, which isn't.
const progressStage = document.createElement("span");
const progressAmount = document.createElement("span");
progressAmount.setAttribute("aria-hidden", "true");
$("progress-text").replaceChildren(progressStage, progressAmount);

/** The bar says `what` and how far, `amount`, and fills its ring to
 *  `fraction`, or spins it when that's null. */
function showProgress(what, amount = null, fraction = null) {
  if (progressStage.textContent !== what) progressStage.textContent = what;
  progressAmount.textContent = amount ? ` · ${amount}` : "";
  $("progress-ring").classList.toggle("spin", fraction === null);
  $("progress-fill").setAttribute("stroke-dasharray", fraction === null ? "26 100" : `${Math.max(2, Math.round(fraction * 100))} 100`);
}

/** "3.1 of 8.4 MB": `done` in the unit formatSize gives `total`. */
function ofSize(done, total) {
  const [unit, scale] = [["GB", 1e9], ["MB", 1e6], ["KB", 1e3]].find(([, size]) => total >= size) ?? ["bytes", 1];
  const digits = scale > 1 ? 1 : 0;
  const number = (bytes) => (bytes / scale).toLocaleString("en", { minimumFractionDigits: digits, maximumFractionDigits: digits });
  return `${number(Math.min(done, total))} of ${number(total)} ${unit}`;
}

function showProblem(id, message) {
  const problem = $(id);
  problem.querySelector("span").textContent = message ?? "";
  problem.hidden = !message;
}

/** Everything that follows from the state: which steps are ahead, what
 *  can be tapped, and what step 3 says. */
function update() {
  const ready = Boolean(state.certificate) && !blocked();
  const working = state.stage === "working";
  const info = ipaInfo();

  $("choose-hint").textContent = state.checking ? "Checking…" : "From Files, iCloud Drive or a ZIP";
  $("choose-hint").hidden = !state.checking && Boolean(state.files.p12 && state.files.profile);
  showProblem("files-problem", state.pickProblem ?? state.checkProblem);
  for (const control of [$("choose-files"), password, $("choose-ipa")]) control.disabled = working;

  $("step-sign").classList.toggle("later", !ready);
  $("sign-lede").textContent = !ready
    ? "Choose your certificate first."
    : device === "ready" ? "iOS asks before it installs Atelier. Tap Install." : "Open this page in Safari on your iPhone to install it.";
  showRelease();
  include.disabled = !ready || working || Boolean(info && !info.takesCertificate);
  $("sign-install").disabled = !ready || !state.apple || device !== "ready" || !(state.chosen || state.release);

  $("step-open").classList.toggle("later", state.stage !== "done");
  if (state.stage === "idle") $("open-text").textContent = includesCertificate() ? OPEN_WITH : OPEN_WITHOUT;
  showOpenNote();
}

/** What iOS asks before Atelier opens, for the certificate's kind
 *  (CertificateNotes). */
function showOpenNote() {
  const kind = state.certificate?.kind;
  const note = $("open-note");
  note.hidden = !["development", "adHoc", "enterprise"].includes(kind);
  if (note.hidden) return;
  if (kind === "enterprise") {
    $("open-note-title").textContent = "Trust the developer first";
    $("open-note-text").textContent = "iOS opens your certificate's apps once you trust its developer. Open Settings › General › VPN & Device Management, tap the developer under Enterprise App, then Trust.";
  } else {
    $("open-note-title").textContent = "Turn on Developer Mode first";
    $("open-note-text").textContent = "Your certificate's apps need it. Open Atelier once so iOS asks, then turn it on in Settings › Privacy & Security › Developer Mode. Your iPhone restarts.";
  }
}

update();
