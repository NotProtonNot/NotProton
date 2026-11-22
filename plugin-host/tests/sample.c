#include "../notproton_plugin.h"

#include <stdio.h>

#define TAG "sample"

static const struct np_plugin_api *api;
static uintptr_t real_value, real_hidden;

static unsigned value_plus_one(void) { return ((unsigned (*)(void))real_value)() + 1; }
static unsigned hidden_plus_one(void) { return ((unsigned (*)(void))real_hidden)() + 1; }

static int swap(const struct mach_header_64 *mh, intptr_t slide, const char *name, uintptr_t *real,
                uintptr_t replacement) {
    uintptr_t *slot = NULL;
    if (!(*real = api->symbol(mh, slide, name))) {
        api->log(TAG, "no %s", name);
        return 0;
    }
    const char *back = api->symbol_name(mh, slide, *real);
    int n = api->count_pointers(mh, slide, *real, &slot);
    if (n != 1 || !api->swap_pointer(slot, *real, replacement)) {
        api->log(TAG, "%s: %d pointers, not swapped", name, n);
        return 0;
    }
    if (api->swap_pointer(slot, *real, replacement)) {
        api->log(TAG, "%s: swapped twice", name);
        return 0;
    }
    api->log(TAG, "%s is %s, swapped", name, back ? back : "nameless");
    return 1;
}

static void arm(const struct mach_header_64 *mh, intptr_t slide, const char *path) {
    char version[32];
    const char *hidden = api->symbol_name(mh, slide, api->symbol(mh, slide, "_fixture_hidden"));
    uintptr_t none = 0;
    if (!swap(mh, slide, "_np_fixture_value", &real_value, (uintptr_t)value_plus_one)
        || !api->redirect(mh, slide, "_fixture_hidden", (uintptr_t)hidden_plus_one, &real_hidden))
        return;
    api->log(TAG, "%s redirected", hidden ? hidden : "nameless");
    if (!api->redirect(mh, slide, "_np_fixture_call", (uintptr_t)hidden_plus_one, &none)
        && !api->redirect(mh, slide, "_fixture_absent", (uintptr_t)hidden_plus_one, &none) && !none)
        api->log(TAG, "redirects without one pointer are refused");
    if (api->bundle_short_version(path, version, sizeof(version))) api->log(TAG, "version %s", version);
    else api->log(TAG, "no version");
}

static void never(const struct mach_header_64 *mh, intptr_t slide, const char *path) {
    (void)mh;
    (void)slide;
    api->log(TAG, "fired for %s", path);
}

__attribute__((constructor))
static void sample_init(void) {
    if (!(api = np_plugin_api())) {
        fprintf(stderr, TAG ": plugin-host.dylib isn't loaded, not armed\n");
        return;
    }
    api->log(TAG, "patch changed %d", api->patch(TAG, "npfixture.dylib: b8 78=79 56 5a 5a c3"));
    api->log(TAG, "bad patch gave %d", api->patch(TAG, "npfixture.dylib: b8 78=79; npfixture.dylib: b8 zz"));
    api->on_first_image("npfixture.dylib", "/Versions/A/", arm);
    api->on_first_image("npfixture.dylib", "/elsewhere/", never);
}
