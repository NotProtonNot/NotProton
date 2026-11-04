// The decision is in two static functions, so the unit under test is included rather
// than linked. What matters is which child keeps the insert and which entries survive
// the strip, neither of which needs Dobby or a live client.
#include "../hooks/hook_spawn.c"

#include <stdio.h>

int   np_log_level = 0;
FILE *np_log_file  = NULL;

int DobbyHook(void *address, void *replace_call, void **origin_call) {
    (void)address; (void)replace_call; (void)origin_call;
    return -1;
}

void *DobbySymbolResolver(const char *image_name, const char *symbol_name) {
    (void)image_name; (void)symbol_name;
    return NULL;
}

int np_hooks_env_lists_label(const char *var, const char *label) {
    (void)var; (void)label;
    return 0;
}

static int failures;

static void check(int ok, const char *what) {
    if (!ok) {
        printf("FAIL %s\n", what);
        failures++;
    }
}

static void keeps(const char *path, int want, const char *what) {
    check(np_target_keeps_insert(path) == want, what);
}

// Entries of `got`, in order, against a NULL-terminated expectation.
static void survives(char *const envp[], const char *const want[], const char *what) {
    char **got = np_without_insert(envp);
    if (!want) {
        check(got == NULL, what);
        free(got);
        return;
    }
    if (!got) {
        check(0, what);
        return;
    }
    int i = 0;
    for (; want[i] && got[i]; i++) {
        if (strcmp(want[i], got[i]) != 0)
            break;
    }
    check(want[i] == NULL && got[i] == NULL, what);
    free(got);
}

#define NP_DYLIB "/Applications/Steam.app/Contents/MacOS/notproton.dylib"
#define OVERLAY  "/S/steamloader.dylib:/S/gameoverlayrenderer.dylib"

int main(void) {
    np_insert_entry = (char *)"DYLD_INSERT_LIBRARIES=" NP_DYLIB;
    np_block_entry  = (char *)"SDL_JOYSTICK_BLACKLIST_DEVICES=0x05ac/0x0004";

    // The client's own re-exec is the one child that has to keep the insert, because the
    // hooks install in that process and an exec does not get LSEnvironment.
    keeps("/Applications/Steam.app/Contents/MacOS/steam_osx", 1, "an absolute steam_osx keeps it");
    keeps("/Users/x/Library/Application Support/Steam/Steam.AppBundle/Steam/Contents/MacOS/steam_osx",
          1, "the AppBundle copy of steam_osx keeps it");
    keeps("steam_osx", 1, "a bare steam_osx keeps it");
    keeps(NULL, 1, "an unnamed target keeps it");

    // Everything else is what dyld was killing.
    keeps("/bin/sh", 0, "sh loses it");
    keeps("/bin/bash", 0, "bash loses it");
    keeps("/usr/sbin/lsof", 0, "lsof loses it");
    keeps("/bin/launchctl", 0, "launchctl loses it");
    keeps("/Applications/Steam.app/Contents/MacOS/Steam Helper", 1,
          "the helper keeps it for the webpatch interpose");
    // A prefix match on the directory would hand the insert to every one of these.
    keeps("/Applications/Steam.app/Contents/MacOS/steam_osx_helper", 0,
          "a name starting with steam_osx loses it");

    survives(NULL, NULL, "a null environment is left alone");

    char *plain[] = { (char *)"PATH=/bin", (char *)"HOME=/Users/x", NULL };
    survives(plain, NULL, "an environment without the insert is not copied");

    char *with[] = { (char *)"PATH=/bin",
                     (char *)"DYLD_INSERT_LIBRARIES=" NP_DYLIB,
                     (char *)"HOME=/Users/x", NULL };
    const char *without[] = { "PATH=/bin", "HOME=/Users/x", NULL };
    survives(with, without, "the insert is taken out and the rest kept in order");

    char *only[] = { (char *)"DYLD_INSERT_LIBRARIES=" NP_DYLIB, NULL };
    const char *empty[] = { NULL };
    survives(only, empty, "an environment of nothing but the insert comes back empty");

    // The compat tool's run script reads STEAM_DYLD_INSERT_LIBRARIES to build the overlay's
    // insert. A match that was not anchored at the start would eat it and take the overlay
    // out of every game launch.
    char *shim[] = { (char *)"STEAM_DYLD_INSERT_LIBRARIES=/overlay.dylib", NULL };
    survives(shim, NULL, "the overlay's own variable is not the insert");

    // The key has to carry its '=' or a longer name sharing the prefix goes too.
    char *longer[] = { (char *)"DYLD_INSERT_LIBRARIES_EXTRA=" NP_DYLIB, NULL };
    survives(longer, NULL, "a longer name sharing the prefix is not the insert");

    char *twice[] = { (char *)"DYLD_INSERT_LIBRARIES=" NP_DYLIB,
                      (char *)"PATH=/bin",
                      (char *)"DYLD_INSERT_LIBRARIES=" NP_DYLIB, NULL };
    const char *once[] = { "PATH=/bin", NULL };
    survives(twice, once, "every copy of the insert is taken out");

    char *blocked[] = { (char *)"PATH=/bin",
                        (char *)"SDL_JOYSTICK_BLACKLIST_DEVICES=0x05ac/0x0004",
                        (char *)"DYLD_INSERT_LIBRARIES=" NP_DYLIB, NULL };
    survives(blocked, once, "the SDL block list goes with the insert");

    char *alone[] = { (char *)"SDL_JOYSTICK_BLACKLIST_DEVICES=0x05ac/0x0004",
                      (char *)"PATH=/bin", NULL };
    survives(alone, once, "the SDL block list goes without the insert");

    char *sdl[] = { (char *)"SDL_JOYSTICK_BLACKLIST_DEVICES_EXCLUDED=0x05ac/0x0004",
                    (char *)"SDL_GAMECONTROLLER_IGNORE_DEVICES=0x045e/0x028e", NULL };
    survives(sdl, NULL, "other SDL lists stay");

    char *user_sdl[] = { (char *)"SDL_JOYSTICK_BLACKLIST_DEVICES=0x045e/0x028e", NULL };
    survives(user_sdl, NULL, "a block list that isn't ours stays");

    char *game[] = { (char *)"PATH=/bin", (char *)"DYLD_INSERT_LIBRARIES=" OVERLAY, NULL };
    survives(game, NULL, "a native game keeps the overlay");

    const char *overlay[] = { "PATH=/bin", "DYLD_INSERT_LIBRARIES=" OVERLAY, NULL };
    char *ahead[] = { (char *)"PATH=/bin",
                      (char *)"DYLD_INSERT_LIBRARIES=" NP_DYLIB ":" OVERLAY, NULL };
    survives(ahead, overlay, "ours goes from ahead of the overlay");

    char *behind[] = { (char *)"PATH=/bin",
                       (char *)"DYLD_INSERT_LIBRARIES=" OVERLAY ":" NP_DYLIB, NULL };
    survives(behind, overlay, "ours goes from behind the overlay");

    char *between[] = { (char *)"PATH=/bin",
                        (char *)"DYLD_INSERT_LIBRARIES=/S/steamloader.dylib:" NP_DYLIB
                                ":/S/gameoverlayrenderer.dylib", NULL };
    survives(between, overlay, "ours goes from the middle");

    char *lookalike[] = { (char *)"DYLD_INSERT_LIBRARIES=" NP_DYLIB ".bak", NULL };
    survives(lookalike, NULL, "a path that only starts like ours stays");

    const char *compat_only[] = { "STEAM_COMPAT_DATA_PATH=/c", NULL };
    char *compat[] = { (char *)"DYLD_INSERT_LIBRARIES=" OVERLAY,
                       (char *)"STEAM_COMPAT_DATA_PATH=/c", NULL };
    survives(compat, compat_only, "a compat launch loses the whole insert");

    char *compat_ours[] = { (char *)"STEAM_COMPAT_DATA_PATH=/c",
                            (char *)"DYLD_INSERT_LIBRARIES=" NP_DYLIB ":" OVERLAY, NULL };
    survives(compat_ours, compat_only, "a compat launch loses ours and the overlay");

    char *compat_plain[] = { (char *)"STEAM_COMPAT_DATA_PATH=/c", NULL };
    survives(compat_plain, NULL, "a compat launch without an insert is not copied");

    np_insert_entry = NULL;
    np_block_entry  = NULL;
    survives(with, NULL, "nothing is ours without an insert of our own");

    if (failures) {
        printf("==> spawn env: %d check(s) failed\n", failures);
        return 1;
    }
    printf("==> spawn env: steam_osx and Steam Helper keep the insert, native games keep the overlay\n");
    return 0;
}
