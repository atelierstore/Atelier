// The builds GitHub Actions makes of pull requests and main (build.yml in
// .github/workflows), kept here for 7 days so Safari and Atelier's install
// links can download them: GitHub keeps a run's files behind a sign-in. The
// build job sends them with the token GitHub gives it to prove which repo,
// workflow and run it is (github-oidc.js), so the site keeps no key for it,
// and only BUILDS_REPOSITORY's build workflow can send them. Pull requests
// from forks get no such token, so theirs aren't kept.
//
// Each IPA is kept by a Durable Object of its own (BuildApp), named by a
// random token in its address, as the certificate page's uploads are
// (ota.js). The build's record, with all its addresses, goes to the BUILDS KV
// namespace, which only Cloudflare API tokens for the site's account can
// read. The run's log, which anyone can read in a public repo, shows only the
// unsigned IPA's addresses, as the signed one's profile lists the
// maintainer's iPhones.

import { GitHubKeys, KeysError, TokenError, verifyToken } from "./github-oidc.js";
import { HEADERS, json } from "./http.js";
import { MAX_SIZE, SignedApp, kept, manifest, newToken, rangeOnly } from "./ota.js";

/** How long a build is kept, in milliseconds: as long as Codemagic's links
 *  to its builds lasted. */
export const LIFETIME = 7 * 24 * 60 * 60 * 1000;
/** The files a build has: the IPA signed with the maintainer's profile, and
 *  the unsigned one, which Atelier signs as it installs it. */
export const FILES = new Set(["Atelier.ipa", "Atelier-unsigned.ipa"]);
/** The signed one, the one iOS's install alert can install. */
const SIGNED = "Atelier.ipa";
/** The events whose builds are kept: what build.yml's callers run on. */
const EVENTS = new Set(["push", "pull_request", "workflow_dispatch"]);

const TOKEN = /^[0-9a-f]{32}$/;
const COMMIT = /^[0-9a-f]{40}$/;

/** GitHub's signing keys, for this Worker instance. */
const githubKeys = new GitHubKeys();

/** Answers the build job, and those who install its builds, `apps` being
 *  BuildApp's namespace:
 *  - POST /builds/<file>, with the IPA as the body and the job's token as
 *    Authorization: Bearer <token>, keeps it, and answers 201 with {url,
 *    expires}. <file> is one of FILES.
 *  - POST /builds, with the token and {commit, files: [{url, signed}]} as
 *    JSON, `url` an address the site gave for one of the build's files,
 *    records the build in BUILDS and answers 201 with its record (see
 *    record() below).
 *  - GET or HEAD /builds/<token>/<file> is the IPA, or the part a Range
 *    header asks for, and GET /builds/<token>/manifest.plist the manifest
 *    iOS's install alert reads, for a signed IPA.
 *  - GET or HEAD /builds/<token>/install, for a signed IPA, redirects to its
 *    itms-services:// link, so that a link to it opens iOS's install alert
 *    in Safari, as Codemagic's links to its builds did. Chats, and other
 *    places that only link https:// addresses, can link it.
 *  A token that isn't GitHub's, or is another repo's or workflow's, gets a
 *  401 or 403, and an IPA that isn't Atelier a 422, each with {error}.
 *  `keys` is for tests. */
export async function builds(request, env, apps, { keys = githubKeys } = {}) {
  const url = new URL(request.url);
  const [, , first, second, ...rest] = url.pathname.split("/");
  if (rest.length) return notFound();

  if (second === undefined) {
    if (request.method !== "POST") return notAllowed("POST");
    if (first !== undefined && !FILES.has(first)) return notFound();
    const { claims, refusal } = await authorize(request, env, keys);
    if (refusal) return refusal;
    return first === undefined ? record(request, env, apps, claims) : upload(request, apps, first);
  }

  if (!TOKEN.test(first)) return notFound();
  const app = apps.get(apps.idFromName(first));
  if (second === "manifest.plist") {
    if (request.method !== "GET") return notAllowed("GET");
    const info = await kept(app);
    if (!info?.file) return notFound();
    return new Response(manifest({
      ...info,
      ipa: `${url.origin}/builds/${first}/${info.file}`,
      image: `${url.origin}/apple-touch-icon.png`,
    }), { headers: { "Content-Type": "application/xml; charset=utf-8", ...HEADERS } });
  }
  if (second === "install") {
    if (request.method !== "GET" && request.method !== "HEAD") return notAllowed("GET, HEAD");
    if ((await kept(app))?.file !== SIGNED) return notFound();
    return new Response(null, {
      status: 302,
      headers: { Location: itmsServices(`${url.origin}/builds/${first}/manifest.plist`), ...HEADERS },
    });
  }
  if (!FILES.has(second)) return notFound();
  if (request.method !== "GET" && request.method !== "HEAD") return notAllowed("GET, HEAD");
  return app.fetch(`https://build-app/ipa?file=${encodeURIComponent(second)}`, {
    method: request.method,
    headers: rangeOnly(request),
  });
}

/** The claims of the request's token, once it's checked as a token of
 *  BUILDS_REPOSITORY's build workflow, or the answer that refuses it. */
async function authorize(request, env, keys) {
  const repository = env.BUILDS_REPOSITORY;
  if (!repository) return { refusal: json({ error: "This site doesn't keep builds." }, 403) };
  const bearer = /^Bearer\s+(\S+)$/i.exec(request.headers.get("Authorization") ?? "");
  if (!bearer) return { refusal: unauthorized("There's no GitHub Actions token.") };

  let claims;
  try {
    claims = await verifyToken(bearer[1], { audience: new URL(request.url).origin, keys });
  } catch (error) {
    if (error instanceof TokenError) return { refusal: unauthorized(`The token isn't accepted: ${error.message}.`) };
    if (error instanceof KeysError) return { refusal: json({ error: `${error.message}.` }, 503) };
    throw error;
  }

  // GitHub's names ignore case.
  const same = (a, b) => String(a ?? "").toLowerCase() === String(b).toLowerCase();
  if (!same(claims.repository, repository)) return { refusal: forbidden(`Only ${repository}'s builds are kept.`) };
  // A repo made later under the same name has another ID.
  if (env.BUILDS_REPOSITORY_ID && String(claims.repository_id) !== String(env.BUILDS_REPOSITORY_ID)) {
    return { refusal: forbidden(`Only ${repository}'s builds are kept.`) };
  }
  const workflow = `${repository}/.github/workflows/build.yml@`.toLowerCase();
  if (!String(claims.job_workflow_ref ?? "").toLowerCase().startsWith(workflow)) {
    return { refusal: forbidden("Only build.yml's builds are kept.") };
  }
  if (claims.runner_environment !== "github-hosted") return { refusal: forbidden("Only builds on GitHub's own runners are kept.") };
  if (!EVENTS.has(claims.event_name)) return { refusal: forbidden(`Builds of ${claims.event_name} events aren't kept.`) };
  return { claims };
}

async function upload(request, apps, file) {
  // The object checks the size too, as a body needn't say it.
  if (Number(request.headers.get("Content-Length")) > MAX_SIZE) return tooLarge();
  if (!request.body) return json({ error: "There's no IPA." }, 400);
  const token = newToken();
  const response = await apps.get(apps.idFromName(token)).fetch(`https://build-app/ipa?file=${encodeURIComponent(file)}`, {
    method: "PUT",
    body: request.body,
    // For Node, where the tests run; the Workers runtime ignores it.
    duplex: "half",
  });
  if (!response.ok) return response;
  const { expires } = await response.json();
  return json({
    url: `${new URL(request.url).origin}/builds/${token}/${file}`,
    expires: new Date(expires).toISOString(),
  }, 201);
}

/** Records a build whose files were uploaded, from the job's claims and
 *  what the request says, and answers with its record:
 *  {repository, commit, branch, pr, version, build, run, runID, created,
 *  expires, files: [{name, url, signed, size, install, safari}], install}.
 *  `commit` is the commit the build is of, which the request says, as a
 *  pull request's build is of its merge into main, `pr` its pull request's
 *  number or null, and `version` and `build` its Info.plist's. A signed
 *  file's `install` is its itms-services:// link, and its `safari` the
 *  https:// address that redirects there (/builds/<token>/install), to open
 *  in Safari. The record's `install` is the https:// link that installs the
 *  unsigned one with Atelier. BUILDS keeps it, when the site has it, as
 *  commit/<commit>, branch/<branch> and pr/<pr>, the last two unless a
 *  later run's build is there, until the files go. */
async function record(request, env, apps, claims) {
  let body;
  try {
    body = await request.json();
  } catch {
    return json({ error: "The build isn't JSON." }, 400);
  }
  const origin = new URL(request.url).origin;
  const entries = Array.isArray(body?.files) ? body.files : [];
  if (!entries.length || entries.length > FILES.size) return json({ error: "A build has one or two files." }, 400);

  const files = [];
  let info;
  for (const entry of entries) {
    const [, token, name] = /^\/builds\/([0-9a-f]{32})\/([^/]+)$/.exec(fileURL(entry?.url, origin)?.pathname ?? "") ?? [];
    const stored = token && FILES.has(name) && (await kept(apps.get(apps.idFromName(token))));
    if (!stored || stored.file !== name) return json({ error: `${entry?.url} isn't one of this site's builds.` }, 422);
    if (files.some((file) => file.name === name)) return json({ error: `The build has ${name} twice.` }, 400);
    info ??= stored;
    const signed = entry.signed === true;
    files.push({
      name,
      url: `${origin}/builds/${token}/${name}`,
      signed,
      size: stored.size,
      expires: stored.expires,
      ...(signed ? {
        install: itmsServices(`${origin}/builds/${token}/manifest.plist`),
        safari: `${origin}/builds/${token}/install`,
      } : {}),
    });
  }

  const pr = /^refs\/pull\/(\d+)\/merge$/.exec(claims.ref ?? "")?.[1];
  const unsigned = files.find((file) => !file.signed);
  const build = {
    repository: claims.repository,
    commit: COMMIT.test(body.commit ?? "") ? body.commit : claims.sha,
    branch: claims.head_ref || String(claims.ref ?? "").replace(/^refs\/heads\//, ""),
    pr: pr ? Number(pr) : null,
    version: info.version,
    build: info.build,
    run: `https://github.com/${claims.repository}/actions/runs/${claims.run_id}`,
    runID: Number(claims.run_id),
    created: new Date().toISOString(),
    expires: new Date(Math.min(...files.map((file) => file.expires))).toISOString(),
    files: files.map(({ expires, ...file }) => file),
    install: unsigned ? `${origin}/install?url=${encodeURIComponent(unsigned.url)}` : null,
  };
  if (env.BUILDS) await index(env.BUILDS, build);
  return json(build, 201);
}

/** Writes `build` to the KV namespace `kv` under its keys, until it goes. */
async function index(kv, build) {
  const value = JSON.stringify(build);
  const expiration = Math.floor(Date.parse(build.expires) / 1000);
  const keys = [`commit/${build.commit}`];
  for (const key of [`branch/${build.branch}`, build.pr ? `pr/${build.pr}` : null]) {
    if (!key) continue;
    // Runs can finish in another order than they started in.
    const there = await kv.get(key, "json");
    if (!(there?.runID > build.runID)) keys.push(key);
  }
  await Promise.all(keys.map((key) => kv.put(key, value, { expiration })));
}

/** `address` as a URL, when it's on `origin`, or null. */
function fileURL(address, origin) {
  if (typeof address !== "string") return null;
  try {
    const url = new URL(address);
    return url.origin === origin && !url.search && !url.hash ? url : null;
  } catch {
    return null;
  }
}

function itmsServices(manifestURL) {
  return `itms-services://?action=download-manifest&url=${encodeURIComponent(manifestURL)}`;
}

// MARK: The Durable Object

/** Keeps one IPA of a build for LIFETIME, however often it's downloaded, as
 *  SignedApp keeps the certificate page's. */
export class BuildApp extends SignedApp {
  static lifetime = LIFETIME;
  // CI's builds aren't the site's installs.
  static counted = false;

  async downloaded() {}
}

function notFound() {
  return json({ error: "There's nothing here, or it has gone." }, 404);
}

function notAllowed(methods) {
  return json({ error: "method not allowed" }, 405, { Allow: methods });
}

function unauthorized(error) {
  return json({ error }, 401, { "WWW-Authenticate": "Bearer" });
}

function forbidden(error) {
  return json({ error }, 403);
}

function tooLarge() {
  return json({ error: `The IPA is over ${MAX_SIZE >> 20} MB.` }, 413);
}
