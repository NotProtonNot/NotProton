#import <IOKit/hid/IOHIDManager.h>
#include <stdatomic.h>
#include <assert.h>
#include <pthread.h>
#include <unistd.h>

static atomic_bool blockWrite, writeEntered;
static atomic_uint physicalWrites;
static IOReturn writeResult;
static IOReturn mockSetReport(IOHIDDeviceRef device, IOHIDReportType type, CFIndex reportID,
                              const uint8_t *report, CFIndex size) {
    atomic_fetch_add(&physicalWrites, 1);
    atomic_store(&writeEntered, true);
    while (atomic_load(&blockWrite)) {
        usleep(1000);
    }
    return writeResult;
}

#define IOHIDDeviceSetReport mockSetReport
#define main brokerMain
#include "broker.m"
#undef main
#undef IOHIDDeviceSetReport

static bool writeSucceeded;
static void *writeOnWorker(void *unused) {
    uint8_t report[78] = {0x31};
    writeSucceeded = DSBWriteOutput(report, sizeof(report));
    return NULL;
}

int main(void) {
    uint8_t report[78] = {0x31};
    assert(DSBWriteOutput(report, sizeof(report)));
    assert(dsb.reports == 1 && dsb.errors == 0 && !dsb.writeStartedNS);
    writeResult = kIOReturnError;
    assert(!DSBWriteOutput(report, sizeof(report)));
    assert(dsb.stalled && dsb.errors == 1 && !dsb.writeStartedNS);
    unsigned writes = physicalWrites;
    assert(!DSBWriteOutput(report, sizeof(report)) && physicalWrites == writes);

    for (unsigned pcm = 0; pcm < 2; pcm++) {
        dsb.pcmMode = pcm;
        dsb.stalled = false;
        dsb.errors = 0;
        writeResult = kIOReturnSuccess;
        blockWrite = true;
        writeEntered = false;
        pthread_t worker;
        assert(!pthread_create(&worker, NULL, writeOnWorker, NULL));
        while (!atomic_load(&writeEntered)) {
            usleep(1000);
        }
        assert(!DSBOutputWriteTimedOut());
        double deadline = CFAbsoluteTimeGetCurrent() + 1;
        while (!DSBOutputWriteTimedOut() && CFAbsoluteTimeGetCurrent() < deadline) {
            usleep(1000);
        }
        assert(dsb.stalled && dsb.errors == 1 && dsb.writeStartedNS);
        blockWrite = false;
        pthread_join(worker, NULL);
        assert(!writeSucceeded && !dsb.writeStartedNS && dsb.errors == 1);
    }
    puts("PASS: write errors, blocked-driver watchdog and suppression after failure");
}
