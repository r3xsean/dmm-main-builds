// Prepares the upstream checkout for a personal build. Runs at the repo root of
// the upstream checkout. Fails loudly if anything it expects is missing.
//   - sets the app version
//   - relabels the "Nightly" badge and tooltip in every locale
//   - writes the Tauri config overlay (personal update feed and key, no
//     downgrades, the backup hook)
import { readFileSync, writeFileSync, readdirSync } from "node:fs";
import { join, resolve } from "node:path";

const { VERSION, DETAIL, PERSONAL_DIR, OVERLAY } = process.env;
for (const [k, v] of Object.entries({ VERSION, DETAIL, PERSONAL_DIR, OVERLAY })) {
  if (!v) throw new Error(`${k} is not set`);
}

const pkgPath = "apps/desktop/package.json";
const pkg = JSON.parse(readFileSync(pkgPath, "utf8"));
pkg.version = VERSION;
writeFileSync(pkgPath, `${JSON.stringify(pkg, null, 2)}\n`);

const localeDir = "apps/desktop/src/locales";
let relabelled = 0;
for (const file of readdirSync(localeDir).filter((f) => f.endsWith(".json"))) {
  const path = join(localeDir, file);
  const data = JSON.parse(readFileSync(path, "utf8"));
  if (!data.branding) continue;
  data.branding.nightlyBuild = "Main";
  data.branding.fullBuildVersion = `${DETAIL} · {{version}}`;
  writeFileSync(path, `${JSON.stringify(data, null, 2)}\n`);
  relabelled++;
}
const en = JSON.parse(readFileSync(join(localeDir, "en.json"), "utf8"));
if (en.branding?.nightlyBuild !== "Main") throw new Error("en.json has no branding.nightlyBuild to relabel");

const conf = JSON.parse(readFileSync("apps/desktop/src-tauri/tauri.conf.json", "utf8"));
if (!conf.plugins?.updater?.pubkey) throw new Error("tauri.conf.json no longer has plugins.updater.pubkey");

const overlay = {
  bundle: {
    createUpdaterArtifacts: false,
    windows: {
      allowDowngrades: false,
      nsis: { installerHooks: resolve(PERSONAL_DIR, "installer-hooks.nsh") },
    },
  },
  plugins: {
    updater: {
      // Already base64, the same form as upstream's pubkey.
      pubkey: readFileSync(resolve(PERSONAL_DIR, "updater.pub"), "utf8").trim(),
      endpoints: ["https://github.com/r3xsean/dmm-main-builds/releases/latest/download/latest.json"],
    },
  },
};
writeFileSync(OVERLAY, JSON.stringify(overlay, null, 2));
console.log(`version ${VERSION}; relabelled ${relabelled} locales; overlay at ${OVERLAY}`);
