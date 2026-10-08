# NotProton

Play supported Windows games from the macOS Steam app, using CrossOver behind the scenes.

NotProton enables Steam Play in the native Steam client and provides the bridge Windows games use to talk to it. You keep one Steam library and choose the compatibility tool in each game's Steam properties.

**This repository is a contribution fork of [NotProton](https://github.com/NotProtonNot/NotProton), based on its `dev-1.1.0` branch.** It adds installation fixes, clearer status messages, guided setup and help. These changes have not been merged upstream. An experimental Apple Silicon test build is available from this fork’s releases.

[Download test build](https://github.com/schroedernils/NotProton/releases/tag/v1.1.0-contribution.1) · [Deutsche Anleitung](docs/DE.md) · [Compatibility and troubleshooting](#when-something-does-not-work) · [Build from source](#for-developers)

## What you can do

* Install the Steam integration with a native macOS app.
* Follow five short setup pages with app icons, readiness boxes and optional details, covering requirements, macOS permissions, installation, CrossOver setup and the first game.
* Use the supported CrossOver Stable and Preview profiles below. Choose Rosetta or FEX where the profile provides both.
* Choose a compatibility tool and game graphics/input options in Steam's **Properties → Compatibility** page.
* Inspect game environments, run a program inside one, back them up and rebuild them. These environments are also called Wine prefixes.
* Find searchable help and preview a support summary before copying it. The summary excludes account data, paths, license details and raw logs. It is never uploaded automatically.

You can expand help, setup details and maintenance by clicking anywhere on their heading row. Steam and CrossOver icons are read from your installed apps, with a fallback when an app is missing. No separate logo assets are distributed.

The new setup and help pages are available in English and German. Existing advanced tools retain their current English labels.

## What you need

* macOS 26 or later for this app. Local gameplay validation was on Apple Silicon. Intel Macs and older macOS versions have not been validated with this contribution.
* The **macOS** Steam app in `/Applications/Steam.app`. Open it and sign in once before setting up NotProton.
* An activated, supported CrossOver build. NotProton is free; CrossOver is a separate paid product. CrossOver's license rules still apply.
* Internet access when the installer needs to fetch the pinned Valve components.
* Enough free disk space for a runtime copy, each game's Windows environment and any backups. Sizes vary by game; the app reports measured storage after setup.

### Supported CrossOver profiles

| Release | Exact bundle build | Runtime options |
| --- | --- | --- |
| Stable 26.3 | `26.3.0.39832` | Rosetta |
| Preview 20260821 | `27.0.0.40921` | Rosetta build, or FEX build with FEX and Rosetta tools |
| Preview 20261006 | `27.0.0.41069` | Rosetta build, or FEX build with FEX and Rosetta tools |

Stable support already comes from the upstream development branch. This contribution makes the release, build number and runtime flavor easier to distinguish.

A release name is not enough to establish support. NotProton checks the actual binaries against verified profiles before patching a separate runtime copy. Other CrossOver builds are not automatically compatible. Start with Rosetta; FEX is experimental and its gameplay was not tested for this contribution.

Steam also needs compatible native hooks and interface patches. Steam client build `1788652215` was used in the local gameplay test. Signature profiles for other Steam builds exist in the source, but that does not mean every Steam update or every game has been tested. A future Steam update can require a NotProton update.

## Install and start playing

For the released upstream version, use the assets from the [official release page](https://github.com/NotProtonNot/NotProton/releases). Its requirements may differ from this development fork. Do not assume that the released version includes the changes described here.

For this fork, download `NotProton-1.1.0-contribution.1-macos-arm64.zip` from the [test release](https://github.com/schroedernils/NotProton/releases/tag/v1.1.0-contribution.1), or build from source. Unzip it and copy NotProton.app into Applications. This is an experimental, ad hoc signed build, without Apple notarization. macOS may block the first launch. If you trust this exact download, use the individual Open Anyway option in Privacy & Security. Keep Gatekeeper enabled. Automatic app updates are disabled in this test build. The redesigned build still needs a manual installation and game test.

1. Copy the app into Applications and open it. The setup guide opens on the first app launch. You can reopen it from Settings at the bottom of the sidebar or from Status.
2. **Check requirements.** Confirm Steam and a supported CrossOver source. Use Choose CrossOver if it is in another folder. Activate CrossOver in its own app if necessary.
3. **Prepare macOS permissions.** Read the App Management explanation and use its System Settings button. Enable the NotProton app you are using if macOS lists it. If it is not listed yet, macOS may add it after the installation request. The app cannot reliably read this permission's state and does not claim it is granted merely because you continued.
4. **Install the integration.** Quit your games first. Installation may close Steam. For an activated source, it can also prepare the runtime automatically. A failed operation stays on the current page with the error and relevant settings link.
5. **Set up the runtime.** Follow the page if a runtime or required components are still missing. The original CrossOver app remains the source; NotProton uses its own copy.
6. **Start a game.** Open or restart the normal macOS Steam app. In Library, open a Windows game's **Properties → Compatibility** and choose an installed NotProton/CrossOver tool. Start the game and check picture, controls and saves.

The first launch can take longer while the Windows environment is created. A ready installation means the required files and runtime passed the checks. It does not guarantee compatibility with every game.

If Steam requests Input Monitoring for controller support, allow it for Steam when prompted and restart Steam. Full Disk Access is not a general setup requirement.

## Game environments and saves

A game's prefix contains its Windows registry, components and sometimes save files. It appears in **Game environments** after that Windows game has first launched through NotProton.

Before changing components or rebuilding a prefix, use the backup action. Prefix backups do not include downloaded game files and do not guarantee Steam Cloud synchronization. Keep independent save backups for games you care about.

Existing Steam downloads can be reused and verified by Steam, but a CrossOver bottle cannot be migrated simply by moving its directory. This fork does not automatically import bottles or their save files.

**Tools → Run Program** runs a trusted Windows program in the selected game environment. It does not change the executable behind Steam's default Play button.

## When something does not work

| Symptom | Start here |
| --- | --- |
| CrossOver says unsupported | Compare the exact bundle build in Status with the profiles above. Do not rename the app or bypass the binary checks. |
| Installation cannot write Steam | Read the error. If it points to App Management, open the linked setting and check the app's permission. Ownership errors need the correct macOS account or folder ownership. |
| “Installed, but not for this account” | This contribution separates Steam integration files from runtime files and reports actual missing components. It is not a Steam purchase or account entitlement check. |
| Compatibility page or tool is missing | Restart Steam after setup. Refresh Status. Steam updates can change the interface and native hooks. |
| Game window stays black | Let first setup finish, quit the game normally, then retry. Check the selected runtime and change one graphics setting at a time. Some games still have renderer or launcher problems. |
| Controller does not work | Check macOS and Steam controller settings and the game's input options. Reset Steam's controller permission from Status only if needed, then restart Steam. |
| Missing VCRuntime or other Windows component | Install a trusted component installer into the affected game environment using Tools → Run Program. Avoid arbitrary DLL download sites. |
| Ubisoft or another launcher installs Windows Steam | This is a known launcher compatibility issue, not proof that the native Steam integration is missing. See the current upstream reports. |
| Online or anti-cheat fails | VAC is not supported by this integration. Other anti-cheat systems can also be incompatible with Wine. Launching the game does not prove protected multiplayer works. |

Use **Help** for fuller guidance. **Maintenance** in Status contains repair and removal actions. Repair restores Steam; removing NotProton restores Steam and removes its integration/runtime components while keeping game downloads and game prefixes. Read each confirmation before proceeding.

Blocking Steam client updates is optional. It can keep a working setup on a known client version, but it also delays Steam fixes. It does not block game updates. An older NotProton app refuses to overwrite a newer installation.

For a report, include the game, macOS version, exact CrossOver build, selected tool, reproduction steps and the expected result. Preview the app's support summary before copying it. Raw local logs can contain private paths or error details; review them separately before sharing. [Upstream issues](https://github.com/NotProtonNot/NotProton/issues) contain current game-specific reports.

## Runtime scope

This fork focuses on CrossOver. It does not add a free Wine provider, bypass CrossOver activation or claim support for every Wine engine. Runtime work needs its own verified binary profiles and a working Steam bridge.

## Validation and current limits

The earlier local package `1.1.0-local.1` was installed manually from a clean integration state and **Normal Golf Game** was confirmed visible and playable with CrossOver 26.3 Rosetta. That result does not by itself validate the later setup UI or other games.

The contribution has automated checks for installation status, precise signing metadata recovery, Steam interface variable renames, controller-panel behavior, setup readiness and privacy of the support summary. See [validation details](docs/VALIDATION.md) for the current test and visual evidence.

Untested configurations include FEX gameplay, Intel Macs, older macOS, physical controllers and broad game compatibility. No general performance improvement or universal CrossOver/Wine support is promised.

## For developers

The app lives in `app`, the Steam integration in `dylib`, the Steam bridge in `lsteamclient`, and runtime patch generation in `ntdll-patch`. The project pins upstream sources and component hashes. Read [NOTICE](NOTICE) before redistributing a build.

The full build requires an appropriate Xcode toolchain and macOS SDK, Python 3, CMake, the pinned Dobby source, Wine build dependencies and MinGW cross compilers. The [app workflow](.github/workflows/app.yml) records the full build setup. `bridge/setup-wine-tree.sh` and `lsteamclient/build.sh` describe the Wine and bridge builds. A source-only Swift build is useful for UI work but does not create a complete installer payload.

```sh
make dobby
make bridge
make app
```

Set `DOBBY_DIR` if your Dobby checkout/build is outside the default location. Keep generated outputs out of version control. Component builds should target a disposable staging tree, not an installed CrossOver app.

For UI/model tests and Steam interface regressions

```sh
swift test --package-path app
make webpatch-fixtures
```

Some runtime tests require an explicitly selected local test installation; they are not proof of all supported profiles. Review the workflow and test output rather than treating a skipped check as passed.

## Credits and licenses

NotProton is created by the [upstream project](https://github.com/NotProtonNot/NotProton). Valve's Steam Play and Proton components, Wine, CodeWeavers' CrossOver, Dobby and Sparkle make this integration possible.

Most project code is GPLv3. Valve-derived components and other dependencies have their own licenses. The complete licensing information is in [NOTICE](NOTICE) and the original source notices.
