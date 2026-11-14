// What this Mac is, for the settings that depend on the hardware.
#ifndef NOTPROTON_FEATS_MACHINE_H
#define NOTPROTON_FEATS_MACHINE_H

#include <stddef.h>

#define NP_MACHINE_CHIP_MAX 64

// Zero in a field means the probe could not read it, so a caller treats it as unknown
// rather than as a small number: a Mac with no window server has no display to size, and
// a GPU whose core count the registry does not carry still runs games.
typedef struct {
    int      apple_silicon;
    char     chip[NP_MACHINE_CHIP_MAX];  // "Apple M4 Max", or the CPU brand on Intel
    int      gpu_cores;
    int      cpu_cores;
    unsigned ram_gb;
    int      macos_major;
    int      display_w, display_h;       // backing pixels of the main display's mode
    int      refresh_hz;
} np_machine_t;

// Probed once, then the same answer for the life of the process. Never NULL: a probe that
// reads nothing returns a profile of zeroes, which every caller already has to handle.
const np_machine_t *np_machine(void);

// "Apple M4 Max, 40 GPU cores, 64 GB, 3456x2234 at 120 Hz", for the line under the
// button that applies the settings. Truncates rather than fails.
void np_machine_summary(const np_machine_t *m, char *out, size_t size);

#endif // NOTPROTON_FEATS_MACHINE_H
