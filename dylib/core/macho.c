#include "macho.h"
#include <mach-o/dyld.h>
#include <signal.h>
#include <string.h>
#include <unistd.h>

static volatile sig_atomic_t g_await_stop;

void np_await_stop(void) {
    g_await_stop = 1;
}

static int image_index_by_name(const char *needle) {
    uint32_t n = _dyld_image_count();
    for (uint32_t idx = 0; idx < n; idx++) {
        const char *path = _dyld_get_image_name(idx);
        if (path && strstr(path, needle))
            return (int)idx;
    }
    return -1;
}

int np_await_image(const char *name, int timeout_ms,
                         const struct mach_header_64 **out_mh, intptr_t *out_slide,
                         char *out_path, size_t path_size) {
    for (int waited = 0; waited < timeout_ms; waited += 100) {
        if (g_await_stop) return -1;

        int idx = image_index_by_name(name);
        if (idx >= 0) {
            *out_mh    = (const struct mach_header_64 *)_dyld_get_image_header((uint32_t)idx);
            *out_slide = _dyld_get_image_vmaddr_slide((uint32_t)idx);
            if (out_path && path_size) {
                const char *p = _dyld_get_image_name((uint32_t)idx);
                size_t len = strlen(p);
                if (len >= path_size) len = path_size - 1;
                memcpy(out_path, p, len);
                out_path[len] = '\0';
            }
            return 0;
        }
        usleep(100000);
    }
    return -1;
}

int np_find_segment(const struct mach_header_64 *mh, intptr_t slide,
                   const char *segname, uintptr_t *out_base, size_t *out_size) {
    if (!mh || !segname) return -1;

    const uint8_t *cursor = (const uint8_t *)(mh + 1);
    uint32_t remaining = mh->ncmds;

    while (remaining--) {
        const struct load_command *lc = (const struct load_command *)cursor;
        if (lc->cmdsize < sizeof(*lc))
            return -1;   // corrupt or truncated
        if (lc->cmd == LC_SEGMENT_64) {
            const struct segment_command_64 *sc = (const struct segment_command_64 *)cursor;
            if (strncmp(sc->segname, segname, sizeof(sc->segname)) == 0) {
                *out_base = (uintptr_t)sc->vmaddr + (uintptr_t)slide;
                *out_size = (size_t)sc->vmsize;
                return 0;
            }
        }
        cursor += lc->cmdsize;
    }
    return -1;
}

static const uint8_t *fn_starts_table(const struct mach_header_64 *mh,
                                      intptr_t slide, size_t *out_size) {
    const uint8_t *cursor = (const uint8_t *)(mh + 1);
    uint32_t remaining = mh->ncmds;

    const struct linkedit_data_command *fs = NULL;
    uint64_t le_vmaddr = 0, le_fileoff = 0;
    int have_le = 0;

    while (remaining--) {
        const struct load_command *lc = (const struct load_command *)cursor;
        if (lc->cmdsize < sizeof(*lc)) return NULL;

        if (lc->cmd == LC_FUNCTION_STARTS && lc->cmdsize >= sizeof(*fs)) {
            fs = (const struct linkedit_data_command *)cursor;
        } else if (lc->cmd == LC_SEGMENT_64) {
            const struct segment_command_64 *sc = (const struct segment_command_64 *)cursor;
            if (strncmp(sc->segname, SEG_LINKEDIT, sizeof(sc->segname)) == 0) {
                le_vmaddr  = sc->vmaddr;
                le_fileoff = sc->fileoff;
                have_le    = 1;
            }
        }
        cursor += lc->cmdsize;
    }

    if (!fs || !have_le || !fs->datasize) return NULL;
    if (fs->dataoff < le_fileoff) return NULL;

    *out_size = fs->datasize;
    return (const uint8_t *)(uintptr_t)(le_vmaddr + (fs->dataoff - le_fileoff)
                                        + (uint64_t)slide);
}

int np_function_bounds(const struct mach_header_64 *mh, intptr_t slide,
                       uintptr_t addr, uintptr_t *out_start, uintptr_t *out_end) {
    if (!mh || !out_start || !out_end) return -1;

    size_t size = 0;
    const uint8_t *p = fn_starts_table(mh, slide, &size);
    if (!p) return -1;

    const uint8_t *end = p + size;
    uintptr_t va = (uintptr_t)mh;
    uintptr_t start = 0;

    while (p < end) {
        uint64_t delta = 0;
        unsigned shift = 0;
        int complete = 0;

        while (p < end) {
            uint8_t b = *p++;
            if (shift < 64) delta |= (uint64_t)(b & 0x7F) << shift;
            shift += 7;
            if (!(b & 0x80)) { complete = 1; break; }
        }
        if (!complete) break;
        if (!delta) break;

        va += (uintptr_t)delta;
        if (va <= addr) {
            start = va;
            continue;
        }
        if (!start) return -1;
        *out_start = start;
        *out_end   = va;
        return 0;
    }

    return -1;
}

int np_get_section_containing(const struct mach_header_64 *mh, intptr_t slide,
                             uintptr_t addr, uintptr_t *out_base,
                             size_t *out_size) {
    if (!mh || !out_base || !out_size) return -1;

    const uint8_t *cursor = (const uint8_t *)(mh + 1);
    uint32_t remaining = mh->ncmds;

    while (remaining--) {
        const struct load_command *lc = (const struct load_command *)cursor;
        if (lc->cmdsize < sizeof(*lc))
            return -1;   // corrupt or truncated
        if (lc->cmd == LC_SEGMENT_64) {
            const struct segment_command_64 *sc =
                (const struct segment_command_64 *)cursor;

            if (lc->cmdsize < sizeof(*sc) + sc->nsects * sizeof(struct section_64))
                return -1;

            const struct section_64 *sect = (const struct section_64 *)(sc + 1);
            for (uint32_t i = 0; i < sc->nsects; i++) {
                uintptr_t base = (uintptr_t)sect[i].addr + (uintptr_t)slide;
                if (addr < base || addr >= base + (uintptr_t)sect[i].size)
                    continue;
                *out_base = base;
                *out_size = (size_t)sect[i].size;
                return 0;
            }
        }
        cursor += lc->cmdsize;
    }
    return -1;
}
