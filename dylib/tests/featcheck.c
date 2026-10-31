#include "../feats/webpatch.c"

#include <stdarg.h>
#include <stdio.h>
#include <unistd.h>

int   np_log_level = NP_LVL_WARN;
FILE *np_log_file;

char *np_nativeplatform_javascript(void) {
    return NULL;
}

static int g_failed;
static char g_home[1024];
static char g_featdir[1200];
static char g_vardir[1200];

static void ok(int cond, const char *what) {
    printf("  %s  %s\n", cond ? "ok  " : "FAIL", what);
    if (!cond) g_failed++;
}

static void shout(const char *fmt, ...) {
    va_list ap;
    va_start(ap, fmt);
    vprintf(fmt, ap);
    va_end(ap);
    putchar('\n');
}

static void write_desc(const char *name, const char *body) {
    char path[2048];
    FILE *f;
    snprintf(path, sizeof(path), "%s/%s", g_featdir, name);
    if (!(f = fopen(path, "w"))) { shout("cannot write %s", path); g_failed++; return; }
    fputs(body, f);
    fclose(f);
}

static void write_var(const char *name, const char *body) {
    char path[2048];
    FILE *f;
    snprintf(path, sizeof(path), "%s/%s", g_vardir, name);
    if (!(f = fopen(path, "w"))) { shout("cannot write %s", path); g_failed++; return; }
    fputs(body, f);
    fclose(f);
}

// Variants are offered per compat tool, and a tool is only a build whose runner is on
// disk, so a check has to build both sides of that.
static void make_dir(const char *fmt, const char *a, const char *b) {
    char cmd[4096];
    snprintf(cmd, sizeof(cmd), fmt, a, b);
    if (system(cmd) != 0) { shout("cannot run %s", cmd); g_failed++; }
}

static const char *vars_json(void) {
    g_var_done = 0;
    var_build();
    return input_text(IN_VARS);
}

static void clear_vars(void) {
    char cmd[2600];
    snprintf(cmd, sizeof(cmd), "rm -f '%s'/*.conf", g_vardir);
    if (system(cmd) != 0) { shout("cannot clear %s", g_vardir); g_failed++; }
}

static void clear_descs(void) {
    char cmd[2600];
    snprintf(cmd, sizeof(cmd), "rm -f '%s'/*.conf", g_featdir);
    if (system(cmd) != 0) { shout("cannot clear %s", g_featdir); g_failed++; }
}

static void make_asset(const char *rel) {
    char path[2048], cmd[2200];
    FILE *f;
    snprintf(path, sizeof(path), "%s/%s", g_home, rel);
    snprintf(cmd, sizeof(cmd), "mkdir -p \"$(dirname '%s')\"", path);
    if (system(cmd) != 0) { shout("cannot make dirs for %s", path); g_failed++; return; }
    if (!(f = fopen(path, "w"))) { shout("cannot write %s", path); g_failed++; return; }
    fclose(f);
}

static void rebuild(void) {
    g_feat_ready_done = 0;
    feat_build();
}

static const char *ready_json(void) { rebuild(); return input_text(IN_READY); }
static const char *feats_json(void) { rebuild(); return input_text(IN_FEATS); }

int main(void) {
    char tmpl[] = "/tmp/np-featcheck.XXXXXX";
    char cmd[2600];
    char *dir = mkdtemp(tmpl);

    if (!dir) { fputs("cannot make a temp directory\n", stderr); return 2; }
    snprintf(g_home, sizeof(g_home), "%s", dir);
    snprintf(g_featdir, sizeof(g_featdir),
             "%s/" NP_FEAT_DIR, g_home);
    np_support_path(g_vardir, sizeof(g_vardir), g_home, "variants");
    snprintf(cmd, sizeof(cmd), "mkdir -p '%s' '%s'", g_featdir, g_vardir);
    if (system(cmd) != 0) {
        fputs("cannot make the plugins and variants folders\n", stderr);
        return 2;
    }
    setenv("HOME", g_home, 1);

    puts("== an empty plugins folder");
    ok(strcmp(feats_json(), "[]") == 0, "renders no rows");
    ok(strcmp(ready_json(), "{}") == 0, "reports no readiness");

    puts("== a plugin with an unmet requires");
    write_desc("10-a.conf",
               "[NOTPROTON_A]\nlabel = Feature A\nsection = dev\n"
               "on = 1\noff = 0\nrequires = assets/a.dylib\n");
    ok(strstr(feats_json(),
              "{k:\"NOTPROTON_A\",l:\"Feature A\",on:\"1\",off:\"0\",dep:\"\",d:\"\"}") != NULL,
       "renders with its label and values");
    ok(strcmp(ready_json(), "{\"NOTPROTON_A\":0}") == 0, "is not ready");

    puts("== once the asset exists");
    make_asset("assets/a.dylib");
    ok(strcmp(ready_json(), "{\"NOTPROTON_A\":1}") == 0, "is ready");

    puts("== repeated requires are any-of");
    clear_descs();
    write_desc("10-b.conf",
               "[NOTPROTON_B]\nlabel = Feature B\nsection = dev\n"
               "requires = assets/missing-one.dylib\nrequires = assets/a.dylib\n");
    ok(strcmp(ready_json(), "{\"NOTPROTON_B\":1}") == 0, "the second entry can satisfy it");

    puts("== a row that requires nothing");
    clear_descs();
    write_desc("10-c.conf", "[NOTPROTON_C]\nlabel = Feature C\nsection = dev\n");
    ok(strcmp(ready_json(), "{\"NOTPROTON_C\":1}") == 0,
       "is always offerable, having nothing that can be missing");
    ok(strstr(feats_json(), "on:\"1\"") != NULL, "defaults its on value to 1");

    puts("== file order decides row order");
    clear_descs();
    write_desc("30-z.conf", "[NOTPROTON_Z]\nlabel = Zed\nsection = dev\n");
    write_desc("10-a.conf", "[NOTPROTON_A]\nlabel = Ay\nsection = dev\n");
    write_desc("20-m.conf", "[NOTPROTON_M]\nlabel = Em\nsection = dev\n");
    {
        const char *j = feats_json();
        const char *a = strstr(j, "NOTPROTON_A");
        const char *m = strstr(j, "NOTPROTON_M");
        const char *z = strstr(j, "NOTPROTON_Z");
        ok(a && m && z && a < m && m < z, "rows follow the sorted file names");
    }

    puts("== rejections");
    clear_descs();
    write_desc("10-ok.conf", "[NOTPROTON_OK]\nlabel = Fine\nsection = dev\n");
    write_desc("20-badsection.conf", "[NOTPROTON_BAD]\nlabel = Bad\nsection = graphics\n");
    write_desc("30-nokey.conf", "label = No key\nsection = dev\n");
    write_desc("40-dup.conf", "[NOTPROTON_OK]\nlabel = Again\nsection = dev\n");
    {
        const char *j = feats_json();
        ok(strstr(j, "NOTPROTON_OK") != NULL, "a good plugin still loads");
        ok(strstr(j, "NOTPROTON_BAD") == NULL, "an unknown section is refused");
        ok(strstr(j, "No key") == NULL, "a plugin with no key is refused");
        ok(strstr(j, "Again") == NULL, "a repeated key is refused");
    }
    clear_descs();
    write_desc("10-evil.conf", "[NOTPROTON_A:-}$(touch x)${X]\nlabel = Evil\n");
    write_desc("20-lower.conf", "[NOTPROTON_low]\nlabel = Lower\n");
    write_desc("30-bare.conf", "[NOTPROTON_]\nlabel = Bare\n");
    write_desc("40-nolabel.conf", "[NOTPROTON_NOLABEL]\n");
    ok(strcmp(feats_json(), "[]") == 0, "an id that is not a NOTPROTON_ name is refused");
    ok(strcmp(ready_json(), "{}") == 0, "and so is a plugin with no label");

    puts("== a repeated field");
    clear_descs();
    write_desc("10-f.conf",
               "[NOTPROTON_F]\nlabel = First\nlabel = Second\n"
               "[NOTPROTON_G]\nlabel = Good\n");
    {
        const char *j = feats_json();
        ok(strstr(j, "NOTPROTON_F") == NULL, "loses its record");
        ok(strstr(j, "NOTPROTON_G") != NULL, "and the rest of the file is kept");
    }

    puts("== a field that is not in the schema");
    clear_descs();
    write_desc("10-k.conf", "[NOTPROTON_K]\nkey = NOTPROTON_K\nlabel = Key\n");
    ok(strcmp(feats_json(), "[]") == 0,
       "key is one of them now the header carries the id, so it is refused");

    puts("== limits shared with compat_run.sh");
    clear_descs();
    {
        char body[4096];
        memset(body, 'x', sizeof(body));
        memcpy(body, "[NOTPROTON_LONG]\nlabel = L\n# ", 29);
        memcpy(body + 2100, "\n", 2);
        write_desc("10-line.conf", body);
    }
    ok(strcmp(feats_json(), "[]") == 0, "a line too long loses the file");
    clear_descs();
    make_asset("assets/fifth.dylib");
    write_desc("10-five.conf",
               "[NOTPROTON_FIVE]\nlabel = Five\nrequires = m1\nrequires = m2\n"
               "requires = m3\nrequires = m4\nrequires = assets/fifth.dylib\n");
    ok(strcmp(ready_json(), "{}") == 0, "a fifth requires is past the cap, so the record goes");
    clear_descs();
    write_desc("10-vt.conf", "[NOTPROTON_VT]\nlabel\v=\fVt\n");
    ok(strstr(feats_json(), "k:\"NOTPROTON_VT\"") != NULL, "any blank counts as space");
    clear_descs();
    for (int i = 0; i < NP_CONF_RECORDS_MAX; i++) {
        char name[32], body[2048], fill[600];
        memset(fill, '"', sizeof(fill));
        snprintf(name, sizeof(name), "%02d.conf", i);
        snprintf(body, sizeof(body),
                 "[NOTPROTON_%0180d]\nlabel = %.190s\ndescription = %.510s\n"
                 "on = %.31s\noff = %.31s\ndepends = NOTPROTON_%0180d\n",
                 i, fill, fill, fill, fill, (i + 1) % NP_CONF_RECORDS_MAX);
        write_desc(name, body);
    }
    {
        const char *j = feats_json();
        int rows = 0;
        for (const char *p = j; (p = strstr(p, "{k:")); p++) rows++;
        ok(rows == NP_CONF_RECORDS_MAX, "the most plugins at their longest all render");
    }

    puts("== a transform");
    rebuild();
    vars_json();
    {
        size_t len = 0;
        free(np_webpatch_transform((const uint8_t *)"x", 1, &len, NULL));
    }
    ok(!g_feat_ready_done, "reads the plugins again");
    ok(!g_var_done, "and reads the variants again");

    puts("== an optional description");
    clear_descs();
    write_desc("10-d.conf",
               "[NOTPROTON_D]\nlabel = Dee\nsection = dev\n"
               "description = What this does, in a sentence.\n");
    ok(strstr(feats_json(), "d:\"What this does, in a sentence.\"") != NULL,
       "is carried through to the row");
    clear_descs();
    write_desc("10-e.conf", "[NOTPROTON_E]\nlabel = Ee\nsection = dev\n");
    ok(strstr(feats_json(), "d:\"\"") != NULL,
       "is empty when the plugin omits it");
    clear_descs();
    write_desc("10-longon.conf",
               "[NOTPROTON_LONGON]\nlabel = Long on\n"
               "on = 0123456789012345678901234567890123\n");
    ok(strstr(feats_json(), "on:\"0123456789012345678901234567890123\"") != NULL,
       "keeps a long on value intact");

    puts("== a choice row");
    clear_descs();
    write_desc("10-ch.conf",
               "[NOTPROTON_ENV_HUD_POS]\nlabel = HUD position\nsection = dev\n"
               "type = choice\n"
               "choice = tl = Top left\nchoice = tr = Top right\nchoice = br\n");
    write_desc("20-empty-ch.conf",
               "[NOTPROTON_ENV_EMPTY_CH]\nlabel = Empty\n"
               "type = choice\nchoice = = Missing value\n");
    {
        const char *j = feats_json();
        // The whole tail, so a mis-counted literal cannot drop a bracket and still pass.
        ok(strstr(j, ",ty:\"choice\",ch:[{v:\"tl\",l:\"Top left\"},"
                     "{v:\"tr\",l:\"Top right\"},{v:\"br\",l:\"br\"}]}") != NULL,
           "is marked as a choice, splits value from label, and defaults a missing label");
        ok(strstr(j, "NOTPROTON_ENV_EMPTY_CH") == NULL,
           "and refuses a choice with an empty value before '='");
    }

    puts("== a slider snapped to declared values");
    clear_descs();
    write_desc("10-ld.conf",
               "[NOTPROTON_ENV_HZ]\nlabel = Target\nsection = dev\n"
               "type = slider\ndefault = off\n"
               "choice = off = Off\nchoice = 60 = 60 Hz\n");
    ok(strstr(feats_json(),
              ",ty:\"slider\",ch:[{v:\"off\",l:\"Off\"},{v:\"60\",l:\"60 Hz\"}],"
              "df:\"off\"") != NULL,
       "carries its values and a default that stays one of them");
    clear_descs();
    write_desc("10-e1.conf", "[NOTPROTON_E1]\nlabel = Ee\nsection = dev\n"
                             "type = slider\nchoice = 30\n");
    write_desc("10-e2.conf", "[NOTPROTON_E2]\nlabel = Ee\nsection = dev\n"
                             "type = slider\nmin = 0\nmax = 1\nchoice = 30\n"
                             "choice = 60\n");
    write_desc("10-e3.conf", "[NOTPROTON_E3]\nlabel = Ee\nsection = dev\n"
                             "type = slider\ndefault = 45\nchoice = 30\nchoice = 60\n");
    {
        const char *j = feats_json();
        ok(strstr(j, "NOTPROTON_E1") == NULL, "one value cannot be moved, so it is refused");
        ok(strstr(j, "NOTPROTON_E2") == NULL, "values and a range together are refused");
        ok(strstr(j, "NOTPROTON_E3") == NULL,
           "and a default that is not one of the values is refused");
    }

    puts("== a slider that could not be drawn");
    clear_descs();
    write_desc("10-a.conf", "[NOTPROTON_A]\nlabel = Ay\nsection = dev\n"
                            "type = slider\nmax = 1\n");
    write_desc("10-b.conf", "[NOTPROTON_B]\nlabel = Bee\nsection = dev\n"
                            "type = slider\nmin = 1\nmax = 1\n");
    write_desc("10-c.conf", "[NOTPROTON_C]\nlabel = Cee\nsection = dev\n"
                            "type = slider\nmin = 0\nmax = 1\nstep = fast\n");
    write_desc("10-c2.conf", "[NOTPROTON_C2]\nlabel = Cee2\nsection = dev\n"
                             "type = slider\nmin = 0\nmax = 1\nstep = 0\n");
    write_desc("10-d2.conf", "[NOTPROTON_D2]\nlabel = Dee\nsection = dev\n"
                             "type = slider\nmin = 0\nmax = 1px\n");
    write_desc("10-d3.conf", "[NOTPROTON_D3]\nlabel = Dee3\nsection = dev\n"
                             "type = slider\nmin = 0\nmax = 1\ndefault = 2\n");
    {
        const char *j = feats_json();
        ok(strstr(j, "NOTPROTON_A") == NULL, "no min is refused");
        ok(strstr(j, "NOTPROTON_B") == NULL, "an empty range is refused");
        ok(strstr(j, "NOTPROTON_C") == NULL, "a step that is not a number is refused");
        ok(strstr(j, "NOTPROTON_C2") == NULL, "a non-positive step is refused");
        ok(strstr(j, "NOTPROTON_D2") == NULL, "a bound with trailing text is refused");
        ok(strstr(j, "NOTPROTON_D3") == NULL, "and a default outside the range is refused");
    }

    puts("== a slider row");
    clear_descs();
    write_desc("10-sl.conf",
               "[NOTPROTON_ENV_HUD_SCALE]\nlabel = HUD size\nsection = dev\n"
               "type = slider\nmin = 0.5\nmax = 2\nstep = 0.25\ndefault = 1\n"
               "suffix = x\n");
    ok(strstr(feats_json(),
              ",ty:\"slider\",mn:0.5,mx:2,st:0.25,df:1,sf:\"x\"") != NULL,
       "carries its range, step, default and suffix as numbers");
    clear_descs();
    write_desc("10-sl.conf",
               "[NOTPROTON_ENV_HUD_SCALE]\nlabel = HUD size\nsection = dev\n"
               "type = slider\nmin = 0\nmax = 1\n");
    ok(strstr(feats_json(), ",ty:\"slider\",mn:0,mx:1}") != NULL,
       "and leaves out a step, default and suffix it was not given");
    clear_descs();
    write_desc("10-sl.conf",
               "[NOTPROTON_ENV_BIG]\nlabel = Big\ntype = slider\n"
               "min = 1000000\nmax = 1000000.5\nstep = 0.1\ndefault = 100000025e-2\n");
    ok(strstr(feats_json(), ",mn:1000000,mx:1000000.5,st:0.1,df:1000000.25") != NULL,
       "keeps every digit a value has, and no more");
    clear_descs();
    write_desc("10-inf.conf",
               "[NOTPROTON_ENV_INF]\nlabel = Inf\ntype = slider\nmin = 0\nmax = 1e999\n");
    ok(strcmp(feats_json(), "[]") == 0,
       "a bound too large to be a number is refused, not written into the page as inf");
    clear_descs();
    write_desc("10-dep.conf", "[NOTPROTON_DEP]\nlabel = Dep\ndepends = == x.conf\n");
    ok(strcmp(feats_json(), "[]") == 0, "a depends that is not a plugin id is refused");

    puts("== the tools a plugin is for");
    clear_descs();
    write_desc("10-tl.conf",
               "[NOTPROTON_PICKY]\nlabel = Picky\nsection = dev\n"
               "tools = notproton-fex*\ntools = notproton-26.3\n");
    ok(strstr(feats_json(), ",tl:[\"notproton-fex*\",\"notproton-26.3\"]") != NULL,
       "each one is carried, in the order it was read");
    clear_descs();
    write_desc("10-tl.conf", "[NOTPROTON_ALL]\nlabel = All\nsection = dev\n");
    ok(strstr(feats_json(), "tl:") == NULL, "naming none carries none, which means all");
    clear_descs();
    write_desc("10-star.conf", "[NOTPROTON_STAR]\nlabel = Star\nsection = dev\n"
                               "tools = not*proton\n");
    ok(strcmp(feats_json(), "[]") == 0,
       "a star anywhere but the end is refused, since the two readers would disagree");

    puts("== a row with no type, or one that does not exist");
    clear_descs();
    write_desc("10-t.conf", "[NOTPROTON_T]\nlabel = T\nsection = dev\n");
    write_desc("10-t2.conf", "[NOTPROTON_T2]\nlabel = T2\nsection = dev\n"
                             "type = dial\n");
    write_desc("10-t3.conf", "[NOTPROTON_T3]\nlabel = T3\nsection = dev\n"
                             "type = choice\n");
    {
        const char *j = feats_json();
        ok(strstr(j, "ty:") == NULL,
           "no type at all stays the toggle it has always been");
        ok(strstr(j, "NOTPROTON_T2") == NULL, "a type that does not exist is refused");
        ok(strstr(j, "NOTPROTON_T3") == NULL, "and so is a choice with no values");
    }

    puts("== lines for when a row is on");
    clear_descs();
    write_desc("10-dn.conf",
               "[NOTPROTON_DN]\nlabel = Dee\nsection = dev\n"
               "description = What it does.\n"
               "description_on = Ctrl+Opt+H hides it.\n"
               "description_on = Ctrl+Opt+G draws the graph.\n");
    ok(strstr(feats_json(),
              "d:\"What it does.\",dn:[\"Ctrl+Opt+H hides it.\","
              "\"Ctrl+Opt+G draws the graph.\"]") != NULL,
       "each line is carried separately, in the order it was read");
    clear_descs();
    write_desc("10-dn.conf", "[NOTPROTON_DN]\nlabel = Dee\nsection = dev\n");
    ok(strstr(feats_json(), "dn:") == NULL, "a row with none carries none");

    puts("== a label cannot break the page it renders into");
    clear_descs();
    write_desc("10-q.conf",
               "[NOTPROTON_Q]\nlabel = He said \"go\" \\ onwards\nsection = dev\n");
    ok(strstr(feats_json(), "l:\"He said \\\"go\\\" \\\\ onwards\"") != NULL,
       "quotes and backslashes are escaped");

    puts("== a missing plugins folder");
    snprintf(cmd, sizeof(cmd), "rm -rf '%s'", g_featdir);
    if (system(cmd) != 0) { shout("cannot remove %s", g_featdir); g_failed++; }
    ok(strcmp(feats_json(), "[]") == 0, "renders no rows, since nothing ships by default");
    ok(strcmp(ready_json(), "{}") == 0, "reports no readiness");

    puts("== runner variants");
    {
        const char *tools[]  = { "notproton", "notproton-26.3", "notproton-fex-rosetta" };
        const char *builds[] = { "27.0-fex", "26.3.0", "27.0-fex" };
        const char *archs[]  = { "aarch64", "x86_64", "x86_64" };
        np_webpatch_set_tool_builds(tools, builds, archs, 3);
    }
    // The 26.3 runner carries one slot. The FEX runner carries both, as a real one does,
    // which is why the slot a tool actually runs has to decide and not the directory.
    make_dir("mkdir -p '%s/Library/Application Support/notproton/runners/"
             "crossover-26.3.0/CrossOver/lib/dxmt/x86_64-windows'%s", g_home, "");
    make_dir("mkdir -p '%s/Library/Application Support/notproton/runners/"
             "crossover-27.0-fex/CrossOver/lib/dxmt/'{x86_64,aarch64}'-windows'%s",
             g_home, "");
    make_dir("mkdir -p '%s/trees/one/x86_64-windows'%s", g_home, "");
    make_asset("trees/one/x86_64-windows/d3d11.dll");

    ok(strcmp(vars_json(), "[]") == 0, "an empty directory offers nothing");

    write_var("one.conf",
               "[one]\n"
               "label   = A build\nvariant = Backend\n"
              "src     = trees/one\ndst     = lib/dxmt\n");
    ok(strcmp(vars_json(),
              "[{k:\"one\",l:\"A build\",v:\"Backend\","
              "t:[\"notproton-26.3\",\"notproton-fex-rosetta\"]}]") == 0,
       "an x86_64 tree is offered to the tools that run x86_64, and not to the arm64 one");

    puts("== a tree for the other architecture");
    clear_vars();
    make_dir("mkdir -p '%s/trees/otherarch/aarch64-windows'%s", g_home, "");
    make_asset("trees/otherarch/aarch64-windows/d3d11.dll");
    write_var("otherarch.conf",
               "[otherarch]\nlabel = Other\nvariant = Backend\n"
               "src = trees/otherarch\ndst = lib/dxmt\n");
    ok(strstr(vars_json(), "t:[\"notproton\"]") != NULL,
       "an arm64 tree is offered only to the tool that runs arm64 Wine");
    clear_vars();
    write_var("nolabel.conf", "[nolabel]\nsrc = trees/otherarch\ndst = lib/dxmt\n");
    {
        const char *j = vars_json();
        ok(strstr(j, "l:\"nolabel\"") != NULL,
           "a variant on its own is labelled with its id rather than saying it twice");
        ok(strstr(j, "v:\"nolabel\"") != NULL, "and is its own group");
    }

    puts("== a tree carrying both architectures");
    clear_vars();
    make_dir("mkdir -p '%s/trees/both/'{x86_64,aarch64}'-windows'%s", g_home, "");
    make_asset("trees/both/x86_64-windows/d3d11.dll");
    make_asset("trees/both/aarch64-windows/d3d11.dll");
    write_var("bothslots.conf",
               "[bothslots]\nlabel = Both\nvariant = Backend\n"
               "src = trees/both\ndst = lib/dxmt\n");
    // A cross build produces one architecture at a time but installs them into one
    // prefix, so a shared src holds both -- and the first runner has only the x86_64 slot.
    ok(strstr(vars_json(), "t:[\"notproton\",\"notproton-26.3\",\"notproton-fex-rosetta\"]")
       != NULL, "is offered everywhere, each runner taking the slot it has");

    puts("== rejections");
    clear_vars();
    write_var("ok-one.conf",
               "[ok-one]\nlabel = Fine\nvariant = Backend\n"
               "src = trees/one\ndst = lib/dxmt\n");
    write_var("typo.conf",
               "[typo]\nlabel = Typo\nvariant = Backend\n"
               "src = trees/one\ndst = lib/dxmt\nsrcc = elsewhere\n");
    write_var("nowhere.conf",
               "[nowhere]\nlabel = No source\nvariant = Backend\n");
    write_var("escape.conf",
               "[escape]\nlabel = Escape\nvariant = Backend\n"
               "src = trees/one\ndst = ../../lib/wine\n");
    write_var("absolute.conf",
               "[absolute]\nlabel = Absolute\nvariant = Backend\n"
               "src = trees/one\ndst = /lib/wine\n");
    {
        const char *j = vars_json();
        ok(strstr(j, "ok-one") != NULL, "a good descriptor still loads");
        ok(strstr(j, "typo") == NULL, "an unknown field is refused");
        ok(strstr(j, "No source") == NULL, "a descriptor with no src is refused");
        ok(strstr(j, "escape") == NULL, "a dst that climbs out of the runner is refused");
        ok(strstr(j, "absolute") == NULL, "an absolute dst is refused");
    }

    puts("== replacing wine's own files needs a build");
    clear_vars();
    make_dir("mkdir -p '%s/Library/Application Support/notproton/runners/"
             "crossover-26.3.0/CrossOver/lib/wine/'{x86_64-windows,x86_64-unix}%s", g_home, "");
    make_dir("mkdir -p '%s/Library/Application Support/notproton/runners/"
             "crossover-27.0-fex/CrossOver/lib/wine/'{x86_64,aarch64}'-windows'%s", g_home, "");
    make_asset("trees/winefix/x86_64-windows/win32u.dll");
    write_var("winefix.conf", "[winefix]\nsrc = trees/winefix\ndst = lib/wine\n");
    ok(strstr(vars_json(), "t:[\"notproton-26.3\",\"notproton-fex-rosetta\"]") != NULL,
       "adding a file to lib/wine needs no build");
    make_asset("Library/Application Support/notproton/runners/crossover-26.3.0/CrossOver/lib/wine/"
               "x86_64-windows/win32u.dll");
    ok(strstr(vars_json(), "t:[\"notproton-fex-rosetta\"]") != NULL,
       "replacing one a runner ships is left out on that runner only");
    write_var("winefix.conf", "[winefix]\nsrc = trees/winefix\ndst = lib/wine\nbuild = 26.3.0\n");
    ok(strstr(vars_json(), "t:[\"notproton-26.3\"]") != NULL, "naming a build offers it to that build's tool");
    write_var("winefix.conf", "[winefix]\nsrc = trees/winefix\ndst = lib/wine\nbuild = 27.0-fex\n");
    ok(strstr(vars_json(), "t:[\"notproton-fex-rosetta\"]") != NULL,
       "and only to the tools on that build that run the tree's architecture");
    clear_vars();
    make_asset("trees/dotdst/lib/wine/x86_64-windows/WIN32U.DLL");
    write_var("dotdst.conf", "[dotdst]\nsrc = trees/dotdst\ndst = .\n");
    ok(strstr(vars_json(), "{k:\"dotdst\",l:\"dotdst\",v:\"dotdst\",t:[\"notproton\",\"notproton-fex-rosetta\"]}") != NULL,
       "a file reached from dst = . in another case is still Wine's");
    clear_vars();
    make_asset("Library/Application Support/notproton/runners/crossover-26.3.0/CrossOver/lib/dxmt/"
               "x86_64-windows/dxgi.dll");
    make_asset("trees/viaparent/dxmt/x86_64-windows/dxgi.dll");
    write_var("viaparent.conf", "[viaparent]\nsrc = trees/viaparent\ndst = lib\n");
    ok(strstr(vars_json(), "t:[\"notproton\",\"notproton-26.3\",\"notproton-fex-rosetta\"]") != NULL,
       "replacing a DXMT file needs no build");

    puts("== the steam bridge is not a variant's to change");
    clear_vars();
    make_asset("trees/bridge/x86_64-windows/win32u.dll");
    make_asset("trees/bridge/x86_64-unix/lsteamclient.so");
    write_var("bridge.conf", "[bridge]\nsrc = trees/bridge\ndst = lib/wine\nbuild = 26.3.0\n");
    ok(strstr(vars_json(), "bridge") == NULL, "a tree carrying lsteamclient is not offered");
    clear_vars();
    write_var("bridge2.conf", "[bridge2]\nsrc = trees/winefix\ndst = lib/wine\nbuild = 26.3.0\n"
                              "remove = ./x86_64-windows//ntdll.dll\n");
    ok(strstr(vars_json(), "bridge2") == NULL, "removing ntdll however it is spelled is not offered");
    clear_vars();
    write_var("bridge3.conf", "[bridge3]\nsrc = trees/winefix\ndst = Lib/Wine\nbuild = 26.3.0\n"
                              "remove = X86_64-Windows/NTDLL.DLL\n");
    ok(strstr(vars_json(), "bridge3") == NULL, "or in another case, which APFS takes for the same file");
    clear_vars();
    make_asset("trees/upper/x86_64-windows/win32u.dll");
    make_asset("trees/upper/x86_64-windows/NTDLL.DLL");
    write_var("upper.conf", "[upper]\nsrc = trees/upper\ndst = lib/wine\nbuild = 26.3.0\n");
    ok(strstr(vars_json(), "upper") == NULL, "nor a tree spelling it that way");

    puts("== an entitlement only Apple can sign for");
    clear_vars();
    make_dir("mkdir -p '%s/Library/Application Support/notproton/runners/"
             "crossover-26.3.0/CrossOver/bin'%s", g_home, "");
    make_dir("printf '\\317\\372\\355\\376<key>com.apple.developer.x</key>' > '%s/Library/Application Support/"
             "notproton/runners/crossover-26.3.0/CrossOver/bin/loader'%s", g_home, "");
    make_dir("printf 'plain' > '%s/Library/Application Support/notproton/runners/"
             "crossover-26.3.0/CrossOver/bin/script'%s", g_home, "");
    make_asset("trees/apple/bin/loader");
    write_var("apple.conf", "[apple]\nsrc = trees/apple\ndst = .\nbuild = 26.3.0\n");
    ok(strstr(vars_json(), "{k:\"apple\",l:\"apple\",v:\"apple\",t:[]}") != NULL,
       "replacing a file holding one is not offered");
    clear_vars();
    make_asset("trees/plain/bin/script");
    write_var("plain.conf", "[plain]\nsrc = trees/plain\ndst = .\nbuild = 26.3.0\n");
    ok(strstr(vars_json(), "{k:\"plain\",l:\"plain\",v:\"plain\",t:[\"notproton-26.3\"]}") != NULL,
       "replacing one that doesn't still is");

    puts("== links in a tree are not followed");
    clear_vars();
    make_asset("elsewhere/x86_64-windows/d3d11.dll");
    make_dir("mkdir -p '%s/trees/linked' && ln -s '%s/elsewhere/x86_64-windows' "
             "\"$HOME/trees/linked/x86_64-windows\"", g_home, g_home);
    write_var("linked.conf", "[linked]\nsrc = trees/linked\ndst = lib/dxmt\n");
    ok(strcmp(vars_json(), "[]") == 0, "a tree holding only a linked folder is not offered");

    puts("== removes");
    clear_vars();
    make_asset("Library/Application Support/notproton/runners/crossover-26.3.0/CrossOver/lib/dxmt/"
               "x86_64-windows/nvapi64.dll");
    make_dir("mkdir -p '%s/trees/emptytree'%s", g_home, "");
    write_var("onlyremove.conf",
              "[onlyremove]\nsrc = trees/emptytree\ndst = lib/dxmt\nremove = x86_64-windows/nvapi64.dll\n");
    ok(strstr(vars_json(), "{k:\"onlyremove\",l:\"onlyremove\",v:\"onlyremove\",t:[\"notproton-26.3\"]}") != NULL,
       "a variant that only removes is offered where the runner has the file");

    puts("== a tree holding nothing");
    clear_vars();
    make_dir("mkdir -p '%s/trees/empty/x86_64-windows'%s", g_home, "");
    write_var("hollow.conf",
               "[hollow]\nlabel = Hollow\nvariant = Backend\n"
               "src = trees/empty\ndst = lib/dxmt\n");
    ok(strcmp(vars_json(), "[]") == 0, "is not offered at all");

    puts("== a label cannot break the page it renders into");
    clear_vars();
    write_var("quoted.conf",
               "[quoted]\nvariant = Backend\n"
               "label = He said \"go\" \\ onwards\nsrc = trees/one\ndst = lib/dxmt\n");
    ok(strstr(vars_json(), "l:\"He said \\\"go\\\" \\\\ onwards\"") != NULL,
       "quotes and backslashes are escaped");

    puts("== a missing variant directory");
    clear_vars();
    snprintf(cmd, sizeof(cmd), "rm -rf '%s'", g_vardir);
    if (system(cmd) != 0) { shout("cannot remove %s", g_vardir); g_failed++; }
    ok(strcmp(vars_json(), "[]") == 0, "offers nothing, since nothing ships by default");

    snprintf(cmd, sizeof(cmd), "rm -rf '%s'", g_home);
    if (system(cmd) != 0) shout("note: could not remove %s", g_home);

    if (g_failed) { printf("\n%d failure(s)\n", g_failed); return 1; }
    puts("\n==> featcheck: plugins and variants load, validate and report readiness");
    return 0;
}
