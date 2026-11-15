# Mac compatibility badges

An Apple badge on each installed game, in the corner of its library tile where Steam
puts the Steam Deck badge, and a `MAC` stat on the game's page next to Play Time. Hover
either one for the reason.

Everything comes from this Mac. Nothing is fetched, nothing is applied to a game, and
no Steam Deck data is used.

## The badges

| Badge | Label | When |
|---|---|---|
| Green | Verified | It has run here at least twice, for 20 minutes or more, without crashing. Or it ships a native macOS build. |
| Yellow | Playable | It starts through a third-party launcher (EA app, Ubisoft Connect, Epic, Rockstar), or some of its sessions here crashed. |
| Red | Unsupported | Its folder carries an anti-cheat (Easy Anti-Cheat, BattlEye, Vanguard), or every session here crashed. |
| Dashed ring | Unknown | It has not run here yet. |

An anti-cheat outranks any history.

## Where it comes from

- **Sessions.** At the end of each launch, the run script already decides whether the
  session was healthy, failed, or neither (`session_health`). It now also keeps a running
  count beside the prefix in `notproton-sessions`.
- **The game's folder.** A walk of the install (5 levels, 20,000 entries at most) for
  anti-cheat and launcher files and a macOS app bundle. File names only. The result is
  kept in `notproton-scan` beside the prefix and redone when the game updates.

The Compatibility page's rebuild row also shows the verdict with its numbers: runs,
crashes, time played, the CrossOver build and backend of the last session.

## Turning it off

Steam → Preferences → Compatibility → **Show Mac compatibility badges**. It takes effect
at once. Or create an empty `no-mac-badges` in `~/Library/Application Support/notproton/`.

## Files

| File | Does |
|---|---|
| `dylib/feats/compat_run.sh` | `record_history` keeps the session counts. |
| `dylib/feats/verdict.c` | Session counts → a tier. |
| `dylib/feats/game.c` | Install folder → anti-cheat, launcher, native build. |
| `dylib/feats/badge.c` | Game + history → badge and reason. |
| `dylib/feats/catalog.c` | One pass over the installed games, on a thread. Writes `badges` in the support folder and hands the map to the library. |
| `dylib/feats/webpatch.c` | Tile badge, game page stat, Preferences switch. |
| `dylib/feats/prefixstate.c` | Adds the verdict to the Compatibility page's state. |

## Notes for changing the UI

- Steam runs its JavaScript in a hidden `SharedJSContext` and draws into a separate
  window, so a `<style>` added by injected code never reaches the page. Everything is
  styled inline.
- The tile's own icon row only shows while it is hovered, so the badge is a sibling of
  that row, placed by its own style. On the wide featured tile it moves to the top
  corner, off the Play button.
- The tile anchors are checked together before any is written. If Steam moves one, the
  badges switch off with a warning in `notproton.log` and nothing else is affected. The
  game page stat has its own anchor for the same reason.
- Written against Steam client build 1794536281.

## Checks

`make verdict-check game-check badge-check catalog-check`, plus `panel-behavior`,
`prefixstate-check` and `buildcheck`, which cover the injected code, the page state and
the session record.
