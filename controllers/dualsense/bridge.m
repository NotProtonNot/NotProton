// Present the Bluetooth DualSense through Wine's USB HID interface.
#import <Foundation/Foundation.h>
#import <IOKit/hid/IOHIDManager.h>
#include <arpa/inet.h>
#include <sys/socket.h>
#include <pthread.h>
#include <stdatomic.h>
#include <unistd.h>
#include <math.h>
#include "protocol.h"
#include "descriptor.h"
#include "Bridge.h"
static bool enabled, raw, pcmMode;
static int sock = -1;
static uint8_t token[16];
static uint32_t sequence;
static pthread_mutex_t senderLock = PTHREAD_MUTEX_INITIALIZER;
static struct sockaddr_in dest;
static CFDataRef descriptor;
static CFNumberRef usbInput, usbOutput;
static bool bluetooth(IOHIDDeviceRef d) {
    if (!enabled) {
        return false;
    }
    int vid = 0, pid = 0;
    CFTypeRef v = IOHIDDeviceGetProperty(d, CFSTR(kIOHIDVendorIDKey));
    if (v && CFGetTypeID(v) == CFNumberGetTypeID()) {
        CFNumberGetValue(v, kCFNumberIntType, &vid);
    }
    v = IOHIDDeviceGetProperty(d, CFSTR(kIOHIDProductIDKey));
    if (v && CFGetTypeID(v) == CFNumberGetTypeID()) {
        CFNumberGetValue(v, kCFNumberIntType, &pid);
    }
    CFStringRef tr = IOHIDDeviceGetProperty(d, CFSTR(kIOHIDTransportKey));
    return vid == 0x54c && pid == 0xce6 && tr && CFGetTypeID(tr) == CFStringGetTypeID() &&
           CFStringHasPrefix(tr, CFSTR("Bluetooth"));
}
void DSBSendPacket(uint32_t kind, float left, float right, const uint8_t *report, size_t size) {
    if (!enabled || sock < 0) {
        return;
    }
    DSBPacket p = {.magic = DSB_MAGIC,
                   .kind = kind,
                   .pid = getpid(),
                   .timestamp = CFAbsoluteTimeGetCurrent(),
                   .left = left,
                   .right = right};
    memcpy(p.token, token, 16);
    if (report) {
        memcpy(p.report, report, MIN(size, 64));
    }
    // Audio and HID callbacks may run on different threads. Assign the sequence
    // at the send boundary so a newer datagram cannot overtake an older control.
    pthread_mutex_lock(&senderLock);
    p.sequence = sequence++;
    ssize_t sent = sendto(sock, &p, sizeof(p), MSG_DONTWAIT, (void *)&dest, sizeof(dest));
    int sendError = sent < 0 ? errno : 0;
    pthread_mutex_unlock(&senderLock);
    static atomic_uint logged;
    unsigned bit = 1u << kind;
    if (!(atomic_fetch_or(&logged, bit) & bit)) {
        fprintf(stderr, "DSB: first packet pid=%d kind=%u port=%u bytes=%ld errno=%d\n", getpid(),
                kind, ntohs(dest.sin_port), (long)sent, sendError);
    }
}
__attribute__((constructor)) static void initialize(void) {
    const char *port = getenv("DSB_PORT"), *secret = getenv("DSB_TOKEN"), *mode = getenv("DSB_RAW");
    if (!port || !secret || strlen(secret) != 32) {
        return;
    }
    char *end = NULL;
    long n = strtol(port, &end, 10);
    if (end == port || *end || n < 1024 || n > 65535 || !DSBParseToken(secret, token)) {
        return;
    }
    sock = socket(AF_INET, SOCK_DGRAM, 0);
    if (sock < 0) {
        return;
    }
    dest = (struct sockaddr_in){.sin_len = sizeof(dest),
                                .sin_family = AF_INET,
                                .sin_port = htons(n),
                                .sin_addr.s_addr = htonl(INADDR_LOOPBACK)};
    raw = mode && atoi(mode) == 1;
    const char *pcm = getenv("DSB_PCM");
    pcmMode = (mode && !strcmp(mode, "1:pcm")) || (pcm && !strcmp(pcm, "1"));
    descriptor = CFDataCreate(NULL, usb_descriptor, sizeof(usb_descriptor));
    int a = 78, b = 48;
    usbInput = CFNumberCreate(NULL, kCFNumberIntType, &a);
    usbOutput = CFNumberCreate(NULL, kCFNumberIntType, &b);
    enabled = true;
    fprintf(stderr, "DSB: Bluetooth bridge loaded pid=%d raw=%d pcm=%d port=%u\n", getpid(), raw,
            pcmMode, ntohs(dest.sin_port));
}
static CFTypeRef property(IOHIDDeviceRef d, CFStringRef key) {
    if (raw && bluetooth(d)) {
        if (CFEqual(key, CFSTR(kIOHIDTransportKey))) {
            return CFSTR("USB");
        }
        if (CFEqual(key, CFSTR(kIOHIDManufacturerKey))) {
            return CFSTR("Sony Interactive Entertainment");
        }
        if (CFEqual(key, CFSTR(kIOHIDReportDescriptorKey))) {
            return descriptor;
        }
        if (CFEqual(key, CFSTR(kIOHIDMaxInputReportSizeKey))) {
            return usbInput;
        }
        if (CFEqual(key, CFSTR(kIOHIDMaxOutputReportSizeKey))) {
            return usbOutput;
        }
    }
    return IOHIDDeviceGetProperty(d, key);
}
DSB_INTERPOSE(property, IOHIDDeviceGetProperty);
typedef struct Reader {
    IOHIDDeviceRef d;
    IOHIDReportCallback cb;
    void *ctx;
    uint8_t buffer[1024];
    struct Reader *next;
} Reader;
// Keep callback contexts at stable addresses until process exit, including after
// unregister: IOKit may still have an in-flight callback on the device run loop.
static Reader *readers;
static pthread_mutex_t readersLock = PTHREAD_MUTEX_INITIALIZER;
static void input(void *c, IOReturn result, void *sender, IOHIDReportType type, uint32_t id,
                  uint8_t *bytes, CFIndex length) {
    Reader *r = c;
    pthread_mutex_lock(&readersLock);
    IOHIDReportCallback cb = r->cb;
    void *context = r->ctx;
    pthread_mutex_unlock(&readersLock);
    if (!cb) {
        return;
    }
    if (result == 0 && id == 0x31 && length >= 66) {
        uint8_t usb[64] = {1};
        memcpy(usb + 1, bytes + 2, 63);
        cb(context, result, sender, type, 1, usb, 64);
    } else if (result == 0 && id == 1 && length <= 10) {
        // Feature 05 enables full reports; abbreviated Bluetooth reports lack USB fields.
    } else {
        cb(context, result, sender, type, id, bytes, length);
    }
}
static void registerInput(IOHIDDeviceRef d, uint8_t *buffer, CFIndex len, IOHIDReportCallback cb,
                          void *ctx) {
    if (!raw || !bluetooth(d)) {
        IOHIDDeviceRegisterInputReportCallback(d, buffer, len, cb, ctx);
        return;
    }
    pthread_mutex_lock(&readersLock);
    Reader *r = readers;
    while (r && r->d != d) {
        r = r->next;
    }
    if (!r) {
        r = calloc(1, sizeof(*r));
        if (r) {
            r->d = (IOHIDDeviceRef)CFRetain(d);
            r->next = readers;
            readers = r;
        }
    }
    if (r) {
        r->cb = cb;
        r->ctx = ctx;
    }
    pthread_mutex_unlock(&readersLock);
    if (!r) {
        fprintf(stderr, "DSB: cannot allocate Bluetooth input callback\n");
        return;
    }
    IOHIDDeviceRegisterInputReportCallback(d, r->buffer, sizeof(r->buffer), cb ? input : NULL,
                                           cb ? r : NULL);
    if (cb) {
        uint8_t f[64] = {5};
        CFIndex n = 41;
        IOHIDDeviceGetReport(d, kIOHIDReportTypeFeature, 5, f, &n);
    }
}
DSB_INTERPOSE(registerInput, IOHIDDeviceRegisterInputReportCallback);
// USB clients (including Sony's PC library) disable the physical radio after
// enumeration via feature 08/02. The virtual USB transport uses that radio,
// so acknowledge this exact transport-management request locally. Unknown
// feature reports still pass through unchanged.
static bool virtualRadioDisable(IOHIDReportType type, CFIndex id, const uint8_t *b, CFIndex n) {
    if (type != kIOHIDReportTypeFeature || id != 8 || !b || n != 48 || b[0] != 8 || b[1] != 2) {
        return false;
    }
    for (CFIndex i = 2; i < n; i++) {
        if (b[i]) {
            return false;
        }
    }
    return true;
}
static IOReturn setReport(IOHIDDeviceRef d, IOHIDReportType type, CFIndex id, const uint8_t *b,
                          CFIndex n) {
    if (raw && bluetooth(d) && type == kIOHIDReportTypeFeature) {
        static atomic_uint count;
        if (atomic_fetch_add(&count, 1) < 20) {
            fprintf(stderr, "DSB: feature write pid=%d id=%ld size=%ld head=", getpid(), (long)id,
                    (long)n);
            for (CFIndex i = 0; i < MIN(n, 8); i++) {
                fprintf(stderr, "%02x", b[i]);
            }
            fprintf(stderr, "\n");
        }
    }
    if (raw && bluetooth(d) && virtualRadioDisable(type, id, b, n)) {
        static atomic_uint handled;
        if (atomic_fetch_add(&handled, 1) < 4) {
            fprintf(stderr, "DSB: virtual USB radio-disable acknowledged; Bluetooth retained\n");
        }
        return kIOReturnSuccess;
    }
    if (raw && bluetooth(d) && type == kIOHIDReportTypeOutput && id == 2 && n >= 48 && b[0] == 2) {
        DSBSendPacket(DSB_OUTPUT, 0, 0, b, n);
        return kIOReturnSuccess;
    }
    return IOHIDDeviceSetReport(d, type, id, b, n);
}
DSB_INTERPOSE(setReport, IOHIDDeviceSetReport);
static IOReturn getReport(IOHIDDeviceRef d, IOHIDReportType type, CFIndex id, uint8_t *b,
                          CFIndex *n) {
    IOReturn r = IOHIDDeviceGetReport(d, type, id, b, n);
    if (raw && bluetooth(d)) {
        static atomic_uint count[256];
        if (id >= 0 && id < 256 && atomic_fetch_add(&count[id], 1) < 4) {
            fprintf(stderr, "DSB: HID get type=%d id=%ld size=%ld result=%x\n", type, (long)id,
                    (long)*n, r);
        }
    }
    return r;
}
DSB_INTERPOSE(getReport, IOHIDDeviceGetReport);

bool DSBBridgeEnabled(void) {
    return enabled;
}
bool DSBRawControllerEnabled(void) {
    return raw;
}
bool DSBDirectPCMEnabled(void) {
    return pcmMode;
}
