// Plugin API
#ifndef NOTPROTON_PLUGIN_H
#define NOTPROTON_PLUGIN_H

#include <dlfcn.h>
#include <mach-o/loader.h>
#include <stddef.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>

#define NP_PLUGIN_API_VERSION 1

typedef void (*np_image_fn)(const struct mach_header_64 *mh, intptr_t slide, const char *path);

struct np_plugin_api {
    unsigned version;
    void (*log)(const char *tag, const char *fmt, ...) __attribute__((format(printf, 2, 3)));
    int (*on_first_image)(const char *name, const char *path_contains, np_image_fn fn);
    uintptr_t (*symbol)(const struct mach_header_64 *mh, intptr_t slide, const char *name);
    const char *(*symbol_name)(const struct mach_header_64 *mh, intptr_t slide, uintptr_t addr);
    int (*count_pointers)(const struct mach_header_64 *mh, intptr_t slide, uintptr_t value, uintptr_t **first);
    int (*swap_pointer)(uintptr_t *slot, uintptr_t expect, uintptr_t value);
    int (*bundle_short_version)(const char *image_path, char *out, size_t len);
    int (*patch)(const char *tag, const char *patches);
    int (*redirect)(const struct mach_header_64 *mh, intptr_t slide, const char *symbol, uintptr_t replacement,
                    uintptr_t *original);
};

static inline const struct np_plugin_api *np_plugin_api(void) {
    typedef const struct np_plugin_api *(*np_get_fn)(unsigned);
    np_get_fn get = (np_get_fn)dlsym(RTLD_DEFAULT, "np_plugin_api_get");
    if (!get) {
        const char *home = getenv("HOME");
        char path[1024];
        if (!home || !*home) return NULL;
        snprintf(path, sizeof(path), "%s/Library/Application Support/notproton/plugin-host.dylib", home);
        void *host = dlopen(path, RTLD_NOW | RTLD_GLOBAL);
        if (!host) return NULL;
        get = (np_get_fn)dlsym(host, "np_plugin_api_get");
    }
    return get ? get(NP_PLUGIN_API_VERSION) : NULL;
}

#endif
