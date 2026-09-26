#include "../util/peicon.h"

#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#define PEO         0x80u
#define OPT_SIZE    240u
#define SECT_OFF    (PEO + 24u + OPT_SIZE)
#define RSRC_OFF    0x400u
#define RSRC_RVA    0x1000u
#define BUDGET_SECS 20
#define MAX_ICO     (32u * 1024u * 1024u)

static const char *g_case = "startup";

static void on_alarm(int sig) {
    (void)sig;
    static const char msg[] = " did not finish within the time budget\n";
    write(2, "peicon-check: ", 14);
    write(2, g_case, strlen(g_case));
    write(2, msg, sizeof(msg) - 1);
    _exit(9);
}

static void put16(uint8_t *p, unsigned v) {
    p[0] = (uint8_t)(v & 0xFF);
    p[1] = (uint8_t)((v >> 8) & 0xFF);
}

static void put32(uint8_t *p, uint32_t v) {
    p[0] = (uint8_t)(v & 0xFF);
    p[1] = (uint8_t)((v >> 8) & 0xFF);
    p[2] = (uint8_t)((v >> 16) & 0xFF);
    p[3] = (uint8_t)((v >> 24) & 0xFF);
}

static uint8_t *pe_alloc(size_t rsrc_size, size_t *out_total) {
    size_t total = RSRC_OFF + rsrc_size;
    uint8_t *img = calloc(1, total);
    if (!img) return NULL;

    img[0] = 'M';
    img[1] = 'Z';
    put32(img + 0x3C, PEO);

    uint8_t *pe = img + PEO;
    pe[0] = 'P';
    pe[1] = 'E';
    put16(pe + 6, 1);
    put16(pe + 20, OPT_SIZE);
    put16(pe + 24, 0x20B);
    put32(pe + 24 + 108, 16);
    put32(pe + 24 + 112 + 16, RSRC_RVA);

    uint8_t *sect = img + SECT_OFF;
    memcpy(sect, ".rsrc", 5);
    put32(sect + 8, (uint32_t)rsrc_size);
    put32(sect + 12, RSRC_RVA);
    put32(sect + 16, (uint32_t)rsrc_size);
    put32(sect + 20, RSRC_OFF);

    *out_total = total;
    return img;
}

static void dir_header(uint8_t *node, unsigned named, unsigned ids) {
    put16(node + 12, named);
    put16(node + 14, ids);
}

static void dir_entry(uint8_t *node, unsigned slot, uint32_t name, uint32_t off,
                      int is_subdir) {
    uint8_t *e = node + 16 + (size_t)slot * 8;
    put32(e, name);
    put32(e + 4, is_subdir ? (off | 0x80000000u) : off);
}

static void data_entry(uint8_t *at, uint32_t rva, uint32_t size) {
    put32(at, rva);
    put32(at + 4, size);
}

static int write_file(const char *path, const uint8_t *buf, size_t len) {
    FILE *f = fopen(path, "wb");
    if (!f) return -1;
    size_t wrote = fwrite(buf, 1, len, f);
    if (fclose(f) != 0 || wrote != len) return -1;
    return 0;
}

static uint8_t *build_selfref(size_t *out_total) {
    unsigned entries = 131070;
    size_t rsrc = 16 + (size_t)entries * 8;
    uint8_t *img = pe_alloc(rsrc, out_total);
    if (!img) return NULL;

    uint8_t *root = img + RSRC_OFF;
    dir_header(root, 65535, 65535);
    for (unsigned i = 0; i < entries; i++)
        dir_entry(root, i, 0, 0, 1);

    return img;
}

#define B_ROOT   0x000u
#define B_T3     0x020u
#define B_T3ID   0x038u
#define B_T14    0x050u
#define B_T14ID  0x068u
#define B_LICON  0x080u
#define B_LGROUP 0x090u
#define B_GROUP  0x100u

static uint8_t *build_group(unsigned count, uint32_t icon_size, size_t *out_total) {
    size_t group_bytes = 6 + (size_t)count * 14;
    size_t icon_at = (B_GROUP + group_bytes + 0xFFF) & ~(size_t)0xFFF;
    size_t rsrc = icon_at + icon_size;

    uint8_t *img = pe_alloc(rsrc, out_total);
    if (!img) return NULL;

    uint8_t *base = img + RSRC_OFF;

    dir_header(base + B_ROOT, 0, 2);
    dir_entry(base + B_ROOT, 0, 3, B_T3, 1);
    dir_entry(base + B_ROOT, 1, 14, B_T14, 1);

    dir_header(base + B_T3, 0, 1);
    dir_entry(base + B_T3, 0, 1, B_T3ID, 1);
    dir_header(base + B_T3ID, 0, 1);
    dir_entry(base + B_T3ID, 0, 0, B_LICON, 0);

    dir_header(base + B_T14, 0, 1);
    dir_entry(base + B_T14, 0, 1, B_T14ID, 1);
    dir_header(base + B_T14ID, 0, 1);
    dir_entry(base + B_T14ID, 0, 0, B_LGROUP, 0);

    data_entry(base + B_LICON, (uint32_t)(RSRC_RVA + icon_at), icon_size);
    data_entry(base + B_LGROUP, (uint32_t)(RSRC_RVA + B_GROUP), (uint32_t)group_bytes);

    uint8_t *group = base + B_GROUP;
    put16(group + 2, 1);
    put16(group + 4, count);
    for (unsigned i = 0; i < count; i++) {
        uint8_t *e = group + 6 + (size_t)i * 14;
        e[0] = 32;
        e[1] = 32;
        e[2] = 0;
        put16(e + 4, 1);
        put16(e + 6, 32);
        put32(e + 8, icon_size);
        put16(e + 12, 1);
    }

    memset(base + icon_at, 0xA5, icon_size);
    return img;
}

static int fails;

static void fail(const char *what) {
    printf("  FAIL %s: %s\n", g_case, what);
    fails++;
}

static void expect_null(const char *dir, const char *name, const uint8_t *img,
                        size_t len) {
    char path[1024];
    snprintf(path, sizeof(path), "%s/%s", dir, name);
    g_case = name;
    if (write_file(path, img, len) != 0) { fail("could not write fixture"); return; }

    size_t out = 12345;
    void *ico = np_pe_icon_ico(path, &out);
    if (ico) {
        fail("expected no icon");
        free(ico);
        return;
    }
    printf("  ok   %s: refused\n", name);
}

static void expect_bounded(const char *dir, const char *name, const uint8_t *img,
                           size_t len) {
    char path[1024];
    snprintf(path, sizeof(path), "%s/%s", dir, name);
    g_case = name;
    if (write_file(path, img, len) != 0) { fail("could not write fixture"); return; }

    size_t out = 0;
    void *ico = np_pe_icon_ico(path, &out);
    if (!ico) { fail("expected an icon"); return; }
    if (out > MAX_ICO) {
        fail("icon exceeds the output ceiling");
        printf("       produced %zu bytes, ceiling is %u\n", out, MAX_ICO);
        free(ico);
        return;
    }
    printf("  ok   %s: %zu bytes, within the ceiling\n", name, out);
    free(ico);
}

static void expect_valid_ico(const char *dir, const char *name, const uint8_t *img,
                             size_t len, uint32_t icon_size) {
    char path[1024];
    snprintf(path, sizeof(path), "%s/%s", dir, name);
    g_case = name;
    if (write_file(path, img, len) != 0) { fail("could not write fixture"); return; }

    size_t out = 0;
    uint8_t *ico = np_pe_icon_ico(path, &out);
    if (!ico) { fail("expected an icon"); return; }

    if (out < 22) { fail("icon is too short to hold one entry"); free(ico); return; }
    if (ico[0] || ico[1]) fail("reserved field is not zero");
    if (ico[2] != 1 || ico[3] != 0) fail("type is not 1");

    unsigned n = (unsigned)ico[4] | ((unsigned)ico[5] << 8);
    if (n != 1) fail("expected exactly one image");

    if (n == 1) {
        const uint8_t *r = ico + 6;
        uint32_t size = (uint32_t)r[8] | ((uint32_t)r[9] << 8) |
                        ((uint32_t)r[10] << 16) | ((uint32_t)r[11] << 24);
        uint32_t at = (uint32_t)r[12] | ((uint32_t)r[13] << 8) |
                      ((uint32_t)r[14] << 16) | ((uint32_t)r[15] << 24);
        if (size != icon_size) fail("entry size does not match the resource");
        if ((size_t)at + size > out) fail("entry points outside the buffer");
        if (at == 22 && size == icon_size && ico[at] != 0xA5)
            fail("payload was not copied");
    }

    if (!fails) printf("  ok   %s: %zu bytes, one well formed entry\n", name, out);
    free(ico);
}

int main(int argc, char **argv) {
    char dir[1024];
    if (argc > 1) {
        snprintf(dir, sizeof(dir), "%s", argv[1]);
    } else {
        const char *tmp = getenv("TMPDIR");
        snprintf(dir, sizeof(dir), "%speicon-check.XXXXXX",
                 tmp && *tmp ? tmp : "/var/tmp/");
        if (!mkdtemp(dir)) { perror("mkdtemp"); return 2; }
    }

    signal(SIGALRM, on_alarm);
    alarm(BUDGET_SECS);

    printf("==> peicon fixtures\n");

    size_t len = 0;
    uint8_t *img = build_selfref(&len);
    if (!img) { fprintf(stderr, "peicon-check: out of memory\n"); return 2; }
    expect_null(dir, "selfref.exe", img, len);
    free(img);

    img = build_group(65535, 65536, &len);
    if (!img) { fprintf(stderr, "peicon-check: out of memory\n"); return 2; }
    expect_bounded(dir, "manyentries.exe", img, len);
    free(img);

    img = build_group(1024, 65536, &len);
    if (!img) { fprintf(stderr, "peicon-check: out of memory\n"); return 2; }
    expect_bounded(dir, "repeated.exe", img, len);
    free(img);

    img = build_group(1, 64, &len);
    if (!img) { fprintf(stderr, "peicon-check: out of memory\n"); return 2; }
    expect_valid_ico(dir, "good.exe", img, len, 64);
    size_t half = len / 2;
    expect_null(dir, "truncated.exe", img, half);
    free(img);

    uint8_t junk[0x200];
    memset(junk, 0xAA, sizeof(junk));
    expect_null(dir, "notpe.exe", junk, sizeof(junk));

    alarm(0);

    if (fails) {
        printf("==> %d peicon fixture check(s) failed\n", fails);
        return 1;
    }
    printf("==> peicon fixtures: hostile resources bounded, valid icon intact\n");
    return 0;
}
