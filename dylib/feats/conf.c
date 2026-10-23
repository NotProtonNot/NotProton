#include "conf.h"

#include <dirent.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

typedef struct {
    const char   *name;
    unsigned char most;      // how many times it may be given
    unsigned char required;
} np_conf_spec_t;

// Cardinality lives here and nowhere else, so the tables are the schema.
static const np_conf_spec_t kPlugin[] = {
    { "label", 1, 1 },     { "description", 1, 0 }, { "description_on", 16, 0 },
    { "section", 1, 0 },   { "on", 1, 0 },          { "off", 1, 0 },
    { "depends", 1, 0 },   { "requires", 4, 0 },    { "inject", 1, 0 },
    { "env", 16, 0 },      { "overrides", 1, 0 },   { "stage", 1, 0 },
    { "type", 1, 0 },      { "choice", 16, 0 },     { "min", 1, 0 },
    { "max", 1, 0 },       { "step", 1, 0 },        { "default", 1, 0 },
    { "suffix", 1, 0 },    { NULL, 0, 0 }
};

// label and variant fall back to the record's id, so a variant that is the only one in
// its group says its name once.
static const np_conf_spec_t kVariant[] = {
    { "label", 1, 0 }, { "variant", 1, 0 }, { "src", 1, 1 }, { "dst", 1, 1 },
    { NULL, 0, 0 }
};

static int conf_space(char c) { return c == ' ' || (c >= '\t' && c <= '\r'); }

static void conf_trim(char *v) {
    size_t n = strlen(v);
    while (n && conf_space(v[n - 1])) v[--n] = 0;
}

static const np_conf_spec_t *conf_spec(np_conf_kind kind, const char *name) {
    const np_conf_spec_t *s = kind == NP_CONF_PLUGIN ? kPlugin : kVariant;
    for (; s->name; s++)
        if (strcmp(s->name, name) == 0) return s;
    return NULL;
}

int np_conf_next(const np_conf_rec_t *rec, int *iter, const char **name, const char **value) {
    const char *p = rec->kv;
    if (*iter >= rec->nkv) return 0;
    for (int i = 0; i < *iter; i++) {
        p += strlen(p) + 1;
        p += strlen(p) + 1;
    }
    *name = p;
    *value = p + strlen(p) + 1;
    (*iter)++;
    return 1;
}

const char *np_conf_get(const np_conf_rec_t *rec, const char *name) {
    const char *n, *v;
    int it = 0;
    while (np_conf_next(rec, &it, &n, &v))
        if (strcmp(n, name) == 0) return v;
    return NULL;
}

int np_conf_count(const np_conf_rec_t *rec, const char *name) {
    const char *n, *v;
    int it = 0, count = 0;
    while (np_conf_next(rec, &it, &n, &v))
        if (strcmp(n, name) == 0) count++;
    return count;
}

static int conf_id_ok(np_conf_kind kind, const char *id) {
    if (kind == NP_CONF_PLUGIN) {
        if (strncmp(id, "NOTPROTON_", 10) != 0 || !id[10]) return 0;
        for (const char *p = id + 10; *p; p++)
            if (!((*p >= 'A' && *p <= 'Z') || (*p >= '0' && *p <= '9') || *p == '_')) return 0;
        return 1;
    }
    if (strlen(id) > 64 || !*id) return 0;
    if (!((id[0] >= 'A' && id[0] <= 'Z') || (id[0] >= 'a' && id[0] <= 'z') ||
          (id[0] >= '0' && id[0] <= '9'))) return 0;
    for (const char *p = id; *p; p++)
        if (!((*p >= 'A' && *p <= 'Z') || (*p >= 'a' && *p <= 'z') ||
              (*p >= '0' && *p <= '9') || *p == '.' || *p == '_' || *p == '-')) return 0;
    return 1;
}

// Deliberately narrower than strtod, which also takes hex, inf and nan: this is the
// same grammar the awk in compat_run.sh matches.
static int conf_num(const char *v) {
    int digits = 0;
    if (*v == '+' || *v == '-') v++;
    while (*v >= '0' && *v <= '9') { v++; digits++; }
    if (*v == '.') {
        v++;
        while (*v >= '0' && *v <= '9') { v++; digits++; }
    }
    if (!digits) return 0;
    if (*v == 'e' || *v == 'E') {
        v++;
        if (*v == '+' || *v == '-') v++;
        if (!(*v >= '0' && *v <= '9')) return 0;
        while (*v >= '0' && *v <= '9') v++;
    }
    return !*v;
}

static double conf_dbl(const char *v) { return strtod(v, NULL); }

// A choice is "<value> = <label>"; the value is what has to be matched.
static int conf_choice_has(const np_conf_rec_t *rec, const char *want) {
    const char *n, *v;
    int it = 0;
    size_t len = strlen(want);
    while (np_conf_next(rec, &it, &n, &v)) {
        const char *eq;
        size_t vlen;
        if (strcmp(n, "choice") != 0) continue;
        eq = strchr(v, '=');
        vlen = eq ? (size_t)(eq - v) : strlen(v);
        while (vlen && conf_space(v[vlen - 1])) vlen--;
        if (vlen == len && strncmp(v, want, len) == 0) return 1;
    }
    return 0;
}

static int conf_env_ok(const char *v) {
    const char *eq = strchr(v, '=');
    if (!eq || eq == v) return 0;
    if (!((*v >= 'A' && *v <= 'Z') || *v == '_')) return 0;
    for (const char *p = v; p < eq; p++)
        if (!((*p >= 'A' && *p <= 'Z') || (*p >= '0' && *p <= '9') || *p == '_')) return 0;
    return 1;
}

// What a record needs beyond the grammar: the fields the tables mark required, and the
// rules a value has to keep. Returns a code, with *detail set when it names a field.
static const char *conf_schema(const np_conf_rec_t *rec, np_conf_kind kind,
                               const char **detail) {
    const np_conf_spec_t *s = kind == NP_CONF_PLUGIN ? kPlugin : kVariant;
    const char *type, *mn, *mx, *step, *dflt, *n, *v;
    int it = 0, values;

    for (; s->name; s++)
        if (s->required && !np_conf_get(rec, s->name)) {
            *detail = s->name;
            return NP_CONF_REQUIRED;
        }

    if (kind == NP_CONF_VARIANT) {
        const char *dst = np_conf_get(rec, "dst");
        if (dst[0] == '/' || strstr(dst, "..")) {
            *detail = "dst";
            return NP_CONF_BAD_VALUE;
        }
        return NULL;
    }

    while (np_conf_next(rec, &it, &n, &v))
        if (strcmp(n, "env") == 0 && !conf_env_ok(v)) {
            *detail = "env";
            return NP_CONF_BAD_VALUE;
        }
    v = np_conf_get(rec, "section");
    if (v && strcmp(v, "dev") != 0) {
        *detail = "section";
        return NP_CONF_BAD_VALUE;
    }

    type = np_conf_get(rec, "type");
    if (!type) return NULL;
    values = np_conf_count(rec, "choice");
    mn = np_conf_get(rec, "min");
    mx = np_conf_get(rec, "max");
    step = np_conf_get(rec, "step");
    dflt = np_conf_get(rec, "default");

    if (strcmp(type, "choice") == 0) {
        if (!values) {
            *detail = "choice";
            return NP_CONF_REQUIRED;
        }
        return NULL;
    }
    if (strcmp(type, "slider") != 0) {
        *detail = type;
        return NP_CONF_BAD_TYPE;
    }
    // A slider is a range or a ladder, never both, never neither, never one notch.
    if ((values && (mn || mx)) || (!values && !(mn && mx)) || values == 1)
        return NP_CONF_SLIDER_SHAPE;
    if (values) {
        if (dflt && !conf_choice_has(rec, dflt)) return NP_CONF_BAD_DEFAULT;
        return NULL;
    }
    if (!conf_num(mn)) { *detail = "min"; return NP_CONF_BAD_VALUE; }
    if (!conf_num(mx) || conf_dbl(mx) <= conf_dbl(mn)) { *detail = "max"; return NP_CONF_BAD_VALUE; }
    if (step && !conf_num(step)) { *detail = "step"; return NP_CONF_BAD_VALUE; }
    if (dflt && !conf_num(dflt)) return NP_CONF_BAD_DEFAULT;
    return NULL;
}

static void conf_emit(np_conf_rec_t *rec, np_conf_kind kind, const char *code,
                      const char *detail, const np_conf_sink_t *sink, void *ctx) {
    if (!*rec->id) return;
    if (!code) code = conf_schema(rec, kind, &detail);
    if (!code && sink->record) code = sink->record(rec, ctx, &detail);
    if (code && sink->refused) sink->refused(rec->id, code, detail, ctx);
    rec->id[0] = 0;
    rec->nkv = rec->kvlen = 0;
}

void np_conf_read_file(const char *path, const char *shown, np_conf_kind kind,
                       const np_conf_sink_t *sink, void *ctx) {
    char line[NP_CONF_LINE + 2];
    char unknown[64];
    np_conf_rec_t rec;
    const char *code = NULL, *detail = NULL;
    int seen_header = 0;
    FILE *fp;

    if (sink->file) sink->file(shown, ctx);
    if (!(fp = fopen(path, "r"))) {
        if (sink->refused) sink->refused(shown, NP_CONF_UNREADABLE, NULL, ctx);
        return;
    }
    memset(&rec, 0, sizeof(rec));
    while (fgets(line, sizeof(line), fp)) {
        char *eq, *v, *k = line;
        const np_conf_spec_t *spec;
        size_t len = strcspn(line, "\n");

        if (len >= NP_CONF_LINE) {
            rec.id[0] = 0;
            if (sink->refused) sink->refused(shown, NP_CONF_LINE_LONG, NULL, ctx);
            fclose(fp);
            return;
        }
        line[len] = 0;
        while (conf_space(*k)) k++;
        if (!*k || *k == '#') continue;

        if (*k == '[') {
            char *close = strrchr(k, ']');
            if (!close) {
                // Not a header at all, so it is a field line with no "=".
                continue;
            }
            *close = 0;
            conf_emit(&rec, kind, code, detail, sink, ctx);
            code = NULL;
            detail = NULL;
            k++;
            while (conf_space(*k)) k++;
            conf_trim(k);
            seen_header = 1;
            if (snprintf(rec.id, sizeof(rec.id), "%s", k) >= (int)sizeof(rec.id) ||
                !conf_id_ok(kind, rec.id)) {
                code = NP_CONF_BAD_ID;
            }
            continue;
        }
        if (!(eq = strchr(k, '='))) continue;
        if (!seen_header) {
            if (sink->refused) sink->refused(shown, NP_CONF_NO_HEADER, NULL, ctx);
            fclose(fp);
            return;
        }
        if (code) continue;   // this record is already refused; skip to the next header
        *eq = 0;
        v = eq + 1;
        conf_trim(k);
        while (conf_space(*v)) v++;
        conf_trim(v);
        if (!(spec = conf_spec(kind, k))) {
            // k points into line, which the next read overwrites.
            snprintf(unknown, sizeof(unknown), "%s", k);
            code = NP_CONF_UNKNOWN;
            detail = unknown;
            continue;
        }
        if (!*v) { code = NP_CONF_EMPTY; detail = spec->name; continue; }
        if (strchr(v, '\t')) { code = NP_CONF_TAB; detail = spec->name; continue; }
        if (np_conf_count(&rec, spec->name) >= spec->most) {
            code = spec->most == 1 ? NP_CONF_DUP_FIELD : NP_CONF_LIMIT;
            detail = spec->name;
            continue;
        }
        if (rec.kvlen + (int)strlen(spec->name) + (int)strlen(v) + 2 > (int)sizeof(rec.kv)) {
            code = NP_CONF_LIMIT;
            detail = spec->name;
            continue;
        }
        memcpy(rec.kv + rec.kvlen, spec->name, strlen(spec->name) + 1);
        rec.kvlen += (int)strlen(spec->name) + 1;
        memcpy(rec.kv + rec.kvlen, v, strlen(v) + 1);
        rec.kvlen += (int)strlen(v) + 1;
        rec.nkv++;
    }
    conf_emit(&rec, kind, code, detail, sink, ctx);
    fclose(fp);
}

static int conf_cmp(const void *a, const void *b) {
    return strcmp(*(const char *const *)a, *(const char *const *)b);
}

static int conf_has_suffix(const char *s, const char *suf) {
    size_t n = strlen(s), m = strlen(suf);
    return n >= m && strcmp(s + n - m, suf) == 0;
}

void np_conf_read_dir(const char *dir, const char *shown_dir, np_conf_kind kind,
                      const np_conf_sink_t *sink, void *ctx) {
    char **names = NULL;
    int count = 0;
    struct dirent *de;
    DIR *d = opendir(dir);

    if (!d) return;
    while ((de = readdir(d))) {
        char **grown;
        if (de->d_name[0] == '.' || !conf_has_suffix(de->d_name, ".conf")) continue;
        // A tab or a newline in the name would break the normalised lines.
        if (strchr(de->d_name, '\t') || strchr(de->d_name, '\n')) continue;
        if (!(grown = realloc(names, (size_t)(count + 1) * sizeof(*names)))) break;
        names = grown;
        if (!(names[count] = strdup(de->d_name))) break;
        count++;
    }
    closedir(d);
    if (names) qsort(names, (size_t)count, sizeof(*names), conf_cmp);
    for (int i = 0; i < count; i++) {
        char path[2048], shown[2048];
        snprintf(path, sizeof(path), "%s/%s", dir, names[i]);
        snprintf(shown, sizeof(shown), "%s%s%s", shown_dir ? shown_dir : "",
                 shown_dir && *shown_dir ? "/" : "", names[i]);
        np_conf_read_file(path, shown, kind, sink, ctx);
        free(names[i]);
    }
    free(names);
}
