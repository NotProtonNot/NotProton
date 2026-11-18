// The badge each game gets, most serious first.
#include "../feats/badge.c"

#include <stdio.h>
#include <string.h>

int np_log_level = 0;
FILE *np_log_file = NULL;

static int failures;

static void check(int ok, const char *what) {
    printf("  %s  %s\n", ok ? "ok  " : "FAIL", what);
    if (!ok) failures++;
}

static np_game_t game(void) {
    np_game_t g = { 0 };
    g.scanned = 1;
    return g;
}

int main(void) {
    char why[256];
    np_verdict_t ran = { NP_VERDICT_VERIFIED, 9, 0, 300, "healthy", "26.3", "dxmt" };
    np_verdict_t rough = { NP_VERDICT_PLAYABLE, 3, 2, 100, "healthy", "26.3", "dxmt" };
    np_verdict_t dead = { NP_VERDICT_BROKEN, 0, 4, 2, "failed", "26.3", "dxmt" };
    np_verdict_t once = { NP_VERDICT_PLAYABLE, 1, 0, 45, "healthy", "26.3", "dxmt" };

    printf("== what this Mac has seen ==\n");
    np_game_t g = game();
    check(np_badge_for(&g, &ran, why, sizeof why) == NP_BADGE_GOOD, "clean runs here are good");
    check(strstr(why, "9 times") != NULL, "and the reason counts them");
    check(np_badge_for(&g, &rough, why, sizeof why) == NP_BADGE_ISSUES, "crashes here are issues");
    check(strstr(why, "2 of its 5") != NULL, "and the reason counts both");
    check(np_badge_for(&g, &dead, why, sizeof why) == NP_BADGE_BLOCKED, "only crashes here is blocked");
    // One clean session is not yet enough to call it verified.
    check(np_badge_for(&g, &once, why, sizeof why) == NP_BADGE_UNKNOWN, "a single clean run is still unknown");

    printf("== what the folder says ==\n");
    np_game_t eac = game();
    eac.anticheat = NP_AC_EASYANTICHEAT;
    check(np_badge_for(&eac, NULL, why, sizeof why) == NP_BADGE_BLOCKED, "an anti-cheat is blocked");
    check(strstr(why, "Easy Anti-Cheat") != NULL, "and the reason names it");
    check(np_badge_for(&eac, &ran, why, sizeof why) == NP_BADGE_BLOCKED, "even over a clean history");
    np_game_t ubi = game();
    ubi.launcher = NP_LAUNCHER_UBISOFT;
    check(np_badge_for(&ubi, NULL, why, sizeof why) == NP_BADGE_ISSUES, "a launcher is issues");
    check(strstr(why, "Ubisoft Connect") != NULL, "and the reason names it");
    np_game_t native = game();
    native.native = 1;
    check(np_badge_for(&native, NULL, why, sizeof why) == NP_BADGE_GOOD, "a native build is good");

    printf("== nothing known ==\n");
    np_game_t plain = game();
    check(np_badge_for(&plain, NULL, why, sizeof why) == NP_BADGE_UNKNOWN, "a game never run here is unknown");
    check(strcmp(why, "This game has not run on this Mac yet.") == 0, "and says so");
    check(np_badge_for(NULL, NULL, why, sizeof why) == NP_BADGE_UNKNOWN, "no game at all is unknown");

    printf("== names ==\n");
    check(!strcmp(np_badge_name(NP_BADGE_GOOD), "good") && !strcmp(np_badge_name(NP_BADGE_ISSUES), "issues")
          && !strcmp(np_badge_name(NP_BADGE_BLOCKED), "blocked") && !strcmp(np_badge_name(NP_BADGE_UNKNOWN), "unknown"),
          "each badge has the name the page uses");

    printf(failures ? "==> badge-check: %d failure(s)\n" : "==> badge-check: every game gets one badge\n", failures);
    return failures ? 1 : 0;
}
