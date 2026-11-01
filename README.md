# dmm-main-builds

Unofficial personal Windows builds of [Deadlock Mod Manager](https://github.com/deadlock-mod-manager/deadlock-mod-manager)'s `main` branch. Not affiliated with or supported by the DMM team. For normal use, get the official release or nightly instead.

## What you get

- **Installing.** It installs over the official Deadlock Mod Manager, in the same folder with the same data, so it opens the same way as before: Start menu, taskbar, tray, autostart and `deadlock-mod-manager://` links.
- **Updates.** When the app opens it offers the newest personal build, the same way the official app offers updates. It only accepts strictly newer personal builds, signed with this repo's key. Official releases and nightlies are never offered or installed.
- **The sidebar label.** It shows something like `v2.3.0 +163 · Main`: 163 upstream commits past the newest official release (nightly or stable). Hover over it for the exact commit.
- **Backups.** Before every install or update, the installer waits for DMM to close and copies both app-data folders to `%USERPROFILE%\dmm-backups\`. It keeps the newest 10. If the backup fails, the update is cancelled and the current version stays.

## How a build is made

[The workflow](.github/workflows/build.yml) runs every 15 minutes:

1. **Pick.** It picks the newest upstream `main` commit where `Type Check`, `Run Tests` and `Run Rust Tests` passed and no E2E scenario check failed.
2. **Name.** It names the build after the most recently published official Windows release, which must be in `main`'s history. The version is `C-main.<run>.<commits>+g<commit>`, e.g. `2.3.1-main.57.163+g0ca70a40`. `C` is one patch above the official version, so every build sorts above the official install it replaces and above every earlier personal build. The sidebar shows the readable form.
3. **Build.** It applies [`personal/patches`](personal/patches) and fails if they don't apply exactly. Then it builds the NSIS installer with upstream's nightly settings (thin LTO, 16 codegen units) and signs it for the updater.
4. **Test.** [`personal/migration-test.ps1`](personal/migration-test.ps1) runs on a fresh Windows runner. It installs the official nightly with made-up data, then this build over it. It checks the version, the data, the backup, update-mode installs, shortcuts, link handlers, and that it won't install over a running DMM.
5. **Publish.** It publishes the release and keeps the newest 15.

## Changes from upstream

These are only the patches in `personal/patches` and `personal/stamp.mjs`:
- the update feed points here, and the signing key is this repo's;
- updates must be strictly newer;
- the sidebar label and tooltip, and the release-notes link going to this build's release;
- "What's New" doesn't open by itself after every build;
- [`personal/installer-hooks.nsh`](personal/installer-hooks.nsh) runs [`personal/dmm-backup.ps1`](personal/dmm-backup.ps1) before installing.

## Going back to official

Close DMM and restore a backup from `%USERPROFILE%\dmm-backups\` if needed. Then run the official installer from [upstream releases](https://github.com/deadlock-mod-manager/deadlock-mod-manager/releases).

## License

Deadlock Mod Manager is GPL-3.0 (`LICENSE.md`, also attached to every release). Each release links the exact upstream commit and attaches the patches applied to it, which together are its complete source. Everything here is under the same license.
