// What a game's recorded sessions come to, and what a record that cannot be trusted does.
#include "../feats/verdict.c"

#include <limits.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

static int failures;
static char root[PATH_MAX];

static void check(const char *what, const char *want, const char *got) {
    int ok = strcmp(want, got) == 0;
    printf("  %s  %s%s\n", ok ? "ok  " : "FAIL", what, ok ? "" : "");
    if (!ok) { printf("        want [%s]\n        got  [%s]\n", want, got); failures++; }
}

static void put(const char *text) {
    char path[PATH_MAX];
    snprintf(path, sizeof path, "%s/notproton-sessions", root);
    if (!text) { unlink(path); return; }
    FILE *f = fopen(path, "w");
    if (!f) { perror("fopen"); exit(1); }
    fputs(text, f);
    fclose(f);
}

// "<read> <tier> <runs>/<crashes> <minutes>m <last> <build> <backend>", so one line says
// everything a record came to.
static const char *sum(const char *text) {
    static char out[256];
    np_verdict_t v;
    put(text);
    int read = np_verdict_read(root, &v);
    snprintf(out, sizeof out, "%s %s %d/%d %dm %s %s %s", read ? "read" : "no",
             np_verdict_name(v.tier), v.healthy, v.failed, v.minutes, v.last,
             v.build[0] ? v.build : "-", v.backend[0] ? v.backend : "-");
    return out;
}

int main(void) {
    snprintf(root, sizeof root, "%s/verdict.XXXXXX", getenv("TMPDIR") ? getenv("TMPDIR") : "/tmp");
    if (!mkdtemp(root)) { perror("mkdtemp"); return 1; }

    printf("== what the sessions come to ==\n");
    check("a game never run here is unknown", "no unknown 0/0 0m unknown - -", sum(NULL));
    check("and so is one whose record holds no session",
          "read unknown 0/0 0m unknown 26.3 dxmt", sum("1\n0\n0\n0\nunknown\n26.3\ndxmt\n"));
    check("two clean sessions over twenty minutes are verified",
          "read verified 2/0 45m healthy 26.3 dxmt", sum("1\n2\n0\n2700\nhealthy\n26.3\ndxmt\n"));
    // One session is a game that started, which is not yet a game that runs.
    check("one clean session is playable",
          "read playable 1/0 45m healthy 26.3 dxmt", sum("1\n1\n0\n2700\nhealthy\n26.3\ndxmt\n"));
    check("and so are two that barely ran",
          "read playable 2/0 3m healthy 26.3 dxmt", sum("1\n2\n0\n180\nhealthy\n26.3\ndxmt\n"));
    check("a crash anywhere in the record keeps it playable",
          "read playable 9/1 300m healthy 26.3 dxmt", sum("1\n9\n1\n18000\nhealthy\n26.3\ndxmt\n"));
    check("a game that has only ever crashed is broken",
          "read broken 0/3 2m failed 26.3 dxvk", sum("1\n0\n3\n120\nfailed\n26.3\ndxvk\n"));

    printf("== a record to distrust ==\n");
    check("an empty file says nothing", "no unknown 0/0 0m unknown - -", sum(""));
    check("a format this does not read is not read",
          "no unknown 0/0 0m unknown - -", sum("2\n2\n0\n2700\nhealthy\n26.3\ndxmt\n"));
    check("a count that is not a number is not read",
          "no unknown 0/0 0m unknown - -", sum("1\n2x\n0\n2700\nhealthy\n26.3\ndxmt\n"));
    check("nor is a negative one",
          "no unknown 0/0 0m unknown - -", sum("1\n-2\n0\n2700\nhealthy\n26.3\ndxmt\n"));
    check("nor one no run could reach",
          "no unknown 0/0 0m unknown - -", sum("1\n999999999\n0\n2700\nhealthy\n26.3\ndxmt\n"));
    check("a record that stops early is not read",
          "no unknown 0/0 0m unknown - -", sum("1\n2\n0\n2700\n"));
    // The build and the backend are printed on the page, so a quote in them is a record
    // that was not written by the run script.
    check("a field that could break out of the JSON is not read",
          "no unknown 0/0 0m unknown - -", sum("1\n2\n0\n2700\nhealthy\n26.3\"\ndxmt\n"));
    check("and neither is one longer than the field",
          "no unknown 0/0 0m unknown - -",
          sum("1\n2\n0\n2700\nhealthy\n2666666666666666666666666666666666666666666666666666666666666666666666.3\ndxmt\n"));
    // A health word nobody wrote is not one the page should repeat.
    check("an unknown health word reads as unknown",
          "read verified 2/0 45m unknown 26.3 dxmt", sum("1\n2\n0\n2700\nwedged\n26.3\ndxmt\n"));

    put(NULL);
    rmdir(root);
    printf(failures ? "==> verdict-check: %d failure(s)\n" : "==> verdict-check: sessions read as expected\n",
           failures);
    return failures ? 1 : 0;
}
