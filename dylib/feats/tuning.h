// The settings this Mac is best run with, as the lines defaults.c already takes.
#ifndef NOTPROTON_FEATS_TUNING_H
#define NOTPROTON_FEATS_TUNING_H

#include "machine.h"

#include <stddef.h>
#include <stdint.h>

// Writes "KEY=VALUE\n" lines for `runner` (NP_DEFAULTS_ROSETTA or NP_DEFAULTS_FEX) into
// out, every one of them a key and a value the defaults whitelist accepts. Returns 0 and
// empties out when the runner is neither, or when the lines do not fit.
//
// Only what the hardware decides is set. A toggle whose answer depends on the game, such
// as the DLSS extensions a title may or may not ask for, is left alone so that applying
// this never silently changes how one game behaves on the strength of what the Mac is.
int np_tuning_recommend(const np_machine_t *m, uint32_t runner, char *out, size_t size);

#endif // NOTPROTON_FEATS_TUNING_H
