// Launch rules: what to pass a particular game, read from files rather than built in.
#ifndef NOTPROTON_FEATS_RULES_H
#define NOTPROTON_FEATS_RULES_H

#include "game.h"

#define NP_RULES_OPTIONS_MAX 192
#define NP_RULES_NOTE_MAX    192

typedef struct {
    char options[NP_RULES_OPTIONS_MAX];  // space separated, in the order the rules gave them
    char note[NP_RULES_NOTE_MAX];        // the first note a matching rule carried
    int  matched;
} np_rules_t;

// Reads *.conf in `dir` and collects what the rules matching this game say. A rule has to
// match on everything it names -- appid, engine, launcher, executable -- so a rule for one
// game never reaches another.
void np_rules_apply(const char *dir, const char *shown_dir, unsigned appid,
                    const np_game_t *game, np_rules_t *out);

#endif // NOTPROTON_FEATS_RULES_H
