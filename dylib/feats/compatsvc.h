// CompatManager WebUI service.
#ifndef NOTPROTON_FEATS_COMPATSVC_H
#define NOTPROTON_FEATS_COMPATSVC_H

#include <stdint.h>
#include <stddef.h>
#include <mach-o/loader.h>

// Registers on first route lookup rather than at install time
void np_compatsvc_register(const struct mach_header_64 *mh, intptr_t slide,
                           uintptr_t text_base, size_t text_size);

// Whether the CompatManager routes are answering. UNTRIED is a route lookup that has
// not happened yet, which is not the same as a client that cannot serve them: the
// compat chunk can be served before anything asks the transport for a route.
enum {
    NP_COMPATSVC_UNTRIED = 0,
    NP_COMPATSVC_READY,
    NP_COMPATSVC_ABSENT,
};
int np_compatsvc_routes(void);

// Sentinel name for "no tool".
#define NP_COMPAT_TOOL_NONE "notproton.none"

#define NP_COMPATSVC_PARTLY_APPLIED 129

// Tells the page the mapping changed.
void np_compatsvc_state_changed(void);

#endif // NOTPROTON_FEATS_COMPATSVC_H
