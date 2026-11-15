#include "../feats/compatpage.c"

#include <limits.h>
#include <unistd.h>
#include <stdio.h>
#include <string.h>
#include <sys/stat.h>
#include "../util/file.h"

int np_log_level = 0;
FILE *np_log_file = NULL;

static np_compat_tool_info_t g_tools[4];
static size_t g_tool_count;

size_t np_compat_tools(np_compat_tool_info_t *out, size_t max) {
    size_t n = g_tool_count < max ? g_tool_count : max;
    memcpy(out, g_tools, n * sizeof *out);
    return n;
}

const char *np_compat_fallback_tool_name(void) { return "notproton-26.1"; }

size_t np_compat_fex_tools(const char **names, size_t max) {
    if (max) names[0] = "notproton-26.1-fex";
    return max ? 1 : 0;
}

size_t np_compat_tool_builds(const char **names, const char **builds, const char **archs, size_t max) {
    return 0;
}
void np_webpatch_set_tool_builds(const char *const *names, const char *const *builds,
                                 const char *const *archs, size_t count) {}

static int g_shape;
int np_webpatch_has_shape(const uint8_t *src, size_t len) { return g_shape; }

static char g_fallback[64], g_fex[64];
void np_webpatch_set_fallback_tool(const char *name) { snprintf(g_fallback, sizeof g_fallback, "%s", name); }
void np_webpatch_set_fex_tools(const char *const *names, size_t count) {
    snprintf(g_fex, sizeof g_fex, "%s", count ? names[0] : "");
}

static char g_pub_rosetta[NP_DEFAULTS_TEXT_MAX + 1], g_pub_fex[NP_DEFAULTS_TEXT_MAX + 1];
static int g_pub_unread, g_pub_calls;

void np_webpatch_set_defaults(const char *rosetta, const char *fex) {
    g_pub_calls++;
    g_pub_unread = !rosetta || !fex;
    snprintf(g_pub_rosetta, sizeof g_pub_rosetta, "%s", rosetta ? rosetta : "");
    snprintf(g_pub_fex, sizeof g_pub_fex, "%s", fex ? fex : "");
}

static np_webpatch_build_t g_pub[4];
static char g_pub_override[4][NP_DEFAULTS_TEXT_MAX + 1];
static size_t g_pub_count;

void np_webpatch_set_builds(const np_webpatch_build_t *builds, size_t count) {
    g_pub_count = count;
    for (size_t i = 0; i < count && i < 4; i++) {
        g_pub[i] = builds[i];
        if (builds[i].override) {
            snprintf(g_pub_override[i], sizeof g_pub_override[i], "%s", builds[i].override);
            g_pub[i].override = g_pub_override[i];
        }
    }
}

static int failures;

static void check(int ok, const char *what) {
    printf("  %s  %s\n", ok ? "ok  " : "FAIL", what);
    if (!ok) failures++;
}

static char g_dir[PATH_MAX];

static void path_of(char *buf, const char *name) { snprintf(buf, PATH_MAX, "%s/%s", g_dir, name); }

static void put_file(const char *name, const char *text) {
    char path[PATH_MAX];
    path_of(path, name);
    FILE *f = fopen(path, "w");
    fputs(text, f);
    fclose(f);
}

static void chmod_file(const char *name, mode_t mode) {
    char path[PATH_MAX];
    path_of(path, name);
    chmod(path, mode);
}
static void lock_file(const char *name) { chmod_file(name, 0); }
static void unlock_file(const char *name) { chmod_file(name, 0644); }

static void publish(void) { np_compatpage_publish((const uint8_t *)"", 0); }

int main(void) {
    const char *tmp = getenv("TMPDIR");
    char tmpl[PATH_MAX];
    snprintf(tmpl, sizeof tmpl, "%s/np-compatpage-XXXXXX", tmp && tmp[0] ? tmp : "/tmp");
    const char *home = mkdtemp(tmpl);
    if (!home) { perror("mkdtemp"); return 1; }
    setenv("HOME", home, 1);
    np_support_path(g_dir, sizeof g_dir, home, NULL);
    char lib[PATH_MAX];
    snprintf(lib, sizeof lib, "%s/Library", home);
    mkdir(lib, 0755);
    strcat(lib, "/Application Support");
    mkdir(lib, 0755);
    mkdir(g_dir, 0755);

    put_file("defaults-rosetta", "WINEMSYNC=1\n");
    put_file("defaults-fex", "MTL_HUD_ENABLED=0\n");
    put_file("defaults-override-26.1-fex", "WINEMSYNC=0\n");
    put_file("defaults-override-25.0-rosetta", "");
    g_tools[0] = (np_compat_tool_info_t){ "notproton-26.1-fex", "26.1", "CrossOver 26.1 (FEX)", true };
    g_tools[1] = (np_compat_tool_info_t){ "notproton-26.1", "26.1", "CrossOver 26.1", false };
    g_tools[2] = (np_compat_tool_info_t){ "notproton-25.0", "25.0", "CrossOver 25", false };
    g_tool_count = 3;

    publish();
    check(strcmp(g_fallback, "notproton-26.1") == 0 && strcmp(g_fex, "notproton-26.1-fex") == 0,
          "every chunk gets the fallback and the FEX tools");
    check(g_pub_calls == 0, "a chunk without a compat UI reads no defaults");

    g_shape = 1;
    publish();
    check(!g_pub_unread && strcmp(g_pub_rosetta, "WINEMSYNC=1\n") == 0 &&
          strcmp(g_pub_fex, "MTL_HUD_ENABLED=0\n") == 0, "the page gets each runner's set");
    check(g_pub_count == 3 && g_pub[0].fex && strcmp(g_pub[0].tool, "notproton-26.1-fex") == 0 &&
          strcmp(g_pub[0].build, "26.1") == 0 && strcmp(g_pub[0].label, "CrossOver 26.1 (FEX)") == 0,
          "the page gets every tool with its build and label");
    check(g_pub[0].override && strcmp(g_pub[0].override, "WINEMSYNC=0\n") == 0,
          "a build's own set goes with it");
    check(!g_pub[1].override, "a build without its own set gets none");
    check(g_pub[2].override && g_pub[2].override[0] == '\0', "an empty own set stays empty, not none");

    lock_file("defaults-fex");
    publish();
    check(g_pub_unread, "a runner's set that cannot be read gives the page nothing to save over");
    unlock_file("defaults-fex");
    lock_file("defaults-override-26.1-fex");
    publish();
    check(!g_pub_unread && g_pub_count == 2 && strcmp(g_pub[0].tool, "notproton-26.1") == 0,
          "a build's own set that cannot be read leaves only that build out");
    unlock_file("defaults-override-26.1-fex");

    g_tool_count = 0;
    publish();
    check(g_pub_count == 0 && !g_pub_unread, "no tools give the page no builds");

    char cmd[PATH_MAX + 16];
    snprintf(cmd, sizeof cmd, "rm -rf '%s'", home);
    system(cmd);

    if (failures) {
        printf("==> compatpage: %d failed\n", failures);
        return 1;
    }
    printf("==> compatpage: every chunk gets its tools, a compat UI also gets the defaults it can save over\n");
    return 0;
}
