// What an installed game's folder says about it.
#ifndef NOTPROTON_FEATS_GAME_H
#define NOTPROTON_FEATS_GAME_H

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

typedef struct {
    int            scanned;   // the folder was there and could be read
    int            native;    // it ships a macOS app bundle of its own
    np_anticheat_t anticheat;
    np_launcher_t  launcher;
} np_game_t;

// Returns 0 and leaves out empty when there is no folder to read.
int np_game_scan(const char *install_dir, np_game_t *out);

// For the badge's reason and the log. Empty for none.
const char *np_game_anticheat_name(np_anticheat_t a);
const char *np_game_launcher_name(np_launcher_t l);

#endif // NOTPROTON_FEATS_GAME_H
