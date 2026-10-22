# Descriptor files

Plugins and runner variants are declared in the same file format, read by two parsers that
cannot share code: `webpatch.c`, in Steam's process, decides what the Compatibility panel
shows; `compat_run.sh` decides what a launch actually does. They share this grammar, the
schema tables below, and the fixture corpus in `dylib/tests/conf-fixtures`, which both are
checked against so they cannot drift.

    ~/Library/Application Support/notproton/plugins/*.conf    rows in the Developer section
    ~/Library/Application Support/notproton/variants/*.conf   runner variants

## Grammar

    # a comment
    [NOTPROTON_FRAMESCOPE]
    label       = FrameScope
    description = Adds the FrameScope HUD.
    requires    = code/github/framescope/build/libframescope.dylib
    inject      = 1

    [NOTPROTON_ENV_FRAMESCOPE_POSITION]
    label   = HUD position
    type    = choice
    depends = NOTPROTON_FRAMESCOPE
    choice  = tl = Top left
    choice  = tr = Top right

- A file is a sequence of **records**. `[id]` opens one and it runs to the next header or
  the end of the file. One file can hold as many as it likes: a feature and its sub-options
  belong together.
- The header **is** the id. For a plugin that is the launch option it reads and writes, so
  `NOTPROTON_` followed by one or more of `A-Z 0-9 _`. For a variant it is the name used in
  `NOTPROTON_RUNNER_VARIANT`: `A-Za-z0-9`, then any of `A-Za-z0-9 . _ -`, at most 64 bytes.
  A plugin has no `key` field and a variant's file name means nothing.
- Fields are `name = value`, split at the first `=`, so a value may contain `=`.
- Whitespace around a header, inside its brackets, and around a name or a value is
  trimmed. Once trimmed, a value may not contain a tab, which keeps the normalised form
  unambiguous; a tab around the `=` is just whitespace. A `#` as the first non-blank
  character comments out the line; one inside a value is part of the value. Blank lines are
  ignored.
- Lines are at most 2048 bytes and one record's names and values come to at most 4096
  together, so that what a parser can hold is part of the grammar rather than its own
  business. A number is `-1.5e3` at its widest: no hex, no `inf`, no `nan`.
- Lines are at most 2048 bytes. Records appear in file-name order (`LC_ALL=C`), then in the
  order they appear within their file. At most 32 records per directory, counted across
  files; the rest are refused.

## Strict

A file or record that is not exactly right is refused and logged, never half-applied. A
mistake that looks like it worked is worse than a row that does not appear.

**The file is dropped** when it cannot be read, a line is over 2048 bytes, or a field line
appears before the first header. **The record is dropped**, and the rest of the file kept,
for everything else: an unknown field, an id that breaks the rules above, a repeat of an id
already seen, a required field missing, a field given twice that is not repeatable, an empty
value, a tab inside a value, or a value that fails its rule in the tables below.

Three of these change what the parsers do today and are deliberate: an unknown field used to
be ignored on a plugin (and only refused on a variant); a single-valued field given twice
used to keep the first value; an empty value used to be skipped. All three are now refusals,
in both directories.

## Plugin fields

| field | repeat | required | value |
| --- | --- | --- | --- |
| `label` | once | yes | what the row is called |
| `description` | once | | the line under the label |
| `description_on` | append, max 16 | | a line shown under the description only while the row is on |
| `section` | once | | `dev`, the only section there is; the default |
| `on` | once | | the value that counts as on; `1` |
| `off` | once | | what switching off writes; empty, which removes the launch option |
| `depends` | once | | another record's id. Hidden until that one is on, and indented under it |
| `requires` | append, max 4 | | a file, absolute or relative to `$HOME`; the first that exists wins |
| `inject` | once | | `1` loads what `requires` found into the game |
| `env` | append, max 16 | | `NAME=VALUE`, exported for the game; `NAME` is `[A-Z_][A-Z0-9_]*` |
| `overrides` | once | | appended to `WINEDLLOVERRIDES` |
| `stage` | once | | a folder whose files are copied into the prefix's `system32` |
| `type` | once | | `choice` or `slider`; a toggle without one |
| `choice` | append, max 16 | | `<value> = <label>`, split at the first `=`; the label defaults to the value |
| `min`, `max` | once | for a range slider | numbers, `max` the larger |
| `step` | once | | a number |
| `default` | once | | a number for a range slider, one of the values for a snapping one |
| `suffix` | once | | drawn after a range slider's value, joined on with no space |

`type` decides the control, and the fields it needs:

| `type` | needs | is |
| --- | --- | --- |
| *(none)* | | a toggle writing `on` or `off` |
| `choice` | at least one `choice` | a dropdown of Default plus each value |
| `slider` | `min` and `max`, and no `choice` | a slider over that range |
| `slider` | at least two `choice`, and no `min`/`max` | a slider snapping to those values, a labelled tick each |

## Variant fields

| field | repeat | required | value |
| --- | --- | --- | --- |
| `label` | once | | what the dropdown shows for this entry; the id when it is left out |
| `variant` | once | | the group it belongs to, which is the dropdown's label; the id when it is left out, so a variant on its own needs no group |
| `src` | once | yes | the folder laid over the runner, absolute or relative to `$HOME` |
| `dst` | once | yes | where it goes, relative to the CrossOver folder; relative, and no `..` |

## The normalised form

Both parsers can dump what they read as tab-separated lines, which is what the fixtures pin.
Values cannot contain a tab, so the stream is unambiguous.

    <id>	<field>	<value>        one line per field, in the order read
    !	<path-or-id>	<code>     a file or record that was refused

Records appear in the order given above. A refusal is emitted where it was found, in place
of the record or the remainder of the file. The codes are shared; the wording the two
parsers log is not, and does not have to match.

| code | |
| --- | --- |
| `unreadable` | the file could not be opened. Each parser reports this where it notices it, which is the one line the corpus does not pin |
| `line-too-long` | a line over 2048 bytes |
| `no-header` | a field line before the first `[id]` |
| `bad-id` | an id that breaks the rules for its directory |
| `duplicate-id` | an id already seen, in this file or an earlier one |
| `unknown-field` | a field name that is not in the table |
| `duplicate-field` | a field given twice that may only be given once |
| `empty-value` | a field with nothing after the `=` |
| `tab-in-value` | a tab inside a value |
| `missing-required` | a required field that is absent |
| `bad-value` | a value that fails its rule, such as `env` without `NAME=` |
| `limit` | past 32 records for the directory, or past a field's own cap |
| `bad-type` | a `type` that does not exist |
| `slider-shape` | a slider with both a range and values, with neither, or with one value |
| `bad-default` | a `default` that is not a number, or not one of a snapping slider's values |

Each code may carry a detail after a colon, such as `unknown-field:labell`. Details are part
of what the fixtures pin, so both parsers name the same thing.

## Converting a file written before sections

Put a header on it and drop the `key` line. For a plugin the header is what `key` was; for a
variant it is the file name without `.conf`.
