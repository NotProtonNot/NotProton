#include "check.h"
#include "../notproton_plugin.h"

#include <dlfcn.h>

static int child_load(const char *host, const char *plugin, const char *fixture, int fixture_first, int changed) {
    void *fx = NULL;
    if (strcmp(host, "-") != 0 && !dlopen(host, RTLD_NOW)) { printf("dlopen %s: %s\n", host, dlerror()); return 2; }
    if (fixture_first && !(fx = dlopen(fixture, RTLD_NOW))) { printf("dlopen %s: %s\n", fixture, dlerror()); return 2; }
    if (!dlopen(plugin, RTLD_NOW)) { printf("dlopen %s: %s\n", plugin, dlerror()); return 2; }
    if (!fx && !(fx = dlopen(fixture, RTLD_NOW))) { printf("dlopen %s: %s\n", fixture, dlerror()); return 2; }
    unsigned (*call)(int) = (unsigned (*)(int))dlsym(fx, "np_fixture_call");
    if (!call) { printf("no np_fixture_call\n"); return 2; }
    unsigned a = call(0), b = call(1), wa = changed ? 0x5a5a1235 : 0x5a5a1234, wb = changed ? 0x78 : 0x77;
    if (a != wa || b != wb) { printf("returned %#x and %#x, wanted %#x and %#x\n", a, b, wa, wb); return 1; }
    return 0;
}

static int child_version(const char *host) {
    if (!dlopen(host, RTLD_NOW)) { printf("dlopen %s: %s\n", host, dlerror()); return 2; }
    const struct np_plugin_api *(*get)(unsigned) =
        (const struct np_plugin_api *(*)(unsigned))dlsym(RTLD_DEFAULT, "np_plugin_api_get");
    if (!get) { printf("no np_plugin_api_get\n"); return 2; }
    const struct np_plugin_api *now = get(NP_PLUGIN_API_VERSION);
    if (!now || now->version != NP_PLUGIN_API_VERSION) { printf("version %u has no API\n", NP_PLUGIN_API_VERSION); return 1; }
    for (unsigned v = 1; v < NP_PLUGIN_API_VERSION; v++)
        if (get(v) != now) { printf("version %u has no API\n", v); return 1; }
    if (get(0) || get(NP_PLUGIN_API_VERSION + 1)) { printf("answered a version it doesn't have\n"); return 1; }
    return 0;
}

static void absent(const char *what, const char *out, const char *needle) {
    int ok = !strstr(out, needle);
    if (!ok) failures++;
    printf("  %s  %s\n", ok ? "PASS" : "FAIL", what);
}

int main(int argc, char **argv) {
    if (argc == 7 && strcmp(argv[1], "--load") == 0)
        return child_load(argv[2], argv[3], argv[4], atoi(argv[5]), atoi(argv[6]));
    if (argc == 3 && strcmp(argv[1], "--version") == 0) return child_version(argv[2]);
    if (argc != 5) {
        fprintf(stderr, "usage: apicheck <plugin-host.dylib> <sample plugin> <fixture dir> <scratch dir>\n");
        return 2;
    }
    const char *host = argv[1], *plugin = argv[2], *dir = argv[3], *scratch = argv[4];
    char self[1024], log[1024], xml[1024], bin[1024], out[16384];
    if (!realpath(argv[0], self)) return 2;
    snprintf(log, sizeof(log), "%s/api.log", scratch);
    snprintf(xml, sizeof(xml), "%s/xml/Versions/A/npfixture.dylib", dir);
    snprintf(bin, sizeof(bin), "%s/bin/Versions/A/npfixture.dylib", dir);

    char *first[] = { self, "--load", (char *)host, (char *)plugin, xml, "0", "1", NULL };
    int rc = run(first, log, out, sizeof(out));
    expect("api: an exported function is found, named and swapped", rc, out, 0,
           "_np_fixture_value is _np_fixture_value, swapped", 1);
    expect("api: a hidden function is found, named and swapped", rc, out, 0,
           "_fixture_hidden is _fixture_hidden, swapped", 1);
    expect("api: an XML Info.plist gives the version", rc, out, 0, "version 1.2.3", 1);
    absent("api: a watch for another path never fires", out, "fired for");

    char *late[] = { self, "--load", (char *)host, (char *)plugin, xml, "1", "1", NULL };
    rc = run(late, log, out, sizeof(out));
    expect("api: an image loaded before the plugin still reaches it", rc, out, 0, "_np_fixture_value is", 1);

    char *binary[] = { self, "--load", (char *)host, (char *)plugin, bin, "0", "1", NULL };
    rc = run(binary, log, out, sizeof(out));
    expect("api: a binary Info.plist gives the version", rc, out, 0, "version 4.5.6", 1);

    char *alone[] = { self, "--load", "-", (char *)plugin, xml, "0", "0", NULL };
    rc = run(alone, log, out, sizeof(out));
    expect("api: without the host a plugin changes nothing", rc, out, 0, "isn't loaded, not armed", 1);

    char *version[] = { self, "--version", (char *)host, NULL };
    rc = run(version, log, out, sizeof(out));
    expect("api: a host answers every version up to its own", rc, out, 0, NULL, 0);

    return finish("plugin API", "every function answers");
}
