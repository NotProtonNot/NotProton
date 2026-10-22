# Example plugins and variants

Drop these in and restart Steam to see what a plugin can put in the Developer section
of a game's Compatibility page. They are examples, not features: nothing here is
installed or enabled by default.

    cp examples/plugins/*.conf   ~/Library/Application\ Support/notproton/plugins/
    cp examples/variants/*.conf  ~/Library/Application\ Support/notproton/variants/

Each file is one row. Delete a file and its row goes away; the folders are yours, and
NotProton never writes to them.

| file | shows |
| --- | --- |
| `plugins/10-example-toggle.conf` | a toggle, an environment variable, and lines that appear only while it is on |
| `plugins/20-example-sub-option.conf` | a row that hides and indents under another |
| `plugins/30-example-dropdown.conf` | a dropdown of declared values |
| `plugins/40-example-slider.conf` | a slider over a range |
| `plugins/50-example-snapping-slider.conf` | a slider that snaps to declared values, with a labelled tick for each |
| `plugins/60-example-requires.conf` | a row for a file you have not built yet, greyed out as "(not installed)" |
| `variants/dxmt-example.conf` | a runner built from a CrossOver copy with your own files over it |

The toggles work as they are. The dropdown and the two sliders write their value into
the game's launch options, and a launch option named `NOTPROTON_ENV_FOO=bar` reaches
the game as `FOO=bar` once [#219](https://github.com/NotProtonNot/NotProton/pull/219)
lands; until then they show the UI without changing the game.

## Plugin fields

A plugin is a `key = value` file in `~/Library/Application Support/notproton/plugins`.
Files are read in name order, which is the order the rows appear in. Unknown fields are
ignored so a file written for a later version still loads; a field given twice keeps the
first value, except for the repeatable ones noted below.

| field | |
| --- | --- |
| `key` | required, and has to start with `NOTPROTON_`. The launch option the row reads and writes. |
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

A variant is a `key = value` file in `~/Library/Application Support/notproton/variants`.
The file name is the variant's id. The Developer section offers one dropdown per
`variant` group, so several files sharing a group become a picker of builds.

| field | |
| --- | --- |
| `label` | what the dropdown shows for this entry. |
| `variant` | the group it belongs to, which is the dropdown's label. |
| `src` | the folder laid over the runner, absolute or relative to `$HOME`. |
| `dst` | where in the runner it goes, relative to the CrossOver folder. |

Unlike a plugin, a variant refuses any field it does not know: a typo that looked like
it worked would leave you testing the stock runner.

The chosen variant is written to the game's launch options as
`NOTPROTON_RUNNER_VARIANT`, and variants from different groups combine as `a+b`. The
runner is assembled the first time a game asks for it and reused after that, so the
first launch pays for the copy and later ones do not.
