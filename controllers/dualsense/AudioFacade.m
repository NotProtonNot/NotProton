// Wine-local CoreAudio/AudioUnit facade. HID translation lives in bridge.m;
// only authenticated packet transport is shared between the two components.
#import <Foundation/Foundation.h>
#import <CoreAudio/CoreAudio.h>
#import <AudioUnit/AudioUnit.h>
#include <pthread.h>
#include <stdatomic.h>
#include <unistd.h>
#include <mach/mach_time.h>
#include "Bridge.h"
#include "PCM.h"
#include "protocol.h"

// A four-channel endpoint visible only to the Wine processes which load this library.
// Speaker channels 0/1 are discarded; haptic channels 2/3 feed the selected transport.
#define VDEVICE 0x44533542u
#define VSTREAM 0x44533543u
#define VUID CFSTR("DualSenseSteamBridge-Bluetooth-Haptics-v1")
// Element zero is the master volume; elements 1..4 address individual channels.
static _Atomic(float) deviceVolume[5] = {1, 1, 1, 1, 1};
static atomic_bool deviceMuted;
static bool audioEnabled(void) {
    return DSBBridgeEnabled() && DSBRawControllerEnabled();
}
static OSStatus copyResult(UInt32 *n, void *out, const void *in, UInt32 size) {
    if (*n < size) {
        return kAudioHardwareBadPropertySizeError;
    }
    memcpy(out, in, size);
    *n = size;
    return noErr;
}
static OSStatus virtualProperty(AudioObjectID id, const AudioObjectPropertyAddress *a, UInt32 *size,
                                void *data, bool sizeOnly) {
    uint8_t bytes[256] = {0};
    UInt32 n = 4, u = 0;
    Float64 rate = 48000;
    Float32 volume;
    CFStringRef s = NULL;
    switch (a->mSelector) {
    case kAudioObjectPropertyName:
        s = CFSTR("DualSense Wireless Controller (Bluetooth Bridge)");
        break;
    case kAudioDevicePropertyDeviceUID:
        s = VUID;
        break;
    case kAudioObjectPropertyManufacturer:
        s = CFSTR("Local DualSense Steam Bridge");
        break;
    case kAudioDevicePropertyModelUID:
        s = CFSTR("054c:0ce6:wireless");
        break;
    case kAudioDevicePropertyStreamConfiguration: {
        AudioBufferList list = {.mNumberBuffers =
                                    a->mScope == kAudioDevicePropertyScopeInput ? 0 : 1,
                                .mBuffers = {{.mNumberChannels = 4}}};
        n = sizeof(list);
        memcpy(bytes, &list, n);
        break;
    }
    case kAudioDevicePropertyPreferredChannelLayout:
        return kAudioHardwareUnknownPropertyError;
    case kAudioDevicePropertyNominalSampleRate:
        n = 8;
        memcpy(bytes, &rate, n);
        break;
    case kAudioDevicePropertyAvailableNominalSampleRates: {
        AudioValueRange range = {48000, 48000};
        n = sizeof(range);
        memcpy(bytes, &range, n);
        break;
    }
    case kAudioDevicePropertyStreams:
        u = VSTREAM;
        memcpy(bytes, &u, 4);
        if (a->mScope == kAudioDevicePropertyScopeInput) {
            n = 0;
        }
        break;
    case kAudioObjectPropertyClass:
        u = id == VSTREAM ? kAudioStreamClassID : kAudioDeviceClassID;
        memcpy(bytes, &u, 4);
        break;
    case kAudioDevicePropertyTransportType:
        u = kAudioDeviceTransportTypeUSB;
        memcpy(bytes, &u, 4);
        break;
    case kAudioDevicePropertyDeviceIsAlive:
        u = 1;
        memcpy(bytes, &u, 4);
        break;
    case kAudioDevicePropertyBufferFrameSize:
        u = 480;
        memcpy(bytes, &u, 4);
        break;
    case kAudioDevicePropertyBufferFrameSizeRange: {
        AudioValueRange range = {480, 480};
        n = sizeof(range);
        memcpy(bytes, &range, n);
        break;
    }
    case kAudioDevicePropertyVolumeScalar:
        if (a->mElement > 4) {
            return kAudioHardwareUnknownPropertyError;
        }
        volume = atomic_load(&deviceVolume[a->mElement]);
        memcpy(bytes, &volume, 4);
        break;
    case kAudioDevicePropertyMute:
        u = atomic_load(&deviceMuted);
        memcpy(bytes, &u, 4);
        break;
    case kAudioDevicePropertyLatency:
    case kAudioDevicePropertySafetyOffset:
        break;
    default:
        return kAudioHardwareUnknownPropertyError;
    }
    if (s) {
        n = sizeof(s);
        if (!sizeOnly && *size >= n) {
            CFRetain(s);
        }
        memcpy(bytes, &s, n);
    }
    if (sizeOnly) {
        *size = n;
        return noErr;
    }
    return copyResult(size, data, bytes, n);
}
static OSStatus objectSize(AudioObjectID id, const AudioObjectPropertyAddress *a, UInt32 q,
                           const void *qual, UInt32 *n) {
    if (audioEnabled() && (id == VDEVICE || id == VSTREAM)) {
        return virtualProperty(id, a, n, NULL, true);
    }
    OSStatus r = AudioObjectGetPropertyDataSize(id, a, q, qual, n);
    if (audioEnabled() && r == noErr && id == kAudioObjectSystemObject &&
        a->mSelector == kAudioHardwarePropertyDevices) {
        *n += 4;
    }
    return r;
}
DSB_INTERPOSE(objectSize, AudioObjectGetPropertyDataSize);
static OSStatus objectData(AudioObjectID id, const AudioObjectPropertyAddress *a, UInt32 q,
                           const void *qual, UInt32 *n, void *out) {
    if (audioEnabled()) {
        if (id == VDEVICE || id == VSTREAM) {
            return virtualProperty(id, a, n, out, false);
        }
        if (id == kAudioObjectSystemObject &&
            a->mSelector == kAudioHardwarePropertyTranslateUIDToDevice &&
            q == sizeof(CFStringRef) && qual && CFEqual(*(CFStringRef *)qual, VUID)) {
            UInt32 v = VDEVICE;
            return copyResult(n, out, &v, 4);
        }
        if (id == kAudioObjectSystemObject && a->mSelector == kAudioHardwarePropertyDevices) {
            UInt32 cap = *n;
            OSStatus r = AudioObjectGetPropertyData(id, a, q, qual, n, out);
            if (r == noErr && cap >= *n + 4) {
                ((UInt32 *)((char *)out + *n))[0] = VDEVICE;
                *n += 4;
            }
            return r;
        }
    }
    return AudioObjectGetPropertyData(id, a, q, qual, n, out);
}
DSB_INTERPOSE(objectData, AudioObjectGetPropertyData);
static Boolean objectHas(AudioObjectID id, const AudioObjectPropertyAddress *a) {
    if (audioEnabled() && (id == VDEVICE || id == VSTREAM)) {
        UInt32 n;
        return virtualProperty(id, a, &n, NULL, true) == 0;
    }
    return AudioObjectHasProperty(id, a);
}
DSB_INTERPOSE(objectHas, AudioObjectHasProperty);
static OSStatus objectSet(AudioObjectID id, const AudioObjectPropertyAddress *a, UInt32 q,
                          const void *qual, UInt32 n, const void *in) {
    if (audioEnabled() && (id == VDEVICE || id == VSTREAM)) {
        if (id == VDEVICE && a->mSelector == kAudioDevicePropertyVolumeScalar && a->mElement <= 4) {
            if (n != sizeof(Float32) || !in) {
                return kAudioHardwareBadPropertySizeError;
            }
            Float32 volume;
            memcpy(&volume, in, sizeof(volume));
            if (!isfinite(volume) || volume < 0 || volume > 1) {
                return kAudioHardwareIllegalOperationError;
            }
            atomic_store(&deviceVolume[a->mElement], volume);
            return noErr;
        }
        if (id == VDEVICE && a->mSelector == kAudioDevicePropertyMute) {
            if (n != sizeof(UInt32) || !in) {
                return kAudioHardwareBadPropertySizeError;
            }
            UInt32 muted;
            memcpy(&muted, in, sizeof(muted));
            atomic_store(&deviceMuted, muted != 0);
            return noErr;
        }
        return kAudioHardwareUnknownPropertyError;
    }
    return AudioObjectSetPropertyData(id, a, q, qual, n, in);
}
DSB_INTERPOSE(objectSet, AudioObjectSetPropertyData);
static OSStatus objectListener(AudioObjectID id, const AudioObjectPropertyAddress *a,
                               AudioObjectPropertyListenerProc cb, void *c) {
    if (audioEnabled() && (id == VDEVICE || id == VSTREAM)) {
        return noErr;
    }
    return AudioObjectAddPropertyListener(id, a, cb, c);
}
DSB_INTERPOSE(objectListener, AudioObjectAddPropertyListener);
static OSStatus objectUnlisten(AudioObjectID id, const AudioObjectPropertyAddress *a,
                               AudioObjectPropertyListenerProc cb, void *c) {
    if (audioEnabled() && (id == VDEVICE || id == VSTREAM)) {
        return noErr;
    }
    return AudioObjectRemovePropertyListener(id, a, cb, c);
}
DSB_INTERPOSE(objectUnlisten, AudioObjectRemovePropertyListener);
typedef struct Unit {
    AudioUnit unit;
    AudioStreamBasicDescription fmt;
    AURenderCallbackStruct callback;
    pthread_t thread;
    atomic_bool running;
    bool started;
    _Atomic(float) volume;
    struct Unit *next;
} Unit;
// As with the underlying AudioUnit API, each client serializes a unit's lifecycle
// and property changes. The registry lock protects different clients/units;
// running and volume are the only fields changed concurrently with render().
static Unit *units;
static pthread_mutex_t unitLock = PTHREAD_MUTEX_INITIALIZER;
static Unit *getUnit(AudioUnit unit) {
    pthread_mutex_lock(&unitLock);
    Unit *u = units;
    while (u && u->unit != unit) {
        u = u->next;
    }
    pthread_mutex_unlock(&unitLock);
    return u;
}
static AudioStreamBasicDescription defaultFormat(void) {
    return (AudioStreamBasicDescription){48000,
                                         kAudioFormatLinearPCM,
                                         kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
                                         16,
                                         1,
                                         16,
                                         4,
                                         32,
                                         0};
}
static OSStatus unitStop(AudioUnit unit);
static void removeUnit(Unit *unit);

static OSStatus unitSet(AudioUnit unit, AudioUnitPropertyID p, AudioUnitScope scope,
                        AudioUnitElement elem, const void *data, UInt32 n) {
    Unit *u = getUnit(unit);
    if (audioEnabled() && p == kAudioOutputUnitProperty_CurrentDevice && n == 4 &&
        *(UInt32 *)data == VDEVICE) {
        if (!u) {
            u = calloc(1, sizeof(*u));
            if (!u) {
                return kAudioUnitErr_FailedInitialization;
            }
            u->unit = unit;
            u->fmt = defaultFormat();
            u->volume = 1;
            pthread_mutex_lock(&unitLock);
            u->next = units;
            units = u;
            pthread_mutex_unlock(&unitLock);
        }
        return noErr;
    }
    if (u) {
        if (p == kAudioOutputUnitProperty_CurrentDevice) {
            if (n != sizeof(AudioDeviceID)) {
                return kAudioUnitErr_InvalidPropertyValue;
            }
            if (u->started) {
                return kAudioUnitErr_CannotDoInCurrentContext;
            }
            OSStatus result = AudioUnitSetProperty(unit, p, scope, elem, data, n);
            if (result == noErr) {
                removeUnit(u);
            }
            return result;
        }
        if (p == kAudioUnitProperty_StreamFormat) {
            if (n != sizeof(u->fmt)) {
                return kAudioUnitErr_InvalidPropertyValue;
            }
            AudioStreamBasicDescription f = *(AudioStreamBasicDescription *)data;
            if (f.mFormatID != kAudioFormatLinearPCM || f.mChannelsPerFrame != 4 ||
                !isfinite(f.mSampleRate) || f.mSampleRate < 8000 || f.mSampleRate > 192000 ||
                (f.mFormatFlags &
                 (kAudioFormatFlagIsNonInterleaved | kAudioFormatFlagIsBigEndian)) ||
                f.mBytesPerFrame != 4 * (f.mBitsPerChannel / 8) || f.mFramesPerPacket != 1 ||
                f.mBytesPerPacket != f.mBytesPerFrame ||
                ((f.mFormatFlags & kAudioFormatFlagIsFloat) && f.mBitsPerChannel != 32) ||
                !(f.mBitsPerChannel == 8 || f.mBitsPerChannel == 16 || f.mBitsPerChannel == 32)) {
                return kAudioUnitErr_FormatNotSupported;
            }
            if (u->started) {
                return kAudioUnitErr_CannotDoInCurrentContext;
            }
            u->fmt = f;
        } else if (p == kAudioUnitProperty_SetRenderCallback) {
            if (n != sizeof(u->callback)) {
                return kAudioUnitErr_InvalidPropertyValue;
            }
            if (u->started) {
                return kAudioUnitErr_CannotDoInCurrentContext;
            }
            u->callback = *(AURenderCallbackStruct *)data;
        }
        return noErr;
    }
    return AudioUnitSetProperty(unit, p, scope, elem, data, n);
}
DSB_INTERPOSE(unitSet, AudioUnitSetProperty);
static OSStatus unitGet(AudioUnit unit, AudioUnitPropertyID p, AudioUnitScope scope,
                        AudioUnitElement elem, void *data, UInt32 *n) {
    Unit *u = getUnit(unit);
    if (u) {
        if (p == kAudioUnitProperty_StreamFormat) {
            return copyResult(n, data, &u->fmt, sizeof(u->fmt));
        }
        UInt32 v = p == kAudioOutputUnitProperty_CurrentDevice     ? VDEVICE
                   : p == kAudioUnitProperty_MaximumFramesPerSlice ? 4096
                                                                   : 0;
        return copyResult(n, data, &v, 4);
    }
    return AudioUnitGetProperty(unit, p, scope, elem, data, n);
}
DSB_INTERPOSE(unitGet, AudioUnitGetProperty);
static OSStatus unitInit(AudioUnit unit) {
    if (getUnit(unit)) {
        return 0;
    }
    return AudioUnitInitialize(unit);
}
DSB_INTERPOSE(unitInit, AudioUnitInitialize);
static OSStatus unitUninit(AudioUnit unit) {
    if (getUnit(unit)) {
        return unitStop(unit);
    }
    return AudioUnitUninitialize(unit);
}
DSB_INTERPOSE(unitUninit, AudioUnitUninitialize);
// Samples are interleaved little-endian PCM. Honor signedness at every width;
// Wine may choose either signed or unsigned integer PCM before opening a stream.
static float sample(const uint8_t *bytes, const AudioStreamBasicDescription *format) {
    if (format->mFormatFlags & kAudioFormatFlagIsFloat) {
        float value;
        memcpy(&value, bytes, sizeof(value));
        return isfinite(value) ? value : 0;
    }
    uint32_t value = 0;
    memcpy(&value, bytes, format->mBitsPerChannel / 8);
    double midpoint = ldexp(1.0, format->mBitsPerChannel - 1);
    double normalized = value;
    if (format->mFormatFlags & kAudioFormatFlagIsSignedInteger) {
        if (normalized >= midpoint) {
            normalized -= 2 * midpoint;
        }
    } else {
        normalized -= midpoint;
    }
    return (float)(normalized / midpoint);
}
static void clearAudioBuffer(uint8_t *buffer, size_t size,
                             const AudioStreamBasicDescription *format) {
    memset(buffer, 0, size);
    if (!(format->mFormatFlags & (kAudioFormatFlagIsFloat | kAudioFormatFlagIsSignedInteger))) {
        unsigned width = format->mBitsPerChannel / 8;
        for (size_t i = width - 1; i < size; i += width) {
            buffer[i] = 0x80;
        }
    }
}

static void *render(void *ctx) {
    Unit *u = ctx;
    unsigned frames = (unsigned)(u->fmt.mSampleRate / 100);
    size_t size = frames * u->fmt.mBytesPerFrame;
    uint8_t *buf = calloc(1, size);
    if (!buf) {
        atomic_store(&u->running, false);
        return NULL;
    }
    double frameTime = 0;
    DSBResampler resampler;
    DSBResamplerInit(&resampler, u->fmt.mSampleRate);
    static atomic_uint nextStream;
    uint32_t stream = atomic_fetch_add(&nextStream, 1) + 1;
    uint8_t pcm[64] = {0, (uint8_t)stream, (uint8_t)(stream >> 8), (uint8_t)(stream >> 16)};
    unsigned count = 0;
    double next = clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW) / 1e9;
    pthread_set_qos_class_self_np(QOS_CLASS_USER_INTERACTIVE, 0);
    while (atomic_load(&u->running)) {
        clearAudioBuffer(buf, size, &u->fmt);
        AudioBufferList list = {.mNumberBuffers = 1, .mBuffers = {{4, (UInt32)size, buf}}};
        AudioUnitRenderActionFlags flags = 0;
        AudioTimeStamp ts = {.mSampleTime = frameTime,
                             .mHostTime = mach_absolute_time(),
                             .mFlags =
                                 kAudioTimeStampSampleTimeValid | kAudioTimeStampHostTimeValid};
        OSStatus result =
            u->callback.inputProc
                ? u->callback.inputProc(u->callback.inputProcRefCon, &flags, &ts, 0, frames, &list)
                : 0;
        const uint8_t *samples = list.mBuffers[0].mData;
        if (result || (flags & kAudioUnitRenderAction_OutputIsSilence) ||
            list.mNumberBuffers != 1 || list.mBuffers[0].mNumberChannels != 4 || !samples ||
            list.mBuffers[0].mDataByteSize < size) {
            clearAudioBuffer(buf, size, &u->fmt);
            samples = buf;
        }
        float l = 0, r = 0;
        float master = atomic_load(&deviceMuted) ? 0 : atomic_load(&deviceVolume[0]);
        float leftGain = u->volume * master * atomic_load(&deviceVolume[3]);
        float rightGain = u->volume * master * atomic_load(&deviceVolume[4]);
        unsigned stride = u->fmt.mBytesPerFrame, bytes = u->fmt.mBitsPerChannel / 8;
        for (unsigned i = 0; i < frames; i++) {
            float left = sample(samples + i * stride + bytes * 2, &u->fmt) * leftGain,
                  right = sample(samples + i * stride + bytes * 3, &u->fmt) * rightGain;
            l = fmaxf(l, fabsf(left));
            r = fmaxf(r, fabsf(right));
            if (DSBDirectPCMEnabled()) {
                int8_t out[2];
                if (DSBResample(&resampler, left, right, out)) {
                    memcpy(pcm + 4 + count * 2, out, 2);
                    if (++count == 30) {
                        pcm[0] = 30;
                        DSBSendPacket(DSB_PCM, 0, 0, pcm, 64);
                        count = 0;
                    }
                }
            }
        }
        if (!DSBDirectPCMEnabled()) {
            DSBSendPacket(DSB_LEVEL, fminf(1, l), fminf(1, r), NULL, 0);
        }
        frameTime += frames;
        next += frames / u->fmt.mSampleRate;
        double now = clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW) / 1e9;
        if (now - next > .04) {
            next = now;
        }
        while (atomic_load(&u->running) &&
               (now = clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW) / 1e9) < next) {
            double remain = next - now;
            if (remain > .0005) {
                usleep((remain - .0003) * 1e6);
            }
        }
    }
    if (DSBDirectPCMEnabled()) {
        pcm[0] = 0;
        memset(pcm + 4, 0, 60);
        DSBSendPacket(DSB_PCM, 0, 0, pcm, 64);
    } else {
        DSBSendPacket(DSB_LEVEL, 0, 0, NULL, 0);
    }
    free(buf);
    return NULL;
}
static OSStatus unitStart(AudioUnit unit) {
    Unit *u = getUnit(unit);
    if (!u) {
        return AudioOutputUnitStart(unit);
    }
    if (!u->started) {
        atomic_store(&u->running, true);
        if (pthread_create(&u->thread, NULL, render, u)) {
            atomic_store(&u->running, false);
            return kAudioUnitErr_FailedInitialization;
        }
        u->started = true;
        fprintf(stderr, "DSB: virtual haptic stream started, 4 channels %.0f Hz\n",
                u->fmt.mSampleRate);
    }
    return 0;
}
DSB_INTERPOSE(unitStart, AudioOutputUnitStart);
static OSStatus unitStop(AudioUnit unit) {
    Unit *u = getUnit(unit);
    if (!u) {
        return AudioOutputUnitStop(unit);
    }
    if (u->started) {
        if (pthread_equal(pthread_self(), u->thread)) {
            return kAudioUnitErr_CannotDoInCurrentContext;
        }
        atomic_store(&u->running, false);
        pthread_join(u->thread, NULL);
        u->started = false;
    }
    return 0;
}
DSB_INTERPOSE(unitStop, AudioOutputUnitStop);
static void removeUnit(Unit *unit) {
    pthread_mutex_lock(&unitLock);
    Unit **entry = &units;
    while (*entry && *entry != unit) {
        entry = &(*entry)->next;
    }
    if (*entry) {
        *entry = unit->next;
    }
    pthread_mutex_unlock(&unitLock);
    free(unit);
}
static OSStatus unitDispose(AudioComponentInstance unit) {
    Unit *u = getUnit(unit);
    if (u) {
        OSStatus result = unitStop(unit);
        if (result) {
            return result;
        }
        removeUnit(u);
    }
    return AudioComponentInstanceDispose(unit);
}
DSB_INTERPOSE(unitDispose, AudioComponentInstanceDispose);
static OSStatus unitParam(AudioUnit unit, AudioUnitParameterID p, AudioUnitScope s,
                          AudioUnitElement e, AudioUnitParameterValue v, UInt32 o) {
    Unit *u = getUnit(unit);
    if (u) {
        if (p == kHALOutputParam_Volume) {
            u->volume = fmaxf(0, fminf(1, v));
        }
        return 0;
    }
    return AudioUnitSetParameter(unit, p, s, e, v, o);
}
DSB_INTERPOSE(unitParam, AudioUnitSetParameter);
