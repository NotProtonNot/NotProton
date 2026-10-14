// Feature descriptors drive the Developer rows and whether each one is offerable, so
// both answers are checked against a descriptor directory this test builds itself. The
// emitters read $HOME, which is what makes a temp tree enough to pin them down.
#include "../feats/webpatch.c"

#include <stdarg.h>
#include <stdio.h>
#include <unistd.h>

// Satisfies the log macros without pulling in log.c. Rejection reasons land on stderr,
// which is where a check that expects one goes looking.
int   np_log_level = NP_LVL_WARN;
FILE *np_log_file;

static int g_failed;
static char g_home[1024];
static char g_featdir[1200];

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

static void clear_descs(void) {
    char cmd[2600];
    snprintf(cmd, sizeof(cmd), "rm -f '%s'/*.conf", g_featdir);
    if (system(cmd) != 0) { shout("cannot clear %s", g_featdir); g_failed++; }
}

// Touch a file under the temp home so a "requires" can be made to resolve.
static void make_asset(const char *rel) {
    char path[2048], cmd[2200];
    FILE *f;
    snprintf(path, sizeof(path), "%s/%s", g_home, rel);
    snprintf(cmd, sizeof(cmd), "mkdir -p \"$(dirname '%s')\"", path);
    if (system(cmd) != 0) { shout("cannot make dirs for %s", path); g_failed++; return; }
    if (!(f = fopen(path, "w"))) { shout("cannot write %s", path); g_failed++; return; }
    fclose(f);
}

// feat_build caches, so each call re-reads the directory the test just rewrote.
static void rebuild(void) {
    g_feat_ready_done = 0;
    feat_build();
}

static char *ready_json(void) { rebuild(); return g_feat_ready; }
static char *feats_json(void) { rebuild(); return g_feat_rows; }

int main(void) {
    char tmpl[] = "/tmp/np-featcheck.XXXXXX";
    char cmd[2600];
    char *dir = mkdtemp(tmpl);

    if (!dir) { fputs("cannot make a temp directory\n", stderr); return 2; }
    snprintf(g_home, sizeof(g_home), "%s", dir);
    snprintf(g_featdir, sizeof(g_featdir),
             "%s/" NP_FEAT_DIR, g_home);
    snprintf(cmd, sizeof(cmd), "mkdir -p '%s'", g_featdir);
    if (system(cmd) != 0) { fputs("cannot make the descriptor directory\n", stderr); return 2; }
    setenv("HOME", g_home, 1);

    puts("== an empty descriptor directory");
    ok(strcmp(feats_json(), "[]") == 0, "renders no rows");
    ok(strcmp(ready_json(), "{}") == 0, "reports no readiness");

    puts("== a descriptor with an unmet requires");
    write_desc("10-a.conf",
               "key = NOTPROTON_A\nlabel = Feature A\nsection = dev\n"
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
               "key = NOTPROTON_B\nlabel = Feature B\nsection = dev\n"
               "requires = assets/missing-one.dylib\nrequires = assets/a.dylib\n");
    ok(strcmp(ready_json(), "{\"NOTPROTON_B\":1}") == 0, "the second entry can satisfy it");

    puts("== a row that requires nothing");
    clear_descs();
    write_desc("10-c.conf", "key = NOTPROTON_C\nlabel = Feature C\nsection = dev\n");
    ok(strcmp(ready_json(), "{\"NOTPROTON_C\":1}") == 0,
       "is always offerable, having nothing that can be missing");
    ok(strstr(feats_json(), "on:\"1\"") != NULL, "defaults its on value to 1");

    puts("== file order decides row order");
    clear_descs();
    write_desc("30-z.conf", "key = NOTPROTON_Z\nlabel = Zed\nsection = dev\n");
    write_desc("10-a.conf", "key = NOTPROTON_A\nlabel = Ay\nsection = dev\n");
    write_desc("20-m.conf", "key = NOTPROTON_M\nlabel = Em\nsection = dev\n");
    {
        const char *j = feats_json();
        const char *a = strstr(j, "NOTPROTON_A");
        const char *m = strstr(j, "NOTPROTON_M");
        const char *z = strstr(j, "NOTPROTON_Z");
        ok(a && m && z && a < m && m < z, "rows follow the sorted file names");
    }

    puts("== rejections");
    clear_descs();
    write_desc("10-ok.conf", "key = NOTPROTON_OK\nlabel = Fine\nsection = dev\n");
    write_desc("20-badsection.conf", "key = NOTPROTON_BAD\nlabel = Bad\nsection = graphics\n");
    write_desc("30-nokey.conf", "label = No key\nsection = dev\n");
    write_desc("40-dup.conf", "key = NOTPROTON_OK\nlabel = Again\nsection = dev\n");
    {
        const char *j = feats_json();
        ok(strstr(j, "NOTPROTON_OK") != NULL, "a good descriptor still loads");
        ok(strstr(j, "NOTPROTON_BAD") == NULL, "an unknown section is refused");
        ok(strstr(j, "No key") == NULL, "a descriptor with no key is refused");
        ok(strstr(j, "Again") == NULL, "a repeated key is refused");
    }

    puts("== an optional description");
    clear_descs();
    write_desc("10-d.conf",
               "key = NOTPROTON_D\nlabel = Dee\nsection = dev\n"
               "description = What this does, in a sentence.\n");
    ok(strstr(feats_json(), "d:\"What this does, in a sentence.\"") != NULL,
       "is carried through to the row");
    clear_descs();
    write_desc("10-e.conf", "key = NOTPROTON_E\nlabel = Ee\nsection = dev\n");
    ok(strstr(feats_json(), "d:\"\"") != NULL,
       "is empty when the descriptor omits it");

    puts("== a label cannot break the page it renders into");
    clear_descs();
    write_desc("10-q.conf",
               "key = NOTPROTON_Q\nlabel = He said \"go\" \\ onwards\nsection = dev\n");
    ok(strstr(feats_json(), "l:\"He said \\\"go\\\" \\\\ onwards\"") != NULL,
       "quotes and backslashes are escaped");

    puts("== a missing descriptor directory");
    snprintf(cmd, sizeof(cmd), "rm -rf '%s'", g_featdir);
    if (system(cmd) != 0) { shout("cannot remove %s", g_featdir); g_failed++; }
    ok(strcmp(feats_json(), "[]") == 0, "renders no rows, since nothing ships by default");
    ok(strcmp(ready_json(), "{}") == 0, "reports no readiness");

    snprintf(cmd, sizeof(cmd), "rm -rf '%s'", g_home);
    if (system(cmd) != 0) shout("note: could not remove %s", g_home);

    if (g_failed) { printf("\n%d failure(s)\n", g_failed); return 1; }
    puts("\n==> featcheck: descriptors load, rank, validate and report readiness");
    return 0;
}
