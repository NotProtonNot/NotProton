// Give shortcuts nice icons instead of the generic icon Valve sets
#include "hooks.h"
#include "../feats/compat.h"
#include "../util/log.h"

#include <crt_externs.h>
#include <dispatch/dispatch.h>
#include <dlfcn.h>
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <signal.h>
#include <spawn.h>
#include <stdio.h>
#include <string.h>
#include <sys/wait.h>

#define NP_APP_KIND_OFF 0x3c
#define NP_APP_KIND_DLC 0x20
#define NP_GAME_ID_SHORTCUT 0x2000000ull

typedef uint64_t (*np_create_fn)(void *app, uint64_t desktop, uint64_t unused);
typedef uint32_t (*np_app_id_fn)(void *app);

static np_create_fn     g_create_orig;
static dispatch_queue_t g_queue;
static char             g_client[PATH_MAX];

static void update_icons(void *ctx) {
    uint32_t app_id = (uint32_t)(uintptr_t)ctx;
    const char *tool = np_compat_tool_dir();
    if (!tool) return;

    char run[PATH_MAX], id[16], game[24];
    snprintf(run, sizeof(run), "%s/run", tool);
    snprintf(id, sizeof(id), "%u", app_id);
    snprintf(game, sizeof(game), "%llu", (unsigned long long)app_id << 32 | NP_GAME_ID_SHORTCUT);

    posix_spawn_file_actions_t actions;
    posix_spawnattr_t attr;
    sigset_t none, all;
    sigemptyset(&none);
    sigfillset(&all);
    if (posix_spawn_file_actions_init(&actions) != 0) return;
    if (posix_spawnattr_init(&attr) != 0) {
        posix_spawn_file_actions_destroy(&actions);
        return;
    }
    posix_spawn_file_actions_addopen(&actions, STDIN_FILENO, "/dev/null", O_RDONLY, 0);
    posix_spawn_file_actions_addopen(&actions, STDOUT_FILENO, "/dev/null", O_WRONLY, 0);
    posix_spawn_file_actions_addopen(&actions, STDERR_FILENO, "/dev/null", O_WRONLY, 0);
    posix_spawnattr_setsigmask(&attr, &none);
    posix_spawnattr_setsigdefault(&attr, &all);
    posix_spawnattr_setflags(&attr, POSIX_SPAWN_SETSIGMASK | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_CLOEXEC_DEFAULT);
    char *icons[] = { "/bin/sh", run, "shortcut-icons", id, g_client, NULL };
    char *fix[] = { "/bin/sh", run, "shortcut-fix", id, game, g_client, NULL };
    char **argv = app_id > INT32_MAX ? fix : icons;
    pid_t pid;
    int rc = posix_spawn(&pid, argv[0], &actions, &attr, argv, *_NSGetEnviron());
    posix_spawnattr_destroy(&attr);
    posix_spawn_file_actions_destroy(&actions);
    if (rc != 0) {
        NP_WARN("shortcut-bundle: cannot run the icon update for %u (%d)", app_id, rc);
        return;
    }
    int status = 0;
    pid_t done;
    while ((done = waitpid(pid, &status, 0)) < 0 && errno == EINTR) {}
    if (done == pid && WIFEXITED(status))
        NP_LOG("shortcut-bundle: icon update for %u exited %d", app_id, WEXITSTATUS(status));
    else
        NP_WARN("shortcut-bundle: icon update for %u ended without an exit status", app_id);
}

void np_hooks_shortcut_bundle_bind(const struct mach_header_64 *steamui) {
    Dl_info info = {0};
    const char *slash = dladdr(steamui, &info) && info.dli_fname ? strrchr(info.dli_fname, '/') : NULL;
    if (!slash || slash - info.dli_fname >= (ptrdiff_t)sizeof(g_client)) {
        NP_WARN("shortcut-bundle: steamui path unknown, shortcut icons stay stock");
        return;
    }
    snprintf(g_client, sizeof(g_client), "%.*s", (int)(slash - info.dli_fname), info.dli_fname);
    g_queue = dispatch_queue_create("com.notproton.shortcut-bundle", DISPATCH_QUEUE_SERIAL);
}

static uint64_t np_shortcut_create(void *app, uint64_t desktop, uint64_t unused) {
    if (!g_create_orig) return 0;
    uint64_t ret = g_create_orig(app, desktop, unused);
    if (!ret || !app || *(const uint32_t *)((const char *)app + NP_APP_KIND_OFF) == NP_APP_KIND_DLC)
        return ret;

    // Vtable slot 0 returns the app ID. Steam writes run.sh with %d, so a non-Steam game's
    // ID, which is past INT32_MAX, comes out negative and opens the wrong app.
    uint32_t app_id = (**(np_app_id_fn **)app)(app);
    if (!g_queue || !app_id || !np_compat_app_runs_tool(app_id)) return ret;
    dispatch_async_f(g_queue, (void *)(uintptr_t)app_id, update_icons);
    return ret;
}

static np_patch_entry_t g_hooks[] = {
    {
        .label      = "shortcut-bundle-icon",
        .signature  = "steamui::ShortcutCreate",
        .entry      = (void *)np_shortcut_create,
        .trampoline = (void **)&g_create_orig,
        .mode       = NP_PATCH_REPLACE,
    },
};

int np_hooks_shortcut_bundle_count(void) {
    return (int)(sizeof(g_hooks) / sizeof(g_hooks[0]));
}

np_patch_entry_t *np_hooks_shortcut_bundle_defs(void) {
    return g_hooks;
}
