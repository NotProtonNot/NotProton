// Signature resolver
#ifndef NOTPROTON_RESOLVER_RESOLVER_H
#define NOTPROTON_RESOLVER_RESOLVER_H

#include <stdint.h>
#include <stddef.h>
#include <mach-o/loader.h>
#include "sigdb.h"

typedef struct {
    const char *name;
    uintptr_t   site;
} np_resolved_t;

typedef struct {
    np_resolved_t *items;
    int            used;
    int            cap;
} np_resolve_result_t;

// True when the 32-bit value at `addr` looks like a common AArch64 prologue.
int np_looks_like_prologue(uintptr_t addr);

uintptr_t np_aob_site(const np_sig_entry_t *sig, uintptr_t text, size_t text_sz);

// Resolve the signatures in `sigdb` that name `module` against the live image at
// `mh`+`slide`. Entries belonging to another image are left out of `out`.
int np_resolve_signatures(const struct mach_header_64 *mh, intptr_t slide,
                      np_sigdb_t *sigdb, const char *module,
                      np_resolve_result_t *out);

int np_required_for_module(const np_sigdb_t *sigdb, const char *module);

uintptr_t np_lookup_address(const np_resolve_result_t *result, const char *name);
void      np_free_resolution(np_resolve_result_t *result);

#endif // NOTPROTON_RESOLVER_RESOLVER_H
