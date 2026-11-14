// Mac, game and history in; settings, launch arguments and a badge out.
//
// The Mac decides how much work the GPU is given (tuning.c). The game decides which
// translation layer can carry it at all, which is what the rules below are about. The
// history decides whether this Mac has actually seen it run, which is the only thing that
// earns a green badge: everything else here is a reason something might not work, never a
// promise that it will.
#include "advice.h"
#include "tuning.h"

#include <stdio.h>
#include <string.h>

// DXMT translates Direct3D 11. D3DMetal is what carries Direct3D 12, and CrossOver only
// builds it for the Rosetta runner, so a D3D12 game on FEX has nothing to run on.
#define NP_D3D12_NEEDS "d3dmetal"

static void set_line(char *text, size_t size, const char *key, const char *value) {
    char want[64];
    int n = snprintf(want, sizeof want, "%s=", key);
    if (n < 0 || (size_t)n >= sizeof want) return;
    // Replace the line the Mac's own set wrote, so the game has the last word on it.
    for (char *at = text; *at; ) {
        char *nl = strchr(at, '\n');
        size_t len = nl ? (size_t)(nl - at) : strlen(at);
        if (len > (size_t)n && strncmp(at, want, (size_t)n) == 0) {
            char rest[NP_DEFAULTS_TEXT_MAX + 1];
            snprintf(rest, sizeof rest, "%s", nl ? nl + 1 : "");
            if ((size_t)snprintf(at, size - (size_t)(at - text), "%s%s\n%s", want, value, rest)
                >= size - (size_t)(at - text))
                *at = '\0';
            return;
        }
        at += len + (nl ? 1 : 0);
    }
    size_t at = strlen(text);
    snprintf(text + at, size - at, "%s%s\n", want, value);
}

static void add_option(np_advice_t *a, const char *option) {
    size_t at = strlen(a->options);
    snprintf(a->options + at, sizeof a->options - at, "%s%s", at ? " " : "", option);
}

static void say(np_advice_t *a, const char *text) {
    snprintf(a->reason, sizeof a->reason, "%s", text);
}

// Which translation layer the game's own graphics API needs. Returns NULL to leave the
// Mac's choice standing, which is what a game that asks for nothing in particular gets.
static const char *backend_for(const np_game_t *g) {
    if (!g || !g->scanned || !g->gfx) return NULL;
    // Vulkan and OpenGL are not Direct3D: nothing here translates them, and CrossOver's
    // own handling is better than a backend picked on a guess.
    if (!(g->gfx & (NP_GFX_D3D9 | NP_GFX_D3D11 | NP_GFX_D3D12))) return NULL;
    if (g->gfx & NP_GFX_D3D12) return NP_D3D12_NEEDS;
    if (g->gfx & NP_GFX_D3D11) return "dxmt";
    // Direct3D 9 predates DXMT, and DXVK has carried it for years.
    return "dxvk";
}

void np_advice(const np_machine_t *machine, const np_game_t *game, const np_verdict_t *history,
               uint32_t runner, np_advice_t *out) {
    if (!out) return;
    memset(out, 0, sizeof *out);
    if (!np_tuning_recommend(machine, runner, out->settings, sizeof out->settings))
        out->settings[0] = '\0';

    const int fex = runner == NP_DEFAULTS_FEX;
    const int scanned = game && game->scanned;
    const unsigned gfx = scanned ? game->gfx : 0;
    const char *backend = backend_for(game);
    const int d3d12_on_fex = fex && backend && strcmp(backend, NP_D3D12_NEEDS) == 0;

    if (backend && !d3d12_on_fex) {
        set_line(out->settings, sizeof out->settings, "CX_GRAPHICS_BACKEND", backend);
        // MetalFX upscaling and the frame cap are DXMT's own settings, so a game on
        // another backend has no use for the lines the Mac's set wrote for them.
        if (strcmp(backend, "dxmt") != 0) {
            set_line(out->settings, sizeof out->settings, "DXMT_METALFX_SPATIAL_SWAPCHAIN", "0");
            char *at = strstr(out->settings, "DXMT_CONFIG=");
            if (at && (at == out->settings || at[-1] == '\n')) {
                char *nl = strchr(at, '\n');
                memmove(at, nl ? nl + 1 : "", nl ? strlen(nl + 1) + 1 : 1);
            }
        }
    }

    // Unity's Direct3D 11 renderer is the same game, so a Unity title that came up on
    // D3D12 is asked for the path that DXMT can actually carry.
    if (scanned && game->engine == NP_ENGINE_UNITY && (gfx & NP_GFX_D3D12)) {
        add_option(out, "-force-d3d11");
        set_line(out->settings, sizeof out->settings, "CX_GRAPHICS_BACKEND", "dxmt");
    }

    // The badge, most serious first. Anything that cannot work here outranks anything
    // this Mac has seen work.
    if (scanned && game->anticheat != NP_AC_NONE) {
        out->badge = NP_BADGE_BLOCKED;
        snprintf(out->reason, sizeof out->reason,
                 "This game uses %s, which does not run under CrossOver on macOS.",
                 np_game_anticheat_name(game->anticheat));
    } else if (history && history->tier == NP_VERDICT_BROKEN) {
        out->badge = NP_BADGE_BLOCKED;
        snprintf(out->reason, sizeof out->reason,
                 "This game has crashed every time it was started on this Mac (%d of %d).",
                 history->failed, history->failed);
    } else if (d3d12_on_fex) {
        out->badge = NP_BADGE_ISSUES;
        say(out, "This game needs Direct3D 12, which only the Rosetta runner has. "
                 "Switch its compatibility tool away from FEX.");
    } else if (scanned && game->launcher != NP_LAUNCHER_NONE) {
        out->badge = NP_BADGE_ISSUES;
        snprintf(out->reason, sizeof out->reason,
                 "This game starts through %s, which may need setting up inside the prefix "
                 "before the game itself will run.", np_game_launcher_name(game->launcher));
    } else if (history && history->tier == NP_VERDICT_PLAYABLE && history->failed) {
        out->badge = NP_BADGE_ISSUES;
        snprintf(out->reason, sizeof out->reason,
                 "This game runs on this Mac, but %d of its %d sessions here crashed.",
                 history->failed, history->failed + history->healthy);
    } else if (history && history->tier == NP_VERDICT_VERIFIED) {
        out->badge = NP_BADGE_GOOD;
        snprintf(out->reason, sizeof out->reason,
                 "This game has run on this Mac %d times without crashing.", history->healthy);
    } else if (scanned && game->native) {
        out->badge = NP_BADGE_GOOD;
        say(out, "This game has a native macOS version, which Steam runs without CrossOver.");
    } else {
        out->badge = NP_BADGE_UNKNOWN;
        if (scanned && gfx)
            snprintf(out->reason, sizeof out->reason,
                     "This game has not run on this Mac yet. It is set up for %s.",
                     gfx & NP_GFX_D3D12 ? "Direct3D 12, through D3DMetal"
                   : gfx & NP_GFX_D3D11 ? "Direct3D 11, through DXMT"
                   : gfx & NP_GFX_D3D9  ? "Direct3D 9, through DXVK"
                   : gfx & NP_GFX_VULKAN ? "Vulkan, through MoltenVK" : "OpenGL");
        else
            say(out, "This game has not run on this Mac yet.");
    }
}

np_badge_t np_advice_from_valve(int mac, int deck, int anticheat, char *reason, size_t size) {
    // An anti-cheat that refuses Proton refuses Wine whoever built it, so this is the one
    // of Valve's results that carries over to CrossOver unchanged, and it outranks a
    // macOS build the page still lists.
    if (anticheat) {
        snprintf(reason, size, "Valve's testing found this game's anti-cheat does not support "
                               "Proton, so it will not run under CrossOver either.");
        return NP_BADGE_BLOCKED;
    }
    if (mac) {
        snprintf(reason, size, "This game has a native macOS version, which Steam runs without CrossOver.");
        return NP_BADGE_GOOD;
    }
    switch (deck) {
        case NP_DECK_VERIFIED:
            snprintf(reason, size, "Verified on Steam Deck through Proton, which is a good sign for "
                                   "CrossOver. It has not run on this Mac yet.");
            return NP_BADGE_LIKELY;
        case NP_DECK_PLAYABLE:
            snprintf(reason, size, "Playable on Steam Deck through Proton, which is a good sign for "
                                   "CrossOver. It has not run on this Mac yet.");
            return NP_BADGE_LIKELY;
        case NP_DECK_UNSUPPORTED:
            snprintf(reason, size, "Valve marks this game unsupported on Steam Deck, so it may not "
                                   "run under CrossOver. It has not run on this Mac yet.");
            return NP_BADGE_ISSUES;
        default:
            snprintf(reason, size, "This game has not run on this Mac yet, and Valve has not tested it.");
            return NP_BADGE_UNKNOWN;
    }
}

const char *np_badge_name(np_badge_t badge) {
    switch (badge) {
        case NP_BADGE_LIKELY:  return "likely";
        case NP_BADGE_GOOD:    return "good";
        case NP_BADGE_ISSUES:  return "issues";
        case NP_BADGE_BLOCKED: return "blocked";
        default:               return "unknown";
    }
}
