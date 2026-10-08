// The gate table is static, so the unit under test is included rather than
// linked.
#include "../feats/webpatch.c"

#include <stdarg.h>
#include <stdio.h>
#include <pthread.h>
#include <stdatomic.h>

// Satisfies the log macros without pulling in log.c, which reaches for the
// support directory this tool has no use for. Drift reasons land on stderr.
int   np_log_level = NP_LVL_INFO;
FILE *np_log_file;

static int g_wrong;

static void wrong(const char *fmt, ...) {
    va_list ap;
    va_start(ap, fmt);
    fputs("WRONG: ", stdout);
    vprintf(fmt, ap);
    fputc('\n', stdout);
    va_end(ap);
    g_wrong = 1;
}

static void *rewrite_fallback(void *arg) {
    atomic_int *stop = arg;
    while (!atomic_load(stop))
        np_webpatch_set_fallback_tool("notproton-fex");
    return NULL;
}

static void check_fallback(void) {
    static const char source[] =
        "return t?(0,i.jsx)(m.B,{feature:p.OK,label:(0,l.we)"
        "(\"#Settings_SteamPlay_DefaultTool\"),rgOptions:A,disabled:0==A.length,"
        "selectedOption:t,onChange:e=>g(e.data)}):null";
    np_webpatch_set_fallback_tool("notproton-fex");
    atomic_int stop = 0;
    pthread_t writer;
    if (pthread_create(&writer, NULL, rewrite_fallback, &stop) != 0) {
        wrong("the fallback writer thread did not start");
        return;
    }
    int saved = np_log_level;
    np_log_level = -1;
    for (int i = 0; i < 10000; i++) {
        size_t length = 0;
        char *out = np_webpatch_transform((const uint8_t *)source, sizeof(source) - 1,
                                         &length, NULL);
        int ok = out && !memchr(out, '\0', length)
            && strstr(out, "A.some(e=>e.data===\"notproton-fex\")")
            && strstr(out, "selectedOption:t||\"notproton-fex\"");
        free(out);
        if (!ok) {
            wrong("concurrent fallback writes changed a chunk's tool name");
            break;
        }
    }
    atomic_store(&stop, 1);
    pthread_join(writer, NULL);
    np_log_level = saved;
}

// Invariants the transform relies on but cannot check at run time. A replacement still
// holding its own anchor would be found again next pass, and an anchor inside another
// anchor would make the result depend on table order rather than on the chunk.
static void check_gate(const char *nm, size_t i, const np_gate_t *a,
                       const np_gate_t *group, size_t group_n) {
    if (!a->find || !*a->find)       wrong("[%s] gate %zu has no anchor", nm, i);
    if (!a->replace || !*a->replace) wrong("[%s] gate %zu has no replacement", nm, i);
    if (a->expect < 1)               wrong("[%s] gate %zu expects %d hits", nm, i, a->expect);
    if (a->find && a->replace && strcmp(a->find, a->replace) == 0)
        wrong("[%s] gate %zu replaces its anchor with itself", nm, i);
    if (a->find && a->replace && *a->find && strstr(a->replace, a->find))
        wrong("[%s] gate %zu replacement still contains its own anchor", nm, i);
    // A capture the replacement reads but the anchor never binds would
    // expand to nothing, so the transform would refuse at run time.
    for (const char *r = a->replace; r && *r; r++) {
        int ci = cap_index((unsigned char)*r);
        if (ci >= 0 && !strchr(a->find, *r))
            wrong("[%s] gate %zu replacement reads capture %d, anchor never binds it",
                  nm, i, ci + 1);
    }
    for (size_t j = 0; j < group_n; j++) {
        if (i == j || !a->find || !group[j].find || !*group[j].find) continue;
        if (strstr(a->find, group[j].find))
            wrong("[%s] gate %zu anchor contains gate %zu anchor", nm, i, j);
    }
}

static void check_paths(void) {
    static const struct { const char *path; int want; } cases[] = {
        { "/Steam.AppBundle/Steam/Contents/MacOS/steamui/sp.js",                   1 },
        { "/Steam.AppBundle/Steam/Contents/MacOS/steamui/chunk~2dcc5aaf7.js",      1 },
        { "/Steam.AppBundle/Steam/Contents/MacOS/steamui/1129.js",                 1 },
        { "/Steam.AppBundle/Steam/Contents/MacOS/steamui/library.js",              1 },
        { "steamui/sp.js",                                                         1 },
        { "/Steam.AppBundle/Steam/Contents/MacOS/steamui/app/sp.js",               1 },
        { "/Steam.AppBundle/Steam/Contents/MacOS/steamui/localization/en-json.js", 0 },
        { "/Steam.AppBundle/Steam/Contents/MacOS/steamui/libraries/lib~00299.js",  0 },
        { "/Steam.AppBundle/Steam/Contents/MacOS/steamui/sp.js.orig",              0 },
        { "/Steam.AppBundle/Steam/Contents/MacOS/steamui/css/library.css",         0 },
        { "/Steam.AppBundle/Steam/Contents/MacOS/notsteamui/sp.js",                0 },
        { "/Steam.AppBundle/Steam/Contents/MacOS/steamui",                         0 },
        { "sp.js",                                                                 0 },
    };
    size_t n = sizeof(cases) / sizeof(cases[0]);
    for (size_t i = 0; i < n; i++) {
        int got = np_webpatch_should_patch(cases[i].path);
        if (!got != !cases[i].want)
            wrong("should_patch(%s) answered %d, wanted %d",
                  cases[i].path, got, cases[i].want);
    }
    if (np_webpatch_should_patch(NULL))
        wrong("should_patch(NULL) answered yes");
    printf("%zu chunk paths checked\n", n + 1);
}

static void selfcheck(void) {
    size_t total = 0;
    for (size_t sh = 0; sh < NP_SHAPE_COUNT; sh++) {
        const np_ui_shape_t *S = &g_shapes[sh];
        const char *nm = S->name;
        if (!S->probe || !*S->probe) wrong("[%s] has no probe", nm);
        for (size_t o = 0; o < NP_SHAPE_COUNT; o++) {
            if (o == sh) continue;
            if (strcmp(S->probe, g_shapes[o].probe) == 0)
                wrong("[%s] and [%s] share a probe", nm, g_shapes[o].name);
        }
        for (size_t i = 0; i < S->count; i++)
            check_gate(nm, i, &S->gates[i], S->gates, S->count);
        total += S->count;
    }

    for (size_t f = 0; f < NP_FIX_COUNT; f++) {
        check_gate("fix", f, &g_fixes[f], g_fixes, NP_FIX_COUNT);
        for (size_t sh = 0; sh < NP_SHAPE_COUNT; sh++)
            for (size_t g = 0; g < g_shapes[sh].count; g++)
                if (strstr(g_fixes[f].find, g_shapes[sh].gates[g].find) ||
                    strstr(g_shapes[sh].gates[g].find, g_fixes[f].find))
                    wrong("fix %zu and [%s] gate %zu share an anchor",
                          f, g_shapes[sh].name, g);
    }

    printf("%zu shapes, %zu gates, %zu fixes checked\n",
           NP_SHAPE_COUNT, total, NP_FIX_COUNT);
    check_paths();
}

static uint8_t *slurp(const char *path, size_t *len) {
    FILE *f = fopen(path, "rb");
    if (!f) return NULL;
    fseek(f, 0, SEEK_END);
    long n = ftell(f);
    fseek(f, 0, SEEK_SET);
    if (n < 0) { fclose(f); return NULL; }
    uint8_t *buf = malloc((size_t)n + 1);
    if (!buf) { fclose(f); return NULL; }
    size_t got = fread(buf, 1, (size_t)n, f);
    fclose(f);
    buf[got] = 0;
    *len = got;
    return buf;
}

// A patched chunk has to carry every replacement, keep none of the anchors, and
// be refused if it is fed back in, which is what stops a second read of the same
// file from patching it twice.
static const np_ui_shape_t *shape_of(const char *buf, size_t len) {
    for (size_t i = 0; i < NP_SHAPE_COUNT; i++)
        if (count_matches(buf, len, g_shapes[i].probe) > 0) return &g_shapes[i];
    return NULL;
}

static void check_output(const char *out, size_t out_len) {
    const np_ui_shape_t *S = shape_of(out, out_len);
    if (!S) { wrong("the patched chunk no longer matches any known compat UI"); return; }
    for (size_t g = 0; g < S->count; g++) {
        if (count_matches(out, out_len, S->gates[g].find) != 0)
            wrong("[%s] gate %zu anchor survived the patch", S->name, g);
        if (count_matches(out, out_len, S->gates[g].replace)
            < (size_t)S->gates[g].expect)
            wrong("[%s] gate %zu replacement is missing from the patch", S->name, g);
    }
    for (size_t f = 0; f < NP_FIX_COUNT; f++) {
        size_t anchor = count_matches(out, out_len, g_fixes[f].find);
        size_t repl   = count_matches(out, out_len, g_fixes[f].replace);
        if (!anchor && !repl) continue;
        if (anchor)
            wrong("fix %zu anchor survived the patch", f);
        if (repl < (size_t)g_fixes[f].expect)
            wrong("fix %zu replacement is missing from the patch", f);
    }

    // This pass is meant to be refused, so its drift report is not a finding.
    size_t again_len = 0;
    int saved = np_log_level;
    np_log_level = -1;
    char *again = np_webpatch_transform((const uint8_t *)out, out_len, &again_len, NULL);
    np_log_level = saved;
    if (again) { wrong("a patched chunk was patched a second time"); free(again); }
}

// Cuts a window around every anchor occurrence in a real chunk and joins them
// into a fixture, so the committed bytes are Steam's rather than a restatement of
// the table above. Run by hand when the fixture is first made or refreshed.
static int extract(const char *chunk, const char *out_path) {
    size_t len = 0;
    uint8_t *buf = slurp(chunk, &len);
    if (!buf) { fprintf(stderr, "cannot read %s\n", chunk); return 1; }

    FILE *o = fopen(out_path, "wb");
    if (!o) { fprintf(stderr, "cannot write %s\n", out_path); free(buf); return 1; }

    const np_ui_shape_t *S = shape_of((const char *)buf, len);
    if (!S) {
        fprintf(stderr, "%s carries no known compat UI\n", chunk);
        fclose(o); free(buf);
        return 1;
    }
    // The probe goes in first so the fixture selects the same shape the chunk did.
    fprintf(o, "%s\n", S->probe);

    const size_t pad = 160;
    np_cap_t caps[NP_CAP_MAX];
    for (size_t g = 0; g < S->count; g++) {
        size_t hits = 0;
        for (size_t i = 0; i < len; ) {
            size_t used = match_at((const char *)buf, len, i, S->gates[g].find, caps);
            if (!used) { i++; continue; }
            size_t from = i > pad ? i - pad : 0;
            size_t to   = i + used + pad < len ? i + used + pad : len;
            fwrite(buf + from, 1, to - from, o);
            fputs("\n", o);
            hits++;
            i += used;
        }
        if (hits != (size_t)S->gates[g].expect) {
            fprintf(stderr, "[%s] gate %zu found %zu times in %s, table expects %d\n",
                    S->name, g, hits, chunk, S->gates[g].expect);
            fclose(o); free(buf);
            return 1;
        }
    }
    fclose(o);
    free(buf);
    printf("extracted fixture to %s\n", out_path);
    return 0;
}

int main(int argc, char **argv) {
    if (argc == 4 && strcmp(argv[1], "--write") == 0) {
        size_t len = 0, out_len = 0;
        uint8_t *buf = slurp(argv[2], &len);
        if (!buf) return 1;
        char *out = np_webpatch_transform(buf, len, &out_len, NULL);
        free(buf);
        if (!out) return 1;
        check_output(out, out_len);
        FILE *file = fopen(argv[3], "wb");
        if (!file) { free(out); return 1; }
        int failed = fwrite(out, 1, out_len, file) != out_len;
        failed |= fclose(file) != 0;
        free(out);
        return failed || g_wrong;
    }

    if (argc == 4 && strcmp(argv[1], "--extract") == 0)
        return extract(argv[2], argv[3]);

    if (argc < 2) { selfcheck(); check_fallback(); return g_wrong; }

    np_webpatch_set_fallback_tool("notproton-fex");

    for (int i = 1; i < argc; i++) {
        size_t len = 0;
        uint8_t *buf = slurp(argv[i], &len);
        if (!buf) { wrong("cannot read %s", argv[i]); continue; }

        size_t out_len = 0;
        char *out = np_webpatch_transform(buf, len, &out_len, NULL);
        if (out) {
            check_output(out, out_len);
            printf("APPLIED  %s\n", argv[i]);
            free(out);
        } else {
            printf("REJECTED %s\n", argv[i]);
        }
        free(buf);
    }
    return g_wrong;
}
