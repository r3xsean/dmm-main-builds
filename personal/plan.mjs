// Picks what to build and how to label it. Runs in the `pick` job.
// Writes GitHub Actions outputs; exits non-zero (failing the run) on anything ambiguous.
//
// - Candidate: newest upstream `main` commit whose required CI passed and whose
//   E2E scenario checks (if any ran) didn't fail.
// - Anchor: the most recently published official Windows release (stable `v*` or
//   the rolling `nightly`), read from its updater manifest. It must be in the
//   candidate's history; if not, the run fails rather than mislabel the build.
// - Version: C-main.<run_number>.<N>+g<sha8>, where N = commits from anchor to
//   candidate and C never goes down and always sorts above the anchor.
import { appendFileSync } from "node:fs";
import { execFileSync } from "node:child_process";
import semver from "semver";

const UPSTREAM = process.env.UPSTREAM;
const SELF = process.env.GITHUB_REPOSITORY;
const REQUIRED = (process.env.REQUIRED_CHECKS ?? "").split("|").filter(Boolean);
const RUN = process.env.GITHUB_RUN_NUMBER;
const PATCH_REV = process.env.GITHUB_SHA;
const FORCE = process.env.FORCE === "true";
const INPUT_SHA = process.env.INPUT_SHA ?? "";

const out = (k, v) => appendFileSync(process.env.GITHUB_OUTPUT, `${k}=${v}\n`);
const stop = (why) => { console.log(why); out("build", "false"); process.exit(0); };
const fail = (why) => { console.error(`::error::${why}`); process.exit(1); };

const gh = (path, { allow404 = false } = {}) => {
  try {
    return JSON.parse(execFileSync("gh", ["api", "-H", "Accept: application/vnd.github+json", path], { encoding: "utf8", maxBuffer: 64 << 20 }));
  } catch (e) {
    if (allow404 && /HTTP 404/.test(String(e.stderr ?? e.message))) return null;
    fail(`GitHub API ${path} failed: ${String(e.stderr ?? e.message).trim()}`);
  }
};
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
// Reads a JSON release asset. The assets API is tried first, with retries,
// because the browser download link sometimes returns 5xx for hours.
const readAsset = async (asset) => {
  const errors = [];
  for (let attempt = 1; attempt <= 3; attempt++) {
    try {
      return JSON.parse(execFileSync("gh", ["api", "-H", "Accept: application/octet-stream", asset.url], { encoding: "utf8", maxBuffer: 64 << 20 }));
    } catch (e) {
      errors.push(String(e.stderr ?? e.message).trim());
      await sleep(attempt * 5000);
    }
  }
  const res = await fetch(asset.browser_download_url, { headers: { "User-Agent": "dmm-main-builds" }, redirect: "follow" });
  if (res.ok) return res.json();
  fail(`Download of ${asset.name} failed: API: ${errors.at(-1)}; ${asset.browser_download_url}: HTTP ${res.status}`);
};

// 1. Candidate
const eligible = (sha) => {
  const runs = gh(`repos/${UPSTREAM}/commits/${sha}/check-runs?per_page=100`).check_runs;
  for (const name of REQUIRED) {
    const last = runs.filter((r) => r.name === name).sort((a, b) => (a.started_at ?? "").localeCompare(b.started_at ?? "")).at(-1);
    if (!last || last.status !== "completed" || last.conclusion !== "success") return false;
  }
  return !runs.some((r) => /scenarios/.test(r.name) && r.status === "completed" && !["success", "skipped", "neutral"].includes(r.conclusion));
};
let sha = INPUT_SHA ? gh(`repos/${UPSTREAM}/commits/${INPUT_SHA}`).sha : "";
if (!sha) {
  for (const c of gh(`repos/${UPSTREAM}/commits?sha=main&per_page=30`)) {
    if (eligible(c.sha)) { sha = c.sha; break; }
  }
}
if (!sha) stop("No eligible commit among the latest 30 on main.");
let short = sha.slice(0, 8);

// 2. Anchor: most recently published official Windows release
const releases = gh(`repos/${UPSTREAM}/releases?per_page=30`)
  .filter((r) => !r.draft && (r.tag_name === "nightly" || /^v\d+\.\d+\.\d+$/.test(r.tag_name)))
  .sort((a, b) => b.published_at.localeCompare(a.published_at) || b.id - a.id);
let anchor = null;
for (const r of releases) {
  const asset = r.assets.find((a) => a.name === "latest.json");
  if (!asset) continue;
  const manifest = await readAsset(asset);
  const platforms = manifest.platforms ?? {};
  if (!platforms["windows-x86_64-nsis"] && !platforms["windows-x86_64"]) continue;
  if (!semver.valid(manifest.version)) fail(`Official ${r.tag_name} has an invalid version ${manifest.version}`);
  let ref = gh(`repos/${UPSTREAM}/git/ref/tags/${r.tag_name}`).object;
  while (ref.type === "tag") ref = gh(`repos/${UPSTREAM}/git/tags/${ref.sha}`).object;
  anchor = { tag: r.tag_name, id: r.id, published: r.published_at, version: manifest.version, sha: ref.sha };
  break;
}
if (!anchor) fail("No published official Windows release found.");
// The rolling nightly may have moved while we resolved it.
const recheck = gh(`repos/${UPSTREAM}/releases/${anchor.id}`);
if (recheck.published_at !== anchor.published) fail(`Official ${anchor.tag} changed while being read; next run will retry.`);

let cmp = gh(`repos/${UPSTREAM}/compare/${anchor.sha}...${sha}`);
// Upstream shipped a newer commit than any that passed the gate (e.g. its E2E
// is red but it published the nightly anyway). Build what upstream shipped.
if (cmp.status === "behind" && !INPUT_SHA) {
  const onMain = gh(`repos/${UPSTREAM}/compare/${anchor.sha}...main`).status;
  if (!["ahead", "identical"].includes(onMain)) fail(`Official ${anchor.tag} at ${anchor.sha.slice(0, 8)} isn't on main (status: ${onMain}).`);
  console.log(`Newest commit passing the gate (${short}) is older than official ${anchor.tag}; building ${anchor.sha.slice(0, 8)}, which upstream shipped.`);
  sha = anchor.sha;
  short = sha.slice(0, 8);
  cmp = { status: "identical", ahead_by: 0 };
}
if (!["ahead", "identical"].includes(cmp.status)) {
  fail(`Official ${anchor.tag} (${anchor.version}, ${anchor.sha.slice(0, 8)}) isn't in main's history at ${short} (status: ${cmp.status}). Not publishing a build that would claim to be past it.`);
}
const n = cmp.ahead_by;

// 3. Previous personal build (the only ordering state)
const latest = gh(`repos/${SELF}/releases/latest`, { allow404: true });
let prev = null;
if (latest) {
  const m = latest.assets.find((a) => a.name === "manifest.json");
  if (!m) fail(`Latest personal release ${latest.tag_name} has no manifest.json.`);
  prev = await readAsset(m);
  if (!semver.valid(prev.version)) fail(`Latest personal release has an invalid version ${prev.version}`);
}

if (!FORCE && prev?.format === 2 && prev.sha === sha && prev.anchor?.version === anchor.version && prev.patchRev === PATCH_REV) {
  stop(`${short} is already built with the same anchor and patches.`);
}
if (!FORCE && prev?.format === 2 && prev.anchor?.version === anchor.version && prev.patchRev === PATCH_REV) {
  const files = gh(`repos/${UPSTREAM}/compare/${prev.sha}...${sha}`).files ?? [];
  if (!files.some((f) => /^(apps\/desktop\/|packages\/|pnpm-lock\.yaml$|package\.json$|Cargo\.lock$)/.test(f.filename))) {
    stop(`No app changes between ${prev.sha.slice(0, 8)} and ${short}.`);
  }
}

// 4. Version
const anchorCore = `${semver.major(anchor.version)}.${semver.minor(anchor.version)}.${semver.patch(anchor.version)}`;
let core = semver.inc(anchorCore, "patch");
if (prev) {
  const prevCore = `${semver.major(prev.version)}.${semver.minor(prev.version)}.${semver.patch(prev.version)}`;
  if (semver.gt(prevCore, core)) core = prevCore;
}
const version = `${core}-main.${RUN}.${n}+g${short}`;
if (!semver.valid(version)) fail(`Generated an invalid version ${version}`);
if (prev && !semver.gt(version, prev.version)) fail(`${version} isn't newer than the last published ${prev.version}.`);

const nightlyDate = anchor.version.match(/-nightly\.(\d{4})(\d{2})(\d{2})\./);
const anchorName = anchor.tag === "nightly"
  ? `nightly ${nightlyDate ? `${nightlyDate[1]}-${nightlyDate[2]}-${nightlyDate[3]}` : anchor.published.slice(0, 10)}`
  : `v${anchor.version}`;
const label = `${anchorCore} +${n}`;
const detail = `${n} commit${n === 1 ? "" : "s"} past official ${anchorName} · source ${short}`;

console.log(`Building ${version}: ${detail}`);
out("build", "true");
out("sha", sha);
out("short", short);
out("version", version);
out("tag", `main-${RUN}`);
out("label", label);
out("detail", detail);
out("anchor_tag", anchor.tag);
out("anchor_version", anchor.version);
out("anchor_sha", anchor.sha);
out("n", String(n));
out("prev_sha", prev?.sha ?? "");
