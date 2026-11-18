// A Mac badge for every installed game.
//
// The library reads what the last pass saved, and a thread behind it saves a fresh set,
// so a big library never holds up Steam's start.
#include "catalog.h"
#include "badge.h"
#include "game.h"
#include "verdict.h"
#include "../util/file.h"
#include "../util/log.h"

#include <dirent.h>
#include <errno.h>
#include <limits.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

#define NP_CATALOG_LIBRARIES 16
#define NP_CATALOG_APPS      4096
#define NP_CATALOG_FILE      "badges"
#define NP_CATALOG_OFF_FILE  "no-mac-badges"
#define NP_CATALOG_LINE      512
// How long the library waits for a fresh pass before taking the last one. A pass over
// scans that are already saved takes a few milliseconds; this covers a first start.
#define NP_CATALOG_WAIT_MS   2500
// Bumped whenever what a saved scan holds changes, so older ones are scanned again.
#define NP_SCAN_FORMAT       2

static const char *vdf_value(const char *line, const char *key, char *out, size_t size) {
    const char *at = strstr(line, key);
    if (!at) return NULL;
    at = strchr(at + strlen(key), '"');
    if (!at) return NULL;
    const char *end = strchr(++at, '"');
    if (!end || (size_t)(end - at) >= size) return NULL;
    memcpy(out, at, (size_t)(end - at));
    out[end - at] = '\0';
    return out;
}

// Calls fn on each line of a small text file.
static void each_line(const char *path, void (*fn)(const char *line, void *ctx), void *ctx) {
    size_t len = 0;
    uint8_t *text = np_read_file_max(path, 1u << 20, 0, &len);
    if (!text) return;
    char line[2048];
    for (size_t at = 0; at < len; ) {
        size_t n = 0;
        while (at + n < len && text[at + n] != '\n' && n < sizeof line - 1) n++;
        memcpy(line, text + at, n);
        line[n] = '\0';
        at += n + 1;
        fn(line, ctx);
    }
    free(text);
}

typedef struct { char paths[NP_CATALOG_LIBRARIES][PATH_MAX]; int count; } libraries_t;

static void take_library(const char *line, void *ctx) {
    libraries_t *libs = ctx;
    char value[PATH_MAX];
    if (libs->count >= NP_CATALOG_LIBRARIES || !vdf_value(line, "\"path\"", value, sizeof value)) return;
    // Steam doubles the backslashes in paths it writes.
    char *w = value;
    for (const char *r = value; *r; r++) {
        if (*r == '\\' && r[1]) r++;
        *w++ = *r;
    }
    *w = '\0';
    for (int i = 0; i < libs->count; i++)
        if (strcmp(libs->paths[i], value) == 0) return;
    if (value[0] == '/') snprintf(libs->paths[libs->count++], PATH_MAX, "%s", value);
}

static void read_libraries(const char *steam_root, libraries_t *libs) {
    libs->count = 0;
    snprintf(libs->paths[libs->count++], PATH_MAX, "%s", steam_root);
    char path[PATH_MAX];
    snprintf(path, sizeof path, "%s/steamapps/libraryfolders.vdf", steam_root);
    each_line(path, take_library, libs);
}

typedef struct {
    unsigned appid;
    char     install[PATH_MAX];
    char     compatdata[PATH_MAX];
    char     stamp[64];   // build and update time, so a patched game is scanned again
} app_t;

typedef struct { char dir[PATH_MAX], build[32], updated[32]; } manifest_t;

static void take_manifest(const char *line, void *ctx) {
    manifest_t *m = ctx;
    if (!m->dir[0]) vdf_value(line, "\"installdir\"", m->dir, sizeof m->dir);
    if (!m->build[0]) vdf_value(line, "\"buildid\"", m->build, sizeof m->build);
    if (!m->updated[0]) vdf_value(line, "\"LastUpdated\"", m->updated, sizeof m->updated);
}

static int read_manifest(const char *steamapps, const char *name, app_t *app) {
    unsigned appid = 0;
    if (sscanf(name, "appmanifest_%u.acf", &appid) != 1 || !appid) return 0;
    char path[PATH_MAX];
    if ((size_t)snprintf(path, sizeof path, "%s/%s", steamapps, name) >= sizeof path) return 0;
    manifest_t m = { "", "", "" };
    each_line(path, take_manifest, &m);
    if (!m.dir[0]) return 0;
    app->appid = appid;
    snprintf(app->stamp, sizeof app->stamp, "%s-%s", m.build[0] ? m.build : "0", m.updated[0] ? m.updated : "0");
    if ((size_t)snprintf(app->install, sizeof app->install, "%s/common/%s", steamapps, m.dir)
        >= sizeof app->install) return 0;
    snprintf(app->compatdata, sizeof app->compatdata, "%s/compatdata/%u", steamapps, appid);
    return 1;
}

static void support_file(char *buf, size_t size, const char *name) {
    const char *home = np_home_dir();
    np_support_path(buf, size, home ? home : "", name);
}

// A game's scan is kept beside its prefix, so an unchanged game is not walked twice.
static int cached_scan(const app_t *app, np_game_t *game) {
    char path[PATH_MAX], stamp[64] = "";
    snprintf(path, sizeof path, "%s/notproton-scan", app->compatdata);
    size_t len = 0;
    uint8_t *text = np_read_file_max(path, 4096, 0, &len);
    if (!text) return 0;
    int format = 0, native = 0, ac = 0, launcher = 0;
    int ok = sscanf((const char *)text, "%d\n%63s\n%d\n%d\n%d", &format, stamp, &native, &ac, &launcher) == 5
          && format == NP_SCAN_FORMAT && strcmp(stamp, app->stamp) == 0
          && ac >= NP_AC_NONE && ac <= NP_AC_VANGUARD && launcher >= NP_LAUNCHER_NONE
          && launcher <= NP_LAUNCHER_ROCKSTAR;
    free(text);
    if (!ok) return 0;
    *game = (np_game_t){ 1, native != 0, (np_anticheat_t)ac, (np_launcher_t)launcher };
    return 1;
}

static void save_scan(const app_t *app, const np_game_t *game) {
    struct stat sb;
    if (stat(app->compatdata, &sb) != 0 || !S_ISDIR(sb.st_mode)) return;
    char path[PATH_MAX], tmp[PATH_MAX];
    snprintf(path, sizeof path, "%s/notproton-scan", app->compatdata);
    snprintf(tmp, sizeof tmp, "%s.new", path);
    FILE *f = fopen(tmp, "w");
    if (!f) return;
    fprintf(f, "%d\n%s\n%d\n%d\n%d\n", NP_SCAN_FORMAT, app->stamp, game->native,
            (int)game->anticheat, (int)game->launcher);
    int ok = fflush(f) == 0;
    fclose(f);
    if (!ok || rename(tmp, path) != 0) unlink(tmp);
}

// The reason ends up inside a JS string, so it may carry no quote, backslash or control.
static int js_safe(const char *s) {
    for (; *s; s++)
        if ((unsigned char)*s < 0x20 || *s == '"' || *s == '\\') return 0;
    return 1;
}

static int catalog_pass(const char *steam_root) {
    libraries_t libs;
    read_libraries(steam_root, &libs);
    char path[PATH_MAX], tmp[PATH_MAX];
    support_file(path, sizeof path, NP_CATALOG_FILE);
    snprintf(tmp, sizeof tmp, "%s.new", path);
    FILE *out = fopen(tmp, "w");
    if (!out) {
        NP_WARN("catalog: cannot write the badges, the library keeps the last set");
        return 0;
    }
    int seen = 0;
    for (int i = 0; i < libs.count && seen < NP_CATALOG_APPS; i++) {
        char steamapps[PATH_MAX];
        snprintf(steamapps, sizeof steamapps, "%s/steamapps", libs.paths[i]);
        DIR *d = opendir(steamapps);
        if (!d) continue;
        for (struct dirent *e; (e = readdir(d)) && seen < NP_CATALOG_APPS; ) {
            app_t app;
            if (strncmp(e->d_name, "appmanifest_", 12) != 0 || !read_manifest(steamapps, e->d_name, &app))
                continue;
            seen++;
            np_game_t game;
            if (!cached_scan(&app, &game)) {
                np_game_scan(app.install, &game);
                save_scan(&app, &game);
            }
            if (!game.scanned) continue;
            np_verdict_t history;
            np_verdict_read(app.compatdata, &history);
            char reason[256];
            np_badge_t badge = np_badge_for(&game, &history, reason, sizeof reason);
            if (js_safe(reason)) fprintf(out, "%u %s %s\n", app.appid, np_badge_name(badge), reason);
        }
        closedir(d);
    }
    int ok = fflush(out) == 0;
    fclose(out);
    if (!ok || rename(tmp, path) != 0) {
        unlink(tmp);
        NP_WARN("catalog: the badges could not be saved");
        return seen;
    }
    NP_LOG("catalog: %d installed game(s) looked at", seen);
    return seen;
}

// One pass at a time. A caller that asked waits its turn; a background pass stands down.
static pthread_mutex_t g_pass = PTHREAD_MUTEX_INITIALIZER;
static volatile int g_passes;

int np_catalog_refresh(const char *steam_root) {
    if (!steam_root || !*steam_root) return 0;
    pthread_mutex_lock(&g_pass);
    int seen = catalog_pass(steam_root);
    pthread_mutex_unlock(&g_pass);
    return seen;
}

static void *refresh_thread(void *p) {
    char *root = p;
    if (pthread_mutex_trylock(&g_pass) == 0) {
        catalog_pass(root);
        pthread_mutex_unlock(&g_pass);
        g_passes++;
    }
    free(root);
    return NULL;
}

void np_catalog_refresh_async(const char *steam_root) {
    char *root = steam_root && *steam_root ? strdup(steam_root) : NULL;
    if (!root) return;
    pthread_t t;
    pthread_attr_t attr;
    if (pthread_attr_init(&attr) != 0) { free(root); return; }
    pthread_attr_setdetachstate(&attr, PTHREAD_CREATE_DETACHED);
    if (pthread_create(&t, &attr, refresh_thread, root) != 0) free(root);
    pthread_attr_destroy(&attr);
}

typedef struct { char *js; size_t cap, at; int first; } map_t;

static void take_badge(const char *line, void *ctx) {
    map_t *m = ctx;
    unsigned appid = 0;
    char tier[16] = "";
    int reason_at = 0;
    if (!m->js || sscanf(line, "%u %15s %n", &appid, tier, &reason_at) < 2 || !appid || !reason_at) return;
    const char *reason = line + reason_at;
    if (!js_safe(reason) || !js_safe(tier)) return;
    int n = snprintf(m->js + m->at, m->cap - m->at, "%s%u:[\"%s\",\"%s\"]", m->first ? "" : ",",
                     appid, tier, reason);
    if (n < 0 || (size_t)n >= m->cap - m->at - 2) return;
    m->at += (size_t)n;
    m->first = 0;
}

char *np_catalog_map(void) {
    char path[PATH_MAX];
    support_file(path, sizeof path, NP_CATALOG_FILE);
    struct stat sb;
    if (stat(path, &sb) != 0 || sb.st_size <= 0) return NULL;
    map_t m = { malloc((size_t)sb.st_size * 2 + 16), (size_t)sb.st_size * 2 + 16, 1, 1 };
    if (!m.js) return NULL;
    m.js[0] = '{';
    each_line(path, take_badge, &m);
    if (m.first) { free(m.js); return NULL; }
    snprintf(m.js + m.at, m.cap - m.at, "}");
    return m.js;
}

char *np_catalog_javascript(const char *steam_root) {
    // Give a fresh pass a moment, or a new install shows nothing until Steam's next start.
    int before = g_passes;
    np_catalog_refresh_async(steam_root);
    for (int waited = 0; g_passes == before && waited < NP_CATALOG_WAIT_MS; waited += 20)
        usleep(20 * 1000);
    char *map = np_catalog_map();
    if (!map) return NULL;
    char off[PATH_MAX];
    support_file(off, sizeof off, NP_CATALOG_OFF_FILE);
    struct stat sb;
    size_t cap = strlen(map) + 128;
    char *js = malloc(cap);
    // The switch goes with the map, so turning badges back on needs no restart.
    if (js)
        snprintf(js, cap, "window.__NOTPROTON_BADGES_OFF__=%s;window.__NOTPROTON_COMPAT__=%s;\n",
                 stat(off, &sb) == 0 ? "true" : "false", map);
    free(map);
    return js;
}

int np_catalog_set_enabled(int on) {
    char path[PATH_MAX];
    support_file(path, sizeof path, NP_CATALOG_OFF_FILE);
    if (on) return unlink(path) == 0 || errno == ENOENT;
    FILE *f = fopen(path, "w");
    return f && fclose(f) == 0;
}
