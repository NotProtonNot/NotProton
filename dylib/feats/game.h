// What a game is, read from the files Steam installed.
#ifndef NOTPROTON_FEATS_GAME_H
#define NOTPROTON_FEATS_GAME_H

#include <stddef.h>

#define NP_GAME_NAME_MAX 48
#define NP_GAME_PATH_MAX 1024

// Graphics APIs the executable asks for, by import or by the name it loads at runtime.
#define NP_GFX_D3D9   (1u << 0)
#define NP_GFX_D3D11  (1u << 1)
#define NP_GFX_D3D12  (1u << 2)
#define NP_GFX_DXGI   (1u << 3)
#define NP_GFX_VULKAN (1u << 4)
#define NP_GFX_OPENGL (1u << 5)

typedef enum {
    NP_AC_NONE = 0,
    NP_AC_EASYANTICHEAT,
    NP_AC_BATTLEYE,
    NP_AC_VANGUARD,
} np_anticheat_t;

typedef enum {
    NP_LAUNCHER_NONE = 0,
    NP_LAUNCHER_EA,
    NP_LAUNCHER_UBISOFT,
    NP_LAUNCHER_EPIC,
    NP_LAUNCHER_ROCKSTAR,
} np_launcher_t;

typedef enum {
    NP_ENGINE_NONE = 0,
    NP_ENGINE_UNREAL,
    NP_ENGINE_UNITY,
} np_engine_t;

typedef struct {
    int            scanned;                 // the install was there and could be read
    int            native;                  // it ships a macOS app bundle of its own
    char           exe[NP_GAME_PATH_MAX];   // the executable the rest of this was read from
    int            bits;                    // 32 or 64, 0 when no PE header was read
    unsigned       gfx;                     // NP_GFX_*
    np_anticheat_t anticheat;
    np_launcher_t  launcher;
    np_engine_t    engine;
} np_game_t;

// Reads the install folder. Returns 0 and leaves `out` empty when there is nothing to
// read, which is a game that is not installed rather than a game that will not run.
int np_game_scan(const char *install_dir, np_game_t *out);

// For the page and the log. Empty strings for none.
const char *np_game_anticheat_name(np_anticheat_t a);
const char *np_game_launcher_name(np_launcher_t l);
const char *np_game_engine_name(np_engine_t e);

#endif // NOTPROTON_FEATS_GAME_H
