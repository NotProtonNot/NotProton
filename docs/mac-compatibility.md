# Mac compatibility

NotProton works out, for each game, how it should be run on this Mac and how likely it is
to run at all, and shows the answer where Steam shows the Steam Deck's.

This page covers what you see, where the answers come from, how to turn it off, and how
the pieces fit together for anyone changing them.

## What you see

**A badge on every game in the library.** An Apple mark in the corner of the tile, in the
place Steam Deck badges use. Hovering it says why.

| Badge | Label | Meaning |
|---|---|---|
| Green, filled | Verified | It has run on this Mac at least twice, for 20 minutes or more, without crashing. Or it has a native macOS version. |
| Green ring | Likely | Valve verified it, or found it playable, on Steam Deck through Proton. It has not run on this Mac yet. |
| Yellow | Playable | Something is in the way: a third-party launcher, crashes in some sessions here, or Valve marks it unsupported on Steam Deck. |
| Red | Unsupported | It cannot work here. Usually an anti-cheat that refuses Proton, or it has crashed every time it was started. |
| Dashed ring | Unknown | Nothing is known yet. |

Filled green is kept for what this Mac has actually seen. A game that only a Steam Deck
has run gets the ring.

**A stat on the game's page**, beside Play Time and Achievements: the same mark, with
`MAC` and the label.

**A row on the game's Properties → Compatibility page**: "Recommended Graphics Settings",
naming this Mac, with a "Use Recommended" button that writes the settings into the game's
launch options.

**A block on store pages and a chip on each wishlist row**, above Steam Deck
Compatibility. See [The store and the wishlist](#the-store-and-the-wishlist): this part
works differently from the rest and has its own switch.

## Settings that apply themselves

At launch, a game that has been told nothing gets the settings worked out for it. Anything
you set yourself wins: launch options first, then Default Compatibility Settings, then
these.

From the Mac (`dylib/feats/machine.c`, `tuning.c`):

- DXMT on Apple silicon, DXVK on Intel.
- MSync on, the Metal HUD off, High Resolution on for Apple silicon.
- AVX2 advertised to Rosetta on macOS 15 and later. Reduced x87 precision on FEX.
- A MetalFX upscale factor from the display's pixels per GPU core: none where the GPU
  covers the panel (a 40-core Max on a 16" display), up to 2x where it does not (a base
  chip on a 5K display). One band higher with 8 GB of memory.
- A frame cap at the display's refresh rate.

From the game (`dylib/feats/game.c`, `advice.c`), read from its installed files:

- Direct3D 12 → D3DMetal. Direct3D 11 → DXMT. Direct3D 9 → DXVK. Vulkan and OpenGL are
  left to CrossOver.
- A Unity game that asks for Direct3D 12 is passed `-force-d3d11` and run on DXMT. An
  Unreal one is left on D3DMetal, since forcing it to Direct3D 11 costs features.
- A game that needs Direct3D 12 on a FEX tool is flagged: FEX has no D3DMetal.

Toggles whose right answer depends on the game rather than the hardware (DLSS, for
instance) are never set for you.

## Where the answers come from

Nothing is fetched from the network for the library. In order of weight:

1. **This Mac's own history.** The run script records how each session ended
   (`notproton-sessions` beside the game's prefix): healthy, crashed in the first minute,
   or neither, and for how long.
2. **The game's files.** The executable's PE header and import table (word size, which
   Direct3D it loads), and whether the folder carries Easy Anti-Cheat, BattlEye, a
   third-party launcher, a known engine, or a macOS app bundle.
3. **Valve's Steam Deck testing**, from the `appinfo.vdf` Steam already keeps: the
   category, and whether a test failed for anti-cheat. This is what gives a game a badge
   before it is downloaded. An anti-cheat that refuses Proton refuses Wine as well, so
   that result is taken as it stands; a "verified" is only ever shown as Likely.

The store and wishlist ask the store's own endpoints for the same Valve report, for games
Steam has no local record of. See below.

## Turning it off

In Steam, **Steam → Preferences → Compatibility**:

- **Show Mac compatibility badges** — the library badges, the game page stat, and the
  store. Takes effect at once.
- **Show Mac compatibility in the Store and Wishlist** — the store part alone. Takes
  effect when Steam restarts.

Or by hand, with empty files in `~/Library/Application Support/notproton/`:

| File | Effect |
|---|---|
| `no-mac-badges` | No badges anywhere. |
| `no-store-badges` | No store or wishlist block, and Steam's web debugger is not turned on. |
| `no-auto-settings` | Nothing is applied at launch that you did not set. |

## Launch rules

The flags that get a particular game past its launcher are found one game at a time, so
they live in files rather than in NotProton. A rule names a game and the words to pass
it:

```
[some-game-skip-launcher]
appid  = 123456
option = -skipLauncher
note   = Started without the launcher.
```

Put rules in `~/Library/Application Support/notproton/rules/*.conf`. A rule can match on
`appid`, `engine` (`unreal`, `unity`), `launcher` (`ea`, `ubisoft`, `epic`, `rockstar`) or
`exe`; everything it names has to match. `option` may repeat. `note` is added to the
badge's tooltip. A rule that names no game, or carries shell punctuation in an option, is
refused. The format and a worked example are in `examples/rules/`.

NotProton ships one rule's worth of behaviour itself (`-force-d3d11` for Unity on
Direct3D 12) and one example (`-nostartupmovies` for Unreal). It ships no launcher
bypasses, because a flag that helps one game can stop another from starting.

## The store and the wishlist

Store pages are Valve's, served from the network. Nothing NotProton patches on disk
reaches them, and Steam's client has no way to run a script in them. The one way in is
the debugger built into Steam's web helper (CEF), which is how Decky and Millennium reach
the same pages.

So, when the store switch is on:

- NotProton starts Steam's web helper with `--remote-debugging-port=27101
  --remote-debugging-address=127.0.0.1` (`dylib/hooks/hook_spawn.c`).
- A thread in the dylib (`dylib/feats/store.c`) connects to that port, checks that what
  answers is Steam, and keeps `dylib/feats/store_page.js` registered on pages under
  `https://store.steampowered.com/`.
- That script adds the Mac block above the Deck block on app pages, and a chip on each
  wishlist row. It reads the page's own anti-cheat notice and macOS icon, the badges this
  Mac has worked out, and, for a game it has nothing on, the store's own Deck report and
  platform list (same origin, two requests at a time, remembered for the session).

**What this costs.** The port listens on this Mac only, not the network. But any program
running on this Mac can connect to it while Steam is open, and through it can read and
drive Steam's web views, the logged-in store among them. That is a real thing to agree
to, which is why it is a separate switch and says so. With the switch off, the helper is
started as Steam starts it and no port is opened.

## How the pieces fit

| File | Does |
|---|---|
| `dylib/feats/machine.c` | Reads the Mac. The chip name and GPU core count come from the I/O registry, because Steam runs under Rosetta where `sysctl` reports a virtual CPU. |
| `dylib/feats/tuning.c` | Mac → settings, as lines the defaults whitelist accepts. |
| `dylib/feats/game.c` | Installed folder → what the game is. Maps the executable rather than reading it. |
| `dylib/feats/verdict.c` | A game's recorded sessions → a tier. |
| `dylib/feats/advice.c` | Mac + game + history → settings, launch arguments, badge and reason. Also the verdict for a game that is not installed, from Valve's data. |
| `dylib/feats/rules.c` | Launch rules, on the plugin grammar (`conf.c`, kind `NP_CONF_RULE`). |
| `dylib/feats/catalog.c` | One pass over the library: scans what changed, writes the badge file and each game's advice, hands the map to the UI. |
| `helpers/appinfo.swift` | `--compat` prints Valve's category and anti-cheat result per game. |
| `dylib/feats/webpatch.c` | Draws the tile badge, the game page stat, and the Preferences rows. |
| `dylib/feats/store.c`, `store_page.js` | The store and wishlist. |
| `dylib/feats/compat_run.sh` | Records sessions; applies advice and rule arguments at launch. |

Two things worth knowing before changing the UI code:

- Steam runs its JavaScript in a hidden `SharedJSContext` and draws into a separate
  window. `document` in injected code is the hidden one, so a `<style>` element added
  there never reaches the page. Everything is styled on the elements themselves.
- The tile's own icon row is only shown while the tile is hovered. The badge is a child
  of the tile beside that row, placed by its own style.

The anchors into Steam's interface are checked as a set before any is written. If Steam
moves one, that part switches off with a warning in `notproton.log` and the rest carries
on. The tile badge and the game page stat have separate anchors for that reason.

## Checking it

```
make tuning-check verdict-check advice-check game-check rules-check catalog-check store-check
make panel-behavior envcheck buildcheck
```

`panel-behavior` runs the injected interface code against stubs; `store-check` also runs
the store page script, and checks that it says word for word what `advice.c` says.

None of that shows what Steam actually draws. To look at the real thing, with the store
switch on, Steam's debugger is at `http://127.0.0.1:27101/json`: any DevTools client can
attach to the `Steam` window and inspect the tiles. `tools/store-badge/agent.js` injects
`store_page.js` from a script, for working on it without rebuilding the dylib.

## Known limits

- The anchors were written against Steam client build 1794536281. Other builds may need
  them moved, as the existing gates do.
- The Apple mark is Apple's trademark.
- A game's badge updates when Steam starts, not the moment a session ends.
- Detection reads what is near the top of the install folder (five levels, 20,000
  entries). An unusual layout can hide the real executable.
- Deck "verified" is not a promise for CrossOver, which is why it is shown as Likely.
