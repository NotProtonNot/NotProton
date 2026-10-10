#pragma once
#import <Foundation/Foundation.h>
#import <IOKit/hid/IOHIDManager.h>
#include <pthread.h>
#include <stdatomic.h>
#include "protocol.h"

// Private state shared by the session loop and its output worker.
// Session configuration (hid/dry/pcmMode) is immutable after worker creation.
// pending/lastSent/history/dirty flags are protected by outputLock.
// Counters, shutdown and legacy motor values are atomic across threads.
typedef struct {
    IOHIDDeviceRef hid;
    bool dry, pcmMode;
    pthread_mutex_t outputLock;
    uint8_t pending[47], lastSent[47];
    bool outputDirty, haveLast, legacyDirty;
    NSMutableArray *sentHistory;
    atomic_bool quitting, workerRunning, workerExited, stalled, deviceRemoved;
    atomic_uint reports, errors;
    atomic_ullong writeStartedNS;
    atomic_uchar legacyLeft, legacyRight;
    uint8_t btSequence; // Owned only by the active output worker.
} DSBBrokerState;
extern DSBBrokerState dsb;

// The session loop monitors writes independently of the blocking IOKit call.
bool DSBWriteOutput(const uint8_t *report, unsigned size);
bool DSBOutputWriteTimedOut(void);

// Called on the main run loop before the worker starts; no output is sent.
bool DSBPCMStartInput(void);
bool DSBPCMWorkerIsReady(void);
void *DSBPCMWorker(void *unused);
void DSBPCMNotify(void);
void DSBPCMReceive(const DSBPacket *packet);
// Takes its own lock. Callers must not hold outputLock.
NSDictionary *DSBPCMSnapshot(void);
