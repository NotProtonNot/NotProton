// Signature database loader
#ifndef NOTPROTON_RESOLVER_SIGDB_H
#define NOTPROTON_RESOLVER_SIGDB_H

#include <stdint.h>
#include <stddef.h>
#include "anchor.h"

#define NP_MODULE_DEFAULT "steamclient.dylib"

typedef struct {
    char        name[128];
    char        module[64];
    char        aob_hex[4096];
    uintptr_t   func_addr_this_build;
    int         deprecated;
    int32_t     match_offset;   // signed delta from the pattern hit to the entry point
    np_anchor_t anchor;
} np_sig_entry_t;

// A loaded signature database targeting a specific Steam client build.
typedef struct {
    np_sig_entry_t *signatures;
    int             sig_count;
    int             schema_version;
    int             sigdb_version;
    uint64_t        steam_build;
    char            steam_build_date[32];
} np_sigdb_t;

int  np_load_profile(const char *path, np_sigdb_t *out);
void np_free_profile(np_sigdb_t *p);

#endif // NOTPROTON_RESOLVER_SIGDB_H
