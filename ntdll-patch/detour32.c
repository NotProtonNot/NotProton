// Clever detours, but 32 bit

typedef unsigned long long u64;
typedef unsigned int u32;
typedef unsigned short u16;
typedef unsigned char u8;

#define STDCALL __attribute__((stdcall))

typedef u32 (STDCALL *ldr_getdllhandle_t)(void *path, void *unused, void *name_us, void **out);
typedef u32 (STDCALL *ldr_loaddll_t)(void *path, void *flags, void *name_us, void **out);
typedef u32 (STDCALL *nt_protect_t)(void *proc, void **base, u32 *size, u32 newprot, u32 *oldprot);
typedef u32 (STDCALL *nt_openfile_t)(void **handle, u32 access, void *attr, void *io,
                                     u32 share, u32 options);
typedef u32 (STDCALL *nt_readfile_t)(void *handle, void *event, void *apc, void *apc_ctx, void *io,
                                     void *buf, u32 len, u64 *offset, void *key);
typedef u32 (STDCALL *nt_close_t)(void *handle);

struct ctx
{
    ldr_getdllhandle_t get_dll_handle;
    ldr_loaddll_t      load_dll;
    nt_protect_t       protect;
    nt_openfile_t      open_file;
    nt_readfile_t      read_file;
    nt_close_t         close;
    u32                delta;   // load base - preferred base; see shim32.S
};

#define CAVE_PTR(c, p) ((void *)((u8 *)(p) + (c)->delta))

struct dos_header  { u16 e_magic; u8 pad[58]; u32 e_lfanew; };
struct data_dir    { u32 rva; u32 size; };
struct opt_hdr32   { u16 magic;                 //  0
                     u8  pad0[14];              //  2
                     u32 entry_point;           // 16
                     u8  pad1[8];               // 20
                     u32 image_base;            // 28
                     u8  pad2[24];              // 32
                     u32 size_of_image;         // 56
                     u8  pad3[36];              // 60
                     struct data_dir dir[16]; };// 96
struct nt_headers  { u32 sig; u8 file_hdr[20]; struct opt_hdr32 opt; };
struct export_dir  { u32 flags; u32 stamp; u16 maj; u16 min; u32 name;
                     u32 base; u32 nfuncs; u32 nnames;
                     u32 addr_funcs; u32 addr_names; u32 addr_ords; };

struct us      { u16 len; u16 max; void *buf; };
struct obj_attr{ u32 len; void *root; void *name; u32 attrs; void *sd; void *sqos; };
struct io_status { u32 status; u32 information; };

#define ARG_FLAGS(fp)     ( (u32 *)((u8 *)(fp) + FLAGS_SLOT))
#define ARG_LOAD_PATH(fp) (*(void **)((u8 *)(fp) + LOAD_PATH_SLOT))

// WINE_MODREF 32
#define WM_DLLBASE(wm)   (*(u8 **)((u8 *)(wm) + 0x18))
#define WM_FULLNAME(wm)  ( (const struct us *)((u8 *)(wm) + 0x24))
#define WM_BASENAME(wm)  (*(const u16 **)((u8 *)(wm) + 0x30))
#define WM_FLAGS(wm)     ( (u32 *)((u8 *)(wm) + 0x34))

#define LDR_DONT_RESOLVE_REFS  0x00000002
#define LDR_DONT_CALL_DLLMAIN  0x20000000

static const u16 name_lsteam[] = {'l','s','t','e','a','m','c','l','i','e','n','t','.','d','l','l',0};

static void *resolve_lsteam(struct ctx *c, void *load_path)
{
    struct us u;
    void *h = 0;
    u.len = 32;                 // "lsteamclient.dll" = 16 wchars
    u.max = 34;
    u.buf = CAVE_PTR(c, name_lsteam);
    if (c->get_dll_handle(load_path, 0, &u, &h) == 0 && h)
        return h;
    if (c->load_dll(load_path, 0, &u, &h) == 0 && h)
        return h;
    return 0;
}

static struct nt_headers *nt_of(u8 *mod)
{
    return (struct nt_headers *)(mod + ((struct dos_header *)mod)->e_lfanew);
}

static struct export_dir *export_of(u8 *mod)
{
    u32 rva = nt_of(mod)->opt.dir[0].rva;
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

// mov eax, tgt ; jmp eax
static void write_jump(u8 *src, void *tgt)
{
    src[0] = 0xB8;
    *(u32 *)(src + 1) = (u32)tgt;
    src[5] = 0xFF; src[6] = 0xE0;
}

static void setup_trampolines(struct ctx *c, u8 *sc, u8 *lsteam)
{
    struct nt_headers *snt = nt_of(sc);
    struct nt_headers *lnt = nt_of(lsteam);
    struct export_dir *se;
    u32 *snames, *sfuncs, i;
    u16 *sords;
    void *base = sc;
    u32 size = snt->opt.size_of_image;
    u32 oldp;

    if (c->protect((void *)~0u, &base, &size, 0x40 /*RWX*/, &oldp) != 0)
        return;

    se = export_of(sc);
    if (!se)
        return;

    snames = (u32 *)(sc + se->addr_names);
    sfuncs = (u32 *)(sc + se->addr_funcs);
    sords  = (u16 *)(sc + se->addr_ords);
    for (i = 0; i < se->nnames; i++)
    {
        void *tgt = find_named_export(lsteam, (const char *)(sc + snames[i]));
        if (tgt)
            write_jump(sc + sfuncs[sords[i]], tgt);
    }

    if (snt->opt.entry_point && lnt->opt.entry_point)
        write_jump(sc + snt->opt.entry_point, lsteam + lnt->opt.entry_point);
}

static int nt_name_of(void *wm, u16 *buf, unsigned cap, struct us *out)
{
    const struct us *full = WM_FULLNAME(wm);
    const u16 *src = (const u16 *)full->buf;
    unsigned i, n = full->len / 2;

    if (!src || n < 2 || n + 4 > cap || src[0] == '\\')
        return 0;

    buf[0] = '\\'; buf[1] = '?'; buf[2] = '?'; buf[3] = '\\';
    for (i = 0; i < n; i++)
        buf[4 + i] = src[i];

    out->len = (u16)((n + 4) * 2);
    out->max = out->len;
    out->buf = buf;
    return 1;
}

static void restore_image_base(struct ctx *c, void *wm, u8 *mod)
{
    struct nt_headers *nt = nt_of(mod);
    struct obj_attr attr;
    struct io_status io;
    struct us name;
    u16 path[320];
    void *addr = mod;
    void *file = 0;
    u32 size = 0x1000;
    u32 oldp;
    u64 offset;

    if (!nt_name_of(wm, path, 320, &name))
        return;

    if (c->protect((void *)~0u, &addr, &size, 4 /*PAGE_READWRITE*/, &oldp) != 0)
        return;

    attr.len   = sizeof(attr);
    attr.root  = 0;
    attr.name  = &name;
    attr.attrs = 0x40;
    attr.sd    = 0;
    attr.sqos  = 0;

    if (c->open_file(&file, 0x80000000u | 0x00100000u, &attr, &io, 1 | 4, 0x20 | 0x40) == 0)
    {
        offset = (u64)(u32)((u8 *)&nt->opt.image_base - (u8 *)mod);
        c->read_file(file, 0, 0, 0, &io, &nt->opt.image_base,
                     sizeof(nt->opt.image_base), &offset, 0);
        c->close(file);
    }

    addr = mod;
    size = 0x1000;
    c->protect((void *)~0u, &addr, &size, oldp, &oldp);
}

static int basename_is(void *wm, const char *want)
{
    const u16 *nm = WM_BASENAME(wm);
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

void detour_build_module32(struct ctx *c, void *wm, void *fp)
{
    u8 *sc, *lsteam;
    int is_steamclient32;

    if (!wm)
        return;

    is_steamclient32 = basename_is(wm, CAVE_PTR(c, "steamclient.dll"));
    if (!is_steamclient32 && !basename_is(wm, CAVE_PTR(c, "gameoverlayrenderer.dll")))
        return;

    sc = WM_DLLBASE(wm);
    if (!sc)
        return;

    lsteam = (u8 *)resolve_lsteam(c, ARG_LOAD_PATH(fp));
    if (!lsteam)
        return;

    setup_trampolines(c, sc, lsteam);

    if (is_steamclient32)
    {
        *WM_FLAGS(wm)  |= LDR_DONT_RESOLVE_REFS;
        *ARG_FLAGS(fp) |= FLAGS_BIT;
        restore_image_base(c, wm, sc);
    }
    else
    {
        *WM_FLAGS(wm) |= LDR_DONT_CALL_DLLMAIN;
    }
}
