// Plugin host
#include "notproton_plugin.h"

#include <dlfcn.h>
#include <libkern/OSCacheControl.h>
#include <libproc.h>
#include <mach/mach.h>
#include <mach/mach_vm.h>
#include <mach-o/dyld.h>
#include <mach-o/loader.h>
#include <mach-o/nlist.h>
#include <os/lock.h>
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
#define WATCHES_MAX 16
#define PATH_CONTAINS_LEN 128

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
    int arch;
    int nforms;
    struct form forms[FORMS_MAX];
};

enum { ARCH_ANY, ARCH_X86_64, ARCH_ARM64, ARCH_I386 };
static const char *const g_arch_names[] = { "any", "x86_64", "arm64", "i386" };

struct span {
    uintptr_t start;
    size_t size;
};

struct image {
    uintptr_t base;
    int arch;
    int nsections;
    struct span code[SECTIONS_MAX];
};

static struct patch g_patches[PATCHES_MAX];
static int g_npatches;
static os_unfair_lock g_patch_lock = OS_UNFAIR_LOCK_INIT;

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
    const char *slash = memchr(m, '/', (size_t)(me - m));
    if (slash) {
        size_t n = (size_t)(me - slash - 1);
        for (int a = ARCH_X86_64; a <= ARCH_I386 && !p->arch; a++)
            if (strlen(g_arch_names[a]) == n && memcmp(slash + 1, g_arch_names[a], n) == 0) p->arch = a;
        if (!p->arch) return "its architecture is not x86_64, arm64 or i386";
        me = slash;
    }
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

static int pe_arch(unsigned machine, int chpe) {
    if (machine == 0xaa64 || machine == 0xa641 || (machine == 0x8664 && chpe)) return ARCH_ARM64;
    if (machine == 0x8664) return ARCH_X86_64;
    return machine == 0x14c ? ARCH_I386 : ARCH_ANY;
}

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

    int chpe = 0;
    uint32_t cfg = rd32(opt + dirs + 80), cfg_size = rd32(opt + dirs + 84);
    unsigned char lc[0xd0];
    if (magic == 0x20b && cfg && cfg_size >= sizeof(lc) && cfg < image_size && copy_in(base + cfg, lc, sizeof(lc)))
        chpe = rd32(lc) >= sizeof(lc) && (rd32(lc + 0xc8) || rd32(lc + 0xcc));
    img->arch = pe_arch(rd16(h + pe + 4), chpe);
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

static const struct load_command *next_command(const struct mach_header_64 *mh, const struct load_command *c) {
    const unsigned char *lc = c ? (const unsigned char *)c + c->cmdsize : (const unsigned char *)(mh + 1);
    const unsigned char *end = (const unsigned char *)(mh + 1) + mh->sizeofcmds;
    const struct load_command *n = (const struct load_command *)lc;
    if (lc + sizeof(*n) > end || n->cmdsize < sizeof(*n) || lc + n->cmdsize > end) return NULL;
    return n;
}

#define EACH_COMMAND(mh, c) \
    for (uint32_t c##_i = 0; c##_i < (mh)->ncmds && ((c = next_command((mh), c##_i ? c : NULL))); c##_i++)

#if !defined(__arm64__)
static int macho_image(const struct mach_header *mh, intptr_t slide, struct image *img) {
    if (mh->magic != MH_MAGIC_64) return 0;
    const struct mach_header_64 *h = (const struct mach_header_64 *)mh;
    const struct load_command *c = NULL;
    img->arch = ARCH_X86_64;
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

static int patch_image(const struct image *img, const char *module, const char *plugin) {
    static unsigned char saved[PATCHES_MAX][BYTES_MAX];
    uintptr_t sites[PATCHES_MAX];
    int idx[PATCHES_MAX], forms[PATCHES_MAX], n = 0;
    char where[512];
    size_t used = 0;

    if (applied(plugin, img->base)) return 0;
    for (int i = 0; i < g_npatches; i++) {
        const struct patch *p = &g_patches[i];
        if (strcmp(p->plugin, plugin) != 0 || strcasecmp(p->module, module) != 0) continue;
        if (p->arch && p->arch != img->arch) continue;
        int count = find_patch(img, p, &sites[n], &forms[n]);
        if (count != 1) {
            host_log("%s: %s at %#lx is left alone as its patch %d is found %d times, not once",
                     plugin, module, (unsigned long)img->base, n + 1, count);
            return 0;
        }
        idx[n++] = i;
    }
    if (!n) return 0;

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
        return 0;
    }
    if (g_napplied < APPLIED_MAX) {
        memcpy(g_applied[g_napplied].plugin, plugin, NAME_LEN);
        snprintf(g_applied[g_napplied].module, NAME_LEN, "%s", module);
        g_applied[g_napplied++].base = img->base;
    }
    host_log("%s: patched %s at %#lx (%s)", plugin, module, (unsigned long)img->base, where);
    return 1;
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
    if (!__atomic_load_n(&g_npatches, __ATOMIC_ACQUIRE) || !dladdr(mh, &info) || !info.dli_fname) return;
    const char *name = base_name(info.dli_fname);
    os_unfair_lock_lock(&g_patch_lock);
    for (int i = 0; i < g_npatches; i++) {
        if (strcasecmp(g_patches[i].trigger, name) != 0) continue;
        int first = 1;
        for (int j = 0; j < i; j++) first &= strcasecmp(g_patches[j].module, g_patches[i].module) != 0;
        if (!first) continue;
        if (g_patches[i].pe) patch_pe_module(g_patches[i].module);
        else patch_macho_module(g_patches[i].module, mh, slide);
    }
    os_unfair_lock_unlock(&g_patch_lock);
}

static void on_remove_image(const struct mach_header *mh, intptr_t slide) {
    Dl_info info;
    (void)slide;
    if (!__atomic_load_n(&g_npatches, __ATOMIC_ACQUIRE) || !dladdr(mh, &info) || !info.dli_fname) return;
    const char *name = base_name(info.dli_fname);
    int kept = 0;
    os_unfair_lock_lock(&g_patch_lock);
    for (int i = 0; i < g_napplied; i++) {
        int gone = 0;
        for (int j = 0; j < g_npatches && !gone; j++)
            gone = strcasecmp(g_patches[j].trigger, name) == 0
                   && strcasecmp(g_patches[j].module, g_applied[i].module) == 0;
        if (!gone) g_applied[kept++] = g_applied[i];
    }
    g_napplied = kept;
    os_unfair_lock_unlock(&g_patch_lock);
}

static int patch_loaded(const struct patch *p) {
    struct image imgs[IMAGES_MAX];
    int n = 0, done = 0;
    if (p->pe) {
        n = images_by_file(p->module, imgs, IMAGES_MAX);
    } else {
        for (uint32_t i = 0; i < _dyld_image_count() && n < IMAGES_MAX; i++) {
            const char *name = _dyld_get_image_name(i);
            const struct mach_header *mh = _dyld_get_image_header(i);
            if (!name || !mh || strcasecmp(base_name(name), p->module) != 0) continue;
#if defined(__arm64__)
            host_log("%s is left alone, arm64 code can't be changed without breaking its signature", p->module);
#else
            if (macho_image(mh, _dyld_get_image_vmaddr_slide(i), &imgs[n])) n++;
#endif
        }
    }
    os_unfair_lock_lock(&g_patch_lock);
    for (int m = 0; m < n; m++) done += patch_image(&imgs[m], p->module, p->plugin);
    os_unfair_lock_unlock(&g_patch_lock);
    return done;
}

static void watch_pe(int from, int to);

static int api_patch(const char *tag, const char *patches) {
    static int groups;
    char group[NAME_LEN];
    const char *why = NULL;
    if (!patches) return -1;
    os_unfair_lock_lock(&g_patch_lock);
    int base = g_npatches, n = 0;
    snprintf(group, sizeof(group), "%.40s#%d", tag && *tag ? tag : "plugin", ++groups);
    for (const char *s = patches; *s && !why;) {
        const char *end = strchr(s, ';');
        if (!end) end = s + strlen(s);
        if (base + n >= PATCHES_MAX) {
            why = "there are too many patches";
        } else {
            struct patch *p = &g_patches[base + n++];
            memset(p, 0, sizeof(*p));
            memcpy(p->plugin, group, NAME_LEN);
            why = parse_patch(p, s, end);
        }
        s = *end ? end + 1 : end;
    }
    if (!why && !n) why = "it has no bytes";
    if (!why) __atomic_store_n(&g_npatches, base + n, __ATOMIC_RELEASE);
    os_unfair_lock_unlock(&g_patch_lock);
    if (why) {
        host_log("%s: a patch is refused as %s, so are the ones given with it", group, why);
        return -1;
    }
    watch_pe(base, base + n);
    int done = 0;
    for (int i = base; i < base + n; i++) {
        int first = 1;
        for (int j = base; j < i; j++) first &= strcasecmp(g_patches[j].module, g_patches[i].module) != 0;
        if (first) done += patch_loaded(&g_patches[i]);
    }
    return done;
}

static struct {
    char name[NAME_LEN];
    char path_contains[PATH_CONTAINS_LEN];
    np_image_fn fn;
    int fired;
} g_watches[WATCHES_MAX];
static int g_nwatches;
static int g_watching;
static os_unfair_lock g_watch_lock = OS_UNFAIR_LOCK_INIT;

static void watch_image(const struct mach_header *mh, intptr_t slide) {
    Dl_info info;
    int n = __atomic_load_n(&g_nwatches, __ATOMIC_ACQUIRE);
    if (!n || mh->magic != MH_MAGIC_64 || !dladdr(mh, &info) || !info.dli_fname) return;
    const char *path = info.dli_fname;
    for (int i = 0; i < n; i++) {
        if (strcmp(base_name(path), g_watches[i].name) != 0) continue;
        if (g_watches[i].path_contains[0] && !strstr(path, g_watches[i].path_contains)) continue;
        if (__atomic_exchange_n(&g_watches[i].fired, 1, __ATOMIC_ACQ_REL)) continue;
        g_watches[i].fn((const struct mach_header_64 *)mh, slide, path);
    }
}

static void replay_loaded_images(void) {
    for (uint32_t i = 0; i < _dyld_image_count(); i++) {
        const struct mach_header *mh = _dyld_get_image_header(i);
        if (mh) watch_image(mh, _dyld_get_image_vmaddr_slide(i));
    }
}

static int api_on_first_image(const char *name, const char *path_contains, np_image_fn fn) {
    if (!name || !fn || strlen(name) >= NAME_LEN || (path_contains && strlen(path_contains) >= PATH_CONTAINS_LEN))
        return 0;
    os_unfair_lock_lock(&g_watch_lock);
    int n = g_nwatches;
    if (n >= WATCHES_MAX) {
        os_unfair_lock_unlock(&g_watch_lock);
        return 0;
    }
    snprintf(g_watches[n].name, NAME_LEN, "%s", name);
    snprintf(g_watches[n].path_contains, PATH_CONTAINS_LEN, "%s", path_contains ? path_contains : "");
    g_watches[n].fn = fn;
    __atomic_store_n(&g_nwatches, n + 1, __ATOMIC_RELEASE);
    int first = !g_watching;
    g_watching = 1;
    os_unfair_lock_unlock(&g_watch_lock);
    if (first) _dyld_register_func_for_add_image(watch_image);
    else replay_loaded_images();
    return 1;
}

static int symtab_of(const struct mach_header_64 *mh, intptr_t slide, const struct nlist_64 **syms,
                     uint32_t *nsyms, const char **strs, uint32_t *strsize) {
    const struct segment_command_64 *le = NULL;
    const struct symtab_command *st = NULL;
    const struct load_command *c = NULL;
    if (mh->magic != MH_MAGIC_64) return 0;
    EACH_COMMAND(mh, c) {
        if (c->cmd == LC_SEGMENT_64 && strncmp(((const struct segment_command_64 *)c)->segname, SEG_LINKEDIT, 16) == 0)
            le = (const struct segment_command_64 *)c;
        else if (c->cmd == LC_SYMTAB)
            st = (const struct symtab_command *)c;
    }
    if (!le || !st) return 0;
    uint64_t lo = le->fileoff, hi = le->fileoff + le->filesize;
    if (st->symoff < lo || st->symoff + (uint64_t)st->nsyms * sizeof(struct nlist_64) > hi
        || st->stroff < lo || st->stroff + (uint64_t)st->strsize > hi)
        return 0;
    uintptr_t base = (uintptr_t)(le->vmaddr + (uint64_t)slide - le->fileoff);
    *syms = (const struct nlist_64 *)(base + st->symoff);
    *strs = (const char *)(base + st->stroff);
    *nsyms = st->nsyms;
    *strsize = st->strsize;
    return 1;
}

static const char *defined_name(const struct nlist_64 *s, const char *strs, uint32_t strsize) {
    if ((s->n_type & N_STAB) || (s->n_type & N_TYPE) != N_SECT) return NULL;
    return s->n_un.n_strx && s->n_un.n_strx < strsize ? strs + s->n_un.n_strx : NULL;
}

static uintptr_t api_symbol(const struct mach_header_64 *mh, intptr_t slide, const char *name) {
    const struct nlist_64 *syms;
    const char *strs;
    uint32_t nsyms, strsize;
    if (!name || !symtab_of(mh, slide, &syms, &nsyms, &strs, &strsize)) return 0;
    for (uint32_t i = 0; i < nsyms; i++) {
        const char *n = defined_name(&syms[i], strs, strsize);
        if (n && strcmp(n, name) == 0) return (uintptr_t)(syms[i].n_value + (uint64_t)slide);
    }
    return 0;
}

static const char *api_symbol_name(const struct mach_header_64 *mh, intptr_t slide, uintptr_t addr) {
    const struct nlist_64 *syms;
    const char *strs;
    uint32_t nsyms, strsize;
    if (!symtab_of(mh, slide, &syms, &nsyms, &strs, &strsize)) return NULL;
    for (uint32_t i = 0; i < nsyms; i++) {
        const char *n = defined_name(&syms[i], strs, strsize);
        if (n && (uintptr_t)(syms[i].n_value + (uint64_t)slide) == addr) return n;
    }
    return NULL;
}

static int api_count_pointers(const struct mach_header_64 *mh, intptr_t slide, uintptr_t value, uintptr_t **first) {
    const struct load_command *c = NULL;
    int found = 0;
    if (mh->magic != MH_MAGIC_64) return 0;
    EACH_COMMAND(mh, c) {
        if (c->cmd != LC_SEGMENT_64) continue;
        const struct segment_command_64 *seg = (const struct segment_command_64 *)c;
        const struct section_64 *s = (const struct section_64 *)(seg + 1);
        if (strncmp(seg->segname, "__DATA", 6) != 0 || sizeof(*seg) + (size_t)seg->nsects * sizeof(*s) > c->cmdsize)
            continue;
        for (uint32_t k = 0; k < seg->nsects; k++) {
            uint8_t type = s[k].flags & SECTION_TYPE;
            if (type == S_ZEROFILL || type == S_GB_ZEROFILL || type == S_THREAD_LOCAL_ZEROFILL) continue;
            uintptr_t *w = (uintptr_t *)(uintptr_t)(s[k].addr + (uint64_t)slide);
            size_t words = (size_t)s[k].size / sizeof(uintptr_t);
            for (size_t i = 0; i < words; i++)
                if (w[i] == value && ++found == 1 && first) *first = &w[i];
        }
    }
    return found;
}

static int api_swap_pointer(uintptr_t *slot, uintptr_t expect, uintptr_t value) {
    uintptr_t page_size = (uintptr_t)getpagesize(), page = (uintptr_t)slot & ~(page_size - 1), start;
    size_t size;
    vm_prot_t prot = VM_PROT_READ;
    if (!region_at(page, &start, &size, &prot) || start > page) return 0;
    int opened = !(prot & VM_PROT_WRITE);
    if (opened && mach_vm_protect(mach_task_self(), page, page_size, FALSE,
                                  VM_PROT_READ | VM_PROT_WRITE | VM_PROT_COPY) != KERN_SUCCESS)
        return 0;
    int ok = __atomic_compare_exchange_n(slot, &expect, value, 0, __ATOMIC_ACQ_REL, __ATOMIC_ACQUIRE);
    if (opened) mach_vm_protect(mach_task_self(), page, page_size, FALSE, prot);
    return ok;
}

static int api_redirect(const struct mach_header_64 *mh, intptr_t slide, const char *symbol, uintptr_t replacement,
                        uintptr_t *original) {
    uintptr_t fn = api_symbol(mh, slide, symbol), *slot = NULL;
    if (!fn || !replacement || !original) {
        host_log("redirect: no %s, nothing changed", symbol ? symbol : "symbol");
        return 0;
    }
    int n = api_count_pointers(mh, slide, fn, &slot);
    if (n != 1) {
        host_log("redirect: %d pointers to %s, not one, nothing changed", n, symbol);
        return 0;
    }
    *original = fn;
    if (!api_swap_pointer(slot, fn, replacement)) {
        host_log("redirect: the pointer to %s could not be written", symbol);
        return 0;
    }
    return 1;
}

typedef int32_t (*map_fn)(void *section, void *process, void **addr, uintptr_t zero_bits, size_t commit,
                          const void *offset, size_t *size, int inherit, uint64_t alloc_type, uint64_t protect);
typedef int32_t (*map_ex_fn)(void *section, void *process, void **addr, const void *offset, size_t *size,
                             uint32_t alloc_type, uint32_t protect, void *params, uint32_t count);
static uintptr_t g_map, g_map_ex;
static int g_late;

static void patch_view(uintptr_t base) {
    struct proc_regionwithpathinfo info;
    unsigned char mz[2];
    const char *file = "";
    if (!copy_in(base, mz, 2) || mz[0] != 'M' || mz[1] != 'Z') return;
    memset(&info, 0, sizeof(info));
    if (proc_pidinfo(getpid(), PROC_PIDREGIONPATHINFO, base, &info, sizeof(info)) == (int)sizeof(info)
        && info.prp_prinfo.pri_address <= base && info.prp_vip.vip_path[0])
        file = base_name(info.prp_vip.vip_path);
    int n = __atomic_load_n(&g_npatches, __ATOMIC_ACQUIRE), named = 0;
    for (int i = 0; i < n && !named; i++)
        named = g_patches[i].pe && (!*file || strcasecmp(file, g_patches[i].module) == 0);
    if (!named) return;

    os_unfair_lock_lock(&g_patch_lock);
    int kept = 0;
    for (int i = 0; i < g_napplied; i++)
        if (g_applied[i].base != base) g_applied[kept++] = g_applied[i];
    g_napplied = kept;
    for (int i = 0; i < g_npatches; i++) {
        const struct patch *p = &g_patches[i];
        struct image img;
        int first = p->pe && (!*file || strcasecmp(file, p->module) == 0);
        for (int j = 0; j < i && first; j++) first = strcasecmp(g_patches[j].module, p->module) != 0;
        if (first && pe_image(base, *file ? NULL : p->module, &img)) patch_plugins(&img, p->module);
    }
    os_unfair_lock_unlock(&g_patch_lock);
}

static void after_map(void *process, void **addr, int32_t status) {
    static int looked;
    int n = __atomic_load_n(&g_npatches, __ATOMIC_ACQUIRE), pe = 0;
    for (int i = 0; i < n && !pe; i++) pe = g_patches[i].pe;
    if (!pe) return;
    if (!__atomic_exchange_n(&looked, 1, __ATOMIC_ACQ_REL)) {
        for (int i = 0; i < n; i++) {
            int first = g_patches[i].pe;
            for (int j = 0; j < i && first; j++)
                first = strcmp(g_patches[j].plugin, g_patches[i].plugin) != 0
                        || strcasecmp(g_patches[j].module, g_patches[i].module) != 0;
            if (first) patch_loaded(&g_patches[i]);
        }
    }
    if (status >= 0 && process == (void *)~(uintptr_t)0 && addr && *addr) patch_view((uintptr_t)*addr);
}

static int32_t map_hook(void *section, void *process, void **addr, uintptr_t zero_bits, size_t commit,
                        const void *offset, size_t *size, int inherit, uint64_t alloc_type, uint64_t protect) {
    int32_t status = ((map_fn)g_map)(section, process, addr, zero_bits, commit, offset, size, inherit, alloc_type,
                                     protect);
    after_map(process, addr, status);
    return status;
}

static int32_t map_ex_hook(void *section, void *process, void **addr, const void *offset, size_t *size,
                           uint32_t alloc_type, uint32_t protect, void *params, uint32_t count) {
    int32_t status = ((map_ex_fn)g_map_ex)(section, process, addr, offset, size, alloc_type, protect, params, count);
    after_map(process, addr, status);
    return status;
}

#if defined(__arm64__)
static int redirect_wrapper(const struct mach_header_64 *mh, intptr_t slide, uintptr_t fn, uintptr_t replacement,
                            uintptr_t *original) {
    const struct load_command *c = NULL;
    uintptr_t lo = 0, hi = 0, *slot = NULL, wrapper = 0;
    int found = 0;
    EACH_COMMAND(mh, c) {
        const struct segment_command_64 *seg = (const struct segment_command_64 *)c;
        if (c->cmd == LC_SEGMENT_64 && strcmp(seg->segname, "__TEXT") == 0) {
            lo = (uintptr_t)(seg->vmaddr + (uint64_t)slide);
            hi = lo + (uintptr_t)seg->vmsize;
        }
    }
    c = NULL;
    EACH_COMMAND(mh, c) {
        const struct segment_command_64 *seg = (const struct segment_command_64 *)c;
        if (c->cmd != LC_SEGMENT_64 || strncmp(seg->segname, "__DATA", 6) != 0) continue;
        const struct section_64 *s = (const struct section_64 *)(seg + 1);
        for (uint32_t k = 0; k < seg->nsects; k++) {
            uint8_t type = s[k].flags & SECTION_TYPE;
            if (type == S_ZEROFILL || type == S_GB_ZEROFILL || type == S_THREAD_LOCAL_ZEROFILL) continue;
            uintptr_t *w = (uintptr_t *)(uintptr_t)(s[k].addr + (uint64_t)slide);
            for (size_t i = 0; i < (size_t)s[k].size / sizeof(uintptr_t); i++) {
                uintptr_t v = w[i];
                if (v < lo || v + 16 > hi || (v & 3)) continue;
                for (int n = 0; n < 4; n++) {
                    uint32_t insn = ((const uint32_t *)v)[n];
                    if ((insn & 0xfc000000u) != 0x14000000u) continue;
                    int64_t off = (int64_t)((int32_t)(insn << 6) >> 6) * 4;
                    if (v + 4 * (uintptr_t)n + (uintptr_t)off == fn && ++found == 1) {
                        slot = &w[i];
                        wrapper = v;
                    }
                    break;
                }
            }
        }
    }
    if (found != 1) {
        host_log("redirect: %d wrappers of NtMapViewOfSection, not one, nothing changed", found);
        return 0;
    }
    *original = wrapper;
    return api_swap_pointer(slot, wrapper, replacement);
}
#endif

static int redirect_map(const struct mach_header_64 *mh, intptr_t slide) {
#if defined(__arm64__)
    // arm64 Wine's syscall table points at a wrapper, not NtMapViewOfSection
    uintptr_t fn = api_symbol(mh, slide, "_NtMapViewOfSection");
    if (fn && !api_count_pointers(mh, slide, fn, NULL))
        return redirect_wrapper(mh, slide, fn, (uintptr_t)map_hook, &g_map);
#endif
    return api_redirect(mh, slide, "_NtMapViewOfSection", (uintptr_t)map_hook, &g_map);
}

static void watch_maps(const struct mach_header_64 *mh, intptr_t slide, const char *path) {
    int map = redirect_map(mh, slide);
    int map_ex = api_redirect(mh, slide, "_NtMapViewOfSectionEx", (uintptr_t)map_ex_hook, &g_map_ex);
    if (!map || !map_ex) host_log("%s: only modules with a unix half get their patches", path);
    if (g_late) after_map(NULL, NULL, -1);
}

static void watch_pe(int from, int to) {
    static int armed;
    int pe = 0;
    for (int i = from; i < to && !pe; i++) pe = g_patches[i].pe;
    if (pe && !__atomic_exchange_n(&armed, 1, __ATOMIC_ACQ_REL)) api_on_first_image("ntdll.so", "-unix/", watch_maps);
}

static uint64_t be_int(const unsigned char *p, int n) {
    uint64_t v = 0;
    while (n--) v = v << 8 | *p++;
    return v;
}

static int bplist_obj(const unsigned char *b, uint64_t area, uint64_t off, int *type, uint64_t *count,
                      uint64_t *data) {
    if (off >= area) return 0;
    *type = b[off] >> 4;
    *count = b[off] & 0xf;
    *data = off + 1;
    if (*count == 0xf) {
        if (*data >= area || (b[*data] >> 4) != 1 || (b[*data] & 0xf) > 3) return 0;
        int n = 1 << (b[*data] & 0xf);
        if (*data + 1 + (uint64_t)n > area) return 0;
        *count = be_int(b + *data + 1, n);
        *data += 1 + (uint64_t)n;
    }
    return *count <= area && *data + *count <= area;
}

static int bplist_string(const unsigned char *b, size_t len, const char *key, char *out, size_t outsz) {
    if (len < 40 || memcmp(b, "bplist00", 8) != 0) return 0;
    const unsigned char *t = b + len - 32;
    int osz = t[6], rsz = t[7];
    uint64_t nobj = be_int(t + 8, 8), top = be_int(t + 16, 8), table = be_int(t + 24, 8), area = len - 32;
    if (osz < 1 || osz > 8 || rsz < 1 || rsz > 8 || top >= nobj || table > area || nobj > (area - table) / (uint64_t)osz)
        return 0;
    int type;
    uint64_t count, data, klen = strlen(key);
    if (!bplist_obj(b, table, be_int(b + table + top * (uint64_t)osz, osz), &type, &count, &data) || type != 0xd
        || data + 2 * count * (uint64_t)rsz > table)
        return 0;
    for (uint64_t i = 0; i < count; i++) {
        uint64_t kref = be_int(b + data + i * (uint64_t)rsz, rsz), vref = be_int(b + data + (count + i) * (uint64_t)rsz, rsz);
        int kt, vt;
        uint64_t kn, kd, vn, vd;
        if (kref >= nobj || vref >= nobj) return 0;
        if (!bplist_obj(b, table, be_int(b + table + kref * (uint64_t)osz, osz), &kt, &kn, &kd)) return 0;
        if (kt != 5 || kn != klen || memcmp(b + kd, key, klen) != 0) continue;
        if (!bplist_obj(b, table, be_int(b + table + vref * (uint64_t)osz, osz), &vt, &vn, &vd) || vt != 5
            || vn >= outsz)
            return 0;
        memcpy(out, b + vd, vn);
        out[vn] = 0;
        return 1;
    }
    return 0;
}

static int xml_string(const char *text, const char *key, char *out, size_t outsz) {
    char want[128];
    snprintf(want, sizeof(want), "<key>%s</key>", key);
    const char *k = strstr(text, want);
    if (!k) return 0;
    k += strlen(want);
    while (*k == ' ' || *k == '\t' || *k == '\r' || *k == '\n') k++;
    if (strncmp(k, "<string>", 8) != 0) return 0;
    k += 8;
    const char *e = strstr(k, "</string>");
    if (!e || (size_t)(e - k) >= outsz) return 0;
    memcpy(out, k, (size_t)(e - k));
    out[e - k] = 0;
    return 1;
}

static int api_bundle_short_version(const char *image_path, char *out, size_t len) {
    static unsigned char buf[64 * 1024 + 1];
    char plist[1024];
    const char *slash = image_path ? strrchr(image_path, '/') : NULL;
    if (!slash || !out || !len) return 0;
    snprintf(plist, sizeof(plist), "%.*s/Resources/Info.plist", (int)(slash - image_path), image_path);
    FILE *f = fopen(plist, "rb");
    if (!f) return 0;
    size_t n = fread(buf, 1, sizeof(buf) - 1, f);
    fclose(f);
    if (!n || n == sizeof(buf) - 1) return 0;
    buf[n] = 0;
    return bplist_string(buf, n, "CFBundleShortVersionString", out, len)
           || xml_string((const char *)buf, "CFBundleShortVersionString", out, len);
}

__attribute__((format(printf, 2, 3)))
static void api_log(const char *tag, const char *fmt, ...) {
    va_list ap;
    va_start(ap, fmt);
    vlog(tag && *tag ? tag : "plugin", fmt, ap);
    va_end(ap);
}

static const struct np_plugin_api g_api = {
    .version = NP_PLUGIN_API_VERSION,
    .log = api_log,
    .on_first_image = api_on_first_image,
    .symbol = api_symbol,
    .symbol_name = api_symbol_name,
    .count_pointers = api_count_pointers,
    .swap_pointer = api_swap_pointer,
    .bundle_short_version = api_bundle_short_version,
    .patch = api_patch,
    .redirect = api_redirect,
};

__attribute__((visibility("default")))
const struct np_plugin_api *np_plugin_api_get(unsigned version) {
    return version >= 1 && version <= NP_PLUGIN_API_VERSION ? &g_api : NULL;
}

#ifdef NP_PATCHCHECK
__attribute__((unused))
#else
__attribute__((constructor))
#endif
static void plugin_host_init(void) {
    for (uint32_t i = 0; i < _dyld_image_count() && !g_late; i++) {
        const char *name = _dyld_get_image_name(i);
        g_late = name && strstr(name, "-unix/ntdll.so") != NULL;
    }
    const char *spec = getenv("NOTPROTON_PLUGIN_PATCHES");
    if (spec && *spec) parse_spec(spec);
    watch_pe(0, __atomic_load_n(&g_npatches, __ATOMIC_ACQUIRE));
    _dyld_register_func_for_add_image(on_add_image);
    _dyld_register_func_for_remove_image(on_remove_image);
}
