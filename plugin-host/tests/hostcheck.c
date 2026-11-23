#include "check.h"
#include "../notproton_plugin.h"

#include <dlfcn.h>
#include <mach-o/dyld.h>
#include <stdint.h>
#include <sys/mman.h>
#include <unistd.h>

static uint16_t rd16(const unsigned char *p) { return (uint16_t)(p[0] | p[1] << 8); }
static uint32_t rd32(const unsigned char *p) { return (uint32_t)rd16(p) | (uint32_t)rd16(p + 2) << 16; }
static void wr16(unsigned char *p, uint16_t v) { p[0] = (unsigned char)v; p[1] = (unsigned char)(v >> 8); }
static void wr32(unsigned char *p, uint32_t v) { wr16(p, (uint16_t)v); wr16(p + 2, (uint16_t)(v >> 16)); }

static const unsigned char kSiteA[] = { 0x31, 0xd2, 0xe8, 0x11, 0x22, 0x33, 0x44, 0x75, 0x05 };
static const unsigned char kSiteB[] = { 0x48, 0x8b, 0x0b, 0x41, 0xb8, 0x01, 0x00, 0x00, 0x00 };
static const unsigned char kSiteC[] = { 0x0f, 0x1f, 0x44, 0x00, 0x00, 0xb0, 0x07, 0xc3 };

static int write_fixture_dll(const char *path, uint32_t raw) {
    static unsigned char f[0x3000];
    size_t len = (size_t)raw + 0x2000;
    if (raw < 0x400 || len > sizeof(f)) return 0;
    memset(f, 0, sizeof(f));
    f[0] = 'M'; f[1] = 'Z';
    wr32(f + 0x3c, 0x80);
    memcpy(f + 0x40, "Wine builtin DLL", 16);
    unsigned char *pe = f + 0x80, *opt = pe + 24, *sec = opt + 0xf0;
    memcpy(pe, "PE\0\0", 4);
    wr16(pe + 4, 0x8664);
    wr16(pe + 6, 2);
    wr16(pe + 20, 0xf0);
    wr16(pe + 22, 0x2022);
    wr16(opt, 0x20b);
    wr32(opt + 32, 0x1000);
    wr32(opt + 36, raw < 0x1000 ? 0x200 : 0x1000);
    wr32(opt + 56, 0x3000);
    wr32(opt + 60, raw);
    wr32(opt + 108, 16);
    wr32(opt + 112, 0x2000);
    wr32(opt + 116, 0x40);
    memcpy(sec, ".text", 5);
    wr32(sec + 8, 0x1000); wr32(sec + 12, 0x1000); wr32(sec + 16, 0x1000); wr32(sec + 20, raw);
    wr32(sec + 36, 0x60000020);
    memcpy(sec + 40, ".rdata", 6);
    wr32(sec + 48, 0x1000); wr32(sec + 52, 0x2000); wr32(sec + 56, 0x1000); wr32(sec + 60, raw + 0x1000);
    wr32(sec + 76, 0x40000040);
    memset(f + raw, 0xcc, 0x1000);
    memcpy(f + raw + 0x100, kSiteA, sizeof(kSiteA));
    memcpy(f + raw + 0x200, kSiteB, sizeof(kSiteB));
    memcpy(f + raw + 0x300, kSiteC, sizeof(kSiteC));
    wr32(f + raw + 0x1000 + 12, 0x2040);
    memcpy(f + raw + 0x1040, "npfixture.dll", 14);
    FILE *out = fopen(path, "wb");
    if (!out) return 0;
    int ok = fwrite(f, 1, len, out) == len;
    return fclose(out) == 0 && ok;
}

struct pe {
    unsigned char *file;
    size_t len;
    uint32_t image_size;
    unsigned nsec;
    const unsigned char *sec;
};

static int pe_parse(const char *path, struct pe *pe) {
    if (!(pe->file = slurp(path, &pe->len)) || pe->len < 0x400) return 0;
    uint32_t off = rd32(pe->file + 0x3c);
    if (off + 0x108 > pe->len || memcmp(pe->file + off, "PE\0\0", 4) != 0) return 0;
    pe->nsec = rd16(pe->file + off + 6);
    pe->image_size = rd32(pe->file + off + 24 + 56);
    pe->sec = pe->file + off + 24 + rd16(pe->file + off + 20);
    return 1;
}

static unsigned char *pe_load(const char *path, const struct pe *pe, int from_file, unsigned char *at) {
    unsigned char *base = at;
    if (!base) {
        size_t span = ((size_t)pe->image_size + 0xffff) & ~(size_t)0xffff;
        unsigned char *raw = mmap(NULL, span + 0x10000, PROT_NONE, MAP_ANON | MAP_PRIVATE, -1, 0);
        if (raw == MAP_FAILED) return NULL;
        base = (unsigned char *)(((uintptr_t)raw + 0xffff) & ~(uintptr_t)0xffff);
    }
    int aligned = 1;
    for (unsigned i = 0; i < pe->nsec; i++)
        aligned &= rd32(pe->sec + i * 40 + 12) == rd32(pe->sec + i * 40 + 20);
    if (mmap(base, pe->image_size, PROT_READ | PROT_WRITE, MAP_FIXED | MAP_ANON | MAP_PRIVATE, -1, 0) == MAP_FAILED)
        return NULL;
    if (from_file) {
        int fd = open(path, O_RDONLY);
        size_t n = aligned ? (pe->len + 0xfff) & ~(size_t)0xfff : 0x1000;
        if (fd < 0 || mmap(base, n, PROT_READ | PROT_WRITE, MAP_FIXED | MAP_PRIVATE, fd, 0) == MAP_FAILED)
            return NULL;
        close(fd);
    } else {
        memcpy(base, pe->file, 0x1000);
    }
    if (!from_file || !aligned) {
        for (unsigned i = 0; i < pe->nsec; i++) {
            const unsigned char *s = pe->sec + i * 40;
            uint32_t vs = rd32(s + 8), va = rd32(s + 12), rs = rd32(s + 16), rp = rd32(s + 20);
            if (rp + rs <= pe->len && va + rs <= pe->image_size) memcpy(base + va, pe->file + rp, rs < vs ? rs : vs);
        }
    }
    for (unsigned i = 0; i < pe->nsec; i++) {
        const unsigned char *s = pe->sec + i * 40;
        uint32_t vs = rd32(s + 8), va = rd32(s + 12);
        uintptr_t page = (uintptr_t)getpagesize(), lo = ((uintptr_t)base + va) & ~(page - 1);
        uintptr_t hi = ((uintptr_t)base + va + vs + page - 1) & ~(page - 1);
        if (rd32(s + 36) & 0x20000000u) mprotect((void *)lo, hi - lo, PROT_READ | PROT_EXEC);
    }
    return base;
}

static void pe_changes(const struct pe *pe, const unsigned char *base, char *out, size_t outsz) {
    static int counts[256][256];
    memset(counts, 0, sizeof(counts));
    for (unsigned i = 0; i < pe->nsec; i++) {
        const unsigned char *s = pe->sec + i * 40;
        uint32_t vs = rd32(s + 8), va = rd32(s + 12), rs = rd32(s + 16), rp = rd32(s + 20);
        uint32_t n = rs < vs ? rs : vs;
        for (uint32_t k = 0; k < n && rp + k < pe->len; k++)
            if (pe->file[rp + k] != base[va + k]) counts[pe->file[rp + k]][base[va + k]]++;
    }
    size_t used = 0;
    out[0] = 0;
    for (int was = 0; was < 256; was++)
        for (int is = 0; is < 256; is++)
            if (counts[was][is] && used < outsz)
                used += (size_t)snprintf(out + used, outsz - used, "%s%02x>%02x*%d", used ? "," : "", was, is,
                                         counts[was][is]);
}

static int child_pe(const char *host, const char *dll, const char *trigger, const char *spec, int from_file,
                    const char *want, int reload) {
    struct pe pe;
    char got[512];
    if (!pe_parse(dll, &pe)) { printf("cannot read %s\n", dll); return 2; }
    unsigned char *base = pe_load(dll, &pe, from_file, NULL);
    if (!base) { printf("cannot load %s\n", dll); return 2; }
    setenv("NOTPROTON_PLUGIN_PATCHES", spec, 1);
    if (!dlopen(host, RTLD_NOW)) { printf("dlopen %s: %s\n", host, dlerror()); return 2; }
    pe_changes(&pe, base, got, sizeof(got));
    if (*got) { printf("patched before the unix half loaded: %s\n", got); return 1; }
    void *t = dlopen(trigger, RTLD_NOW);
    if (!t) { printf("dlopen %s: %s\n", trigger, dlerror()); return 2; }
    pe_changes(&pe, base, got, sizeof(got));
    if (strcmp(got, want) != 0) { printf("changed [%s], wanted [%s]\n", got, want); return 1; }
    if (!reload) return 0;
    if (dlclose(t) != 0) { printf("dlclose %s: %s\n", trigger, dlerror()); return 2; }
    if (pe_load(dll, &pe, from_file, base) != base) { printf("cannot map %s again\n", dll); return 2; }
    pe_changes(&pe, base, got, sizeof(got));
    if (*got) { printf("the fresh mapping is already changed: %s\n", got); return 1; }
    if (!dlopen(trigger, RTLD_NOW)) { printf("dlopen %s again: %s\n", trigger, dlerror()); return 2; }
    pe_changes(&pe, base, got, sizeof(got));
    if (strcmp(got, want) != 0) { printf("after the reload changed [%s], wanted [%s]\n", got, want); return 1; }
    return 0;
}

static int child_pe_api(const char *host, const char *dll, const char *trigger, const char *patches,
                        const char *want) {
    struct pe pe;
    char got[512];
    if (!pe_parse(dll, &pe)) { printf("cannot read %s\n", dll); return 2; }
    unsigned char *base = pe_load(dll, &pe, 1, NULL);
    if (!base) { printf("cannot load %s\n", dll); return 2; }
    if (!dlopen(host, RTLD_NOW)) { printf("dlopen %s: %s\n", host, dlerror()); return 2; }
    const struct np_plugin_api *api = np_plugin_api();
    if (!api) { printf("no plugin API\n"); return 2; }
    int n = api->patch("hostcheck", patches);
    pe_changes(&pe, base, got, sizeof(got));
    if (n != 1 || strcmp(got, want) != 0) { printf("patch gave %d and changed [%s], wanted [%s]\n", n, got, want); return 1; }
    if (!dlopen(trigger, RTLD_NOW)) { printf("dlopen %s: %s\n", trigger, dlerror()); return 2; }
    pe_changes(&pe, base, got, sizeof(got));
    if (strcmp(got, want) != 0) { printf("after the unix half loaded changed [%s], wanted [%s]\n", got, want); return 1; }
    return 0;
}

static int changed(const struct pe *pe, const unsigned char *base, const char *want, const char *when) {
    char got[512];
    pe_changes(pe, base, got, sizeof(got));
    if (strcmp(got, want) == 0) return 1;
    printf("%s changed [%s], wanted [%s]\n", when, got, want);
    return 0;
}

static int child_map(const char *host, const char *ntdll, const char *dll, const char *exe) {
    static unsigned char plain[0x1000];
    struct pe pe, game;
    void *self = (void *)~(uintptr_t)0;
    if (!pe_parse(dll, &pe) || !pe_parse(exe, &game)) { printf("cannot read %s or %s\n", dll, exe); return 2; }
    setenv("NOTPROTON_PLUGIN_PATCHES", "NP_A:npfixture.dll: 31 d2 e8 ?? ?? ?? ?? 75=eb 05;"
                                       "NP_B:npgame.exe: 31 d2 e8 ?? ?? ?? ?? 75=eb 05", 1);
    if (!dlopen(host, RTLD_NOW)) { printf("dlopen %s: %s\n", host, dlerror()); return 2; }
    void *nt = dlopen(ntdll, RTLD_NOW);
    int32_t (*map)(void *, int, int32_t, void *) = nt ? (int32_t (*)(void *, int, int32_t, void *))dlsym(nt, "np_fake_map") : NULL;
    if (!map) { printf("dlopen %s: %s\n", ntdll, dlerror()); return 2; }
    unsigned char *gbase = pe_load(exe, &game, 1, NULL);
    if (!gbase) { printf("cannot load %s\n", exe); return 2; }
    if (!changed(&game, gbase, "", "before any section was mapped the exe")) return 1;
    map(plain, 0, 0, self);
    if (!changed(&game, gbase, "75>eb*1", "after the first section the exe")) return 1;

    unsigned char *base = pe_load(dll, &pe, 1, NULL);
    if (!base) { printf("cannot load %s\n", dll); return 2; }
    map(base, 0, (int32_t)0xc0000018, self);
    if (!changed(&pe, base, "", "a failed mapping")) return 1;
    map(base, 0, 0, (void *)4);
    if (!changed(&pe, base, "", "another process's mapping")) return 1;
    if (map(base, 0, 0x40000003, self) != 0x40000003) { printf("the status was lost\n"); return 1; }
    const uint32_t *alloc_type = dlsym(nt, "np_alloc_type"), *protect = dlsym(nt, "np_protect");
    if (!alloc_type || !protect || *alloc_type != 0x2000 || *protect != 0x40) {
        printf("the arguments arrived as %#x %#x\n", alloc_type ? *alloc_type : 0, protect ? *protect : 0);
        return 1;
    }
    if (!changed(&pe, base, "75>eb*1", "the mapped DLL")) return 1;
    if (pe_load(dll, &pe, 1, base) != base) { printf("cannot map %s again\n", dll); return 2; }
    map(base, 1, 0, self);
    if (!changed(&pe, base, "75>eb*1", "the DLL mapped again")) return 1;
    unsigned char *copy = pe_load(dll, &pe, 0, NULL);
    if (!copy) { printf("cannot copy %s in\n", dll); return 2; }
    map(copy, 1, 0, self);
    return changed(&pe, copy, "75>eb*1", "the copied-in DLL") ? 0 : 1;
}

static int child_late(const char *host, const char *ntdll, const char *exe) {
    struct pe game;
    if (!pe_parse(exe, &game)) { printf("cannot read %s\n", exe); return 2; }
    setenv("NOTPROTON_PLUGIN_PATCHES", "NP_B:npgame.exe: 31 d2 e8 ?? ?? ?? ?? 75=eb 05", 1);
    if (!dlopen(ntdll, RTLD_NOW)) { printf("dlopen %s: %s\n", ntdll, dlerror()); return 2; }
    unsigned char *gbase = pe_load(exe, &game, 1, NULL);
    if (!gbase) { printf("cannot load %s\n", exe); return 2; }
    if (!dlopen(host, RTLD_NOW)) { printf("dlopen %s: %s\n", host, dlerror()); return 2; }
    return changed(&game, gbase, "75>eb*1", "once the host loaded the exe") ? 0 : 1;
}

struct words {
    uintptr_t *at;
    size_t n;
    uintptr_t *before;
};

static int data_words(const char *path, struct words *out, int max) {
    for (uint32_t i = 0; i < _dyld_image_count(); i++) {
        if (strcmp(_dyld_get_image_name(i), path) != 0) continue;
        const struct mach_header_64 *mh = (const struct mach_header_64 *)_dyld_get_image_header(i);
        const unsigned char *lc = (const unsigned char *)(mh + 1);
        int found = 0;
        for (uint32_t c = 0; c < mh->ncmds && found < max; c++, lc += ((const struct load_command *)lc)->cmdsize) {
            const struct segment_command_64 *seg = (const struct segment_command_64 *)lc;
            if (seg->cmd != LC_SEGMENT_64 || strncmp(seg->segname, "__DATA", 6) != 0) continue;
            out[found].at = (uintptr_t *)(uintptr_t)(seg->vmaddr + (uint64_t)_dyld_get_image_vmaddr_slide(i));
            out[found].n = (size_t)seg->vmsize / sizeof(uintptr_t);
            out[found].before = malloc(out[found].n * sizeof(uintptr_t));
            if (!out[found].before) return 0;
            memcpy(out[found].before, out[found].at, out[found].n * sizeof(uintptr_t));
            found++;
        }
        return found;
    }
    return 0;
}

static int child_ntdll(const char *host, const char *path, const char *mode) {
    const char *pe = "NP_A:npfixture.dll: 31 d2 e8 ?? ?? ?? ?? 75=eb 05";
    if (strcmp(mode, "pe") == 0) setenv("NOTPROTON_PLUGIN_PATCHES", pe, 1);
    if (strcmp(mode, "macho") == 0) setenv("NOTPROTON_PLUGIN_PATCHES", "NP_A:D3DMetal: b8 34=35 12 5a 5a c3", 1);
    if (!dlopen(path, RTLD_NOW | RTLD_LOCAL)) { printf("dlopen %s: %s\n", path, dlerror()); return 3; }
    struct words segs[8];
    int nsegs = data_words(path, segs, 8);
    if (!nsegs) { printf("ntdll.so has no data to compare\n"); return 2; }
    void *h = dlopen(host, RTLD_NOW);
    if (!h) { printf("dlopen %s: %s\n", host, dlerror()); return 2; }
    Dl_info self, to;
    if (!dladdr(dlsym(h, "np_plugin_api_get"), &self)) { printf("the patcher has no np_plugin_api_get\n"); return 2; }
    if (strcmp(mode, "api") == 0) {
        const struct np_plugin_api *api = np_plugin_api();
        if (!api || api->patch("hostcheck", pe + 5) != 0) { printf("the API patch was not taken\n"); return 2; }
    }
    int want = strcmp(mode, "pe") == 0 || strcmp(mode, "api") == 0 ? 2 : 0;
    int changed = 0, into = 0;
    for (int s = 0; s < nsegs; s++) {
        for (size_t i = 0; i < segs[s].n; i++) {
            if (segs[s].at[i] == segs[s].before[i]) continue;
            changed++;
            into += dladdr((void *)segs[s].at[i], &to) && to.dli_fbase == self.dli_fbase;
        }
        free(segs[s].before);
    }
    printf("%d pointers changed, %d of them into the patcher\n", changed, into);
    return changed == want && into == want ? 0 : 1;
}

static int child_fixture_dylib(const char *host, const char *dylib) {
    setenv("NOTPROTON_PLUGIN_PATCHES", "NOTPROTON_HOSTCHECK:npfixture.dylib: b8 34=35 12 5a 5a c3", 1);
    if (!dlopen(host, RTLD_NOW)) { printf("dlopen %s: %s\n", host, dlerror()); return 2; }
    void *h = dlopen(dylib, RTLD_NOW);
    if (!h) { printf("dlopen %s: %s\n", dylib, dlerror()); return 2; }
    unsigned (*value)(void) = (unsigned (*)(void))dlsym(h, "np_fixture_value");
    if (!value) { printf("no np_fixture_value\n"); return 2; }
#if defined(__x86_64__)
    if (value() != 0x5a5a1235) { printf("returned %#x\n", value()); return 1; }
#else
    if (value() != 0x5a5a1234) { printf("returned %#x\n", value()); return 1; }
#endif
    return 0;
}

static int child_macho(const char *host, const char *d3dmetal) {
    void *h = dlopen(d3dmetal, RTLD_NOW);
    if (!h) { printf("dlopen %s: %s\n", d3dmetal, dlerror()); return 3; }
    unsigned char *fn = dlsym(h, "DXGIDeclareAdapterRemovalSupport");
    if (!fn) { printf("no DXGIDeclareAdapterRemovalSupport\n"); return 3; }
    unsigned (*call)(void) = (unsigned (*)(void))fn;
    unsigned before = call() & 0xff;
    if (before || fn[0] != 0x31 || fn[1] != 0xc0 || fn[2] != 0xc3) {
        printf("DXGIDeclareAdapterRemovalSupport is not xor eax, eax; ret\n");
        return 3;
    }
    char spec[512];
    int n = snprintf(spec, sizeof(spec), "NOTPROTON_HOSTCHECK:D3DMetal:");
    for (int i = -12; i < 15; i++) {
        if (i == 0) n += snprintf(spec + n, sizeof(spec) - (size_t)n, " 31=b0");
        else if (i == 1) n += snprintf(spec + n, sizeof(spec) - (size_t)n, " c0=01");
        else n += snprintf(spec + n, sizeof(spec) - (size_t)n, " %02x", fn[i]);
    }
    setenv("NOTPROTON_PLUGIN_PATCHES", spec, 1);
    if (!dlopen(host, RTLD_NOW)) { printf("dlopen %s: %s\n", host, dlerror()); return 2; }
    unsigned after = call() & 0xff;
    if (after != 1) { printf("returned %u before and %u after\n", before, after); return 1; }
    return 0;
}

static void fixture_cases(const char *self, const char *host, const char *dir, const char *scratch, const char *log) {
    char dll[1024], trigger[1024], dylib[1024], out[16384];
    snprintf(dll, sizeof(dll), "%s/npfixture.dll", scratch);
    snprintf(trigger, sizeof(trigger), "%s/npfixture.so", dir);
    snprintf(dylib, sizeof(dylib), "%s/npfixture.dylib", dir);
    if (!write_fixture_dll(dll, 0x1000)) {
        printf("  FAIL  fixture DLL could not be written to %s\n", dll);
        failures++;
        return;
    }
    const char *a = "NP_A:npfixture.dll: 31 d2 e8 ?? ?? ?? ?? 75=eb 05";
    const char *b = "NP_A:npfixture.dll: 48 8b 0b 41 b8 01=00 00 00 00";
    const char *c = "NP_B:npfixture.dll: 0f 1f 44 00 00 b0 07=08 c3";
    char spec[1024];
    struct {
        const char *name, *spec, *want, *needle;
        int times, reload;
    } cases[] = {
        { "fixture: a plugin's patches land together", NULL, "01>00*1,75>eb*1", "NP_A: patched npfixture.dll", 1, 0 },
        { "fixture: the log says where it wrote", NULL, "01>00*1,75>eb*1", "(+0x1107 +0x1205)", 1, 0 },
        { "fixture: two plugins patch the same module", "+c", "01>00*1,07>08*1,75>eb*1", "patched npfixture.dll", 2, 0 },
        { "fixture: a module mapped again after its unix half unloads is patched again", NULL, "01>00*1,75>eb*1",
          "NP_A: patched npfixture.dll", 2, 1 },
        { "fixture: a patch found more than once leaves the plugin's others unapplied",
          ";NP_A:npfixture.dll: cc cc cc cc cc=90", "", "is found", 0, 0 },
        { "fixture: a malformed patch leaves the plugin's others unapplied",
          ";NP_A:npfixture.dll: 31 d2 zz 75=eb", "", "a byte is not XX", 0, 0 },
        { "fixture: a patch that writes nothing is refused with the plugin",
          ";NP_A:npfixture.dll: 31 d2 e8 ?? 11", "", "changes no byte", 0, 0 },
        { "fixture: another plugin's broken patch doesn't stop this one",
          ";NP_B:npfixture.dll: 31 d2 zz", "01>00*1,75>eb*1", "NP_A: patched", 1, 0 },
        { "fixture: a module that isn't mapped patches nothing",
          ";NP_B:winemac.drv: 31 d2 e8 ?? ?? ?? ?? 75=eb", "01>00*1,75>eb*1", "NP_A: patched", 1, 0 },
        { "fixture: a patch with no bytes is refused", "=NP_A:npfixture.dll:", "", "no bytes", 0, 0 },
    };
    for (size_t k = 0; k < sizeof(cases) / sizeof(*cases); k++) {
        const char *extra = cases[k].spec;
        if (extra && *extra == '=') snprintf(spec, sizeof(spec), "%s", extra + 1);
        else if (extra && *extra == '+') snprintf(spec, sizeof(spec), "%s;%s;%s", a, b, c);
        else snprintf(spec, sizeof(spec), "%s;%s%s", a, b, extra ? extra : "");
        for (int from_file = 1; from_file >= 0; from_file--) {
            char what[256];
            snprintf(what, sizeof(what), "%s (%s)", cases[k].name, from_file ? "mapped" : "copied-in");
            char *argv[] = { (char *)self, "--pe", (char *)host, dll, trigger, spec, from_file ? "1" : "0",
                             (char *)cases[k].want, cases[k].reload ? "1" : "0", NULL };
            int rc = run(argv, log, out, sizeof(out));
            expect(what, rc, out, 0, cases[k].needle, cases[k].times);
        }
    }
    char *api[] = { (char *)self, "--pe-api", (char *)host, dll, trigger,
                    "npfixture.dll: 31 d2 e8 ?? ?? ?? ?? 75=eb 05; npfixture.dll: 48 8b 0b 41 b8 01=00 00 00 00",
                    "01>00*1,75>eb*1", NULL };
    int rc = run(api, log, out, sizeof(out));
    expect("fixture: patches a plugin gives in code land the same way", rc, out, 0,
           "hostcheck#1: patched npfixture.dll", 1);
    char exe[1024], ntdll[1024];
    snprintf(exe, sizeof(exe), "%s/npgame.exe", scratch);
    snprintf(ntdll, sizeof(ntdll), "%s/np-unix/ntdll.so", dir);
    char *map[] = { (char *)self, "--map", (char *)host, ntdll, dll, exe, NULL };
    rc = write_fixture_dll(exe, 0x1000) ? run(map, log, out, sizeof(out)) : 2;
    expect("fixture: an exe is patched by the time the first section is mapped", rc, out, 0,
           "NP_B: patched npgame.exe", 1);
    expect("fixture: a module without a unix half is patched each time it is mapped", rc, out, 0,
           "NP_A: patched npfixture.dll", 3);
    char *late[] = { (char *)self, "--late", (char *)host, ntdll, exe, NULL };
    rc = run(late, log, out, sizeof(out));
    expect("fixture: a host loaded late patches the exe at once", rc, out, 0, "NP_B: patched npgame.exe", 1);
    char *argv[] = { (char *)self, "--dylib", (char *)host, dylib, NULL };
    rc = run(argv, log, out, sizeof(out));
#if defined(__x86_64__)
    expect("fixture: a dylib's code changes in memory and the change runs", rc, out, 0,
           "NOTPROTON_HOSTCHECK: patched npfixture.dylib", 1);
#else
    expect("fixture: arm64 code is left alone", rc, out, 0, "arm64 code can't be changed", 1);
#endif
}

int main(int argc, char **argv) {
    if (argc == 9 && strcmp(argv[1], "--pe") == 0)
        return child_pe(argv[2], argv[3], argv[4], argv[5], atoi(argv[6]), argv[7], atoi(argv[8]));
    if (argc == 7 && strcmp(argv[1], "--pe-api") == 0) return child_pe_api(argv[2], argv[3], argv[4], argv[5], argv[6]);
    if (argc == 4 && strcmp(argv[1], "--dylib") == 0) return child_fixture_dylib(argv[2], argv[3]);
    if (argc == 5 && strcmp(argv[1], "--late") == 0) return child_late(argv[2], argv[3], argv[4]);
    if (argc == 6 && strcmp(argv[1], "--map") == 0) return child_map(argv[2], argv[3], argv[4], argv[5]);
    if (argc == 5 && strcmp(argv[1], "--ntdll") == 0) return child_ntdll(argv[2], argv[3], argv[4]);
    if (argc == 4 && strcmp(argv[1], "--macho") == 0) return child_macho(argv[2], argv[3]);
    if (argc == 4 && strcmp(argv[1], "--fixture") == 0)
        return write_fixture_dll(argv[2], (uint32_t)strtoul(argv[3], NULL, 0)) ? 0 : 2;
    if (argc != 4) {
        fprintf(stderr, "usage: hostcheck <plugin-host.dylib> <fixture dir> <scratch dir>\n");
        return 2;
    }
    const char *host = argv[1], *dir = argv[2], *scratch = argv[3];
    char log[1024], self[1024];
    if (!realpath(argv[0], self)) return 2;
    snprintf(log, sizeof(log), "%s/child.log", scratch);

    fixture_cases(self, host, dir, scratch, log);

    char out[16384];
#if defined(__x86_64__)
    glob_t metals;
    runner_files(D3DMETALS, &metals);
    if (!metals.gl_pathc) printf("  SKIP  runner checks: no runners installed\n");
    for (size_t i = 0; i < metals.gl_pathc; i++) {
        char what[256], *a[] = { self, "--macho", (char *)host, metals.gl_pathv[i], NULL };
        snprintf(what, sizeof(what), "%s: D3DMetal's code changes in memory and the change runs",
                 runner_of(metals.gl_pathv[i]));
        int rc = run(a, log, out, sizeof(out));
        if (rc == 3) printf("  SKIP  %s: %s", what, out);
        else expect(what, rc, out, 0, "NOTPROTON_HOSTCHECK: patched D3DMetal", 1);
    }
    globfree(&metals);
#endif
    glob_t libs;
#if defined(__x86_64__)
    runner_files("lib/wine/x86_64-unix/ntdll.so", &libs);
#else
    runner_files("lib/wine/aarch64-unix/ntdll.so", &libs);
#endif
    static const char *const modes[][2] = {
        { "pe", "section mapping is watched" }, { "api", "API patch watches section mapping" },
        { "none", "no patches, ntdll untouched" }, { "macho", "dylib patches only, ntdll untouched" },
    };
    for (size_t i = 0; i < libs.gl_pathc; i++) {
        for (size_t m = 0; m < sizeof(modes) / sizeof(*modes); m++) {
            char what[256], *a[] = { self, "--ntdll", (char *)host, libs.gl_pathv[i], (char *)modes[m][0], NULL };
            snprintf(what, sizeof(what), "%s: %s", runner_of(libs.gl_pathv[i]), modes[m][1]);
            int rc = run(a, log, out, sizeof(out));
            if (rc == 3) printf("  SKIP  %s: %s", what, out);
            else expect(what, rc, out, 0, NULL, 0);
        }
    }
    globfree(&libs);

    return finish("plugin host", "patches land once, in memory, or not at all");
}
