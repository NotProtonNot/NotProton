// What a game's folder gives away, against folders laid out the way installs are.
#include "../feats/game.c"

#include <limits.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

int np_log_level = 0;
FILE *np_log_file = NULL;

static int failures;
static char root[PATH_MAX];

static void check(int ok, const char *what) {
    printf("  %s  %s\n", ok ? "ok  " : "FAIL", what);
    if (!ok) failures++;
}

static void mkdirs(const char *rel) {
    char path[PATH_MAX];
    snprintf(path, sizeof path, "%s/%s", root, rel);
    for (char *at = path + strlen(root) + 1; *at; at++) {
        if (*at != '/') continue;
        *at = '\0';
        mkdir(path, 0755);
        *at = '/';
    }
    mkdir(path, 0755);
}

static void touch(const char *rel) {
    char path[PATH_MAX];
    snprintf(path, sizeof path, "%s/%s", root, rel);
    FILE *f = fopen(path, "w");
    if (f) fclose(f);
}

static np_game_t scan(const char *rel) {
    char path[PATH_MAX];
    snprintf(path, sizeof path, "%s/%s", root, rel);
    np_game_t g;
    np_game_scan(path, &g);
    return g;
}

int main(void) {
    snprintf(root, sizeof root, "%s/game.XXXXXX", getenv("TMPDIR") ? getenv("TMPDIR") : "/tmp");
    if (!mkdtemp(root)) { perror("mkdtemp"); return 1; }

    printf("== anti-cheat ==\n");
    mkdirs("eac/EasyAntiCheat");
    touch("eac/Game.exe");
    check(scan("eac").anticheat == NP_AC_EASYANTICHEAT, "Easy Anti-Cheat's folder is seen");
    // Unreal games keep it four folders down.
    mkdirs("deep/Game/Binaries/Win64/EasyAntiCheat");
    check(scan("deep").anticheat == NP_AC_EASYANTICHEAT, "and so is one deep in the install");
    mkdirs("be");
    touch("be/BEService.exe");
    check(scan("be").anticheat == NP_AC_BATTLEYE, "BattlEye is seen");
    mkdirs("vg");
    touch("vg/vgc.exe");
    check(scan("vg").anticheat == NP_AC_VANGUARD, "Vanguard is seen");
    mkdirs("plain");
    touch("plain/Game.exe");
    check(scan("plain").anticheat == NP_AC_NONE, "a game without one has none");

    printf("== launchers ==\n");
    mkdirs("ubi");
    touch("ubi/UbisoftConnectInstaller.exe");
    check(scan("ubi").launcher == NP_LAUNCHER_UBISOFT, "Ubisoft Connect is seen");
    mkdirs("ea");
    touch("ea/EALauncher.exe");
    check(scan("ea").launcher == NP_LAUNCHER_EA, "the EA app is seen");
    mkdirs("rs");
    touch("rs/SocialClubHelper.exe");
    check(scan("rs").launcher == NP_LAUNCHER_ROCKSTAR, "the Rockstar launcher is seen");
    // Lots of games ship the EOS SDK for crossplay without the Epic launcher.
    mkdirs("eos");
    touch("eos/EOSSDK-Win64-Shipping.dll");
    check(scan("eos").launcher == NP_LAUNCHER_NONE, "the EOS SDK is not a launcher");

    printf("== native builds ==\n");
    mkdirs("native/Game.app/Contents");
    touch("native/Game.exe");
    check(scan("native").native, "an app bundle beside the Windows files is a native build");
    check(!scan("plain").native, "and a folder without one is not");

    printf("== nothing to read ==\n");
    np_game_t none;
    check(!np_game_scan("/nope/not/here", &none) && !none.scanned, "a folder that is not there");
    check(!np_game_scan(NULL, &none), "no folder at all");
    mkdirs("empty");
    np_game_t empty = scan("empty");
    check(empty.scanned && !empty.native && !empty.anticheat && !empty.launcher,
          "an empty folder is read and says nothing");

    printf(failures ? "==> game-check: %d failure(s)\n" : "==> game-check: installs read as expected\n", failures);
    return failures ? 1 : 0;
}
