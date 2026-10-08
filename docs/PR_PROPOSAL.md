# Improve installation checks and add guided CrossOver setup

I came across NotProton through a YouTube video and wanted to try it on my Mac. Being able to use the normal Steam app for Windows games looked like exactly what I had been missing.

While setting it up I ran into a few things that were hard to understand. My CrossOver version did not match what the app seemed to expect, the installation status said it was not installed for my account, and the compatibility controls in Steam were not behaving as expected. I also had a black game window on the first attempt. I have not treated that last one as a general bug fix, since a retry worked and game compatibility has its own limits.

I wanted to spend some time working through the problems rather than leave them as another confusing setup experience. After the fixes, I installed the local package again myself and got a Windows game running through native Steam with CrossOver 26.3. I also used the issue reports to make setup clearer for the next person, with a guide that explains permissions before installation and walks through one page at a time.

## What changed

The installation status now distinguishes the files installed into Steam from files that belong to runtime setup. Missing runtime files no longer produce the misleading account message. When Steam integration really needs repair, the app lists its missing components.

CrossOver status shows the release, runtime flavor and exact bundle build. Stable 26.3 support already exists in the development branch this work is based on, so this does not add it a second time or claim support for arbitrary versions.

Signing is retried only for codesign's specific Finder metadata error. The recovery removes FinderInfo and ResourceFork without following external symlinks or clearing unrelated attributes. Other signing failures are still reported.

The Steam interface patch captures additional minified identifiers while preserving its exact match counts and atomic acceptance check. Injected dependencies are bound in their own scope so names such as React=t and UI=g cannot collide with panel locals. Existing controller options and launch option migration remain intact. German text was included in the fixtures, but I found no evidence that German itself caused the problem.

Setup is presented as five pages covering requirements, macOS permissions, Steam integration, runtime setup and the first game. Installation completion comes from the inspected files. The permission page performs a temporary Steam write probe, requests access before opening System Settings, explains how to add the app when it is missing, and rechecks when the app becomes active. A green check and Continue are enabled only after the write check succeeds, and reaching the last page does not claim a game has been tested. The selected source is passed through installation instead of silently using another CrossOver copy.

The sidebar uses Game environments and Backups to explain the prefix tools more clearly. Searchable help covers first launch, missing components, controllers, saves, launchers and anti cheat. Maintenance actions are collapsed by default. Setup appears on the first app launch and can be reopened from Settings at the bottom of the sidebar. Help, setup details and maintenance expand when any part of the heading row is clicked, including its text and empty space. Each page keeps the essential copy short, uses the installed Steam and CrossOver icons for orientation and puts longer explanations behind Details. Step transitions respect Reduce Motion, while navigation and controls stay immediately available. The app and repository documentation are in English. The last page explains the Steam compatibility checkbox and closes after Steam opens successfully. macOS Accessibility permission is not requested just to select CrossOver.

A support summary uses a deliberate field allowlist and can be previewed before copying. It does not read account configuration or raw logs and does not include user paths, license details or arbitrary error text. Nothing is sent automatically.

## Validation

The local package before the larger UI changes was installed manually and a Windows game was confirmed visible and playable on Apple Silicon with CrossOver 26.3 Rosetta. The newer UI package and its visual checks are recorded separately in docs/VALIDATION.md.

Installer, status and signing checks passed with a complete staged payload. Steam interface checks cover three fixtures and ninety seeded identifier renamings, ambiguous matches, changed exports and colliding dependency names. The installed Steam JavaScript chunk was also patched offline and passed Node syntax checking.

The local Swift run passed 483 tests in 58 suites with the complete staged payload. The real Wine prefix rebuild suite was skipped because its opt-in was unset. The optimized app build, strict ad hoc signature verification and archive integrity checks passed. The new permission flow and automatic setup dismissal compiled and passed regression checks, but still need a complete manual installation test of the latest package. These checks do not establish broad gameplay compatibility.

This targets dev-1.1.0 because that branch already contains the runtime and prefix functionality used here. The branch also merges current main history, retaining its resolver and ntdll guards while preserving the newer development runtime profiles. The commits ahead of dev include inherited main commits; they are not all new work from this contribution. Both upstream comparisons currently merge without conflicts. Details and commands are recorded in [the validation record](https://github.com/schroedernils/NotProton/blob/upstream-installation-and-setup/docs/VALIDATION.md).

The native Mac library filter requested in issue 48 was investigated separately. Steam’s global compatibility check and the patched invalid-OS getter prevent a simple native-only predicate. This contribution does not claim to fix it; docs/ISSUE_48.md records the evidence and follow-up requirements.

## Scope

This addresses the misleading installation status in issue 39 and the targeted signing failure from issue 36, and makes the version distinction in issue 40 easier to understand. It also adds guidance for problems described in issues 13, 17, 34 and 42 without claiming every controller, launcher or game is fixed.

This does not add a working free Wine provider, automatically import bottles, bypass CrossOver activation or claim FEX gameplay, Intel or older macOS validation. The contribution stays focused on CrossOver. If smaller changes would be easier to review, I am happy to split the installation fixes and guided setup into separate pull requests.

A [preview package](https://github.com/schroedernils/NotProton/releases/tag/v1.1.0-preview.2) is available for trying the changes. It is ad hoc signed, not Apple notarized, and automatic updates are disabled for that test build. The upstream app identity and production update configuration are retained in the source. The preview is not an official upstream release.
