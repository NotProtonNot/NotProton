#ifndef NOTPROTON_FEATS_NATIVEPLATFORM_H
#define NOTPROTON_FEATS_NATIVEPLATFORM_H

#include <stddef.h>
#include <stdint.h>

typedef struct {
    uint32_t *native_appids;
    size_t native_count;
    uint32_t *known_appids;
    size_t known_count;
    uint32_t *windows_appids;
    size_t windows_count;
} np_nativeplatform_snapshot_t;

// common/oslist is Steam's declared platform metadata. It does not establish
// that a legacy 32-bit Mac build runs on current macOS. The caller owns all
// arrays in a successfully parsed snapshot.
int np_nativeplatform_parse_appinfo(const uint8_t *bytes, size_t length,
                                    np_nativeplatform_snapshot_t *out);
void np_nativeplatform_snapshot_free(np_nativeplatform_snapshot_t *snapshot);

// Reads Steam's local appinfo.vdf and returns a JS prefix defining the native
// Mac/Windows app ID sets, known-metadata set, and snapshot generation.
// Refresh is bounded and invalidated by file metadata changes.
char *np_nativeplatform_javascript(uint64_t *out_generation);
uint64_t np_nativeplatform_generation(void);

#endif
