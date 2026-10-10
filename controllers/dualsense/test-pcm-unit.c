#include <assert.h>
#include <stdio.h>
#include "PCM.h"
int main(void) {
    for (int f = 0; f < 2; f++) {
        DSBResampler r;
        DSBResamplerInit(&r, 48000);
        double energy = 0;
        unsigned n = 0;
        for (int i = 0; i < 48000; i++) {
            float v = .5 * sin(2 * M_PI * (f ? 5000 : 50) * i / 48000.);
            int8_t out[2];
            if (DSBResample(&r, v, -v, out)) {
                assert(out[0] == -out[1]);
                if (n > 100) {
                    energy += out[0] * out[0];
                }
                n++;
            }
        }
        assert(n == 3000);
        double rms = sqrt(energy / 2899) / 127;
        if (f) {
            assert(rms < .01);
        } else {
            assert(rms > .34 && rms < .37);
        }
    }
    int8_t data[128];
    for (int i = 0; i < 128; i++) {
        data[i] = i - 64;
    }
    for (unsigned seq = 0; seq < 512; seq++) {
        for (int first = 0; first < 2; first++) {
            uint8_t b[206];
            unsigned n = DSBPCMReport(b, seq, seq, first, data);
            assert(n == (first ? 206 : 142));
            assert(b[1] == (seq % 16) * 16);
            assert(!memcmp(b + (first ? 13 : 9), data, 128));
            assert(b[4] == (first ? 0xfe : 0x62));
            assert(b[first ? 10 : 6] == (uint8_t)(seq * 2));
            unsigned crc = 0xffffffff;
            unsigned char seed = 0xa2;
            for (unsigned k = 0; k < n - 3; k++) {
                unsigned char v = k ? b[k - 1] : seed;
                crc ^= v;
                for (int j = 0; j < 8; j++) {
                    crc = (crc >> 1) ^ ((crc & 1) ? 0xedb88320 : 0);
                }
            }
            crc = ~crc;
            assert(b[n - 4] == (crc & 255) && b[n - 3] == ((crc >> 8) & 255) &&
                   b[n - 2] == ((crc >> 16) & 255) && b[n - 1] == (crc >> 24));
        }
    }
    puts("PASS: signed 50Hz waveform/phase, antialias rejection, 3kHz rate, packet payload, "
         "independent CRC and sequence wrap");
}
