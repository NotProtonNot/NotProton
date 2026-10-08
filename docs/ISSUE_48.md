# Native Mac library filter

[Upstream issue 48](https://github.com/NotProtonNot/NotProton/issues/48) asks for Steam’s “Show only games that run on macOS” filter to show native Mac games, even while Steam Play makes Windows games runnable.

## Findings

The locally inspected Steam client has a library predicate that accepts every app when Steam Play is enabled. NotProton also overrides the invalid-OS getter to allow compatibility launches. Consequently, removing the global Steam Play bypass alone would not prove that the remaining result means native Mac support.

The compact library overview does not expose the same native platform list (`vecPlatforms`) used by the full app-details screen. Filtering only on already loaded details could hide native games until their details happen to be fetched. Fetching full details for every library item during filter evaluation needs a separate cache, loading behavior, refresh handling and tests with a large library.

## Status

**Investigated, not fixed in this contribution.** No new filter predicate is shipped, and the PR must not claim that issue 48 is resolved. A reliable follow-up should use native platform metadata independently of Steam Play, preserve ordinary launching and shortcuts, and verify all three states: filter off, native-only filter on and metadata loading. It must also handle native 32-bit Mac games explicitly rather than claiming their store platform tag guarantees current macOS compatibility.

Until then, the macOS library button can include games made available through compatibility tools. That is distinct from the per-game Properties → Compatibility checkbox used to select CrossOver.
