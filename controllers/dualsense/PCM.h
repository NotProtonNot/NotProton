#pragma once
#include <stdint.h>
#include <stdbool.h>
#include <string.h>
#include <math.h>
#include <zlib.h>

// Streaming 257-tap, 1.2 kHz anti-alias filter for conversion to 3 kHz PCM.
typedef struct {
    float h[257], history[257][2];
    unsigned pos;
    double phase, rate;
} DSBResampler;
static inline void DSBResamplerInit(DSBResampler *r, double rate) {
    memset(r, 0, sizeof(*r));
    r->rate = rate;
    double sum = 0, cut = 1200 / rate;
    for (int i = 0; i < 257; i++) {
        double x = i - 128;
        double v = (x ? sin(2 * M_PI * cut * x) / (M_PI * x) : 2 * cut) *
                   (.5 - .5 * cos(2 * M_PI * i / 256));
        r->h[i] = v;
        sum += v;
    }
    for (int i = 0; i < 257; i++) {
        r->h[i] /= sum;
    }
}
static inline bool DSBResample(DSBResampler *r, float l, float rr, int8_t out[2]) {
    r->history[r->pos][0] = isfinite(l) ? l : 0;
    r->history[r->pos][1] = isfinite(rr) ? rr : 0;
    r->pos = (r->pos + 1) % 257;
    r->phase += 3000;
    if (r->phase + 1e-6 < r->rate) {
        return false;
    }
    r->phase -= r->rate;
    double a = 0, b = 0;
    unsigned at = r->pos;
    for (unsigned k = 0; k < 257; k++) {
        at = (at + 256) % 257;
        a += r->h[k] * r->history[at][0];
        b += r->h[k] * r->history[at][1];
    }
    out[0] = (int8_t)lrint(fmax(-128, fmin(127, a * 127)));
    out[1] = (int8_t)lrint(fmax(-128, fmin(127, b * 127)));
    return true;
}
static inline void DSBCRC(uint8_t *b, unsigned n) {
    uint8_t seed = 0xa2;
    uint32_t c = (uint32_t)crc32(0, &seed, 1);
    c = (uint32_t)crc32(c, b, n - 4);
    for (int i = 0; i < 4; i++) {
        b[n - 4 + i] = c >> (8 * i);
    }
}
// The first report initializes audio buffers. Compact continuation retains
// control bit 1 to keep normal HID input active during PCM output.
static inline unsigned DSBPCMReport(uint8_t b[206], unsigned seq, unsigned pcmIndex, bool first,
                                    const int8_t samples[128]) {
    memset(b, 0, 206);
    b[0] = first ? 0x33 : 0x32;
    b[1] = (seq & 15) << 4;
    b[2] = 0x91;
    unsigned offset, n;
    if (first) {
        b[3] = 7;
        b[4] = 0xfe;
        memset(b + 5, 48, 5);
        b[10] = (uint8_t)(pcmIndex * 2);
        b[11] = 0xd2;
        b[12] = 64;
        offset = 13;
        n = 206;
    } else {
        b[3] = 3;
        b[4] = 0x62;
        b[5] = 48;
        b[6] = (uint8_t)(pcmIndex * 2);
        b[7] = 0xd2;
        b[8] = 64;
        offset = 9;
        n = 142;
    }
    memcpy(b + offset, samples, 128);
    DSBCRC(b, n);
    return n;
}
