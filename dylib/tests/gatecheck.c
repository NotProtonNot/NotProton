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

static const char *g_platform_js;

char *np_nativeplatform_javascript(void) {
    return g_platform_js ? strdup(g_platform_js) : NULL;
}

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
            && strstr(out, "selectedOption:t||\"notproton-fex\"")
            && strstr(out, "globalThis.MSCXDefaultTool=t||\"notproton-fex\"");
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

static void check_fex_tools(void) {
    np_webpatch_set_fex_tools((const char *[]){ "notproton-fex", "bad name", NULL, "",
                                                "x\"y", "notproton-fex-41069" }, 6);
    if (strcmp(marker_text(NP_FEX_TOOLS[0]), "[\"notproton-fex\",\"notproton-fex-41069\"]") != 0)
        wrong("the FEX tool array is %s", marker_text(NP_FEX_TOOLS[0]));

    np_webpatch_set_fex_tools(NULL, 0);
    if (strcmp(marker_text(NP_FEX_TOOLS[0]), "[]") != 0) wrong("no FEX tools gives %s", marker_text(NP_FEX_TOOLS[0]));

    char names[NP_WEBPATCH_FEX_TOOLS_MAX + 1][NP_TOOL_NAME_MAX];
    const char *list[NP_WEBPATCH_FEX_TOOLS_MAX + 1];
    for (int i = 0; i <= NP_WEBPATCH_FEX_TOOLS_MAX; i++) {
        memset(names[i], 'a', NP_TOOL_NAME_MAX - 1);
        names[i][NP_TOOL_NAME_MAX - 1] = '\0';
        names[i][0] = (char)('A' + i);
        list[i] = names[i];
    }
    np_webpatch_set_fex_tools(list, NP_WEBPATCH_FEX_TOOLS_MAX + 1);
    size_t want = 2 + NP_WEBPATCH_FEX_TOOLS_MAX * (NP_TOOL_NAME_MAX + 2) - 1;
    if (strlen(marker_text(NP_FEX_TOOLS[0])) != want || strchr(marker_text(NP_FEX_TOOLS[0]), 'A' + NP_WEBPATCH_FEX_TOOLS_MAX))
        wrong("the longest FEX tool array is %zu bytes, not %zu", strlen(marker_text(NP_FEX_TOOLS[0])), want);
    np_webpatch_set_fex_tools(NULL, 0);
}

static void *fresh_defaults(void *arg) {
    *(int *)arg = strcmp(marker_text(NP_DEFAULTS[0]), NP_UNREAD_DEFAULTS) == 0
               && strcmp(marker_text(NP_BUILDS[0]), "[]") == 0;
    return NULL;
}

static void check_defaults(void) {
    int fresh = 0;
    pthread_t other;
    np_webpatch_set_defaults("WINEMSYNC=1", "");
    if (pthread_create(&other, NULL, fresh_defaults, &fresh) != 0 || pthread_join(other, NULL) != 0)
        wrong("the fresh thread did not run");
    else if (!fresh)
        wrong("a thread that set nothing sees another thread's defaults, or reads them as empty");
    np_webpatch_set_defaults("WINEMSYNC=1\nDXMT_CONFIG=d3d11.metalSpatialUpscaleFactor=1.5\n", "MTL_HUD_ENABLED=0");
    if (strcmp(marker_text(NP_DEFAULTS[0]), "{rosetta:{\"WINEMSYNC\":\"1\","
                           "\"DXMT_CONFIG\":\"d3d11.metalSpatialUpscaleFactor=1.5\"},"
                           "fex:{\"MTL_HUD_ENABLED\":\"0\"}}") != 0)
        wrong("the defaults are %s", marker_text(NP_DEFAULTS[0]));
    np_webpatch_set_defaults("FOO=\"});alert(1);({\nwinemsync=1\nWINEMSYNC=1\nNOEQUALS\n=1", "");
    if (strcmp(marker_text(NP_DEFAULTS[0]), "{rosetta:{\"WINEMSYNC\":\"1\"},fex:{}}") != 0)
        wrong("lines the page cannot take give %s", marker_text(NP_DEFAULTS[0]));
    np_webpatch_set_defaults("", "");
    if (strcmp(marker_text(NP_DEFAULTS[0]), "{rosetta:{},fex:{}}") != 0) wrong("no defaults gives %s", marker_text(NP_DEFAULTS[0]));
    np_webpatch_set_defaults("WINEMSYNC=1", NULL);
    if (strcmp(marker_text(NP_DEFAULTS[0]), "{rosetta:{\"WINEMSYNC\":\"1\"},fex:null}") != 0)
        wrong("a set that could not be read gives %s", marker_text(NP_DEFAULTS[0]));
    static char big[3 * 2000 + 1];
    for (int i = 0; i < 2000; i++) memcpy(big + 3 * i, "A=\n", 3);
    np_webpatch_set_defaults(big, big);
    const char *dj = marker_text(NP_DEFAULTS[0]);
    if (strncmp(dj, "{rosetta:{\"A\":\"\",", 17) != 0 || strcmp(dj + strlen(dj) - 8, "\"A\":\"\"}}") != 0)
        wrong("the most the defaults can grow does not fit: %.40s", dj);
    np_webpatch_set_defaults("", "");

    const np_webpatch_build_t builds[] = {
        { "notproton-26.1-fex", "26.1", "CrossOver 26.1 (FEX)", 1, "WINEMSYNC=0\nBAD\"=1" },
        { "notproton-26.1", "26.1", "CrossOver 26.1 (Preview)", 0, NULL },
        { "notproton-25.0", "25.0", "CrossOver 25", 0, "" },
        { "notproton-evil", "26.2", "Evil\"});alert(1);({", 0, NULL },
        { "notproton-slash", "26.2", "Back\\slash", 0, NULL },
        { "notproton-nl", "26.2", "Line\nbreak", 0, NULL },
        { "notproton-path", "../x", "Path", 0, NULL },
        { "bad name", "26.2", "Name", 0, NULL },
        { NULL, "26.2", "No name", 0, NULL },
        { "notproton-nolabel", "26.2", "", 0, NULL },
    };
    int saved = np_log_level;
    np_log_level = -1;
    np_webpatch_set_builds(builds, sizeof builds / sizeof builds[0]);
    const char *want =
        "[{id:\"notproton-26.1-fex\",build:\"26.1\",runner:\"fex\",label:\"CrossOver 26.1 (FEX)\","
        "override:{\"WINEMSYNC\":\"0\"}},"
        "{id:\"notproton-26.1\",build:\"26.1\",runner:\"rosetta\",label:\"CrossOver 26.1 (Preview)\",override:null},"
        "{id:\"notproton-25.0\",build:\"25.0\",runner:\"rosetta\",label:\"CrossOver 25\",override:{}}]";
    if (strcmp(marker_text(NP_BUILDS[0]), want) != 0)
        wrong("the builds are %s", marker_text(NP_BUILDS[0]));

    np_webpatch_set_builds(builds + 3, 7);
    if (strcmp(marker_text(NP_BUILDS[0]), "[]") != 0) wrong("only refused builds give %s", marker_text(NP_BUILDS[0]));
    np_webpatch_set_builds(NULL, 4);
    if (strcmp(marker_text(NP_BUILDS[0]), "[]") != 0) wrong("no builds give %s", marker_text(NP_BUILDS[0]));

    enum { MOST = NP_WEBPATCH_BUILDS_MAX };
    static char ids[MOST][64], tools[MOST][NP_TOOL_NAME_MAX], labels[MOST][96];
    const char *full = "CX_GRAPHICS_BACKEND=d3dmetal\nMTL_HUD_ENABLED=1\nD3DM_ENABLE_METALFX=1\n"
        "DXMT_ENABLE_NVEXT=1\nROSETTA_ADVERTISE_AVX=1\nWINEMSYNC=1\nNOTPROTON_RETINA=1\n"
        "DXMT_METALFX_SPATIAL_SWAPCHAIN=1\nDXMT_CONFIG=d3d11.metalSpatialUpscaleFactor=1.72\n"
        "NOTPROTON_RAW_CONTROLLERS=1\nNOTPROTON_DISABLE_HIDRAW=1\n";
    np_webpatch_build_t most[MOST];
    for (int i = 0; i < MOST; i++) {
        snprintf(ids[i], sizeof ids[i], "%02d%061d", i, 0);
        memset(tools[i], 't', sizeof tools[i] - 1);
        tools[i][sizeof tools[i] - 1] = '\0';
        tools[i][0] = (char)('0' + i / 10);
        tools[i][1] = (char)('0' + i % 10);
        memset(labels[i], 'L', sizeof labels[i] - 1);
        labels[i][sizeof labels[i] - 1] = '\0';
        most[i] = (np_webpatch_build_t){ tools[i], ids[i], labels[i], 0, full };
    }
    np_webpatch_set_builds(most, MOST);
    const char *js = marker_text(NP_BUILDS[0]);
    if (strcmp(js, "[]") == 0 || !strstr(js, "\"NOTPROTON_DISABLE_HIDRAW\":\"1\"}}]"))
        wrong("every tool with the longest names and a full set does not fit the page");
    np_webpatch_set_builds(NULL, 0);
    np_log_level = saved;
}

static void check_barrel(void) {
    static const struct { const char *src; int want; } cases[] = {
        { "e.d(t,{XY:()=>a,m:()=>b,Yh:()=>c,$n:()=>d,Vb:()=>f,D0:()=>g})",            1 },
        { "e.d(t,{Vb:()=>f,D0:()=>g,XY:()=>a,m:()=>b,Yh:()=>c,$n:()=>d,zz:()=>h})",   1 },
        { "e.d(t,{XY:()=>a,m:()=>b,Yh:()=>c,$n:()=>d,Vb:()=>f})",                     0 },
        { "e.d(t,{XY:()=>a,m:()=>b,Yh:()=>c,$n:()=>d,Vb:()=>f,xD0:()=>g})",           0 },
        { "e.d(t,{XY:()=>a,m:()=>b,Yh:()=>c}),e.d(u,{$n:()=>d,Vb:()=>f,D0:()=>g})",   0 },
        { "e.d(t,{Vb:()=>f})e.d(u,{XY:()=>a,m:()=>b,Yh:()=>c,$n:()=>d,Vb:()=>f,D0:()=>g})", 1 },
        { "Vb:()=>f,D0:()=>g,XY:()=>a,m:()=>b,Yh:()=>c,$n:()=>d}",                    0 },
    };
    for (size_t i = 0; i < sizeof cases / sizeof cases[0]; i++)
        if ((find_barrel(cases[i].src, strlen(cases[i].src), NULL) != NULL) != cases[i].want)
            wrong("barrel case %zu reads as %d", i, !cases[i].want);
    const char *src = cases[5].src;
    size_t span = 0;
    const char *at = find_barrel(src, strlen(src), &span);
    if (at != strrchr(src, '{') || at + span != strrchr(src, '}') + 1)
        wrong("the barrel span is %zu bytes at %td", span, at ? at - src : -1);
}

static void check_captures(void) {
    int seen = 0;
    for (int c = 1; c < 256; c++) {
        int ci = cap_index((unsigned char)c);
        if (ci < 0) continue;
        seen |= 1 << ci;
        if (ci >= NP_CAP_MAX || c == ' ' || (c >= '\t' && c <= '\r') || marker_text((char)c))
            wrong("byte %d reads as capture %d", c, ci + 1);
    }
    if (seen != (1 << NP_CAP_MAX) - 1) wrong("captures bound by byte: %#x", seen);

    static const struct { const char *src, *find; size_t want; } cases[] = {
        { "(0,T.CI)()",  "(0," NP_C1 ".CI)()", 10 },
        { "(0,9T.CI)()", "(0," NP_C1 ".CI)()", 0 },
        { "(0,.CI)()",   "(0," NP_C1 ".CI)()", 0 },
        { "ab.CI",       NP_C1 ".CI",           5 },
        { "a.b(a)",      NP_C1 ".b(" NP_C1 ")", 6 },
        { "a.b(c)",      NP_C1 ".b(" NP_C1 ")", 0 },
    };
    np_cap_t caps[NP_CAP_MAX];
    for (size_t i = 0; i < sizeof(cases) / sizeof(cases[0]); i++) {
        const char *s = cases[i].src;
        size_t got = match_at(s, strlen(s), 0, cases[i].find, caps);
        if (got != cases[i].want) wrong("capture case %zu matched %zu bytes, wanted %zu",
                                        i, got, cases[i].want);
    }
    if (match_at("xab.CI", 6, 1, NP_C1 ".CI", caps))
        wrong("a capture matched from the middle of a name");
    if (match_at("x.ab.CI", 7, 2, NP_C1 ".CI", caps) || match_at("x?.ab.CI", 8, 3, NP_C1 ".CI", caps))
        wrong("a capture matched a member");
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
        size_t required = 0;
        for (size_t i = 0; i < S->count; i++) {
            check_gate(nm, i, &S->gates[i], S->gates, S->count);
            required += !S->gates[i].optional;
        }
        if (!required) wrong("[%s] has no required gate", nm);
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

    for (size_t g = 0; g < NP_LIBRARY_FILTER_COUNT; g++) {
        check_gate("library", g, &g_library_filters[g], g_library_filters, NP_LIBRARY_FILTER_COUNT);
        for (size_t f = 0; f < NP_FIX_COUNT; f++)
            if (strstr(g_fixes[f].find, g_library_filters[g].find) ||
                strstr(g_library_filters[g].find, g_fixes[f].find))
                wrong("fix %zu and library anchor %zu share an anchor", f, g);
    }

    printf("%zu shapes, %zu gates, %zu fixes, %zu library anchors checked\n",
           NP_SHAPE_COUNT, total, NP_FIX_COUNT, NP_LIBRARY_FILTER_COUNT);
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

static void check_output(const char *out, size_t out_len, const int *applied) {
    const np_ui_shape_t *S = shape_of(out, out_len);
    if (!S) { wrong("the patched chunk no longer matches any known compat UI"); return; }
    for (size_t g = 0; g < S->count; g++) {
        if (!applied[g]) {
            if (count_matches(out, out_len, S->gates[g].replace))
                wrong("[%s] optional gate %zu was skipped but its replacement is in the patch",
                      S->name, g);
            continue;
        }
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
    size_t span = 0;
    const char *barrel = find_barrel((const char *)buf, len, &span);
    if (barrel) {
        fwrite(barrel, 1, span, o);
        fputs("\n", o);
    }
    fclose(o);
    free(buf);
    printf("extracted fixture to %s\n", out_path);
    return 0;
}

static const np_gate_t *library_anchor(size_t i) {
    return i < NP_LIBRARY_FILTER_COUNT ? &g_library_filters[i]
                                       : &g_fixes[NP_NATIVE_MAC_FILTER_FIX + i - NP_LIBRARY_FILTER_COUNT];
}
#define NP_LIBRARY_ANCHORS (NP_LIBRARY_FILTER_COUNT + 2)

static int extract_library(const char *chunk, const char *out_path) {
    size_t len = 0;
    uint8_t *buf = slurp(chunk, &len);
    if (!buf) { fprintf(stderr, "cannot read %s\n", chunk); return 1; }
    FILE *o = fopen(out_path, "wb");
    if (!o) { fprintf(stderr, "cannot write %s\n", out_path); free(buf); return 1; }

    const size_t pad = 160;
    np_cap_t caps[NP_CAP_MAX];
    size_t fixes = 0, toolbars = 0;
    for (size_t a = 0; a < NP_LIBRARY_ANCHORS; a++) {
        size_t hits = 0;
        for (size_t i = 0; i < len; ) {
            size_t used = match_at((const char *)buf, len, i, library_anchor(a)->find, caps);
            if (!used) { i++; continue; }
            size_t from = i > pad ? i - pad : 0;
            size_t to   = i + used + pad < len ? i + used + pad : len;
            fwrite(buf + from, 1, to - from, o);
            fputs("\n", o);
            hits++;
            i += used;
        }
        if (a >= NP_LIBRARY_FILTER_COUNT) { fixes += hits; continue; }
        if (a == NP_LIBRARY_TOOLBAR || a == NP_LOCALIZED_LIBRARY_TOOLBAR) { toolbars += hits; continue; }
        if (hits != (size_t)library_anchor(a)->expect) {
            fprintf(stderr, "library anchor %zu found %zu times in %s\n", a, hits, chunk);
            fclose(o); free(buf);
            return 1;
        }
    }
    fclose(o);
    free(buf);
    if (fixes != 1) { fprintf(stderr, "%zu filter fixes in %s\n", fixes, chunk); return 1; }
    if (toolbars != 1) { fprintf(stderr, "%zu library toolbars in %s\n", toolbars, chunk); return 1; }
    printf("extracted fixture to %s\n", out_path);
    return 0;
}

static void page_gates_out(const np_ui_shape_t *S, const char *why, const int *gates, const char *what) {
    if (!why) wrong("[%s] %s and the page was not left out", S->name, what);
    for (size_t g = 0; g < S->count; g++)
        if (S->gates[g].optional == NP_GATE_PAGE && gates[g])
            wrong("[%s] %s and page gate %zu stayed in", S->name, what, g);
}

static void check_optional_drift(const np_ui_shape_t *S, size_t g, const uint8_t *buf,
                                 size_t len, const int *applied) {
    char *copy = malloc(len + 1);
    if (!copy) { wrong("out of memory"); return; }
    memcpy(copy, buf, len + 1);
    np_cap_t caps[NP_CAP_MAX];
    for (size_t i = 0; i < len; ) {
        size_t used = match_at(copy, len, i, S->gates[g].find, caps);
        if (!used) { i++; continue; }
        copy[i + used - 1] = '\x01';
        i += used;
    }
    int without[NP_GATE_MAX];
    memcpy(without, applied, sizeof(without));
    without[g] = 0;
    const char *why = settle_page(S, copy, len, without, NULL);
    if (S->gates[g].optional == NP_GATE_PAGE) page_gates_out(S, why, without, "a page gate drifted");

    int saved = np_log_level;
    np_log_level = -1;
    size_t out_len = 0;
    char *out = np_webpatch_transform((const uint8_t *)copy, len, &out_len, NULL);
    np_log_level = saved;
    if (out) {
        check_output(out, out_len, without);
        free(out);
    } else {
        wrong("[%s] drift in optional gate %zu left the whole shape unpatched", S->name, g);
    }
    free(copy);
}

static void check_barrel_drift(const np_ui_shape_t *S, const uint8_t *buf, size_t len,
                               const int *applied) {
    size_t span = 0;
    const char *at = find_barrel((const char *)buf, len, &span);
    if (!at) return;
    char *copy = malloc(len + 1);
    if (!copy) { wrong("out of memory"); return; }
    memcpy(copy, buf, len + 1);
    static const char *const names[] = NP_CX_BARREL_NAMES;
    char export[16];
    snprintf(export, sizeof export, "%s:()=>", names[sizeof names / sizeof names[0] - 1]);
    const char *name = find_in(at, span, export);
    if (!name) { wrong("[%s] the barrel has no %s", S->name, export); free(copy); return; }
    copy[name - (const char *)buf] = '_';
    int without[NP_GATE_MAX];
    memcpy(without, applied, sizeof(without));
    page_gates_out(S, settle_page(S, copy, len, without, NULL), without, "the barrel lost a name");

    int saved = np_log_level;
    np_log_level = -1;
    size_t out_len = 0;
    char *out = np_webpatch_transform((const uint8_t *)copy, len, &out_len, NULL);
    np_log_level = saved;
    if (out) {
        check_output(out, out_len, without);
        free(out);
    } else {
        wrong("[%s] a missing barrel left the whole shape unpatched", S->name);
    }
    free(copy);
}

static const char g_test_lists[] =
    "window.__NOTPROTON_NATIVE_PLATFORM__={mac:new Set([1,4]),windows:new Set([2,4])};\n";

static char *library_transform(const char *src, size_t len, size_t *out_len) {
    int saved = np_log_level;
    np_log_level = -1;
    char *out = np_webpatch_transform((const uint8_t *)src, len, out_len, NULL);
    np_log_level = saved;
    return out;
}

static int write_file(const char *path, const char *buf, size_t len) {
    FILE *o = fopen(path, "wb");
    if (!o) return 0;
    int ok = fwrite(buf, 1, len, o) == len;
    return fclose(o) == 0 && ok;
}

static void check_library(const char *path, const char *out_path, int literal_version) {
    size_t len = 0;
    uint8_t *buf = slurp(path, &len);
    if (!buf) { wrong("cannot read %s", path); return; }

    if (literal_version) {
        const char *prefix = "this.m_filterSpec={nFormatVersion:";
        char *version = strstr((char *)buf, prefix);
        if (version) version += strlen(prefix);
        char *end = version ? strchr(version, ',') : NULL;
        if (!end || end == version) { wrong("no constructor version in %s", path); free(buf); return; }
        size_t tail = len - (size_t)(end - (char *)buf);
        memmove(version + 1, end, tail + 1);
        *version = '2';
        len = (size_t)(version - (char *)buf) + 1 + tail;
    }

    int present[NP_LIBRARY_FILTER_COUNT];
    for (size_t g = 0; g < NP_LIBRARY_FILTER_COUNT; g++)
        present[g] = count_matches((const char *)buf, len, g_library_filters[g].find) != 0;
    if (present[NP_LIBRARY_TOOLBAR] == present[NP_LOCALIZED_LIBRARY_TOOLBAR])
        wrong("%s needs exactly one library toolbar", path);

    g_platform_js = g_test_lists;
    size_t out_len = 0;
    char *out = library_transform((const char *)buf, len, &out_len);
    if (!out) {
        wrong("%s was not patched", path);
    } else {
        if (strncmp(out, g_test_lists, sizeof(g_test_lists) - 1) != 0)
            wrong("%s does not start with the platform lists", path);
        if (!strstr(out, "SelectCollectionsAppFilterOption(\"notprotonWindows\""))
            wrong("%s has no Windows button", path);
        for (size_t a = 0; a < NP_LIBRARY_ANCHORS; a++) {
            if (count_matches(out, out_len, library_anchor(a)->find))
                wrong("library anchor %zu survived in %s", a, path);
        }
        for (size_t g = 0; g < NP_LIBRARY_FILTER_COUNT; g++) {
            if (!present[g]) continue;
            if (count_matches(out, out_len, g_library_filters[g].replace) != (size_t)g_library_filters[g].expect)
                wrong("library replacement %zu is missing from %s", g, path);
        }
        size_t again_len = 0;
        char *again = library_transform(out, out_len, &again_len);
        if (again) { wrong("%s was patched a second time", path); free(again); }
        if (out_path && !write_file(out_path, out, out_len)) wrong("cannot write %s", out_path);
        free(out);
    }

    g_platform_js = NULL;
    out = library_transform((const char *)buf, len, &out_len);
    if (out && (strstr(out, "__NOTPROTON") || strstr(out, "notprotonWindows")))
        wrong("%s got the Apple filter without platform lists", path);
    free(out);

    g_platform_js = g_test_lists;
    if (np_webpatch_has_shape(buf, len)) wrong("%s reads as a compat UI", path);
    np_cap_t caps[NP_CAP_MAX];
    for (size_t g = 0; g < NP_LIBRARY_FILTER_COUNT; g++) {
        if (!present[g]) continue;
        char *copy = malloc(len + 1);
        if (!copy) { wrong("out of memory"); break; }
        memcpy(copy, buf, len + 1);
        for (size_t i = 0; i < len; ) {
            size_t used = match_at(copy, len, i, g_library_filters[g].find, caps);
            if (!used) { i++; continue; }
            copy[i + used - 1] = '\x01';
            i += used;
        }
        out = library_transform(copy, len, &out_len);
        if (!out || strstr(out, "npWindows") || strstr(out, "m_filterSpec.notprotonWindows") ||
            !strstr(out, ".mac.has("))
            wrong("drift in library anchor %zu of %s left a partial filter", g, path);
        free(out);
        free(copy);
    }
    g_platform_js = NULL;
    free(buf);
}

static void check_older_filter(const char *out_path) {
    static const char source[] =
        "function Y(e){return t=>{switch(t){case L.Pu:return!!(0,P.td)()||"
        "e.is_available_on_current_platform&&!e.is_invalid_os_type;}}}";
    g_platform_js = g_test_lists;
    size_t out_len = 0;
    char *out = library_transform(source, sizeof(source) - 1, &out_len);
    g_platform_js = NULL;
    if (!out || !strstr(out, "case L.Pu:return (0,P.Pr)()&&window.__NOTPROTON_NATIVE_PLATFORM__.mac.has(e.appid)"))
        wrong("the older filter was not patched");
    else if (out_path && !write_file(out_path, out, out_len))
        wrong("cannot write %s", out_path);
    free(out);
}

int main(int argc, char **argv) {
    if (argc == 4 && strcmp(argv[1], "--extract") == 0)
        return extract(argv[2], argv[3]);
    if (argc == 4 && strcmp(argv[1], "--extract-library") == 0)
        return extract_library(argv[2], argv[3]);
    if ((argc == 3 || argc == 4) &&
        (strcmp(argv[1], "--library") == 0 || strcmp(argv[1], "--library-literal") == 0)) {
        check_library(argv[2], argc == 4 ? argv[3] : NULL, strcmp(argv[1], "--library-literal") == 0);
        return g_wrong;
    }
    if ((argc == 2 || argc == 3) && strcmp(argv[1], "--older-filter") == 0) {
        check_older_filter(argc == 3 ? argv[2] : NULL);
        return g_wrong;
    }

    if (argc < 2) {
        selfcheck(); check_captures(); check_fallback(); check_fex_tools(); check_defaults(); check_barrel();
        return g_wrong;
    }

    np_webpatch_set_fallback_tool("notproton-fex");
    np_webpatch_set_fex_tools((const char *[]){ "notproton-fex", "notproton-fex-41069" }, 2);

    for (int i = 1; i < argc; i++) {
        size_t len = 0;
        uint8_t *buf = slurp(argv[i], &len);
        if (!buf) { wrong("cannot read %s", argv[i]); continue; }

        const np_ui_shape_t *S = shape_of((const char *)buf, len);
        if (!S != !np_webpatch_has_shape(buf, len)) wrong("%s reads as having a shape: %d", argv[i], !S);
        int applied[NP_GATE_MAX] = {0};
        for (size_t g = 0; S && g < S->count; g++)
            applied[g] = count_matches((const char *)buf, len, S->gates[g].find)
                         == (size_t)S->gates[g].expect;
        if (S) settle_page(S, (const char *)buf, len, applied, NULL);

        size_t out_len = 0;
        char *out = np_webpatch_transform(buf, len, &out_len, NULL);
        if (out) {
            check_output(out, out_len, applied);
            printf("APPLIED  %s\n", argv[i]);
            free(out);
            for (size_t g = 0; S && g < S->count; g++)
                if (S->gates[g].optional && applied[g])
                    check_optional_drift(S, g, buf, len, applied);
            if (S) check_barrel_drift(S, buf, len, applied);
        } else {
            printf("REJECTED %s\n", argv[i]);
        }
        free(buf);
    }
    return g_wrong;
}
