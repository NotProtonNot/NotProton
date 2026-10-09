# Localization

NotProton includes English and Simplified Chinese (`zh-Hans`). The application
follows macOS's language selection. To choose a different language just for
NotProton, add it in **System Settings > General > Language & Region >
Applications**, then quit and reopen NotProton.

The Steam compatibility panel uses the page's `document.documentElement.lang`,
falling back to `navigator.language` only when the page has no language. Unknown
languages retain the existing English labels. The translation does not modify
Steam's settings or translate launch-option names, environment variables, file
paths, brand names, or matching anchors. Steam's page language can differ from
the language selected for the standalone NotProton app.

## Adding or updating strings

- Wrap user-facing Swift strings with `L10n.tr("…")`, including computed strings
  and error descriptions. Do not localize persisted identifiers.
- Keep English text as the lookup key in both
  `app/Sources/NotProtonApp/Resources/Localization/en.lproj/Localizable.strings`
  and `zh-Hans.lproj/Localizable.strings`.
- Swift interpolations become numbered placeholders (`{0}`, `{1}`, …). Preserve
  their number and occurrence counts in translations. Replacement is one-pass:
  inserted game names containing braces, percent signs, or quotes stay literal.
- Keep destructive operations explicit, especially the loss of saves when
  deleting or rebuilding a Wine prefix. The Chinese UI calls a prefix a
  “游戏容器” and must not imply it contains only temporary/cache files.
- Steam panel translations live beside their English labels in
  `dylib/feats/webpatch.c`; retain the English matching anchors.

## Checks

```sh
python3 scripts/check-localization.py
make localizationcheck
make panel-behavior webpatch-fixtures
NOTPROTON_LANGUAGE=en make app-tests
```

`NOTPROTON_LANGUAGE` overrides the app's language for a single process. The
original English test assertions remain unchanged; localization tests explicitly
exercise both languages. `make app` also verifies that the packaged resource
bundle is relocatable and retains the official update configuration.

Before release, manually check both languages in the native app and in Steam
(stable and beta compatibility tabs). In particular, check long warnings,
language preferences, table columns and the update dialog. Automated panel tests
stub the page language and do not substitute for testing an installed Steam
client.

This change does not lower the supported macOS version, change the update feed
or signing key, or introduce a separate Chinese release channel.
