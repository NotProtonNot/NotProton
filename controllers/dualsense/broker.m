#import <AppKit/AppKit.h>
#import <GameController/GameController.h>
#import <CoreHaptics/CoreHaptics.h>
#import <IOKit/hid/IOHIDManager.h>
#include <arpa/inet.h>
#include <fcntl.h>
#include <signal.h>
#include <unistd.h>
#include <zlib.h>
#include <pthread.h>
#include <stdatomic.h>
#include <mach/mach.h>
#include <limits.h>
#include <time.h>
#include "BrokerInternal.h"
#include "protocol.h"
#include "Calibration.h"
#include "Controls.h"

// Local per-session service. Only receives packets bearing the launch token.
// --pcm selects the bounded direct PCM transport; default retains Core Haptics.
static CHHapticEngine *engines[2];
static atomic_bool engineRunning[2];
static id<CHHapticPatternPlayer> players[2];
static float lastLevel[2] = {-1, -1};
static CHHapticPattern *silentPattern;
static double playerStart;
static GCDualSenseGamepad *nativePad;
// Optional grace period for interleaved active-trigger and reset commands.
// Off commands are delayed only briefly after an active feedback command.
// A genuine release is applied within resetGrace; effect bytes stay unchanged.
static double resetGrace, lastActive[2], releaseAt[2];
static uint8_t releaseEffect[2][11];
static unsigned suppressedResets[2];
static uint64_t ledCommands, playerCommands;
static uint32_t ledSource;
static uint8_t ledRGB[3], playerLED;
DSBBrokerState dsb = {.outputLock = PTHREAD_MUTEX_INITIALIZER};
static uint64_t writeTimeoutNS(void) {
    return dsb.pcmMode ? 80000000 : 250000000;
}

static bool markWriteTimeout(uint64_t started) {
    uint64_t now = clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW);
    if (!started || now - started <= writeTimeoutNS() ||
        atomic_load(&dsb.writeStartedNS) != started) {
        return false;
    }
    if (!atomic_exchange(&dsb.stalled, true)) {
        atomic_fetch_add(&dsb.errors, 1);
        fprintf(stderr, "HID output timed out after %.1f ms\n", (now - started) / 1e6);
    }
    return true;
}

bool DSBOutputWriteTimedOut(void) {
    return markWriteTimeout(atomic_load(&dsb.writeStartedNS));
}

bool DSBWriteOutput(const uint8_t *report, unsigned size) {
    if (atomic_load(&dsb.stalled)) {
        return false;
    }
    uint64_t started = clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW);
    atomic_store(&dsb.writeStartedNS, started);
    IOReturn result =
        dsb.dry ? kIOReturnSuccess
                : IOHIDDeviceSetReport(dsb.hid, kIOHIDReportTypeOutput, report[0], report, size);
    markWriteTimeout(started);
    atomic_store(&dsb.writeStartedNS, 0);
    atomic_fetch_add(&dsb.reports, 1);
    if (result) {
        atomic_fetch_add(&dsb.errors, 1);
        atomic_store(&dsb.stalled, true);
        fprintf(stderr, "HID output failed: error=0x%x report=0x%02x size=%u\n", result, report[0],
                size);
    }
    return !atomic_load(&dsb.stalled);
}

static void stopSignal(int s) {
    dsb.quitting = 1;
}
// Read readiness wakes the run loop immediately; the main loop drains and
// authenticates datagrams before rearming this source.
static void socketReady(CFFileDescriptorRef descriptor, CFOptionFlags flags, void *context) {}
static void queueOutput(const uint8_t *usb) {
    const uint8_t *src = usb + 1;
    pthread_mutex_lock(&dsb.outputLock);
    // Merge independent valid fields, optionally defer transient trigger resets.
    double now = CFAbsoluteTimeGetCurrent();
    for (int side = 0; side < 2; side++) {
        unsigned bit = 4u << side, offset = 10 + side * 11;
        if (!(src[0] & bit)) {
            continue;
        }
        const uint8_t *effect = src + offset;
        if (effect[0] == 0x21) {
            lastActive[side] = now;
            releaseAt[side] = 0;
        } else if (resetGrace > 0 && (effect[0] == 5 || effect[0] == 0) &&
                   dsb.pending[offset] == 0x21 && now - lastActive[side] < resetGrace) {
            releaseAt[side] = lastActive[side] + resetGrace;
            memcpy(releaseEffect[side], effect, 11);
            suppressedResets[side]++;
            continue;
        } else {
            releaseAt[side] = 0;
        }
        dsb.pending[0] |= bit;
        memcpy(dsb.pending + offset, effect, 11);
    }
    if (src[1] & 4) {
        dsb.pending[1] |= 4;
        memcpy(dsb.pending + 44, src + 44, 3);
    }
    if (src[1] & 0x10) {
        dsb.pending[1] |= 0x10;
        dsb.pending[43] = src[43];
    }
    if (src[1] & 1) {
        dsb.pending[1] |= 1;
        dsb.pending[8] = src[8];
    }
    dsb.outputDirty = dsb.pending[0] || dsb.pending[1];
    pthread_mutex_unlock(&dsb.outputLock);
    if (dsb.pcmMode) {
        DSBPCMNotify();
    }
}
static void *outputWorker(void *unused) {
    @autoreleasepool {
        while (atomic_load(&dsb.workerRunning)) {
            @autoreleasepool {
                uint8_t payload[47], snapshot[47];
                bool changed = false;
                pthread_mutex_lock(&dsb.outputLock);
                if (dsb.outputDirty) {
                    memcpy(snapshot, dsb.pending, 47);
                    dsb.outputDirty = false;
                    changed = DSBControlDelta(snapshot, dsb.lastSent, dsb.haveLast, payload);
                }
                pthread_mutex_unlock(&dsb.outputLock);
                if (changed && !atomic_load(&dsb.stalled)) {
                    uint8_t b[78] = {0x31};
                    b[1] = (dsb.btSequence++ & 15) << 4;
                    b[2] = 0x10;
                    memcpy(b + 3, payload, 47);
                    uint8_t seed = 0xa2;
                    uLong crc = crc32(0, &seed, 1);
                    crc = crc32(crc, b, 74);
                    for (int i = 0; i < 4; i++) {
                        b[74 + i] = crc >> (8 * i);
                    }
                    if (!DSBWriteOutput(b, sizeof(b))) {
                        break;
                    }
                    pthread_mutex_lock(&dsb.outputLock);
                    memcpy(dsb.lastSent, snapshot, 47);
                    dsb.haveLast = true;
                    NSMutableArray *r2 = [NSMutableArray array];
                    for (int i = 10; i < 21; i++) {
                        [r2 addObject:@(payload[i])];
                    }
                    [dsb.sentHistory addObject:@{
                        @"at" : @([[NSDate date] timeIntervalSince1970]),
                        @"r2" : r2
                    }];
                    if (dsb.sentHistory.count > 40) {
                        [dsb.sentHistory removeObjectAtIndex:0];
                    }
                    pthread_mutex_unlock(&dsb.outputLock);
                }
            }
            usleep(16000);
        }
    }
    atomic_store(&dsb.workerExited, true);
    return NULL;
}
static bool setLevel(int ch, float level) {
    level = fmaxf(0, fminf(1, level));
    if (fabsf(lastLevel[ch] - level) < .001) {
        return true;
    }
    if (dsb.dry) {
        lastLevel[ch] = level;
        return true;
    }
    if (!atomic_load(&engineRunning[ch])) {
        return level == 0;
    }
    NSError *error = nil;
    CHHapticDynamicParameter *p = [[CHHapticDynamicParameter alloc]
        initWithParameterID:CHHapticDynamicParameterIDHapticIntensityControl
                      value:level
               relativeTime:0];
    @try {
        if (![players[ch] sendParameters:@[ p ] atTime:CHHapticTimeImmediate error:&error]) {
            fprintf(stderr, "Core Haptics update failed: %s\n", error.description.UTF8String);
            return false;
        }
    } @catch (NSException *exception) {
        atomic_store(&engineRunning[ch], false);
        fprintf(stderr, "Core Haptics became unavailable: %s\n", exception.reason.UTF8String);
        return false;
    }
    lastLevel[ch] = level;
    return true;
}
static bool prepare(GCController *pad) {
    NSArray *localities = @[ GCHapticsLocalityLeftHandle, GCHapticsLocalityRightHandle ];
    for (int i = 0; i < 2; i++) {
        engines[i] = [pad.haptics createEngineWithLocality:localities[i]];
        if (!engines[i]) {
            fprintf(stderr, "No haptic engine locality=%s supported=%s\n",
                    [localities[i] UTF8String],
                    pad.haptics.supportedLocalities.description.UTF8String);
            return false;
        }
        engines[i].autoShutdownEnabled = NO;
        engines[i].stoppedHandler = ^(CHHapticEngineStoppedReason reason) {
          atomic_store(&engineRunning[i], false);
          fprintf(stderr, "Core Haptics stopped: %ld\n", (long)reason);
          dsb.quitting = 1;
        };
        engines[i].resetHandler = ^{
          atomic_store(&engineRunning[i], false);
          fprintf(stderr, "Core Haptics reset; session must restart\n");
          dsb.quitting = 1;
        };
        NSError *e = nil;
        if (![engines[i] startAndReturnError:&e]) {
            fprintf(stderr, "Engine start ch=%d error=%s\n", i, e.description.UTF8String);
            return false;
        }
        atomic_store(&engineRunning[i], true);
        CHHapticEventParameter *one = [[CHHapticEventParameter alloc]
            initWithParameterID:CHHapticEventParameterIDHapticIntensity
                          value:1];
        CHHapticEvent *event =
            [[CHHapticEvent alloc] initWithEventType:CHHapticEventTypeHapticContinuous
                                          parameters:@[ one ]
                                        relativeTime:0
                                            duration:30];
        CHHapticDynamicParameter *zero = [[CHHapticDynamicParameter alloc]
            initWithParameterID:CHHapticDynamicParameterIDHapticIntensityControl
                          value:0
                   relativeTime:0];
        CHHapticPattern *pattern = [[CHHapticPattern alloc] initWithEvents:@[ event ]
                                                                parameters:@[ zero ]
                                                                     error:&e];
        silentPattern = pattern;
        players[i] = [engines[i] createPlayerWithPattern:pattern error:&e];
        if (!players[i]) {
            fprintf(stderr, "Player create ch=%d error=%s\n", i, e.description.UTF8String);
            return false;
        }

        if (![players[i] startAtTime:CHHapticTimeImmediate error:&e]) {
            fprintf(stderr, "Player start ch=%d error=%s\n", i, e.description.UTF8String);
            return false;
        }
        lastLevel[i] = 0;
    }
    playerStart = CFAbsoluteTimeGetCurrent();
    return true;
}
static bool renewPlayers(void) {
    if (dsb.dry || CFAbsoluteTimeGetCurrent() - playerStart < 25) {
        return true;
    }
    for (int i = 0; i < 2; i++) {
        NSError *e = nil;
        id<CHHapticPatternPlayer> next = [engines[i] createPlayerWithPattern:silentPattern
                                                                       error:&e];
        if (!next) {
            return false;
        }
        [players[i] stopAtTime:CHHapticTimeImmediate error:NULL];
        players[i] = next;
        if (![next startAtTime:CHHapticTimeImmediate error:&e]) {
            return false;
        }
        lastLevel[i] = -1;
    }
    playerStart = CFAbsoluteTimeGetCurrent();
    return true;
}
typedef struct {
    uint32_t pid, sequence;
    double lastLevelAt, lastRumbleAt, lastPacketAt;
    float levelLeft, levelRight, rumbleLeft, rumbleRight;
    bool initialized;
} Source;
static Source sources[64];

// Source state and metrics are owned by the session's main run loop.
typedef struct {
    uint64_t accepted, dropped, levels, outputs;
    float left, right, peakLeft, peakRight;
} SessionMetrics;

static bool validPayload(const DSBPacket *packet) {
    switch (packet->kind) {
    case DSB_LEVEL:
        return true;
    case DSB_PCM:
        return dsb.pcmMode && (packet->report[0] == 0 || packet->report[0] == 30);
    case DSB_OUTPUT:
        return packet->report[0] == 2;
    default:
        return false;
    }
}

static void receivePackets(int fd, const uint8_t token[16], double now, SessionMetrics *metrics) {
    for (int j = 0; j < 1024; j++) {
        DSBPacket p;
        uint8_t datagram[sizeof(p) + 1];
        ssize_t n = recv(fd, datagram, sizeof(datagram), 0);
        if (n < 0) {
            break;
        }
        memcpy(&p, datagram, MIN((size_t)n, sizeof(p)));
        if (n != sizeof(p) || p.magic != DSB_MAGIC || memcmp(p.token, token, 16) ||
            !isfinite(p.timestamp) || fabs(now - p.timestamp) > .25 || !isfinite(p.left) ||
            !isfinite(p.right) || !p.pid || !validPayload(&p)) {
            metrics->dropped++;
            continue;
        }
        Source *s = NULL;
        for (int k = 0; k < 64; k++) {
            if (sources[k].pid == p.pid) {
                s = sources + k;
                break;
            }
        }
        if (!s) {
            for (int k = 0; k < 64; k++) {
                if (!sources[k].pid || now - sources[k].lastPacketAt > 2) {
                    s = sources + k;
                    memset(s, 0, sizeof(*s));
                    s->pid = p.pid;
                    break;
                }
            }
        }
        if (!s || (s->initialized && (int32_t)(p.sequence - s->sequence) <= 0)) {
            metrics->dropped++;
            continue;
        }
        s->initialized = true;
        s->lastPacketAt = now;
        s->sequence = p.sequence;
        if (p.kind == DSB_LEVEL) {
            s->lastLevelAt = now;
            s->levelLeft = fmaxf(0, fminf(1, p.left));
            s->levelRight = fmaxf(0, fminf(1, p.right));
            metrics->levels++;
        } else if (dsb.pcmMode && p.kind == DSB_PCM && (p.report[0] == 0 || p.report[0] == 30)) {
            DSBPCMReceive(&p);
            s->lastLevelAt = now;
            metrics->levels++;
        } else if (p.kind == DSB_OUTPUT && p.report[0] == 2) {
            const uint8_t *b = p.report + 1;
            if (b[1] & 4) {
                if (!ledCommands || memcmp(ledRGB, b + 44, 3) || ledSource != p.pid) {
                    fprintf(stderr, "LED source=%u rgb=%u,%u,%u flags=%02x/%02x\n", p.pid, b[44],
                            b[45], b[46], b[0], b[1]);
                }
                ledCommands++;
                ledSource = p.pid;
                memcpy(ledRGB, b + 44, 3);
            }
            if (b[1] & 16) {
                if (!playerCommands || playerLED != b[43]) {
                    fprintf(stderr, "Player LED source=%u value=%02x flags=%02x/%02x\n", p.pid,
                            b[43], b[0], b[1]);
                }
                playerCommands++;
                playerLED = b[43];
            }
            queueOutput(p.report);
            metrics->outputs++;
            if ((b[0] & 3) || (b[38] & 4)) {
                s->lastRumbleAt = now;
                s->rumbleLeft = b[3] / 255.f;
                s->rumbleRight = b[2] / 255.f;
            }
            // LED/trigger-only transactions leave the last rumble intact.
        } else {
            metrics->dropped++;
            continue;
        }
        metrics->accepted++;
    }
}

static bool updateEffects(double now, float pcmGain, SessionMetrics *metrics) {
    pthread_mutex_lock(&dsb.outputLock);
    for (int side = 0; side < 2; side++) {
        if (releaseAt[side] && now >= releaseAt[side]) {
            dsb.pending[0] |= 4u << side;
            memcpy(dsb.pending + 10 + side * 11, releaseEffect[side], 11);
            releaseAt[side] = 0;
            dsb.outputDirty = true;
        }
    }
    pthread_mutex_unlock(&dsb.outputLock);
    float l = 0, r = 0;
    for (int i = 0; i < 64; i++) {
        Source *s = sources + i;
        if (now - s->lastLevelAt < .15) {
            l = fmaxf(l, DSBCalibratedPCM(s->levelLeft, pcmGain));
            r = fmaxf(r, DSBCalibratedPCM(s->levelRight, pcmGain));
        }
        if (now - s->lastRumbleAt < .5) {
            l = fmaxf(l, s->rumbleLeft);
            r = fmaxf(r, s->rumbleRight);
        }
    }
    if (dsb.pcmMode) {
        float a = 0, b = 0;
        for (int i = 0; i < 64; i++) {
            if (now - sources[i].lastRumbleAt < .5) {
                a = fmaxf(a, sources[i].rumbleLeft);
                b = fmaxf(b, sources[i].rumbleRight);
            }
        }
        uint8_t left = (uint8_t)lrintf(a * 255), right = (uint8_t)lrintf(b * 255);
        pthread_mutex_lock(&dsb.outputLock);
        if (left != dsb.legacyLeft || right != dsb.legacyRight) {
            dsb.legacyLeft = left;
            dsb.legacyRight = right;
            dsb.legacyDirty = true;
        }
        pthread_mutex_unlock(&dsb.outputLock);
    }
    if (dsb.pcmMode) {
        DSBPCMNotify();
    }
    metrics->peakLeft = fmaxf(metrics->peakLeft, l);
    metrics->peakRight = fmaxf(metrics->peakRight, r);
    if (!dsb.pcmMode) {
        if (!renewPlayers()) {
            return false;
        }
        if (!setLevel(0, l) || !setLevel(1, r)) {
            return false;
        }
    }

    metrics->left = l;
    metrics->right = r;
    return true;
}

static void writeStatus(NSString *status, unsigned port, float pcmGain,
                        const SessionMetrics *metrics) {
    NSDictionary *pcmStats = DSBPCMSnapshot();
    pthread_mutex_lock(&dsb.outputLock);
    NSMutableArray *r2 = [NSMutableArray array];
    for (int i = 10; i < 21; i++) {
        [r2 addObject:@(dsb.pending[i])];
    }
    NSDictionary *triggers = @{
        @"resetGraceMs" : @(resetGrace * 1000),
        @"suppressedR2Resets" : @(suppressedResets[0]),
        @"r2" : r2,
        @"sentHistory" : [dsb.sentHistory copy],
        @"physicalR2Mode" : @(dsb.pcmMode ? -1 : nativePad.rightTrigger.mode),
        @"physicalR2Status" : @(dsb.pcmMode ? -1 : nativePad.rightTrigger.status)
    };
    pthread_mutex_unlock(&dsb.outputLock);
    NSDictionary *obj = @{
        @"state" : @"running",
        @"led" : @{
            @"commands" : @(ledCommands),
            @"sourcePid" : @(ledSource),
            @"rgb" : @[ @(ledRGB[0]), @(ledRGB[1]), @(ledRGB[2]) ],
            @"playerCommands" : @(playerCommands),
            @"player" : @(playerLED)
        },
        @"pcm" : pcmStats,
        @"triggers" : triggers,
        @"pid" : @(getpid()),
        @"port" : @(port),
        @"accepted" : @(metrics->accepted),
        @"dropped" : @(metrics->dropped),
        @"pcmBlocks" : @(metrics->levels),
        @"pcmGain" : @(pcmGain),
        @"outputCommands" : @(metrics->outputs),
        @"hidReports" : @(atomic_load(&dsb.reports)),
        @"hidErrors" : @(atomic_load(&dsb.errors)),
        @"hidStalled" : @(atomic_load(&dsb.stalled)),
        @"left" : @(metrics->left),
        @"right" : @(metrics->right),
        @"peakLeft" : @(metrics->peakLeft),
        @"peakRight" : @(metrics->peakRight),
        @"updated" : @([[NSDate date] timeIntervalSince1970])
    };
    [[NSJSONSerialization dataWithJSONObject:obj options:NSJSONWritingPrettyPrinted
                                       error:NULL] writeToFile:status atomically:YES];
}

typedef struct {
    NSString *status, *secret;
    pid_t parent;
    double seconds;
    bool probe;
    unsigned requestedPort;
} BrokerOptions;

static bool parseArguments(int argc, char **argv, BrokerOptions *options) {
    for (int i = 1; i < argc; i++) {
        if (!strcmp(argv[i], "--probe")) {
            options->probe = true;
        } else if (!strcmp(argv[i], "--pcm")) {
            dsb.pcmMode = true;
        } else if (!strcmp(argv[i], "--trigger-reset-grace-ms") && i + 1 < argc) {
            char *end = NULL;
            long ms = strtol(argv[++i], &end, 10);
            if (end == argv[i] || *end || ms < 0 || ms > 100) {
                return false;
            }
            resetGrace = ms / 1000.;
        } else if (!strcmp(argv[i], "--dry-run")) {
            dsb.dry = true;
        } else if (!strcmp(argv[i], "--token") && i + 1 < argc) {
            options->secret = @(argv[++i]);
        } else if (!strcmp(argv[i], "--status") && i + 1 < argc) {
            options->status = @(argv[++i]);
        } else if (!strcmp(argv[i], "--parent") && i + 1 < argc) {
            char *end = NULL;
            long parent = strtol(argv[++i], &end, 10);
            if (end == argv[i] || *end || parent <= 0 || parent > INT_MAX) {
                return false;
            }
            options->parent = (pid_t)parent;
        } else if (!strcmp(argv[i], "--seconds") && i + 1 < argc) {
            char *end = NULL;
            options->seconds = strtod(argv[++i], &end);
            if (end == argv[i] || *end || !isfinite(options->seconds) || options->seconds <= 0) {
                return false;
            }
        } else if (!strcmp(argv[i], "--port") && i + 1 < argc) {
            char *end = NULL;
            long p = strtol(argv[++i], &end, 10);
            if (end == argv[i] || *end || p < 1024 || p > 65535) {
                return false;
            }
            options->requestedPort = (unsigned)p;
        } else {
            return false;
        }
    }
    return true;
}

static int openController(bool probe, IOHIDManagerRef *owner) {
    if (dsb.dry) {
        if (probe) {
            puts("{\"bluetooth\":0,\"usb\":0,\"eligible\":false}");
        }
        return 0;
    }
    IOHIDManagerRef manager = NULL;
    unsigned bt = 0, usb = 0;
    manager = IOHIDManagerCreate(NULL, dsb.pcmMode ? kIOHIDManagerOptionIndependentDevices : 0);
    *owner = manager;
    if (!manager) {
        return 4;
    }
    IOHIDManagerSetDeviceMatching(
        manager, (__bridge CFDictionaryRef)
                     @{@kIOHIDVendorIDKey : @0x54c,
                       @kIOHIDProductIDKey : @0xce6});
    if (IOHIDManagerOpen(manager, 0)) {
        return 4;
    }
    CFSetRef devices = IOHIDManagerCopyDevices(manager);
    if (devices) {
        for (id obj in (__bridge NSSet *)devices) {
            IOHIDDeviceRef d = (__bridge IOHIDDeviceRef)obj;
            NSString *transport =
                (__bridge NSString *)IOHIDDeviceGetProperty(d, CFSTR(kIOHIDTransportKey));
            if ([transport isEqualToString:@"USB"]) {
                usb++;
            } else if ([transport hasPrefix:@"Bluetooth"]) {
                bt++;
                dsb.hid = d;
            }
        }
        if (dsb.hid) {
            CFRetain(dsb.hid);
        }
        CFRelease(devices);
    }
    if (probe) {
        printf("{\"bluetooth\":%u,\"usb\":%u,\"eligible\":%s}\n", bt, usb,
               bt == 1 && !usb ? "true" : "false");
        return 0;
    }
    if (bt != 1 || usb) {
        fprintf(stderr, "Requires exactly one Bluetooth DualSense and no USB DualSense\n");
        return 3;
    }
    if (IOHIDDeviceOpen(dsb.hid, 0)) {
        return 4;
    }
    [NSApplication sharedApplication];
    [NSApp setActivationPolicy:NSApplicationActivationPolicyProhibited];
    GCController *pad = nil;
    // The raw PCM transport owns HID output. Do not also create a native
    // controller/haptic client: its initialization and teardown can write
    // competing mode/LED commands. Core Haptics is an explicit fallback only.
    if (!dsb.pcmMode) {
        GCController.shouldMonitorBackgroundEvents = YES;
        for (int i = 0; i < 80 && !pad; i++) {
            for (GCController *c in GCController.controllers) {
                if ([c.extendedGamepad isKindOfClass:GCDualSenseGamepad.class]) {
                    pad = c;
                    break;
                }
            }
            if (!pad) {
                [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:.05]];
            }
        }
        nativePad = (GCDualSenseGamepad *)pad.extendedGamepad;
        if (!pad || !prepare(pad)) {
            fprintf(stderr, "DualSense Core Haptics initialization failed\n");
            return 5;
        }
    }
    if (dsb.pcmMode) {
        if (!DSBPCMStartInput()) {
            return 8;
        }
    }
    if (!dsb.pcmMode) {
        [[NSNotificationCenter defaultCenter]
            addObserverForName:GCControllerDidDisconnectNotification
                        object:pad
                         queue:NSOperationQueue.mainQueue
                    usingBlock:^(NSNotification *n) {
                      fprintf(stderr, "Core Haptics controller disconnected\n");
                      dsb.quitting = 1;
                    }];
    }

    return 0;
}

// Scope cleanup covers probe and every startup failure before the event loop.
// A stalled driver call is the exception: the process exits without touching
// that IOKit connection again, since closing it could block on the same driver.
static void releaseControllerManager(IOHIDManagerRef *manager) {
    if (*manager && !atomic_load(&dsb.stalled)) {
        IOHIDManagerClose(*manager, 0);
        CFRelease(*manager);
    }
}

int main(int argc, char **argv) {
    @autoreleasepool {
        id activity = [[NSProcessInfo processInfo]
            beginActivityWithOptions:NSActivityUserInitiated | NSActivityLatencyCritical
                              reason:@"DualSense real-time haptic transport"];
        setbuf(stdout, NULL);
        dsb.sentHistory = [NSMutableArray array];
        signal(SIGTERM, stopSignal);
        signal(SIGINT, stopSignal);
        BrokerOptions options = {0};
        uint8_t token[16] = {0};
        if (!parseArguments(argc, argv, &options) ||
            (!options.probe && !DSBParseToken(options.secret.UTF8String, token))) {
            return 64;
        }
        NSString *status = options.status;
        IOHIDManagerRef manager __attribute__((cleanup(releaseControllerManager))) = NULL;
        int controllerResult = openController(options.probe, &manager);
        if (controllerResult || options.probe) {
            if (dsb.hid) {
                CFRelease(dsb.hid);
                dsb.hid = NULL;
            }
            return controllerResult;
        }
        if (dsb.pcmMode) {
            task_category_policy_data_t policy = {TASK_FOREGROUND_APPLICATION};
            kern_return_t result =
                task_policy_set(mach_task_self(), TASK_CATEGORY_POLICY, (task_policy_t)&policy,
                                TASK_CATEGORY_POLICY_COUNT);
            fprintf(stderr, "PCM task scheduling role result=%d\n", result);
        }
        int fd = socket(AF_INET, SOCK_DGRAM, 0);
        if (fd < 0) {
            return 6;
        }
        struct sockaddr_in addr = {.sin_len = sizeof(addr),
                                   .sin_family = AF_INET,
                                   .sin_port = htons(options.requestedPort),
                                   .sin_addr.s_addr = htonl(INADDR_LOOPBACK)};
        if (bind(fd, (void *)&addr, sizeof(addr))) {
            return 6;
        }
        socklen_t len = sizeof(addr);
        if (getsockname(fd, (void *)&addr, &len) || fcntl(fd, F_SETFL, O_NONBLOCK) < 0) {
            return 6;
        }
        unsigned port = ntohs(addr.sin_port);
        CFFileDescriptorRef socketEvents = NULL;
        CFRunLoopSourceRef socketSource = NULL;
        if (dsb.pcmMode) {
            socketEvents = CFFileDescriptorCreate(NULL, fd, false, socketReady, NULL);
            if (!socketEvents) {
                fprintf(stderr, "PCM socket event source unavailable\n");
                return 9;
            }
            socketSource = CFFileDescriptorCreateRunLoopSource(NULL, socketEvents, 0);
            if (!socketSource) {
                fprintf(stderr, "PCM socket run loop source unavailable\n");
                return 9;
            }
            CFRunLoopAddSource(CFRunLoopGetMain(), socketSource, kCFRunLoopDefaultMode);
        }
        pthread_t worker;
        atomic_store(&dsb.workerRunning, true);
        if (pthread_create(&worker, NULL, dsb.pcmMode ? DSBPCMWorker : outputWorker, NULL)) {
            fprintf(stderr, "Controller writer thread unavailable\n");
            return 9;
        }
        if (dsb.pcmMode) {
            double deadline = CFAbsoluteTimeGetCurrent() + 5;
            while (!DSBPCMWorkerIsReady() && CFAbsoluteTimeGetCurrent() < deadline) {
                CFRunLoopRunInMode(kCFRunLoopDefaultMode, .002, true);
            }
            if (!DSBPCMWorkerIsReady() || atomic_load(&dsb.stalled)) {
                fprintf(stderr, "PCM writer did not initialize\n");
                atomic_store(&dsb.workerRunning, false);
                atomic_store(&dsb.stalled, true);
                return 9;
            }
        }
        printf("{\"ready\":true,\"port\":%u,\"pid\":%d}\n", port, getpid());
        NSString *calibrationPath = [NSHomeDirectory()
            stringByAppendingPathComponent:
                @"Library/Application Support/notproton/controllers/dualsense/calibration.json"];
        float pcmGain = 1;
        double nextCalibration = 0;
        double start = CFAbsoluteTimeGetCurrent(), nextStatus = 0;
        SessionMetrics metrics = {0};
        while (!dsb.quitting &&
               (!options.seconds || CFAbsoluteTimeGetCurrent() - start < options.seconds)) {
            @autoreleasepool {
                double now = CFAbsoluteTimeGetCurrent();
                if (options.parent && kill(options.parent, 0) && errno == ESRCH) {
                    break;
                }
                if (DSBOutputWriteTimedOut() || atomic_load(&dsb.stalled)) {
                    break;
                }
                if (now >= nextCalibration) {
                    pcmGain = DSBPCMGain(calibrationPath);
                    nextCalibration = now + 1;
                }
                receivePackets(fd, token, now, &metrics);
                if (!updateEffects(now, pcmGain, &metrics)) {
                    break;
                }
                if (status && now >= nextStatus) {
                    writeStatus(status, port, pcmGain, &metrics);
                    nextStatus = now + 1;
                }
                if (dsb.pcmMode) {
                    CFFileDescriptorEnableCallBacks(socketEvents, kCFFileDescriptorReadCallBack);
                    CFRunLoopRunInMode(kCFRunLoopDefaultMode, .002, true);
                } else {
                    [[NSRunLoop currentRunLoop]
                        runUntilDate:[NSDate dateWithTimeIntervalSinceNow:.01]];
                }
            }
        }
        if (!dsb.pcmMode) {
            setLevel(0, 0);
            setLevel(1, 0);
        }
        // Release triggers only if this session touched them. Leave unrelated Steam output alone.
        resetGrace = 0; // Cleanup must never defer release.
        if (!atomic_load(&dsb.stalled) && !atomic_load(&dsb.deviceRemoved) &&
            (dsb.pending[0] & 12)) {
            uint8_t reset[64];
            DSBTriggerRelease(dsb.pending[0], reset);
            queueOutput(reset);
            double deadline = CFAbsoluteTimeGetCurrent() + .25;
            while (!atomic_load(&dsb.stalled) && CFAbsoluteTimeGetCurrent() < deadline) {
                uint8_t unsent[47];
                pthread_mutex_lock(&dsb.outputLock);
                bool pending = DSBControlDelta(dsb.pending, dsb.lastSent, dsb.haveLast, unsent);
                pthread_mutex_unlock(&dsb.outputLock);
                if (!pending || DSBOutputWriteTimedOut()) {
                    break;
                }
                CFRunLoopRunInMode(kCFRunLoopDefaultMode, .002, true);
            }
        }
        atomic_store(&dsb.workerRunning, false);
        while (!atomic_load(&dsb.workerExited) && !atomic_load(&dsb.stalled)) {
            DSBOutputWriteTimedOut();
            CFRunLoopRunInMode(kCFRunLoopDefaultMode, .002, true);
        }
        if (atomic_load(&dsb.workerExited)) {
            pthread_join(worker, NULL);
        }
        for (int i = 0; i < 2; i++) {
            // Disconnect can stop the engine before cleanup. PatternPlayer stop then
            // raises an ObjC exception rather than returning NSError on macOS 27.
            @try {
                if (atomic_load(&engineRunning[i])) {
                    [players[i] stopAtTime:CHHapticTimeImmediate error:NULL];
                }
                [engines[i] stopWithCompletionHandler:nil];
            } @catch (NSException *exception) {
                fprintf(stderr, "Core Haptics already stopped during cleanup: %s\n",
                        exception.reason.UTF8String);
            }
            atomic_store(&engineRunning[i], false);
        }
        if (dsb.hid && !atomic_load(&dsb.stalled)) {
            if (dsb.pcmMode) {
                IOHIDDeviceUnscheduleFromRunLoop(dsb.hid, CFRunLoopGetMain(),
                                                 kCFRunLoopCommonModes);
            }
            IOHIDDeviceClose(dsb.hid, 0);
            CFRelease(dsb.hid);
        }
        [[NSProcessInfo processInfo] endActivity:activity];
        if (status) {
            writeStatus(status, port, pcmGain, &metrics);
            NSData *data = [NSData dataWithContentsOfFile:status];
            NSMutableDictionary *final =
                data ? [[NSJSONSerialization JSONObjectWithData:data
                                                        options:NSJSONReadingMutableContainers
                                                          error:NULL] mutableCopy]
                     : [NSMutableDictionary dictionary];
            if (!final) {
                final = [NSMutableDictionary dictionary];
            }
            final[@"state"] = atomic_load(&dsb.deviceRemoved) ? @"disconnected"
                              : atomic_load(&dsb.stalled)     ? @"output-stopped"
                                                              : @"stopped";
            final[@"updated"] = @([[NSDate date] timeIntervalSince1970]);
            [[NSJSONSerialization dataWithJSONObject:final
                                             options:NSJSONWritingPrettyPrinted
                                               error:NULL] writeToFile:status atomically:YES];
        }
        if (socketEvents) {
            CFFileDescriptorInvalidate(socketEvents);
            CFRunLoopRemoveSource(CFRunLoopGetMain(), socketSource, kCFRunLoopDefaultMode);
            CFRelease(socketSource);
            CFRelease(socketEvents);
        }
        close(fd);
        fprintf(stderr, "Stopped: packets=%llu PCM=%llu output=%llu HID=%u errors=%u\n",
                metrics.accepted, metrics.levels, metrics.outputs, atomic_load(&dsb.reports),
                atomic_load(&dsb.errors));
        return atomic_load(&dsb.deviceRemoved) ? 10 : atomic_load(&dsb.stalled) ? 11 : 0;
    }
}
