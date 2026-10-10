#include "Controls.h"
#include "protocol.h"
#include <assert.h>
#include <stdio.h>
int main(void) {
    uint8_t state[47] = {0}, previous[47] = {0}, out[47];
    state[1] = 4 | 16;
    state[44] = 217;
    state[45] = 255;
    state[43] = 4;
    assert(DSBControlDelta(state, previous, false, out));
    assert(out[1] == 20);
    memcpy(previous, state, 47);
    state[0] = 4;
    state[10] = 0x21;
    state[11] = 0xfe;
    assert(DSBControlDelta(state, previous, true, out));
    assert(out[0] == 4 && out[1] == 0);
    assert(out[43] == 0 && out[44] == 0 && out[45] == 0);
    memcpy(previous, state, 47);
    assert(!DSBControlDelta(state, previous, true, out));
    state[10] = 5;
    state[11] = 0;
    assert(DSBControlDelta(state, previous, true, out));
    assert(out[0] == 4 && out[10] == 5 && out[1] == 0);
    memcpy(previous, state, 47);
    state[44] = 0;
    state[45] = 0;
    assert(DSBControlDelta(state, previous, true, out));
    assert(out[0] == 0 && out[1] == 4);
    memcpy(previous, state, 47);
    state[43] = 2;
    assert(DSBControlDelta(state, previous, true, out));
    assert(out[0] == 0 && out[1] == 16 && out[43] == 2);
    uint8_t release[64];
    DSBTriggerRelease(4, release);
    assert(release[1] == 4 && release[11] == 5 && release[22] == 0);
    DSBTriggerRelease(8, release);
    assert(release[1] == 8 && release[11] == 0 && release[22] == 5);
    DSBTriggerRelease(0, release);
    assert(release[1] == 0 && release[11] == 0 && release[22] == 0);
    uint8_t token[16];
    assert(DSBParseToken("0123456789aBcDeF0123456789aBcDeF", token));
    assert(token[0] == 1 && token[7] == 0xef);
    assert(!DSBParseToken(NULL, token));
    assert(!DSBParseToken("1234", token));
    assert(!DSBParseToken("1z23456789abcdef0123456789abcdef", token));
    assert(!DSBParseToken(" 123456789abcdef0123456789abcdef", token));
    puts("PASS: changing triggers/rumble never replays old RGB/player state; actual color/release "
         "changes preserved");
}
