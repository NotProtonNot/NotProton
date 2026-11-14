// Mac compatibility on Steam's store and wishlist pages.
#ifndef NOTPROTON_FEATS_STORE_H
#define NOTPROTON_FEATS_STORE_H

#include <stddef.h>
#include <stdint.h>

// The store is Valve's page, served from the network, so nothing NotProton patches on
// disk reaches it. What does reach it is the debugger built into Steam's web helper: the
// helper is started with it listening on this machine only, and a thread here uses it to
// keep one script registered on the store's pages.
//
// That port is open to anything running on this Mac for as long as Steam is, which is why
// the store has a switch of its own, apart from the one for the badges in the library.
#define NP_STORE_PORT 27101

// Whether the store's pages get the block. Off when either switch is: the store's own
// (the "no-store-badges" file) or the one for every badge ("no-mac-badges").
int np_store_enabled(void);

// The store's own switch alone, whatever the one for every badge says. For the row in
// Preferences, which shows what was chosen rather than what follows from it.
int np_store_switch(void);

// Keeps the store's own switch. Takes effect when Steam next starts, since the port is
// decided when the web helper is.
int np_store_set_enabled(int on);

// The helper's arguments with the debugger's two added, or NULL when they are not
// wanted: the store is off, this is not the helper's own process (its renderers and the
// like carry --type=), or the port is already asked for. The caller frees the array, not
// the strings in it.
char **np_store_helper_args(const char *path, char *const argv[]);

// Starts the thread that keeps the script on the store's pages. Once per process.
void np_store_start(void);

// --- the parts with nothing to do with a socket, exposed for the checks ---

// One masked WebSocket text frame. Returns its length, or 0 when it does not fit.
size_t np_store_frame(const char *text, size_t n, const uint8_t mask[4], uint8_t *out, size_t cap);

// Whether a debugger target is one of the store's pages.
int np_store_wants(const char *type, const char *url);

// The page script with the catalogue's map in the one place that takes it. NULL when the
// script does not name that place exactly once. The caller frees it.
char *np_store_script(const char *page, const char *map);

#endif // NOTPROTON_FEATS_STORE_H
