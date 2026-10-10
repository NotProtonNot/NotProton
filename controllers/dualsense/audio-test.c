#include <CoreAudio/CoreAudio.h>
#include <AudioUnit/AudioUnit.h>
#include <assert.h>
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>
#include <stdatomic.h>
#include <math.h>
#include <string.h>
static atomic_uint calls;
static unsigned sampleBits = 32;
static bool floating = true, signedPCM = false;
static const char *mode = "normal";
static uint8_t alternateBuffer[1920 * 16];
static void storeSample(uint8_t *out, float sample) {
    if (floating) {
        memcpy(out, &sample, sizeof(sample));
        return;
    }
    double midpoint = ldexp(1.0, sampleBits - 1);
    int64_t value = llrint(sample * midpoint);
    if (!signedPCM) {
        value += (int64_t)midpoint;
    }
    uint32_t bits = (uint32_t)value;
    memcpy(out, &bits, sampleBits / 8);
}
static OSStatus render(void *ctx, AudioUnitRenderActionFlags *f, const AudioTimeStamp *t,
                       UInt32 bus, UInt32 n, AudioBufferList *list) {
    assert(list->mNumberBuffers == 1);
    if (!strcmp(mode, "fail")) {
        atomic_fetch_add(&calls, 1);
        return -1;
    }
    if (!strcmp(mode, "external")) {
        assert(list->mBuffers[0].mDataByteSize <= sizeof(alternateBuffer));
        list->mBuffers[0].mData = alternateBuffer;
    }
    uint8_t *samples = list->mBuffers[0].mData;
    unsigned width = sampleBits / 8;
    for (unsigned i = 0; i < n; i++) {
        storeSample(samples + (i * 4) * width, .75);
        storeSample(samples + (i * 4 + 1) * width, .75);
        storeSample(samples + (i * 4 + 2) * width, -.125);
        storeSample(samples + (i * 4 + 3) * width, .5);
    }
    if (!strcmp(mode, "silence")) {
        *f |= kAudioUnitRenderAction_OutputIsSilence;
    } else if (!strcmp(mode, "short")) {
        list->mBuffers[0].mDataByteSize = 0;
    }
    atomic_fetch_add(&calls, 1);
    return 0;
}
int main(int argc, char **argv) {
    if (argc > 1) {
        floating = argv[1][0] == 'f';
        signedPCM = argv[1][0] == 's';
        sampleBits = (unsigned)atoi(argv[1] + 1);
    }
    if (argc > 2) {
        mode = argv[2];
    }
    AudioObjectPropertyAddress a = {kAudioHardwarePropertyDevices, kAudioObjectPropertyScopeGlobal,
                                    kAudioObjectPropertyElementMain};
    UInt32 n = 0;
    assert(!AudioObjectGetPropertyDataSize(kAudioObjectSystemObject, &a, 0, NULL, &n));
    AudioObjectID *ids = calloc(1, n);
    assert(!AudioObjectGetPropertyData(kAudioObjectSystemObject, &a, 0, NULL, &n, ids));
    bool found = false;
    for (unsigned i = 0; i < n / 4; i++) {
        if (ids[i] == 0x44533542) {
            found = true;
        }
    }
    free(ids);
    assert(found);
    if (!strcmp(mode, "volume")) {
        a.mSelector = kAudioDevicePropertyVolumeScalar;
        for (UInt32 element = 0; element <= 4; element++) {
            a.mElement = element;
            Float32 volume = element == 0 ? .5 : element == 3 ? .5 : 1;
            assert(!AudioObjectSetPropertyData(0x44533542, &a, 0, NULL, sizeof(volume), &volume));
            Float32 observed = -1;
            n = sizeof(observed);
            assert(!AudioObjectGetPropertyData(0x44533542, &a, 0, NULL, &n, &observed));
            assert(observed == volume);
        }
    } else if (!strcmp(mode, "mute")) {
        a.mSelector = kAudioDevicePropertyMute;
        UInt32 muted = 1;
        assert(!AudioObjectSetPropertyData(0x44533542, &a, 0, NULL, sizeof(muted), &muted));
    }
    AudioComponentDescription d = {kAudioUnitType_Output, kAudioUnitSubType_HALOutput,
                                   kAudioUnitManufacturer_Apple, 0, 0};
    AudioComponent comp = AudioComponentFindNext(NULL, &d);
    assert(comp);
    AudioComponentInstance unit;
    assert(!AudioComponentInstanceNew(comp, &unit));
    UInt32 dev = 0x44533542;
    assert(!AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice,
                                 kAudioUnitScope_Global, 0, &dev, 4));
    AudioStreamBasicDescription fmt = {48000,
                                       kAudioFormatLinearPCM,
                                       kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
                                       16,
                                       1,
                                       16,
                                       4,
                                       32,
                                       0};
    fmt.mBitsPerChannel = sampleBits;
    fmt.mBytesPerFrame = fmt.mBytesPerPacket = 4 * (sampleBits / 8);
    fmt.mFormatFlags = kAudioFormatFlagIsPacked | (floating    ? kAudioFormatFlagIsFloat
                                                   : signedPCM ? kAudioFormatFlagIsSignedInteger
                                                               : 0);
    AudioStreamBasicDescription invalid = fmt;
    invalid.mSampleRate = NAN;
    assert(AudioUnitSetProperty(unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 0,
                                &invalid, sizeof(invalid)) == kAudioUnitErr_FormatNotSupported);
    invalid = fmt;
    invalid.mBytesPerPacket = 0;
    assert(AudioUnitSetProperty(unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 0,
                                &invalid, sizeof(invalid)) == kAudioUnitErr_FormatNotSupported);
    UInt32 current = 0, currentSize = sizeof(current);
    assert(!AudioUnitGetProperty(unit, kAudioOutputUnitProperty_CurrentDevice,
                                 kAudioUnitScope_Global, 0, &current, &currentSize));
    assert(current == dev);
    assert(!AudioUnitSetProperty(unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 0,
                                 &fmt, sizeof(fmt)));
    AURenderCallbackStruct cb = {render, NULL};
    assert(!AudioUnitSetProperty(unit, kAudioUnitProperty_SetRenderCallback, kAudioUnitScope_Input,
                                 0, &cb, sizeof(cb)));
    assert(!AudioUnitInitialize(unit));
    assert(!AudioOutputUnitStart(unit));
    usleep(150000);
    assert(AudioUnitSetProperty(unit, kAudioUnitProperty_SetRenderCallback, kAudioUnitScope_Input,
                                0, &cb, sizeof(cb)) == kAudioUnitErr_CannotDoInCurrentContext);
    // Uninitialize must join the renderer even when the client omitted Stop.
    assert(!AudioUnitUninitialize(unit));
    unsigned stoppedAt = atomic_load(&calls);
    assert(stoppedAt >= 5);
    usleep(30000);
    assert(atomic_load(&calls) == stoppedAt);
    assert(!AudioOutputUnitStop(unit));
    assert(!AudioComponentInstanceDispose(unit));
    printf("PASS callbacks=%u format=%s mode=%s\n", atomic_load(&calls), argc > 1 ? argv[1] : "f32",
           mode);
}
