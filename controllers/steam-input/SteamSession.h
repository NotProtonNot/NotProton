#pragma once
#include <dlfcn.h>
#include <cstdio>
#include <cstdlib>
#include <unistd.h>
#include "steam_api.h"

// Owned by the rumble worker; no Steam calls run on the SDL input thread.
struct SteamSession {
    SteamSession() = default;
    SteamSession(const SteamSession &) = delete;
    SteamSession &operator=(const SteamSession &) = delete;
    ~SteamSession() {
        close();
    }

    void *library = nullptr;
    ISteamClient *client = nullptr;
    ISteamController *controller = nullptr;
    HSteamPipe pipe = 0;
    HSteamUser user = 0;
    bool open() {
        if (controller) {
            return true;
        }
        const char *path = getenv("STEAM_COMPAT_CLIENT_INSTALL_PATH");
        if (!path || !*path) {
            return false;
        }
        char file[4096];
        if (snprintf(file, sizeof(file), "%s/steamclient.dylib", path) >= (int)sizeof(file)) {
            return false;
        }
        if (!library) {
            library = dlopen(file, RTLD_NOW | RTLD_LOCAL);
        }
        if (!library) {
            return false;
        }
        auto factory = (void *(*)(const char *, int *))dlsym(library, "CreateInterface");
        if (!factory) {
            return false;
        }
        client = (ISteamClient *)factory(STEAMCLIENT_INTERFACE_VERSION, nullptr);
        if (!client || !(pipe = client->CreateSteamPipe()) ||
            !(user = client->ConnectToGlobalUser(pipe))) {
            close();
            return false;
        }
        controller = client->GetISteamController(user, pipe, STEAMCONTROLLER_INTERFACE_VERSION);
        if (!controller || !controller->Init()) {
            controller = nullptr;
            close();
            return false;
        }
        fprintf(stderr, "notproton-rumble: native Steam controller API ready (pid %d)\n", getpid());
        return true;
    }
    void close() {
        if (controller) {
            controller->Shutdown();
        }
        if (client && user) {
            client->ReleaseUser(pipe, user);
        }
        if (client && pipe) {
            client->BReleaseSteamPipe(pipe);
        }
        // Steam owns background threads. Keep its image mapped until process exit.
        controller = nullptr;
        client = nullptr;
        user = 0;
        pipe = 0;
    }
};
