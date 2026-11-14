// A badge for every installed game.
//
// Two halves that never wait on each other: the library asks for what was saved last
// time, and a thread behind it walks the installed games and saves a fresh set. A game
// installed since the last pass wears no badge until the next one, which is the honest
// answer anyway -- nothing has looked at it yet.
#include "catalog.h"
#include "advice.h"
#include "game.h"
#include "machine.h"
#include "nativeplatform.h"
#include "rules.h"
#include "store.h"
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
// Present when someone has turned the badges off; the library is then told to draw none.
#define NP_CATALOG_OFF_FILE  "no-mac-badges"
// How long the library waits for a fresh pass before settling for the last one.
#define NP_CATALOG_WAIT_MS   2500
// Where anyone can drop a rule for a game, read the same way plugins are.
#define NP_CATALOG_RULES_DIR "Library/Application Support/notproton/rules"
// A reason is one sentence; the file is one line per game.
#define NP_CATALOG_LINE      (NP_ADVICE_REASON_MAX + 64)

static const char *vdf_value(const char *line, const char *key, char *out, size_t size) {
    const char *at = strstr(line, key);
    if (!at) return NULL;
    at = strchr(at + strlen(key), '"');          // opening quote of the value
    if (!at) return NULL;
    const char *end = strchr(++at, '"');
    if (!end) return NULL;
    size_t n = (size_t)(end - at);
    if (n >= size) return NULL;
    memcpy(out, at, n);
    out[n] = '\0';
    return out;
}

typedef struct {
    char paths[NP_CATALOG_LIBRARIES][PATH_MAX];
    int  count;
} libraries_t;

static void read_libraries(const char *steam_root, libraries_t *libs) {
    libs->count = 0;
    snprintf(libs->paths[libs->count++], PATH_MAX, "%s", steam_root);
    char path[PATH_MAX];
    snprintf(path, sizeof path, "%s/steamapps/libraryfolders.vdf", steam_root);
    size_t len = 0;
    uint8_t *text = np_read_file_max(path, 1u << 20, 0, &len);
    if (!text) return;
    char line[2048];
    size_t at = 0;
    while (at < len && libs->count < NP_CATALOG_LIBRARIES) {
        size_t n = 0;
        while (at + n < len && text[at + n] != '\n' && n < sizeof line - 1) n++;
        memcpy(line, text + at, n);
        line[n] = '\0';
        at += n + 1;
        char value[PATH_MAX];
        if (!vdf_value(line, "\"path\"", value, sizeof value)) continue;
        // Steam writes its escapes doubled; a path is the one thing here that carries them.
        char *w = value;
        for (const char *r = value; *r; r++) {
            if (*r == '\\' && r[1]) r++;
            *w++ = *r;
        }
        *w = '\0';
        int seen = 0;
        for (int i = 0; i < libs->count; i++) seen |= strcmp(libs->paths[i], value) == 0;
        if (!seen && value[0] == '/') snprintf(libs->paths[libs->count++], PATH_MAX, "%s", value);
    }
    free(text);
}

typedef struct {
    unsigned appid;
    char     install[PATH_MAX];   // steamapps/common/<dir>
    char     compatdata[PATH_MAX];
    char     stamp[64];           // the manifest's build, so a patched game is scanned again
} app_t;

static int read_manifest(const char *steamapps, const char *name, app_t *app) {
    unsigned appid = 0;
    if (sscanf(name, "appmanifest_%u.acf", &appid) != 1 || !appid) return 0;
    char path[PATH_MAX];
    if ((size_t)snprintf(path, sizeof path, "%s/%s", steamapps, name) >= sizeof path) return 0;
    size_t len = 0;
    uint8_t *text = np_read_file_max(path, 1u << 20, 0, &len);
    if (!text) return 0;

    char dir[PATH_MAX] = "", build[64] = "", updated[64] = "";
    char line[2048];
    size_t at = 0;
    while (at < len) {
        size_t n = 0;
        while (at + n < len && text[at + n] != '\n' && n < sizeof line - 1) n++;
        memcpy(line, text + at, n);
        line[n] = '\0';
        at += n + 1;
        if (!dir[0]) vdf_value(line, "\"installdir\"", dir, sizeof dir);
        if (!build[0]) vdf_value(line, "\"buildid\"", build, sizeof build);
        if (!updated[0]) vdf_value(line, "\"LastUpdated\"", updated, sizeof updated);
    }
    free(text);
    if (!dir[0]) return 0;

    app->appid = appid;
    snprintf(app->stamp, sizeof app->stamp, "%s-%s", build[0] ? build : "0",
             updated[0] ? updated : "0");
    if ((size_t)snprintf(app->install, sizeof app->install, "%s/common/%s", steamapps, dir)
        >= sizeof app->install) return 0;
    snprintf(app->compatdata, sizeof app->compatdata, "%s/compatdata/%u", steamapps, appid);
    return 1;
}

static void catalog_path(char *buf, size_t size) {
    const char *home = np_home_dir();
    np_support_path(buf, size, home ? home : "", NP_CATALOG_FILE);
}

// The scan of one game, kept beside its prefix so a game that has not changed is never
// walked twice. The stamp is the manifest's build, so an update costs one fresh scan.
static int cached_scan(const app_t *app, np_game_t *game) {
    char path[PATH_MAX], want[64];
    snprintf(path, sizeof path, "%s/notproton-scan", app->compatdata);
    size_t len = 0;
    uint8_t *text = np_read_file_max(path, 4096, 0, &len);
    if (!text) return 0;
    int ok = 0;
    unsigned gfx = 0;
    int bits = 0, native = 0, ac = 0, launcher = 0, engine = 0;
    char stamp[64] = "";
    if (sscanf((const char *)text, "1\n%63s\n%d\n%u\n%d\n%d\n%d\n%d",
               stamp, &bits, &gfx, &native, &ac, &launcher, &engine) == 7) {
        snprintf(want, sizeof want, "%s", app->stamp);
        if (strcmp(stamp, want) == 0) {
            memset(game, 0, sizeof *game);
            game->scanned = 1;
            game->bits = bits;
            game->gfx = gfx;
            game->native = native;
            game->anticheat = (np_anticheat_t)ac;
            game->launcher = (np_launcher_t)launcher;
            game->engine = (np_engine_t)engine;
            ok = 1;
        }
    }
    free(text);
    return ok;
}

static void save_scan(const app_t *app, const np_game_t *game) {
    char path[PATH_MAX], tmp[PATH_MAX];
    struct stat sb;
    if (stat(app->compatdata, &sb) != 0 || !S_ISDIR(sb.st_mode)) return;
    snprintf(path, sizeof path, "%s/notproton-scan", app->compatdata);
    snprintf(tmp, sizeof tmp, "%s.new", path);
    FILE *f = fopen(tmp, "w");
    if (!f) return;
    fprintf(f, "1\n%s\n%d\n%u\n%d\n%d\n%d\n%d\n", app->stamp, game->bits, game->gfx,
            game->native, (int)game->anticheat, (int)game->launcher, (int)game->engine);
    int ok = fflush(f) == 0;
    fclose(f);
    if (!ok || rename(tmp, path) != 0) unlink(tmp);
}

// What the run script reads at launch to set up a game it has been told nothing about:
// the settings in one file, the words to pass the game in another.
static void save_beside(const app_t *app, const char *name, const char *body) {
    char path[PATH_MAX], tmp[PATH_MAX];
    struct stat sb;
    if (stat(app->compatdata, &sb) != 0 || !S_ISDIR(sb.st_mode)) return;
    snprintf(path, sizeof path, "%s/%s", app->compatdata, name);
    if (!body || !*body) { unlink(path); return; }
    snprintf(tmp, sizeof tmp, "%s.new", path);
    FILE *f = fopen(tmp, "w");
    if (!f) return;
    fputs(body, f);
    int ok = fflush(f) == 0;
    fclose(f);
    if (!ok || rename(tmp, path) != 0) unlink(tmp);
}

static int js_safe(const char *s) {
    for (; *s; s++)
        if ((unsigned char)*s < 0x20 || *s == '"' || *s == '\\') return 0;
    return 1;
}

// What Steam already knows about each game from Valve's own testing, which is all there
// is to go on for one that is not installed.
typedef struct { unsigned appid; unsigned char mac, deck, anticheat, seen; } valve_t;

static size_t read_valve(valve_t **out) {
    *out = NULL;
    char *text = np_nativeplatform_compat();
    if (!text) return 0;
    size_t cap = 256, n = 0;
    valve_t *rows = malloc(cap * sizeof *rows);
    for (const char *at = text; rows && *at; ) {
        unsigned appid = 0, mac = 0, deck = 0, anticheat = 0;
        int used = 0;
        if (sscanf(at, "%u %u %u %u%n", &appid, &mac, &deck, &anticheat, &used) == 4
            && appid && mac <= 1 && deck <= 3 && anticheat <= 1) {
            if (n == cap) {
                valve_t *more = realloc(rows, (cap *= 2) * sizeof *rows);
                if (!more) break;
                rows = more;
            }
            rows[n++] = (valve_t){ appid, (unsigned char)mac, (unsigned char)deck,
                                   (unsigned char)anticheat, 0 };
        }
        const char *nl = strchr(at, '\n');
        if (!nl) break;
        at = nl + 1;
    }
    free(text);
    *out = rows;
    return rows ? n : 0;
}

static valve_t *find_valve(valve_t *rows, size_t n, unsigned appid) {
    for (size_t i = 0; i < n; i++)
        if (rows[i].appid == appid) return &rows[i];
    return NULL;
}

// One pass at a time. A refresh asked for while one is running is the same pass twice
// over the same files, writing the same scratch file, so the background one stands down
// and a caller that asked outright waits its turn.
static pthread_mutex_t g_pass = PTHREAD_MUTEX_INITIALIZER;

static int catalog_pass(const char *steam_root);

int np_catalog_refresh(const char *steam_root) {
    if (!steam_root || !*steam_root) return 0;
    pthread_mutex_lock(&g_pass);
    int seen = catalog_pass(steam_root);
    pthread_mutex_unlock(&g_pass);
    return seen;
}

static int catalog_pass(const char *steam_root) {
    libraries_t libs;
    read_libraries(steam_root, &libs);

    char path[PATH_MAX], tmp[PATH_MAX];
    catalog_path(path, sizeof path);
    snprintf(tmp, sizeof tmp, "%s.new", path);
    FILE *out = fopen(tmp, "w");
    if (!out) {
        NP_WARN("catalog: cannot write the badges, the library keeps the last set");
        return 0;
    }
    const np_machine_t *machine = np_machine();
    valve_t *valve = NULL;
    size_t valve_count = read_valve(&valve);
    char rules_dir[PATH_MAX];
    const char *home = np_home_dir();
    snprintf(rules_dir, sizeof rules_dir, "%s/%s", home ? home : "", NP_CATALOG_RULES_DIR);
    int seen = 0;
    for (int i = 0; i < libs.count && seen < NP_CATALOG_APPS; i++) {
        char steamapps[PATH_MAX];
        snprintf(steamapps, sizeof steamapps, "%s/steamapps", libs.paths[i]);
        DIR *d = opendir(steamapps);
        if (!d) continue;
        for (struct dirent *e; (e = readdir(d)) && seen < NP_CATALOG_APPS; ) {
            app_t app;
            if (strncmp(e->d_name, "appmanifest_", 12) != 0) continue;
            if (!read_manifest(steamapps, e->d_name, &app)) continue;
            seen++;

            np_game_t game;
            if (!cached_scan(&app, &game)) {
                np_game_scan(app.install, &game);
                save_scan(&app, &game);
            }
            np_verdict_t history;
            np_verdict_read(app.compatdata, &history);
            np_advice_t advice;
            // The badge is about the game, not about a runner, so it is worked out for
            // the one every Mac has.
            np_advice(machine, &game, &history, NP_DEFAULTS_ROSETTA, &advice);

            // Rules from the support folder come after, since a rule is someone saying
            // something about one game that nothing here could have worked out.
            np_rules_t rules;
            np_rules_apply(rules_dir, NULL, app.appid, &game, &rules);
            for (const char *at = rules.options; *at; ) {
                const char *sp = strchr(at, ' ');
                size_t len = sp ? (size_t)(sp - at) : strlen(at);
                size_t have = strlen(advice.options);
                if (have + len + 2 < sizeof advice.options)
                    snprintf(advice.options + have, sizeof advice.options - have, "%s%.*s",
                             have ? " " : "", (int)len, at);
                at += len + (sp ? 1 : 0);
            }
            if (rules.note[0]) {
                size_t have = strlen(advice.reason);
                snprintf(advice.reason + have, sizeof advice.reason - have, "%s%s",
                         have ? " " : "", rules.note);
            }
            save_beside(&app, "notproton-advice", advice.settings);
            save_beside(&app, "notproton-advice-args", advice.options);

            // Valve's testing fills in what the files could not say. An anti-cheat that
            // failed Proton blocks the game whatever its folder looked like, and a game
            // nothing here has an opinion on takes Valve's.
            valve_t *known = find_valve(valve, valve_count, app.appid);
            if (known) {
                known->seen = 1;
                char reason[NP_ADVICE_REASON_MAX];
                np_badge_t theirs = np_advice_from_valve(known->mac && game.native, known->deck,
                                                         known->anticheat, reason, sizeof reason);
                if ((known->anticheat && advice.badge != NP_BADGE_BLOCKED)
                    || (advice.badge == NP_BADGE_UNKNOWN && theirs != NP_BADGE_UNKNOWN)) {
                    advice.badge = theirs;
                    snprintf(advice.reason, sizeof advice.reason, "%s", reason);
                }
            }
            // Every installed game gets a line, "nothing is known yet" included: that
            // is a badge of its own, the way the Deck's unknown is.
            if (!game.scanned) continue;
            if (!js_safe(advice.reason)) continue;
            fprintf(out, "%u %s %s\n", app.appid, np_badge_name(advice.badge), advice.reason);
        }
        closedir(d);
    }
    // Every other game the client knows about: owned, wished for or merely looked at,
    // and none of them on disk. Finding out whether a game will run should not take
    // downloading it first.
    for (size_t i = 0; i < valve_count; i++) {
        if (valve[i].seen) continue;
        char reason[NP_ADVICE_REASON_MAX];
        np_badge_t badge = np_advice_from_valve(valve[i].mac, valve[i].deck, valve[i].anticheat,
                                                reason, sizeof reason);
        if (js_safe(reason)) fprintf(out, "%u %s %s\n", valve[i].appid, np_badge_name(badge), reason);
    }
    free(valve);
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

typedef struct { char root[PATH_MAX]; } refresh_arg_t;

// Counts the passes that have finished, so a caller can tell a fresh set from last time's.
static volatile int g_passes;

static void *refresh_thread(void *p) {
    refresh_arg_t *arg = p;
    if (pthread_mutex_trylock(&g_pass) == 0) {
        catalog_pass(arg->root);
        pthread_mutex_unlock(&g_pass);
        g_passes++;
    }
    free(arg);
    return NULL;
}

void np_catalog_refresh_async(const char *steam_root) {
    if (!steam_root || !*steam_root) return;
    refresh_arg_t *arg = calloc(1, sizeof *arg);
    if (!arg) return;
    snprintf(arg->root, sizeof arg->root, "%s", steam_root);
    pthread_t t;
    pthread_attr_t attr;
    // Nobody waits for it: the library already has last pass's badges.
    if (pthread_attr_init(&attr) != 0) { free(arg); return; }
    pthread_attr_setdetachstate(&attr, PTHREAD_CREATE_DETACHED);
    if (pthread_create(&t, &attr, refresh_thread, arg) != 0) free(arg);
    pthread_attr_destroy(&attr);
}

// The saved badges as one JavaScript object, {appid:["tier","reason"],...}, or NULL when
// there are none. Both the library and the store's pages are handed this.
char *np_catalog_map(void) {
    char path[PATH_MAX];
    catalog_path(path, sizeof path);
    size_t len = 0;
    uint8_t *text = np_read_file_max(path, 1u << 20, 0, &len);
    if (!text) return NULL;
    size_t cap = len * 2 + 16;
    char *js = malloc(cap);
    if (!js) { free(text); return NULL; }
    size_t at = (size_t)snprintf(js, cap, "{");
    int first = 1;
    for (size_t i = 0; i < len; ) {
        char line[NP_CATALOG_LINE];
        size_t n = 0;
        while (i + n < len && text[i + n] != '\n' && n < sizeof line - 1) n++;
        memcpy(line, text + i, n);
        line[n] = '\0';
        i += n + 1;
        unsigned appid = 0;
        char tier[16] = "";
        int reason_at = 0;
        if (sscanf(line, "%u %15s %n", &appid, tier, &reason_at) < 2 || !appid || !reason_at) continue;
        const char *reason = line + reason_at;
        if (!js_safe(reason) || !js_safe(tier)) continue;
        int wrote = snprintf(js + at, cap - at, "%s%u:[\"%s\",\"%s\"]", first ? "" : ",",
                             appid, tier, reason);
        if (wrote < 0 || (size_t)wrote >= cap - at - 2) break;
        at += (size_t)wrote;
        first = 0;
    }
    free(text);
    if (first) { free(js); return NULL; }   // nothing to say, so nothing is injected
    snprintf(js + at, cap - at, "}");
    return js;
}

char *np_catalog_javascript(const char *steam_root) {
    // A pass with every scan already kept is a helper run and a few small files, so the
    // library is given a moment for a fresh set before it is handed last time's. Without
    // this the badges are always one start of Steam behind, and a new install has none.
    int before = g_passes;
    np_catalog_refresh_async(steam_root);
    for (int waited = 0; g_passes == before && waited < NP_CATALOG_WAIT_MS; waited += 20)
        usleep(20 * 1000);
    // The store's pages are fed from the same set, by a thread of their own.
    np_store_start();
    char *map = np_catalog_map();
    if (!map) return NULL;

    char off_path[PATH_MAX];
    const char *home = np_home_dir();
    np_support_path(off_path, sizeof off_path, home ? home : "", NP_CATALOG_OFF_FILE);
    struct stat off;
    size_t cap = strlen(map) + 192;
    char *js = malloc(cap);
    // The switches go with the map rather than instead of it, so turning the badges back
    // on in Preferences shows them at once instead of after Steam next starts.
    if (js)
        snprintf(js, cap, "window.__NOTPROTON_BADGES_OFF__=%s;window.__NOTPROTON_STORE_OFF__=%s;"
                          "window.__NOTPROTON_COMPAT__=%s;\n",
                 stat(off_path, &off) == 0 ? "true" : "false",
                 np_store_switch() ? "false" : "true", map);
    free(map);
    return js;
}

int np_catalog_set_enabled(int on) {
    char path[PATH_MAX];
    const char *home = np_home_dir();
    np_support_path(path, sizeof path, home ? home : "", NP_CATALOG_OFF_FILE);
    if (on) return unlink(path) == 0 || errno == ENOENT;
    FILE *f = fopen(path, "w");
    if (!f) return 0;
    return fclose(f) == 0;
}
