#define _DARWIN_C_SOURCE
#include "nativeplatform.h"

#include <errno.h>
#include <fcntl.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <time.h>
#include <unistd.h>

#define APPINFO_MAGIC_V29 0x07564429u
#define APPINFO_MAGIC_V28 0x07564428u
#define APPINFO_MAGIC_V27 0x07564427u
#define APPINFO_MAX_BYTES (64u * 1024u * 1024u)
#define APPINFO_MAX_IDS 100000u
#define REFRESH_SECONDS 300

typedef struct { const uint8_t *bytes; size_t length, position; } cursor;
typedef struct {
    dev_t dev; ino_t ino; off_t size;
    time_t mtime, ctime;
    long mtime_ns, ctime_ns;
} file_key;

static pthread_mutex_t cache_mutex = PTHREAD_MUTEX_INITIALIZER;
static np_nativeplatform_snapshot_t cached_snapshot;
static file_key cached_key;
static time_t checked_at;
static int cache_valid;
static uint64_t refresh_sequence;
static uint64_t snapshot_generation;

static int take(cursor *c, size_t n, const uint8_t **out) {
    if (n > c->length - c->position) return 0;
    if (out) *out = c->bytes + c->position;
    c->position += n;
    return 1;
}

static int u8(cursor *c, uint8_t *out) {
    const uint8_t *p;
    if (!take(c, 1, &p)) return 0;
    *out = p[0]; return 1;
}

static int u32(cursor *c, uint32_t *out) {
    const uint8_t *p;
    if (!take(c, 4, &p)) return 0;
    *out = (uint32_t)p[0] | (uint32_t)p[1] << 8 |
           (uint32_t)p[2] << 16 | (uint32_t)p[3] << 24;
    return 1;
}

static int u64(cursor *c, uint64_t *out) {
    const uint8_t *p;
    if (!take(c, 8, &p)) return 0;
    uint64_t v = 0;
    for (unsigned i = 0; i < 8; i++) v |= (uint64_t)p[i] << (8 * i);
    *out = v; return 1;
}

static int cstring(cursor *c, const char **out) {
    size_t start = c->position;
    while (c->position < c->length && c->bytes[c->position]) c->position++;
    if (c->position == c->length) return 0;
    if (out) *out = (const char *)c->bytes + start;
    c->position++;
    return 1;
}

static int read_table(cursor *c, const char ***out, size_t *count_out) {
    uint32_t count;
    if (!u32(c, &count) || count > APPINFO_MAX_IDS) return 0;
    const char **table = calloc(count ? count : 1, sizeof(*table));
    if (!table) return 0;
    for (uint32_t i = 0; i < count; i++) {
        if (!cstring(c, &table[i])) { free(table); return 0; }
    }
    *out = table; *count_out = count;
    return 1;
}

static int skip_value(cursor *c, uint8_t type, const char **table, size_t table_count,
                      unsigned depth);

static int skip_section(cursor *c, const char **table, size_t table_count, unsigned depth) {
    if (depth > 32) return 0;
    for (;;) {
        uint8_t type;
        if (!u8(c, &type)) return 0;
        if (type == 0x08 || type == 0x0b) return 1;
        uint32_t key;
        if (table) {
            if (!u32(c, &key) || key >= table_count) return 0;
        } else if (!cstring(c, NULL)) return 0;
        if (!skip_value(c, type, table, table_count, depth)) return 0;
    }
}

static int skip_value(cursor *c, uint8_t type, const char **table, size_t table_count,
                      unsigned depth) {
    if (type == 0x00) return skip_section(c, table, table_count, depth + 1);
    uint32_t ignored32; uint64_t ignored64;
    switch (type) {
        case 0x01: return cstring(c, NULL);
        case 0x02: case 0x03: case 0x04: case 0x06: return u32(c, &ignored32);
        case 0x05: {
            const uint8_t *p;
            while (take(c, 2, &p)) if (!p[0] && !p[1]) return 1;
            return 0;
        }
        case 0x07: case 0x0a: return u64(c, &ignored64);
        default: return 0;
    }
}

static int key_is(cursor *c, const char **table, size_t table_count,
                  const char *wanted) {
    if (table) {
        uint32_t index;
        if (!u32(c, &index) || index >= table_count) return -1;
        return strcmp(table[index], wanted) == 0;
    }
    const char *key;
    if (!cstring(c, &key)) return -1;
    return strcmp(key, wanted) == 0;
}

static int parse_common(cursor *c, const char **table, size_t table_count,
                        int *known, int *native, int *windows) {
    for (;;) {
        uint8_t type;
        if (!u8(c, &type)) return 0;
        if (type == 0x08 || type == 0x0b) return 1;
        int is_oslist = key_is(c, table, table_count, "oslist");
        if (is_oslist < 0) return 0;
        if (is_oslist && type == 0x01) {
            const char *value;
            if (!cstring(c, &value)) return 0;
            *known = 1;
            const char *token = value;
            while (*token) {
                const char *end = strchr(token, ',');
                size_t length = end ? (size_t)(end - token) : strlen(token);
                if (length == 5 && !memcmp(token, "macos", 5)) *native = 1;
                if (length == 7 && !memcmp(token, "windows", 7)) *windows = 1;
                if (!end) break;
                token = end + 1;
            }
        } else if (!skip_value(c, type, table, table_count, 2)) return 0;
    }
}

static int parse_appinfo_section(cursor *c, const char **table, size_t table_count,
                                 int *known, int *native, int *windows) {
    for (;;) {
        uint8_t type;
        if (!u8(c, &type)) return 0;
        if (type == 0x08 || type == 0x0b) return 1;
        int is_common = key_is(c, table, table_count, "common");
        if (is_common < 0) return 0;
        if (is_common && type == 0x00) {
            if (!parse_common(c, table, table_count, known, native, windows)) return 0;
        } else if (!skip_value(c, type, table, table_count, 1)) return 0;
    }
}

static int parse_entry(cursor *c, const char **table, size_t table_count,
                       int *known, int *native, int *windows) {
    for (;;) {
        uint8_t type;
        if (!u8(c, &type)) return 0;
        if (type == 0x08 || type == 0x0b) return 1;
        int is_appinfo = key_is(c, table, table_count, "appinfo");
        if (is_appinfo < 0) return 0;
        if (is_appinfo && type == 0x00) {
            if (!parse_appinfo_section(c, table, table_count, known, native, windows)) return 0;
        } else if (!skip_value(c, type, table, table_count, 0)) return 0;
    }
}

void np_nativeplatform_snapshot_free(np_nativeplatform_snapshot_t *snapshot) {
    if (!snapshot) return;
    free(snapshot->native_appids);
    free(snapshot->known_appids);
    free(snapshot->windows_appids);
    memset(snapshot, 0, sizeof(*snapshot));
}

int np_nativeplatform_parse_appinfo(const uint8_t *bytes, size_t length,
                                    np_nativeplatform_snapshot_t *out) {
    if (!bytes || !out || length < 16 || length > APPINFO_MAX_BYTES)
        return 0;
    memset(out, 0, sizeof(*out));
    cursor header = { bytes, length, 0 };
    uint32_t magic, ignored;
    if (!u32(&header, &magic) || !u32(&header, &ignored)) return 0;
    const char **table = NULL; size_t table_count = 0;
    size_t position; size_t entry_header = 60;
    if (magic == APPINFO_MAGIC_V29) {
        uint64_t offset;
        if (!u64(&header, &offset) || offset < 16 || offset >= length) return 0;
        cursor tc = { bytes, length, (size_t)offset };
        if (!read_table(&tc, &table, &table_count)) return 0;
        position = 16;
    } else if (magic == APPINFO_MAGIC_V28) position = 8;
    else if (magic == APPINFO_MAGIC_V27) { position = 8; entry_header = 40; }
    else return 0;

    uint32_t *native_ids = calloc(APPINFO_MAX_IDS, sizeof(*native_ids));
    uint32_t *known_ids = calloc(APPINFO_MAX_IDS, sizeof(*known_ids));
    uint32_t *windows_ids = calloc(APPINFO_MAX_IDS, sizeof(*windows_ids));
    if (!native_ids || !known_ids || !windows_ids) { free(table); free(native_ids); free(known_ids); free(windows_ids); return 0; }
    size_t native_count = 0, known_count = 0, windows_count = 0;
    int terminated = 0;
    while (position + 8 <= length) {
        cursor ec = { bytes, length, position };
        uint32_t appid, size;
        if (!u32(&ec, &appid) || !u32(&ec, &size)) goto fail;
        if (!appid) { terminated = 1; break; }
        if (!size || size < entry_header || size > length - position - 8) goto fail;
        int known = 0, native = 0, windows = 0;
        cursor data = { bytes, position + 8 + size, position + 8 + entry_header };
        if (!parse_entry(&data, table, table_count, &known, &native, &windows)) goto fail;
        if (known) {
            if (known_count == APPINFO_MAX_IDS) goto fail;
            known_ids[known_count++] = appid;
        }
        if (native) {
            if (native_count == APPINFO_MAX_IDS) goto fail;
            native_ids[native_count++] = appid;
        }
        if (windows) {
            if (windows_count == APPINFO_MAX_IDS) goto fail;
            windows_ids[windows_count++] = appid;
        }
        position += 8 + size;
    }
    if (!terminated) goto fail;
    free(table);
    if (!native_count) { free(native_ids); native_ids = NULL; }
    else {
        uint32_t *small = realloc(native_ids, native_count * sizeof(*native_ids));
        if (small) native_ids = small;
    }
    if (!known_count) { free(known_ids); known_ids = NULL; }
    else {
        uint32_t *small = realloc(known_ids, known_count * sizeof(*known_ids));
        if (small) known_ids = small;
    }
    out->native_appids = native_ids; out->native_count = native_count;
    out->known_appids = known_ids; out->known_count = known_count;
    if (!windows_count) { free(windows_ids); windows_ids = NULL; }
    else {
        uint32_t *small = realloc(windows_ids, windows_count * sizeof(*windows_ids));
        if (small) windows_ids = small;
    }
    out->windows_appids = windows_ids; out->windows_count = windows_count;
    return 1;
fail:
    free(table); free(native_ids); free(known_ids); free(windows_ids); return 0;
}

static file_key stat_key(const struct stat *st) {
    file_key k = { st->st_dev, st->st_ino, st->st_size,
                   st->st_mtimespec.tv_sec, st->st_ctimespec.tv_sec,
                   st->st_mtimespec.tv_nsec, st->st_ctimespec.tv_nsec };
    return k;
}

static int same_key(file_key a, file_key b) {
    return a.dev == b.dev && a.ino == b.ino && a.size == b.size &&
           a.mtime == b.mtime && a.ctime == b.ctime &&
           a.mtime_ns == b.mtime_ns && a.ctime_ns == b.ctime_ns;
}

static char *appinfo_path(void) {
    const char *home = getenv("HOME");
    if (!home || !*home) return NULL;
    size_t n = strlen(home) + sizeof("/Library/Application Support/Steam/appcache/appinfo.vdf");
    char *path = malloc(n);
    if (path) snprintf(path, n, "%s/Library/Application Support/Steam/appcache/appinfo.vdf", home);
    return path;
}

static int refresh_cache(void) {
    char *path = appinfo_path();
    if (!path) return 0;
    int fd = open(path, O_RDONLY);
    if (fd < 0) { free(path); return 0; }
    struct stat st;
    if (fstat(fd, &st) || !S_ISREG(st.st_mode) || st.st_size <= 0 ||
        (uintmax_t)st.st_size > APPINFO_MAX_BYTES) {
        close(fd); free(path); return 0;
    }
    file_key key = stat_key(&st);
    time_t now = time(NULL);
    pthread_mutex_lock(&cache_mutex);
    if (cache_valid && same_key(key, cached_key) && now >= checked_at &&
        now - checked_at < REFRESH_SECONDS) {
        pthread_mutex_unlock(&cache_mutex); close(fd); free(path); return 1;
    }
    uint64_t my_sequence = ++refresh_sequence;
    if (!my_sequence) my_sequence = ++refresh_sequence;
    pthread_mutex_unlock(&cache_mutex);
    size_t length = (size_t)st.st_size;
    uint8_t *bytes = malloc(length);
    size_t done = 0;
    while (bytes && done < length) {
        ssize_t n = read(fd, bytes + done, length - done);
        if (n < 0 && errno == EINTR) continue;
        if (n <= 0) break;
        done += (size_t)n;
    }
    struct stat after;
    int stable = done == length && fstat(fd, &after) == 0 && same_key(key, stat_key(&after));
    close(fd);
    int current_path = 0;
    if (stable) {
        int verify = open(path, O_RDONLY);
        struct stat current;
        current_path = verify >= 0 && fstat(verify, &current) == 0 &&
                       same_key(key, stat_key(&current));
        if (verify >= 0) close(verify);
    }
    free(path);
    np_nativeplatform_snapshot_t fresh = {0};
    int parsed = stable && current_path &&
                 np_nativeplatform_parse_appinfo(bytes, length, &fresh);
    free(bytes);
    if (!parsed) { np_nativeplatform_snapshot_free(&fresh); return 0; }
    pthread_mutex_lock(&cache_mutex);
    if (my_sequence != refresh_sequence) {
        pthread_mutex_unlock(&cache_mutex);
        np_nativeplatform_snapshot_free(&fresh);
        return 0;
    }
    int changed = !cache_valid ||
        fresh.native_count != cached_snapshot.native_count ||
        fresh.known_count != cached_snapshot.known_count ||
        fresh.windows_count != cached_snapshot.windows_count ||
        (fresh.windows_count && memcmp(fresh.windows_appids, cached_snapshot.windows_appids,
                                      fresh.windows_count * sizeof(uint32_t))) ||
        (fresh.native_count && memcmp(fresh.native_appids, cached_snapshot.native_appids,
                                     fresh.native_count * sizeof(uint32_t))) ||
        (fresh.known_count && memcmp(fresh.known_appids, cached_snapshot.known_appids,
                                    fresh.known_count * sizeof(uint32_t)));
    np_nativeplatform_snapshot_free(&cached_snapshot);
    cached_snapshot = fresh;
    if (changed) {
        snapshot_generation++;
        if (!snapshot_generation) snapshot_generation++;
    }
    cached_key = key; checked_at = now; cache_valid = 1;
    pthread_mutex_unlock(&cache_mutex);
    return 1;
}

uint64_t np_nativeplatform_generation(void) {
    if (!refresh_cache()) return 0;
    pthread_mutex_lock(&cache_mutex);
    uint64_t generation = snapshot_generation;
    pthread_mutex_unlock(&cache_mutex);
    return generation;
}

char *np_nativeplatform_javascript(uint64_t *out_generation) {
    if (!refresh_cache()) return NULL;
    pthread_mutex_lock(&cache_mutex);
    size_t total = cached_snapshot.native_count + cached_snapshot.known_count + cached_snapshot.windows_count;
    size_t cap = 256 + total * 12;
    char *js = malloc(cap);
    if (!js) { pthread_mutex_unlock(&cache_mutex); return NULL; }
    size_t used = (size_t)snprintf(js, cap,
        "window.__NOTPROTON_NATIVE_PLATFORM__={g:%llu,mac:new Set([",
        (unsigned long long)snapshot_generation);
    for (size_t i = 0; i < cached_snapshot.native_count; i++) {
        int n = snprintf(js + used, cap - used, "%s%u", i ? "," : "",
                         cached_snapshot.native_appids[i]);
        if (n < 0 || (size_t)n >= cap - used) { free(js); pthread_mutex_unlock(&cache_mutex); return NULL; }
        used += (size_t)n;
    }
    int n = snprintf(js + used, cap - used, "]),known:new Set([");
    if (n < 0 || (size_t)n >= cap - used) { free(js); pthread_mutex_unlock(&cache_mutex); return NULL; }
    used += (size_t)n;
    for (size_t i = 0; i < cached_snapshot.known_count; i++) {
        n = snprintf(js + used, cap - used, "%s%u", i ? "," : "",
                     cached_snapshot.known_appids[i]);
        if (n < 0 || (size_t)n >= cap - used) { free(js); pthread_mutex_unlock(&cache_mutex); return NULL; }
        used += (size_t)n;
    }
    n = snprintf(js + used, cap - used, "]),windows:new Set([");
    if (n < 0 || (size_t)n >= cap - used) { free(js); pthread_mutex_unlock(&cache_mutex); return NULL; }
    used += (size_t)n;
    for (size_t i = 0; i < cached_snapshot.windows_count; i++) {
        n = snprintf(js + used, cap - used, "%s%u", i ? "," : "",
                     cached_snapshot.windows_appids[i]);
        if (n < 0 || (size_t)n >= cap - used) { free(js); pthread_mutex_unlock(&cache_mutex); return NULL; }
        used += (size_t)n;
    }
    n = snprintf(js + used, cap - used, "])};\n");
    if (n < 0 || (size_t)n >= cap - used) { free(js); pthread_mutex_unlock(&cache_mutex); return NULL; }
    if (out_generation) *out_generation = snapshot_generation;
    pthread_mutex_unlock(&cache_mutex);
    return js;
}
