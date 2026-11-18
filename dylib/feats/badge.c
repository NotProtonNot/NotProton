#include "badge.h"

#include <stdio.h>

np_badge_t np_badge_for(const np_game_t *game, const np_verdict_t *history,
                        char *reason, size_t size) {
    const int scanned = game && game->scanned;
    // Most serious first: an anti-cheat outranks any history.
    if (scanned && game->anticheat != NP_AC_NONE) {
        snprintf(reason, size, "This game uses %s, which does not run under CrossOver on macOS.",
                 np_game_anticheat_name(game->anticheat));
        return NP_BADGE_BLOCKED;
    }
    if (history && history->tier == NP_VERDICT_BROKEN) {
        snprintf(reason, size, "This game has crashed every time it was started on this Mac (%d of %d).",
                 history->failed, history->failed);
        return NP_BADGE_BLOCKED;
    }
    if (scanned && game->launcher != NP_LAUNCHER_NONE) {
        snprintf(reason, size, "This game starts through %s, which may need setting up inside the "
                               "prefix before the game itself will run.",
                 np_game_launcher_name(game->launcher));
        return NP_BADGE_ISSUES;
    }
    if (history && history->tier == NP_VERDICT_PLAYABLE && history->failed) {
        snprintf(reason, size, "This game runs on this Mac, but %d of its %d sessions here crashed.",
                 history->failed, history->failed + history->healthy);
        return NP_BADGE_ISSUES;
    }
    if (history && history->tier == NP_VERDICT_VERIFIED) {
        snprintf(reason, size, "This game has run on this Mac %d times without crashing.", history->healthy);
        return NP_BADGE_GOOD;
    }
    if (scanned && game->native) {
        snprintf(reason, size, "This game has a native macOS version, which Steam runs without CrossOver.");
        return NP_BADGE_GOOD;
    }
    snprintf(reason, size, "This game has not run on this Mac yet.");
    return NP_BADGE_UNKNOWN;
}

const char *np_badge_name(np_badge_t badge) {
    switch (badge) {
        case NP_BADGE_GOOD:    return "good";
        case NP_BADGE_ISSUES:  return "issues";
        case NP_BADGE_BLOCKED: return "blocked";
        default:               return "unknown";
    }
}
