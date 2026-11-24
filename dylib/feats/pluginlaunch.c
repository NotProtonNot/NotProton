// Launch choices a plugin offers for a non-Steam shortcut. An entry is only offered once
// its file exists next to the shortcut's exe.
#include "pluginlaunch.h"
#include "conf.h"
#include "../util/file.h"
#include "../util/log.h"

#include <dirent.h>
#include <limits.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <strings.h>
#include <sys/stat.h>
#include <time.h>

#define VDF_MAP    0x00
#define VDF_STRING 0x01
#define VDF_INT32  0x02
#define VDF_FLOAT  0x03
#define VDF_UINT64 0x07
#define VDF_END    0x08
#define VDF_DEPTH_MAX 8

// Binary VDF. Returns the byte after the map, or NULL if malformed.
static const uint8_t *vdf_map(const uint8_t *p, const uint8_t *end, int depth, uint32_t want,
                              char *exe, size_t size, int *found) {
    uint32_t appid = 0;
    int have_id = 0;
    const char *entry_exe = NULL;

    if (depth > VDF_DEPTH_MAX) return NULL;
    while (p < end) {
        uint8_t type = *p++;
        if (type == VDF_END) {
            // root > "shortcuts" > shortcut
            if (depth == 2 && have_id && appid == want && entry_exe && !*found) {
                snprintf(exe, size, "%s", entry_exe);
                *found = 1;
            }
            return p;
        }
        const char *key = (const char *)p;
        p = memchr(p, 0, (size_t)(end - p));
        if (!p) return NULL;
        p++;

        switch (type) {
        case VDF_MAP:
            p = vdf_map(p, end, depth + 1, want, exe, size, found);
            if (!p) return NULL;
            break;
        case VDF_STRING: {
            const char *value = (const char *)p;
            p = memchr(p, 0, (size_t)(end - p));
            if (!p) return NULL;
            p++;
            if (depth == 2 && strcasecmp(key, "exe") == 0) entry_exe = value;
            break;
        }
        case VDF_INT32:
        case VDF_FLOAT:
            if (end - p < 4) return NULL;
            if (type == VDF_INT32 && depth == 2 && strcasecmp(key, "appid") == 0) {
                memcpy(&appid, p, 4);
                have_id = 1;
            }
            p += 4;
            break;
        case VDF_UINT64:
            if (end - p < 8) return NULL;
            p += 8;
            break;
        default:
            return NULL;
        }
    }
    return depth == 0 ? p : NULL;
}

static int shortcut_exe_in(const char *vdf, uint32_t appid, char *exe, size_t size) {
    size_t len = 0;
    uint8_t *buf = np_read_whole_file(vdf, &len);
    if (!buf) return 0;
    int found = 0;
    vdf_map(buf, buf + len, 0, appid, exe, size, &found);
    free(buf);
    return found;
}

// The shortcut's exe, unquoted.
static int shortcut_exe(const char *home, uint32_t appid, char *out, size_t size) {
    char root[PATH_MAX];
    snprintf(root, sizeof root, "%s/Library/Application Support/Steam/userdata", home);
    DIR *d = opendir(root);
    if (!d) return 0;

    // One file per account
    char exe[PATH_MAX] = "";
    int found = 0;
    struct dirent *e;
    while (!found && (e = readdir(d))) {
        if (e->d_name[0] == '.') continue;
        char vdf[PATH_MAX];
        snprintf(vdf, sizeof vdf, "%s/%s/config/shortcuts.vdf", root, e->d_name);
        found = shortcut_exe_in(vdf, appid, exe, sizeof exe);
    }
    closedir(d);
    if (!found) return 0;

    char *path = exe;
    size_t n = strlen(path);
    if (n >= 2 && path[0] == '"' && path[n - 1] == '"') {
        path[n - 1] = 0;
        path++;
    }
    return snprintf(out, size, "%s", path) < (int)size;
}

int np_pluginlaunch_shortcut_dir(const char *home, uint32_t appid, char *out, size_t size) {
    if (!shortcut_exe(home, appid, out, size)) return 0;
    char *slash = strrchr(out, '/');
    if (!slash || slash == out) return 0;
    *slash = 0;
    return 1;
}

typedef struct {
    np_conf_rec_t *list;
    int count;
} launch_ctx_t;

static const char *launch_take(const np_conf_rec_t *rec, void *ctx, const char **detail) {
    (void)detail;
    launch_ctx_t *lc = ctx;
    if (np_conf_count(rec, "launch")) lc->list[lc->count++] = *rec;
    return NULL;
}

static void launch_refused(const char *scope, const char *code, const char *detail, void *ctx) {
    (void)scope; (void)code; (void)detail; (void)ctx;  // the panel logs these
}

typedef struct { char *buf; size_t len, cap; int ok; } json_t;

static void json_put(json_t *j, const char *s, size_t n) {
    if (!j->ok) return;
    if (j->len + n + 1 > j->cap) {
        size_t cap = (j->cap ? j->cap * 2 : 512) + n;
        char *b = realloc(j->buf, cap);
        if (!b) { j->ok = 0; return; }
        j->buf = b;
        j->cap = cap;
    }
    memcpy(j->buf + j->len, s, n);
    j->len += n;
    j->buf[j->len] = 0;
}

static void json_str(json_t *j, const char *s, size_t n) {
    json_put(j, "\"", 1);
    for (size_t i = 0; i < n; i++) {
        unsigned char c = (unsigned char)s[i];
        char esc[8];
        if (c == '"' || c == '\\') { esc[0] = '\\'; esc[1] = (char)c; json_put(j, esc, 2); }
        else if (c < 0x20) { snprintf(esc, sizeof esc, "\\u%04x", c); json_put(j, esc, 6); }
        else json_put(j, (const char *)&s[i], 1);
    }
    json_put(j, "\"", 1);
}

static const char *trimmed(const char *s, const char *end, size_t *len) {
    while (s < end && (*s == ' ' || *s == '\t')) s++;
    while (end > s && (end[-1] == ' ' || end[-1] == '\t')) end--;
    *len = (size_t)(end - s);
    return s;
}

// "label = path [= args]". 0 if label or path is missing.
static int launch_split(const char *v, const char **label, size_t *llen, const char **path,
                        size_t *plen, const char **args, size_t *alen) {
    const char *a = strchr(v, '=');
    if (!a) return 0;
    const char *b = strchr(a + 1, '=');
    const char *end = v + strlen(v);
    *label = trimmed(v, a, llen);
    *path = trimmed(a + 1, b ? b : end, plen);
    if (b) *args = trimmed(b + 1, end, alen);
    else { *args = end; *alen = 0; }
    return *llen && *plen;
}

static int launch_exists(const char *dir, const char *path, size_t plen) {
    char full[PATH_MAX];
    struct stat st;
    if (plen >= sizeof full || memmem(path, plen, "..", 2)) return 0;
    snprintf(full, sizeof full, "%s/%.*s", dir, (int)plen, path);
    return stat(full, &st) == 0 && S_ISREG(st.st_mode);
}

typedef void (*launch_fn)(const np_conf_rec_t *rec, const char *on, const char *label,
                          size_t llen, const char *args, size_t alen, void *ctx);

// Calls fn for each launch entry a shortcut offers. Returns 0 if out of memory.
static int each_launch(uint32_t appid, launch_fn fn, void *ctx) {
    const char *home = np_home_dir();
    char dir[PATH_MAX];
    if (!home || !np_pluginlaunch_shortcut_dir(home, appid, dir, sizeof dir)) return 1;

    np_conf_rec_t *list = calloc(NP_CONF_RECORDS_MAX, sizeof *list);
    if (!list) return 0;
    char plugins[PATH_MAX];
    snprintf(plugins, sizeof plugins, "%s/Library/Application Support/notproton/plugins", home);
    launch_ctx_t lc = { list, 0 };
    const np_conf_sink_t sink = { launch_take, launch_refused, NULL };
    np_conf_read_dir(plugins, NULL, NP_CONF_PLUGIN, &sink, &lc);

    for (int r = 0; r < lc.count; r++) {
        const char *on = np_conf_get(&list[r], "on");
        const char *name, *value;
        int it = 0;
        while (np_conf_next(&list[r], &it, &name, &value)) {
            const char *label, *path, *args;
            size_t llen, plen, alen;
            if (strcmp(name, "launch") != 0) continue;
            if (!launch_split(value, &label, &llen, &path, &plen, &args, &alen)) continue;
            if (!launch_exists(dir, path, plen)) continue;
            fn(&list[r], on ? on : "1", label, llen, args, alen, ctx);
        }
    }
    free(list);
    return 1;
}

typedef struct { json_t j; int first; } json_ctx_t;

static void json_entry(const np_conf_rec_t *rec, const char *on, const char *label,
                       size_t llen, const char *args, size_t alen, void *ctx) {
    json_ctx_t *c = ctx;
    json_put(&c->j, c->first ? "{\"k\":" : ",{\"k\":", c->first ? 5 : 6);
    json_str(&c->j, rec->id, strlen(rec->id));
    json_put(&c->j, ",\"on\":", 6);
    json_str(&c->j, on, strlen(on));
    json_put(&c->j, ",\"l\":", 5);
    json_str(&c->j, label, llen);
    json_put(&c->j, ",\"a\":", 5);
    json_str(&c->j, args, alen);
    json_put(&c->j, "}", 1);
    c->first = 0;
}

char *np_pluginlaunch_json(uint32_t appid) {
    json_ctx_t c = { { NULL, 0, 0, 1 }, 1 };
    json_put(&c.j, "[", 1);
    int ok = each_launch(appid, json_entry, &c);
    json_put(&c.j, "]", 1);
    if (!ok || !c.j.ok) { free(c.j.buf); return NULL; }
    return c.j.buf;
}

// Steam can't pass a shortcut arguments, so a pick waits here for its launch command.
#define PICK_TTL_SECONDS 120

static pthread_mutex_t g_pick_lock = PTHREAD_MUTEX_INITIALIZER;
static char g_pick_exe[PATH_MAX + 2];  // quoted, as in the launch command
static char g_pick_args[1024];
static time_t g_pick_at;

static time_t now_seconds(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return ts.tv_sec;
}

typedef struct { const char *want; int found; } match_ctx_t;

static void match_entry(const np_conf_rec_t *rec, const char *on, const char *label,
                        size_t llen, const char *args, size_t alen, void *ctx) {
    (void)rec; (void)on; (void)label; (void)llen;
    match_ctx_t *m = ctx;
    if (alen && strlen(m->want) == alen && memcmp(m->want, args, alen) == 0) m->found = 1;
}

int np_pluginlaunch_pick(uint32_t appid, const char *args) {
    pthread_mutex_lock(&g_pick_lock);
    g_pick_exe[0] = 0;
    pthread_mutex_unlock(&g_pick_lock);
    if (!args || !*args) return 1;

    // Only arguments a plugin declared for this shortcut
    match_ctx_t m = { args, 0 };
    char exe[PATH_MAX];
    const char *home = np_home_dir();
    if (!each_launch(appid, match_entry, &m) || !m.found || strlen(args) >= sizeof g_pick_args
        || !home || !shortcut_exe(home, appid, exe, sizeof exe)) {
        NP_ERR("pluginlaunch: app %u has no launch choice with arguments %s", appid, args);
        return 0;
    }
    pthread_mutex_lock(&g_pick_lock);
    snprintf(g_pick_exe, sizeof g_pick_exe, "\"%s\"", exe);
    snprintf(g_pick_args, sizeof g_pick_args, "%s", args);
    g_pick_at = now_seconds();
    pthread_mutex_unlock(&g_pick_lock);
    NP_LOG("pluginlaunch: app %u starts next with %s", appid, args);
    return 1;
}

// Appends s to out as one single-quoted shell word.
static size_t put_quoted(char *out, const char *s, size_t n) {
    size_t w = 0;
    out[w++] = ' ';
    out[w++] = '\'';
    for (size_t i = 0; i < n; i++) {
        if (s[i] == '\'') { memcpy(out + w, "'\\''", 4); w += 4; }
        else out[w++] = s[i];
    }
    out[w++] = '\'';
    return w;
}

char *np_pluginlaunch_take(const char *cmd) {
    char args[sizeof g_pick_args];
    const char *exe = NULL;
    size_t exe_len = 0;
    pthread_mutex_lock(&g_pick_lock);
    int fresh = g_pick_exe[0] && now_seconds() - g_pick_at <= PICK_TTL_SECONDS;
    if (fresh && (exe = strstr(cmd, g_pick_exe))) {
        exe_len = strlen(g_pick_exe);
        snprintf(args, sizeof args, "%s", g_pick_args);
    }
    if (exe || !fresh) g_pick_exe[0] = 0;
    pthread_mutex_unlock(&g_pick_lock);
    if (!exe) return NULL;

    // Right after the exe, one quoted word each
    size_t head = (size_t)(exe - cmd) + exe_len, len = head;
    char *out = malloc(strlen(cmd) + 7 * strlen(args) + 1);
    if (!out) return NULL;
    memcpy(out, cmd, head);
    for (const char *p = args; *p;) {
        while (*p == ' ' || *p == '\t') p++;
        const char *e = p;
        while (*e && *e != ' ' && *e != '\t') e++;
        if (e > p) len += put_quoted(out + len, p, (size_t)(e - p));
        p = e;
    }
    strcpy(out + len, cmd + head);
    return out;
}
