// Plugin loader for FEX
#include <dlfcn.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

__attribute__((visibility("default"))) int __wine_unix_lib_init(void) {
    const char *libs = getenv("NOTPROTON_PLUGIN_LIBS");
    char path[4096];
    for (const char *p = libs; p && *p;) {
        const char *end = strchr(p, ':');
        size_t len = end ? (size_t)(end - p) : strlen(p);
        if (len && len < sizeof(path)) {
            memcpy(path, p, len);
            path[len] = 0;
            if (!dlopen(path, RTLD_NOW)) fprintf(stderr, "npload: %s\n", dlerror());
        }
        p = end ? end + 1 : p + len;
    }
    // dyld skips interposes on a dlopen.
    const char *shim = getenv("NOTPROTON_OVERLAY_SHIM");
    void *loaded = shim && *shim ? dlopen(shim, RTLD_NOW | RTLD_NOLOAD) : NULL;
    void (*install)(void) = loaded ? (void (*)(void))dlsym(loaded, "np_overlay_shim_install") : NULL;
    if (install) install();
    return 0;
}
