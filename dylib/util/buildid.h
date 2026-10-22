// CrossOver build IDs
#ifndef NOTPROTON_UTIL_BUILDID_H
#define NOTPROTON_UTIL_BUILDID_H

#include <stdbool.h>
#include <stddef.h>

#define NP_BUILD_ID_MAX 63

static inline bool np_is_build_id(const char *s) {
    size_t n = 0;
    for (; s && s[n]; n++) {
        char c = s[n];
        if (!((c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9')
              || c == '.' || c == '-'))
            return false;
    }
    return n > 0 && n <= NP_BUILD_ID_MAX;
}

#endif // NOTPROTON_UTIL_BUILDID_H
