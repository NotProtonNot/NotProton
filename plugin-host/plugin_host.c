// Plugin host
#include <dlfcn.h>
#include <libkern/OSCacheControl.h>
#include <libproc.h>
#include <mach/mach.h>
#include <mach/mach_vm.h>
#include <mach-o/dyld.h>
#include <mach-o/loader.h>
#include <stdarg.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <strings.h>
#include <sys/proc_info.h>
#include <unistd.h>

#define PATCHES_MAX 64
#define FORMS_MAX   4
#define BYTES_MAX   128
#define NAME_LEN    64
#define APPLIED_MAX 64
#define IMAGES_MAX  8
#define SECTIONS_MAX 16

#define IMAGE_SCN_MEM_EXECUTE 0x20000000u

struct form {
    int len;
    unsigned char want[BYTES_MAX];
    unsigned char any[BYTES_MAX];
    unsigned char put[BYTES_MAX];
    unsigned char set[BYTES_MAX];
};

struct patch {
    char plugin[NAME_LEN];
    char module[NAME_LEN];
    char trigger[NAME_LEN];
    int pe;
    int nforms;
    struct form forms[FORMS_MAX];
};

struct span {
    uintptr_t start;
    size_t size;
};

struct image {
    uintptr_t base;
    int nsections;
    struct span code[SECTIONS_MAX];
};

static struct patch g_patches[PATCHES_MAX];
static int g_npatches;

static struct {
    char plugin[NAME_LEN];
    char module[NAME_LEN];
    uintptr_t base;
} g_applied[APPLIED_MAX];
static int g_napplied;

static void vlog(const char *tag, const char *fmt, va_list ap) {
    char line[1024];
    int n = snprintf(line, sizeof(line), "%s[%d]: ", tag, getpid());
    if (n > 0 && n < (int)sizeof(line)) vsnprintf(line + n, sizeof(line) - (size_t)n, fmt, ap);
    fprintf(stderr, "%s\n", line);
    fflush(stderr);
}

__attribute__((format(printf, 1, 2)))
static void host_log(const char *fmt, ...) {
    va_list ap;
    va_start(ap, fmt);
    vlog("plugin_host", fmt, ap);
    va_end(ap);
}

static int name_ok(const char *s, size_t n, const char *extra) {
    if (!n || n >= NAME_LEN) return 0;
    for (size_t i = 0; i < n; i++) {
        char c = s[i];
        if ((c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z') || (c >= '0' && c <= '9') || c == '_') continue;
        if (!strchr(extra, c)) return 0;
    }
    return 1;
}

static int hex_byte(const char *s, unsigned char *out) {
    unsigned v = 0;
    for (int i = 0; i < 2; i++) {
        char c = s[i];
        v <<= 4;
        if (c >= '0' && c <= '9') v |= (unsigned)(c - '0');
        else if (c >= 'a' && c <= 'f') v |= (unsigned)(c - 'a' + 10);
        else if (c >= 'A' && c <= 'F') v |= (unsigned)(c - 'A' + 10);
        else return 0;
    }
    *out = (unsigned char)v;
    return 1;
}

static const char *parse_form(struct form *f, const char *s, const char *end) {
    int literal = 0, writes = 0;
    while (s < end) {
        while (s < end && *s == ' ') s++;
        if (s >= end) break;
        const char *tok = s;
        while (s < end && *s != ' ') s++;
        size_t n = (size_t)(s - tok);
        if (f->len >= BYTES_MAX) return "a form is longer than 128 bytes";
        int i = f->len++;
        if (n == 2 && tok[0] == '?' && tok[1] == '?') {
            f->any[i] = 1;
        } else if (n == 2 && hex_byte(tok, &f->want[i])) {
            literal++;
        } else if (n == 5 && tok[2] == '=' && hex_byte(tok, &f->want[i]) && hex_byte(tok + 3, &f->put[i])) {
            f->set[i] = 1;
            literal++;
            writes++;
        } else {
            return "a byte is not XX, ?? or XX=YY";
        }
    }
    if (!writes) return "a form changes no byte";
    if (literal < 4) return "a form has fewer than 4 fixed bytes";
    return NULL;
}

static int pe_module(const char *module, char *trigger) {
    static const char *const exts[] = { "dll", "drv", "sys", "exe" };
    const char *dot = strrchr(module, '.');
    if (!dot || dot == module) return 0;
    for (size_t i = 0; i < sizeof(exts) / sizeof(*exts); i++)
        if (strcasecmp(dot + 1, exts[i]) == 0) {
            snprintf(trigger, NAME_LEN, "%.*s.so", (int)(dot - module), module);
            return 1;
        }
    return 0;
}

static void drop_plugin(const char *plugin) {
    int kept = 0;
    for (int i = 0; i < g_npatches; i++)
        if (strcmp(g_patches[i].plugin, plugin) != 0) g_patches[kept++] = g_patches[i];
    g_npatches = kept;
}

static const char *parse_patch(struct patch *p, const char *s, const char *end) {
    const char *colon = memchr(s, ':', (size_t)(end - s));
    if (!colon) return "it names no module";
    const char *m = s, *me = colon;
    while (m < me && *m == ' ') m++;
    while (me > m && me[-1] == ' ') me--;
    if (!name_ok(m, (size_t)(me - m), ".+-")) return "the module is not a file name";
    memcpy(p->module, m, (size_t)(me - m));
    p->pe = pe_module(p->module, p->trigger);
    if (!p->pe) snprintf(p->trigger, sizeof(p->trigger), "%s", p->module);
    for (const char *f = colon + 1; f < end;) {
        const char *bar = memchr(f, '|', (size_t)(end - f));
        if (!bar) bar = end;
        if (p->nforms >= FORMS_MAX) return "it has more than 4 forms";
        const char *why = parse_form(&p->forms[p->nforms++], f, bar);
        if (why) return why;
        f = bar < end ? bar + 1 : end;
    }
    return p->nforms ? NULL : "it has no bytes";
}

static void parse_spec(const char *spec) {
    static char broken[PATCHES_MAX][NAME_LEN];
    int nbroken = 0;
    const char *rec = spec;
    while (*rec) {
        const char *end = strchr(rec, ';');
        if (!end) end = rec + strlen(rec);
        const char *colon = memchr(rec, ':', (size_t)(end - rec));
        static struct patch p;
        memset(&p, 0, sizeof(p));

        if (!colon || !name_ok(rec, (size_t)(colon - rec), "")) {
            host_log("a patch record is unreadable, ignored: %.*s", (int)(end - rec), rec);
            rec = *end ? end + 1 : end;
            continue;
        }
        memcpy(p.plugin, rec, (size_t)(colon - rec));
        const char *why = parse_patch(&p, colon + 1, end);

        int known = 0;
        for (int i = 0; i < nbroken; i++) known |= strcmp(broken[i], p.plugin) == 0;
        if (why) {
            host_log("%s: a patch is skipped as %s, so are the plugin's others", p.plugin, why);
            if (!known && nbroken < PATCHES_MAX) memcpy(broken[nbroken++], p.plugin, NAME_LEN);
        } else if (!known) {
            if (g_npatches < PATCHES_MAX) g_patches[g_npatches++] = p;
            else host_log("%s: more than %d patches in all, the rest are ignored", p.plugin, PATCHES_MAX);
        }
        rec = *end ? end + 1 : end;
    }
    for (int i = 0; i < nbroken; i++) drop_plugin(broken[i]);
}

static int region_at(uintptr_t addr, uintptr_t *start, size_t *size, vm_prot_t *prot) {
    mach_vm_address_t a = addr;
    mach_vm_size_t s = 0;
    vm_region_basic_info_data_64_t info;
    mach_msg_type_number_t n = VM_REGION_BASIC_INFO_COUNT_64;
    mach_port_t object = MACH_PORT_NULL;
    if (mach_vm_region(mach_task_self(), &a, &s, VM_REGION_BASIC_INFO_64, (vm_region_info_t)&info, &n,
                       &object) != KERN_SUCCESS)
        return 0;
    *start = (uintptr_t)a;
    *size = (size_t)s;
    *prot = info.protection;
    return 1;
}

static int range_has(uintptr_t addr, size_t len, vm_prot_t need) {
    uintptr_t end = addr + len;
    while (addr < end) {
        uintptr_t start;
        size_t size;
        vm_prot_t prot;
        if (!region_at(addr, &start, &size, &prot) || start > addr || (prot & need) != need) return 0;
        addr = start + size;
    }
    return 1;
}

static int copy_in(uintptr_t addr, void *buf, size_t len) {
    mach_vm_size_t got = 0;
    return mach_vm_read_overwrite(mach_task_self(), addr, len, (mach_vm_address_t)(uintptr_t)buf, &got)
               == KERN_SUCCESS && got == len;
}

static uint16_t rd16(const unsigned char *p) { return (uint16_t)(p[0] | p[1] << 8); }
static uint32_t rd32(const unsigned char *p) { return (uint32_t)rd16(p) | (uint32_t)rd16(p + 2) << 16; }

static int pe_image(uintptr_t base, const char *name, struct image *img) {
    unsigned char h[0x1000];
    if (!copy_in(base, h, sizeof(h)) || h[0] != 'M' || h[1] != 'Z') return 0;
    uint32_t pe = rd32(h + 0x3c);
    if (pe < 0x40 || pe > sizeof(h) - 0x108 || memcmp(h + pe, "PE\0\0", 4) != 0) return 0;
    unsigned nsec = rd16(h + pe + 6), optsize = rd16(h + pe + 20);
    const unsigned char *opt = h + pe + 24;
    unsigned magic = rd16(opt);
    size_t dirs = magic == 0x20b ? 112 : magic == 0x10b ? 96 : 0;
    if (!dirs || optsize < dirs + 8) return 0;
    uint32_t image_size = rd32(opt + 56);
    size_t sec = pe + 24 + optsize;
    if (nsec == 0 || sec + (size_t)nsec * 40 > sizeof(h)) return 0;

    if (name) {
        uint32_t exp = rd32(opt + dirs), exp_size = rd32(opt + dirs + 4);
        unsigned char ed[40];
        char got[NAME_LEN];
        if (!exp || exp_size < 40 || exp >= image_size || !copy_in(base + exp, ed, sizeof(ed))) return 0;
        uint32_t name_rva = rd32(ed + 12);
        if (!name_rva || name_rva >= image_size || !copy_in(base + name_rva, got, sizeof(got))) return 0;
        got[NAME_LEN - 1] = 0;
        if (strcasecmp(got, name) != 0) return 0;
    }

    img->base = base;
    img->nsections = 0;
    for (unsigned i = 0; i < nsec && img->nsections < SECTIONS_MAX; i++) {
        const unsigned char *s = h + sec + i * 40;
        uint32_t vsize = rd32(s + 8), va = rd32(s + 12), flags = rd32(s + 36);
        if (!(flags & IMAGE_SCN_MEM_EXECUTE) || !vsize || va >= image_size) continue;
        if ((uint64_t)va + vsize > image_size) vsize = image_size - va;
        img->code[img->nsections].start = base + va;
        img->code[img->nsections].size = vsize;
        img->nsections++;
    }
    // LoadLibraryEx(LOAD_LIBRARY_AS_DATAFILE) maps the same file flat and read-only
    if (!img->nsections || !range_has(img->code[0].start, 1, VM_PROT_READ | VM_PROT_EXECUTE)) return 0;
    for (int i = 0; i < img->nsections; i++)
        if (!range_has(img->code[i].start, img->code[i].size, VM_PROT_READ)) return 0;
    return 1;
}

#if !defined(__arm64__)
static const struct load_command *next_command(const struct mach_header_64 *mh, const struct load_command *c) {
    const unsigned char *lc = c ? (const unsigned char *)c + c->cmdsize : (const unsigned char *)(mh + 1);
    const unsigned char *end = (const unsigned char *)(mh + 1) + mh->sizeofcmds;
    const struct load_command *n = (const struct load_command *)lc;
    if (lc + sizeof(*n) > end || n->cmdsize < sizeof(*n) || lc + n->cmdsize > end) return NULL;
    return n;
}

#define EACH_COMMAND(mh, c) \
    for (uint32_t c##_i = 0; c##_i < (mh)->ncmds && ((c = next_command((mh), c##_i ? c : NULL))); c##_i++)

static int macho_image(const struct mach_header *mh, intptr_t slide, struct image *img) {
    if (mh->magic != MH_MAGIC_64) return 0;
    const struct mach_header_64 *h = (const struct mach_header_64 *)mh;
    const struct load_command *c = NULL;
    img->base = (uintptr_t)mh;
    img->nsections = 0;
    EACH_COMMAND(h, c) {
        if (c->cmd != LC_SEGMENT_64) continue;
        const struct segment_command_64 *seg = (const struct segment_command_64 *)c;
        const struct section_64 *s = (const struct section_64 *)(seg + 1);
        if (sizeof(*seg) + (size_t)seg->nsects * sizeof(*s) > c->cmdsize) return 0;
        if (!(seg->initprot & VM_PROT_EXECUTE)) continue;
        for (uint32_t k = 0; k < seg->nsects && img->nsections < SECTIONS_MAX; k++) {
            if (!s[k].size || (s[k].flags & SECTION_TYPE) == S_ZEROFILL) continue;
            img->code[img->nsections].start = (uintptr_t)(s[k].addr + (uint64_t)slide);
            img->code[img->nsections].size = (size_t)s[k].size;
            img->nsections++;
        }
    }
    return img->nsections > 0;
}
#endif

static const char *base_name(const char *path) {
    const char *slash = strrchr(path, '/');
    return slash ? slash + 1 : path;
}

static int images_by_file(const char *module, struct image *out, int max) {
    struct proc_regionwithpathinfo info;
    uint64_t addr = 0;
    int found = 0;
    while (found < max) {
        memset(&info, 0, sizeof(info));
        if (proc_pidinfo(getpid(), PROC_PIDREGIONPATHINFO, addr, &info, sizeof(info)) != (int)sizeof(info))
            break;
        uint64_t start = info.prp_prinfo.pri_address, size = info.prp_prinfo.pri_size;
        if (!size || start + size <= addr) break;
        if (info.prp_vip.vip_path[0] && strcasecmp(base_name(info.prp_vip.vip_path), module) == 0
            && pe_image((uintptr_t)start, NULL, &out[found]))
            found++;
        addr = start + size;
    }
    return found;
}

static int images_by_scan(const char *module, struct image *out, int max) {
    uintptr_t addr = 0;
    int found = 0;
    while (found < max) {
        uintptr_t start;
        size_t size;
        vm_prot_t prot;
        if (!region_at(addr, &start, &size, &prot) || !size) break;
        if (prot & VM_PROT_READ) {
            for (uintptr_t a = start; a < start + size && found < max;
                 a = (a + 0x10000) & ~(uintptr_t)0xffff) {
                unsigned char mz[2];
                if (copy_in(a, mz, 2) && mz[0] == 'M' && mz[1] == 'Z' && pe_image(a, module, &out[found]))
                    found++;
            }
        }
        addr = start + size;
    }
    return found;
}

static int matches_at(const unsigned char *m, const struct form *f) {
    for (int i = 0; i < f->len; i++)
        if (!f->any[i] && m[i] != f->want[i]) return 0;
    return 1;
}

static int find_form(const struct image *img, const struct form *f, uintptr_t *site) {
    int anchor = 0, count = 0;
    while (f->any[anchor]) anchor++;
    for (int s = 0; s < img->nsections; s++) {
        const unsigned char *lo = (const unsigned char *)img->code[s].start;
        size_t size = img->code[s].size;
        if (size < (size_t)f->len) continue;
        const unsigned char *last = lo + size - f->len;
        for (const unsigned char *c = lo + anchor; c <= last + anchor;) {
            c = memchr(c, f->want[anchor], (size_t)(last + anchor - c) + 1);
            if (!c) break;
            if (matches_at(c - anchor, f) && count++ == 0) *site = (uintptr_t)(c - anchor);
            c++;
        }
    }
    return count;
}

static int find_patch(const struct image *img, const struct patch *p, uintptr_t *site, int *form) {
    int total = 0;
    for (int k = 0; k < p->nforms; k++) {
        uintptr_t at = 0;
        int n = find_form(img, &p->forms[k], &at);
        if (n && !total) {
            *site = at;
            *form = k;
        }
        total += n;
    }
    return total;
}

static int write_bytes(uintptr_t addr, const unsigned char *src, size_t len) {
    uintptr_t page_size = (uintptr_t)getpagesize();
    while (len) {
        uintptr_t page = addr & ~(page_size - 1), start;
        size_t chunk = page + page_size - addr, size;
        vm_prot_t prot;
        if (chunk > len) chunk = len;
        if (!region_at(page, &start, &size, &prot) || start > page) return 0;
        if (mach_vm_protect(mach_task_self(), page, page_size, FALSE,
                            VM_PROT_READ | VM_PROT_WRITE | VM_PROT_EXECUTE | VM_PROT_COPY) != KERN_SUCCESS
            && mach_vm_protect(mach_task_self(), page, page_size, FALSE,
                               VM_PROT_READ | VM_PROT_WRITE | VM_PROT_COPY) != KERN_SUCCESS)
            return 0;
        memcpy((void *)addr, src, chunk);
        sys_icache_invalidate((void *)addr, chunk);
        if (mach_vm_protect(mach_task_self(), page, page_size, FALSE, prot) != KERN_SUCCESS) return 0;
        addr += chunk;
        src += chunk;
        len -= chunk;
    }
    return 1;
}

static int applied(const char *plugin, uintptr_t base) {
    for (int i = 0; i < g_napplied; i++)
        if (g_applied[i].base == base && strcmp(g_applied[i].plugin, plugin) == 0) return 1;
    return 0;
}

static int write_form(uintptr_t site, const struct form *f, uintptr_t base, char *where, size_t *used, size_t cap) {
    for (int i = 0; i < f->len; i++) {
        if (!f->set[i]) continue;
        int run = 1;
        while (i + run < f->len && f->set[i + run]) run++;
        if (!write_bytes(site + (uintptr_t)i, f->put + i, (size_t)run)
            || memcmp((void *)(site + (uintptr_t)i), f->put + i, (size_t)run) != 0)
            return 0;
        int w = snprintf(where + *used, cap - *used, "%s+%#lx", *used ? " " : "",
                         (unsigned long)(site + (uintptr_t)i - base));
        if (w > 0 && (size_t)w < cap - *used) *used += (size_t)w;
        i += run - 1;
    }
    return 1;
}

static void patch_image(const struct image *img, const char *module, const char *plugin) {
    static unsigned char saved[PATCHES_MAX][BYTES_MAX];
    uintptr_t sites[PATCHES_MAX];
    int idx[PATCHES_MAX], forms[PATCHES_MAX], n = 0;
    char where[512];
    size_t used = 0;

    if (applied(plugin, img->base)) return;
    for (int i = 0; i < g_npatches; i++) {
        const struct patch *p = &g_patches[i];
        if (strcmp(p->plugin, plugin) != 0 || strcasecmp(p->module, module) != 0) continue;
        int count = find_patch(img, p, &sites[n], &forms[n]);
        if (count != 1) {
            host_log("%s: %s at %#lx is left alone as its patch %d is found %d times, not once",
                     plugin, module, (unsigned long)img->base, n + 1, count);
            return;
        }
        idx[n++] = i;
    }
    if (!n) return;

    where[0] = 0;
    for (int k = 0; k < n; k++) {
        const struct form *f = &g_patches[idx[k]].forms[forms[k]];
        memcpy(saved[k], (const void *)sites[k], (size_t)f->len);
        if (write_form(sites[k], f, img->base, where, &used, sizeof(where))) continue;
        int undone = 1;
        for (int j = k; j >= 0; j--) {
            const struct form *g = &g_patches[idx[j]].forms[forms[j]];
            if (memcmp((const void *)sites[j], saved[j], (size_t)g->len) != 0)
                undone &= write_bytes(sites[j], saved[j], (size_t)g->len);
        }
        host_log("%s: %s at %#lx could not be written, %s", plugin, module, (unsigned long)img->base,
                 undone ? "so it is put back as it was" : "and could not be put back, it is half patched");
        return;
    }
    if (g_napplied < APPLIED_MAX) {
        memcpy(g_applied[g_napplied].plugin, plugin, NAME_LEN);
        snprintf(g_applied[g_napplied].module, NAME_LEN, "%s", module);
        g_applied[g_napplied++].base = img->base;
    }
    host_log("%s: patched %s at %#lx (%s)", plugin, module, (unsigned long)img->base, where);
}

static void patch_plugins(const struct image *img, const char *module) {
    for (int i = 0; i < g_npatches; i++) {
        if (strcasecmp(g_patches[i].module, module) != 0) continue;
        int first = 1;
        for (int j = 0; j < i; j++)
            if (strcmp(g_patches[j].plugin, g_patches[i].plugin) == 0
                && strcasecmp(g_patches[j].module, module) == 0)
                first = 0;
        if (first) patch_image(img, module, g_patches[i].plugin);
    }
}

static void patch_pe_module(const char *module) {
    struct image imgs[IMAGES_MAX];
    int n = images_by_file(module, imgs, IMAGES_MAX);
    if (!n) n = images_by_scan(module, imgs, IMAGES_MAX);
    if (!n) {
        host_log("%s's unix half loaded but %s isn't mapped, nothing patched", module, module);
        return;
    }
    for (int m = 0; m < n; m++) patch_plugins(&imgs[m], module);
}

static void patch_macho_module(const char *module, const struct mach_header *mh, intptr_t slide) {
    struct image img;
#if defined(__arm64__)
    (void)mh;
    (void)slide;
    (void)img;
    host_log("%s is left alone, arm64 code can't be changed without breaking its signature", module);
#else
    if (!macho_image(mh, slide, &img)) {
        host_log("%s has no code section this can read, nothing patched", module);
        return;
    }
    patch_plugins(&img, module);
#endif
}

static void on_add_image(const struct mach_header *mh, intptr_t slide) {
    Dl_info info;
    if (!dladdr(mh, &info) || !info.dli_fname) return;
    const char *name = base_name(info.dli_fname);
    for (int i = 0; i < g_npatches; i++) {
        if (strcasecmp(g_patches[i].trigger, name) != 0) continue;
        int first = 1;
        for (int j = 0; j < i; j++) first &= strcasecmp(g_patches[j].module, g_patches[i].module) != 0;
        if (!first) continue;
        if (g_patches[i].pe) patch_pe_module(g_patches[i].module);
        else patch_macho_module(g_patches[i].module, mh, slide);
    }
}

static void on_remove_image(const struct mach_header *mh, intptr_t slide) {
    Dl_info info;
    (void)slide;
    if (!dladdr(mh, &info) || !info.dli_fname) return;
    const char *name = base_name(info.dli_fname);
    int kept = 0;
    for (int i = 0; i < g_napplied; i++) {
        int gone = 0;
        for (int j = 0; j < g_npatches && !gone; j++)
            gone = strcasecmp(g_patches[j].trigger, name) == 0
                   && strcasecmp(g_patches[j].module, g_applied[i].module) == 0;
        if (!gone) g_applied[kept++] = g_applied[i];
    }
    g_napplied = kept;
}

__attribute__((constructor))
static void plugin_host_init(void) {
    const char *spec = getenv("NOTPROTON_PLUGIN_PATCHES");
    if (!spec || !*spec) return;
    parse_spec(spec);
    if (!g_npatches) return;
    _dyld_register_func_for_add_image(on_add_image);
    _dyld_register_func_for_remove_image(on_remove_image);
}
