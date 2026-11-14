// The whole chain on one scratch library: a manifest, the game's files, a rule in the
// support folder, and what comes out -- a badge line, the settings the run script reads,
// and the words the rule says to pass the game.
#include "../feats/catalog.c"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

// What the appinfo helper would say. A check hands it over, so the games Valve has an
// opinion on are the same on every machine this runs on.
static const char *g_valve;
char *np_nativeplatform_compat(void) { return g_valve ? strdup(g_valve) : NULL; }

// The store's thread and switch are the store's to check; here they are only counted.
static int g_store_started;
void np_store_start(void) { g_store_started++; }
int np_store_switch(void) { return 1; }

static int failures;
static char root[PATH_MAX], home[PATH_MAX], steam[PATH_MAX];

static void check(const char *what, const char *want, const char *got) {
    int ok = strcmp(want, got) == 0;
    printf("  %s  %s\n", ok ? "ok  " : "FAIL", what);
    if (!ok) { printf("        want [%s]\n        got  [%s]\n", want, got); failures++; }
}

static void has(const char *what, const char *haystack, const char *needle) {
    int ok = strstr(haystack, needle) != NULL;
    printf("  %s  %s\n", ok ? "ok  " : "FAIL", what);
    if (!ok) { printf("        no [%s] in [%.160s]\n", needle, haystack); failures++; }
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

static void write_at(const char *path, const void *data, size_t len) {
    FILE *f = fopen(path, "wb");
    if (!f) { perror(path); exit(1); }
    if (len) fwrite(data, 1, len, f);
    fclose(f);
}

static void put_text(const char *path, const char *text) { write_at(path, text, strlen(text)); }

static char *slurp(const char *path) {
    static char buf[4096];
    buf[0] = '\0';
    FILE *f = fopen(path, "r");
    if (!f) return buf;
    size_t n = fread(buf, 1, sizeof buf - 1, f);
    buf[n] = '\0';
    fclose(f);
    return buf;
}

static void put16(uint8_t *p, uint16_t v) { p[0] = (uint8_t)v; p[1] = (uint8_t)(v >> 8); }
static void put32(uint8_t *p, uint32_t v) {
    p[0] = (uint8_t)v; p[1] = (uint8_t)(v >> 8); p[2] = (uint8_t)(v >> 16); p[3] = (uint8_t)(v >> 24);
}

// A 64-bit PE that imports one DLL, which is all the scan reads.
static void put_pe(const char *path, const char *dll) {
    uint8_t pe[0x400] = { 0 };
    const uint32_t peo = 0x80;
    memcpy(pe, "MZ", 2);
    put32(pe + 0x3C, peo);
    memcpy(pe + peo, "PE\0\0", 4);
    put16(pe + peo + 4, 0x8664);
    put16(pe + peo + 6, 1);
    put16(pe + peo + 20, 240);
    put16(pe + peo + 24, 0x20B);
    size_t dir_base = peo + 24 + 112;
    put32(pe + dir_base - 4, 16);
    put32(pe + dir_base + 8, 0x1000);
    size_t sect = peo + 24 + 240;
    memcpy(pe + sect, ".text", 5);
    put32(pe + sect + 8, 0x1000);
    put32(pe + sect + 12, 0x1000);
    put32(pe + sect + 16, 0x200);
    put32(pe + sect + 20, 0x200);
    put32(pe + 0x200 + 12, 0x1050);
    memcpy(pe + 0x250, dll, strlen(dll));
    write_at(path, pe, sizeof pe);
}

int main(void) {
    snprintf(root, sizeof root, "%s/catalog.XXXXXX", getenv("TMPDIR") ? getenv("TMPDIR") : "/tmp");
    if (!mkdtemp(root)) { perror("mkdtemp"); return 1; }
    snprintf(home, sizeof home, "%s/home", root);
    snprintf(steam, sizeof steam, "%s/Steam", root);
    setenv("HOME", home, 1);

    char path[PATH_MAX], game_dir[PATH_MAX];
    snprintf(path, sizeof path, "%s/Library/Application Support/notproton/rules", home);
    mkdirs(path);
    // A rule anyone could have dropped in, for every Unreal game.
    snprintf(path, sizeof path, "%s/Library/Application Support/notproton/rules/10-ue.conf", home);
    put_text(path, "[unreal-movies]\nengine = unreal\noption = -nostartupmovies\n"
                   "note = Startup movies skipped.\n");

    // One installed Unreal game, with a prefix, on the library Steam itself is in.
    snprintf(game_dir, sizeof game_dir, "%s/steamapps/common/Thing/Thing/Binaries/Win64", steam);
    mkdirs(game_dir);
    snprintf(path, sizeof path, "%s/steamapps/compatdata/480", steam);
    mkdirs(path);
    snprintf(path, sizeof path, "%s/Thing-Win64-Shipping.exe", game_dir);
    put_pe(path, "d3d12.dll");
    snprintf(path, sizeof path, "%s/steamapps/appmanifest_480.acf", steam);
    put_text(path, "\"AppState\"\n{\n\t\"appid\"\t\t\"480\"\n\t\"buildid\"\t\t\"99\"\n"
                   "\t\"installdir\"\t\t\"Thing\"\n\t\"LastUpdated\"\t\t\"1700000000\"\n}\n");

    printf("== one pass over the library ==\n");
    int seen = np_catalog_refresh(steam);
    check("the installed game is looked at", "1", (char[4]){ (char)('0' + seen), 0 });

    snprintf(path, sizeof path, "%s/steamapps/compatdata/480/notproton-advice", steam);
    const char *advice = slurp(path);
    has("the settings name the backend D3D12 needs", advice, "CX_GRAPHICS_BACKEND=d3dmetal");
    has("and the Mac's own set is in them", advice, "WINEMSYNC=1");

    snprintf(path, sizeof path, "%s/steamapps/compatdata/480/notproton-advice-args", steam);
    check("the rule's words are left for the run script", "-nostartupmovies", slurp(path));

    snprintf(path, sizeof path, "%s/Library/Application Support/notproton/badges", home);
    const char *badges = slurp(path);
    has("the game gets a badge line", badges, "480 unknown ");
    has("whose reason says what it is set up for", badges, "Direct3D 12");
    has("and carries the rule's note", badges, "Startup movies skipped.");

    printf("== what the library is handed ==\n");
    char *js = np_catalog_javascript(steam);
    check("there is something to inject", "yes", js ? "yes" : "no");
    if (js) {
        has("it defines the map", js, "window.__NOTPROTON_COMPAT__={");
        has("with the game in it", js, "480:[\"unknown\",\"");
        free(js);
    }

    printf("== the second pass ==\n");
    // The scan is kept beside the prefix, so an unchanged game is not walked again.
    snprintf(path, sizeof path, "%s/steamapps/compatdata/480/notproton-scan", steam);
    has("the scan was saved", slurp(path), "99-1700000000");
    unlink(path);
    snprintf(path, sizeof path, "%s/Thing-Win64-Shipping.exe", game_dir);
    unlink(path);
    np_catalog_refresh(steam);
    snprintf(path, sizeof path, "%s/steamapps/compatdata/480/notproton-advice-args", steam);
    check("a game whose files are gone keeps no words", "", slurp(path));

    printf("== games that are not installed ==\n");
    // Four games nobody downloaded, and the installed one again: Valve failed its
    // anti-cheat, which blocks it whatever its folder looked like.
    snprintf(path, sizeof path, "%s/Thing-Win64-Shipping.exe", game_dir);
    put_pe(path, "d3d12.dll");
    g_valve = "480 0 3 1\n501 1 0 0\n502 0 3 0\n503 0 1 0\n504 0 0 0\n505 0 1 1\nnot a line\n506 9 9 9\n";
    np_catalog_refresh(steam);
    snprintf(path, sizeof path, "%s/Library/Application Support/notproton/badges", home);
    badges = slurp(path);
    has("an installed game Valve failed for anti-cheat is blocked", badges, "480 blocked Valve's testing");
    has("a game with a macOS build is good", badges, "501 good This game has a native macOS");
    has("one Valve verified on Proton is likely", badges, "502 likely Verified on Steam Deck");
    has("one Valve marks unsupported has issues", badges, "503 issues ");
    has("one Valve has not tested is unknown", badges, "504 unknown ");
    has("one that failed for anti-cheat is blocked without being installed", badges, "505 blocked ");
    check("a line that is not one adds no game", "no", strstr(badges, "506 ") ? "yes" : "no");

    printf("== the switch ==\n");
    check("handing the library its badges starts the store's side too", "yes", g_store_started ? "yes" : "no");
    js = np_catalog_javascript(steam);
    has("the badges are on until someone turns them off", js ? js : "", "__NOTPROTON_BADGES_OFF__=false;");
    free(js);
    check("turning them off is kept", "1", np_catalog_set_enabled(0) ? "1" : "0");
    js = np_catalog_javascript(steam);
    has("and the library is told", js ? js : "", "__NOTPROTON_BADGES_OFF__=true;");
    has("with the map still there, so turning them on again needs no restart", js ? js : "", "502:[\"likely\"");
    free(js);
    check("turning them on again is kept too", "1", np_catalog_set_enabled(1) ? "1" : "0");
    check("and doing it twice is not an error", "1", np_catalog_set_enabled(1) ? "1" : "0");
    js = np_catalog_javascript(steam);
    has("and the library is told that as well", js ? js : "", "__NOTPROTON_BADGES_OFF__=false;");
    free(js);

    printf(failures ? "==> catalog-check: %d failure(s)\n"
                    : "==> catalog-check: one pass turns a library into badges and settings\n",
           failures);
    return failures ? 1 : 0;
}
