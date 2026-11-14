// The recommended settings: that they say what the hardware asks for, and that every line
// is one the defaults whitelist would accept, since the page saves them through it.
#include "../feats/defaults.c"
#include "../feats/tuning.c"

#include <stdio.h>
#include <string.h>

int np_log_level = 0;
FILE *np_log_file = NULL;

static int failures;

static void check(int ok, const char *what) {
    printf("  %s  %s\n", ok ? "ok  " : "FAIL", what);
    if (!ok) failures++;
}

// Each line has to pass the same validation the Settings page saves through, or applying
// the recommendation would write a file the dylib then refuses to read back.
static int whitelisted(const char *text, uint32_t runner) {
    for (const char *at = text; *at; ) {
        const char *nl = strchr(at, '\n');
        size_t n = nl ? (size_t)(nl - at) : strlen(at);
        const char *eq = memchr(at, '=', n);
        if (!eq) return 0;
        int i = setting_index(runner, at, (size_t)(eq - at));
        if (i < 0 || !valid_value((size_t)i, runner, eq + 1, n - (size_t)(eq - at) - 1)) return 0;
        at += n + (nl ? 1 : 0);
    }
    return 1;
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

static np_machine_t mac(const char *chip, int gpu, unsigned ram, int macos, int w, int h, int hz) {
    np_machine_t m = { 0 };
    m.apple_silicon = 1;
    snprintf(m.chip, sizeof m.chip, "%s", chip);
    m.gpu_cores = gpu;
    m.cpu_cores = 10;
    m.ram_gb = ram;
    m.macos_major = macos;
    m.display_w = w;
    m.display_h = h;
    m.refresh_hz = hz;
    return m;
}

int main(void) {
    char out[NP_DEFAULTS_TEXT_MAX + 1];

    // A 40-core Max fills a 16" panel on its own, so nothing is traded away for it.
    np_machine_t max = mac("Apple M4 Max", 40, 64, 27, 3456, 2234, 120);
    check(np_tuning_recommend(&max, NP_DEFAULTS_ROSETTA, out, sizeof out), "M4 Max: recommends");
    check(whitelisted(out, NP_DEFAULTS_ROSETTA), "M4 Max: every line is on the whitelist");
    check(says(out, "CX_GRAPHICS_BACKEND", "dxmt"), "M4 Max: DXMT");
    check(says(out, "NOTPROTON_RETINA", "1"), "M4 Max: Retina on");
    check(says(out, "WINEMSYNC", "1"), "M4 Max: msync on");
    check(says(out, "MTL_HUD_ENABLED", "0"), "M4 Max: HUD off");
    check(says(out, "DXMT_METALFX_SPATIAL_SWAPCHAIN", "0"), "M4 Max: no upscaling");
    check(says(out, "DXMT_CONFIG", "d3d11.preferredMaxFrameRate=120"), "M4 Max: capped at 120 Hz");
    check(says(out, "ROSETTA_ADVERTISE_AVX", "1"), "M4 Max: AVX2 advertised on macOS 27");

    // A base M1 on a 13" panel is the other end: the most upscaling, capped at 60.
    np_machine_t base = mac("Apple M1", 8, 16, 26, 2560, 1600, 60);
    check(np_tuning_recommend(&base, NP_DEFAULTS_ROSETTA, out, sizeof out), "M1: recommends");
    check(whitelisted(out, NP_DEFAULTS_ROSETTA), "M1: every line is on the whitelist");
    check(says(out, "DXMT_METALFX_SPATIAL_SWAPCHAIN", "1"), "M1: upscaling on");
    check(says(out, "DXMT_CONFIG",
               "d3d11.metalSpatialUpscaleFactor=1.72;d3d11.preferredMaxFrameRate=60"),
          "M1: 1.72x at 60 Hz");

    // 8 GB is shared with the GPU, so the same part on the same panel steps up a band.
    np_machine_t tight = mac("Apple M1", 8, 8, 26, 2560, 1600, 60);
    check(np_tuning_recommend(&tight, NP_DEFAULTS_ROSETTA, out, sizeof out), "M1 8 GB: recommends");
    check(says(out, "DXMT_CONFIG",
               "d3d11.metalSpatialUpscaleFactor=2.0;d3d11.preferredMaxFrameRate=60"),
          "M1 8 GB: 2x at 60 Hz");

    // A base chip on a 5K panel asks for the most help the whitelist offers.
    np_machine_t dense = mac("Apple M4", 10, 16, 26, 5120, 2880, 60);
    check(np_tuning_recommend(&dense, NP_DEFAULTS_ROSETTA, out, sizeof out), "5K: recommends");
    check(says(out, "DXMT_CONFIG",
               "d3d11.metalSpatialUpscaleFactor=2.0;d3d11.preferredMaxFrameRate=60"),
          "5K: 2x at 60 Hz");

    // FEX has no D3DMetal and no Rosetta, and runs the reduced x87 precision CrossOver
    // Preview defaults to.
    check(np_tuning_recommend(&max, NP_DEFAULTS_FEX, out, sizeof out), "FEX: recommends");
    check(whitelisted(out, NP_DEFAULTS_FEX), "FEX: every line is on the whitelist");
    check(says(out, "FEX_X87REDUCEDPRECISION", "1"), "FEX: reduced x87 precision");
    check(!value_of(out, "ROSETTA_ADVERTISE_AVX"), "FEX: nothing about Rosetta");

    // Rosetta advertises AVX2 from macOS 15 on, so older releases are left alone.
    np_machine_t old = mac("Apple M1", 8, 16, 14, 2560, 1600, 60);
    check(np_tuning_recommend(&old, NP_DEFAULTS_ROSETTA, out, sizeof out), "macOS 14: recommends");
    check(!value_of(out, "ROSETTA_ADVERTISE_AVX"), "macOS 14: no AVX2 flag");

    // An Intel Mac has neither DXMT nor D3DMetal worth taking, and no dense panel to feed.
    np_machine_t intel = mac("Intel Core i9", 0, 32, 26, 2880, 1800, 60);
    intel.apple_silicon = 0;
    check(np_tuning_recommend(&intel, NP_DEFAULTS_ROSETTA, out, sizeof out), "Intel: recommends");
    check(whitelisted(out, NP_DEFAULTS_ROSETTA), "Intel: every line is on the whitelist");
    check(says(out, "CX_GRAPHICS_BACKEND", "dxvk"), "Intel: DXVK");
    check(says(out, "NOTPROTON_RETINA", "0"), "Intel: Retina off");
    check(!value_of(out, "DXMT_CONFIG"), "Intel: nothing for DXMT");
    check(!value_of(out, "DXMT_METALFX_SPATIAL_SWAPCHAIN"), "Intel: no upscaling row");

    // No window server, so no display to size: the backend stands, the trade does not.
    np_machine_t headless = mac("Apple M4 Max", 40, 64, 27, 0, 0, 0);
    check(np_tuning_recommend(&headless, NP_DEFAULTS_ROSETTA, out, sizeof out), "No display: recommends");
    check(whitelisted(out, NP_DEFAULTS_ROSETTA), "No display: every line is on the whitelist");
    check(says(out, "DXMT_METALFX_SPATIAL_SWAPCHAIN", "0"), "No display: no upscaling");
    check(!value_of(out, "DXMT_CONFIG"), "No display: no frame cap");

    // A probe that read nothing at all still has to produce a set that saves.
    np_machine_t nothing = { 0 };
    check(np_tuning_recommend(&nothing, NP_DEFAULTS_ROSETTA, out, sizeof out), "Unknown Mac: recommends");
    check(whitelisted(out, NP_DEFAULTS_ROSETTA), "Unknown Mac: every line is on the whitelist");

    // A refusal leaves nothing half-written behind for a caller to save.
    check(!np_tuning_recommend(&max, 7, out, sizeof out) && !out[0], "Bad runner: refused, out empty");
    check(!np_tuning_recommend(NULL, NP_DEFAULTS_ROSETTA, out, sizeof out) && !out[0],
          "No machine: refused, out empty");
    char tiny[8];
    check(!np_tuning_recommend(&max, NP_DEFAULTS_ROSETTA, tiny, sizeof tiny) && !tiny[0],
          "No room: refused, out empty");

    printf(failures ? "==> tuning-check: %d failure(s)\n" : "==> tuning-check: all good\n", failures);
    return failures ? 1 : 0;
}
