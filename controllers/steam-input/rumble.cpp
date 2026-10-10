// Forward Winebus SDL2 rumble for Steam's virtual gamepads to native Steam Input.
#include <CoreFoundation/CoreFoundation.h>
#include <IOKit/IOKitLib.h>
#include <dlfcn.h>
#include <pthread.h>
#include <atomic>
#include <algorithm>
#include <chrono>
#include <cstdlib>
#include <cstring>
#include <limits>
#include <unistd.h>
#include "SteamSession.h"
#include "VirtualGamepad.h"

#ifndef INTERPOSE
#define INTERPOSE(replacement, original)                                                           \
    __attribute__((used)) static const struct {                                                    \
        const void *a, *b;                                                                         \
    } ip_##original                                                                                \
        __attribute__((section("__DATA,__interpose"))) = {(void *)replacement, (void *)original}
#endif
static_assert(kGamepadCount == STEAM_CONTROLLER_MAX_COUNT);
constexpr double kMappingPollSeconds = 0.020;
constexpr double kSteamRetrySeconds = 2;

// The mutex protects the slot mailbox; the worker alone owns the Steam session.
using Clock = std::chrono::steady_clock;
static double now() {
    return std::chrono::duration<double>(Clock::now().time_since_epoch()).count();
}
static pthread_mutex_t lock = PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t wake = PTHREAD_COND_INITIALIZER;
static pthread_once_t workerOnce = PTHREAD_ONCE_INIT;
static std::atomic<bool> running{true};
static pthread_t workerThread;
static std::atomic<bool> workerStarted{false};
static void *sdlLibrary;
static int (*originalRumble)(void *, uint16_t, uint16_t, uint32_t);
static int (*originalHasRumble)(void *);
static void (*originalClose)(void *);
static JoystickGUID (*getGUID)(void *);
static int32_t (*getInstance)(void *);
static int (*getAttached)(void *);

struct Slot {
    int32_t instance = -1;
    uint16_t left = 0, right = 0;
    double until = 0;
    uint64_t generation = 0;
};
static Slot slots[kGamepadCount];

static bool enabled() {
    const char *mode = getenv("NOTPROTON_STEAM_RUMBLE");
    const char *raw = getenv("NOTPROTON_RAW_CONTROLLERS");
    const char *app = getenv("SteamAppId");
    return mode && !strcmp(mode, "1") && (!raw || strcmp(raw, "1")) && app && *app;
}
static int readNumberProperty(CFDictionaryRef properties, CFStringRef key) {
    int n = 0;
    CFTypeRef v = CFDictionaryGetValue(properties, key);
    if (v && CFGetTypeID(v) == CFNumberGetTypeID()) {
        CFNumberGetValue((CFNumberRef)v, kCFNumberIntType, &n);
    }
    return n;
}
static void readStringProperty(CFDictionaryRef properties, CFStringRef key, char *out,
                               size_t capacity) {
    out[0] = 0;
    CFTypeRef v = CFDictionaryGetValue(properties, key);
    if (v && CFGetTypeID(v) == CFStringGetTypeID()) {
        CFStringGetCString((CFStringRef)v, out, capacity, kCFStringEncodingUTF8);
    }
}
static int lookupSlot(void *joystick) {
    if (!getGUID || !getInstance || !getAttached || !getAttached(joystick)) {
        return -1;
    }
    int32_t instance = getInstance(joystick);
    if (instance < 0) {
        return -1;
    }
    pthread_mutex_lock(&lock);
    for (int i = 0; i < kGamepadCount; ++i) {
        if (slots[i].instance == instance) {
            pthread_mutex_unlock(&lock);
            return i;
        }
    }
    pthread_mutex_unlock(&lock);
    JoystickGUID guid = getGUID(joystick);
    // Reject physical controllers before consulting IOKit. No device is opened.
    if (guid.data[0] != 3 || guid.data[4] != 0x5e || guid.data[5] != 4 || guid.data[8] != 0x8e ||
        guid.data[9] != 2) {
        return -1;
    }
    io_iterator_t devices = 0;
    if (IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOHIDDevice"),
                                     &devices)) {
        return -1;
    }
    int found = -1;
    io_service_t device;
    while ((device = IOIteratorNext(devices))) {
        CFMutableDictionaryRef properties = nullptr;
        if (!IORegistryEntryCreateCFProperties(device, &properties, kCFAllocatorDefault, 0)) {
            char transport[64], manufacturer[128], product[128];
            readStringProperty(properties, CFSTR("Transport"), transport, sizeof(transport));
            readStringProperty(properties, CFSTR("Manufacturer"), manufacturer,
                               sizeof(manufacturer));
            readStringProperty(properties, CFSTR("Product"), product, sizeof(product));
            int slot = virtualGamepadSlot(guid, transport, manufacturer, product,
                                          readNumberProperty(properties, CFSTR("VendorID")),
                                          readNumberProperty(properties, CFSTR("ProductID")),
                                          readNumberProperty(properties, CFSTR("VersionNumber")));
            if (slot >= 0) {
                found = slot;
            }
            CFRelease(properties);
        }
        IOObjectRelease(device);
    }
    IOObjectRelease(devices);
    if (found >= 0) {
        pthread_mutex_lock(&lock);
        if (slots[found].instance != instance) {
            uint64_t generation = slots[found].generation + 1;
            slots[found] = Slot{};
            slots[found].instance = instance;
            slots[found].generation = generation;
            pthread_cond_signal(&wake);
        }
        pthread_mutex_unlock(&lock);
        fprintf(stderr, "notproton-rumble: Steam virtual gamepad slot %d mapped (pid %d)\n", found,
                getpid());
    }
    return found;
}

static void *worker(void *) {
    SteamSession steam;
    uint64_t seen[kGamepadCount] = {};
    ControllerHandle_t active[kGamepadCount] = {};
    double retryAt = 0;
    while (running) {
        Slot snapshot[kGamepadCount];
        pthread_mutex_lock(&lock);
        memcpy(snapshot, slots, sizeof(slots));
        pthread_mutex_unlock(&lock);
        double time = now(), next = time + 1;
        bool pending = false;
        for (int i = 0; i < kGamepadCount; ++i) {
            pending |= snapshot[i].generation != seen[i] && snapshot[i].instance >= 0 &&
                       snapshot[i].until > time;
        }
        if (!steam.controller && pending && time >= retryAt) {
            if (!steam.open()) {
                retryAt = now() + kSteamRetrySeconds;
            }
        }
        if (steam.controller) {
            steam.controller->RunFrame();
            // Use commands received while Steam was opening or RunFrame was blocked.
            pthread_mutex_lock(&lock);
            memcpy(snapshot, slots, sizeof(slots));
            pthread_mutex_unlock(&lock);
            time = now();
            ControllerHandle_t handles[kGamepadCount] = {};
            for (int i = 0; i < kGamepadCount; ++i) {
                if (snapshot[i].until > time && snapshot[i].instance >= 0) {
                    handles[i] = steam.controller->GetControllerForGamepadIndex(i);
                }
            }
            // Stop every old assignment before starting any new one. This also
            // handles two controllers exchanging their gamepad indices.
            for (int i = 0; i < kGamepadCount; ++i) {
                if (active[i] && active[i] != handles[i]) {
                    steam.controller->TriggerVibration(active[i], 0, 0);
                    active[i] = 0;
                }
            }
            for (int i = 0; i < kGamepadCount; ++i) {
                const Slot &request = snapshot[i];
                bool alive = request.until > time && request.instance >= 0;
                ControllerHandle_t handle = handles[i];
                if (handle && (request.generation != seen[i] || active[i] != handle)) {
                    steam.controller->TriggerVibration(handle, request.left, request.right);
                    active[i] = handle;
                    static bool logged;
                    if (!logged) {
                        fprintf(stderr, "notproton-rumble: forwarding rumble via Steam\n");
                        logged = true;
                    }
                }
                if (handle || !alive) {
                    seen[i] = request.generation;
                }
                // Retry a missing mapping, and detect reassignment during an effect.
                if (alive) {
                    next = std::min(next, std::min(time + kMappingPollSeconds, request.until));
                }
            }
        }
        pthread_mutex_lock(&lock);
        bool changed = false;
        for (int i = 0; i < kGamepadCount; ++i) {
            changed |= slots[i].generation != snapshot[i].generation;
        }
        if (!changed && running) {
            double wait = next - now();
            if (wait > 0) {
                struct timespec timeout{(time_t)wait, (long)((wait - (time_t)wait) * 1e9)};
                pthread_cond_timedwait_relative_np(&wake, &lock, &timeout);
            }
        }
        pthread_mutex_unlock(&lock);
    }
    if (steam.controller) {
        for (auto handle : active) {
            if (handle) {
                steam.controller->TriggerVibration(handle, 0, 0);
            }
        }
    }
    return nullptr;
}
static void startWorker() {
    workerStarted = pthread_create(&workerThread, nullptr, worker, nullptr) == 0;
}
static int rumble(void *joystick, uint16_t left, uint16_t right, uint32_t duration) {
    int slot = lookupSlot(joystick);
    if (slot < 0) {
        return originalRumble(joystick, left, right, duration);
    }
    // Wine probes with zeroes: advertise support without connecting to Steam or
    // cancelling rumble owned by another client (e.g. the game's Steam API).
    pthread_mutex_lock(&lock);
    bool idle = slots[slot].until == 0;
    pthread_mutex_unlock(&lock);
    if (idle && !(left || right)) {
        return 0;
    }
    pthread_once(&workerOnce, startWorker);
    if (!workerStarted) {
        return -1;
    }
    pthread_mutex_lock(&lock);
    slots[slot].left = left;
    slots[slot].right = right;
    // SDL2 uses a zero duration for effects without an automatic expiry.
    if (!(left || right)) {
        slots[slot].until = 0;
    } else if (duration) {
        slots[slot].until = now() + std::min(duration, uint32_t{65535}) / 1000.0;
    } else {
        slots[slot].until = std::numeric_limits<double>::infinity();
    }
    ++slots[slot].generation;
    pthread_cond_signal(&wake);
    pthread_mutex_unlock(&lock);
    return 0;
}
static int hasRumble(void *joystick) {
    if (lookupSlot(joystick) >= 0) {
        return 1;
    }
    return originalHasRumble ? originalHasRumble(joystick) : 0;
}
static void closeJoystick(void *joystick) {
    int32_t instance = getInstance ? getInstance(joystick) : -1;
    pthread_mutex_lock(&lock);
    for (auto &slot : slots) {
        if (instance >= 0 && slot.instance == instance) {
            slot.instance = -1;
            slot.until = 0;
            ++slot.generation;
        }
    }
    pthread_cond_signal(&wake);
    pthread_mutex_unlock(&lock);
    originalClose(joystick);
}
static void *resolve(void *library, const char *symbol) {
    void *original = dlsym(library, symbol);
    if (getenv("NOTPROTON_STEAM_RUMBLE_TRACE") && !strcmp(symbol, "SDL_JoystickRumble")) {
        Dl_info diag{};
        dladdr(original, &diag);
        fprintf(stderr, "notproton-rumble: resolve pid=%d enabled=%d source=%s root=%s app=%s\n",
                getpid(), enabled(), diag.dli_fname ? diag.dli_fname : "?",
                getenv("CX_ROOT") ? getenv("CX_ROOT") : "?",
                getenv("SteamAppId") ? getenv("SteamAppId") : "?");
    }
    if (!original || !enabled() ||
        (strcmp(symbol, "SDL_JoystickRumble") && strcmp(symbol, "SDL_JoystickHasRumble") &&
         strcmp(symbol, "SDL_JoystickClose"))) {
        return original;
    }
    // Never hook Steam's own SDL or an unrelated application/library.
    Dl_info image{};
    const char *root = getenv("CX_ROOT");
    if (!root || !*root || !dladdr(original, &image) || !image.dli_fname ||
        strncmp(image.dli_fname, root, strlen(root)) || image.dli_fname[strlen(root)] != '/') {
        return original;
    }
    pthread_mutex_lock(&lock);
    if (!sdlLibrary) {
        auto guid = (decltype(getGUID))dlsym(library, "SDL_JoystickGetGUID");
        auto instance = (decltype(getInstance))dlsym(library, "SDL_JoystickInstanceID");
        auto attached = (decltype(getAttached))dlsym(library, "SDL_JoystickGetAttached");
        auto rumble = (decltype(originalRumble))dlsym(library, "SDL_JoystickRumble");
        auto hasRumble = (decltype(originalHasRumble))dlsym(library, "SDL_JoystickHasRumble");
        auto close = (decltype(originalClose))dlsym(library, "SDL_JoystickClose");
        if (guid && instance && attached && rumble && close) {
            getGUID = guid;
            getInstance = instance;
            getAttached = attached;
            originalRumble = rumble;
            originalHasRumble = hasRumble;
            originalClose = close;
            sdlLibrary = library;
        }
    }
    bool matched = sdlLibrary == library;
    pthread_mutex_unlock(&lock);
    if (!matched) {
        return original;
    }
    if (!strcmp(symbol, "SDL_JoystickRumble")) {
        return (void *)rumble;
    }
    if (!strcmp(symbol, "SDL_JoystickHasRumble")) {
        return (void *)hasRumble;
    }
    return (void *)closeJoystick;
}
INTERPOSE(resolve, dlsym);
__attribute__((destructor)) static void shutdownBridge() {
    if (!workerStarted.exchange(false)) {
        return;
    }
    running = false;
    pthread_mutex_lock(&lock);
    pthread_cond_signal(&wake);
    pthread_mutex_unlock(&lock);
    pthread_join(workerThread, nullptr);
}
