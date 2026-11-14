// The one answer per game: which backend the game's own API needs, what gets said about
// it, and that the hardware's set is still underneath.
#include "../feats/advice.c"

#include <stdio.h>
#include <string.h>

int np_log_level = 0;
FILE *np_log_file = NULL;

static int failures;

static void check(int ok, const char *what) {
    printf("  %s  %s\n", ok ? "ok  " : "FAIL", what);
    if (!ok) failures++;
}

static const char *value_of(const char *text, const char *key) {
    static char value[256];
    size_t klen = strlen(key);
    for (const char *at = text; *at; ) {
        const char *nl = strchr(at, '\n');
        size_t n = nl ? (size_t)(nl - at) : strlen(at);
        if (n > klen && at[klen] == '=' && strncmp(at, key, klen) == 0) {
            size_t vlen = n - klen - 1;
            if (vlen >= sizeof value) vlen = sizeof value - 1;
            memcpy(value, at + klen + 1, vlen);
            value[vlen] = '\0';
            return value;
        }
        at += n + (nl ? 1 : 0);
    }
    return NULL;
}

static int says(const char *text, const char *key, const char *want) {
    const char *got = value_of(text, key);
    return got && strcmp(got, want) == 0;
}

static np_machine_t this_mac(void) {
    np_machine_t m = { 0 };
    m.apple_silicon = 1;
    snprintf(m.chip, sizeof m.chip, "Apple M4 Max");
    m.gpu_cores = 40;
    m.ram_gb = 64;
    m.macos_major = 27;
    m.display_w = 3456;
    m.display_h = 2234;
    m.refresh_hz = 120;
    return m;
}

static np_game_t game(unsigned gfx) {
    np_game_t g = { 0 };
    g.scanned = 1;
    g.bits = 64;
    g.gfx = gfx;
    return g;
}

int main(void) {
    const np_machine_t m = this_mac();
    np_advice_t a;

    printf("== the backend the game needs ==\n");
    np_game_t d3d11 = game(NP_GFX_D3D11 | NP_GFX_DXGI);
    np_advice(&m, &d3d11, NULL, NP_DEFAULTS_ROSETTA, &a);
    check(says(a.settings, "CX_GRAPHICS_BACKEND", "dxmt"), "Direct3D 11 goes to DXMT");
    check(says(a.settings, "WINEMSYNC", "1"), "and the Mac's own set is still underneath");

    np_game_t d3d12 = game(NP_GFX_D3D12 | NP_GFX_DXGI);
    np_advice(&m, &d3d12, NULL, NP_DEFAULTS_ROSETTA, &a);
    check(says(a.settings, "CX_GRAPHICS_BACKEND", "d3dmetal"), "Direct3D 12 goes to D3DMetal");
    // Those two are DXMT's own, and DXMT is not what is running the game.
    check(says(a.settings, "DXMT_METALFX_SPATIAL_SWAPCHAIN", "0"), "with DXMT's upscaling off");
    check(!value_of(a.settings, "DXMT_CONFIG"), "and DXMT's own config dropped");

    np_game_t d3d9 = game(NP_GFX_D3D9);
    np_advice(&m, &d3d9, NULL, NP_DEFAULTS_ROSETTA, &a);
    check(says(a.settings, "CX_GRAPHICS_BACKEND", "dxvk"), "Direct3D 9 goes to DXVK");

    // A game that asks for neither keeps whatever the Mac was going to run.
    np_game_t vulkan = game(NP_GFX_VULKAN);
    np_advice(&m, &vulkan, NULL, NP_DEFAULTS_ROSETTA, &a);
    check(says(a.settings, "CX_GRAPHICS_BACKEND", "dxmt"), "Vulkan leaves the backend alone");
    np_game_t unread = { 0 };
    np_advice(&m, &unread, NULL, NP_DEFAULTS_ROSETTA, &a);
    check(says(a.settings, "CX_GRAPHICS_BACKEND", "dxmt"), "and so does a game never scanned");
    check(a.badge == NP_BADGE_UNKNOWN, "which the badge says nothing about");

    printf("== what the game's own files change ==\n");
    np_game_t unity = game(NP_GFX_D3D12 | NP_GFX_DXGI);
    unity.engine = NP_ENGINE_UNITY;
    np_advice(&m, &unity, NULL, NP_DEFAULTS_ROSETTA, &a);
    check(strcmp(a.options, "-force-d3d11") == 0, "a Unity game on D3D12 is asked for D3D11");
    check(says(a.settings, "CX_GRAPHICS_BACKEND", "dxmt"), "and then DXMT can carry it");

    // Unreal's D3D11 path is not the same game, so it is left on D3DMetal.
    np_game_t unreal = game(NP_GFX_D3D12 | NP_GFX_DXGI);
    unreal.engine = NP_ENGINE_UNREAL;
    np_advice(&m, &unreal, NULL, NP_DEFAULTS_ROSETTA, &a);
    check(!a.options[0], "an Unreal game on D3D12 is not forced anywhere");
    check(says(a.settings, "CX_GRAPHICS_BACKEND", "d3dmetal"), "it stays on D3DMetal");

    printf("== the badge ==\n");
    np_game_t eac = game(NP_GFX_D3D11);
    eac.anticheat = NP_AC_EASYANTICHEAT;
    np_verdict_t ran = { NP_VERDICT_VERIFIED, 9, 0, 300, "healthy", "26.3", "dxmt" };
    np_advice(&m, &eac, &ran, NP_DEFAULTS_ROSETTA, &a);
    check(a.badge == NP_BADGE_BLOCKED, "anti-cheat blocks the game");
    check(strstr(a.reason, "Easy Anti-Cheat") != NULL, "and the reason names it");
    check(strstr(a.reason, "does not run") != NULL, "in a sentence that says what that means");

    // D3D12 has nothing to run on under FEX, which is the game's problem on that runner only.
    np_advice(&m, &d3d12, NULL, NP_DEFAULTS_FEX, &a);
    check(a.badge == NP_BADGE_ISSUES, "Direct3D 12 under FEX is a problem");
    check(strstr(a.reason, "Rosetta") != NULL, "and the reason says where to go");
    check(!says(a.settings, "CX_GRAPHICS_BACKEND", "d3dmetal"),
          "FEX is not told to use a backend it does not have");

    np_game_t ubi = game(NP_GFX_D3D11);
    ubi.launcher = NP_LAUNCHER_UBISOFT;
    np_advice(&m, &ubi, NULL, NP_DEFAULTS_ROSETTA, &a);
    check(a.badge == NP_BADGE_ISSUES, "a game behind a launcher has something in the way");
    check(strstr(a.reason, "Ubisoft Connect") != NULL, "and the reason names the launcher");

    np_advice(&m, &d3d11, &ran, NP_DEFAULTS_ROSETTA, &a);
    check(a.badge == NP_BADGE_GOOD, "a game this Mac has run clean is good");
    check(strstr(a.reason, "9 times") != NULL, "and the reason counts the runs");

    np_verdict_t rough = { NP_VERDICT_PLAYABLE, 3, 2, 100, "healthy", "26.3", "dxmt" };
    np_advice(&m, &d3d11, &rough, NP_DEFAULTS_ROSETTA, &a);
    check(a.badge == NP_BADGE_ISSUES, "a game that has crashed here has issues");
    check(strstr(a.reason, "2 of its 5") != NULL, "and the reason counts both");

    np_verdict_t dead = { NP_VERDICT_BROKEN, 0, 4, 2, "failed", "26.3", "dxmt" };
    np_advice(&m, &d3d11, &dead, NP_DEFAULTS_ROSETTA, &a);
    check(a.badge == NP_BADGE_BLOCKED, "a game that has only crashed here is blocked");

    // A clean history never outranks something that cannot work at all.
    np_advice(&m, &eac, &ran, NP_DEFAULTS_ROSETTA, &a);
    check(a.badge == NP_BADGE_BLOCKED, "anti-cheat outranks a clean history");

    np_game_t native = game(0);
    native.native = 1;
    np_advice(&m, &native, NULL, NP_DEFAULTS_ROSETTA, &a);
    check(a.badge == NP_BADGE_GOOD, "a game with a macOS build of its own is good");
    check(strstr(a.reason, "native macOS") != NULL, "and the reason says why");

    printf("== a game that is not installed ==\n");
    char why[NP_ADVICE_REASON_MAX];
    check(np_advice_from_valve(0, NP_DECK_VERIFIED, 0, why, sizeof why) == NP_BADGE_LIKELY,
          "verified on Proton is likely, not good");
    check(strstr(why, "has not run on this Mac") != NULL, "and the reason says it has not run here");
    check(np_advice_from_valve(0, NP_DECK_PLAYABLE, 0, why, sizeof why) == NP_BADGE_LIKELY,
          "playable on Proton is likely too");
    check(np_advice_from_valve(0, NP_DECK_UNSUPPORTED, 0, why, sizeof why) == NP_BADGE_ISSUES,
          "unsupported on Proton has issues");
    check(np_advice_from_valve(0, NP_DECK_UNKNOWN, 0, why, sizeof why) == NP_BADGE_UNKNOWN,
          "untested is unknown");
    check(np_advice_from_valve(1, NP_DECK_UNKNOWN, 0, why, sizeof why) == NP_BADGE_GOOD,
          "a macOS build is good");
    // An anti-cheat that refuses Proton refuses Wine, so it outranks everything else.
    check(np_advice_from_valve(1, NP_DECK_VERIFIED, 1, why, sizeof why) == NP_BADGE_BLOCKED,
          "a failed anti-cheat blocks it whatever else is true");
    check(strstr(why, "anti-cheat") != NULL, "and the reason names the anti-cheat");

    printf("== what a badge is called ==\n");
    check(strcmp(np_badge_name(NP_BADGE_LIKELY), "likely") == 0, "likely");
    check(strcmp(np_badge_name(NP_BADGE_GOOD), "good") == 0, "good");
    check(strcmp(np_badge_name(NP_BADGE_ISSUES), "issues") == 0, "issues");
    check(strcmp(np_badge_name(NP_BADGE_BLOCKED), "blocked") == 0, "blocked");
    check(strcmp(np_badge_name(NP_BADGE_UNKNOWN), "unknown") == 0, "unknown");

    printf(failures ? "==> advice-check: %d failure(s)\n" : "==> advice-check: every game gets one answer\n",
           failures);
    return failures ? 1 : 0;
}
