#include <cassert>
#include <string>
#include "../rumble.cpp"
#include "MockSteam.h"
static unsigned (*countEvents)();
static RumbleEvent (*eventAt)(unsigned);
static unsigned fallbackCalls;
static int32_t instance(void *j) {
    return (int32_t)(uintptr_t)j;
}
static int attached(void *j) {
    return j != nullptr;
}
static JoystickGUID physicalGUID(void *) {
    return {};
}
static int fallback(void *, uint16_t, uint16_t, uint32_t) {
    ++fallbackCalls;
    return -7;
}
static void noop(void *) {}
static void waitFor(unsigned count) {
    for (int i = 0; i < 200 && countEvents() < count; ++i) {
        usleep(5000);
    }
    assert(countEvents() >= count);
}
int main(int argc, char **argv) {
    assert(argc == 2);
    // Raw Xbox IDs are insufficient; confirm IOKit's Virtual transport and
    // original product name, including slot, against SDL's complete GUID.
    auto guid = virtualGamepadGUID(0, 0);
    const uint8_t recorded[16] = {3, 0, 0x53, 0x25, 0x5e, 4, 0, 0, 0x8e, 2, 0, 0, 0, 0, 0, 0};
    assert(!memcmp(guid.data, recorded, 16));
    assert(virtualGamepadSlot(guid, "Virtual", "Microsoft", "GamePad-1", 0x45e, 0x28e, 0) == 0);
    assert(virtualGamepadSlot(guid, "USB", "Microsoft", "GamePad-1", 0x45e, 0x28e, 0) == -1);
    assert(virtualGamepadSlot(guid, "Virtual", "Microsoft", "GamePad-2", 0x45e, 0x28e, 0) == -1);
    assert(virtualGamepadSlot(guid, "Virtual", "Microsoft", "GamePad-1junk", 0x45e, 0x28e, 0) ==
           -1);
    auto hidapi = guid;
    hidapi.data[14] = 'h';
    assert(virtualGamepadSlot(hidapi, "Virtual", "Microsoft", "GamePad-1", 0x45e, 0x28e, 0) == 0);
    hidapi.data[14] = 'm';
    assert(virtualGamepadSlot(hidapi, "Virtual", "Microsoft", "GamePad-1", 0x45e, 0x28e, 0) == -1);
    for (unsigned i = 0; i < 16; i++) {
        char name[32];
        snprintf(name, sizeof(name), "GamePad-%u", i + 1);
        assert(virtualGamepadSlot(virtualGamepadGUID(i, 7), "Virtual", "Microsoft", name, 0x45e,
                                  0x28e, 7) == (int)i);
    }
    setenv("STEAM_COMPAT_CLIENT_INSTALL_PATH", argv[1], 1);
    std::string library = std::string(argv[1]) + "/steamclient.dylib";
    void *mock = dlopen(library.c_str(), RTLD_NOW | RTLD_LOCAL);
    assert(mock);
    countEvents = (decltype(countEvents))dlsym(mock, "testCount");
    eventAt = (decltype(eventAt))dlsym(mock, "testEvent");
    auto setHandle = (void (*)(int, ControllerHandle_t))dlsym(mock, "testSetHandle");
    auto delayFrame = (void (*)(unsigned))dlsym(mock, "testDelayFrame");
    auto setFailure = (void (*)(unsigned))dlsym(mock, "testFailure");
    auto stats = (SessionStats (*)())dlsym(mock, "testStats");
    assert(countEvents && eventAt && setHandle && delayFrame && setFailure && stats);
    setHandle(0, 100);
    setHandle(1, 101);

    for (unsigned failure = 1; failure <= 4; ++failure) {
        setFailure(failure);
        SteamSession session;
        assert(!session.open());
        auto counts = stats();
        assert(counts.pipes == counts.releasedPipes && counts.users == counts.releasedUsers);
        assert(!session.controller && !session.pipe && !session.user);
    }
    setFailure(0);
    {
        SteamSession session;
        assert(session.open());
    }
    auto counts = stats();
    assert(counts.pipes == counts.releasedPipes && counts.users == counts.releasedUsers);
    assert(counts.shutdowns == 1);

    getInstance = instance;
    getAttached = attached;
    getGUID = physicalGUID;
    originalRumble = fallback;
    originalClose = noop;
    slots[0].instance = 42;
    slots[1].instance = 43;
    assert(rumble((void *)99, 1, 2, 3) == -7 && fallbackCalls == 1); // physical path
    assert(rumble((void *)42, 0, 0, 0) == 0 && !workerStarted);      // capability probe
    assert(rumble((void *)42, 12345, 54321, 200) == 0);
    waitFor(1);
    auto e = eventAt(0);
    assert(e.handle == 100 && e.left == 12345 && e.right == 54321);
    waitFor(2);
    e = eventAt(1);
    assert(e.handle == 100 && !e.left && !e.right); // expiry
    rumble((void *)43, 200, 400, 2000);
    waitFor(3);
    assert(eventAt(2).handle == 101);
    rumble((void *)43, 0, 0, 0);
    waitFor(4);
    assert(eventAt(3).handle == 101 && !eventAt(3).left); // explicit stop
    rumble((void *)42, 333, 444, 2000);
    waitFor(5);
    closeJoystick((void *)42);
    waitFor(6);
    assert(!eventAt(5).left); // removal
    assert(slots[0].instance == -1);
    rumble((void *)43, 500, 600, 2000);
    waitFor(7);
    // A game can send its first effect while Steam is still publishing the
    // virtual-to-physical mapping. It must not need another XInput call.
    rumble((void *)43, 0, 0, 0);
    waitFor(8);
    setHandle(1, 0);
    rumble((void *)43, 777, 888, 2000);
    usleep(60000);
    assert(countEvents() == 8);
    setHandle(1, 101);
    waitFor(9);
    assert(eventAt(8).left == 777 && eventAt(8).right == 888);

    // Mapping changes must stop the old handle before using the replacement,
    // even if Wine has not issued another rumble command.
    setHandle(1, 201);
    waitFor(11);
    assert(eventAt(9).handle == 101 && !eventAt(9).left);
    assert(eventAt(10).handle == 201 && eventAt(10).left == 777);
    setHandle(1, 0);
    waitFor(12);
    assert(eventAt(11).handle == 201 && !eventAt(11).left);
    setHandle(1, 101);
    waitFor(13);
    assert(eventAt(12).left == 777);
    rumble((void *)43, 0, 0, 0);
    waitFor(14);

    // A slow Steam update must not resurrect an effect whose deadline passed.
    delayFrame(100);
    rumble((void *)43, 111, 222, 30);
    usleep(160000);
    assert(countEvents() == 14);

    // SDL2 leaves a nonzero effect running when duration is zero.
    rumble((void *)43, 555, 666, 0);
    waitFor(15);
    usleep(60000);
    assert(countEvents() == 15 && eventAt(14).left == 555);
    rumble((void *)43, 0, 0, 0);
    waitFor(16);
    rumble((void *)43, 123, 456, UINT32_MAX);
    waitFor(17);
    pthread_mutex_lock(&lock);
    double remaining = slots[1].until - now();
    pthread_mutex_unlock(&lock);
    assert(remaining > 64 && remaining <= 65.535);
    // Replace a command while RunFrame is blocked; only the new one may escape.
    auto frameBlocked = (bool (*)())dlsym(mock, "testFrameBlocked");
    delayFrame(150);
    rumble((void *)43, 321, 654, 2000);
    for (int i = 0; i < 200 && !frameBlocked(); ++i) {
        usleep(1000);
    }
    assert(frameBlocked());
    rumble((void *)43, 500, 600, 2000);
    waitFor(18);
    assert(eventAt(17).left == 500);

    pthread_mutex_lock(&lock);
    slots[0].instance = 44;
    pthread_mutex_unlock(&lock);
    rumble((void *)44, 1000, 2000, 2000);
    waitFor(19);
    delayFrame(150);
    rumble((void *)43, 501, 601, 2000);
    for (int i = 0; i < 200 && !frameBlocked(); ++i) {
        usleep(1000);
    }
    assert(frameBlocked());
    setHandle(0, 101);
    setHandle(1, 100);
    waitFor(23);
    assert(eventAt(19).handle == 100 && !eventAt(19).left);
    assert(eventAt(20).handle == 101 && !eventAt(20).left);
    assert(eventAt(21).handle == 101 && eventAt(21).left == 1000);
    assert(eventAt(22).handle == 100 && eventAt(22).left == 501);

    shutdownBridge();
    assert(countEvents() == 25 && !eventAt(23).left && !eventAt(24).left);
    counts = stats();
    assert(counts.pipes == counts.releasedPipes && counts.users == counts.releasedUsers);
    shutdownBridge(); // Idempotent cleanup; no duplicate stop or thread join.
    assert(countEvents() == 25);
    puts("steam-input: routing, fallback, amplitudes, expiry, stop, reassignment, late mapping, "
         "slow Steam, zero/max duration, session failures and shutdown passed");
}
