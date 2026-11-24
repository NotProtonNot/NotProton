// Support for adding Steam launch options via a plugin
#ifndef NOTPROTON_FEATS_PLUGINLAUNCH_H
#define NOTPROTON_FEATS_PLUGINLAUNCH_H

#include <stddef.h>
#include <stdint.h>

// [{k: row id, on: row value, l: label, a: arguments}]. NULL if out of memory.
char *np_pluginlaunch_json(uint32_t appid);

int np_pluginlaunch_pick(uint32_t appid, const char *args);

// Caller frees.
char *np_pluginlaunch_take(const char *cmd);

#endif // NOTPROTON_FEATS_PLUGINLAUNCH_H
