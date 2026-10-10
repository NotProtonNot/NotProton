#pragma once
#include <stdint.h>
#include <stdbool.h>
#include <string.h>
#define DSB_MAGIC 0x31425344u
#define DSB_LEVEL 1
#define DSB_OUTPUT 2
#define DSB_PCM 3
// report[0]: frame count (0=end, 30=10ms), report[1..3]: stream ID,
// report[4..63]: 30 signed-8-bit stereo PCM frames at 3000 Hz.
typedef struct __attribute__((packed)) {
    uint32_t magic, kind;
    uint8_t token[16];
    uint32_t pid, sequence;
    double timestamp;
    float left, right;
    uint8_t report[64];
} DSBPacket;

// Session tokens are exactly 16 bytes encoded as 32 hexadecimal characters.
static inline bool DSBParseToken(const char *text, uint8_t token[16]) {
    if (!text || strlen(text) != 32) {
        return false;
    }
    for (unsigned i = 0; i < 16; ++i) {
        unsigned byte = 0;
        for (unsigned digit = 0; digit < 2; ++digit) {
            unsigned char c = text[i * 2 + digit];
            unsigned value;
            if (c >= '0' && c <= '9') {
                value = c - '0';
            } else if (c >= 'a' && c <= 'f') {
                value = c - 'a' + 10;
            } else if (c >= 'A' && c <= 'F') {
                value = c - 'A' + 10;
            } else {
                return false;
            }
            byte = (byte << 4) | value;
        }
        token[i] = byte;
    }
    return true;
}
