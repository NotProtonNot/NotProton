// A Mac badge for every installed game, for the library.
#ifndef NOTPROTON_FEATS_CATALOG_H
#define NOTPROTON_FEATS_CATALOG_H

// Walks the installed games and saves a badge for each. Returns how many were looked at.
int np_catalog_refresh(const char *steam_root);

// np_catalog_refresh on a thread of its own.
void np_catalog_refresh_async(const char *steam_root);

// The saved badges as a JS object literal, {appid:["tier","reason"],...}, or NULL.
char *np_catalog_map(void);

// The script the library is given: the map and the on/off switch. NULL when there is
// nothing to show. The caller frees it.
char *np_catalog_javascript(const char *steam_root);

// Turns the badges on or off, kept as a file in the support folder.
int np_catalog_set_enabled(int on);

#endif // NOTPROTON_FEATS_CATALOG_H
