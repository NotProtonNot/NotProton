# Validation record

This contribution is based on upstream dev-1.1.0 at `950059dc382d62c8e29dc2a3f943c81654da22e8`.

## Automated checks on 8 October 2026

* The complete Swift test command completed successfully with 483 tests in 58 suites. The real Wine prefix rebuild suite was skipped because its opt-in was unset. It is not counted as a real runtime validation.
* The complete staged installer payload was used for the Swift checks. Coverage includes deployment content guards, signing metadata recovery, prefix and backup safety, supported profiles, setup readiness, English help-resource coverage, help search and the support summary allowlist.
* `make webpatch-fixtures panel-behavior launch-shell` completed successfully. This includes three webpatch fixtures, ninety seeded identifier renamings, ambiguous patch refusal, preserved panel exports, dependency name collisions, launch quoting and migration, and shell behavior.
* A locally installed Steam JavaScript chunk was separately patched offline and syntax checked during development.
* The downloadable app uses the production entry point and real installer actions, not the no-op design preview. It is built with optimization and `NOTPROTON_LOCAL_TEST`, which disables app updates. Its ad hoc signature, archive contents and staged payload hashes are checked during packaging. Debug symbols and embedded absolute diagnostic paths in non-executable PE sections are removed; executable bridge code and section offsets are preserved.

## Manual evidence

The earlier package 1.1.0-local.1 was installed manually after removal of the integration. The user confirmed A Windows game was visible and playable in native Steam on Apple Silicon with CrossOver Stable 26.3 Rosetta and Steam build 1788652215. The first attempt had a black window; a retry succeeded. This is not claimed as a general black-screen fix.

The later UI was inspected in an isolated native preview. Its first page and integration page showed installed app icons, centered text, status boxes and the primary action. The preview did not install anything. The final whole-row disclosure change and the new permission-flow changes compiled and passed regression tests, but were not visually rechecked at the user's request. Screenshots from the user show the previous downloadable build reaching the final setup page and Steam’s working CrossOver 26.3 Compatibility options. They do not prove the new permission check, native-only filter or automatic dismissal. Light appearance, intermediate animation frames and a complete manual installation of the downloadable version remain unverified.

## Compatibility limits

No gameplay proof for Intel, FEX, other CrossOver builds, physical controllers, protected multiplayer or a broad game catalogue. CrossOver Stable and Preview profiles are inherited from upstream. Exact binary validation remains in place. No free Wine provider or license bypass is included.

The Windows bridge uses the pinned Wine 11.15 / Proton sources. The signed arm64 bridge artifact was reused from the same sources; FEX gameplay remains untested. See the release payload provenance for component hashes.

## Reports that informed the work

* [Issue 39](https://github.com/NotProtonNot/NotProton/issues/39) informed the misleading account-status correction.
* [Issue 36](https://github.com/NotProtonNot/NotProton/issues/36) informed the targeted signing metadata recovery.
* [Issue 40](https://github.com/NotProtonNot/NotProton/issues/40) informed clearer release/build labels.
* [Issue 42](https://github.com/NotProtonNot/NotProton/issues/42) informed discoverability of game environments and component installation.
* [Community launch discussion](https://www.reddit.com/r/macgaming/comments/1wns82a/introducing_not_proton_the_linux_steam_play/) informed setup and anti-cheat guidance. These reports are context, not proof that every reported problem is fixed.

## Reproduce

```sh
swift test --package-path app
make webpatch-fixtures panel-behavior launch-shell
```

The Swift model suite can also run without a built payload; payload-specific checks need `make app-payload` or a complete staging tree. Full release build requirements are described in README and the upstream workflow.

## Upstream synchronization

The contribution branch merges upstream main at `599ebf6a4cfa52b46c03299170ccbde8f8fe2205`. Runtime profiles and payload hashes follow the newer dev-1.1.0 branch, preventing duplicate build IDs and mismatched detours. Main’s additional resolver validation and ntdll input checks are retained. There are zero missing main commits at this recorded snapshot. The remaining ahead commits include inherited development history; target dev-1.1.0 when reviewing the original contribution scope.
