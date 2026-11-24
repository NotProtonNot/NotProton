// Support for adding Steam launch options via a plugin
#include "pluginlaunch.h"
#include "compat.h"
#include "conf.h"
#include "usershortcuts.h"
#include "../util/file.h"
#include "../util/log.h"

#include <limits.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <time.h>

static const char *shortcut_exe(uint32_t appid) {
    return np_usershortcuts_exe(np_compat_user(np_compat_manager()), appid);
}

static int shortcut_dir(uint32_t appid, char *dir, size_t size) {
    const char *exe = shortcut_exe(appid);
    if (!exe) return 0;
    if (*exe == '"') exe++;
    if (snprintf(dir, size, "%s", exe) >= (int)size) return 0;
    char *slash = strrchr(dir, '/');
    if (!slash || slash == dir) return 0;
    *slash = 0;
    return 1;
}

// Keep in sync with np_feat_active in compat_run.sh.
static int rec_usable(const np_conf_rec_t *rec, const char *home, const char *tool) {
    int tools = 0, reqs = 0, tool_ok = 0, req_ok = 0;
    const char *name, *v;
    char path[PATH_MAX];
    struct stat st;
    for (int it = 0; np_conf_next(rec, &it, &name, &v);) {
        size_t n = strlen(v);
        if (strcmp(name, "tools") == 0) {
            tools++;
            tool_ok |= n && v[n - 1] == '*' ? strncmp(tool, v, n - 1) == 0 : strcmp(tool, v) == 0;
        } else if (strcmp(name, "requires") == 0) {
            reqs++;
            req_ok |= np_conf_home_path(path, sizeof path, home, v) && stat(path, &st) == 0
                      && S_ISREG(st.st_mode);
        }
    }
    return (!tools || tool_ok) && (!reqs || req_ok);
}

typedef struct { np_conf_rec_t *list; int count; } recs_t;

static const char *rec_take(const np_conf_rec_t *rec, void *ctx, const char **detail) {
    (void)detail;
    recs_t *recs = ctx;
    if (np_conf_count(rec, "launch")) recs->list[recs->count++] = *rec;
    return NULL;
}

static void json_str(FILE *f, const char *s, size_t n) {
    fputc('"', f);
    for (size_t i = 0; i < n; i++) {
        unsigned char c = (unsigned char)s[i];
        if (c == '"' || c == '\\') fprintf(f, "\\%c", c);
        else if (c < 0x20) fprintf(f, "\\u%04x", c);
        else fputc(c, f);
    }
    fputc('"', f);
}

static int launch_entries(uint32_t appid, FILE *json, const char *want) {
    const char *home = np_home_dir(), *tool = np_compat_app_tool_dir(appid);
    char dir[PATH_MAX], plugins[PATH_MAX];
    np_conf_rec_t *list;
    int found = 0, written = 0;

    if (!home || !tool || !shortcut_dir(appid, dir, sizeof dir)
        || !(list = calloc(NP_CONF_RECORDS_MAX, sizeof *list))) return 0;
    recs_t recs = { list, 0 };
    const np_conf_sink_t sink = { rec_take, NULL, NULL };
    np_support_path(plugins, sizeof plugins, home, "plugins");
    np_conf_read_dir(plugins, NULL, NP_CONF_PLUGIN, &sink, &recs);

    if (strrchr(tool, '/')) tool = strrchr(tool, '/') + 1;
    for (int r = 0; r < recs.count; r++) {
        const char *on = np_conf_get(&list[r], "on"), *name, *value;
        if (!on) on = "1";
        if (!rec_usable(&list[r], home, tool)) continue;
        for (int it = 0; np_conf_next(&list[r], &it, &name, &value);) {
            np_conf_launch_t l;
            char path[PATH_MAX];
            struct stat st;
            if (strcmp(name, "launch") != 0 || !np_conf_launch(value, &l)
                || snprintf(path, sizeof path, "%s/%.*s", dir, (int)l.file_len, l.file)
                       >= (int)sizeof path
                || stat(path, &st) != 0 || !S_ISREG(st.st_mode)) continue;
            if (want && strcmp(want, l.args) == 0) found = 1;
            if (!json) continue;
            fputs(written++ ? ",{\"k\":" : "{\"k\":", json);
            json_str(json, list[r].id, strlen(list[r].id));
            fputs(",\"on\":", json);
            json_str(json, on, strlen(on));
            fputs(",\"l\":", json);
            json_str(json, value, l.label_len);
            fputs(",\"a\":", json);
            json_str(json, l.args, strlen(l.args));
            fputc('}', json);
        }
    }
    free(list);
    return found;
}

char *np_pluginlaunch_json(uint32_t appid) {
    char *buf = NULL;
    size_t len = 0;
    FILE *f = open_memstream(&buf, &len);
    if (!f) return NULL;
    fputc('[', f);
    launch_entries(appid, f, NULL);
    fputc(']', f);
    int failed = ferror(f);
    if (fclose(f) != 0 || failed) {
        free(buf);
        return NULL;
    }
    return buf;
}

// Steam's RunGame can't take arguments.
#define PICK_TTL_SECONDS 120

static pthread_mutex_t g_pick_lock = PTHREAD_MUTEX_INITIALIZER;
static char g_pick_exe[PATH_MAX];
static char g_pick_args[1024];
static time_t g_pick_at;

static time_t now_seconds(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return ts.tv_sec;
}

int np_pluginlaunch_pick(uint32_t appid, const char *args) {
    char exe[sizeof g_pick_exe] = "";
    const char *held = args && *args ? shortcut_exe(appid) : NULL;
    int keep = held && snprintf(exe, sizeof exe, "%s", held) < (int)sizeof exe
            && strlen(args) < sizeof g_pick_args && launch_entries(appid, NULL, args);

    pthread_mutex_lock(&g_pick_lock);
    snprintf(g_pick_exe, sizeof g_pick_exe, "%s", keep ? exe : "");
    if (keep) {
        snprintf(g_pick_args, sizeof g_pick_args, "%s", args);
        g_pick_at = now_seconds();
    }
    pthread_mutex_unlock(&g_pick_lock);

    if (keep) NP_LOG("pluginlaunch: app %u starts next with %s", appid, args);
    else if (args && *args)
        NP_ERR("pluginlaunch: app %u has no launch choice with arguments %s", appid, args);
    return keep || !args || !*args;
}

char *np_pluginlaunch_take(const char *cmd) {
    char args[sizeof g_pick_args];
    const char *exe = NULL;
    size_t head = 0;
    pthread_mutex_lock(&g_pick_lock);
    int fresh = g_pick_exe[0] && now_seconds() - g_pick_at <= PICK_TTL_SECONDS;
    if (fresh && (exe = strstr(cmd, g_pick_exe))) {
        head = (size_t)(exe - cmd) + strlen(g_pick_exe);
        snprintf(args, sizeof args, "%s", g_pick_args);
    }
    if (exe || !fresh) g_pick_exe[0] = 0;
    pthread_mutex_unlock(&g_pick_lock);
    if (!exe) return NULL;

    char *out = NULL;
    if (asprintf(&out, "%.*s %s%s", (int)head, cmd, args, cmd + head) < 0) return NULL;
    return out;
}
