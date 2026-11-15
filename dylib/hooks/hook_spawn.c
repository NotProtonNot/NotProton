// Strips our own insert and SDL block list from child processes
#include "hooks.h"
#include "../util/log.h"

#include <spawn.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

extern int   DobbyHook(void *address, void *replace_call, void **origin_call);
extern void *DobbySymbolResolver(const char *image_name, const char *symbol_name);

typedef int (*fn_execve)(const char *path, char *const argv[], char *const envp[]);
typedef int (*fn_posix_spawn)(pid_t *pid, const char *path,
                             const posix_spawn_file_actions_t *fa,
                             const posix_spawnattr_t *attr,
                             char *const argv[], char *const envp[]);

static fn_execve      orig_execve;
static fn_posix_spawn orig_posix_spawn;
static fn_posix_spawn orig_posix_spawnp;

#define NP_INSERT_KEY "DYLD_INSERT_LIBRARIES="

// steam_osx re-execs itself and needs the insert for hooks. Steam Helper runs
// CEF and needs it for the webpatch fopen interpose, strips elsewhere
static int np_target_keeps_insert(const char *path) {
    if (!path)
        return 1;
    const char *base = strrchr(path, '/');
    base = base ? base + 1 : path;
    return strcmp(base, "steam_osx") == 0
        || strcmp(base, "Steam Helper") == 0;
}

// LaunchServices hands the caller's environment to every app it opens, so the insert
// lives here instead and only goes back into steam_osx and Steam Helper
static char *np_insert_entry;

// The SDL block list stops Steam from seeing a second, generic copy of the Steam Controller.
// This solves double input issues.
static char *np_block_entry;

static int np_is_insert(const char *entry) {
    return strncmp(entry, NP_INSERT_KEY, strlen(NP_INSERT_KEY)) == 0;
}

static char **np_with_insert(char *const envp[]) {
    if (!np_insert_entry)
        return NULL;

    int count = 0;
    if (envp) {
        for (; envp[count]; count++) {
            if (np_is_insert(envp[count]))
                return NULL;
        }
    }

    char **full = malloc(sizeof(char *) * (size_t)(count + 2));
    if (!full) {
        NP_WARN("[spawn] cannot allocate an environment with the insert, child starts without it");
        return NULL;
    }
    for (int i = 0; i < count; i++)
        full[i] = envp[i];
    full[count] = np_insert_entry;
    full[count + 1] = NULL;
    return full;
}

static char *np_entry(const char *name) {
    const char *value = getenv(name);
    if (!value)
        return NULL;

    size_t len = strlen(name) + strlen(value) + 2;
    char *entry = malloc(len);
    if (entry)
        snprintf(entry, len, "%s=%s", name, value);
    return entry;
}

static void np_remember_ours(void) {
    if (!np_insert_entry)
        np_insert_entry = np_entry("DYLD_INSERT_LIBRARIES");
    if (!np_block_entry)
        np_block_entry = np_entry("SDL_JOYSTICK_BLACKLIST_DEVICES");
}

static void np_take_insert(void) {
    if (!getenv("DYLD_INSERT_LIBRARIES"))
        return;
    if (!np_insert_entry) {
        NP_WARN("[spawn] cannot hold the insert, apps opened from here inherit it");
        return;
    }
    unsetenv("DYLD_INSERT_LIBRARIES");
    NP_LOG("[spawn] insert taken out of the environment");
}

static int np_list_has(const char *list, const char *part, size_t n) {
    if (!n)
        return 0;
    for (;;) {
        const char *end = strchr(list, ':');
        size_t len = end ? (size_t)(end - list) : strlen(list);
        if (len == n && strncmp(list, part, n) == 0)
            return 1;
        if (!end)
            return 0;
        list = end + 1;
    }
}

static int np_drop_ours(const char *value, char *out) {
    const char *ours = np_insert_entry + strlen(NP_INSERT_KEY);
    int dropped = 0;
    char *o = out;
    for (;;) {
        const char *end = strchr(value, ':');
        size_t n = end ? (size_t)(end - value) : strlen(value);
        if (np_list_has(ours, value, n)) {
            dropped++;
        } else if (n) {
            if (o != out)
                *o++ = ':';
            memcpy(o, value, n);
            o += n;
        }
        if (!end)
            break;
        value = end + 1;
    }
    *o = '\0';
    return dropped;
}

// Steam hands native games its own overlay insert, that part has to get through
static char **np_without_insert(char *const envp[]) {
    if (!envp || (!np_insert_entry && !np_block_entry))
        return NULL;

    size_t count = 0;
    size_t room = 0;
    int compat = 0;
    for (; envp[count]; count++) {
        if (np_is_insert(envp[count]))
            room += strlen(envp[count]) + 1;
        // The run script rebuilds the overlay from STEAM_DYLD_INSERT_LIBRARIES, its shell gets no insert
        if (strncmp(envp[count], "STEAM_COMPAT_DATA_PATH=", 23) == 0)
            compat = 1;
    }

    char **clean = malloc(sizeof(char *) * (count + 1) + room);
    if (!clean) {
        NP_WARN("[spawn] cannot allocate a stripped environment, insert passed through");
        return NULL;
    }
    char *spare = (char *)(clean + count + 1);
    size_t key = strlen(NP_INSERT_KEY);

    int changed = 0;
    size_t j = 0;
    for (size_t i = 0; i < count; i++) {
        char *entry = envp[i];
        if (np_block_entry && strcmp(entry, np_block_entry) == 0) {
            changed = 1;
            continue;
        }
        if (compat && np_is_insert(entry)) {
            changed = 1;
            continue;
        }
        if (np_insert_entry && np_is_insert(entry)) {
            memcpy(spare, NP_INSERT_KEY, key);
            if (np_drop_ours(entry + key, spare + key)) {
                changed = 1;
                if (spare[key]) {
                    clean[j++] = spare;
                    spare += strlen(spare) + 1;
                }
                continue;
            }
        }
        clean[j++] = entry;
    }
    clean[j] = NULL;

    if (!changed) {
        free(clean);
        return NULL;
    }
    return clean;
}

static int np_hook_execve(const char *path, char *const argv[], char *const envp[]) {
    int keep = np_target_keeps_insert(path);
    char **clean = keep ? np_with_insert(envp) : np_without_insert(envp);
    if (!clean)
        return orig_execve(path, argv, envp);

    NP_DBG("[spawn] execve '%s' %s the insert", path, keep ? "with" : "without");
    int rc = orig_execve(path, argv, (char *const *)clean);
    // Only reached when the exec failed, since a successful one replaced this image.
    free(clean);
    return rc;
}

static int np_spawn_filtered(fn_posix_spawn orig, const char *api,
                                   pid_t *pid, const char *path,
                                   const posix_spawn_file_actions_t *fa,
                                   const posix_spawnattr_t *attr,
                                   char *const argv[], char *const envp[]) {
    int keep = np_target_keeps_insert(path);
    char **clean = keep ? np_with_insert(envp) : np_without_insert(envp);
    if (!clean)
        return orig(pid, path, fa, attr, argv, envp);

    NP_DBG("[spawn] %s '%s' %s the insert", api, path, keep ? "with" : "without");
    int rc = orig(pid, path, fa, attr, argv, (char *const *)clean);
    free(clean);
    return rc;
}

static int np_hook_posix_spawn(pid_t *pid, const char *path,
                               const posix_spawn_file_actions_t *fa,
                               const posix_spawnattr_t *attr,
                               char *const argv[], char *const envp[]) {
    return np_spawn_filtered(orig_posix_spawn, "posix_spawn",
                                   pid, path, fa, attr, argv, envp);
}

static int np_hook_posix_spawnp(pid_t *pid, const char *path,
                                const posix_spawn_file_actions_t *fa,
                                const posix_spawnattr_t *attr,
                                char *const argv[], char *const envp[]) {
    return np_spawn_filtered(orig_posix_spawnp, "posix_spawnp",
                                   pid, path, fa, attr, argv, envp);
}

static int np_hook_symbol(const char *sym, void *repl, void **orig) {
    void *addr = DobbySymbolResolver("libsystem_kernel.dylib", sym);
    if (!addr)
        addr = DobbySymbolResolver(NULL, sym);
    if (!addr) {
        NP_WARN("[spawn] %s: unresolved, children keep the insert", sym);
        return 0;
    }

    int rc = DobbyHook(addr, repl, orig);
    if (rc == 0) {
        NP_LOG("[spawn] %s: hooked @ %p", sym, addr);
        return 1;
    }
    NP_WARN("[spawn] %s: DobbyHook failed rc=%d, children keep the insert", sym, rc);
    return 0;
}

void np_hooks_spawn_install(void) {
    if (np_hooks_env_lists_label("NOTPROTON_DISABLE", "spawn")) {
        NP_WARN("[spawn] DISABLED via NOTPROTON_DISABLE, children keep the insert");
        return;
    }

    np_remember_ours();
    int hooked = np_hook_symbol("execve",       (void *)np_hook_execve,       (void **)&orig_execve)
               + np_hook_symbol("posix_spawn",  (void *)np_hook_posix_spawn,  (void **)&orig_posix_spawn)
               + np_hook_symbol("posix_spawnp", (void *)np_hook_posix_spawnp, (void **)&orig_posix_spawnp);

    // Without every hook in place, a steam_osx re-exec could start without the dylib
    if (hooked == 3)
        np_take_insert();
}
