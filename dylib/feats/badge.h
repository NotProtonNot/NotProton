// The Mac badge a game wears in the library.
#ifndef NOTPROTON_FEATS_BADGE_H
#define NOTPROTON_FEATS_BADGE_H

#include "game.h"
#include "verdict.h"

#include <stddef.h>

// Green is only ever what this Mac has seen. Red is a game that cannot work here.
typedef enum {
    NP_BADGE_UNKNOWN = 0,
    NP_BADGE_GOOD,
    NP_BADGE_ISSUES,
    NP_BADGE_BLOCKED,
} np_badge_t;

// game and history may be NULL. Writes one sentence for the tooltip into reason.
np_badge_t np_badge_for(const np_game_t *game, const np_verdict_t *history,
                        char *reason, size_t size);

// "good", "issues", "blocked" or "unknown".
const char *np_badge_name(np_badge_t badge);

#endif // NOTPROTON_FEATS_BADGE_H
