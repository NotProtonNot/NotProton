#include "steam_api.h"
#include "MockSteam.h"
#include <atomic>
#include <cassert>
#include <cstdlib>
#include <cstring>
#include <mutex>
#include <unistd.h>
#include <vector>

static std::mutex eventLock;
static std::vector<RumbleEvent> events;
static std::atomic<ControllerHandle_t> handles[STEAM_CONTROLLER_MAX_COUNT];
static std::atomic<unsigned> frameDelay{0};
static std::atomic<bool> frameBlocked{false};
static unsigned failure, pipes, releasedPipes, users, releasedUsers, initializations, shutdowns;

// Implement the SDK interfaces so the compiler checks the ABI. Any unexpected
// API call aborts the test, including attempts to change LEDs or input bindings.
struct ControllerMock final : ISteamController {
    bool Init() override {
        ++initializations;
        return failure != 4;
    }
    bool Shutdown() override {
        ++shutdowns;
        return true;
    }
    void RunFrame() override {
        unsigned delay = frameDelay.exchange(0);
        if (delay) {
            frameBlocked = true;
            usleep(delay * 1000);
            frameBlocked = false;
        }
    }
    int GetConnectedControllers(ControllerHandle_t *handlesOut) override {
        std::abort();
    }
    ControllerActionSetHandle_t GetActionSetHandle(const char *pszActionSetName) override {
        std::abort();
    }
    void ActivateActionSet(ControllerHandle_t controllerHandle,
                           ControllerActionSetHandle_t actionSetHandle) override {
        std::abort();
    }
    ControllerActionSetHandle_t GetCurrentActionSet(ControllerHandle_t controllerHandle) override {
        std::abort();
    }
    void ActivateActionSetLayer(ControllerHandle_t controllerHandle,
                                ControllerActionSetHandle_t actionSetLayerHandle) override {
        std::abort();
    }
    void DeactivateActionSetLayer(ControllerHandle_t controllerHandle,
                                  ControllerActionSetHandle_t actionSetLayerHandle) override {
        std::abort();
    }
    void DeactivateAllActionSetLayers(ControllerHandle_t controllerHandle) override {
        std::abort();
    }
    int GetActiveActionSetLayers(ControllerHandle_t controllerHandle,
                                 ControllerActionSetHandle_t *handlesOut) override {
        std::abort();
    }
    ControllerDigitalActionHandle_t GetDigitalActionHandle(const char *pszActionName) override {
        std::abort();
    }
    ControllerDigitalActionData_t
    GetDigitalActionData(ControllerHandle_t controllerHandle,
                         ControllerDigitalActionHandle_t digitalActionHandle) override {
        std::abort();
    }
    int GetDigitalActionOrigins(ControllerHandle_t controllerHandle,
                                ControllerActionSetHandle_t actionSetHandle,
                                ControllerDigitalActionHandle_t digitalActionHandle,
                                EControllerActionOrigin *originsOut) override {
        std::abort();
    }
    ControllerAnalogActionHandle_t GetAnalogActionHandle(const char *pszActionName) override {
        std::abort();
    }
    ControllerAnalogActionData_t
    GetAnalogActionData(ControllerHandle_t controllerHandle,
                        ControllerAnalogActionHandle_t analogActionHandle) override {
        std::abort();
    }
    int GetAnalogActionOrigins(ControllerHandle_t controllerHandle,
                               ControllerActionSetHandle_t actionSetHandle,
                               ControllerAnalogActionHandle_t analogActionHandle,
                               EControllerActionOrigin *originsOut) override {
        std::abort();
    }
    const char *GetGlyphForActionOrigin(EControllerActionOrigin eOrigin) override {
        std::abort();
    }
    const char *GetStringForActionOrigin(EControllerActionOrigin eOrigin) override {
        std::abort();
    }
    void StopAnalogActionMomentum(ControllerHandle_t controllerHandle,
                                  ControllerAnalogActionHandle_t eAction) override {
        std::abort();
    }
    ControllerMotionData_t GetMotionData(ControllerHandle_t controllerHandle) override {
        std::abort();
    }
    void TriggerHapticPulse(ControllerHandle_t controllerHandle, ESteamControllerPad eTargetPad,
                            unsigned short usDurationMicroSec) override {
        std::abort();
    }
    void TriggerRepeatedHapticPulse(ControllerHandle_t controllerHandle,
                                    ESteamControllerPad eTargetPad,
                                    unsigned short usDurationMicroSec, unsigned short usOffMicroSec,
                                    unsigned short unRepeat, unsigned int nFlags) override {
        std::abort();
    }
    void TriggerVibration(ControllerHandle_t controllerHandle, unsigned short usLeftSpeed,
                          unsigned short usRightSpeed) override {
        std::lock_guard<std::mutex> guard(eventLock);
        events.push_back({controllerHandle, usLeftSpeed, usRightSpeed});
    }
    void SetLEDColor(ControllerHandle_t controllerHandle, uint8 nColorR, uint8 nColorG,
                     uint8 nColorB, unsigned int nFlags) override {
        std::abort();
    }
    bool ShowBindingPanel(ControllerHandle_t controllerHandle) override {
        std::abort();
    }
    ESteamInputType GetInputTypeForHandle(ControllerHandle_t controllerHandle) override {
        std::abort();
    }
    ControllerHandle_t GetControllerForGamepadIndex(int nIndex) override {
        return handles[nIndex].load();
    }
    int GetGamepadIndexForController(ControllerHandle_t ulControllerHandle) override {
        std::abort();
    }
    const char *GetStringForXboxOrigin(EXboxOrigin eOrigin) override {
        std::abort();
    }
    const char *GetGlyphForXboxOrigin(EXboxOrigin eOrigin) override {
        std::abort();
    }
    EControllerActionOrigin GetActionOriginFromXboxOrigin(ControllerHandle_t controllerHandle,
                                                          EXboxOrigin eOrigin) override {
        std::abort();
    }
    EControllerActionOrigin TranslateActionOrigin(ESteamInputType eDestinationInputType,
                                                  EControllerActionOrigin eSourceOrigin) override {
        std::abort();
    }
    bool GetControllerBindingRevision(ControllerHandle_t controllerHandle, int *pMajor,
                                      int *pMinor) override {
        std::abort();
    }
};
static ControllerMock controller;

struct ClientMock final : ISteamClient {
    HSteamPipe CreateSteamPipe() override {
        if (failure == 1) {
            return 0;
        }
        ++pipes;
        return 1;
    }
    bool BReleaseSteamPipe(HSteamPipe hSteamPipe) override {
        assert(hSteamPipe == 1);
        ++releasedPipes;
        return true;
    }
    HSteamUser ConnectToGlobalUser(HSteamPipe hSteamPipe) override {
        assert(hSteamPipe == 1);
        if (failure == 2) {
            return 0;
        }
        ++users;
        return 1;
    }
    HSteamUser CreateLocalUser(HSteamPipe *phSteamPipe, EAccountType eAccountType) override {
        std::abort();
    }
    void ReleaseUser(HSteamPipe hSteamPipe, HSteamUser hUser) override {
        assert(hSteamPipe == 1 && hUser == 1);
        ++releasedUsers;
    }
    ISteamUser *GetISteamUser(HSteamUser hSteamUser, HSteamPipe hSteamPipe,
                              const char *pchVersion) override {
        std::abort();
    }
    ISteamGameServer *GetISteamGameServer(HSteamUser hSteamUser, HSteamPipe hSteamPipe,
                                          const char *pchVersion) override {
        std::abort();
    }
    void SetLocalIPBinding(const SteamIPAddress_t &unIP, uint16 usPort) override {
        std::abort();
    }
    ISteamFriends *GetISteamFriends(HSteamUser hSteamUser, HSteamPipe hSteamPipe,
                                    const char *pchVersion) override {
        std::abort();
    }
    ISteamUtils *GetISteamUtils(HSteamPipe hSteamPipe, const char *pchVersion) override {
        std::abort();
    }
    ISteamMatchmaking *GetISteamMatchmaking(HSteamUser hSteamUser, HSteamPipe hSteamPipe,
                                            const char *pchVersion) override {
        std::abort();
    }
    ISteamMatchmakingServers *GetISteamMatchmakingServers(HSteamUser hSteamUser,
                                                          HSteamPipe hSteamPipe,
                                                          const char *pchVersion) override {
        std::abort();
    }
    void *GetISteamGenericInterface(HSteamUser hSteamUser, HSteamPipe hSteamPipe,
                                    const char *pchVersion) override {
        std::abort();
    }
    ISteamUserStats *GetISteamUserStats(HSteamUser hSteamUser, HSteamPipe hSteamPipe,
                                        const char *pchVersion) override {
        std::abort();
    }
    ISteamGameServerStats *GetISteamGameServerStats(HSteamUser hSteamuser, HSteamPipe hSteamPipe,
                                                    const char *pchVersion) override {
        std::abort();
    }
    ISteamApps *GetISteamApps(HSteamUser hSteamUser, HSteamPipe hSteamPipe,
                              const char *pchVersion) override {
        std::abort();
    }
    ISteamNetworking *GetISteamNetworking(HSteamUser hSteamUser, HSteamPipe hSteamPipe,
                                          const char *pchVersion) override {
        std::abort();
    }
    ISteamRemoteStorage *GetISteamRemoteStorage(HSteamUser hSteamuser, HSteamPipe hSteamPipe,
                                                const char *pchVersion) override {
        std::abort();
    }
    ISteamScreenshots *GetISteamScreenshots(HSteamUser hSteamuser, HSteamPipe hSteamPipe,
                                            const char *pchVersion) override {
        std::abort();
    }
    ISteamGameSearch *GetISteamGameSearch(HSteamUser hSteamuser, HSteamPipe hSteamPipe,
                                          const char *pchVersion) override {
        std::abort();
    }
    void RunFrame() override {
        std::abort();
    }
    uint32 GetIPCCallCount() override {
        std::abort();
    }
    void SetWarningMessageHook(SteamAPIWarningMessageHook_t pFunction) override {
        std::abort();
    }
    bool BShutdownIfAllPipesClosed() override {
        std::abort();
    }
    ISteamHTTP *GetISteamHTTP(HSteamUser hSteamuser, HSteamPipe hSteamPipe,
                              const char *pchVersion) override {
        std::abort();
    }
    ISteamController *GetISteamController(HSteamUser hSteamUser, HSteamPipe hSteamPipe,
                                          const char *pchVersion) override {
        assert(hSteamUser == 1 && hSteamPipe == 1);
        assert(!strcmp(pchVersion, STEAMCONTROLLER_INTERFACE_VERSION));
        return failure == 3 ? nullptr : &controller;
    }
    ISteamUGC *GetISteamUGC(HSteamUser hSteamUser, HSteamPipe hSteamPipe,
                            const char *pchVersion) override {
        std::abort();
    }
    ISteamMusic *GetISteamMusic(HSteamUser hSteamuser, HSteamPipe hSteamPipe,
                                const char *pchVersion) override {
        std::abort();
    }
    ISteamMusicRemote *GetISteamMusicRemote(HSteamUser hSteamuser, HSteamPipe hSteamPipe,
                                            const char *pchVersion) override {
        std::abort();
    }
    ISteamHTMLSurface *GetISteamHTMLSurface(HSteamUser hSteamuser, HSteamPipe hSteamPipe,
                                            const char *pchVersion) override {
        std::abort();
    }
    void DEPRECATED_Set_SteamAPI_CPostAPIResultInProcess(void (*)()) override {
        std::abort();
    }
    void DEPRECATED_Remove_SteamAPI_CPostAPIResultInProcess(void (*)()) override {
        std::abort();
    }
    void Set_SteamAPI_CCheckCallbackRegisteredInProcess(
        SteamAPI_CheckCallbackRegistered_t func) override {
        std::abort();
    }
    ISteamInventory *GetISteamInventory(HSteamUser hSteamuser, HSteamPipe hSteamPipe,
                                        const char *pchVersion) override {
        std::abort();
    }
    ISteamVideo *GetISteamVideo(HSteamUser hSteamuser, HSteamPipe hSteamPipe,
                                const char *pchVersion) override {
        std::abort();
    }
    ISteamParentalSettings *GetISteamParentalSettings(HSteamUser hSteamuser, HSteamPipe hSteamPipe,
                                                      const char *pchVersion) override {
        std::abort();
    }
    ISteamInput *GetISteamInput(HSteamUser hSteamUser, HSteamPipe hSteamPipe,
                                const char *pchVersion) override {
        std::abort();
    }
    ISteamParties *GetISteamParties(HSteamUser hSteamUser, HSteamPipe hSteamPipe,
                                    const char *pchVersion) override {
        std::abort();
    }
    ISteamRemotePlay *GetISteamRemotePlay(HSteamUser hSteamUser, HSteamPipe hSteamPipe,
                                          const char *pchVersion) override {
        std::abort();
    }
    void DestroyAllInterfaces() override {
        std::abort();
    }
};
static ClientMock client;

extern "C" void *CreateInterface(const char *version, int *) {
    assert(!strcmp(version, STEAMCLIENT_INTERFACE_VERSION));
    return &client;
}
extern "C" unsigned testCount() {
    std::lock_guard<std::mutex> guard(eventLock);
    return events.size();
}
extern "C" RumbleEvent testEvent(unsigned i) {
    std::lock_guard<std::mutex> guard(eventLock);
    return events.at(i);
}
extern "C" void testSetHandle(int slot, ControllerHandle_t handle) {
    handles[slot] = handle;
}
extern "C" void testDelayFrame(unsigned milliseconds) {
    frameDelay = milliseconds;
}
extern "C" void testFailure(unsigned stage) {
    failure = stage;
}
extern "C" SessionStats testStats() {
    return {pipes, releasedPipes, users, releasedUsers, initializations, shutdowns};
}

extern "C" bool testFrameBlocked() {
    return frameBlocked;
}
