#include "tuning.h"
#include "defaults.h"

#include <stdio.h>
#include <string.h>

// An Apple GPU whose core count the registry did not carry is sized as a base part, so an
// unknown GPU is given the help a small one needs rather than the free ride a big one gets.
#define NP_TUNING_ASSUMED_CORES 10

// Pixels of the main display per GPU core, which is what decides how much of the frame the
// GPU renders itself and how much MetalFX upscales. The bands come out of what the parts
// are paired with: a 40-core Max driving a 16" panel sits near 190k and needs no help, a
// base chip on the same panel is near 770k and needs the most.
#define NP_TUNING_PPC_HEAVY   600000
#define NP_TUNING_PPC_MEDIUM  350000
#define NP_TUNING_PPC_LIGHT   200000

// Rosetta only advertises AVX2 from macOS 15, so asking for it on anything older sets a
// flag the translator ignores.
#define NP_TUNING_AVX_MACOS 15

// 8 GB is shared with the GPU and with Windows inside the prefix, so a machine with that
// much renders one band lower than its core count alone would ask for.
#define NP_TUNING_TIGHT_RAM_GB 8

typedef struct { char *buf; size_t size, len; int ok; } np_out_t;

static void line(np_out_t *o, const char *key, const char *value) {
    if (!o->ok) return;
    int n = snprintf(o->buf + o->len, o->size - o->len, "%s=%s\n", key, value);
    if (n < 0 || (size_t)n >= o->size - o->len) { o->ok = 0; return; }
    o->len += (size_t)n;
}

// The MetalFX factor for a panel this GPU has to fill, or NULL when it has it covered.
static const char *upscale_factor(const np_machine_t *m) {
    long pixels = (long)m->display_w * m->display_h;
    if (pixels <= 0) return NULL;  // no display to size: nothing to trade away
    int cores = m->gpu_cores > 0 ? m->gpu_cores : NP_TUNING_ASSUMED_CORES;
    long per = pixels / cores;
    if (m->ram_gb > 0 && m->ram_gb <= NP_TUNING_TIGHT_RAM_GB) per = per * 3 / 2;
    if (per > NP_TUNING_PPC_HEAVY) return "2.0";
    if (per > NP_TUNING_PPC_MEDIUM) return "1.72";
    if (per > NP_TUNING_PPC_LIGHT) return "1.5";
    return NULL;
}

// The highest rate the whitelist offers that the panel can still show. Rendering past the
// panel's refresh is heat and fan noise for frames nobody sees, and a rate below it is a
// cap the hardware did not ask for, so the match is exact or it is left unset.
static const char *frame_cap(int refresh_hz) {
    static const struct { int hz; const char *value; } caps[] = {
        { 144, "144" }, { 120, "120" }, { 60, "60" }, { 40, "40" }, { 30, "30" },
    };
    for (size_t i = 0; i < sizeof caps / sizeof caps[0]; i++)
        if (refresh_hz >= caps[i].hz) return caps[i].value;
    return NULL;
}

int np_tuning_recommend(const np_machine_t *m, uint32_t runner, char *out, size_t size) {
    if (!out || !size) return 0;
    out[0] = '\0';
    if (!m || runner > NP_DEFAULTS_FEX) return 0;

    np_out_t o = { out, size, 0, 1 };
    // DXMT is the D3D11 path both runners share and the only one FEX has. On an Intel Mac
    // neither it nor D3DMetal applies, which leaves DXVK over MoltenVK.
    const int dxmt = m->apple_silicon != 0;
    line(&o, "CX_GRAPHICS_BACKEND", dxmt ? "dxmt" : "dxvk");
    // msync is the fast path for the waits Windows games spend their frame on.
    line(&o, "WINEMSYNC", "1");
    // A HUD is a thing to turn on while looking into a game, not a thing to find on.
    line(&o, "MTL_HUD_ENABLED", "0");
    // Apple panels are dense, so the game is given their real pixels and MetalFX below
    // makes up the difference, which reads sharper than running the whole frame at 1x.
    line(&o, "NOTPROTON_RETINA", m->apple_silicon ? "1" : "0");

    if (runner == NP_DEFAULTS_ROSETTA) {
        if (m->macos_major >= NP_TUNING_AVX_MACOS) line(&o, "ROSETTA_ADVERTISE_AVX", "1");
    } else {
        // What CrossOver Preview itself runs with: the precision no game has asked for.
        line(&o, "FEX_X87REDUCEDPRECISION", "1");
    }

    if (dxmt) {
        const char *factor = upscale_factor(m);
        const char *fps = frame_cap(m->refresh_hz);
        char config[128] = "";
        size_t at = 0;
        if (factor)
            at += (size_t)snprintf(config + at, sizeof config - at,
                                   "d3d11.metalSpatialUpscaleFactor=%s", factor);
        if (fps)
            snprintf(config + at, sizeof config - at, "%sd3d11.preferredMaxFrameRate=%s",
                     at ? ";" : "", fps);
        line(&o, "DXMT_METALFX_SPATIAL_SWAPCHAIN", factor ? "1" : "0");
        if (config[0]) line(&o, "DXMT_CONFIG", config);
    }

    if (!o.ok) out[0] = '\0';
    return o.ok;
}
