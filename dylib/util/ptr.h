// Pointer validation helpers
#ifndef NOTPROTON_UTIL_PTR_H
#define NOTPROTON_UTIL_PTR_H

#include <stdint.h>

static inline int np_plausible_addr(uint64_t v) {
    if (v < 0x100000000ULL)      return 0;  // below 4 GB (image/stack guard)
    if (v >= 0x800000000000ULL)  return 0;  // kernel space
    return 1;
}

static inline int np_plausible_ptr(uint64_t v) {
    if (!np_plausible_addr(v))   return 0;
    if (v & 0x7)                 return 0;  // not 8-byte aligned
    return 1;
}

#endif // NOTPROTON_UTIL_PTR_H
