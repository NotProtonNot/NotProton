// Enables Steam Play in the UI/enables the Compatibility tab in game properties
#include "webpatch.h"
#include "nativeplatform.h"
#include "../util/file.h"
#include "../util/log.h"

#include <dirent.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>

#define NP_C1 "\001"
#define NP_C2 "\002"
#define NP_C3 "\003"
#define NP_C4 "\004"
#define NP_C5 "\005"
#define NP_C6 "\006"
#define NP_C7 "\007"
#define NP_C8 "\010"
// 9-12 sit past whitespace and the \021/\022 markers.
#define NP_C9 "\023"
#define NP_C10 "\024"
#define NP_C11 "\025"
#define NP_C12 "\026"
#define NP_CAP_MAX 12

// Stands for the name set by np_webpatch_set_fallback_tool.
#define NP_FALLBACK_TOOL "\021"
// Stands for the JS array set by np_webpatch_set_fex_tools.
#define NP_FEX_TOOLS "\022"
// MSCXReady and MSCXFeat.
#define NP_READY "\027"
#define NP_FEATS "\030"
// Stands for the runner variants read from the support directory.
#define NP_VARS "\031"

#define NP_TOOL_NAME_MAX 128

static _Thread_local char g_fallback_tool[NP_TOOL_NAME_MAX];
static _Thread_local char g_fex_tools[NP_WEBPATCH_FEX_TOOLS_MAX * (NP_TOOL_NAME_MAX + 3) + 3] = "[]";

typedef struct {
    const char *find;
    const char *replace;
    int         expect;   // exact occurrence count, else abort
    int         optional; // skipped in the event that it doesn't match the current Steam client
} np_gate_t;

#define NP_GATE_MAX 32

typedef struct { const char *at; size_t len; } np_cap_t;

static int is_ident_char(unsigned char c) {
    return (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') ||
           (c >= '0' && c <= '9') || c == '_' || c == '$';
}

static int cap_index(unsigned char c) {
    if (c >= (unsigned char)NP_C1[0] && c <= (unsigned char)NP_C8[0]) return c - NP_C1[0];
    if (c >= (unsigned char)NP_C9[0] && c <= (unsigned char)NP_C12[0]) return c - NP_C9[0] + 8;
    return -1;
}

static int is_tool_name(const char *name) {
    size_t n = strlen(name);
    if (n >= NP_TOOL_NAME_MAX) return 0;
    for (size_t i = 0; i < n; i++)
        if (!is_ident_char((unsigned char)name[i]) && name[i] != '.' && name[i] != '-')
            return 0;
    return 1;
}

void np_webpatch_set_fallback_tool(const char *name) {
    g_fallback_tool[0] = '\0';
    if (name && is_tool_name(name))
        memcpy(g_fallback_tool, name, strlen(name) + 1);
}

void np_webpatch_set_fex_tools(const char *const *names, size_t count) {
    size_t n = 0;
    g_fex_tools[n++] = '[';
    for (size_t i = 0; i < count && i < NP_WEBPATCH_FEX_TOOLS_MAX; i++) {
        if (!names[i] || !*names[i] || !is_tool_name(names[i])) continue;
        size_t len = strlen(names[i]);
        if (n > 1) g_fex_tools[n++] = ',';
        g_fex_tools[n++] = '"';
        memcpy(g_fex_tools + n, names[i], len);
        n += len;
        g_fex_tools[n++] = '"';
    }
    g_fex_tools[n++] = ']';
    g_fex_tools[n] = '\0';
}

static int has_suffix(const char *s, const char *suf);

// "Developer" section rows are declared in ~/Library/Application Support/notproton/plugins/*.conf,
// one "key = value" per line, applied at launch by compat_run.sh.
#define NP_FEAT_DIR      "Library/Application Support/notproton/plugins"
#define NP_FEAT_MAX      32
#define NP_FEAT_REQ_MAX  4
#define NP_FEAT_STR      192
#define NP_FEAT_DESC     512

typedef struct {
    char key[NP_FEAT_STR];
    char label[NP_FEAT_STR];
    char desc[NP_FEAT_DESC];
    char section[32];
    char on[32];
    char off[32];
    char depends[NP_FEAT_STR];
    char req[NP_FEAT_REQ_MAX][NP_FEAT_STR];
    int  nreq;
} np_feat_t;

static int feat_exists(const char *home, const char *rel) {
    char path[2048];
    struct stat st;
    if (!rel || !*rel) return 0;
    if (*rel == '/') return stat(rel, &st) == 0 && S_ISREG(st.st_mode);
    if (snprintf(path, sizeof(path), "%s/%s", home, rel) >= (int)sizeof(path)) return 0;
    return stat(path, &st) == 0 && S_ISREG(st.st_mode);
}

// isspace() without the locale, to match [[:space:]] in compat_run.sh.
static int feat_space(char c) {
    return c == ' ' || (c >= '\t' && c <= '\r');
}

static void feat_trim(char *v) {
    size_t n = strlen(v);
    while (n && feat_space(v[n - 1])) v[--n] = 0;
}

// compat_run.sh ignores keys that aren't valid shell variable names, so the compatibility panel does the same thing
static int feat_key_ok(const char *k) {
    if (strncmp(k, "NOTPROTON_", 10) != 0 || !k[10]) return 0;
    for (k += 10; *k; k++)
        if (!((*k >= 'A' && *k <= 'Z') || (*k >= '0' && *k <= '9') || *k == '_')) return 0;
    return 1;
}

// Takes the first value when a setting appears twice so as to match compat_run.sh.
static void feat_set(char *dst, size_t size, const char *v, int *bad) {
    if (*dst) return;
    if (strlen(v) >= size) *bad = 1;
    snprintf(dst, size, "%s", v);
}

static np_feat_t *feat_find(np_feat_t *list, int n, const char *key) {
    for (int i = 0; i < n; i++)
        if (strcmp(list[i].key, key) == 0) return &list[i];
    return NULL;
}

// Unknown fields are ignored so a plugin file written for a later version still loads.
static void feat_read_file(const char *path, np_feat_t *list, int *count) {
    char line[2048];
    np_feat_t f;
    int bad = 0;
    FILE *fp = fopen(path, "r");
    if (!fp) return;
    memset(&f, 0, sizeof(f));
    while (fgets(line, sizeof(line), fp)) {
        char *eq, *v, *k = line;
        size_t len = strcspn(line, "\n");
        if (len >= sizeof(line) - 1) {
            NP_WARN("plugins: %s has a line over %zu bytes, ignored", path, sizeof(line) - 2);
            fclose(fp);
            return;
        }
        line[len] = 0;
        while (feat_space(*k)) k++;
        if (*k == '#' || !(eq = strchr(k, '='))) continue;
        *eq = 0;
        v = eq + 1;
        feat_trim(k);
        while (feat_space(*v)) v++;
        feat_trim(v);
        if (!*v) continue;
        if (strcmp(k, "key") == 0) feat_set(f.key, sizeof(f.key), v, &bad);
        else if (strcmp(k, "label") == 0) feat_set(f.label, sizeof(f.label), v, &bad);
        else if (strcmp(k, "description") == 0) feat_set(f.desc, sizeof(f.desc), v, &bad);
        else if (strcmp(k, "section") == 0) feat_set(f.section, sizeof(f.section), v, &bad);
        else if (strcmp(k, "on") == 0) feat_set(f.on, sizeof(f.on), v, &bad);
        else if (strcmp(k, "off") == 0) feat_set(f.off, sizeof(f.off), v, &bad);
        else if (strcmp(k, "depends") == 0) feat_set(f.depends, sizeof(f.depends), v, &bad);
        else if (strcmp(k, "requires") == 0 && f.nreq < NP_FEAT_REQ_MAX)
            feat_set(f.req[f.nreq++], NP_FEAT_STR, v, &bad);
    }
    fclose(fp);
    if (bad) {
        NP_WARN("plugins: %s has a value that's too long, ignored", path);
        return;
    }
    if (!*f.on) snprintf(f.on, sizeof(f.on), "1");
    if (!*f.section) snprintf(f.section, sizeof(f.section), "dev");
    if (!*f.key) {
        NP_WARN("plugins: %s has no key, ignored", path);
        return;
    }
    if (!feat_key_ok(f.key)) {
        NP_WARN("plugins: %s has an invalid key %s, ignored", path, f.key);
        return;
    }
    if (!*f.label) {
        NP_WARN("plugins: %s has no label, ignored", path);
        return;
    }
    if (strcmp(f.section, "dev") != 0) {
        NP_WARN("plugins: %s is not in the dev section, ignored", path);
        return;
    }
    if (feat_find(list, *count, f.key)) {
        NP_WARN("plugins: %s repeats key %s, ignored", path, f.key);
        return;
    }
    if (*count >= NP_FEAT_MAX) {
        NP_WARN("plugins: %s is over the %d plugin limit, ignored", path, NP_FEAT_MAX);
        return;
    }
    list[(*count)++] = f;
}

static int feat_load(const char *home, np_feat_t *list) {
    char dir[2048];
    struct dirent *de;
    DIR *d;
    int count = 0;
    char **names = NULL;
    int nnames = 0;

    if (snprintf(dir, sizeof(dir), "%s/" NP_FEAT_DIR, home) >= (int)sizeof(dir)) return 0;
    if ((d = opendir(dir))) {
        while ((de = readdir(d))) {
            char **grown;
            if (de->d_name[0] == '.' || strchr(de->d_name, '\n')) continue;
            if (!has_suffix(de->d_name, ".conf")) continue;
            grown = realloc(names, (size_t)(nnames + 1) * sizeof(*names));
            if (!grown) break;
            names = grown;
            names[nnames] = strdup(de->d_name);
            if (!names[nnames]) break;
            nnames++;
        }
        closedir(d);
        for (int i = 1; i < nnames; i++)
            for (int j = i; j > 0 && strcmp(names[j - 1], names[j]) > 0; j--) {
                char *t = names[j - 1]; names[j - 1] = names[j]; names[j] = t;
            }
        for (int i = 0; i < nnames; i++) {
            char path[4096];
            if (snprintf(path, sizeof(path), "%s/%s", dir, names[i]) < (int)sizeof(path))
                feat_read_file(path, list, &count);
            free(names[i]);
        }
        free(names);
    }

    return count;
}

static _Thread_local char g_feat_ready[NP_FEAT_MAX * (NP_FEAT_STR + 8) + 4] = "{}";
static _Thread_local char g_feat_rows[NP_FEAT_MAX * (2 * (3 * NP_FEAT_STR + NP_FEAT_DESC + 64) + 32) + 4] = "[]";
static _Thread_local int  g_feat_ready_done;
static _Thread_local int  g_feat_pinned;
static _Thread_local char g_var_rows[8192] = "[]";
static _Thread_local int  g_var_done;
static void feat_build(void);
static void var_build(void);

static const char *marker_text(char c) {
    if (c == NP_FALLBACK_TOOL[0]) return g_fallback_tool;
    if (c == NP_FEX_TOOLS[0]) return g_fex_tools;
    if (c == NP_READY[0] || c == NP_FEATS[0]) {
        if (!g_feat_ready_done) feat_build();
        return c == NP_READY[0] ? g_feat_ready : g_feat_rows;
    }
    if (c == NP_VARS[0]) {
        if (!g_var_done) var_build();
        return g_var_rows;
    }
    return NULL;
}

static size_t match_at(const char *src, size_t len, size_t pos,
                       const char *find, np_cap_t *caps) {
    if (cap_index((unsigned char)find[0]) < 0 && !marker_text(find[0]) && src[pos] != find[0])
        return 0;
    for (int i = 0; i < NP_CAP_MAX; i++) { caps[i].at = NULL; caps[i].len = 0; }

    if (cap_index((unsigned char)find[0]) >= 0 && pos &&
        (is_ident_char((unsigned char)src[pos - 1]) || src[pos - 1] == '.')) return 0;

    size_t s = pos;
    for (const char *f = find; *f; f++) {
        const char *text = marker_text(*f);
        if (text) {
            size_t n = strlen(text);
            if (s + n > len || memcmp(src + s, text, n) != 0) return 0;
            s += n;
            continue;
        }
        int ci = cap_index((unsigned char)*f);
        if (ci < 0) {
            if (s >= len || src[s] != *f) return 0;
            s++;
            continue;
        }

        if (s >= len || (src[s] >= '0' && src[s] <= '9')) return 0;
        size_t run = 0;
        while (s + run < len && is_ident_char((unsigned char)src[s + run])) run++;
        if (run == 0) return 0;

        if (caps[ci].at) {
            if (run != caps[ci].len || memcmp(src + s, caps[ci].at, run) != 0)
                return 0;
        } else {
            caps[ci].at = src + s;
            caps[ci].len = run;
        }
        s += run;
    }
    return s - pos;
}

static void mark_start(unsigned char *can_start, const char *find) {
    if (marker_text(find[0])) {
        memset(can_start, 1, 256);
    } else if (cap_index((unsigned char)find[0]) >= 0) {
        for (int c = 0; c < 256; c++)
            if (is_ident_char((unsigned char)c) && !(c >= '0' && c <= '9')) can_start[c] = 1;
    } else {
        can_start[(unsigned char)find[0]] = 1;
    }
}

static size_t count_matches(const char *src, size_t len, const char *find) {
    np_cap_t caps[NP_CAP_MAX];
    size_t n = 0, lit = 0;
    while (find[lit] && cap_index((unsigned char)find[lit]) < 0 && !marker_text(find[lit])) lit++;
    for (size_t i = 0; i < len; ) {
        if (lit) {
            const char *at = memmem(src + i, len - i, find, lit);
            if (!at) break;
            i = (size_t)(at - src);
        }
        size_t used = match_at(src, len, i, find, caps);
        if (used) { n++; i += used; } else i++;
    }
    return n;
}

typedef struct { char *buf; size_t len, cap; } np_out_t;

static int out_reserve(np_out_t *o, size_t extra) {
    if (o->len + extra + 1 <= o->cap) return 1;
    size_t want = o->cap ? o->cap : 1024;
    while (want < o->len + extra + 1) want *= 2;
    char *grown = realloc(o->buf, want);
    if (!grown) return 0;
    o->buf = grown;
    o->cap = want;
    return 1;
}

static int out_put(np_out_t *o, const char *p, size_t n) {
    if (!out_reserve(o, n)) return 0;
    memcpy(o->buf + o->len, p, n);
    o->len += n;
    return 1;
}

static int out_jsstr(np_out_t *o, const char *v) {
    if (!out_put(o, "\"", 1)) return 0;
    for (const char *p = v; *p; p++) {
        if (*p == '"' || *p == '\\') { if (!out_put(o, "\\", 1)) return 0; }
        else if ((unsigned char)*p < 0x20) continue;
        if (!out_put(o, p, 1)) return 0;
    }
    return out_put(o, "\"", 1);
}

static void feat_build(void) {
    const char *home = getenv("HOME");
    np_feat_t list[NP_FEAT_MAX];
    np_out_t ready = { 0 }, rows = { 0 };
    int n = 0, wrote = 0;

    g_feat_ready_done = 1;
    snprintf(g_feat_ready, sizeof(g_feat_ready), "{}");
    snprintf(g_feat_rows, sizeof(g_feat_rows), "[]");
    if (!home) return;
    n = feat_load(home, list);
    if (!out_put(&ready, "{", 1) || !out_put(&rows, "[", 1)) goto done;
    for (int i = 0; i < n; i++) {
        int ok = list[i].nreq == 0;
        char item[NP_FEAT_STR + 32];
        int len;
        for (int j = 0; j < list[i].nreq; j++)
            if (feat_exists(home, list[i].req[j])) { ok = 1; break; }
        len = snprintf(item, sizeof(item), "%s\"%s\":%d", i ? "," : "", list[i].key, ok);
        if (len < 0 || len >= (int)sizeof(item) || !out_put(&ready, item, (size_t)len)) goto done;

        if (wrote++ && !out_put(&rows, ",", 1)) goto done;
        if (!out_put(&rows, "{k:", 3) || !out_jsstr(&rows, list[i].key)) goto done;
        if (!out_put(&rows, ",l:", 3) || !out_jsstr(&rows, list[i].label)) goto done;
        if (!out_put(&rows, ",on:", 4) || !out_jsstr(&rows, list[i].on)) goto done;
        if (!out_put(&rows, ",off:", 5) || !out_jsstr(&rows, list[i].off)) goto done;
        if (!out_put(&rows, ",dep:", 5) || !out_jsstr(&rows, list[i].depends)) goto done;
        if (!out_put(&rows, ",d:", 3) || !out_jsstr(&rows, list[i].desc)) goto done;
        if (!out_put(&rows, "}", 1)) goto done;
    }
    if (!out_put(&ready, "}", 1) || !out_put(&rows, "]", 1)) goto done;
    if (ready.len < sizeof(g_feat_ready) && rows.len < sizeof(g_feat_rows)) {
        snprintf(g_feat_ready, sizeof(g_feat_ready), "%.*s", (int)ready.len, ready.buf);
        snprintf(g_feat_rows, sizeof(g_feat_rows), "%.*s", (int)rows.len, rows.buf);
    } else {
        NP_WARN("plugins: too large to show, all ignored");
    }
done:
    free(ready.buf);
    free(rows.buf);
}

void np_webpatch_set_features(const char *ready, const char *rows) {
    snprintf(g_feat_ready, sizeof(g_feat_ready), "%s", ready ? ready : "{}");
    snprintf(g_feat_rows, sizeof(g_feat_rows), "%s", rows ? rows : "[]");
    g_feat_ready_done = 1;
    g_feat_pinned = 1;
}

// Runner variants are declared in the support directory's variants/*.conf and assembled by
// compat_run.sh at launch.
#define NP_VAR_MAX  24
#define NP_VAR_STR  192

typedef struct {
    char name[NP_VAR_STR];
    char label[NP_VAR_STR];
    char variant[NP_VAR_STR];
    char src[1024];
    char dst[NP_VAR_STR];
} np_var_t;

#define NP_VAR_TOOLS_MAX 8
static _Thread_local char g_var_tool[NP_VAR_TOOLS_MAX][NP_TOOL_NAME_MAX];
static _Thread_local char g_var_build[NP_VAR_TOOLS_MAX][NP_TOOL_NAME_MAX];
static _Thread_local char g_var_arch[NP_VAR_TOOLS_MAX][NP_TOOL_NAME_MAX];
static _Thread_local size_t g_var_tools;

void np_webpatch_set_tool_builds(const char *const *names, const char *const *builds,
                                 const char *const *archs, size_t count) {
    g_var_tools = 0;
    for (size_t i = 0; i < count && g_var_tools < NP_VAR_TOOLS_MAX; i++) {
        if (!names[i] || !*names[i] || !builds[i] || !*builds[i]) continue;
        if (!is_tool_name(names[i]) || !is_tool_name(builds[i])) continue;
        snprintf(g_var_tool[g_var_tools], NP_TOOL_NAME_MAX, "%s", names[i]);
        snprintf(g_var_build[g_var_tools], NP_TOOL_NAME_MAX, "%s", builds[i]);
        snprintf(g_var_arch[g_var_tools], NP_TOOL_NAME_MAX, "%s",
                 archs && archs[i] ? archs[i] : "");
        g_var_tools++;
    }
}

// A directory named for an architecture, such as x86_64-windows, only serves the tool
// that runs that architecture
static const char *var_arch_of(const char *dir) {
    static const char *const known[] = { "x86_64", "aarch64", "i386", "arm64ec" };
    for (size_t i = 0; i < sizeof(known) / sizeof(*known); i++) {
        size_t n = strlen(known[i]);
        if (strncmp(dir, known[i], n) == 0 && (dir[n] == 0 || dir[n] == '-'))
            return known[i];
    }
    return NULL;
}

static int var_is_dir(const char *path) {
    struct stat st;
    return stat(path, &st) == 0 && S_ISDIR(st.st_mode);
}

// Every directory in src that holds a file, relative to src; "" is src itself. Bounded,
// since this runs while Steam waits for a page.
static int var_dirs(const char *root, const char *rel, char dirs[][NP_VAR_STR], int n,
                    int depth) {
    char path[2048];
    struct dirent *de;
    DIR *d;
    int files = 0;

    if (depth > 3 || n >= 16) return n;
    if (snprintf(path, sizeof(path), "%s%s%s", root, *rel ? "/" : "", rel) >= (int)sizeof(path))
        return n;
    if (!(d = opendir(path))) return n;
    while ((de = readdir(d))) {
        char sub[NP_VAR_STR];
        if (de->d_name[0] == '.') continue;
        if (snprintf(sub, sizeof(sub), "%s%s%s", rel, *rel ? "/" : "", de->d_name)
            >= (int)sizeof(sub)) continue;
        if (snprintf(path, sizeof(path), "%s/%s", root, sub) >= (int)sizeof(path)) continue;
        if (var_is_dir(path)) n = var_dirs(root, sub, dirs, n, depth + 1);
        else files = 1;
    }
    closedir(d);
    if (files && n < 16) snprintf(dirs[n++], NP_VAR_STR, "%s", rel);
    return n;
}

static void var_read_file(const char *path, const char *home, np_var_t *list, int *count) {
    char line[2048];
    np_var_t v;
    const char *base = strrchr(path, '/');
    FILE *fp;
    size_t len;

    memset(&v, 0, sizeof(v));
    base = base ? base + 1 : path;
    snprintf(v.name, sizeof(v.name), "%s", base);
    len = strlen(v.name);
    if (len > 5) v.name[len - 5] = 0;          // drop .conf
    for (const char *p = v.name; *p; p++)
        if (!((*p >= 'A' && *p <= 'Z') || (*p >= 'a' && *p <= 'z') ||
              (*p >= '0' && *p <= '9') || *p == '.' || *p == '-')) {
            NP_WARN("variants: %s is not a usable variant name, ignored", base);
            return;
        }

    if (!(fp = fopen(path, "r"))) return;
    while (fgets(line, sizeof(line), fp)) {
        char *eq, *val, *k = line;
        while (*k == ' ' || *k == '\t') k++;
        if (*k == '#' || !(eq = strchr(k, '='))) continue;
        *eq = 0;
        val = eq + 1;
        feat_trim(k);
        while (*val == ' ' || *val == '\t') val++;
        feat_trim(val);
        if (!*val) continue;
        if (strcmp(k, "label") == 0) snprintf(v.label, sizeof(v.label), "%s", val);
        else if (strcmp(k, "variant") == 0) snprintf(v.variant, sizeof(v.variant), "%s", val);
        else if (strcmp(k, "src") == 0) snprintf(v.src, sizeof(v.src), "%s", val);
        else if (strcmp(k, "dst") == 0) snprintf(v.dst, sizeof(v.dst), "%s", val);
        else {
            // Refused rather than ignored, as in features.d: a typo that looks like it
            // worked is worse than a variant that does not appear.
            NP_WARN("variants: %s declares '%s', which is not a variant field; "
                    "the fields are label, variant, src and dst", path, k);
            fclose(fp);
            return;
        }
    }
    fclose(fp);

    if (!*v.src || !*v.dst) {
        NP_WARN("variants: %s needs both src and dst, ignored", path);
        return;
    }
    if (v.dst[0] == '/' || strstr(v.dst, "..")) {
        NP_WARN("variants: %s dst must be a relative path inside the runner, ignored", path);
        return;
    }
    if (v.src[0] != '/') {
        char abs[1024];
        if (snprintf(abs, sizeof(abs), "%s/%s", home, v.src) >= (int)sizeof(abs)) return;
        snprintf(v.src, sizeof(v.src), "%s", abs);
    }
    if (!*v.label) snprintf(v.label, sizeof(v.label), "%s", v.name);
    if (!*v.variant) snprintf(v.variant, sizeof(v.variant), "Runner");
    if (*count >= NP_VAR_MAX) {
        NP_WARN("variants: more than %d descriptors, %s ignored", NP_VAR_MAX, path);
        return;
    }
    list[(*count)++] = v;
}

static int var_load(const char *home, np_var_t *list) {
    char dir[2048];
    struct dirent *de;
    DIR *d;
    int count = 0;
    char **names = NULL;
    int nnames = 0;

    np_support_path(dir, sizeof(dir), home, "variants");
    if (!(d = opendir(dir))) return 0;
    while ((de = readdir(d))) {
        char **grown;
        if (de->d_name[0] == '.') continue;
        if (!has_suffix(de->d_name, ".conf")) continue;
        grown = realloc(names, (size_t)(nnames + 1) * sizeof(*names));
        if (!grown) break;
        names = grown;
        names[nnames] = strdup(de->d_name);
        if (!names[nnames]) break;
        nnames++;
    }
    closedir(d);
    for (int i = 1; i < nnames; i++)
        for (int j = i; j > 0 && strcmp(names[j - 1], names[j]) > 0; j--) {
            char *t = names[j - 1]; names[j - 1] = names[j]; names[j] = t;
        }
    for (int i = 0; i < nnames; i++) {
        char path[4096];
        if (snprintf(path, sizeof(path), "%s/%s", dir, names[i]) < (int)sizeof(path))
            var_read_file(path, home, list, &count);
        free(names[i]);
    }
    free(names);
    return count;
}

static void var_build(void) {
    const char *home = getenv("HOME");
    np_var_t list[NP_VAR_MAX];
    np_out_t rows = { 0 };
    int n, wrote = 0;

    g_var_done = 1;
    if (!home) return;
    n = var_load(home, list);
    if (!out_put(&rows, "[", 1)) goto done;
    for (int i = 0; i < n; i++) {
        char dirs[16][NP_VAR_STR];
        int ndirs = var_dirs(list[i].src, "", dirs, 0, 0);
        int fits = 0;

        if (!ndirs) {
            NP_WARN("variants: %s holds no files at %s, not offered",
                    list[i].name, list[i].src);
            continue;
        }
        if (wrote && !out_put(&rows, ",", 1)) goto done;
        if (!out_put(&rows, "{k:", 3) || !out_jsstr(&rows, list[i].name)) goto done;
        if (!out_put(&rows, ",l:", 3) || !out_jsstr(&rows, list[i].label)) goto done;
        if (!out_put(&rows, ",v:", 3) || !out_jsstr(&rows, list[i].variant)) goto done;
        if (!out_put(&rows, ",t:[", 4)) goto done;
        for (size_t t = 0; t < g_var_tools; t++) {
            char runner[2048];
            int lands = 0, named = 0, matched = 0;
            np_support_path(runner, sizeof(runner), home, "runners");
            for (int j = 0; j < ndirs; j++) {
                char at[2048];
                const char *arch = var_arch_of(dirs[j]);
                if (snprintf(at, sizeof(at), "%s/crossover-%s/CrossOver/%s%s%s", runner,
                             g_var_build[t], list[i].dst, *dirs[j] ? "/" : "", dirs[j])
                    >= (int)sizeof(at)) continue;
                if (arch) named = 1;
                if (!var_is_dir(at)) continue;
                lands = 1;
                // A FEX runner holds both slots, so a directory landing is not enough:
                // arm64 Wine reads the aarch64 one and never looks at the other.
                if (arch && strcmp(arch, g_var_arch[t]) == 0) matched = 1;
            }
            if (!lands || (named && !matched)) continue;
            if (fits++ && !out_put(&rows, ",", 1)) goto done;
            if (!out_jsstr(&rows, g_var_tool[t])) goto done;
        }
        if (!out_put(&rows, "]}", 2)) goto done;
        wrote++;
        if (!fits)
            NP_LOG("variants: %s fits no installed runner, so it is offered nowhere",
                   list[i].name);
    }
    if (!out_put(&rows, "]", 1)) goto done;
    if (rows.len < sizeof(g_var_rows))
        snprintf(g_var_rows, sizeof(g_var_rows), "%.*s", (int)rows.len, rows.buf);
    else
        NP_WARN("variants: descriptors are too large to render, ignoring them");
done:
    free(rows.buf);
}

// A check supplies the list rather than reading whatever an install happens to carry
void np_webpatch_set_variants(const char *rows) {
    snprintf(g_var_rows, sizeof(g_var_rows), "%s", rows ? rows : "[]");
    g_var_done = 1;
}

static int out_expand(np_out_t *o, const char *replace, const np_cap_t *caps) {
    for (const char *r = replace; *r; r++) {
        const char *text = marker_text(*r);
        if (text) {
            if (!out_put(o, text, strlen(text))) return 0;
            continue;
        }
        int ci = cap_index((unsigned char)*r);
        if (ci < 0) {
            if (!out_put(o, r, 1)) return 0;
        } else {
            if (!caps[ci].at) return 0;
            if (!out_put(o, caps[ci].at, caps[ci].len)) return 0;
        }
    }
    return 1;
}

// Finds the launch options set before %command%.
#define NP_CX_LAUNCH_PARSE \
    "E=(()=>{let i=0,c=[];const cs=[c]," \
    "qs=x=>{while(i<o.length&&o[i]!==x)i+=x!==\"'\"&&o[i]==='\\\\'?2:1;i++}," \
    "nest=(a,b)=>{for(let d=1;i<o.length&&d;){const x=o[i++];" \
    "if(x==='\\\\')i++;else if(\"'\\\"`\".includes(x))qs(x);else if(x===a)d++;else if(x===b)d--}}," \
    "wd=()=>{const s=i;let v=\"\",q=0,l=1;while(i<o.length){const x=o[i];" \
    "if(q===39){if(x===\"'\")q=0;else v+=x;i++;continue}" \
    "if(x==='\\\\'){const n=o[i+1]||\"\";if(q&&!'\"\\\\$`\\n'.includes(n)){v+=x;i++;continue}" \
    "if(n!=='\\n')v+=n;i+=2;continue}" \
    "if(x==='\"'){q=q?0:34;i++;continue}" \
    "if(!q&&' \\t\\n;&|<>()'.includes(x))break;" \
    "if(!q&&x===\"'\"){q=39;i++;continue}" \
    "if(x==='`'){l=0;i++;qs(x);continue}" \
    "if(x==='$'){l=0;const n=o[i+1];if(n==='('||n==='{'){i+=2;nest(n,n==='('?')':'}');continue}}" \
    "v+=x;i++}return{start:s,end:i,value:l?v:null}};" \
    "while(i<o.length){const x=o[i],r=/^(<<-|<<|>>|<&|>&|<>|>\\||&>>|&>|<|>)/.exec(o.slice(i));" \
    "if(x===' '||x==='\\t')i++;" \
    "else if(x==='\\\\'&&o[i+1]==='\\n')i+=2;" \
    "else if(x==='#')while(i<o.length&&o[i]!=='\\n')i++;" \
    "else if(r)i+=r[0].length;" \
    "else if(';&|\\n()'.includes(x)){i++;cs.push(c=[])}" \
    "else{const w=wd();if(!c.length&&/^(if|then|else|elif|do|while|until|!|\\{)$/" \
    ".test(o.slice(w.start,w.end)))cs.push(c=[]);else c.push(w)}}" \
    "const m=w=>/%command%/i.test(o.slice(w.start,w.end)),G=cs.find(c=>c.some(m));" \
    "if(!G)return{p:0,e:[]};" \
    "const n=G.findIndex(w=>m(w)||!/^[A-Za-z_]\\w*=/.test(o.slice(w.start,w.end)));" \
    "return{p:G[0].start,e:G.slice(0,n<0?G.length:n)}})(),"

// Rewrites KEY=value entries before %command% and leaves the rest of the text byte for byte.
#define NP_CX_LAUNCH \
    "(o,id)=>{const " NP_CX_LAUNCH_PARSE \
    "g=k=>{const p=E.e.filter(w=>o.startsWith(k+\"=\",w.start)).pop();" \
    "return p?(p.value===null?o.slice(p.start+k.length+1,p.end):p.value.slice(k.length+1)):\"\"}," \
    "qv=v=>/^[\\w.,:=\\/+@%-]*$/.test(v)?v:\"'\"+v.replace(/'/g,\"'\\\\''\")+\"'\"," \
    "s=ps=>{const add=ps.filter(p=>p[1]).map(p=>p[0]+\"=\"+qv(p[1])).join(\" \");let r;" \
    "if(!/%command%/i.test(o)){if(!add)return;r=add+\" %command%\"+(o.trim()?\" \"+o:\"\")}" \
    "else{let at=E.p;r=o.slice(0,at)+(add?add+\" \":\"\");" \
    "E.e.forEach(w=>{if(ps.some(p=>o.startsWith(p[0]+\"=\",w.start))){" \
    "r+=o.slice(at,w.start);at=w.end;while(o[at]===\" \"||o[at]===\"\\t\")at++}});r+=o.slice(at)}" \
    "SteamClient.Apps.SetAppLaunchOptions(id,r.trim()===\"%command%\"?\"\":r)};" \
    "return{g,s,k:E.e.map(w=>o.slice(w.start,w.end).split(\"=\")[0])}}"

#define NP_CX_PICK \
    "(t,n)=>{const o=t.strLaunchOptions||\"\";" \
    "if(" NP_FEX_TOOLS ".indexOf(n)<0||/[<>\\n]|\\$'/.test(o))return;" \
    "const L=MSCXLaunch(o,t.unAppID)," \
    "ks=L.k.filter(k=>/^D3DM_[A-Z0-9_]*$/.test(k)||k===\"ROSETTA_ADVERTISE_AVX\"" \
    "||k===\"CX_GRAPHICS_BACKEND\"&&L.g(k)===\"d3dmetal\");" \
    "ks.length&&L.s(ks.map(k=>[k,\"\"]))}"

#define NP_CX_TOOL_QUERY \
    "(r,id)=>[r[0],v=>{r[1](v);const d=r[0].data;if(!id||!d)return;" \
    "const n=v||d.default_tool_identifier||\"" NP_FALLBACK_TOOL "\",a=(d.aliases||[]).find(x=>x.alias===n)," \
    "t=globalThis.appDetailsStore?.GetAppDetails(id);t&&MSCXPick(t,a?a.current_tool_name:n)}]"

// CrossOver options panel. Not in great shape, but it'll do
#define NP_WEB_IS_ZH \
    "(()=>{const l=(globalThis.document?.documentElement?.lang||" \
    "globalThis.navigator?.language||\"\").toLowerCase().replace(/_/g,\"-\");" \
    "return /^(zh(-hans(-[a-z0-9]+)*|-cn|-sg)?|schinese)$/.test(l)})()"

#define NP_WEB_IS_IT \
    "(()=>{const l=(globalThis.document?.documentElement?.lang||" \
    "globalThis.navigator?.language||\"\").toLowerCase().replace(/_/g,\"-\");" \
    "return /^(it(-[a-z0-9]+)*|italian)$/.test(l)})()"

#define NP_WEB_TEXT(EN, ZH, IT) \
    "(" NP_WEB_IS_ZH "?\"" ZH "\":" NP_WEB_IS_IT "?\"" IT "\":\"" EN "\")"

#define NP_COMPAT_HINT NP_WEB_TEXT( \
    "Enable CrossOver under Properties > Compatibility to install and run the Windows version.", \
    "请在“属性 > 兼容性”中启用 CrossOver，以安装并运行 Windows 版本。", \
    "Abilita CrossOver in Propriet\\u00e0 > Compatibilit\\u00e0 per installare e avviare la versione Windows.")

#define NP_IMAGE_FILES_LABEL NP_WEB_TEXT( \
    "Image Files (*.tga,*.png,*.exe)", "图像文件 (*.tga,*.png,*.exe)", "File immagine (*.tga,*.png,*.exe)")

#define NP_LIBRARY_WINDOWS_HINT NP_WEB_TEXT( \
    "Show only games that run on Windows and do not have a macOS version", \
    "Show only games that run on Windows and do not have a macOS version", \
    "Show only games that run on Windows and do not have a macOS version")

#define NP_LIBRARY_WINDOWS_SUMMARY NP_WEB_TEXT( \
    "Runs on Windows, no Mac OS version", \
    "Runs on Windows, no Mac OS version", \
    "Runs on Windows, no Mac OS version")

#define NP_CX_OPTIONS_CSS \
    "\".MSCXPanel{margin-top:10px}" \
    ".MSCXPanel .MSCXRow{display:flex;flex-direction:row;padding:9px;margin:0;" \
    "color:#dfe3e6;background:rgba(59,63,72,.5);border-radius:3px}" \
    ".MSCXPanel .MSCXRow:hover{box-shadow:0 6px 8px 0 rgba(0,0,0,.16)}" \
    ".MSCXPanel .MSCXRowDesc{flex-wrap:wrap;align-items:center}" \
    ".MSCXPanel .MSCXRowDesc>:last-child{flex-basis:100%}" \
    ".MSCXNoBottomGap{margin-bottom:0}\""

// FEX runs arm64 Wine, which has no D3DMetal and never runs under Rosetta.
#define NP_CX_OPTIONS_BODY(ARG, RT, BARREL) \
    ARG "=>{" \
    "const t=" ARG ".details,o=t.strLaunchOptions||\"\"," \
    "fex=" NP_FEX_TOOLS ".indexOf(t.strCompatToolName||\"" NP_FALLBACK_TOOL "\")>=0," \
    "npZh=" NP_WEB_IS_ZH ",npIt=" NP_WEB_IS_IT ",npL=(en,zh,it)=>npZh?zh:npIt?it:en," \
    "L=MSCXLaunch(o,t.unAppID),g=L.g,s=L.s," \
    "MSCXReady=" NP_READY ",MSCXFeat=" NP_FEATS ",MSCXVar=" NP_VARS "," \
    "on1=(k,n=0)=>{const p=MSCXFeat.find(x=>x.k===k);" \
    "return!!p&&n<32&&MSCXReady[k]!==0&&g(k)===p.on&&(!p.dep||on1(p.dep,n+1))}," \
    "vav=MSCXVar.filter(v=>v.t.indexOf(t.strCompatToolName||\"" NP_FALLBACK_TOOL "\")>=0)," \
    "vcur=g(\"NOTPROTON_RUNNER_VARIANT\").split(\"+\").filter(x=>x)," \
    "vids=vav.map(v=>v.v).filter((d,i,a)=>a.indexOf(d)===i)," \
    "vset=(id,val)=>{const keep=vcur.filter(x=>MSCXVar.some(v=>v.k===x&&v.v!==id))," \
    "all=(val?keep.concat([val]):keep).filter((x,i,a)=>a.indexOf(x)===i).sort();" \
    "s([[\"NOTPROTON_RUNNER_VARIANT\",all.join(\"+\")]])}," \
    "V=id=>{const vd=vav.filter(v=>v.v===id)," \
    "sel=vcur.find(x=>vd.some(v=>v.k===x))||\"\";" \
    "return(0," RT ".jsx)(" BARREL ".m," \
    "{label:id+npL(\" Variant\",\" 变体\",\" Variant\")," \
    "layout:\"inline\"," \
    "rgOptions:[{data:\"\",label:npL(\"Default\",\"默认\",\"Default\")}]" \
    ".concat(vd.map(v=>({data:v.k,label:v.l})))," \
    "selectedOption:sel,onChange:x=>vset(id,x.data)},id)}," \
    "TD=(k,l,on,off,d,dep)=>{const rd=MSCXReady[k]!==0;" \
    "return(0," RT ".jsx)(" BARREL ".y4," \
    "{label:rd?l:l+npL(\" (not installed)\",\" (未安装)\",\" (not installed)\"),disabled:!rd," \
    "description:d||undefined,checked:rd&&g(k)===on," \
    "indentLevel:dep?1:undefined," \
    "onChange:v=>s([[k,v?on:(off||\"\")]])},k)}," \
    "T=(ks,l,on,off,d,r)=>{const rd=r!==0;" \
    "return(0," RT ".jsx)(" BARREL ".Yh," \
    "{className:\"MSCXRow\"+(d?\" MSCXRowDesc\":\"\")," \
    "label:rd?l:l+npL(\" (not installed)\",\" (未安装)\",\" (not installed)\"),disabled:!rd," \
    "description:d||undefined," \
    "checked:rd&&g(ks[0])===on," \
    "onChange:v=>s(ks.map(k=>[k,v?on:(off||\"\")]))},ks[0])}," \
    "bv=g(\"CX_GRAPHICS_BACKEND\"),b=fex&&\"d3dmetal\"===bv?\"\":bv," \
    "dm=!fex&&(\"\"===b||\"d3dmetal\"===b)," \
    "dx=\"\"===b||\"dxmt\"===b," \
    "sw=\"1\"===g(\"DXMT_METALFX_SPATIAL_SWAPCHAIN\")," \
    "F=\"d3d11.metalSpatialUpscaleFactor=\"," \
    "fe=g(\"DXMT_CONFIG\").split(\";\").filter(e=>e.trim())," \
    "fk=e=>/^[ \\t\\r]*d3d11\\.metalSpatialUpscaleFactor[ \\t\\r]*=/.test(e)," \
    "fx=v=>fe.filter(e=>!fk(e)).concat(v?[F+v]:[]).join(\";\")," \
    "fv=(fe.filter(fk).pop()||\"=2\").replace(/^[^=]*=/,\"\").replace(/\"/g,\"\").trim().split(/\\s/)[0]," \
    "fn=Math.max(isNaN(+fv)?2:+fv,1)," \
    "U=[{data:\"\",label:npL(\"Off\",\"关闭\",\"Disattivato\")}," \
    "{data:\"1.5\",label:\"1.5x\"}," \
    "{data:\"1.72\",label:\"1.72x\"}," \
    "{data:\"2.0\",label:\"2x\"}," \
    "{data:\"3.0\",label:\"3x\"}]," \
    "B=[{data:\"\",label:npL(\"Automatic\",\"自动\",\"Automatico\")}," \
    "{data:\"d3dmetal\",label:\"D3DMetal\"}," \
    "{data:\"dxmt\",label:\"DXMT\"}," \
    "{data:\"dxvk\",label:\"DXVK\"}," \
    "{data:\"wined3d\",label:\"WineD3D\"}].filter(x=>!fex||x.data!==\"d3dmetal\");" \
    "if(t.unAppID<2147483648&&(t.vecPlatforms||[]).indexOf(\"osx\")>=0" \
    "&&!t.strCompatToolName)return null;" \
    "return(0," RT ".jsx)(\"div\",{className:\"MSCXPanel\",children:(0," RT ".jsxs)(" RT ".Fragment,{children:[" \
    "(0," RT ".jsx)(\"style\",{children:" NP_CX_OPTIONS_CSS "})," \
    "(0," RT ".jsxs)(" BARREL ".XY,{label:npL(\"Graphics\",\"图形\",\"Grafica\"),children:[" \
    "(0," RT ".jsx)(" BARREL ".m,{rgOptions:B,selectedOption:b," \
    "onChange:v=>s([[\"CX_GRAPHICS_BACKEND\",v.data]]" \
    ".concat(\"\"===v.data||\"d3dmetal\"===v.data?[]:[[\"D3DM_ENABLE_METALFX\",\"\"]])" \
    ".concat(\"\"===v.data||\"dxmt\"===v.data?[]:" \
    "[[\"DXMT_METALFX_SPATIAL_SWAPCHAIN\",\"\"],[\"DXMT_CONFIG\",fx(\"\")]])" \
    ".concat(\"dxmt\"===v.data?[]:[[\"DXMT_ENABLE_NVEXT\",\"\"]]))})," \
    "T([\"MTL_HUD_ENABLED\"],npL(\"Metal HUD\",\"Metal 性能监视器\",\"Metal HUD\"),\"1\")," \
    "dm&&T([\"D3DM_ENABLE_METALFX\"],\"DLSS\",\"1\")," \
    "\"dxmt\"===b&&T([\"DXMT_ENABLE_NVEXT\"],\"DLSS\",\"1\")," \
    "!fex&&T([\"ROSETTA_ADVERTISE_AVX\"],npL(\"Advertise AVX2 to Rosetta\",\"向 Rosetta 声明 AVX2 支持\",\"Segnala AVX2 a Rosetta\"),\"1\",\"0\")," \
    "T([\"WINEMSYNC\"],\"MSync\",\"1\",\"0\")," \
    "T([\"NOTPROTON_RETINA\"],npL(\"High Resolution\",\"高分辨率\",\"Alta risoluzione\"),\"1\",\"0\")" \
    "]},\"gfx\")," \
    "dx&&(0," RT ".jsx)(" BARREL ".XY," \
    "{label:npL(\"MetalFX Upscaling (Samples from the resolution the game is set to)\"," \
    "\"MetalFX 超分辨率（以游戏设置的分辨率为采样来源）\",\"Upscaling MetalFX (ingrandisce l'immagine dalla risoluzione impostata nel gioco)\")," \
    "children:(0," RT ".jsx)(" BARREL ".m,{rgOptions:U," \
    "selectedOption:sw?(U.find(u=>u.data&&+u.data===fn)||{data:String(fn)}).data:\"\"," \
    "onChange:v=>s([[\"DXMT_METALFX_SPATIAL_SWAPCHAIN\",v.data?\"1\":\"\"],[\"DXMT_CONFIG\",fx(v.data)]])})},\"usf\")," \
    "(0," RT ".jsxs)(" BARREL ".XY,{label:npL(\"Controllers\",\"控制器\",\"Controller\"),children:[" \
    "T([\"NOTPROTON_RAW_CONTROLLERS\"],npL(\"Let games read controllers directly (May break Steam Input. Not recommended)\"," \
    "\"允许游戏直接读取控制器（可能导致 Steam Input 失效，不推荐）\"," \
    "\"Lascia che i giochi leggano direttamente i controller (pu\\u00f2 interferire con Steam Input, sconsigliato)\"),\"1\",\"\")," \
    "T([\"NOTPROTON_DISABLE_HIDRAW\"],npL(\"Disable hidraw\",\"停用 hidraw\",\"Disable hidraw\"),\"1\",\"\")" \
    "]},\"ctl\")," \
    "(MSCXFeat.length||vids.length?(0," RT ".jsx)(" BARREL ".J1,{children:(0," RT ".jsx)(" BARREL ".XY," \
    "{label:npL(\"Developer\",\"开发者\",\"Developer\")," \
    "children:vids.map(V).concat(MSCXFeat.filter(f=>!f.dep||on1(f.dep))" \
    ".map(f=>TD(f.k,f.l,f.on,f.off,f.d,f.dep)))})},\"dev\"):null)" \
    "]})})}"

#define NP_CX_OPTIONS_CAPTURE(RT, BARREL) \
    "((npReact,npUI)=>" NP_CX_OPTIONS_BODY("np", "npReact()", "npUI()") ")(()=>" RT ",()=>" BARREL ")"

#define NP_CX_OPTIONS_COMPONENT \
    "MSCXLaunch=" NP_CX_LAUNCH ",MSCXPick=" NP_CX_PICK "," \
    "MSCXOpts=" NP_CX_OPTIONS_CAPTURE(NP_C4, NP_C5) ","

// Valve is testing a new compatibility page UI, this logic relates to supporting that
#define NP_CX_OPTIONS_STATEMENT \
    "var MSCXLaunch=" NP_CX_LAUNCH ";" \
    "var MSCXPick=" NP_CX_PICK ";" \
    "var MSCXToolQuery=" NP_CX_TOOL_QUERY ";" \
    "var MSCXOpts=" NP_CX_OPTIONS_CAPTURE(NP_C3, NP_C4) ";"

// 1.0.x saved CrossOver settings without %command%, this migrates them.
#define NP_LAUNCH_MIGRATION_RULE \
    "o=>{const T=/(?:[^\\s\"'\\\\]|\\\\[^]|\"(?:[^\"\\\\]|\\\\[^])*\"|'[^']*')+/g," \
    "w=o.match(T)||[]," \
    "k=x=>/^(CX_GRAPHICS|D3DM_|DXMT_|DXVK_|MTL_|NOTPROTON_|ROSETTA_|WINE)\\w*=/.test(x)," \
    "e=w.filter(k);" \
    "if(/%command%/i.test(o)||o.replace(T,\"\").trim()||!e.length)return null;" \
    "return e.map(x=>{const i=x.indexOf(\"=\"),v=x.slice(i+1);" \
    "return/[\"'\\\\]/.test(x)||/^[\\w.,:=\\/+@%-]*$/.test(v)?x:x.slice(0,i+1)+\"'\"+v+\"'\"})" \
    ".concat(\"%command%\",w.filter(x=>!k(x))).join(\" \")}"

#define NP_LAUNCH_MIGRATION \
    "(async()=>{try{" \
    "const K=\"NotProtonLaunchMigrated_\"+this.m_cm.steamid.GetAccountID();" \
    "if(localStorage.getItem(K))return;" \
    "const M=" NP_LAUNCH_MIGRATION_RULE ";" \
    "const A=[...window.appStore.m_mapApps.values()].filter(a=>a);let n=0;" \
    "for(let i=0;i<A.length;i+=20)await Promise.all(A.slice(i,i+20).map(async a=>{const id=a.appid;" \
    "const t=await Promise.race([window.appDetailsStore.RequestAppDetails(id)," \
    "new Promise(r=>setTimeout(r,5e3))]);" \
    "if(!t){console.warn(\"NotProton: no details for app \"+id+\", its launch options were not moved\");return}" \
    "if(!(id<2147483648&&(t.vecPlatforms||[]).indexOf(\"osx\")>=0&&!t.strCompatToolName)){" \
    "const r=M(t.strLaunchOptions||\"\");" \
    "if(r!==null){SteamClient.Apps.SetAppLaunchOptions(id,r);n++;" \
    "console.log(\"NotProton: moved the launch options of app \"+id)}}}));" \
    "console.log(\"NotProton: checked the launch options of \"+A.length+\" apps, moved \"+n);" \
    "localStorage.setItem(K,\"1\")" \
    "}catch(e){console.error(\"NotProton: launch options migration failed\",e)}})()"

static const np_gate_t g_gates_forcetool[] = {
    // SteamPlay settings section
    { "function " NP_C1 "(" NP_C2 "){return(0," NP_C3 ".CI)()?",
      "function " NP_C1 "(" NP_C2 "){return true?", 1, 0 },
    // AppProperties Compatibility tab (app and non-Steam-shortcut variants)
    { "(0," NP_C1 ".CI)()&&" NP_C2 ".push({title:(0," NP_C3 ".we)(\"#AppProperties_CompatibilityPage\")",
      "true&&" NP_C2 ".push({title:(0," NP_C3 ".we)(\"#AppProperties_CompatibilityPage\")", 2, 0 },
    // Settings page Compatibility entry, keeping the SteamOS exclusion (!rf())
    { "Compatibility:{visible:" NP_C1 "&&(0," NP_C2 ".CI)()&&!(0," NP_C2 ".rf)()",
      "Compatibility:{visible:" NP_C1 "&&true&&!(0," NP_C2 ".rf)()", 1, 0 },
    { "return(0," NP_C1 ".jsxs)(" NP_C1 ".Fragment,{children:[0!=" NP_C2 ".length&&(0," NP_C1 ".jsx)(" NP_C3 ",{label:(0," NP_C4 ".we)"
      "(\"#AppProperties_CompatilibityForceTool\"),checked:" NP_C5 ",onChange:" NP_C6 ",disabled:!" NP_C7 "||0===" NP_C2 ".length}),"
      NP_C5 "&&" NP_C2 ".length>0&&(0," NP_C1 ".jsx)(" NP_C8 ".m,{strClassName:" NP_C9 "().TopGap,rgOptions:" NP_C10 ","
      "selectedOption:" NP_C11 ".strCompatToolName,onChange:" NP_C12 "=>SteamClient.Apps.SpecifyCompatTool"
      "(" NP_C11 ".unAppID," NP_C12 ".data)})]})",
      "return(0," NP_C1 ".jsxs)(" NP_C1 ".Fragment,{children:[0!=" NP_C2 ".length&&(0," NP_C1 ".jsx)(" NP_C3 ",{label:(0," NP_C4 ".we)"
      "(\"#AppProperties_CompatilibityForceTool\"),checked:" NP_C5 ",onChange:" NP_C6 ",disabled:!" NP_C7 "||0===" NP_C2 ".length}),"
      NP_C5 "&&" NP_C2 ".length>0&&(0," NP_C1 ".jsx)(" NP_C8 ".m,{strClassName:" NP_C9 "().TopGap+\" MSCXNoBottomGap\",rgOptions:" NP_C10 ","
      "selectedOption:" NP_C11 ".strCompatToolName,onChange:" NP_C12 "=>{SteamClient.Apps.SpecifyCompatTool"
      "(" NP_C11 ".unAppID," NP_C12 ".data);MSCXPick(" NP_C11 "," NP_C12 ".data)}})]})", 1, 0 },
    // Compatibility page container
    { NP_C1 "=(0," NP_C2 ".PA)(" NP_C3 "=>(0," NP_C4 ".jsxs)(" NP_C5
      ".nB,{children:[(0," NP_C4 ".jsx)(\"div\",{className:" NP_C6
      "().HiddenIfNotLast,children:(0," NP_C7 ".we)(\"#AppProperties_CompatibilityNoOptions\")}),"
      "(0," NP_C4 ".jsx)(" NP_C8 ",{..." NP_C3 "}),(0," NP_C4 ".jsx)(" NP_C9
      ",{..." NP_C3 "})]}));",
      NP_CX_OPTIONS_COMPONENT
      NP_C1 "=(0," NP_C2 ".PA)(" NP_C3 "=>(0," NP_C4 ".jsxs)(" NP_C5
      ".nB,{children:[(0," NP_C4 ".jsx)(\"div\",{className:" NP_C6
      "().HiddenIfNotLast,children:(0," NP_C7 ".we)(\"#AppProperties_CompatibilityNoOptions\")}),"
      "(0," NP_C4 ".jsx)(" NP_C8 ",{..." NP_C3 "}),(0," NP_C4 ".jsx)(" NP_C9
      ",{..." NP_C3 "}),(0," NP_C4 ".jsx)(MSCXOpts,{..." NP_C3 "})]}));", 1, 0 },
    { "get is_invalid_os_type(){return this.most_available_per_client_data.is_invalid_os_type}",
      "get is_invalid_os_type(){return false}", 1, 0 },
    // Reminder banner for 32 bit Mac games
    { NP_C1 ".is_invalid_os_type&&(0," NP_C2 ".jsx)(" NP_C3 ",{})",
      "!" NP_C1 ".local_per_client_data?.installed&&"
      NP_C1 ".most_available_per_client_data?.is_invalid_os_type&&"
      "(0," NP_C2 ".jsx)(" NP_C3 ",{})", 1, 0 },
    { "(0," NP_C1 ".we)(\"#GameList_Entry_Invalid_OSType2\")",
      NP_COMPAT_HINT, 1, 0 },
};

// Support for new compatibility tab UI in the Steam beta
static const np_gate_t g_gates_selecttool[] = {
    // AppProperties Compatibility tab
    { "(0," NP_C1 ".CI)()&&" NP_C2 ".push({title:(0," NP_C3 ".we)"
      "(\"#AppProperties_CompatibilityPage\")",
      "true&&" NP_C2 ".push({title:(0," NP_C3 ".we)"
      "(\"#AppProperties_CompatibilityPage\")", 2, 0 },
    // Settings page Compatibility entry.
    { "Compatibility:{visible:" NP_C1 "&&(0," NP_C2 ".CI)(),title:",
      "Compatibility:{visible:" NP_C1 "&&true,title:", 1, 0 },
    { "function " NP_C1 "(" NP_C2 "){return(0," NP_C3 ".jsxs)(" NP_C4 ".XY,{label:(0," NP_C5 ".we)"
      "(\"#Settings_SteamPlay_SteamPlay\"),children:[(0," NP_C3 ".jsx)(" NP_C6 ",{details:" NP_C2 ".details}),"
      "(0," NP_C3 ".jsx)(" NP_C7 ".G,{setting:\"compat_show_all_tools\",label:(0," NP_C5 ".we)"
      "(\"#Settings_SteamPlay_ShowAll\"),feature:" NP_C8 ".OK})]})}",
      NP_CX_OPTIONS_STATEMENT
      "function " NP_C1 "(" NP_C2 "){return(0," NP_C3 ".jsxs)(" NP_C3 ".Fragment,{children:["
      "(0," NP_C3 ".jsxs)(" NP_C4 ".XY,{label:(0," NP_C5 ".we)"
      "(\"#Settings_SteamPlay_SteamPlay\"),children:[(0," NP_C3 ".jsx)(" NP_C6 ",{details:" NP_C2 ".details}),"
      "(0," NP_C3 ".jsx)(" NP_C7 ".G,{setting:\"compat_show_all_tools\",label:(0," NP_C5 ".we)"
      "(\"#Settings_SteamPlay_ShowAll\"),feature:" NP_C8 ".OK})]}),"
      "(0," NP_C3 ".jsx)(MSCXOpts,{details:" NP_C2 ".details})]})}", 1, 0 },
    // Compatibility Tool selector, wrapped to drop settings a FEX tool cannot use
    { "[" NP_C1 "," NP_C2 "]=(0," NP_C3 ".cT)(" NP_C4 ");if(" NP_C1 ".isLoading||!" NP_C1
      ".data?.tools?.length)return null;",
      "[" NP_C1 "," NP_C2 "]=(typeof MSCXToolQuery==\"function\"?MSCXToolQuery:r=>r)"
      "((0," NP_C3 ".cT)(" NP_C4 ")," NP_C4 ");if(" NP_C1
      ".isLoading||!" NP_C1 ".data?.tools?.length)return null;", 1, 1 },
    { "get is_invalid_os_type(){return this.most_available_per_client_data.is_invalid_os_type}",
      "get is_invalid_os_type(){return false}", 1, 0 },
    // Reminder banner for 32 bit Mac games
    { NP_C1 ".is_invalid_os_type&&(0," NP_C2 ".jsx)(" NP_C3 ",{})",
      "!" NP_C1 ".local_per_client_data?.installed&&"
      NP_C1 ".most_available_per_client_data?.is_invalid_os_type&&"
      "(0," NP_C2 ".jsx)(" NP_C3 ",{})", 1, 0 },
    { "(0," NP_C1 ".we)(\"#GameList_Entry_Invalid_OSType2\")",
      NP_COMPAT_HINT, 1, 0 },
};

#define NP_PLATFORM_LISTS "window.__NOTPROTON_NATIVE_PLATFORM__"
#define NP_MAC_64(APP) \
    "(" NP_PLATFORM_LISTS ".mac.has(" APP ".appid)&&!" APP ".most_available_per_client_data?.is_invalid_os_type)"
#define NP_MAC_CHECK(OS, APP) \
    "(0," OS ".Pr)()&&" NP_PLATFORM_LISTS ".mac.has(" APP ".appid)?!" APP \
    ".most_available_per_client_data?.is_invalid_os_type:(0," OS ".Pr)()&&" \
    NP_WINDOWS(APP) "?!1:(0," OS ".Pr)()?" \
    APP ".is_available_on_current_platform&&!" APP ".most_available_per_client_data?.is_invalid_os_type:"
// .exe shortcuts = Windows
#define NP_RUNS_EXE "window.__NOTPROTON_RUNS_EXE__"
#define NP_RUNS_EXE_JS \
    NP_RUNS_EXE "=a=>{if(!a.BIsShortcut?.())return!1;const s=window.appDetailsStore,e=s?.m_mapAppData?.get(a.appid);" \
    "s&&!e?.cRegistered&&queueMicrotask(()=>s.m_mapAppData.get(a.appid)?.cRegistered||s.RegisterForAppData(a.appid));" \
    "return/\\.exe\"?$/i.test(e?.details?.strShortcutExe??\"\")};\n"
#define NP_WINDOWS(APP) \
    "(" NP_PLATFORM_LISTS ".windows.has(" APP ".appid)||" NP_RUNS_EXE "(" APP "))"
#define NP_WINDOWS_ONLY_CASE(OS, APP) \
    "case\"notprotonWindows\":return(0," OS ".Pr)()&&" NP_WINDOWS(APP) "&&!" \
    NP_MAC_64(APP) ";"

static const np_gate_t g_fixes[] = {
    { "(\"#AddNonSteam_Filter_Exe_MacOS\"),rFilePatterns:[\"*.app\"]",
      "(\"#AddNonSteam_Filter_Exe_MacOS\"),rFilePatterns:[\"*.app\",\"*.exe\"]", 1, 0 },
    { "{strFileTypeName:\"Image Files (*.tga,*.png)\",rFilePatterns:[\"*.tga\",\"*.png\"]}",
      "{strFileTypeName:" NP_IMAGE_FILES_LABEL ","
      "rFilePatterns:[\"*.tga\",\"*.png\",\"*.exe\"]}", 1, 0 },
    // Makes Steam's default compatibility tool setting work
    { "r=(0,s.q3)(()=>u.rV.settings.bCompatEnabled),a=function(e,t){const[r,i]=n.useState([]);"
      "return n.useEffect(()=>{SteamClient.Apps.GetAvailableCompatTools(e).then(i)},[e,t]),r}"
      "(t.unAppID,r),o=r&&!!t.strCompatToolName&&t.nCompatToolPriority==h.JN,"
      "l=a.length?a[0].strToolName:\"\"",
      "r=(0,s.q3)(()=>u.rV.settings.bCompatEnabled),a=function(e,t){const[r,i]=n.useState([]);"
      "return n.useEffect(()=>{SteamClient.Apps.GetAvailableCompatTools(e).then(i)},[e,t]),r}"
      "(t.unAppID,r),o=r&&!!t.strCompatToolName&&t.nCompatToolPriority==h.JN,"
      "l=a.length?(a.find(e=>e.strToolName===u.rV.settings.strCompatTool)||a[0]).strToolName:\"\"",
      1, 0 },
    // Shows the default tool picker before a default has been saved
    { "return " NP_C1 "?(0," NP_C2 ".jsx)(" NP_C3 ".B,{feature:" NP_C4 ".OK,label:(0," NP_C5 ".we)"
      "(\"#Settings_SteamPlay_DefaultTool\"),rgOptions:" NP_C6 ",disabled:0==" NP_C6 ".length,"
      "selectedOption:" NP_C1 ",",
      "return(" NP_C1 "||" NP_C6 ".some(e=>e.data===\"" NP_FALLBACK_TOOL "\"))?(0," NP_C2 ".jsx)("
      NP_C3 ".B,{feature:" NP_C4 ".OK,label:(0," NP_C5 ".we)"
      "(\"#Settings_SteamPlay_DefaultTool\"),rgOptions:" NP_C6 ",disabled:0==" NP_C6 ".length,"
      "selectedOption:" NP_C1 "||\"" NP_FALLBACK_TOOL "\",",
      1, 0 },
    { "this.m_bServicesInitialized=!0,SteamClient.UI.NotifyAppInitialized()",
      "this.m_bServicesInitialized=!0," NP_LAUNCH_MIGRATION ",SteamClient.UI.NotifyAppInitialized()", 1, 0 },
    // Pr means macOS, td means Windows.
    // Steam Play makes every game count as available, so the Apple filter goes by oslist.
    // Games missing from appinfo.vdf, and other platforms, keep Steam's check.
    // NotProton forces is_invalid_os_type to false, so 32-bit Mac games are found through the per-client copy.
    { "case " NP_C1 "." NP_C2 ":return!!(0," NP_C3 ".td)()||" NP_C4
      ".is_available_on_current_platform&&!" NP_C4 ".is_invalid_os_type;",
      NP_WINDOWS_ONLY_CASE(NP_C3, NP_C4) "case " NP_C1 "." NP_C2 ":return " NP_MAC_CHECK(NP_C3, NP_C4)
      "!!(0," NP_C3 ".td)()||" NP_C4 ".is_available_on_current_platform&&!" NP_C4 ".is_invalid_os_type;", 1, 0 },
    { "case " NP_C1 "." NP_C2 ":return(0," NP_C3 ".CI)()&&!(0," NP_C3 ".mP)()?"
      NP_C4 "(" NP_C5 "):(0," NP_C3 ".td)()?!0:" NP_C5
      ".is_available_on_current_platform&&!" NP_C5 ".is_invalid_os_type;",
      NP_WINDOWS_ONLY_CASE(NP_C3, NP_C5) "case " NP_C1 "." NP_C2 ":return " NP_MAC_CHECK(NP_C3, NP_C5)
      "(0," NP_C3 ".CI)()&&!(0," NP_C3 ".mP)()?" NP_C4 "(" NP_C5 "):(0,"
      NP_C3 ".td)()?!0:" NP_C5 ".is_available_on_current_platform&&!" NP_C5 ".is_invalid_os_type;", 1, 0 },
};
#define NP_FIX_COUNT (sizeof(g_fixes) / sizeof(g_fixes[0]))

#define NP_NATIVE_MAC_FILTER_FIX (NP_FIX_COUNT - 2)
#define NP_UPDATED_NATIVE_MAC_FILTER_FIX (NP_FIX_COUNT - 1)

#define NP_PLATFORM_TIP "\"#GameList_View_Platform_Linux\":\"#GameList_View_Platform_Apple\""
#define NP_LOCALIZED_PLATFORM_TIP "(0," NP_C12 ".we)(\"#GameList_View_Platform_Linux\"):(0," NP_C12 \
    ".we)(\"#GameList_View_Platform_Apple\")"
#define NP_PLATFORM_BUTTON(tip) \
    NP_C1 "&&(0," NP_C2 ".jsxs)(" NP_C3 ".he,{direction:\"top\",nDelayShowMS:240,toolTipContent:" NP_C4 \
    "?" tip ",className:(0," NP_C5 ".A)(" NP_C6 "().CheckboxWithImage," NP_C7 "&&" NP_C6 "().Disabled," \
    NP_C8 "&&" NP_C6 "().Active),onClick:()=>" NP_C7 "||" NP_C9 "(" NP_C10 ".W6," NP_C10 ".Pu,!" NP_C8 \
    "),children:[" NP_C4 "&&(0," NP_C2 ".jsx)(" NP_C11 ".Wy0,{}),!" NP_C4 "&&(0," NP_C2 ".jsx)(" NP_C11 ".kPc,{})]})"
#define NP_WINDOWS_BUTTON \
    NP_C1 "&&!" NP_C4 "&&" NP_C11 ".Xz0&&(0," NP_C2 ".jsxs)(" NP_C3 ".he,{direction:\"top\",nDelayShowMS:240," \
    "toolTipContent:" NP_LIBRARY_WINDOWS_HINT ",className:(0," NP_C5 ".A)(" NP_C6 "().CheckboxWithImage," \
    NP_C7 "&&" NP_C6 "().Disabled,npWindows&&" NP_C6 "().Active),onClick:()=>" NP_C7 \
    "||npStore.SelectCollectionsAppFilterOption(\"notprotonWindows\",null,!npWindows)," \
    "children:[(0," NP_C2 ".jsx)(\"style\",{children:\".\"+" NP_C6 "().CheckboxWithImage+" \
    "\" .SVGIcon_WindowsLogo{width:13px;height:13px}.\"+" NP_C6 "().CheckboxWithImage+" \
    "\" .SVGIcon_WindowsLogo rect{fill:inherit}\"}),(0," NP_C2 ".jsx)(" NP_C11 ".Xz0,{})]})"

static const np_gate_t g_library_filters[] = {
    // Library list and search
    { "if(!" NP_C1 "(" NP_C2 "[" NP_C3 ".W6]," NP_C4 "(" NP_C5 "))||!" NP_C1 "(" NP_C2 "[" NP_C3 ".sc],",
      "if(!(this.m_filterSpec.notprotonWindows?((npGroup,npCheck)=>{"
      "const npApple=npGroup.rgOptions.includes(" NP_C3 ".Pu);return " NP_C1 "({...npGroup,"
      "rgOptions:[...npGroup.rgOptions.filter(npOption=>npOption!==" NP_C3 ".Pu),\"notprotonWindows\"]},"
      "npOption=>npOption===\"notprotonWindows\"?npCheck(npOption)||npApple&&npCheck(" NP_C3 ".Pu):npCheck(npOption))"
      "})(" NP_C2 "[" NP_C3 ".W6]," NP_C4 "(" NP_C5 ")):" NP_C1 "(" NP_C2 "[" NP_C3 ".W6]," NP_C4 "(" NP_C5 ")))||!"
      NP_C1 "(" NP_C2 "[" NP_C3 ".sc],", 2, 0 },
    // Saved library filter
    { ",strSearchText:" NP_C1 "&&" NP_C1 ".strSearchText||\"\",filterGroups:",
      ",strSearchText:" NP_C1 "&&" NP_C1 ".strSearchText||\"\","
      "notprotonWindows:!!" NP_C1 "?.notprotonWindows,filterGroups:", 1, 0 },
    { "SelectOption(" NP_C1 "," NP_C2 "," NP_C3 "){let " NP_C4 "=this.m_filterSpec.filterGroups[" NP_C1 "].rgOptions;",
      "SelectOption(" NP_C1 "," NP_C2 "," NP_C3 "){if(" NP_C1 "===\"notprotonWindows\"){"
      "this.m_filterSpec.notprotonWindows=!!" NP_C3 ";return}let " NP_C4 "=this.m_filterSpec.filterGroups[" NP_C1 "].rgOptions;", 1, 0 },
    { "Reset(){this.m_filterSpec.strSearchText=\"\",",
      "Reset(){this.m_filterSpec.notprotonWindows=!1,this.m_filterSpec.strSearchText=\"\",", 1, 0 },
    { "get bIsEmpty(){return this.searchText.length==0&&",
      "get bIsEmpty(){return!this.m_filterSpec.notprotonWindows&&this.searchText.length==0&&", 1, 0 },
    { "let " NP_C1 "=this.GetSelectedOptions(" NP_C2 ".W6);" NP_C1 ".length>0&&" NP_C3 ".push(" NP_C1 ".map("
      NP_C4 "=>{if(" NP_C4 "==" NP_C2 ".Pu){",
      "let " NP_C1 "=this.GetSelectedOptions(" NP_C2 ".W6);this.m_filterSpec.notprotonWindows&&(" NP_C1 "=[..."
      NP_C1 ",\"notprotonWindows\"]);" NP_C1 ".length>0&&" NP_C3 ".push(" NP_C1 ".map(" NP_C4 "=>{if(" NP_C4
      "===\"notprotonWindows\")return " NP_LIBRARY_WINDOWS_SUMMARY ";if(" NP_C4 "==" NP_C2 ".Pu){", 1, 0 },
    // Library toolbar
    { "," NP_C1 "=" NP_C2 ".n6.currentAppFilter.BIsSelected(" NP_C3 ".W6," NP_C3 ".Pu);return(0,"
      NP_C4 ".jsxs)(\"div\",{className:" NP_C5 "().Bar,",
      "," NP_C1 "=" NP_C2 ".n6.currentAppFilter.BIsSelected(" NP_C3 ".W6," NP_C3 ".Pu),npStore=" NP_C2 ".n6,"
      "npWindows=!!" NP_C2 ".n6.currentAppFilter.m_filterSpec.notprotonWindows;return(0,"
      NP_C4 ".jsxs)(\"div\",{className:" NP_C5 "().Bar,", 1, 0 },
    { "children:[" NP_PLATFORM_BUTTON(NP_PLATFORM_TIP), "children:[" NP_WINDOWS_BUTTON "," NP_PLATFORM_BUTTON(NP_PLATFORM_TIP), 1, 0 },
    // 1792192922 passes the tooltip through Steam's localize call.
    { "children:[" NP_PLATFORM_BUTTON(NP_LOCALIZED_PLATFORM_TIP),
      "children:[" NP_WINDOWS_BUTTON "," NP_PLATFORM_BUTTON(NP_LOCALIZED_PLATFORM_TIP), 1, 0 },
};
#define NP_LIBRARY_FILTER_COUNT (sizeof(g_library_filters) / sizeof(g_library_filters[0]))

// Exactly one of the two toolbar anchors has to match.
#define NP_LIBRARY_TOOLBAR (NP_LIBRARY_FILTER_COUNT - 2)
#define NP_LOCALIZED_LIBRARY_TOOLBAR (NP_LIBRARY_FILTER_COUNT - 1)

typedef struct {
    const char     *name;
    const char     *probe;
    const np_gate_t *gates;
    size_t          count;
} np_ui_shape_t;

static const np_ui_shape_t g_shapes[] = {
    { NP_SHAPE_FORCETOOL,  "#AppProperties_CompatilibityForceTool",
      g_gates_forcetool,  sizeof(g_gates_forcetool) / sizeof(g_gates_forcetool[0]) },
    { NP_SHAPE_SELECTTOOL, "#AppProperties_Compat_SelectTool",
      g_gates_selecttool, sizeof(g_gates_selecttool) / sizeof(g_gates_selecttool[0]) },
};
#define NP_SHAPE_COUNT (sizeof(g_shapes) / sizeof(g_shapes[0]))
_Static_assert(sizeof(g_gates_forcetool) / sizeof(np_gate_t) <= NP_GATE_MAX, "gate table too long");
_Static_assert(sizeof(g_gates_selecttool) / sizeof(np_gate_t) <= NP_GATE_MAX, "gate table too long");

static int has_suffix(const char *s, const char *suf) {
    size_t ls = strlen(s), lf = strlen(suf);
    return ls >= lf && memcmp(s + ls - lf, suf, lf) == 0;
}

static const char *inside_steamui(const char *path) {
    const char *at = strstr(path, "/steamui/");
    if (at)
        return at + sizeof("/steamui/") - 1;
    if (strncmp(path, "steamui/", sizeof("steamui/") - 1) == 0)
        return path + sizeof("steamui/") - 1;
    return NULL;
}

// The compatibility UI has shipped in both chunk~*.js and sp.js.
// np_webpatch_transform rejects scripts without matching anchors.
int np_webpatch_should_patch(const char *path) {
    if (!path || !has_suffix(path, ".js"))
        return 0;

    const char *rest = inside_steamui(path);
    if (!rest)
        return 0;

    return strncmp(rest, "localization/", sizeof("localization/") - 1) != 0
        && strncmp(rest, "libraries/", sizeof("libraries/") - 1) != 0;
}

char *np_webpatch_transform(const uint8_t *src, size_t src_len, size_t *out_len,
                            const char **out_shape) {
    const char *s = (const char *)src;

    if (out_shape)
        *out_shape = NULL;
    if (!g_feat_pinned)
        g_feat_ready_done = 0;

    const np_ui_shape_t *shape = NULL;
    for (size_t i = 0; i < NP_SHAPE_COUNT; i++) {
        if (count_matches(s, src_len, g_shapes[i].probe) == 0)
            continue;
        if (shape) {
            NP_WARN("webpatch: chunk carries both the '%s' and '%s' compat UI, "
                    "refusing to guess which one renders", shape->name, g_shapes[i].name);
            return NULL;
        }
        shape = &g_shapes[i];
    }
    int    fix_on[NP_FIX_COUNT];
    size_t fix_live = 0;
    char *native_mac_js = NULL;
    for (size_t f = 0; f < NP_FIX_COUNT; f++) {
        size_t n = count_matches(s, src_len, g_fixes[f].find);
        fix_on[f] = n == (size_t)g_fixes[f].expect;
        if ((f == NP_NATIVE_MAC_FILTER_FIX || f == NP_UPDATED_NATIVE_MAC_FILTER_FIX) && fix_on[f]) {
            free(native_mac_js);
            native_mac_js = np_nativeplatform_javascript();
        }
        if (fix_on[f]) { fix_live++; continue; }
        if (n)
            NP_WARN("webpatch: fix %zu expected %d occurrence(s), found %zu; "
                    "leaving it alone", f, g_fixes[f].expect, n);
    }
    if (!native_mac_js && (fix_on[NP_NATIVE_MAC_FILTER_FIX] || fix_on[NP_UPDATED_NATIVE_MAC_FILTER_FIX])) {
        NP_WARN("webpatch: no platform list from appinfo.vdf, the Apple filter stays stock");
        fix_live -= fix_on[NP_NATIVE_MAC_FILTER_FIX] + fix_on[NP_UPDATED_NATIVE_MAC_FILTER_FIX];
        fix_on[NP_NATIVE_MAC_FILTER_FIX] = fix_on[NP_UPDATED_NATIVE_MAC_FILTER_FIX] = 0;
    }
    int library_filter = fix_on[NP_NATIVE_MAC_FILTER_FIX] || fix_on[NP_UPDATED_NATIVE_MAC_FILTER_FIX];
    int library_on[NP_LIBRARY_FILTER_COUNT] = {0};
    for (size_t g = 0; library_filter && g < NP_LIBRARY_FILTER_COUNT; g++) {
        size_t n = count_matches(s, src_len, g_library_filters[g].find);
        library_on[g] = n == (size_t)g_library_filters[g].expect;
        if (library_on[g] || g == NP_LIBRARY_TOOLBAR || g == NP_LOCALIZED_LIBRARY_TOOLBAR) continue;
        NP_WARN("webpatch: library anchor %zu expected %d occurrence(s), found %zu; "
                "no Windows filter button", g, g_library_filters[g].expect, n);
        library_filter = 0;
    }
    if (library_filter && library_on[NP_LIBRARY_TOOLBAR] == library_on[NP_LOCALIZED_LIBRARY_TOOLBAR]) {
        NP_WARN("webpatch: %s; no Windows filter button",
                library_on[NP_LIBRARY_TOOLBAR] ? "both library toolbar anchors matched"
                                               : "no library toolbar anchor matched");
        library_filter = 0;
    }

    if (!shape && !fix_live) {
        free(native_mac_js);
        return NULL;   // Not the part carrying the compat UI.
    }

    int    gate_on[NP_GATE_MAX] = {0};
    size_t gate_live = 0;
    if (shape) {
        if (out_shape)
            *out_shape = shape->name;

        int drifted = 0;
        for (size_t g = 0; g < shape->count; g++) {
            size_t n = count_matches(s, src_len, shape->gates[g].find);
            gate_on[g] = n == (size_t)shape->gates[g].expect;
            if (gate_on[g]) { gate_live++; continue; }
            if (shape->gates[g].optional) {
                NP_WARN("webpatch: [%s] optional gate %zu expected %d occurrence(s), "
                        "found %zu; skipping it", shape->name, g, shape->gates[g].expect, n);
            } else {
                NP_WARN("webpatch: [%s] gate %zu expected %d occurrence(s), found %zu",
                        shape->name, g, shape->gates[g].expect, n);
                drifted = 1;
            }
        }
        if (drifted) {
            NP_ERR("webpatch: [%s] compat UI left unpatched, a Steam update moved the "
                   "anchors", shape->name);
            free(native_mac_js);
            return NULL;
        }
    }

    np_out_t out = {0};
    np_cap_t caps[NP_CAP_MAX];
    if (native_mac_js && (!out_put(&out, native_mac_js, strlen(native_mac_js)) ||
                          !out_put(&out, NP_RUNS_EXE_JS, sizeof(NP_RUNS_EXE_JS) - 1))) {
        free(out.buf);
        free(native_mac_js);
        return NULL;
    }
    free(native_mac_js);
    unsigned char can_start[256] = {0};
    for (size_t g = 0; shape && g < shape->count; g++)
        if (gate_on[g]) mark_start(can_start, shape->gates[g].find);
    for (size_t f = 0; f < NP_FIX_COUNT; f++)
        if (fix_on[f]) mark_start(can_start, g_fixes[f].find);
    for (size_t g = 0; library_filter && g < NP_LIBRARY_FILTER_COUNT; g++)
        if (library_on[g]) mark_start(can_start, g_library_filters[g].find);
    for (size_t i = 0; i < src_len; ) {
        size_t plain = i;
        while (plain < src_len && !can_start[(unsigned char)s[plain]]) plain++;
        if (plain > i) {
            if (!out_put(&out, s + i, plain - i)) { free(out.buf); return NULL; }
            i = plain;
            continue;
        }
        const np_gate_t *hit = NULL;
        size_t used = 0;
        for (size_t g = 0; shape && g < shape->count; g++) {
            if (!gate_on[g]) continue;
            used = match_at(s, src_len, i, shape->gates[g].find, caps);
            if (used) { hit = &shape->gates[g]; break; }
        }
        for (size_t f = 0; !hit && f < NP_FIX_COUNT; f++) {
            if (!fix_on[f]) continue;
            used = match_at(s, src_len, i, g_fixes[f].find, caps);
            if (used) { hit = &g_fixes[f]; break; }
        }
        for (size_t g = 0; !hit && library_filter && g < NP_LIBRARY_FILTER_COUNT; g++) {
            if (!library_on[g]) continue;
            used = match_at(s, src_len, i, g_library_filters[g].find, caps);
            if (used) { hit = &g_library_filters[g]; break; }
        }
        int ok = hit ? out_expand(&out, hit->replace, caps)
                     : out_put(&out, s + i, 1);
        if (!ok) { free(out.buf); return NULL; }
        i += hit ? used : 1;
    }

    if (!out_reserve(&out, 0)) { free(out.buf); return NULL; }
    out.buf[out.len] = '\0';
    *out_len = out.len;
    if (library_filter) NP_LOG("webpatch: Windows library filter button added");
    NP_LOG("webpatch: [%s] %zu gates, %zu fixes applied",
           shape ? shape->name : "no compat UI", gate_live, fix_live);
    return out.buf;
}
