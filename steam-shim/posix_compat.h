#ifndef STEAM_HELPER_POSIX_COMPAT_H
#define STEAM_HELPER_POSIX_COMPAT_H

/* mingw has no setenv. steam.cpp uses it for the locale and the anti-cheat
   runtime paths. */

#include <stdlib.h>

#ifdef __cplusplus
extern "C" {
#endif

static inline int setenv(const char *name, const char *value, int overwrite)
{
    if (!overwrite && getenv(name)) return 0;
    return _putenv_s(name, value ? value : "");
}

#ifdef __cplusplus
}
#endif

#endif
