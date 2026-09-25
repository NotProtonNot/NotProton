// Enables selecting/using Windows applications as non-steam shortcuts inside the Steam client
#include "hooks.h"
#include "../util/log.h"

#include <string.h>
#include <strings.h>

typedef int (*np_ext_matches_fn)(const char *const *path_slot,
                                 const char *const *want_slot);

static np_ext_matches_fn g_ext_matches_orig;

static const char *file_extension(const char *path) {
    if (!path) return NULL;

    const char *dot = NULL;
    for (const char *p = path; *p; p++) {
        if (*p == '/')      dot = NULL;
        else if (*p == '.') dot = p;
    }
    return (dot && dot[1]) ? dot + 1 : NULL;
}

static int np_ext_matches(const char *const *path_slot, const char *const *want_slot) {
    if (g_ext_matches_orig && g_ext_matches_orig(path_slot, want_slot))
        return 1;

    const char *want = want_slot ? *want_slot : NULL;
    const char *path = path_slot ? *path_slot : NULL;
    const char *ext  = file_extension(path);

    if (!want || !ext)
        return 0;

    if (!g_ext_matches_orig && strcasecmp(ext, want) == 0)
        return 1;

    if (strcasecmp(want, "app") != 0 || strcasecmp(ext, "exe") != 0)
        return 0;

    NP_DBG("shortcut: treating '%s' as shortcut-able where only .app is asked for", path);
    return 1;
}

static np_patch_entry_t g_hooks[] = {
    {
        .label            = "shortcut-exe",
        .signature        = "steamui::ShortcutExtensionMatches",
        .entry            = (void *)np_ext_matches,
        .trampoline       = (void **)&g_ext_matches_orig,
        .tolerate_missing = 0,
        .mode             = NP_PATCH_REPLACE,
    },
};

int np_hooks_shortcut_count(void) {
    return (int)(sizeof(g_hooks) / sizeof(g_hooks[0]));
}

np_patch_entry_t *np_hooks_shortcut_defs(void) {
    return g_hooks;
}
