// extracts icon from Windows application binary, used for non-Steam shortcuts
#include "peicon.h"

#include <fcntl.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <unistd.h>

#define NP_PE_MAX_SECTIONS 96
#define NP_PE_MAX_LEAVES   4096
#define NP_PE_MAX_IMAGE    (16 * 1024 * 1024)
#define NP_PE_MAX_DEPTH    3

#define NP_RT_ICON         3
#define NP_RT_GROUP_ICON   14

typedef struct {
    uint32_t va;
    uint32_t size;
    uint32_t raw;
    uint32_t raw_size;
} np_sect_t;

typedef struct {
    uint32_t type;
    uint32_t id;
    uint32_t rva;
    uint32_t size;
} np_leaf_t;

typedef struct {
    const uint8_t *p;
    size_t         n;
    np_sect_t      sects[NP_PE_MAX_SECTIONS];
    int            nsects;
    np_leaf_t     *leaves;
    int            nleaves;
} np_pe_t;

static int rd_u8(const np_pe_t *pe, size_t off, uint8_t *out) {
    if (off >= pe->n) return 0;
    *out = pe->p[off];
    return 1;
}

static int rd_u16(const np_pe_t *pe, size_t off, uint16_t *out) {
    if (pe->n < 2 || off > pe->n - 2) return 0;
    *out = (uint16_t)((uint16_t)pe->p[off] | ((uint16_t)pe->p[off + 1] << 8));
    return 1;
}

static int rd_u32(const np_pe_t *pe, size_t off, uint32_t *out) {
    if (pe->n < 4 || off > pe->n - 4) return 0;
    *out = (uint32_t)pe->p[off]             | ((uint32_t)pe->p[off + 1] << 8) |
           ((uint32_t)pe->p[off + 2] << 16) | ((uint32_t)pe->p[off + 3] << 24);
    return 1;
}

static int rva_to_off(const np_pe_t *pe, uint32_t rva, size_t *out) {
    for (int i = 0; i < pe->nsects; i++) {
        const np_sect_t *s = &pe->sects[i];
        uint32_t span = s->size > s->raw_size ? s->size : s->raw_size;
        if (rva >= s->va && (uint64_t)rva < (uint64_t)s->va + span) {
            *out = (size_t)s->raw + (size_t)(rva - s->va);
            return 1;
        }
    }
    return 0;
}

static int read_sections(np_pe_t *pe, size_t peo, int count, size_t opt_size) {
    if (count <= 0 || count > NP_PE_MAX_SECTIONS) return 0;

    size_t cursor = peo + 24 + opt_size;
    for (int i = 0; i < count; i++) {
        np_sect_t s;
        if (!rd_u32(pe, cursor + 8,  &s.size)     ||
            !rd_u32(pe, cursor + 12, &s.va)       ||
            !rd_u32(pe, cursor + 16, &s.raw_size) ||
            !rd_u32(pe, cursor + 20, &s.raw)) return 0;
        pe->sects[pe->nsects++] = s;
        cursor += 40;
    }
    return 1;
}

static void walk(np_pe_t *pe, size_t base, size_t node, int depth,
                 uint32_t type, uint32_t id) {
    uint16_t named, ids;
    if (depth >= NP_PE_MAX_DEPTH || pe->nleaves >= NP_PE_MAX_LEAVES) return;
    if (!rd_u16(pe, node + 12, &named) || !rd_u16(pe, node + 14, &ids)) return;

    int total = (int)named + (int)ids;
    for (int i = 0; i < total; i++) {
        size_t   entry = node + 16 + (size_t)i * 8;
        uint32_t name_field, off_field;
        if (!rd_u32(pe, entry, &name_field) || !rd_u32(pe, entry + 4, &off_field)) return;

        uint32_t rtype = depth == 0 ? name_field : type;
        uint32_t rid   = depth == 1 ? name_field : id;

        if (off_field & 0x80000000u) {
            walk(pe, base, base + (off_field & 0x7FFFFFFFu), depth + 1, rtype, rid);
            if (pe->nleaves >= NP_PE_MAX_LEAVES) return;
            continue;
        }

        size_t   at = base + off_field;
        np_leaf_t leaf;
        if (!rd_u32(pe, at, &leaf.rva) || !rd_u32(pe, at + 4, &leaf.size)) return;
        leaf.type = rtype;
        leaf.id   = rid;
        pe->leaves[pe->nleaves++] = leaf;
        if (pe->nleaves >= NP_PE_MAX_LEAVES) return;
    }
}

static const np_leaf_t *lowest_group(const np_pe_t *pe) {
    const np_leaf_t *best = NULL;
    for (int i = 0; i < pe->nleaves; i++) {
        const np_leaf_t *l = &pe->leaves[i];
        if (l->type != NP_RT_GROUP_ICON) continue;
        if (!best || l->id < best->id) best = l;
    }
    return best;
}

static const np_leaf_t *image_with_id(const np_pe_t *pe, uint32_t id) {
    for (int i = 0; i < pe->nleaves; i++) {
        const np_leaf_t *l = &pe->leaves[i];
        if (l->type == NP_RT_ICON && l->id == id) return l;
    }
    return NULL;
}

static void put_u16(uint8_t *p, uint16_t v) {
    p[0] = (uint8_t)(v & 0xFF);
    p[1] = (uint8_t)(v >> 8);
}

static void put_u32(uint8_t *p, uint32_t v) {
    p[0] = (uint8_t)(v & 0xFF);
    p[1] = (uint8_t)((v >> 8) & 0xFF);
    p[2] = (uint8_t)((v >> 16) & 0xFF);
    p[3] = (uint8_t)((v >> 24) & 0xFF);
}

static void *build_ico(np_pe_t *pe, uint32_t rsrc_rva, size_t *out_len) {
    size_t base;
    if (!rva_to_off(pe, rsrc_rva, &base)) return NULL;

    walk(pe, base, base, 0, 0, 0);

    const np_leaf_t *group = lowest_group(pe);
    if (!group) return NULL;

    size_t   group_at;
    uint16_t count;
    if (!rva_to_off(pe, group->rva, &group_at)) return NULL;
    if (group->size < 6) return NULL;
    if (!rd_u16(pe, group_at + 4, &count) || count == 0) return NULL;
    if (group->size < 6 + (uint32_t)count * 14) return NULL;

    const np_leaf_t **picked = calloc(count, sizeof(*picked));
    uint8_t          *records = calloc(count, 16);
    if (!picked || !records) {
        free(picked);
        free(records);
        return NULL;
    }

    int    written = 0;
    size_t payload = 0;

    for (int i = 0; i < (int)count; i++) {
        size_t   e = group_at + 6 + (size_t)i * 14;
        uint8_t  w, h, colors;
        uint16_t planes, bits, id;
        size_t   at;

        if (!rd_u8(pe, e, &w) || !rd_u8(pe, e + 1, &h) || !rd_u8(pe, e + 2, &colors) ||
            !rd_u16(pe, e + 4, &planes) || !rd_u16(pe, e + 6, &bits) ||
            !rd_u16(pe, e + 12, &id)) continue;

        const np_leaf_t *img = image_with_id(pe, id);
        if (!img || img->size == 0 || img->size > NP_PE_MAX_IMAGE) continue;
        if (!rva_to_off(pe, img->rva, &at)) continue;
        if (pe->n < img->size || at > pe->n - img->size) continue;

        uint8_t *r = records + (size_t)written * 16;
        r[0] = w;
        r[1] = h;
        r[2] = colors;
        r[3] = 0;
        put_u16(r + 4, planes);
        put_u16(r + 6, bits);
        put_u32(r + 8, img->size);
        picked[written] = img;
        written++;
        payload += img->size;
    }

    if (written == 0) {
        free(picked);
        free(records);
        return NULL;
    }

    size_t   header = 6 + (size_t)written * 16;
    size_t   total  = header + payload;
    uint8_t *ico    = malloc(total);
    if (!ico) {
        free(picked);
        free(records);
        return NULL;
    }

    put_u16(ico, 0);
    put_u16(ico + 2, 1);
    put_u16(ico + 4, (uint16_t)written);

    size_t at = header;
    for (int i = 0; i < written; i++) {
        uint8_t *r = ico + 6 + (size_t)i * 16;
        memcpy(r, records + (size_t)i * 16, 16);
        put_u32(r + 12, (uint32_t)at);

        size_t src = 0;
        if (!rva_to_off(pe, picked[i]->rva, &src)) continue;
        memcpy(ico + at, pe->p + src, picked[i]->size);
        at += picked[i]->size;
    }

    free(picked);
    free(records);
    *out_len = total;
    return ico;
}

static void *icon_from_map(const uint8_t *map, size_t len, size_t *out_len) {
    np_pe_t pe;
    memset(&pe, 0, sizeof(pe));
    pe.p = map;
    pe.n = len;

    uint16_t mz;
    uint32_t peo32, sig;
    if (!rd_u16(&pe, 0, &mz) || mz != 0x5A4D) return NULL;
    if (!rd_u32(&pe, 0x3C, &peo32)) return NULL;

    size_t peo = peo32;
    if (!rd_u32(&pe, peo, &sig) || sig != 0x00004550) return NULL;

    uint16_t nsects, opt_size, magic;
    if (!rd_u16(&pe, peo + 6, &nsects) || !rd_u16(&pe, peo + 20, &opt_size) ||
        !rd_u16(&pe, peo + 24, &magic)) return NULL;

    size_t dir_base, count_at;
    if (magic == 0x10B) {
        dir_base = peo + 24 + 96;
        count_at = peo + 24 + 92;
    } else if (magic == 0x20B) {
        dir_base = peo + 24 + 112;
        count_at = peo + 24 + 108;
    } else {
        return NULL;
    }

    uint32_t dir_count, rsrc_rva;
    if (!rd_u32(&pe, count_at, &dir_count) || dir_count <= 2) return NULL;
    if (!rd_u32(&pe, dir_base + 16, &rsrc_rva) || rsrc_rva == 0) return NULL;

    if (!read_sections(&pe, peo, (int)nsects, opt_size)) return NULL;

    pe.leaves = calloc(NP_PE_MAX_LEAVES, sizeof(*pe.leaves));
    if (!pe.leaves) return NULL;

    void *ico = build_ico(&pe, rsrc_rva, out_len);
    free(pe.leaves);
    return ico;
}

void *np_pe_icon_ico(const char *path, size_t *out_len) {
    if (!path || !*path || !out_len) return NULL;

    int fd = open(path, O_RDONLY | O_CLOEXEC);
    if (fd < 0) return NULL;

    struct stat st;
    if (fstat(fd, &st) != 0 || !S_ISREG(st.st_mode) || st.st_size <= 0x40) {
        close(fd);
        return NULL;
    }

    size_t len = (size_t)st.st_size;
    void  *map = mmap(NULL, len, PROT_READ, MAP_PRIVATE, fd, 0);
    close(fd);
    if (map == MAP_FAILED) return NULL;

    void *ico = icon_from_map(map, len, out_len);
    munmap(map, len);
    return ico;
}
