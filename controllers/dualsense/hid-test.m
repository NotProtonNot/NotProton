#import <Foundation/Foundation.h>
#import <IOKit/hid/IOHIDManager.h>
#include <sys/socket.h>
#include <assert.h>
#include "protocol.h"
#include "Bridge.h"

static IOHIDReportCallback registeredCallback;
static void *registeredContext;
static unsigned physicalWrites, packets, callbacks;
static uint32_t receivedID;
static CFIndex receivedSize;
static uint8_t received[1024];
static DSBPacket sent;

static CFTypeRef mockProperty(IOHIDDeviceRef device, CFStringRef key) {
    return CFDictionaryGetValue((CFDictionaryRef)device, key);
}
static void mockRegister(IOHIDDeviceRef device, uint8_t *buffer, CFIndex size,
                         IOHIDReportCallback callback, void *context) {
    registeredCallback = callback;
    registeredContext = context;
}
static IOReturn mockGetReport(IOHIDDeviceRef device, IOHIDReportType type, CFIndex reportID,
                              uint8_t *report, CFIndex *size) {
    return kIOReturnSuccess;
}
static IOReturn mockSetReport(IOHIDDeviceRef device, IOHIDReportType type, CFIndex reportID,
                              const uint8_t *report, CFIndex size) {
    physicalWrites++;
    return kIOReturnSuccess;
}
static ssize_t mockSend(int socket, const void *bytes, size_t size, int flags,
                        const struct sockaddr *address, socklen_t length) {
    assert(size == sizeof(sent));
    memcpy(&sent, bytes, size);
    packets++;
    return size;
}

#undef DSB_INTERPOSE
#define DSB_INTERPOSE(replacement, original)
#define IOHIDDeviceGetProperty mockProperty
#define IOHIDDeviceRegisterInputReportCallback mockRegister
#define IOHIDDeviceGetReport mockGetReport
#define IOHIDDeviceSetReport mockSetReport
#define sendto mockSend
#include "bridge.m"

static void receiveReport(void *context, IOReturn result, void *sender, IOHIDReportType type,
                          uint32_t reportID, uint8_t *bytes, CFIndex size) {
    assert(context == &callbacks);
    assert(size <= sizeof(received));
    memcpy(received, bytes, size);
    receivedID = reportID;
    receivedSize = size;
    callbacks++;
}

int main(void) {
    setenv("DSB_PORT", "19000", 1);
    setenv("DSB_TOKEN", "1234567890abcdef1234567890abcdef", 1);
    setenv("DSB_RAW", "1", 1);
    initialize();
    assert(DSBBridgeEnabled());
    @autoreleasepool {
        for (unsigned connection = 0; connection < 24; connection++) {
            NSDictionary *info = @{
                @kIOHIDVendorIDKey : @0x54c,
                @kIOHIDProductIDKey : @0xce6,
                @kIOHIDTransportKey : @"Bluetooth"
            };
            IOHIDDeviceRef device = (__bridge IOHIDDeviceRef)[info mutableCopy];
            assert(CFEqual(property(device, CFSTR(kIOHIDTransportKey)), CFSTR("USB")));
            uint8_t buffer[1024], report[78] = {0x31};
            for (unsigned i = 1; i < sizeof(report); i++) {
                report[i] = i;
            }
            registerInput(device, buffer, sizeof(buffer), receiveReport, &callbacks);
            registeredCallback(registeredContext, 0, device, kIOHIDReportTypeInput, 0x31, report,
                               sizeof(report));
            assert(receivedID == 1 && receivedSize == 64 && received[0] == 1);
            assert(!memcmp(received + 1, report + 2, 63));
            unsigned before = callbacks;
            registeredCallback(registeredContext, 0, device, kIOHIDReportTypeInput, 1, report, 10);
            assert(callbacks == before);
            IOHIDReportCallback inflight = registeredCallback;
            void *context = registeredContext;
            registerInput(device, buffer, sizeof(buffer), NULL, NULL);
            inflight(context, 0, device, kIOHIDReportTypeInput, 0x31, report, sizeof(report));
            assert(callbacks == before);

            uint8_t feature[48] = {8, 2};
            unsigned previousWrites = physicalWrites;
            assert(!setReport(device, kIOHIDReportTypeFeature, 8, feature, sizeof(feature)));
            assert(physicalWrites == previousWrites);
            feature[2] = 1;
            assert(!setReport(device, kIOHIDReportTypeFeature, 8, feature, sizeof(feature)));
            assert(physicalWrites == previousWrites + 1);
            uint8_t output[48] = {2, 4};
            assert(!setReport(device, kIOHIDReportTypeOutput, 2, output, sizeof(output)));
            assert(sent.kind == DSB_OUTPUT && !memcmp(sent.report, output, sizeof(output)));
            CFRelease(device);
        }
    }
    assert(packets == 24);
    puts("PASS: HID identity, sensor/button bytes, unregister, reconnects and output routing");
}
