// Non-Steam shortcuts
#ifndef NOTPROTON_FEATS_USERSHORTCUTS_H
#define NOTPROTON_FEATS_USERSHORTCUTS_H

#include <mach-o/loader.h>
#include <stdbool.h>
#include <stdint.h>

// Finds the CUserShortcuts vtable and reads the table layout out of SetShortcutExe,
// returns 1 when both are found.
int np_usershortcuts_bind(const struct mach_header_64 *mh, intptr_t slide,
                          uintptr_t set_shortcut_exe);

// True for a shortcut to a Windows .exe that isn't from Steam Remote Play.
// Linux Steam runs these with the default compatibility tool.
bool np_usershortcuts_runs_exe(const void *user, uint32_t appid);

#endif // NOTPROTON_FEATS_USERSHORTCUTS_H
