I came across NotProton through Andrew Tsai's YouTube video and wanted to try it on my Mac. Being able to use the normal Steam app for Windows games looked like exactly what I had been missing.

While setting it up I ran into a few things that were hard to understand. My CrossOver version did not match what the app seemed to expect, the installation status said it was not installed for my account, and the compatibility controls in Steam were not behaving as expected. I also had a black game window on the first attempt. I have not treated that last one as a general bug fix, since a retry worked and game compatibility has its own limits.

I wanted to spend some time working through the problems rather than leave them as another confusing setup experience. After the fixes, I installed the local package again myself and got Normal Golf Game running through native Steam with CrossOver 26.3. I also used the issue reports to make setup clearer for the next person, with a guide that explains permissions before installation and walks through one page at a time.

## What changed

The installation status now distinguishes the files installed into Steam from files that belong to runtime setup. Missing runtime files no longer produce the misleading account message. When Steam integration really needs repair, the app lists its missing components.

CrossOver status shows the release, runtime flavor and exact bundle build. Stable 26.3 support already exists in the development branch this work is based on, so this does not add it a second time or claim support for arbitrary versions.

Signing is retried only for codesign's specific Finder metadata error. The recovery removes FinderInfo and ResourceFork without following external symlinks or clearing unrelated attributes. Other signing failures are still reported.

The Steam interface patch captures additional minified identifiers while preserving its exact match counts and atomic acceptance check. Injected dependencies are bound in their own scope so names such as React=t and UI=g cannot collide with panel locals. Existing controller options and launch option migration remain intact. German text was included in the fixtures, but I found no evidence that German itself caused the problem.

Setup is presented as five pages covering requirements, macOS permissions, Steam integration, runtime setup and the first game. Installation completion comes from the inspected files. Reviewing the permission page does not claim that App Management is granted, and reaching the last page does not claim a game has been tested. The selected source is passed through installation instead of silently using another CrossOver copy.

The sidebar uses Game environments and Backups to explain the prefix tools more clearly. Searchable help covers first launch, missing components, controllers, saves, launchers and anti cheat. Maintenance actions are collapsed by default. Setup appears on the first app launch and can be reopened from Settings at the bottom of the sidebar. Help, setup details and maintenance expand when any part of the heading row is clicked, including its text and empty space. Each page keeps the essential copy short, uses the installed Steam and CrossOver icons for orientation and puts longer explanations behind Details. Step transitions respect Reduce Motion, while navigation and controls stay immediately available. The new guidance is available in English and German.

A support summary uses a deliberate field allowlist and can be previewed before copying. It does not read account configuration or raw logs and does not include user paths, license details or arbitrary error text. Nothing is sent automatically.

## Validation

The local package before the larger UI changes was installed manually and Normal Golf Game was confirmed visible and playable on Apple Silicon with CrossOver 26.3 Rosetta. The newer UI package and its visual checks are recorded separately in docs/VALIDATION.md.

Installer, status and signing checks passed with a complete staged payload. Steam interface checks cover three fixtures and ninety seeded identifier renamings, ambiguous matches, changed exports and colliding dependency names. The installed Steam JavaScript chunk was also patched offline and passed Node syntax checking.

The current setup, privacy and regression test totals are recorded in docs/VALIDATION.md so that the numbers reflect the final commit.

## Scope

This addresses the misleading installation status in issue 39 and the targeted signing failure from issue 36, and makes the version distinction in issue 40 easier to understand. It also adds guidance for problems described in issues 13, 17, 34 and 42 without claiming every controller, launcher or game is fixed.

This does not add a working free Wine provider, automatically import bottles, bypass CrossOver activation or claim FEX gameplay, Intel or older macOS validation. The contribution stays focused on CrossOver. If smaller changes would be easier to review, I am happy to split the installation fixes and guided setup into separate pull requests.
