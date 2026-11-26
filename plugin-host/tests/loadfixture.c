#include <stdio.h>

__attribute__((constructor)) static void loaded(void) { dprintf(1, "loaded " NAME "\n"); }

#ifdef SHIM
void np_overlay_shim_install(void) { dprintf(1, "installed\n"); }
#endif
