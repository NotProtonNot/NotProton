#define NP_PATCHCHECK
#include "plugin_host.c"
#include "../dylib/feats/conf.h"

#include <dirent.h>
#include <fcntl.h>
#include <fts.h>
#include <libkern/OSByteOrder.h>
#include <mach-o/fat.h>
#include <sys/mman.h>
#include <sys/stat.h>

#define FOUND_MAX   64
#define RUNNERS_MAX 128

struct conf_ctx {
    const char *file;
    int in_file, refused;
    char *spec;
    size_t used, cap;
};

struct result {
    int plugin;
    const char *status;
    char where[1024];
    char detail[512];
};

static const char *g_plugins[PATCHES_MAX];
static int g_nplugins;
static struct result *g_results;
static int g_nresults, g_capresults;
static intptr_t g_shift[SECTIONS_MAX];

static int spec_put(struct conf_ctx *c, const char *s) {
    size_t n = strlen(s);
    if (c->used + n + 1 > c->cap) {
        size_t cap = (c->used + n + 1) * 2;
        char *grown = realloc(c->spec, cap);
        if (!grown) return 0;
        c->spec = grown;
        c->cap = cap;
    }
    memcpy(c->spec + c->used, s, n + 1);
    c->used += n;
    return 1;
}

static void on_file(const char *path, void *ctx) {
    struct conf_ctx *c = ctx;
    c->in_file = strcmp(path, c->file) == 0;
}

static const char *on_record(const np_conf_rec_t *rec, void *ctx, const char **detail) {
    struct conf_ctx *c = ctx;
    const char *n, *v;
    int it = 0;
    (void)detail;
    if (!c->in_file) return NULL;
    while (np_conf_next(rec, &it, &n, &v))
        if (!strcmp(n, "patch")
            && (!(c->used ? spec_put(c, ";") : 1) || !spec_put(c, rec->id) || !spec_put(c, ":") || !spec_put(c, v)))
            return NULL;
    return NULL;
}

static void on_refused(const char *scope, const char *code, const char *detail, void *ctx) {
    struct conf_ctx *c = ctx;
    if (strchr(scope, '.') ? strcmp(scope, c->file) != 0 : !c->in_file) return;
    printf("%s refused, %s%s%s\n", scope, code, detail ? ":" : "", detail ? detail : "");
    c->refused++;
}

__attribute__((format(printf, 4, 5)))
static void result(int plugin, const char *status, const char *where, const char *fmt, ...) {
    if (g_nresults == g_capresults) {
        int cap = g_capresults ? g_capresults * 2 : 64;
        struct result *grown = realloc(g_results, (size_t)cap * sizeof(*grown));
        if (!grown) return;
        g_results = grown;
        g_capresults = cap;
    }
    struct result *r = &g_results[g_nresults++];
    r->plugin = plugin;
    r->status = status;
    snprintf(r->where, sizeof(r->where), "%s", where);
    va_list ap;
    va_start(ap, fmt);
    vsnprintf(r->detail, sizeof(r->detail), fmt, ap);
    va_end(ap);
}

static int map_file(const char *path, const unsigned char **p, size_t *len) {
    struct stat st;
    int fd = open(path, O_RDONLY);
    if (fd < 0) return 0;
    if (fstat(fd, &st) != 0 || st.st_size <= 0) { close(fd); return 0; }
    void *m = mmap(NULL, (size_t)st.st_size, PROT_READ, MAP_PRIVATE, fd, 0);
    close(fd);
    if (m == MAP_FAILED) return 0;
    *p = m;
    *len = (size_t)st.st_size;
    return 1;
}

static void add_span(struct image *img, const unsigned char *file, size_t len, uint64_t off, uint64_t size,
                     intptr_t shift) {
    if (img->nsections >= SECTIONS_MAX || off >= len || !size) return;
    if (size > len - off) size = len - off;
    g_shift[img->nsections] = shift;
    img->code[img->nsections].start = (uintptr_t)(file + off);
    img->code[img->nsections].size = (size_t)size;
    img->nsections++;
}

static unsigned long offset_of(const struct image *img, uintptr_t site) {
    for (int i = 0; i < img->nsections; i++)
        if (site >= img->code[i].start && site < img->code[i].start + img->code[i].size)
            return (unsigned long)((intptr_t)(site - img->base) + g_shift[i]);
    return 0;
}

static int pe_file(const unsigned char *p, size_t len, struct image *img) {
    if (len < 0x40 || p[0] != 'M' || p[1] != 'Z') return 0;
    uint32_t pe = rd32(p + 0x3c);
    if (pe > len - 24 || memcmp(p + pe, "PE\0\0", 4) != 0) return 0;
    unsigned nsec = rd16(p + pe + 6), optsize = rd16(p + pe + 20), magic = rd16(p + pe + 24);
    size_t sec = pe + 24 + (size_t)optsize;
    if ((magic != 0x20b && magic != 0x10b) || optsize < 60 || sec + (size_t)nsec * 40 > len) return 0;
    uint32_t image_size = rd32(p + pe + 24 + 56);
    img->base = (uintptr_t)p;
    img->nsections = 0;
    for (unsigned i = 0; i < nsec; i++) {
        const unsigned char *s = p + sec + i * 40;
        uint32_t vsize = rd32(s + 8), va = rd32(s + 12), rsize = rd32(s + 16), raw = rd32(s + 20);
        if (!(rd32(s + 36) & IMAGE_SCN_MEM_EXECUTE) || !vsize || va >= image_size) continue;
        add_span(img, p, len, raw, rsize < vsize ? rsize : vsize, (intptr_t)va - (intptr_t)raw);
    }
    return img->nsections > 0;
}

static int macho_file(const unsigned char *p, size_t len, struct image *img, int *arm64) {
    uint64_t off = 0, size = len;
    *arm64 = 0;
    if (len < sizeof(struct mach_header_64)) return 0;
    uint32_t magic = OSSwapBigToHostInt32(*(const uint32_t *)p);
    if (magic == FAT_MAGIC || magic == FAT_MAGIC_64) {
        uint32_t n = OSSwapBigToHostInt32(((const struct fat_header *)p)->nfat_arch);
        size_t each = magic == FAT_MAGIC ? sizeof(struct fat_arch) : sizeof(struct fat_arch_64);
        int found = 0;
        for (uint32_t i = 0; i < n && sizeof(struct fat_header) + (i + 1) * each <= len; i++) {
            const unsigned char *a = p + sizeof(struct fat_header) + i * each;
            cpu_type_t cpu = (cpu_type_t)OSSwapBigToHostInt32(*(const uint32_t *)a);
            if (cpu == CPU_TYPE_ARM64) *arm64 = 1;
            if (cpu != CPU_TYPE_X86_64) continue;
            if (magic == FAT_MAGIC) {
                off = OSSwapBigToHostInt32(((const struct fat_arch *)a)->offset);
                size = OSSwapBigToHostInt32(((const struct fat_arch *)a)->size);
            } else {
                off = OSSwapBigToHostInt64(((const struct fat_arch_64 *)a)->offset);
                size = OSSwapBigToHostInt64(((const struct fat_arch_64 *)a)->size);
            }
            found = 1;
        }
        if (!found || off >= len || size > len - off) return 0;
    }
    const struct mach_header_64 *mh = (const struct mach_header_64 *)(p + off);
    if (size < sizeof(*mh) || mh->magic != MH_MAGIC_64) return 0;
    if (mh->cputype == CPU_TYPE_ARM64) *arm64 = 1;
    if (mh->cputype != CPU_TYPE_X86_64 || sizeof(*mh) + mh->sizeofcmds > size) return 0;
    *arm64 = 0;
    img->base = (uintptr_t)mh;
    img->nsections = 0;
    const struct load_command *c = NULL;
    uint64_t header_at = 0;
    EACH_COMMAND(mh, c) {
        const struct segment_command_64 *seg = (const struct segment_command_64 *)c;
        if (c->cmd == LC_SEGMENT_64 && !seg->fileoff && seg->filesize) header_at = seg->vmaddr;
    }
    c = NULL;
    EACH_COMMAND(mh, c) {
        if (c->cmd != LC_SEGMENT_64) continue;
        const struct segment_command_64 *seg = (const struct segment_command_64 *)c;
        const struct section_64 *s = (const struct section_64 *)(seg + 1);
        if (sizeof(*seg) + (size_t)seg->nsects * sizeof(*s) > c->cmdsize) return 0;
        if (!(seg->initprot & VM_PROT_EXECUTE)) continue;
        for (uint32_t k = 0; k < seg->nsects; k++)
            if (s[k].size && (s[k].flags & SECTION_TYPE) != S_ZEROFILL)
                add_span(img, p + off, (size_t)size, s[k].offset, s[k].size,
                         (intptr_t)(s[k].addr - header_at) - (intptr_t)s[k].offset);
    }
    return img->nsections > 0;
}

static int plugin_patches(int plugin, const char *module) {
    for (int i = 0; i < g_npatches; i++)
        if (!strcmp(g_patches[i].plugin, g_plugins[plugin]) && !strcasecmp(g_patches[i].module, module)) return 1;
    return 0;
}

static void check_plugin(const struct image *img, const char *module, int plugin, const char *where,
                         const char *never) {
    char why[128] = "", sites[384] = "";
    size_t used = 0;
    int k = 0;
    for (int i = 0; i < g_npatches; i++) {
        const struct patch *p = &g_patches[i];
        if (strcmp(p->plugin, g_plugins[plugin]) != 0 || strcasecmp(p->module, module) != 0) continue;
        uintptr_t site = 0;
        int form = 0, count = find_patch(img, p, &site, &form);
        k++;
        if (count != 1 && !*why) snprintf(why, sizeof(why), "patch %d is found %d times, not once", k, count);
        if (count != 1) continue;
        char at[128] = "";
        size_t n = 0;
        const struct form *f = &p->forms[form];
        for (int b = 0; b < f->len; b++) {
            if (!f->set[b] || (b && f->set[b - 1]) || n >= sizeof(at)) continue;
            int w = snprintf(at + n, sizeof(at) - n, " +%#lx", offset_of(img, site + (uintptr_t)b));
            if (w > 0) n += (size_t)w;
        }
        if (used >= sizeof(sites)) continue;
        int w = p->nforms > 1 ? snprintf(sites + used, sizeof(sites) - used, "%spatch %d form %d at%s",
                                         used ? ", " : "", k, form + 1, at)
                              : snprintf(sites + used, sizeof(sites) - used, "%spatch %d at%s", used ? ", " : "", k, at);
        if (w > 0) used += (size_t)w;
    }
    if (never) result(plugin, "not reached", where, "%s; %s", never, *why ? why : sites);
    else if (*why) result(plugin, "left alone", where, "%s", why);
    else result(plugin, "patched", where, "%s", sites);
}

static void check_file(const char *path, const char *module, int pe, const char *where, const char *never) {
    const unsigned char *p = NULL;
    size_t len = 0;
    struct image img;
    int arm64 = 0, mapped = map_file(path, &p, &len);
    int ok = mapped && (pe ? pe_file(p, len, &img) : macho_file(p, len, &img, &arm64));
    for (int k = 0; k < g_nplugins; k++) {
        if (!plugin_patches(k, module)) continue;
        if (!mapped) result(k, "left alone", where, "unreadable");
        else if (!ok) result(k, "left alone", where, "%s", arm64 ? "arm64 code can't be changed" : "no code to read");
        else check_plugin(&img, module, k, where, never);
    }
    if (mapped) munmap((void *)p, len);
}

static int by_name(const FTSENT **a, const FTSENT **b) { return strcmp((*a)->fts_name, (*b)->fts_name); }

static void check_runner(const char *runner, const char *name) {
    char root[1200];
    snprintf(root, sizeof(root), "%s/CrossOver", runner);
    char *roots[] = { root, NULL };
    char (*found)[1024] = calloc(FOUND_MAX, sizeof(*found));
    int which[FOUND_MAX], nfound = 0, loads[PATCHES_MAX] = { 0 }, has[PATCHES_MAX] = { 0 };
    FTS *fts = found ? fts_open(roots, FTS_PHYSICAL | FTS_NOCHDIR, by_name) : NULL;
    if (!fts) { free(found); return; }
    for (FTSENT *e; (e = fts_read(fts));) {
        if (e->fts_info != FTS_F) continue;
        for (int i = 0; i < g_npatches; i++) {
            if (g_patches[i].pe && strstr(e->fts_path, "-unix/") && !strcasecmp(e->fts_name, g_patches[i].trigger))
                loads[i] = 1;
            if (strcasecmp(e->fts_name, g_patches[i].module) != 0) continue;
            has[i] = 1;
            int j = 0;
            while (j < nfound && strcmp(found[j], e->fts_path) != 0) j++;
            if (j < nfound || nfound >= FOUND_MAX) continue;
            snprintf(found[nfound], sizeof(*found), "%s", e->fts_path);
            which[nfound++] = i;
        }
    }
    fts_close(fts);
    for (int i = 0; i < g_npatches; i++) {
        int first = !has[i];
        for (int j = 0; j < i && first; j++) first = strcasecmp(g_patches[j].module, g_patches[i].module) != 0;
        for (int k = 0; k < g_nplugins && first; k++)
            if (plugin_patches(k, g_patches[i].module)) result(k, "missing", name, "no %s", g_patches[i].module);
    }
    for (int f = 0; f < nfound; f++) {
        const struct patch *p = &g_patches[which[f]];
        char where[1400], never[128];
        snprintf(where, sizeof(where), "%s: %s", name, found[f] + strlen(root) + 1);
        snprintf(never, sizeof(never), "no %s to load it", p->trigger);
        check_file(found[f], p->module, p->pe, where, p->pe && !loads[which[f]] ? never : NULL);
    }
    free(found);
}

static int name_cmp(const void *a, const void *b) {
    return strcmp(*(char *const *)a, *(char *const *)b);
}

int main(int argc, char **argv) {
    if (argc < 2) {
        fprintf(stderr, "usage: patchcheck <plugin.conf> [game file...]\n");
        return 2;
    }
    char dir[1024], file[256], runners[1200];
    const char *slash = strrchr(argv[1], '/');
    if (slash > argv[1]) snprintf(dir, sizeof(dir), "%.*s", (int)(slash - argv[1]), argv[1]);
    else snprintf(dir, sizeof(dir), "%s", slash ? "/" : ".");
    snprintf(file, sizeof(file), "%s", slash ? slash + 1 : argv[1]);
    if (access(argv[1], R_OK) != 0) {
        fprintf(stderr, "patchcheck: can't read %s\n", argv[1]);
        return 2;
    }
    struct conf_ctx c = { .file = file };
    const np_conf_sink_t sink = { on_record, on_refused, on_file };
    np_conf_read_dir(dir, "", NP_CONF_PLUGIN, &sink, &c);
    if (!c.used) {
        if (!c.refused) printf("%s has no patch lines to check\n", file);
        free(c.spec);
        return c.refused ? 1 : 2;
    }
    parse_spec(c.spec);
    free(c.spec);
    for (int i = 0; i < g_npatches; i++) {
        int k = 0;
        while (k < g_nplugins && strcmp(g_plugins[k], g_patches[i].plugin) != 0) k++;
        if (k == g_nplugins) g_plugins[g_nplugins++] = g_patches[i].plugin;
    }
    if (!g_nplugins) return 2;

    const char *home = getenv("HOME");
    snprintf(runners, sizeof(runners), "%s/Library/Application Support/notproton/runners", home ? home : "");
    DIR *d = opendir(runners);
    char *names[RUNNERS_MAX];
    int n = 0;
    for (struct dirent *de; d && (de = readdir(d)) && n < RUNNERS_MAX;)
        if (!strncmp(de->d_name, "crossover-", 10) && !strchr(de->d_name, '+') && (names[n] = strdup(de->d_name))) n++;
    if (d) closedir(d);
    qsort(names, (size_t)n, sizeof(*names), name_cmp);
    if (!n) printf("no runners in %s\n", runners);
    for (int i = 0; i < n; i++) {
        char path[1400];
        snprintf(path, sizeof(path), "%s/%s", runners, names[i]);
        check_runner(path, names[i]);
        free(names[i]);
    }

    for (int a = 2; a < argc; a++) {
        int i = 0;
        while (i < g_npatches && strcasecmp(g_patches[i].module, base_name(argv[a])) != 0) i++;
        if (i == g_npatches) printf("%s: no patch is for %s\n", argv[a], base_name(argv[a]));
        else check_file(argv[a], g_patches[i].module, g_patches[i].pe, argv[a],
                        g_patches[i].pe ? "game files aren't patched yet" : NULL);
    }

    int missed = 0;
    for (int k = 0; k < g_nplugins; k++) {
        int patched = 0;
        printf("%s\n", g_plugins[k]);
        for (int r = 0; r < g_nresults; r++) {
            if (g_results[r].plugin != k) continue;
            printf("  %-11s  %s (%s)\n", g_results[r].status, g_results[r].where, g_results[r].detail);
            patched |= !strcmp(g_results[r].status, "patched");
        }
        if (!patched) {
            printf("  patched nowhere\n");
            missed = 1;
        }
    }
    free(g_results);
    return missed || c.refused ? 1 : 0;
}
