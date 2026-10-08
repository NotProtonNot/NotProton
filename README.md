# NotProton

Play Windows games from the native macOS Steam app, powered by CrossOver.

**[Download NotProton.zip](https://github.com/schroedernils/NotProton/releases/download/v1.1.0-preview.2/NotProton.zip)** · [Release notes](https://github.com/schroedernils/NotProton/releases/tag/v1.1.0-preview.2)

This is a contribution fork of [NotProton](https://github.com/NotProtonNot/NotProton), with installation fixes, clearer status messages and guided setup. It is not an official upstream release.

## Requirements

* Apple Silicon and macOS 26 or later for this download.
* The native Steam app in `/Applications/Steam.app`, opened and signed in once.
* An activated, supported CrossOver build. NotProton is free; CrossOver is a separate paid product.
* Internet access for required Steam components and space for runtime copies and games.

Supported profiles are **CrossOver 26.3** (`26.3.0.39832`) and **Preview 20260821 / 20261006** (`27.0.0.40921` / `27.0.0.41069`). The app checks the actual binaries. Start with Rosetta; FEX is experimental.

## Install

1. Unzip the download, copy **NotProton.app** to **Applications** and open it.
2. Follow the setup guide. If Steam access is blocked, open **System Settings → Privacy & Security → App Management** and enable NotProton. If it is missing, click **+** and add `/Applications/NotProton.app`. Return to the app and continue after the green check.
3. Quit games before installing the integration. Finish the runtime step, then click **Open Steam**.
4. In Steam, open a Windows game’s **Properties → Compatibility**. Enable **Force the use of a specific Steam Play compatibility tool**, then choose **CrossOver** in the dropdown and click **Play**.

That checkbox is in Steam’s **Compatibility** page. macOS Accessibility permission is not required to select CrossOver. Reopen setup from **Settings** at the bottom of the sidebar.

The download is ad hoc signed and not Apple-notarized. If macOS blocks it and you trust the download, use the individual **Open Anyway** option under Privacy & Security. Keep Gatekeeper enabled. Automatic app updates are disabled in this preview.

## Help and limits

Use **Help** for setup and game issues. **Game environments** contains Windows components and prefix tools; **Backups** protects those environments before changes.

Game compatibility varies. Anti-cheat and some launchers can fail. This fork does not add free Wine runtimes, import existing CrossOver bottles or support every CrossOver version. Native-only Mac library filtering is [not yet fixed](docs/ISSUE_48.md).

[Full installation steps](docs/INSTALLATION.md) · [Validation and build notes](docs/VALIDATION.md) · [Contribution proposal](docs/PR_PROPOSAL.md)

## Source and licenses

Build instructions and dependencies are recorded in the [app workflow](.github/workflows/app.yml) and Makefile. A full installer needs the staged runtime payload; a Swift UI build alone is insufficient.

NotProton and its dependencies retain their original licenses. See [NOTICE](NOTICE) and [LICENSE](LICENSE).
