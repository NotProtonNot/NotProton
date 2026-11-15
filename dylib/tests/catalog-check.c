// One pass over a scratch library: manifests and folders in, badge lines and the
// library's script out.
#include "../feats/catalog.c"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

static int failures;
static char home[PATH_MAX], steam[PATH_MAX];

static void check(const char *what, int ok) {
    printf("  %s  %s\n", ok ? "ok  " : "FAIL", what);
    if (!ok) failures++;
}

static void mkdirs(const char *path) {
    char buf[PATH_MAX];
    snprintf(buf, sizeof buf, "%s", path);
    for (char *at = buf + 1; *at; at++) {
        if (*at != '/') continue;
        *at = '\0';
        mkdir(buf, 0755);
        *at = '/';
    }
    mkdir(buf, 0755);
}

static void put(const char *path, const char *text) {
    FILE *f = fopen(path, "w");
    if (!f) { perror(path); exit(1); }
    fputs(text, f);
    fclose(f);
}

static const char *slurp(const char *path) {
    static char buf[8192];
    buf[0] = '\0';
    FILE *f = fopen(path, "r");
    if (!f) return buf;
    buf[fread(buf, 1, sizeof buf - 1, f)] = '\0';
    fclose(f);
    return buf;
}

// A game: its manifest, its folder, and a prefix to keep its scan in.
static void install(unsigned appid, const char *dir, const char *marker) {
    char path[PATH_MAX];
    snprintf(path, sizeof path, "%s/steamapps/common/%s", steam, dir);
    mkdirs(path);
    if (marker) {
        snprintf(path, sizeof path, "%s/steamapps/common/%s/%s", steam, dir, marker);
        mkdirs(path);
    }
    snprintf(path, sizeof path, "%s/steamapps/compatdata/%u", steam, appid);
    mkdirs(path);
    char manifest[512];
    snprintf(manifest, sizeof manifest, "\"AppState\"\n{\n\t\"appid\"\t\t\"%u\"\n\t\"buildid\"\t\t\"7\"\n"
             "\t\"installdir\"\t\t\"%s\"\n\t\"LastUpdated\"\t\t\"1700000000\"\n}\n", appid, dir);
    snprintf(path, sizeof path, "%s/steamapps/appmanifest_%u.acf", steam, appid);
    put(path, manifest);
}

int main(void) {
    char root[PATH_MAX], path[PATH_MAX], badges[PATH_MAX];
    snprintf(root, sizeof root, "%s/catalog.XXXXXX", getenv("TMPDIR") ? getenv("TMPDIR") : "/tmp");
    if (!mkdtemp(root)) { perror("mkdtemp"); return 1; }
    snprintf(home, sizeof home, "%s/home", root);
    snprintf(steam, sizeof steam, "%s/Steam", root);
    setenv("HOME", home, 1);
    snprintf(path, sizeof path, "%s/Library/Application Support/notproton", home);
    mkdirs(path);
    snprintf(badges, sizeof badges, "%s/badges", path);

    install(100, "Shooter", "EasyAntiCheat");
    install(200, "Adventure", NULL);
    install(300, "Puzzle", "Puzzle.app");
    // Two clean sessions over twenty minutes, recorded by the run script.
    snprintf(path, sizeof path, "%s/steamapps/compatdata/200/notproton-sessions", steam);
    put(path, "1\n2\n0\n2400\nhealthy\n26.3\ndxmt\n");
    // A manifest whose folder is gone is not a game to badge.
    snprintf(path, sizeof path, "%s/steamapps/appmanifest_400.acf", steam);
    put(path, "\"AppState\"\n{\n\t\"installdir\"\t\t\"Gone\"\n}\n");

    printf("== one pass ==\n");
    check("every manifest is looked at", np_catalog_refresh(steam) == 4);
    const char *b = slurp(badges);
    check("an anti-cheat in the folder is blocked", strstr(b, "100 blocked This game uses Easy Anti-Cheat") != NULL);
    check("a game this Mac has run clean is good", strstr(b, "200 good This game has run on this Mac 2 times") != NULL);
    check("a native build is good", strstr(b, "300 good This game has a native macOS version") != NULL);
    check("a game whose folder is gone gets no line", strstr(b, "\n400 ") == NULL && strncmp(b, "400 ", 4) != 0);

    printf("== scans are kept ==\n");
    snprintf(path, sizeof path, "%s/steamapps/compatdata/100/notproton-scan", steam);
    check("the scan is saved beside the prefix", strncmp(slurp(path), "2\n7-1700000000\n0\n1\n0\n", 22) == 0);
    // A saved scan is believed, so the folder is not walked again for an unchanged game.
    char eac[PATH_MAX];
    snprintf(eac, sizeof eac, "%s/steamapps/common/Shooter/EasyAntiCheat", steam);
    rmdir(eac);
    np_catalog_refresh(steam);
    check("an unchanged game keeps its saved scan", strstr(slurp(badges), "100 blocked") != NULL);
    // A scan from an older format is redone.
    put(path, "1\n7-1700000000\n64\n2\n0\n1\n0\n0\n");
    np_catalog_refresh(steam);
    check("one from an older format is scanned again", strstr(slurp(badges), "100 unknown") != NULL);

    printf("== what the library is handed ==\n");
    char *js = np_catalog_javascript(steam);
    check("the map is there", js && strstr(js, "window.__NOTPROTON_COMPAT__={") != NULL);
    check("with the badges in it", js && strstr(js, "200:[\"good\",\"") != NULL);
    check("and the badges on", js && strstr(js, "window.__NOTPROTON_BADGES_OFF__=false;") != NULL);
    free(js);

    printf("== the switch ==\n");
    check("turning them off is kept", np_catalog_set_enabled(0));
    js = np_catalog_javascript(steam);
    check("and the library is told", js && strstr(js, "__NOTPROTON_BADGES_OFF__=true;") != NULL);
    check("with the map still there, so turning them on needs no restart", js && strstr(js, "200:[") != NULL);
    free(js);
    check("turning them on again is kept", np_catalog_set_enabled(1));
    check("and doing it twice is not an error", np_catalog_set_enabled(1));

    printf("== nothing to read ==\n");
    unlink(badges);
    check("no saved badges is no map", np_catalog_map() == NULL);
    check("and no library at all looks at nothing", np_catalog_refresh("") == 0);

    printf(failures ? "==> catalog-check: %d failure(s)\n" : "==> catalog-check: one pass turns a library into badges\n", failures);
    return failures ? 1 : 0;
}
