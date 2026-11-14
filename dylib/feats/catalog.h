// A badge for every installed game, for the library's tiles.
#ifndef NOTPROTON_FEATS_CATALOG_H
#define NOTPROTON_FEATS_CATALOG_H

#include <stddef.h>

// "window.__NOTPROTON_COMPAT__={...};\n", from the badges worked out on the last pass.
// NULL when there are none to show, which leaves every tile as Steam drew it. The caller
// owns the string.
//
// This reads what was saved, never the games themselves: the library opens at the speed
// of one small file, and np_catalog_refresh brings the file up to date behind it.
char *np_catalog_javascript(const char *steam_root);

// Walks the installed games, scans the ones whose install changed, and saves the badges
// for the next time the library opens. Also leaves each game's advice beside its prefix,
// where the run script picks it up. Returns how many games were looked at.
int np_catalog_refresh(const char *steam_root);

// Runs np_catalog_refresh once on a thread of its own.
void np_catalog_refresh_async(const char *steam_root);

// The saved badges as a JavaScript object literal, or NULL. The caller frees it.
char *np_catalog_map(void);

// Turns the badges on or off for good, by way of a file in the support folder that the
// library and the store agent both read. Returns 0 when the choice could not be kept.
int np_catalog_set_enabled(int on);

#endif // NOTPROTON_FEATS_CATALOG_H
