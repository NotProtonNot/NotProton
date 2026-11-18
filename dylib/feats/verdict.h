// How a game has actually run on this Mac, from the sessions the run script recorded.
#ifndef NOTPROTON_FEATS_VERDICT_H
#define NOTPROTON_FEATS_VERDICT_H

#include <stddef.h>

#define NP_VERDICT_FIELD_MAX 64

// What the page says about a game. Nothing here is a claim about the game itself: it is
// what this Mac saw, on the builds and settings it was run with.
typedef enum {
    NP_VERDICT_UNKNOWN = 0,  // never run here, or no session said anything
    NP_VERDICT_BROKEN,       // it has run and it has only ever crashed
    NP_VERDICT_PLAYABLE,     // it runs, but not every session came through clean
    NP_VERDICT_VERIFIED,     // it runs, more than once, and nothing crashed
} np_verdict_tier_t;

typedef struct {
    np_verdict_tier_t tier;
    int  healthy;            // sessions that ended without a Wine crash
    int  failed;             // sessions that crashed inside the first minute
    int  minutes;            // how long the game has run here, in all
    char last[16];           // healthy, failed or unknown
    char build[NP_VERDICT_FIELD_MAX];    // the CrossOver build of the last session
    char backend[NP_VERDICT_FIELD_MAX];  // and the graphics backend it ran with
} np_verdict_t;

// Reads <compatdata>/notproton-sessions. Returns 0 and leaves `out` an unknown verdict
// when there is no record, or when the one there is not the format this reads.
int np_verdict_read(const char *compatdata, np_verdict_t *out);

// "unknown", "broken", "playable" or "verified", for the page.
const char *np_verdict_name(np_verdict_tier_t tier);

#endif // NOTPROTON_FEATS_VERDICT_H
