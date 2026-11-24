// Launch choices a plugin offers for a non-Steam shortcut.
#ifndef NOTPROTON_FEATS_PLUGINLAUNCH_H
#define NOTPROTON_FEATS_PLUGINLAUNCH_H

#include <stddef.h>
#include <stdint.h>

// The folder a shortcut's exe is in, from shortcuts.vdf. Returns 1 when found.
int np_pluginlaunch_shortcut_dir(const char *home, uint32_t appid, char *out, size_t size);

// The shortcut's launch entries as [{k: row id, on: row value, l: label, a: arguments}].
// NULL if out of memory.
char *np_pluginlaunch_json(uint32_t appid);

#endif // NOTPROTON_FEATS_PLUGINLAUNCH_H
