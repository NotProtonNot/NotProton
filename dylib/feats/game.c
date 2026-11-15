// What an installed game's folder says about it, from file names alone.
#include "game.h"
#include "../util/log.h"

#include <dirent.h>
#include <limits.h>
#include <stdio.h>
#include <string.h>
#include <strings.h>
#include <sys/stat.h>

// Deep enough for <Game>/Binaries/Win64, bounded so a huge install stays quick.
#define NP_SCAN_DEPTH   5
#define NP_SCAN_ENTRIES 20000

static int has_ci(const char *s, const char *needle) {
    size_t n = strlen(s), m = strlen(needle);
    for (size_t i = 0; m && n >= m && i <= n - m; i++)
        if (strncasecmp(s + i, needle, m) == 0) return 1;
    return 0;
}

static void note(np_game_t *g, const char *name) {
    if (has_ci(name, "easyanticheat") || has_ci(name, "eac_launcher"))
        g->anticheat = NP_AC_EASYANTICHEAT;
    else if (has_ci(name, "battleye") || strcasecmp(name, "beservice.exe") == 0
             || strcasecmp(name, "beclient.dll") == 0)
        g->anticheat = NP_AC_BATTLEYE;
    else if (has_ci(name, "vanguard") || strcasecmp(name, "vgc.exe") == 0)
        g->anticheat = NP_AC_VANGUARD;

    if (has_ci(name, "eadesktop") || has_ci(name, "ealauncher") || has_ci(name, "eacore"))
        g->launcher = NP_LAUNCHER_EA;
    else if (has_ci(name, "ubisoft") || has_ci(name, "uplay"))
        g->launcher = NP_LAUNCHER_UBISOFT;
    // Not the EOS SDK, which plenty of games ship for crossplay without the launcher.
    else if (has_ci(name, "epicgameslauncher"))
        g->launcher = NP_LAUNCHER_EPIC;
    else if (has_ci(name, "rockstar") || has_ci(name, "socialclub"))
        g->launcher = NP_LAUNCHER_ROCKSTAR;
}

static void walk(np_game_t *g, const char *dir, int depth, int *entries) {
    if (depth > NP_SCAN_DEPTH || *entries >= NP_SCAN_ENTRIES) return;
    DIR *d = opendir(dir);
    if (!d) return;
    for (struct dirent *e; (e = readdir(d)) && *entries < NP_SCAN_ENTRIES; ) {
        if (e->d_name[0] == '.') continue;
        (*entries)++;
        note(g, e->d_name);
        size_t n = strlen(e->d_name);
        // A macOS app bundle next to the Windows files is the game's native build.
        if (n > 4 && strcasecmp(e->d_name + n - 4, ".app") == 0) { g->native = 1; continue; }
        char path[PATH_MAX];
        struct stat sb;
        if ((size_t)snprintf(path, sizeof path, "%s/%s", dir, e->d_name) >= sizeof path) continue;
        if (stat(path, &sb) == 0 && S_ISDIR(sb.st_mode)) walk(g, path, depth + 1, entries);
    }
    closedir(d);
}

int np_game_scan(const char *install_dir, np_game_t *out) {
    if (!out) return 0;
    memset(out, 0, sizeof *out);
    struct stat sb;
    if (!install_dir || stat(install_dir, &sb) != 0 || !S_ISDIR(sb.st_mode)) return 0;
    int entries = 0;
    walk(out, install_dir, 1, &entries);
    out->scanned = 1;
    NP_DBG("game: %s: anti-cheat %s, launcher %s%s", install_dir,
           np_game_anticheat_name(out->anticheat), np_game_launcher_name(out->launcher),
           out->native ? ", native build" : "");
    return 1;
}

const char *np_game_anticheat_name(np_anticheat_t a) {
    switch (a) {
        case NP_AC_EASYANTICHEAT: return "Easy Anti-Cheat";
        case NP_AC_BATTLEYE:      return "BattlEye";
        case NP_AC_VANGUARD:      return "Vanguard";
        default:                  return "";
    }
}

const char *np_game_launcher_name(np_launcher_t l) {
    switch (l) {
        case NP_LAUNCHER_EA:       return "the EA app";
        case NP_LAUNCHER_UBISOFT:  return "Ubisoft Connect";
        case NP_LAUNCHER_EPIC:     return "the Epic Games launcher";
        case NP_LAUNCHER_ROCKSTAR: return "the Rockstar launcher";
        default:                   return "";
    }
}
