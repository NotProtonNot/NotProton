#include "defaults.h"
#include "../util/buildid.h"
#include "../util/file.h"
#include "../util/log.h"

#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <dirent.h>
#include <sys/stat.h>

#define ROSETTA (1u << NP_DEFAULTS_ROSETTA)
#define FEX     (1u << NP_DEFAULTS_FEX)

static const char *const g_bools[]    = { "0", "1", NULL };
static const char *const g_backends[] = { "dxmt", "dxvk", "wined3d", NULL };
static const char *const g_d3dmetal[] = { "d3dmetal", NULL };
static const char *const g_factors[]  = { "1.5", "1.72", "2.0", "3.0", NULL };
static const char *const g_fps[]      = { "30", "60", "90", "120", "144", "240", NULL };

static const struct {
    const char        *key;
    unsigned           runners;
    const char        *prefix;
    const char *const *values;
    const char *const *rosetta_values; // on top of `values`, for Rosetta only
} g_settings[] = {
    { "CX_GRAPHICS_BACKEND",            ROSETTA | FEX, "", g_backends, g_d3dmetal },
    { "MTL_HUD_ENABLED",                ROSETTA | FEX, "", g_bools, NULL },
    { "D3DM_ENABLE_METALFX",            ROSETTA,       "", g_bools, NULL },
    { "D3DM_SUPPORT_DXR",               ROSETTA,       "", g_bools, NULL },
    { "D3DM_MTL4",                      ROSETTA,       "", g_bools, NULL },
    { "D3DM_MAX_FPS",                   ROSETTA,       "", g_fps, NULL },
    { "DXMT_ENABLE_NVEXT",              ROSETTA | FEX, "", g_bools, NULL },
    { "ROSETTA_ADVERTISE_AVX",          ROSETTA,       "", g_bools, NULL },
    { "WINEMSYNC",                      ROSETTA | FEX, "", g_bools, NULL },
    { "NOTPROTON_RETINA",               ROSETTA | FEX, "", g_bools, NULL },
    { "DXMT_METALFX_SPATIAL_SWAPCHAIN", ROSETTA | FEX, "", g_bools, NULL },
    { "DXMT_CONFIG",                    ROSETTA | FEX, "d3d11.metalSpatialUpscaleFactor=", g_factors, NULL },
    { "NOTPROTON_RAW_CONTROLLERS",      ROSETTA | FEX, "", g_bools, NULL },
    { "NOTPROTON_DISABLE_HIDRAW",       ROSETTA | FEX, "", g_bools, NULL },
    { "FEX_X87REDUCEDPRECISION",        FEX,           "", g_bools, NULL },
};
#define SETTING_COUNT (sizeof(g_settings) / sizeof(g_settings[0]))

static const char *const g_runner_names[] = { "rosetta", "fex" };

static int is(const char *s, size_t len, const char *want) {
    return strlen(want) == len && memcmp(s, want, len) == 0;
}

static int is_one_of(const char *const *list, const char *v, size_t len) {
    for (; list && *list; list++)
        if (is(v, len, *list)) return 1;
    return 0;
}

static int valid_value(size_t i, uint32_t runner, const char *v, size_t len) {
    size_t pre = strlen(g_settings[i].prefix);
    if (len <= pre || memcmp(v, g_settings[i].prefix, pre) != 0) return 0;
    return is_one_of(g_settings[i].values, v + pre, len - pre)
        || (runner == NP_DEFAULTS_ROSETTA && is_one_of(g_settings[i].rosetta_values, v + pre, len - pre));
}

static int setting_index(uint32_t runner, const char *key, size_t key_len) {
    if (runner > NP_DEFAULTS_FEX) return -1;
    for (size_t i = 0; i < SETTING_COUNT; i++)
        if (is(key, key_len, g_settings[i].key) && (g_settings[i].runners & (1u << runner)))
            return (int)i;
    return -1;
}

typedef void (*line_fn)(void *ctx, const char *key, size_t key_len,
                        const char *value, size_t value_len);

static int each_line(uint32_t runner, const char *text, size_t len, line_fn fn, void *ctx) {
    int bad = 0;
    unsigned seen = 0;
    for (size_t at = 0; at < len; ) {
        const char *line = text + at;
        const char *nl = memchr(line, '\n', len - at);
        size_t n = nl ? (size_t)(nl - line) : len - at;
        at += n + (nl ? 1 : 0);
        if (n == 0) continue;

        const char *eq = memchr(line, '=', n);
        size_t key_len = eq ? (size_t)(eq - line) : n;
        int i = eq ? setting_index(runner, line, key_len) : -1;
        if (i < 0 || (seen & (1u << i)) ||
            !valid_value((size_t)i, runner, eq + 1, n - key_len - 1)) {
            bad++;
            continue;
        }
        seen |= 1u << i;
        if (fn) fn(ctx, line, key_len, eq + 1, n - key_len - 1);
    }
    return bad;
}

static void defaults_path(char *buf, size_t size, uint32_t runner) {
    char rel[32];
    snprintf(rel, sizeof rel, "defaults-%s", g_runner_names[runner]);
    const char *home = np_home_dir();
    np_support_path(buf, size, home ? home : "", rel);
}

typedef struct { char *buf; size_t size, len; int ok; } np_text_t;

static void put(np_text_t *t, const char *s, size_t n) {
    if (!t->ok || t->len + n >= t->size) { t->ok = 0; return; }
    memcpy(t->buf + t->len, s, n);
    t->len += n;
    t->buf[t->len] = '\0';
}

static void put_line(void *ctx, const char *key, size_t key_len,
                     const char *value, size_t value_len) {
    np_text_t *t = ctx;
    put(t, key, key_len);
    put(t, "=", 1);
    put(t, value, value_len);
    put(t, "\n", 1);
}

#define OVERRIDE_PREFIX "defaults-override-"

static void build_path(char *buf, size_t size, const char *build, uint32_t runner) {
    char rel[NP_BUILD_ID_MAX + 32];
    snprintf(rel, sizeof rel, OVERRIDE_PREFIX "%s-%s", build, g_runner_names[runner]);
    const char *home = np_home_dir();
    np_support_path(buf, size, home ? home : "", rel);
}

static pthread_mutex_t g_save_lock = PTHREAD_MUTEX_INITIALIZER;

static void sync_dir_of(const char *path) {
    char dir[PATH_MAX];
    snprintf(dir, sizeof dir, "%s", path);
    char *slash = strrchr(dir, '/');
    if (!slash) return;
    *slash = '\0';
    int fd = open(dir, O_RDONLY | O_DIRECTORY | O_CLOEXEC);
    if (fd < 0) return;
    fsync(fd);
    close(fd);
}

static int write_locked(const char *path, const char *body, size_t len) {
    char tmp[PATH_MAX];
    snprintf(tmp, sizeof tmp, "%s.new", path);
    if (unlink(tmp) != 0 && (errno == EPERM || errno == EISDIR)) rmdir(tmp);
    int fd = open(tmp, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0644);
    if (fd < 0) {
        NP_ERR("defaults: cannot write %s: %s", tmp, strerror(errno));
        return 0;
    }
    size_t done = 0;
    errno = 0;
    while (done < len) {
        ssize_t n = write(fd, body + done, len - done);
        if (n < 0 && errno == EINTR) continue;
        if (n <= 0) break;
        done += (size_t)n;
    }
    int ok = done == len && fsync(fd) == 0;
    int err = errno;
    if (close(fd) != 0 && ok) { ok = 0; err = errno; }
    if (ok && rename(tmp, path) != 0) { ok = 0; err = errno; }
    if (!ok) {
        NP_ERR("defaults: cannot save %s: %s", path, strerror(err ? err : EIO));
        unlink(tmp);
        return 0;
    }
    sync_dir_of(path);
    NP_LOG("defaults: saved %s", path);
    return 1;
}

static int remove_locked(const char *path) {
    if (unlink(path) != 0 && errno != ENOENT) {
        NP_ERR("defaults: cannot remove %s: %s", path, strerror(errno));
        return 0;
    }
    sync_dir_of(path);
    NP_LOG("defaults: removed %s", path);
    return 1;
}

static int checked_body(uint32_t runner, const char *text, char *body, size_t size, size_t *len) {
    const char *name = g_runner_names[runner];
    if (!text) {
        NP_ERR("defaults: no text for %s, nothing saved", name);
        return 0;
    }
    size_t n = strlen(text);
    if (n > NP_DEFAULTS_TEXT_MAX) {
        NP_ERR("defaults: %zu bytes for %s, over the %d allowed", n, name, NP_DEFAULTS_TEXT_MAX);
        return 0;
    }
    int bad = each_line(runner, text, n, NULL, NULL);
    if (bad) {
        NP_ERR("defaults: %d bad line(s) for %s, nothing saved", bad, name);
        return 0;
    }
    body[0] = '\0';
    np_text_t t = { body, size, 0, 1 };
    each_line(runner, text, n, put_line, &t);
    if (!t.ok) {
        NP_ERR("defaults: the lines for %s do not fit, nothing saved", name);
        return 0;
    }
    *len = t.len;
    return 1;
}

static int save_file(const char *path, uint32_t runner, const char *text) {
    char body[NP_DEFAULTS_TEXT_MAX + 1];
    size_t len = 0;
    if (!checked_body(runner, text, body, sizeof body, &len)) return 0;
    pthread_mutex_lock(&g_save_lock);
    int ok = write_locked(path, body, len);
    pthread_mutex_unlock(&g_save_lock);
    return ok;
}

int np_defaults_save(uint32_t runner, const char *text) {
    if (runner > NP_DEFAULTS_FEX) {
        NP_ERR("defaults: runner %u is neither Rosetta nor FEX", runner);
        return 0;
    }
    char path[PATH_MAX];
    defaults_path(path, sizeof path, runner);
    return save_file(path, runner, text);
}

int np_defaults_save_build(const char *build, uint32_t runner, const char *text) {
    if (runner > NP_DEFAULTS_FEX) {
        NP_ERR("defaults: runner %u is neither Rosetta nor FEX", runner);
        return 0;
    }
    if (!np_is_build_id(build)) {
        NP_ERR("defaults: no CrossOver build ID for runner %u, nothing saved", runner);
        return 0;
    }
    char path[PATH_MAX];
    build_path(path, sizeof path, build, runner);
    return save_file(path, runner, text);
}

static int is_regular(const char *path) {
    struct stat st;
    return stat(path, &st) == 0 && S_ISREG(st.st_mode);
}

static int read_lines(const char *path, uint32_t runner, np_text_t *t) {
    size_t len = 0;
    uint8_t *text = np_read_whole_file(path, &len);
    if (!text) {
        struct stat st;
        if (stat(path, &st) != 0 ? errno == ENOENT : S_ISREG(st.st_mode) && st.st_size == 0)
            return 1;
        NP_ERR("defaults: cannot read %s", path);
        return 0;
    }
    int ok = len <= NP_DEFAULTS_TEXT_MAX;
    if (!ok) {
        NP_ERR("defaults: %s is over %d bytes, cannot read it", path, NP_DEFAULTS_TEXT_MAX);
    } else {
        int bad = each_line(runner, (const char *)text, len, put_line, t);
        if (bad) NP_WARN("defaults: %d bad line(s) in %s, left out", bad, path);
    }
    free(text);
    return ok && t->ok;
}

static DIR *open_folder_of(const char *family) {
    char dir[PATH_MAX];
    snprintf(dir, sizeof dir, "%s", family);
    char *slash = strrchr(dir, '/');
    if (!slash) return NULL;
    *slash = '\0';
    DIR *d = opendir(dir);
    if (!d) NP_ERR("defaults: cannot list %s: %s", dir, strerror(errno));
    return d;
}

static int remove_overrides_locked(DIR *d, uint32_t runner) {
    char suffix[16];
    snprintf(suffix, sizeof suffix, "-%s", g_runner_names[runner]);
    size_t pre = sizeof(OVERRIDE_PREFIX) - 1, suf = strlen(suffix);
    char (*builds)[NP_BUILD_ID_MAX + 1] = NULL;
    size_t count = 0, cap = 0;
    int ok = 1;
    for (struct dirent *e; (e = readdir(d)); ) {
        size_t n = strlen(e->d_name);
        if (n <= pre + suf || strncmp(e->d_name, OVERRIDE_PREFIX, pre) != 0
            || strcmp(e->d_name + n - suf, suffix) != 0)
            continue;
        char build[NP_BUILD_ID_MAX + 2];
        size_t bn = n - pre - suf;
        if (bn > NP_BUILD_ID_MAX) continue;
        memcpy(build, e->d_name + pre, bn);
        build[bn] = '\0';
        if (!np_is_build_id(build)) continue;
        if (count == cap) {
            void *more = realloc(builds, (cap = cap ? 2 * cap : 16) * sizeof *builds);
            if (!more) { free(builds); return 0; }
            builds = more;
        }
        memcpy(builds[count++], build, bn + 1);
    }
    for (size_t i = 0; i < count; i++) {
        char path[PATH_MAX];
        build_path(path, sizeof path, builds[i], runner);
        if (is_regular(path)) ok &= remove_locked(path);
    }
    free(builds);
    return ok;
}

int np_defaults_apply_build(const char *build, uint32_t runner) {
    if (runner > NP_DEFAULTS_FEX || !np_is_build_id(build)) {
        NP_ERR("defaults: no CrossOver build ID for runner %u, nothing applied", runner);
        return 0;
    }
    char own[PATH_MAX], family[PATH_MAX], body[NP_DEFAULTS_TEXT_MAX + 1] = "";
    build_path(own, sizeof own, build, runner);
    defaults_path(family, sizeof family, runner);
    np_text_t t = { body, sizeof body, 0, 1 };
    pthread_mutex_lock(&g_save_lock);
    DIR *d = open_folder_of(family);
    int ok = d && read_lines(is_regular(own) ? own : family, runner, &t) && write_locked(family, body, t.len);
    int done = ok ? (remove_overrides_locked(d, runner) ? 1 : -1) : 0;
    if (d) closedir(d);
    pthread_mutex_unlock(&g_save_lock);
    if (done > 0) NP_LOG("defaults: %s is now every %s version's set", build, g_runner_names[runner]);
    if (done < 0) NP_ERR("defaults: %s is every %s version's set, but some versions kept their own",
                         build, g_runner_names[runner]);
    return done;
}

int np_defaults_read(uint32_t runner, char *out, size_t size) {
    if (!out || !size) return 0;
    out[0] = '\0';
    if (runner > NP_DEFAULTS_FEX) return 0;
    char path[PATH_MAX];
    defaults_path(path, sizeof path, runner);
    np_text_t t = { out, size, 0, 1 };
    if (read_lines(path, runner, &t)) return 1;
    out[0] = '\0';
    return 0;
}

int np_defaults_read_build(const char *build, uint32_t runner, char *out, size_t size) {
    if (!out || !size) return -1;
    out[0] = '\0';
    if (runner > NP_DEFAULTS_FEX || !np_is_build_id(build)) return -1;
    char path[PATH_MAX];
    build_path(path, sizeof path, build, runner);
    if (!is_regular(path)) return 0;
    np_text_t t = { out, size, 0, 1 };
    if (read_lines(path, runner, &t)) return 1;
    out[0] = '\0';
    return -1;
}
