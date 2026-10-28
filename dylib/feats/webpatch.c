// Enables Steam Play in the UI/enables the Compatibility tab in game properties
#include "webpatch.h"
#include "compatsvc.h"
#include "../util/buildid.h"
#include "nativeplatform.h"
#include "../util/log.h"

#include <dirent.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>

#define NP_STR_(x) #x
#define NP_STR(x) NP_STR_(x)

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
#define NP_DEFAULTS "\027"
#define NP_BUILDS "\030"
// MSCXReady and MSCXFeat.
#define NP_READY "\031"
#define NP_FEATS "\032"

#define NP_TOOL_NAME_MAX 128

#define NP_UNREAD_DEFAULTS "{rosetta:null,fex:null}"

enum { IN_FALLBACK_TOOL, IN_FEX_TOOLS, IN_DEFAULTS, IN_BUILDS, IN_COUNT };
typedef struct { char *text[IN_COUNT]; } np_inputs_t;
static const char *const g_unset[IN_COUNT] = { "", "[]", NP_UNREAD_DEFAULTS, "[]" };
static pthread_key_t g_inputs_key;
static pthread_once_t g_inputs_once = PTHREAD_ONCE_INIT;

static void inputs_free(void *p) {
    np_inputs_t *in = p;
    for (int i = 0; i < IN_COUNT; i++) free(in->text[i]);
    free(in);
}

static int g_inputs_ok;

static void inputs_key_make(void) { g_inputs_ok = pthread_key_create(&g_inputs_key, inputs_free) == 0; }

static void set_input(int which, char *text) {
    pthread_once(&g_inputs_once, inputs_key_make);
    if (!g_inputs_ok) { free(text); return; }
    np_inputs_t *in = pthread_getspecific(g_inputs_key);
    if (!in && (in = calloc(1, sizeof *in)) && pthread_setspecific(g_inputs_key, in) != 0) {
        free(in);
        in = NULL;
    }
    if (!in) { free(text); return; }
    free(in->text[which]);
    in->text[which] = text;
}

static const char *input_text(int which) {
    pthread_once(&g_inputs_once, inputs_key_make);
    const np_inputs_t *in = g_inputs_ok ? pthread_getspecific(g_inputs_key) : NULL;
    return in && in->text[which] ? in->text[which] : g_unset[which];
}

typedef struct {
    const char *find;
    const char *replace;
    int         expect;   // exact occurrence count, else abort
    int         optional; // skipped in the event that it doesn't match the current Steam client
} np_gate_t;

#define NP_GATE_PAGE 2

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
    set_input(IN_FALLBACK_TOOL, name && is_tool_name(name) ? strdup(name) : NULL);
}

typedef struct { char *buf; size_t size, len; int ok; } np_js_t;

static np_js_t js_alloc(size_t size) {
    char *buf = malloc(size);
    if (buf) buf[0] = '\0';
    return (np_js_t){ buf, buf ? size : 0, 0, buf != NULL };
}

static char *js_done(np_js_t *j) {
    if (j->ok) return j->buf;
    free(j->buf);
    return NULL;
}

static void js_put(np_js_t *j, const char *str, size_t n) {
    if (!j->ok || j->len + n >= j->size) { j->ok = 0; return; }
    memcpy(j->buf + j->len, str, n);
    j->len += n;
    j->buf[j->len] = '\0';
}

static void js_puts(np_js_t *j, const char *str) { js_put(j, str, strlen(str)); }

void np_webpatch_set_fex_tools(const char *const *names, size_t count) {
    if (count > NP_WEBPATCH_FEX_TOOLS_MAX) count = NP_WEBPATCH_FEX_TOOLS_MAX;
    size_t size = 3;
    for (size_t i = 0; names && i < count; i++) size += 3 + (names[i] ? strlen(names[i]) : 0);
    np_js_t j = js_alloc(size);
    js_put(&j, "[", 1);
    for (size_t i = 0; names && i < count; i++) {
        if (!names[i] || !*names[i] || !is_tool_name(names[i])) continue;
        if (j.ok && j.buf[j.len - 1] != '[') js_put(&j, ",", 1);
        js_put(&j, "\"", 1);
        js_puts(&j, names[i]);
        js_put(&j, "\"", 1);
    }
    js_put(&j, "]", 1);
    set_input(IN_FEX_TOOLS, js_done(&j));
}

static int is_setting_key(const char *str, size_t n) {
    if (!n) return 0;
    for (size_t i = 0; i < n; i++)
        if (!((str[i] >= 'A' && str[i] <= 'Z') || (str[i] >= '0' && str[i] <= '9') || str[i] == '_'))
            return 0;
    return 1;
}

static int is_setting_value(const char *str, size_t n) {
    for (size_t i = 0; i < n; i++)
        if (!is_ident_char((unsigned char)str[i]) && str[i] != '.' && str[i] != '=') return 0;
    return 1;
}

static void js_settings(np_js_t *j, const char *lines) {
    if (!lines) { js_puts(j, "null"); return; }
    js_put(j, "{", 1);
    int first = 1;
    for (const char *at = lines; *at; ) {
        const char *nl = strchr(at, '\n');
        size_t n = nl ? (size_t)(nl - at) : strlen(at);
        const char *eq = memchr(at, '=', n);
        if (eq && is_setting_key(at, (size_t)(eq - at)) && is_setting_value(eq + 1, n - (size_t)(eq - at) - 1)) {
            if (!first) js_put(j, ",", 1);
            first = 0;
            js_put(j, "\"", 1);
            js_put(j, at, (size_t)(eq - at));
            js_put(j, "\":\"", 3);
            js_put(j, eq + 1, n - (size_t)(eq - at) - 1);
            js_put(j, "\"", 1);
        }
        at += n + (nl ? 1 : 0);
    }
    js_put(j, "}", 1);
}

void np_webpatch_set_defaults(const char *rosetta, const char *fex) {
    np_js_t j = js_alloc(32 + 3 * (strlen(rosetta ? rosetta : "") + strlen(fex ? fex : "")));
    js_puts(&j, "{rosetta:");
    js_settings(&j, rosetta);
    js_puts(&j, ",fex:");
    js_settings(&j, fex);
    js_puts(&j, "}");
    if (!j.ok) NP_WARN("webpatch: the saved defaults do not fit the page, it hides them");
    set_input(IN_DEFAULTS, js_done(&j));
}

static int is_label(const char *str) {
    if (!str || !*str) return 0;
    for (; *str; str++)
        if ((unsigned char)*str < 0x20 || *str == '"' || *str == '\\') return 0;
    return 1;
}

void np_webpatch_set_builds(const np_webpatch_build_t *builds, size_t count) {
    if (count > NP_WEBPATCH_BUILDS_MAX) count = NP_WEBPATCH_BUILDS_MAX;
    size_t size = 3;
    for (size_t i = 0; builds && i < count; i++)
        size += 64 + strlen(builds[i].tool ? builds[i].tool : "") + strlen(builds[i].build ? builds[i].build : "")
              + strlen(builds[i].label ? builds[i].label : "")
              + (builds[i].override ? 3 * strlen(builds[i].override) + 8 : 4);
    np_js_t j = js_alloc(size);
    js_put(&j, "[", 1);
    for (size_t i = 0; builds && i < count; i++) {
        const np_webpatch_build_t *b = &builds[i];
        if (!b->tool || !*b->tool || !is_tool_name(b->tool) || !np_is_build_id(b->build) || !is_label(b->label)) {
            NP_WARN("webpatch: tool %zu cannot be shown on the Settings page", i);
            continue;
        }
        if (j.ok && j.buf[j.len - 1] != '[') js_put(&j, ",", 1);
        js_puts(&j, "{id:\"");
        js_puts(&j, b->tool);
        js_puts(&j, "\",build:\"");
        js_puts(&j, b->build);
        js_puts(&j, b->fex ? "\",runner:\"fex\",label:\"" : "\",runner:\"rosetta\",label:\"");
        js_puts(&j, b->label);
        js_puts(&j, "\",override:");
        js_settings(&j, b->override);
        js_puts(&j, "}");
    }
    js_put(&j, "]", 1);
    if (!j.ok) NP_WARN("webpatch: the CrossOver builds do not fit the page, it shows none");
    set_input(IN_BUILDS, js_done(&j));
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
static void feat_build(void);

static const char *marker_text(char c) {
    if (c == NP_FALLBACK_TOOL[0]) return input_text(IN_FALLBACK_TOOL);
    if (c == NP_FEX_TOOLS[0]) return input_text(IN_FEX_TOOLS);
    if (c == NP_DEFAULTS[0]) return input_text(IN_DEFAULTS);
    if (c == NP_BUILDS[0]) return input_text(IN_BUILDS);
    if (c == NP_READY[0] || c == NP_FEATS[0]) {
        if (!g_feat_ready_done) feat_build();
        return c == NP_READY[0] ? g_feat_ready : g_feat_rows;
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
    "return{p:G[0].start,e:G.slice(0,n<0?G.length:n),c:G.find(m)}})(),"

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
    "return{g,s,k:E.e.map(w=>o.slice(w.start,w.end).split(\"=\")[0]),c:E.c}}"

// The chosen program replaces the argument after waitforexitandrun and starts in its own folder, which Mod Engine 2's .bat needs. Other verbs run unchanged.
#define NP_CX_TARGET \
    "(o,id,home)=>{" \
    "const q=v=>\"'\"+v.replace(/'/g,\"'\\\\''\").replace(/%(?=command%)/gi,\"%'\\\"\\\"'\")+\"'\"," \
    "h=\"sh -c \"+q('exe=$1 dir=$2 found= prev=; shift 2; for arg in \"$@\"; do shift; '+" \
    "'if [ -z \"$found\" ] && [ \"$prev\" = waitforexitandrun ]; then arg=$exe found=1; fi; prev=$arg; set -- \"$@\" \"$arg\"; done; '+" \
    "'if [ \"$found\" ]; then cd \"${dir:-${exe%/*}/}\" || exit; fi; exec \"$@\"')+\" sh \"," \
    "at=o.indexOf(h)," \
    "m=at<0?null:/^('(?:[^']|'\\\\''|'\"\"')*') ('(?:[^']|'\\\\''|'\"\"')*') %command%/.exec(o.slice(at+h.length))," \
    "rd=v=>v.slice(1,-1).replace(/'\\\\''|'\"\"'/g,x=>x[1]===\"\\\\\"?\"'\":\"\")," \
    "b=m?o.slice(0,at)+\"%command%\"+o.slice(at+h.length+m[0].length):o;" \
    "return{home,ex:m?rd(m[1]):\"\",sd:m?rd(m[2]):\"\",write:(e,d)=>{" \
    "const B=/%command%/i.test(b)?b:\"%command%\"+(b.trim()?\" \"+b:\"\"),c=MSCXLaunch(B,id).c;" \
    "if(!c||!/^%command%$/i.test(B.slice(c.start,c.end)))return;" \
    "const r=B.slice(0,c.start)+(e?h+q(e)+\" \"+q(d)+\" %command%\":\"%command%\")+B.slice(c.end);" \
    "SteamClient.Apps.SetAppLaunchOptions(id,r.trim()===\"%command%\"?\"\":r)}}}"

#define NP_CX_PICK \
    "(t,n)=>{const o=t.strLaunchOptions||\"\";" \
    "if(" NP_FEX_TOOLS ".indexOf(n)<0||/[<>\\n]|\\$'/.test(o))return;" \
    "const L=MSCXLaunch(o,t.unAppID)," \
    "ks=L.k.filter(k=>/^D3DM_[A-Z0-9_]*$/.test(k)||k===\"ROSETTA_ADVERTISE_AVX\"" \
    "||k===\"CX_GRAPHICS_BACKEND\"&&L.g(k)===\"d3dmetal\");" \
    "ks.length&&L.s(ks.map(k=>[k,\"\"]))}"

// The picker refetches after the client's state notification, by which point the mapping
// has changed, so a new selection here is when the prefix row asks again.
#define NP_CX_TOOL_QUERY \
    "(r,id)=>{const q=r[0].data;if(id&&q){const k=q.selected_tool_identifier+\"|\"+q.default_tool_identifier," \
    "M=globalThis.MSCXSeen||(globalThis.MSCXSeen=new Map);" \
    "M.has(id)&&M.get(id)!==k&&queueMicrotask(()=>globalThis.dispatchEvent?.(new CustomEvent(\"mscxstate\",{detail:id})));" \
    "M.set(id,k)}return[r[0],v=>{r[1](v);const d=r[0].data;if(!id||!d)return;" \
    "const n=v||d.default_tool_identifier||\"" NP_FALLBACK_TOOL "\",a=(d.aliases||[]).find(x=>x.alias===n)," \
    "t=globalThis.appDetailsStore?.GetAppDetails(id);t&&MSCXPick(t,a?a.current_tool_name:n)}]}"

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
    "Mostra solo i giochi che funzionano su Windows e non hanno una versione macOS")

#define NP_LIBRARY_WINDOWS_SUMMARY NP_WEB_TEXT( \
    "Runs on Windows, no Mac OS version", \
    "Runs on Windows, no Mac OS version", \
    "Funziona su Windows, nessuna versione macOS")

// Rebuild row in the CrossOver panel. Chinese waits for a translator.
// The row is redrawn on every poll, so the bar keeps its phase from when the rebuild started
// instead of restarting on each redraw.
#define NP_PREFIX_NEED NP_WEB_TEXT("Switching to this compatibility tool requires a prefix rebuild. Rebuild now?", "Switching to this compatibility tool requires a prefix rebuild. Rebuild now?", "Per passare a questo strumento di compatibilit\\u00e0 bisogna ricostruire il prefisso. Ricostruirlo ora?")
#define NP_PREFIX_BACKUP NP_WEB_TEXT("Backup & Rebuild Prefix", "Backup & Rebuild Prefix", "Backup e ricostruisci prefisso")
#define NP_PREFIX_REBUILD NP_WEB_TEXT("Rebuild Prefix", "Rebuild Prefix", "Ricostruisci prefisso")
#define NP_PREFIX_RUNNING NP_WEB_TEXT("Quit the game to rebuild.", "Quit the game to rebuild.", "Chiudi il gioco per ricostruire il prefisso.")
#define NP_PREFIX_SETUP NP_WEB_TEXT("Rebuilding prefix\\u2026", "Rebuilding prefix\\u2026", "Ricostruzione del prefisso\\u2026")
#define NP_PREFIX_COPY NP_WEB_TEXT("Copying your files\\u2026", "Copying your files\\u2026", "Copia dei tuoi file\\u2026")
#define NP_PREFIX_FINISH NP_WEB_TEXT("Finishing\\u2026", "Finishing\\u2026", "Ultimi passaggi\\u2026")
#define NP_PREFIX_DONE NP_WEB_TEXT("Prefix rebuilt.", "Prefix rebuilt.", "Prefisso ricostruito.")
#define NP_PREFIX_DONE_BACKUP NP_WEB_TEXT("Prefix rebuilt. A backup of the original is in NotProton's Prefixes view.", "Prefix rebuilt. A backup of the original is in NotProton's Prefixes view.", "Prefisso ricostruito. Il backup dell'originale \\u00e8 nella sezione Prefissi di NotProton.")
#define NP_PREFIX_FAILED NP_WEB_TEXT("Prefix rebuild failed!", "Prefix rebuild failed!", "Ricostruzione del prefisso non riuscita.")
#define NP_PREFIX_LOG NP_WEB_TEXT("Open Log", "Open Log", "Apri registro")
#define NP_PREFIX_APP NP_WEB_TEXT("Couldn't find the NotProton app. Move NotProton to Applications, open it and click Install again.", "Couldn't find the NotProton app. Move NotProton to Applications, open it and click Install again.", "App NotProton non trovata. Sposta NotProton in Applicazioni, aprila e fai di nuovo clic su Installa.")

#define NP_CX_PREFIX_ROW \
    "globalThis.MSCXPrefixRow=(e,id)=>{if(e.npApp===id)return;e.npStop&&e.npStop();e.npApp=id;let ter" \
    "m='',busy=0,timer=0,t0=0,stopped=0,live=0;const T={need:" \
    NP_PREFIX_NEED \
    ",backup:" \
    NP_PREFIX_BACKUP \
    ",rebuild:" \
    NP_PREFIX_REBUILD \
    ",running:" \
    NP_PREFIX_RUNNING \
    ",setup:" \
    NP_PREFIX_SETUP \
    ",copy:" \
    NP_PREFIX_COPY \
    ",finish:" \
    NP_PREFIX_FINISH \
    ",done:" \
    NP_PREFIX_DONE \
    ",doneBackup:" \
    NP_PREFIX_DONE_BACKUP \
    ",failed:" \
    NP_PREFIX_FAILED \
    ",log:" \
    NP_PREFIX_LOG \
    ",app:" \
    NP_PREFIX_APP \
    "},el=(tag,cls,txt)=>{const n=e.ownerDocument.createElement(tag);if(cls)n.className=cls;if(txt!=n" \
    "ull)n.textContent=txt;return n},btn=(txt,main,off,on)=>{const b=el('button','MSCXBtn'+(main?' MS" \
    "CXMain':''),txt);b.disabled=!!off;b.onclick=on;return b},call=r=>MSCXRoute(r,id).then(j=>JSON.pa" \
    "rse(j||'{}')),refresh=()=>{if(stopped)return;if(!e.isConnected||e.npApp!==id)return stop();return MSCXRoute('NotProton.PrefixState#1',id).t" \
    "hen(j=>draw(JSON.parse(j))).catch(()=>{if(stopped||!e.isConnected||e.npApp!==id)return;clearTimeout(timer);if(busy||live)timer=setTimeout(refresh,500);else e.style.display='none'})},start=r=>{term='';busy=1;t0=Date.now();draw(null);cal" \
    "l(r).then(j=>{j.error==='spawn'&&(term='failed')},()=>0).finally(()=>{busy=0;refresh()})},pair=off=>{const r=el('div','MSCXBtns');r.app" \
    "end(btn(T.backup,1,off,()=>start('NotProton.BackupAndRebuildPrefix#1')),btn(T.rebuild,0,off,()=>" \
    "start('NotProton.RebuildPrefix#1')));return r},draw=s=>{if(stopped||!e.isConnected||e.npApp!==id)return;clearTimeout(timer);live=0;const ph=s?s.rebuild" \
    ":'',k=[];if(ph==='done'||ph==='done-backup'||ph==='failed')term=ph;s&&s.needsRebuild&&term!=='failed'&&(term='');if(busy||ph==='setup'||ph==='" \
    "copy'||ph==='finish'){k.push(el('div','',ph==='copy'?T.copy:ph==='finish'?T.finish:T.setup));con" \
    "st b=el('div','MSCXBar');t0||(t0=Date.now());const m=el('div','');m.style.animationDelay=-((Date.now()-t0)%1200)+'ms';b.append(m);k.push(b);live=1;timer=setTimeout(refresh,500)}else if((t0=0)||" \
    "term==='failed'){k.push(el('div','',T.failed));const r=el('div','MSCXBtns');r.append(btn(T.log,0" \
    ",0,()=>call('NotProton.OpenPrefixLog#1').catch(()=>0)));k.push(r);s&&s.needsRebuild&&s.app&&!s.r" \
    "unning&&k.push(pair(0))}else if(term)k.push(el('div','',term==='done-backup'?T.doneBackup:T.done" \
    "));else if(s&&s.needsRebuild){if(!s.app)k.push(el('div','',T.app));else{k.push(el('div','',s.run" \
    "ning?T.running:T.need),pair(s.running));s.running&&(timer=setTimeout(refresh,3e3))}}e.replaceChi" \
    "ldren(...k);e.style.display=k.length?'':'none'};e.style.flexDirection='column';e.style.gap='8px'" \
    ";e.style.display='none';const on=v=>{if(!e.isConnected)return e.npStop();v.detail===id&&!busy&&(" \
    "term='',refresh())};const stop=e.npStop=()=>{stopped=1;clearTimeout(timer);observer?.disconnect();globalThis.removeEventListener?.('mscxstat" \
    "e',on)};const observer=globalThis.MutationObserver?new globalThis.MutationObserver(()=>{if(!e.isConnected)stop()}):null;observer?.observe(e.ownerDocument,{childList:true,subtree:true});globalThis.addEventListener?.('mscxstate',on);refresh()};"


#define NP_CX_OPTIONS_CSS \
    "\".MSCXPanel{margin-top:10px}" \
    ".MSCXPanel .MSCXRow{display:flex;flex-direction:row;padding:9px;margin:0;" \
    "font-size:14px;line-height:18px;color:#dfe3e6;background:rgba(59,63,72,.5);border-radius:3px}" \
    ".MSCXPanel .MSCXRow:hover{box-shadow:0 6px 8px 0 rgba(0,0,0,.16)}" \
    ".MSCXPanel .MSCXRowDesc{flex-wrap:wrap;align-items:center}" \
    ".MSCXPanel .MSCXRowDesc>:last-child{flex-basis:100%}" \
    ".MSCXNoBottomGap{margin-bottom:0}" \
    ".DesktopUI .MSCXSetBtn,.MSCXSetBtn.DesktopUI{color:#dfe3e6;background-color:rgba(59,63,72,.5);" \
    "padding:8px 14px;font-size:13px;line-height:18px}" \
    "@media(prefers-contrast: more){.DesktopUI .MSCXSetBtn,.MSCXSetBtn.DesktopUI{background:#000;color:#fff}}" \
    ".MSCXBtns{display:flex;gap:8px}" \
    ".MSCXBtn{background:#3d4450;color:#fff;border:none;border-radius:2px;padding:6px 14px;" \
    "font-size:14px;cursor:pointer}.MSCXBtn:hover{background:#4c5361}" \
    ".MSCXBtn.MSCXMain{background:#1a9fff}.MSCXBtn.MSCXMain:hover{background:#47b4ff}" \
    ".MSCXBtn:disabled{opacity:.5;cursor:default}" \
    ".MSCXBtn:focus-visible{outline:2px solid #fff;outline-offset:1px}" \
    ".MSCXBar{position:relative;align-self:stretch;width:100%;height:4px;overflow:hidden;" \
    "border-radius:2px;background:rgba(255,255,255,.12)}" \
    ".MSCXBar>div{position:absolute;top:0;bottom:0;left:-30%;width:30%;background:#1a9fff;" \
    "animation:MSCXSlide 1.2s linear infinite}" \
    "@keyframes MSCXSlide{from{left:-30%}to{left:100%}}\""

#define NP_CX_BARREL(X) X(XY) X(m) X(Yh) X($n) X(Vb) X(D0)
#define NP_CX_BARREL_C(n) #n,
#define NP_CX_BARREL_JS(n) "\"" #n "\","
#define NP_CX_BARREL_NAMES { NP_CX_BARREL(NP_CX_BARREL_C) }
#define NP_CX_BARREL_READY(B) "[" NP_CX_BARREL(NP_CX_BARREL_JS) "].every(n=>" B "[n])"

#define NP_CX_FACTOR_ENTRY "e=>/^[ \\t\\r]*d3d11\\.metalSpatialUpscaleFactor[ \\t\\r]*=/.test(e)"

#define NP_CX_DEFAULTS "(globalThis.MSCXDefaultsData||(globalThis.MSCXDefaultsData=" NP_DEFAULTS "))"
#define NP_CX_BUILDS "(globalThis.MSCXBuilds||(globalThis.MSCXBuilds=" NP_BUILDS "))"

// FEX runs arm64 Wine, which has no D3DMetal and never runs under Rosetta.
#define NP_CX_PANEL(RT, BARREL) \
    "({fex,get:G,saved:readSaved,set:s,clearUnused,head,dflt,dev,target:X})=>{" \
    "const npZh=" NP_WEB_IS_ZH ",npIt=" NP_WEB_IS_IT ",npL=(en,zh,it)=>npZh?zh:npIt?it:en," \
    "MSCXReady=" NP_READY ",MSCXFeat=" NP_FEATS "," \
    "on1=(k,n=0)=>{const p=MSCXFeat.find(x=>x.k===k);" \
    "return!!p&&n<32&&MSCXReady[k]!==0&&G(k)===p.on&&(!p.dep||on1(p.dep,n+1))}," \
    "P=f=>{const rd=MSCXReady[f.k]!==0;" \
    "return(0," RT ".jsx)(" BARREL ".Yh," \
    "{className:\"MSCXRow\"+(f.d?\" MSCXRowDesc\":\"\")," \
    "label:rd?f.l:f.l+npL(\" (not installed)\",\" (未安装)\",\" (not installed)\"),disabled:!rd," \
    "description:f.d||undefined," \
    "checked:rd&&G(f.k)===f.on," \
    "onChange:v=>s([[f.k,v?f.on:(f.off||\"\")]])},f.k)}," \
    "w=(k,v,none)=>dflt&&v===(dflt(k)||none)?\"\":v," \
    "T=(k,l)=>(0," RT ".jsx)(" BARREL ".Yh,{className:\"MSCXRow\",label:l," \
    "checked:\"1\"===G(k),onChange:v=>s([[k,w(k,v?\"1\":\"0\",\"0\")]])},k)," \
    "D=(k,l)=>(0," RT ".jsx)(" BARREL ".Yh,{className:\"MSCXRow\",label:l," \
    "checked:\"0\"!==G(k),onChange:v=>s([[k,w(k,v?\"1\":\"0\",\"1\")]])},k)," \
    "SL=(k,en)=>globalThis.LocalizationManager?.LocalizeString?.(k,!0)??en," \
    "ex=X?X.ex:\"\",exd=ex.replace(/\\/[^\\/]*$/,\"\")||\"/\",sd=X&&X.sd||exd," \
    "pk=(q,f)=>SteamClient.System.OpenFileDialog(q).then(p=>p&&f(p),()=>{})," \
    "bt=(l,f,k)=>(0," RT ".jsx)(" BARREL ".$n,{className:\"MSCXSetBtn\",onClick:f,children:l},k)," \
    "br=SL(\"#AppProperties_Shortcut_BrowseFiles\",\"Browse...\")," \
    "XF=(k,l,d,c)=>(0," RT ".jsx)(" BARREL ".D0,{label:l,description:d,childrenContainerWidth:\"min\"," \
    "children:(0," RT ".jsx)(\"div\",{className:\"MSCXBtns\",children:c})},k)," \
    "exe=X&&(0," RT ".jsxs)(" BARREL ".XY,{label:npL(\"Launch Executable\",\"Launch Executable\",\"Launch Executable\"),children:[" \
    "XF(\"target\",npL(\"Executable\",\"Executable\",\"Executable\"),ex||undefined,[" \
    "ex&&bt(SL(\"#Button_Remove\",\"Remove\"),()=>X.write(\"\",\"\"),\"remove\")," \
    "bt(br,()=>pk({strTitle:npL(\"Choose a Program to Launch\",\"选择要启动的程序\",\"Scegli il programma da avviare\")," \
    "rgFilters:[{strFileTypeName:npL(\"Windows Programs (*.exe, *.bat)\",\"Windows 程序 (*.exe, *.bat)\"," \
    "\"Programmi Windows (*.exe, *.bat)\"),rFilePatterns:[\"*.exe\",\"*.bat\"],bUseAsDefault:!0}]," \
    "strInitialFile:ex||X.home},p=>X.write(p,\"\")),\"pick\")])," \
    "ex&&XF(\"dir\",npL(\"Start Executable From\",\"Start Executable From\",\"Start Executable From\"),sd,[" \
    "sd!==exd&&bt(SL(\"#AppProperties_Customization_Reset\",\"Reset\"),()=>X.write(ex,\"\"),\"reset\")," \
    "bt(br,()=>pk({strTitle:SL(\"#AppProperties_Shortcut_ChooseStartDirectoryDialogTitle\",\"Choose Start Directory\")," \
    "strInitialFile:sd,bChooseDirectory:!0},p=>X.write(ex,p===exd?\"\":p)),\"pick\")])" \
    "]},\"exe\")," \
    "bv=G(\"CX_GRAPHICS_BACKEND\"),b=\"auto\"===bv||fex&&\"d3dmetal\"===bv?\"\":bv," \
    "dm=!fex&&(\"\"===b||\"d3dmetal\"===b)," \
    "dx=\"\"===b||\"dxmt\"===b," \
    "sw=\"1\"===G(\"DXMT_METALFX_SPATIAL_SWAPCHAIN\")," \
    "F=\"d3d11.metalSpatialUpscaleFactor=\",fk=" NP_CX_FACTOR_ENTRY "," \
    "fe=readSaved(\"DXMT_CONFIG\").split(\";\").filter(e=>e.trim())," \
    "fx=v=>fe.filter(e=>!fk(e)).concat(v?[F+v]:[]).join(\";\")," \
    "pf=c=>{const v=(c.split(\";\").filter(fk).pop()||\"=2\").replace(/^[^=]*=/,\"\").replace(/\"/g,\"\").trim().split(/\\s/)[0];" \
    "return Math.max(isNaN(+v)?2:+v,1)}," \
    "fn=pf(G(\"DXMT_CONFIG\"))," \
    "U=[{data:\"\",label:npL(\"Off\",\"关闭\",\"Disattivato\")}," \
    "{data:\"1.5\",label:\"1.5x\"}," \
    "{data:\"1.72\",label:\"1.72x\"}," \
    "{data:\"2.0\",label:\"2x\"}," \
    "{data:\"3.0\",label:\"3x\"}]," \
    "B=[{data:\"\",label:npL(\"Automatic\",\"自动\",\"Automatico\")}," \
    "{data:\"d3dmetal\",label:\"D3DMetal\"}," \
    "{data:\"dxmt\",label:\"DXMT\"}," \
    "{data:\"dxvk\",label:\"DXVK\"}," \
    "{data:\"wined3d\",label:\"WineD3D\"}].filter(x=>!fex||x.data!==\"d3dmetal\")," \
    "pick=f=>\"1\"===f(\"DXMT_METALFX_SPATIAL_SWAPCHAIN\")?(U.find(u=>u.data&&+u.data===pf(f(\"DXMT_CONFIG\")||\"\"))" \
    "||{data:String(pf(f(\"DXMT_CONFIG\")||\"\"))}).data:\"\";" \
    "return(0," RT ".jsx)(\"div\",{className:\"MSCXPanel\",children:(0," RT ".jsxs)(" RT ".Fragment,{children:[" \
    "(0," RT ".jsx)(\"style\",{children:" NP_CX_OPTIONS_CSS "}),head," \
    "(0," RT ".jsxs)(" BARREL ".XY,{label:npL(\"Graphics\",\"图形\",\"Grafica\"),children:[" \
    "(0," RT ".jsx)(" BARREL ".m,{rgOptions:B,selectedOption:b," \
    "onChange:v=>s([[\"CX_GRAPHICS_BACKEND\",w(\"CX_GRAPHICS_BACKEND\",v.data||\"auto\",\"auto\")]]" \
    ".concat(!clearUnused||\"\"===v.data||\"d3dmetal\"===v.data?[]:[[\"D3DM_ENABLE_METALFX\",\"\"]])" \
    ".concat(!clearUnused||\"\"===v.data||\"dxmt\"===v.data?[]:" \
    "[[\"DXMT_METALFX_SPATIAL_SWAPCHAIN\",\"\"],[\"DXMT_CONFIG\",fx(\"\")]])" \
    ".concat(!clearUnused||\"dxmt\"===v.data?[]:[[\"DXMT_ENABLE_NVEXT\",\"\"]]))})," \
    "T(\"MTL_HUD_ENABLED\",npL(\"Metal HUD\",\"Metal 性能监视器\",\"Metal HUD\"))," \
    "dm&&T(\"D3DM_ENABLE_METALFX\",\"DLSS\")," \
    "\"dxmt\"===b&&T(\"DXMT_ENABLE_NVEXT\",\"DLSS\")," \
    "!fex&&D(\"ROSETTA_ADVERTISE_AVX\",npL(\"Advertise AVX2 to Rosetta\",\"向 Rosetta 声明 AVX2 支持\",\"Segnala AVX2 a Rosetta\"))," \
    "T(\"WINEMSYNC\",\"MSync\")," \
    "T(\"NOTPROTON_RETINA\",npL(\"High Resolution\",\"高分辨率\",\"Alta risoluzione\"))" \
    "]},\"gfx\")," \
    "dx&&(0," RT ".jsx)(" BARREL ".XY," \
    "{label:npL(\"MetalFX Upscaling (Samples from the resolution the game is set to)\"," \
    "\"MetalFX 超分辨率（以游戏设置的分辨率为采样来源）\",\"Upscaling MetalFX (ingrandisce l'immagine dalla risoluzione del gioco)\")," \
    "children:(0," RT ".jsx)(" BARREL ".m,{rgOptions:U," \
    "selectedOption:sw?(U.find(u=>u.data&&+u.data===fn)||{data:String(fn)}).data:\"\"," \
    "onChange:v=>s(dflt&&v.data===pick(k=>dflt(k)||\"\")" \
    "?[[\"DXMT_METALFX_SPATIAL_SWAPCHAIN\",\"\"],[\"DXMT_CONFIG\",fx(\"\")]]" \
    ":[[\"DXMT_METALFX_SPATIAL_SWAPCHAIN\",v.data?\"1\":\"0\"],[\"DXMT_CONFIG\",fx(v.data)]])})},\"usf\")," \
    "(0," RT ".jsxs)(" BARREL ".XY,{label:npL(\"Controllers\",\"控制器\",\"Controller\"),children:[" \
    "T(\"NOTPROTON_RAW_CONTROLLERS\",npL(\"Let games read controllers directly (May break Steam Input. Not recommended)\"," \
    "\"允许游戏直接读取控制器（可能导致 Steam Input 失效，不推荐）\"," \
    "\"Lascia che i giochi leggano direttamente i controller (pu\\u00f2 interferire con Steam Input, sconsigliato)\"))," \
    "T(\"NOTPROTON_DISABLE_HIDRAW\",npL(\"Disable hidraw\",\"停用 hidraw\",\"Disattiva hidraw\"))" \
    "]},\"ctl\")," \
    "fex&&(0," RT ".jsx)(" BARREL ".XY,{label:\"FEX\"," \
    "children:D(\"FEX_X87REDUCEDPRECISION\"," \
    "\"Reduced x87 Precision (Reducing precision improves game performance, is enabled by default in CrossOver Preview)\")},\"fex\"),exe," \
    "dev&&MSCXFeat.length?(0," RT ".jsx)(" BARREL ".XY,{label:npL(\"Developer\",\"开发者\",\"Developer\")," \
    "children:MSCXFeat.filter(f=>!f.dep||on1(f.dep)).map(P)},\"dev\"):null" \
    "]})})}"

#define NP_CX_OPTIONS_BODY(RT, BARREL) \
    "np=>{" \
    "const t=np.details,o=t.strLaunchOptions||\"\",tn=t.strCompatToolName||\"" NP_FALLBACK_TOOL "\"," \
    "fex=" NP_FEX_TOOLS ".indexOf(tn)>=0," \
    "L=MSCXLaunch(o,t.unAppID),g=L.g,has=k=>L.k.includes(k)," \
    "lost=globalThis.MSCXDefaultsLost,DF=lost?{}:(" NP_CX_BUILDS ".find(x=>x.id===tn)||{}).override||" NP_CX_DEFAULTS "[fex?\"fex\":\"rosetta\"]||{}," \
    "fk=" NP_CX_FACTOR_ENTRY "," \
    "own=g(\"DXMT_CONFIG\").split(\";\").filter(e=>e.trim())," \
    "G=k=>\"DXMT_CONFIG\"===k?(own.some(fk)?g(k):DF[k]||\"\"):has(k)?g(k):DF[k]||\"\";" \
    "if(t.unAppID<2147483648&&(t.vecPlatforms||[]).indexOf(\"osx\")>=0" \
    "&&!t.strCompatToolName)return null;" \
    "return MSCXPanel({fex,get:G,saved:g,set:L.s,clearUnused:1,dev:1,dflt:lost?null:k=>DF[k]," \
    "target:(" NP_CX_TARGET ")(o,t.unAppID,t.strInstallFolder||\"\"),head:" \
    "typeof MSCXPrefixRow==\"function\"&&(0," RT ".jsx)(\"div\",{className:\"MSCXRow\",ref:e=>e&&MSCXPrefixRow(e,t.unAppID)},\"npstate\")" \
    "})}"

// React breaks if the hook count changes between renders, so the hooks wait in their own component
// until Steam's globals exist.
#define NP_CX_DEFAULTS_PAGE_BODY(RT, BARREL) \
    "(()=>{let Q=Promise.resolve(),gen=0,warned=0,lost=0;" \
    "const ser=d=>Object.keys(d).map(k=>k+\"=\"+d[k]).join(\"\\n\"),I=()=>{" \
    "const use=globalThis.MSCXUseState,eff=globalThis.MSCXUseEffect,send=globalThis.MSCXSpecifyRoute;" \
    "const BL=" NP_CX_BUILDS ",only=BL.length&&BL.every(x=>x.runner===BL[0].runner)?BL[0].runner:\"\"," \
    "d0=BL.find(x=>x.id===globalThis.MSCXDefaultTool)||BL[0]," \
    "[r,sr]=use(d0&&\"fex\"===d0.runner?1:0),[id,si]=use(d0?d0.id:\"\"),[,bump]=use(0),[ok,sok]=use(\"\"),all=" NP_CX_DEFAULTS "," \
    "fex=1===r,n=fex?\"fex\":\"rosetta\",b=BL.find(x=>x.id===id)," \
    "set=(nn,c)=>c?c.override||all[nn]||{}:all[nn]||{},DF=set(n,b),G=k=>DF[k]||\"\"," \
    "q=f=>{Q=Q.then(f).catch(e=>console.error(\"NotProton: the defaults were not saved\",e))}," \
    "clr=()=>{gen++;sok(\"\")}," \
    "done=(x,f)=>{if(x.BSuccess()){f();bump(c=>c+1);return 1}" \
    "console.error(\"NotProton: the defaults were not saved, result \"+x.GetEResult());return 0}," \
    "put=(rv,nn,c,d)=>(c?send(\"NotProton.SetToolDefaults#1\",0,c.id+\"\\n\"+ser(d))" \
    ":send(\"NotProton.SetDefaults#1\",rv,ser(d))).then(x=>done(x,()=>{c?c.override=d:all[nn]=d}))," \
    "s=ps=>{const rv=r,nn=n,c=b;clr();q(()=>{const d=Object.assign({},set(nn,c));" \
    "ps.forEach(p=>{p[1]&&\"auto\"!==p[1]?d[p[0]]=p[1]:delete d[p[0]]});return put(rv,nn,c,d)})}," \
    "kind=only===n?\"CrossOver\":fex?\"FEX\":\"Rosetta\"," \
    "apply=()=>{const nn=n,c=b,kk=kind;clr();const my=gen;" \
    "q(()=>{const d=Object.assign({},c.override||all[nn]||{});" \
    "return send(\"NotProton.ApplyToolDefaults#1\",0,c.id).then(x=>{" \
    "if(" NP_STR(NP_COMPATSVC_PARTLY_APPLIED) "===x.GetEResult()){all[nn]=d;lost=1;globalThis.MSCXDefaultsLost=1;bump(c=>c+1);console.error(\"NotProton: Apply left some versions " \
    "with their own settings, so Default Compatibility Settings are hidden until Steam restarts\");return}" \
    "done(x,()=>{all[nn]=d;BL.forEach(y=>{y.runner===nn&&(y.override=null)})})" \
    "&&my===gen&&sok(" NP_WEB_IS_IT "?\"Applicate. Ora tutti gli strumenti di compatibilit\\u00e0 \"+kk+\" usano queste impostazioni.\":\"Applied. Every \"+kk+\" Compatibility Tool now uses these settings.\")})})}," \
    "pickTool=t=>{const p=BL.find(x=>x.id===t);if(p){si(p.id);sr(\"fex\"===p.runner?1:0);clr()}}," \
    "btn=(k,l,t,f,dsc)=>(0," RT ".jsx)(" BARREL ".D0,{label:l,description:dsc," \
    "childrenContainerWidth:\"min\",children:(0," RT ".jsx)(" BARREL ".$n,{className:\"MSCXSetBtn\"," \
    "onClick:f,children:t})},k);" \
    "eff(()=>{const on=e=>pickTool(e.detail);globalThis.addEventListener?.(\"mscxdefaulttool\",on);" \
    "return()=>globalThis.removeEventListener?.(\"mscxdefaulttool\",on)},[]);if(lost)return null;" \
    "return MSCXPanel({fex,get:G,saved:G,set:s,head:(0," RT ".jsxs)(" BARREL ".XY,{label:" NP_WEB_TEXT("Default Compatibility Settings", "Default Compatibility Settings", "Impostazioni di compatibilit\\u00e0 predefinite") ",children:[" \
    "BL.length?(0," RT ".jsx)(" BARREL ".Vb,{label:" NP_WEB_TEXT("CrossOver version", "CrossOver version", "Versione di CrossOver") "," \
    "bMatchWidth:!1,rgOptions:BL.map(x=>({data:x.id,label:x.label}))," \
    "selectedOption:b?b.id:\"\",onChange:v=>{const p=BL.find(x=>x.id===v.data);if(!p)return;" \
    "si(p.id);sr(p.runner===\"fex\"?1:0);clr()}},\"version\"):null," \
    "b?btn(\"apply\",(" NP_WEB_IS_IT "?\"Applica come predefinite a tutti gli strumenti di compatibilit\\u00e0 \"+kind:\"Apply as defaults for all \"+kind+\" Compatibility Tools\")," NP_WEB_TEXT("Apply", "Apply", "Applica") ",apply,ok||void 0):null" \
    "]},\"defaults\")})};" \
    "return()=>{const up=typeof globalThis.MSCXUseState==\"function\"&&typeof globalThis.MSCXUseEffect==\"function\"" \
    "&&typeof globalThis.MSCXSpecifyRoute==\"function\";" \
"const dd=" NP_CX_DEFAULTS ";if(null===dd.rosetta||null===dd.fex){" \
    "warned||(warned=1,console.error(\"NotProton: the saved defaults could not be read, so Default Compatibility Settings are hidden\"));" \
    "return null}" \
    "if(up&&" NP_CX_BARREL_READY(BARREL) ")return(0," RT ".jsx)(I,{});" \
    "up&&!warned&&(warned=1,console.error(\"NotProton: Steam renamed its settings components, so Default Compatibility Settings are hidden\"));" \
    "return null}})()"
#define NP_CX_CAPTURE(BODY, RT, BARREL) \
    "((npReact,npUI)=>" BODY("npReact()", "npUI()") ")(()=>" RT ",()=>" BARREL ")"

#define NP_CX_OPTIONS_COMPONENT \
    "MSCXLaunch=" NP_CX_LAUNCH ",MSCXPick=" NP_CX_PICK "," \
    "MSCXPanel=" NP_CX_CAPTURE(NP_CX_PANEL, NP_C4, NP_C5) "," \
    "MSCXOpts=" NP_CX_CAPTURE(NP_CX_OPTIONS_BODY, NP_C4, NP_C5) ","

// Valve is testing a new compatibility page UI, this logic relates to supporting that
#define NP_CX_OPTIONS_STATEMENT \
    "var MSCXLaunch=" NP_CX_LAUNCH ";" \
    "var MSCXPick=" NP_CX_PICK ";" \
    "var MSCXToolQuery=" NP_CX_TOOL_QUERY ";" \
    "var MSCXPanel=" NP_CX_CAPTURE(NP_CX_PANEL, NP_C3, NP_C4) ";" \
    "var MSCXOpts=" NP_CX_CAPTURE(NP_CX_OPTIONS_BODY, NP_C3, NP_C4) ";" \
    "var MSCXDefaultsPage=" NP_CX_CAPTURE(NP_CX_DEFAULTS_PAGE_BODY, NP_C3, NP_C4) ";"

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
    // SteamPlay settings section
    { "function " NP_C1 "(" NP_C2 "){return(0," NP_C3 ".jsxs)(" NP_C4 ".XY,{label:(0," NP_C5 ".we)"
      "(\"#Settings_SteamPlay_SteamPlay\"),children:[(0," NP_C3 ".jsx)(" NP_C6 ",{}),"
      "(0," NP_C3 ".jsx)(" NP_C7 ".G,{setting:\"compat_show_all_tools\",label:(0," NP_C5 ".we)"
      "(\"#Settings_SteamPlay_ShowAll\"),feature:" NP_C8 ".OK})]})}",
      "function " NP_C1 "(" NP_C2 "){return(0," NP_C3 ".jsxs)(" NP_C3 ".Fragment,{children:["
      "(0," NP_C3 ".jsxs)(" NP_C4 ".XY,{label:(0," NP_C5 ".we)"
      "(\"#Settings_SteamPlay_SteamPlay\"),children:[(0," NP_C3 ".jsx)(" NP_C6 ",{}),"
      "(0," NP_C3 ".jsx)(" NP_C7 ".G,{setting:\"compat_show_all_tools\",label:(0," NP_C5 ".we)"
      "(\"#Settings_SteamPlay_ShowAll\"),feature:" NP_C8 ".OK})]}),"
      "(0," NP_C3 ".jsx)(MSCXDefaultsPage,{})]})}", 1, NP_GATE_PAGE },
    // SpecifyCompatTool: hands its transport to MSCXSpecifyRoute for the defaults routes
    { "function " NP_C1 "(" NP_C2 "," NP_C3 "){return " NP_C3 "=" NP_C3 "||(0," NP_C4
      ".OI)().GetDefaultTransport()," NP_C3 "==null?new Promise((" NP_C5 "," NP_C6 ")=>{"
      "console.error(\"Transport Error: no transport is available for request\"),"
      NP_C6 "(\"Transport Error: no transport is available for request\")}):" NP_C3
      ".SendMsg(\"CompatManager.SpecifyCompatTool#1\",(0," NP_C7 ".I8)(" NP_C8 "," NP_C2 "),"
      NP_C9 ",{ePrivilege:1,eClientExecutionSite:2})}" NP_C10 ".SendMsgSpecifyCompatTool=" NP_C1 ",",
      "function " NP_C1 "(" NP_C2 "," NP_C3 "){return " NP_C3 "=" NP_C3 "||(0," NP_C4
      ".OI)().GetDefaultTransport()," NP_C3 "==null?new Promise((" NP_C5 "," NP_C6 ")=>{"
      "console.error(\"Transport Error: no transport is available for request\"),"
      NP_C6 "(\"Transport Error: no transport is available for request\")}):" NP_C3
      ".SendMsg(\"CompatManager.SpecifyCompatTool#1\",(0," NP_C7 ".I8)(" NP_C8 "," NP_C2 "),"
      NP_C9 ",{ePrivilege:1,eClientExecutionSite:2})}"
      "globalThis.MSCXSpecifyRoute=(npRt,npA,npX)=>{const npT=(0," NP_C4 ".OI)().GetDefaultTransport();"
      "return!/^NotProton\\./.test(npRt)?Promise.reject(\"not a NotProton route\"):"
      "npT==null?Promise.reject(\"Transport Error: no transport is available for request\"):"
      "npT.SendMsg(npRt,(0," NP_C7 ".I8)(" NP_C8 ",{appid:npA,tool_name:npX}),"
      NP_C9 ",{ePrivilege:1,eClientExecutionSite:2})},"
      NP_C10 ".SendMsgSpecifyCompatTool=" NP_C1 ",", 1, NP_GATE_PAGE },
    { "const " NP_C1 "=new " NP_C2 ";function " NP_C3 "(" NP_C4 "){const " NP_C5 "=" NP_C6
      ".useCallback(async()=>{const " NP_C7 "=await " NP_C8 ".GetCompatTools({appid:" NP_C4 "});",
      "const " NP_C1 "=new " NP_C2 ";globalThis.MSCXUseState=" NP_C6 ".useState;"
      "globalThis.MSCXUseEffect=" NP_C6 ".useEffect;function " NP_C3
      "(" NP_C4 "){const " NP_C5 "=" NP_C6
      ".useCallback(async()=>{const " NP_C7 "=await " NP_C8 ".GetCompatTools({appid:" NP_C4 "});", 1, NP_GATE_PAGE },
    // Compatibility Tool selector, wrapped to drop settings a FEX tool cannot use
    { "[" NP_C1 "," NP_C2 "]=(0," NP_C3 ".cT)(" NP_C4 ");if(" NP_C1 ".isLoading||!" NP_C1
      ".data?.tools?.length)return null;",
      "[" NP_C1 "," NP_C2 "]=(typeof MSCXToolQuery==\"function\"?MSCXToolQuery:r=>r)"
      "((0," NP_C3 ".cT)(" NP_C4 ")," NP_C4 ");if(" NP_C1
      ".isLoading||!" NP_C1 ".data?.tools?.length)return null;", 1, 1 },
    // CompatManager service: hands the page's transport to MSCXRoute for NotProton's own routes
    { NP_C7 "=" NP_C7 "||(0," NP_C8 ".OI)().GetDefaultTransport(),"
      NP_C7 "==null?new Promise((" NP_C9 "," NP_C10 ")=>{console.error(\"Transport Error: no transport is available for request\"),"
      NP_C10 "(\"Transport Error: no transport is available for request\")}):"
      NP_C7 ".SendMsg(\"CompatManager.GetCompatTools#1\",(0," NP_C1 ".I8)(" NP_C2 "," NP_C3 ")," NP_C4 ","
      "{ePrivilege:1,eClientExecutionSite:2})}" NP_C5 ".GetCompatTools=" NP_C6 ";",
      NP_C7 "=" NP_C7 "||(0," NP_C8 ".OI)().GetDefaultTransport(),"
      NP_C7 "==null?new Promise((" NP_C9 "," NP_C10 ")=>{console.error(\"Transport Error: no transport is available for request\"),"
      NP_C10 "(\"Transport Error: no transport is available for request\")}):"
      NP_C7 ".SendMsg(\"CompatManager.GetCompatTools#1\",(0," NP_C1 ".I8)(" NP_C2 "," NP_C3 ")," NP_C4 ","
      "{ePrivilege:1,eClientExecutionSite:2})}"
      "globalThis.MSCXRoute=(r,id)=>{const t=(0," NP_C8 ".OI)().GetDefaultTransport();"
      "return!/^NotProton\\./.test(r)?Promise.reject(\"not a NotProton route\"):t?t.SendMsg(r,(0," NP_C1 ".I8)(" NP_C2 ",{appid:id})," NP_C4 ",{ePrivilege:1,eClientExecutionSite:2})"
      ".then(x=>x.BSuccess()?x.Body().toObject().default_tool_identifier||\"\":Promise.reject(\"result \"+x.GetEResult()))"
      ":Promise.reject(\"no transport\")};" NP_CX_PREFIX_ROW NP_C5 ".GetCompatTools=" NP_C6 ";", 1, 1 },
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
      "return(globalThis.MSCXDefaultTool!==(" NP_C1 "||\"" NP_FALLBACK_TOOL "\")&&(globalThis.MSCXDefaultTool="
      NP_C1 "||\"" NP_FALLBACK_TOOL "\",queueMicrotask(()=>globalThis.dispatchEvent?.(new CustomEvent(\"mscxdefaulttool\","
      "{detail:globalThis.MSCXDefaultTool})))),"
      NP_C1 "||" NP_C6 ".some(e=>e.data===\"" NP_FALLBACK_TOOL "\"))?(0," NP_C2 ".jsx)("
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

static const char *find_in(const char *s, size_t len, const char *want) {
    size_t n = strlen(want);
    for (size_t i = 0; n <= len && i <= len - n; i++)
        if (s[i] == want[0] && memcmp(s + i, want, n) == 0) return s + i;
    return NULL;
}

static const char *find_barrel(const char *s, size_t len, size_t *span) {
    static const char *const names[] = NP_CX_BARREL_NAMES;
    char anchor[16];
    snprintf(anchor, sizeof anchor, "%s:()=>", names[0]);
    for (const char *at = s; (at = find_in(at, len - (size_t)(at - s), anchor)); at++) {
        const char *open = at, *close = at;
        while (open > s && open[-1] != '{' && open[-1] != '}' && at - open < 16384) open--;
        while ((size_t)(close - s) < len && *close != '}' && close - at < 16384) close++;
        if (open == s || open[-1] != '{' || (size_t)(close - s) >= len || *close != '}') continue;
        int all = 1;
        for (size_t i = 0; all && i < sizeof names / sizeof names[0]; i++) {
            char lead[16], mid[16];
            snprintf(lead, sizeof lead, "{%s:()=>", names[i]);
            snprintf(mid, sizeof mid, ",%s:()=>", names[i]);
            all = find_in(open - 1, (size_t)(close - open) + 1, lead)
               || find_in(open - 1, (size_t)(close - open) + 1, mid);
        }
        if (all) {
            if (span) *span = (size_t)(close - open) + 2;
            return open - 1;
        }
    }
    return NULL;
}

int np_webpatch_has_shape(const uint8_t *src, size_t src_len) {
    for (size_t i = 0; i < NP_SHAPE_COUNT; i++)
        if (count_matches((const char *)src, src_len, g_shapes[i].probe) > 0) return 1;
    return 0;
}

static const char *settle_page(const np_ui_shape_t *shape, const char *s, size_t len,
                               int *gate_on, size_t *live) {
    int page_in = 0, page_missing = 0;
    for (size_t g = 0; g < shape->count; g++)
        if (shape->gates[g].optional == NP_GATE_PAGE) {
            if (gate_on[g]) page_in = 1;
            else page_missing = 1;
        }
    const char *why = !page_in ? NULL
                    : page_missing ? "one of its gates did not match"
                    : !find_barrel(s, len, NULL) ? "Steam's component barrel lacks a name it takes"
                    : NULL;
    for (size_t g = 0; why && g < shape->count; g++)
        if (shape->gates[g].optional == NP_GATE_PAGE && gate_on[g]) {
            gate_on[g] = 0;
            if (live) (*live)--;
        }
    return why;
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
        const char *page_out = settle_page(shape, s, src_len, gate_on, &gate_live);
        if (page_out)
            NP_ERR("webpatch: [%s] Default Compatibility Settings left out, %s", shape->name, page_out);
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
