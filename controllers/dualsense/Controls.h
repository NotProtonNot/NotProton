#pragma once
#include <stdint.h>
#include <stdbool.h>
#include <string.h>

// State is retained for comparison, but valid bits are transactions. Replaying
// a stale LED/player color alongside every trigger update fights Steam/macOS.
static inline bool DSBControlDelta(const uint8_t state[47], const uint8_t previous[47], bool known,
                                   uint8_t out[47]) {
    memset(out, 0, 47);
    // Offsets are within the 47-byte common output payload (report ID excluded).
    static const struct {
        unsigned flagByte, validBit, offset, length;
    } fields[] = {
        {0, 4, 10, 11}, // Right adaptive trigger.
        {0, 8, 21, 11}, // Left adaptive trigger.
        {1, 4, 44, 3},  // RGB lightbar.
        {1, 16, 43, 1}, // Player indicator.
        {1, 1, 8, 1},   // Microphone indicator.
    };
    bool changed = false;
    for (unsigned i = 0; i < sizeof(fields) / sizeof(fields[0]); i++) {
        unsigned flag = fields[i].flagByte, bit = fields[i].validBit;
        unsigned offset = fields[i].offset, length = fields[i].length;
        if ((state[flag] & bit) && (!known || !(previous[flag] & bit) ||
                                    memcmp(state + offset, previous + offset, length))) {
            out[flag] |= bit;
            memcpy(out + offset, state + offset, length);
            changed = true;
        }
    }
    return changed;
}

// Release only triggers written by this session; never reset another client's trigger.
static inline void DSBTriggerRelease(uint8_t touched, uint8_t report[64]) {
    memset(report, 0, 64);
    report[0] = 2;
    report[1] = touched & 12;
    if (touched & 4) {
        report[11] = 5;
    }
    if (touched & 8) {
        report[22] = 5;
    }
}
