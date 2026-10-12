// Keep Wine child processes in the game's existing signed app bundle.
// CrossOver normally execs a renamed temporary hardlink outside that bundle;
// LaunchServices then has no bundle identity for the actual game window.
#include <unistd.h>
#include <stdlib.h>
#include <string.h>
#include <stdio.h>
#include <ctype.h>
#include <limits.h>

// Resolve the executable, not arbitrary command-line arguments. Services and
// launchers outside the Steam install directory keep their normal Wine host.
static int is_game_executable(const char *argument) {
    const char *root = getenv("STEAM_COMPAT_INSTALL_PATH");
    const char *prefix = getenv("WINEPREFIX");
    char normalized[PATH_MAX], candidate[PATH_MAX], real_root[PATH_MAX], real_exe[PATH_MAX];
    if (!argument || !root || !realpath(root, real_root)) {
        return 0;
    }
    if (strlcpy(normalized, argument, sizeof(normalized)) >= sizeof(normalized)) {
        return 0;
    }
    for (char *p = normalized; *p; p++) {
        if (*p == '\\') {
            *p = '/';
        }
    }
    const char *exe = normalized;
    // Normalize NT object-manager and Win32 extended path prefixes.
    if (!strncmp(exe, "/\?\?/", 4) || !strncmp(exe, "//?/", 4)) {
        exe += 4;
    }
    if (isalpha((unsigned char)exe[0]) && exe[1] == ':' && exe[2] == '/') {
        if (!prefix ||
            snprintf(candidate, sizeof(candidate), "%s/dosdevices/%c:%s", prefix,
                     tolower((unsigned char)exe[0]), exe + 2) >= (int)sizeof(candidate)) {
            return 0;
        }
    } else {
        if (strlcpy(candidate, exe, sizeof(candidate)) >= sizeof(candidate)) {
            return 0;
        }
    }
    if (!realpath(candidate, real_exe)) {
        return 0;
    }
    size_t root_length = strlen(real_root), executable_length = strlen(real_exe);
    return executable_length > root_length + 4 && !strncmp(real_exe, real_root, root_length) &&
           real_exe[root_length] == '/' && !strcasecmp(real_exe + executable_length - 4, ".exe");
}

static const char *game_loader_for(const char *path, char *const argv[]) {
    const char *loader = getenv("NOTPROTON_GAME_LOADER");
    const char *tmp = getenv("TMPDIR");
    const char *noexec = getenv("WINELOADERNOEXEC");
    if (!path || !loader || !tmp || !noexec || strcmp(noexec, "1")) {
        return NULL;
    }
    // TMPDIR may end in '/'. Match its next component, not a string prefix
    // such as /tmp/game-other, and only Wine's immediate winetemp directory.
    size_t temporary_length = strlen(tmp);
    while (temporary_length > 1 && tmp[temporary_length - 1] == '/') {
        --temporary_length;
    }
    if (!temporary_length || strncmp(path, tmp, temporary_length) ||
        (temporary_length > 1 && path[temporary_length] != '/')) {
        return NULL;
    }
    // CrossOver appends /winetemp to a directory that may already end in '/'.
    const char *next_component = path + temporary_length;
    while (*next_component == '/') {
        ++next_component;
    }
    if (strncmp(next_component, "winetemp-", 9)) {
        return NULL;
    }
    const char *loader_suffix = ".app/Contents/MacOS/wine";
    size_t loader_length = strlen(loader), suffix_length = strlen(loader_suffix);
    if (!strstr(loader, "/Application Support/notproton/launchers/") ||
        loader_length < suffix_length ||
        strcmp(loader + loader_length - suffix_length, loader_suffix)) {
        return NULL;
    }
    if (access(loader, X_OK)) {
        return NULL;
    }
    if (!argv || !argv[0] || !is_game_executable(argv[1])) {
        return NULL;
    }
    return loader;
}

static int game_execv(const char *path, char *const argv[]) {
    const char *loader = game_loader_for(path, argv);
    if (loader) {
        fprintf(stderr, "NotProton Game Host: game executable stays inside game app (%s)\n",
                strrchr(path, '/') + 1);
        return execv(loader, argv);
    }
    return execv(path, argv);
}
#ifndef GAME_HOST_TEST
__attribute__((used)) static const struct {
    const void *new_fn, *old_fn;
} interpose_execv __attribute__((section("__DATA,__interpose"))) = {(const void *)game_execv,
                                                                    (const void *)execv};
#endif
