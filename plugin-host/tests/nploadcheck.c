#include "check.h"

#include <dlfcn.h>
#include <mach-o/dyld.h>
#include <unistd.h>

static int load(const char *npload) {
    void *h = dlopen(npload, RTLD_NOW);
    int (*init)(void) = h ? (int (*)(void))dlsym(h, "__wine_unix_lib_init") : NULL;
    if (!init) {
        dprintf(1, "no init: %s\n", dlerror());
        return 2;
    }
    int rc = init();
    dprintf(1, "init %d\n", rc);
    return rc ? 1 : 0;
}

int main(int argc, char **argv) {
    if (argc == 3 && strcmp(argv[1], "--load") == 0) return load(argv[2]);
    if (argc != 3) {
        fprintf(stderr, "usage: nploadcheck <npload.so> <fixture dir>\n");
        return 2;
    }
    char self[1024], log[1100], out[8192];
    uint32_t size = sizeof(self);
    if (_NSGetExecutablePath(self, &size) != 0) return 2;
    const char *d = argv[2];
    snprintf(log, sizeof(log), "%s/npload.log", d);
    char *a[] = { self, "--load", argv[1], NULL };
    char libs[4096], shim[1100];
    snprintf(shim, sizeof(shim), "%s/load-shim.dylib", d);

    struct {
        const char *what, *libs, *shim, *want;
        int lines;
    } cases[] = {
        { "the list loads in order, then the shim installs", "%s/load-shim.dylib:%s/load-a.dylib:%s/load-b.dylib", shim,
          "loaded shim\nloaded a\nloaded b\ninstalled\ninit 0\n", 5 },
        { "a shim that isn't on the list is not loaded for the install", "%s/load-a.dylib", shim,
          "loaded a\ninit 0\n", 2 },
        { "no shim named, no install", "%s/load-shim.dylib:%s/load-a.dylib", NULL,
          "loaded shim\nloaded a\ninit 0\n", 3 },
        { "a missing library is reported and the rest still load", "%s/absent.dylib:%s/load-a.dylib:%s/load-shim.dylib", shim,
          "loaded a\nloaded shim\ninstalled\ninit 0\n", 5 },
        { "empty entries are skipped", "::%s/load-a.dylib::%s/load-b.dylib:", NULL,
          "loaded a\nloaded b\ninit 0\n", 3 },
        { "a plugin without the install export is left alone", "%s/load-a.dylib", "a",
          "loaded a\ninit 0\n", 2 },
        { "no list, nothing loads", NULL, shim, "init 0\n", 1 },
        { "an empty list, nothing loads", "", "", "init 0\n", 1 },
    };
    for (size_t i = 0; i < sizeof(cases) / sizeof(*cases); i++) {
        if (cases[i].libs) {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wformat-nonliteral"
            snprintf(libs, sizeof(libs), cases[i].libs, d, d, d);
#pragma clang diagnostic pop
            setenv("NOTPROTON_PLUGIN_LIBS", libs, 1);
        } else {
            unsetenv("NOTPROTON_PLUGIN_LIBS");
        }
        if (cases[i].shim && strcmp(cases[i].shim, "a") == 0) {
            snprintf(libs, sizeof(libs), "%s/load-a.dylib", d);
            setenv("NOTPROTON_OVERLAY_SHIM", libs, 1);
        } else if (cases[i].shim) {
            setenv("NOTPROTON_OVERLAY_SHIM", cases[i].shim, 1);
        } else {
            unsetenv("NOTPROTON_OVERLAY_SHIM");
        }
        int rc = run(a, log, out, sizeof(out));
        int ok = count_of(out, "\n") == cases[i].lines;
        expect(cases[i].what, ok ? rc : 98, out, 0, cases[i].want, 0);
    }
    setenv("NOTPROTON_PLUGIN_LIBS", "/absent.dylib", 1);
    unsetenv("NOTPROTON_OVERLAY_SHIM");
    expect("the report names the loader", run(a, log, out, sizeof(out)), out, 0, "npload: ", 1);

    return finish("npload", "the list loads in order and only a listed shim installs");
}
