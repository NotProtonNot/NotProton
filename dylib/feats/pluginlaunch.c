// Launch choices a plugin offers for a non-Steam shortcut. An entry is only offered once
// its file exists next to the shortcut's exe.
#include "pluginlaunch.h"
#include "conf.h"
#include "../util/file.h"
#include "../util/log.h"

#include <dirent.h>
#include <limits.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <strings.h>
#include <sys/stat.h>

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

int np_pluginlaunch_shortcut_dir(const char *home, uint32_t appid, char *out, size_t size) {
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

    // Steam keeps the path quoted.
    char *path = exe;
    size_t n = strlen(path);
    if (n >= 2 && path[0] == '"' && path[n - 1] == '"') {
        path[n - 1] = 0;
        path++;
    }
    char *slash = strrchr(path, '/');
    if (!slash || slash == path) return 0;
    *slash = 0;
    return snprintf(out, size, "%s", path) < (int)size;
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

char *np_pluginlaunch_json(uint32_t appid) {
    json_t j = { NULL, 0, 0, 1 };
    json_put(&j, "[", 1);

    const char *home = np_home_dir();
    char dir[PATH_MAX];
    np_conf_rec_t *list = calloc(NP_CONF_RECORDS_MAX, sizeof *list);
    if (!list) { free(j.buf); return NULL; }

    int first = 1;
    if (home && np_pluginlaunch_shortcut_dir(home, appid, dir, sizeof dir)) {
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

                json_put(&j, first ? "{\"k\":" : ",{\"k\":", first ? 5 : 6);
                json_str(&j, list[r].id, strlen(list[r].id));
                json_put(&j, ",\"on\":", 6);
                json_str(&j, on ? on : "1", strlen(on ? on : "1"));
                json_put(&j, ",\"l\":", 5);
                json_str(&j, label, llen);
                json_put(&j, ",\"a\":", 5);
                json_str(&j, args, alen);
                json_put(&j, "}", 1);
                first = 0;
            }
        }
    }
    free(list);
    json_put(&j, "]", 1);
    if (!j.ok) { free(j.buf); return NULL; }
    return j.buf;
}
