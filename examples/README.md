# Example plugins and variants

Drop these in and restart Steam to see what a plugin can put in the Developer section
of a game's Compatibility page. They are examples, not features: nothing here is
installed or enabled by default.

    cp examples/plugins/*.conf   ~/Library/Application\ Support/notproton/plugins/
    cp examples/variants/*.conf  ~/Library/Application\ Support/notproton/variants/

Each `[header]` is one row, and a file holds as many as it likes — a feature and its
sub-options belong together. Delete a file and its rows go away; the folders are yours,
and NotProton never writes to them.

| file | shows |
| --- | --- |
| `plugins/10-framescope.conf` | a feature and its seven settings in one file: a toggle that injects a dylib, a dropdown, a slider over a range, a slider that snaps to values with labelled ticks, a sub-option of a sub-option, and lines that appear only while the row is on |
| `plugins/20-renderdoc.conf` | a toggle with one sub-option, writing `0` when it is switched off rather than clearing the launch option |
| `plugins/30-kosmickrisp.conf` | one toggle that both injects a dylib and sets two environment variables |
| `variants/dxmt-example.conf` | a runner built from a CrossOver copy with your own files over it |

These are the real descriptors behind three tools, not invented ones, so `requires` points
at a build you probably do not have. That is the point of one of them: a row whose files
are missing still appears, greyed out as "(not installed)".

The toggles work as they are, once `requires` points at something real. The dropdowns and
sliders write their value into the game's launch options, and a launch option named
`NOTPROTON_ENV_FOO=bar` reaches the game as `FOO=bar` once
[#219](https://github.com/NotProtonNot/NotProton/pull/219) lands; until then they show the
UI without changing the game.

## Plugin fields

A plugin is a record in a `.conf` file in `~/Library/Application Support/notproton/plugins`,
opened by a `[NOTPROTON_SOMETHING]` header that is also the launch option it reads and
writes. Rows appear in file-name order, then in the order they appear within their file.

The grammar, the fields and every way a record can be refused are specified in
[`dylib/feats/conf-format.md`](../dylib/feats/conf-format.md), which both the panel and
the launch are checked against. The short version: anything that is not exactly right is
refused and logged rather than half-applied — an unknown field, a field given twice that
may only be given once, an empty value, a missing `label`.

| field | |
| --- | --- |
| `label` | required. What the row is called. |
| `description` | the line under the label. |
| `description_on` | repeatable. Lines under the description, shown only while the row is on. |
| `section` | `dev`, the only section plugins can add to, and what you get by leaving it out. |
| `on` | the value that counts as on, `1` by default. |
| `off` | what switching off writes; empty removes the launch option, which is the default. |
| `depends` | another plugin's key. The row is hidden until that one is on, and indents under it. |
| `requires` | repeatable, up to 4. A file, absolute or relative to `$HOME`; the first that exists wins. A row whose files are all missing is greyed out as "(not installed)". |
| `inject` | `1` loads the file `requires` found into the game. |
| `env` | repeatable. `NAME=VALUE` exported for the game. |
| `overrides` | added to `WINEDLLOVERRIDES`, e.g. `dxgi=n,b`. |
| `stage` | a folder whose files are copied into the prefix's `system32` before launch. |

### Row types

`type` decides what the row is. Leave it out and the row is a toggle.

| `type` | |
| --- | --- |
| *(none)* | a switch, writing `on` or `off`. |
| `choice` | a dropdown offering Default plus each `choice`. |
| `slider` | with `min`/`max`, a slider over that range; with `choice` lines, a slider that snaps to those values. |

| field | |
| --- | --- |
| `choice` | repeatable, up to 16. `<value> = <label>`, split on the first `=`; with no label the value is its own. |
| `min`, `max` | the range of a slider. `max` has to be the larger. |
| `step` | what the handle moves by. |
| `default` | where the handle sits while the launch option is unset, and the value that clears it again. On a snapping slider it has to be one of the declared values. |
| `suffix` | drawn after a range slider's value, joined on with no space: `x` reads `1.25x`. |

A row that cannot be drawn is refused rather than half-drawn, and says why in
`~/Library/Application Support/notproton/notproton.log`: a slider with no range, a
range whose `max` is not larger than its `min`, a `step` or `default` that is not a
number, a snapping slider with one value or a `default` that is not one of them, a
`choice` with no values, or a `type` that does not exist.

## Variant fields

A variant is a record in a `.conf` file in `~/Library/Application Support/notproton/variants`,
opened by a `[header]` that is its id. The Developer section offers one dropdown per
`variant` group, so several records sharing a group become a picker of builds — and they
can all live in one file.

| field | |
| --- | --- |
| `label` | what the dropdown shows for this entry. The id when left out. |
| `variant` | the group it belongs to, which is the dropdown's label. The id when left out, so a variant on its own needs neither. |
| `src` | the folder laid over the runner, absolute or relative to `$HOME`. |
| `dst` | where in the runner it goes, relative to the CrossOver folder. |

`src` and `dst` are required; `label` and `variant` fall back to the id, so the smallest
variant is a header and those two lines. Any field that is not one of these four is
refused rather than ignored, since a typo that looked like it worked would leave you
testing the stock runner.

The chosen variant is written to the game's launch options as
`NOTPROTON_RUNNER_VARIANT`, and variants from different groups combine as `a+b`. The
runner is assembled the first time a game asks for it and reused after that, so the
first launch pays for the copy and later ones do not.
