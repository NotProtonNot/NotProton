// Clever detours

typedef unsigned long long u64;
typedef unsigned int u32;
typedef unsigned short u16;
typedef unsigned char u8;

typedef u32 (*ldr_getdllhandle_t)(void *path, void *unused, void *name_us, void **out);
typedef u32 (*ldr_loaddll_t)(void *path, void *flags, void *name_us, void **out);
typedef u32 (*nt_protect_t)(void *proc, void **base, u64 *size, u32 newprot, u32 *oldprot);
typedef u32 (*nt_query_t)(void *proc, void *addr, u32 cls, void *buf, u64 len, u64 *ret);

struct ctx
{
    ldr_getdllhandle_t get_dll_handle;
    ldr_loaddll_t      load_dll;
    nt_protect_t       protect;
#ifdef NP_PLUGINS
    nt_query_t         query;
#endif
};

#define MEMORY_WINE_LOAD_UNIX_LIB_BY_NAME 1002

// PE image structures, minimal subset needed to walk export tables
struct dos_header  { u16 e_magic; u8 pad[58]; u32 e_lfanew; };
struct data_dir    { u32 rva; u32 size; };
struct opt_hdr64   { u16 magic;                 //   0
                     u8  pad0[14];              //   2
                     u32 entry_point;           // 16
                     u8  pad1[36];              //  20
                     u32 size_of_image;         //  56
                     u8  pad2[52];              //  60
                     struct data_dir dir[16]; };// 112
struct nt_headers  { u32 sig; u8 file_hdr[20]; struct opt_hdr64 opt; };
struct export_dir  { u32 flags; u32 stamp; u16 maj; u16 min; u32 name;
                     u32 base; u32 nfuncs; u32 nnames;
                     u32 addr_funcs; u32 addr_names; u32 addr_ords; };

#define LDR_DONT_RESOLVE_REFS  0x00000002

// WINE_MODREF, x86_64 layout.
#define WM_DLLBASE(wm)   (*(void **)((u8 *)(wm) + 0x30))
#define WM_FLAGS(wm)     ( (u32 *)((u8 *)(wm) + 0x68))

struct us { u16 len; u16 max; u32 pad; void *buf; };

static const u16 name_lsteam[] = {'l','s','t','e','a','m','c','l','i','e','n','t','.','d','l','l',0};

static void *resolve_lsteam(struct ctx *c, void *load_path)
{
    struct us u;
    void *h = 0;
    u.len = 32;                 /* "lsteamclient.dll" = 16 wchars */
    u.max = 34;
    u.pad = 0;
    u.buf = (void *)name_lsteam;
    if (c->get_dll_handle(load_path, 0, &u, &h) == 0 && h)
        return h;
    if (c->load_dll(load_path, 0, &u, &h) == 0 && h)
        return h;
    return 0;
}

static struct export_dir *export_of(u8 *mod)
{
    struct dos_header *dos = (struct dos_header *)mod;
    struct nt_headers *nt = (struct nt_headers *)(mod + dos->e_lfanew);
    u32 rva = nt->opt.dir[0].rva;
    if (!rva)
        return 0;
    return (struct export_dir *)(mod + rva);
}

static int name_eq(const char *a, const char *b)
{
    while (*a && *a == *b) { a++; b++; }
    return *a == *b;
}

static void *find_named_export(u8 *mod, const char *want)
{
    struct export_dir *e = export_of(mod);
    u32 *names, *funcs, i;
    u16 *ords;

    if (!e)
        return 0;
    names = (u32 *)(mod + e->addr_names);
    funcs = (u32 *)(mod + e->addr_funcs);
    ords  = (u16 *)(mod + e->addr_ords);
    for (i = 0; i < e->nnames; i++)
        if (name_eq((const char *)(mod + names[i]), want))
            return mod + funcs[ords[i]];
    return 0;
}

// movabs rax, tgt ; jmp rax
static void write_jump(u8 *src, void *tgt)
{
    src[0] = 0x48; src[1] = 0xB8;
    *(u64 *)(src + 2) = (u64)tgt;
    src[10] = 0xFF; src[11] = 0xE0;
}

// mov eax, 1 ; ret
static void write_true_stub(u8 *src)
{
    src[0] = 0xB8; src[1] = 0x01; src[2] = 0x00; src[3] = 0x00; src[4] = 0x00;
    src[5] = 0xC3;
}

// Rewrite every named export of sc64 that lsteamclient also exports so it jumps to the
// lsteamclient one, plus the entry point.
static void setup_trampolines(struct ctx *c, u8 *sc64, u8 *lsteam)
{
    struct nt_headers *snt = (struct nt_headers *)(sc64 + ((struct dos_header *)sc64)->e_lfanew);
    struct export_dir *se;
    u32 *snames, *sfuncs, i;
    u16 *sords;
    void *base = sc64;
    u64 size = snt->opt.size_of_image;
    u32 oldp;

    // make the whole sc64 image writable and executable so export stubs can be overwritten
    if (c->protect((void *)~0ull, &base, &size, 0x40 /*RWX*/, &oldp) != 0)
        return;

    se = export_of(sc64);
    if (!se)
        return;

    snames = (u32 *)(sc64 + se->addr_names);
    sfuncs = (u32 *)(sc64 + se->addr_funcs);
    sords  = (u16 *)(sc64 + se->addr_ords);
    for (i = 0; i < se->nnames; i++)
    {
        void *tgt = find_named_export(lsteam, (const char *)(sc64 + snames[i]));
        if (tgt)
            write_jump(sc64 + sfuncs[sords[i]], tgt);
    }

    // Report success instead of forwarding. lsteamclient's DllMain has to run while
    // Windows is loading lsteamclient, not while it is loading this stub.
    if (snt->opt.entry_point)
        write_true_stub(sc64 + snt->opt.entry_point);
}

// True when the MODREF basename (wm+0x60, a NUL-terminated wide string) is
// steamclient64.dll
static int wm_is_sc64(void *wm)
{
    static const char want[] = "steamclient64.dll";
    const u16 *nm = *(const u16 **)((u8 *)wm + 0x60);
    unsigned i;
    if (!nm)
        return 0;
    for (i = 0; want[i]; i++)
    {
        u16 ch = nm[i];
        if (ch >= 'A' && ch <= 'Z')
            ch = (u16)(ch + 32);
        if (ch != (u16)want[i])
            return 0;
    }
    return nm[i] == 0;
}

#ifdef NP_PLUGINS
static int wm_is_kernel32(void *wm)
{
    static const char want[] = "kernel32.dll";
    const u16 *nm = *(const u16 **)((u8 *)wm + 0x60);
    unsigned i;
    if (!nm)
        return 0;
    for (i = 0; want[i]; i++)
    {
        u16 ch = nm[i];
        if (ch >= 'A' && ch <= 'Z')
            ch = (u16)(ch + 32);
        if (ch != (u16)want[i])
            return 0;
    }
    return nm[i] == 0;
}

static int env_has(const u16 *env, const char *want)
{
    while (env && *env)
    {
        unsigned i = 0;
        while (want[i] && env[i] == (u16)want[i])
            i++;
        if (!want[i])
            return 1;
        while (*env)
            env++;
        env++;
    }
    return 0;
}

static const u16 npload_path[] = u"\\??\\C:\\Program Files (x86)\\Steam\\npload.so";

static void load_plugins(struct ctx *c)
{
    u8 *teb, *peb, *params;
    struct us u;
    u64 res[2];

    __asm__ volatile ("mov %0, x18" : "=r"(teb));
    peb = *(u8 **)(teb + 0x60);
    params = peb ? *(u8 **)(peb + 0x20) : 0;
    if (!params || !env_has(*(const u16 **)(params + 0x80), "NOTPROTON_PLUGIN_LIBS="))
        return;
    u.len = sizeof(npload_path) - 2;
    u.max = sizeof(npload_path);
    u.pad = 0;
    u.buf = (void *)npload_path;
    c->query((void *)~0ull, &u, MEMORY_WINE_LOAD_UNIX_LIB_BY_NAME, res, sizeof(res), 0);
}
#endif

// build_module detour
#ifdef NP_PLUGINS
void detour_build_module(struct ctx *c, void *wm, void *load_path, int site)
#else
void detour_build_module(struct ctx *c, void *wm, void *load_path)
#endif
{
    u8 *sc64, *lsteam;

#ifdef NP_PLUGINS
    if (wm && site == GUEST_SITE && wm_is_kernel32(wm))
    {
        load_plugins(c);
        return;
    }
#endif
    if (!wm || !wm_is_sc64(wm))
        return;

    sc64 = (u8 *)WM_DLLBASE(wm);
    if (!sc64)
        return;

    lsteam = (u8 *)resolve_lsteam(c, load_path);
    if (!lsteam)
        return;                                     // let sc64 load normally

    setup_trampolines(c, sc64, lsteam);

    *WM_FLAGS(wm) |= LDR_DONT_RESOLVE_REFS;
}
