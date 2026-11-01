# dmm-main-builds

Unofficial Windows builds of [Deadlock Mod Manager](https://github.com/deadlock-mod-manager/deadlock-mod-manager)'s `main` branch, for my own use. Not affiliated with or supported by the DMM team. For normal use, get the official release or nightly instead.

## How it works

- **Picking a commit.** Every 15 minutes, [the workflow](.github/workflows/build.yml) picks the newest upstream `main` commit where:
  - upstream's `Type Check`, `Run Tests` and `Run Rust Tests` passed;
  - none of its E2E scenario checks failed.
- **Skipping.** It does nothing if that commit is already built, or if it changed nothing under `apps/desktop`, `packages` or the lockfiles.
- **Building.** It builds a standalone `deadlock-mod-manager.exe` with upstream's nightly compiler settings: release, thin LTO and 16 codegen units. There's no installer and no code signing.
- **Publishing.** Each build is a release tagged `main-<commit>`, with `manifest.json` (commit, version, SHA-256). The newest 15 are kept.
- **Opening it.** [`launcher/dmm-main.ps1`](launcher/dmm-main.ps1) opens the newest build on my PC with `--disable-auto-update`. Before switching to a new build it saves a snapshot of the app's state.

## License

Deadlock Mod Manager is GPL-3.0 (`LICENSE.md` is attached to every release). Each release links the exact upstream commit it was built from, which is its complete source. The workflow and launcher here are under the same license.
