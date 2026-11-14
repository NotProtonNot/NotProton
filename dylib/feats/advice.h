// One answer for one game on this Mac: what to run it with, and what to say about it.
#ifndef NOTPROTON_FEATS_ADVICE_H
#define NOTPROTON_FEATS_ADVICE_H

#include "defaults.h"
#include "game.h"
#include "machine.h"
#include "verdict.h"

#include <stdint.h>

// What the badge on the game's tile says. The colours are the Steam Deck's, read for a
// Mac: green is a game this Mac has actually run well, red is one that cannot work here,
// yellow is one with something in the way, and white is one nothing is known about yet.
typedef enum {
    NP_BADGE_UNKNOWN = 0,
    NP_BADGE_GOOD,
    NP_BADGE_ISSUES,
    NP_BADGE_BLOCKED,
    // Not run here, but Valve's testing passed it under Proton, which is the best sign
    // there is for a game nobody has downloaded yet. Kept apart from GOOD on purpose:
    // green is what this Mac has seen, and this is only what a Steam Deck has.
    NP_BADGE_LIKELY,
} np_badge_t;

#define NP_ADVICE_OPTIONS_MAX 192
#define NP_ADVICE_REASON_MAX  256

typedef struct {
    char       settings[NP_DEFAULTS_TEXT_MAX + 1];  // KEY=VALUE lines, one per line
    char       options[NP_ADVICE_OPTIONS_MAX];      // arguments to pass the game itself
    np_badge_t badge;
    char       reason[NP_ADVICE_REASON_MAX];        // one sentence, for the tooltip
} np_advice_t;

// `game` and `history` may be NULL, which is a game that has not been looked at: the
// settings still come back, and the badge says nothing rather than guessing.
void np_advice(const np_machine_t *machine, const np_game_t *game, const np_verdict_t *history,
               uint32_t runner, np_advice_t *out);

const char *np_badge_name(np_badge_t badge);

// Valve's Steam Deck categories, as appinfo.vdf numbers them.
#define NP_DECK_UNKNOWN     0
#define NP_DECK_UNSUPPORTED 1
#define NP_DECK_PLAYABLE    2
#define NP_DECK_VERIFIED    3

// A verdict for a game that is not installed, from what Steam already knows about it:
// whether it lists a macOS build, its Deck category, and whether Valve's tests failed it
// for its anti-cheat. Writes the reason and returns the badge.
np_badge_t np_advice_from_valve(int mac, int deck, int anticheat, char *reason, size_t size);

#endif // NOTPROTON_FEATS_ADVICE_H
