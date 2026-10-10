#include <CoreFoundation/CoreFoundation.h>
#include <IOKit/IOKitLib.h>
#include <dlfcn.h>
#include <cassert>
#include <cstring>
#include <string>
#include "../VirtualGamepad.h"

struct Joystick {
    int32_t instance;
    bool attached = true;
    JoystickGUID guid;
};
static CFMutableDictionaryRef deviceProperties;
static bool devicePending, incompleteSDL;
static unsigned enumerations, fallbackCalls, closeCalls;
static const char *imagePath = "/test/CrossOver/lib/libSDL2.dylib";
static JoystickGUID mockGUID(void *j) {
    return ((Joystick *)j)->guid;
}
static int32_t mockInstance(void *j) {
    return ((Joystick *)j)->instance;
}
static int mockAttached(void *j) {
    return ((Joystick *)j)->attached;
}
static int mockRumble(void *, uint16_t, uint16_t, uint32_t) {
    ++fallbackCalls;
    return -7;
}
static int mockHasRumble(void *) {
    return 0;
}
static void mockClose(void *j) {
    ((Joystick *)j)->attached = false;
    ++closeCalls;
}
static void *mockDlsym(void *, const char *name) {
    if (!strcmp(name, "SDL_JoystickGetGUID")) {
        return (void *)mockGUID;
    }
    if (!strcmp(name, "SDL_JoystickInstanceID")) {
        return (void *)mockInstance;
    }
    if (!strcmp(name, "SDL_JoystickGetAttached")) {
        return incompleteSDL ? nullptr : (void *)mockAttached;
    }
    if (!strcmp(name, "SDL_JoystickRumble")) {
        return (void *)mockRumble;
    }
    if (!strcmp(name, "SDL_JoystickHasRumble")) {
        return (void *)mockHasRumble;
    }
    if (!strcmp(name, "SDL_JoystickClose")) {
        return (void *)mockClose;
    }
    return nullptr;
}
static int mockDladdr(const void *, Dl_info *info) {
    info->dli_fname = imagePath;
    return 1;
}
static kern_return_t mockMatching(mach_port_t, CFDictionaryRef matching, io_iterator_t *iterator) {
    CFRelease(matching);
    ++enumerations;
    devicePending = true;
    *iterator = 1;
    return KERN_SUCCESS;
}
static io_object_t mockNext(io_iterator_t) {
    if (!devicePending) {
        return 0;
    }
    devicePending = false;
    return 2;
}
static kern_return_t mockProperties(io_registry_entry_t, CFMutableDictionaryRef *out,
                                    CFAllocatorRef, IOOptionBits) {
    *out = CFDictionaryCreateMutableCopy(nullptr, 0, deviceProperties);
    return KERN_SUCCESS;
}
static kern_return_t mockRelease(io_object_t) {
    return KERN_SUCCESS;
}

#define INTERPOSE(replacement, original)
#define dlsym mockDlsym
#define dladdr mockDladdr
#define IOServiceGetMatchingServices mockMatching
#define IOIteratorNext mockNext
#define IORegistryEntryCreateCFProperties mockProperties
#define IOObjectRelease mockRelease
#include "../rumble.cpp"
#undef dlsym
#undef dladdr
#undef IOServiceGetMatchingServices
#undef IOIteratorNext
#undef IORegistryEntryCreateCFProperties
#undef IOObjectRelease

static void number(CFStringRef key, int value) {
    auto property = CFNumberCreate(nullptr, kCFNumberIntType, &value);
    CFDictionarySetValue(deviceProperties, key, property);
    CFRelease(property);
}
int main() {
    void *library = (void *)1;
    setenv("NOTPROTON_STEAM_RUMBLE", "1", 1);
    setenv("NOTPROTON_RAW_CONTROLLERS", "0", 1);
    setenv("SteamAppId", "242680", 1);
    setenv("CX_ROOT", "/test/CrossOver", 1);
    assert(resolve(library, "missing") == nullptr);
    for (const char *key : {"NOTPROTON_STEAM_RUMBLE", "SteamAppId", "CX_ROOT"}) {
        std::string saved = getenv(key);
        setenv(key, "", 1);
        assert(resolve(library, "SDL_JoystickRumble") == (void *)mockRumble);
        setenv(key, saved.c_str(), 1);
    }
    setenv("NOTPROTON_RAW_CONTROLLERS", "1", 1);
    assert(resolve(library, "SDL_JoystickRumble") == (void *)mockRumble);
    setenv("NOTPROTON_RAW_CONTROLLERS", "0", 1);
    for (auto path : {"/Steam/libSDL2.dylib", "/test/CrossOver-other/libSDL2.dylib"}) {
        imagePath = path;
        assert(resolve(library, "SDL_JoystickRumble") == (void *)mockRumble);
    }
    imagePath = "/test/CrossOver/lib/libSDL2.dylib";
    incompleteSDL = true;
    assert(resolve(library, "SDL_JoystickRumble") == (void *)mockRumble);
    assert(!getGUID && !originalRumble && !sdlLibrary);
    incompleteSDL = false;
    assert(resolve(library, "SDL_JoystickRumble") == (void *)rumble);
    assert(resolve(library, "SDL_JoystickHasRumble") == (void *)hasRumble);
    assert(resolve(library, "SDL_JoystickClose") == (void *)closeJoystick);
    assert(resolve((void *)2, "SDL_JoystickRumble") == (void *)mockRumble);

    deviceProperties = CFDictionaryCreateMutable(nullptr, 0, &kCFTypeDictionaryKeyCallBacks,
                                                 &kCFTypeDictionaryValueCallBacks);
    CFDictionarySetValue(deviceProperties, CFSTR("Transport"), CFSTR("Virtual"));
    CFDictionarySetValue(deviceProperties, CFSTR("Manufacturer"), CFSTR("Microsoft"));
    CFDictionarySetValue(deviceProperties, CFSTR("Product"), CFSTR("GamePad-1"));
    number(CFSTR("VendorID"), 0x45e);
    number(CFSTR("ProductID"), 0x28e);
    number(CFSTR("VersionNumber"), 0);
    Joystick physical{10, true, {}};
    assert(hasRumble(&physical) == 0 && enumerations == 0);
    assert(rumble(&physical, 1, 2, 3) == -7 && fallbackCalls == 1);
    Joystick first{11, true, virtualGamepadGUID(0, 0)};
    assert(hasRumble(&first) == 1 && enumerations == 1);
    assert(hasRumble(&first) == 1 && enumerations == 1); // Cached SDL instance.
    assert(rumble(&first, 0, 0, 0) == 0 && !workerStarted);
    first.attached = false;
    assert(hasRumble(&first) == 0);
    slots[0].until = now() + 60;
    slots[0].left = 123;
    uint64_t oldGeneration = slots[0].generation;
    Joystick replacement{12, true, virtualGamepadGUID(0, 0)};
    replacement.guid.data[14] = 'h';
    assert(hasRumble(&replacement) == 1);
    assert(slots[0].instance == 12 && slots[0].until == 0 && slots[0].left == 0);
    assert(slots[0].generation > oldGeneration);
    closeJoystick(&first);
    assert(slots[0].instance == 12); // A late close cannot invalidate the replacement.
    closeJoystick(&replacement);
    assert(slots[0].instance == -1 && closeCalls == 2);
    CFDictionarySetValue(deviceProperties, CFSTR("Transport"), CFSTR("USB"));
    Joystick realXbox{13, true, virtualGamepadGUID(0, 0)};
    assert(hasRumble(&realXbox) == 0);
    assert(!workerStarted);
    CFRelease(deviceProperties);
    puts("steam-input: SDL symbol gating, IOKit identity, cache, HIDAPI, replacement and close "
         "passed");
}
