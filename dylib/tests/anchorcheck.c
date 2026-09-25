// Anchor validation. Resolves every sig in every database against the loaded
// steamclient.dylib by the same path the dylib uses, then checks each against the address
// and bytes recorded when the database was cut. Loaded rather than on disk because dyld
// rebases and ObjC rewrites selector slots. Other builds must land on the live addresses.
// Usage: out/anchorcheck [path-to-sigdb.json ...]

#include "../resolver/sigdb.h"
#include "../resolver/resolver.h"
#include "../resolver/anchor.h"
#include "../resolver/aob.h"
#include "../core/macho.h"

#include <dirent.h>
#include <dlfcn.h>
#include <mach-o/dyld.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define STEAM_MACOS \
    "/Library/Application Support/Steam/Steam.AppBundle/Steam/Contents/MacOS/"
#define MAX_IMAGES 4
#define SIGDB_DIR "signatures/macos.arm64"
#define MAX_DBS   16

// Locate the loaded image whose name ends with `suffix`.
static const struct mach_header_64 *find_image(const char *suffix,
                                               intptr_t *slide_out,
                                               const char **path_out) {
    size_t want = strlen(suffix);
    uint32_t n = _dyld_image_count();
    for (uint32_t i = 0; i < n; i++) {
        const char *name = _dyld_get_image_name(i);
        if (!name) continue;
        size_t len = strlen(name);
        if (len < want) continue;
        if (strcmp(name + len - want, suffix) != 0) continue;
        *slide_out = _dyld_get_image_vmaddr_slide(i);
        *path_out  = name;
        return (const struct mach_header_64 *)_dyld_get_image_header(i);
    }
    return NULL;
}

typedef struct {
    char                          module[64];
    const struct mach_header_64  *mh;
    intptr_t                      slide;
    uintptr_t                     text;
    size_t                        text_sz;
    const char                   *path;
} image_t;

static image_t g_images[MAX_IMAGES];
static int     g_image_count;

static const image_t *image_for(const char *module) {
    for (int i = 0; i < g_image_count; i++)
        if (strcmp(g_images[i].module, module) == 0) return &g_images[i];
    return NULL;
}

static int load_image(const char *module) {
    if (image_for(module)) return 0;
    if (g_image_count >= MAX_IMAGES) return -1;

    const char *home = getenv("HOME");
    char path[1024], suffix[128];
    snprintf(path, sizeof(path), "%s%s%s", home ? home : "", STEAM_MACOS, module);
    snprintf(suffix, sizeof(suffix), "/%s", module);

    if (!dlopen(path, RTLD_LAZY | RTLD_LOCAL)) {
        fprintf(stderr, "dlopen failed: %s\n", dlerror());
        return -1;
    }

    image_t *im = &g_images[g_image_count];
    im->mh = find_image(suffix, &im->slide, &im->path);
    if (!im->mh) {
        fprintf(stderr, "%s not found after dlopen\n", module);
        return -1;
    }
    if (np_find_segment(im->mh, im->slide, "__TEXT", &im->text, &im->text_sz) != 0) {
        fprintf(stderr, "%s has no __TEXT\n", module);
        return -1;
    }
    snprintf(im->module, sizeof(im->module), "%s", module);
    g_image_count++;

    printf("image  : %s\n", im->path);
    printf("slide  : 0x%lx\n", (unsigned long)im->slide);
    printf("__TEXT : 0x%lx (%zu bytes)\n\n", im->text, im->text_sz);
    return 0;
}

// An independent read on the anchor result, meaningful only against the build the
// pattern was recorded from.
static uintptr_t resolve_by_aob(np_sig_entry_t *sig,
                                uintptr_t text, size_t text_sz) {
    if (!sig->aob_hex[0]) return 0;

    np_byte_pattern_t pat;
    if (np_compile_pattern(sig->aob_hex, &pat) != 0) return 0;
    uintptr_t addr = np_scan_sole_match(text, text_sz, &pat);
    np_release_pattern(&pat);
    if (!addr) return 0;

    if (sig->match_offset) {
        uintptr_t adj = addr - (uintptr_t)sig->match_offset;
        if (adj < text || adj >= text + text_sz) return 0;
        addr = adj;
    }
    return addr;
}

static const char *kind_name(np_match_kind_t k) {
    switch (k) {
        case NP_MATCH_STRING:            return "string";
        case NP_MATCH_VTABLE_SLOT:       return "vtable_slot";
        case NP_MATCH_INSN_AFTER_STRING: return "insn_after_string";
        case NP_MATCH_INSN_PAIR_IN_FN:   return "insn_pair";
        case NP_MATCH_AOB:               return "aob";
        case NP_MATCH_CALL_TARGET:       return "call_target";
        default:                          return "none";
    }
}

// Addresses are reported unslid throughout, so they can be pasted into a
// disassembler.
typedef struct {
    const char     *name;
    np_match_kind_t kind;
    uintptr_t       anchor;
    uintptr_t       recorded;
    uintptr_t       aob;
    int             has_pattern;
} row_t;

typedef struct {
    char      path[512];
    uint64_t  build;
    np_sigdb_t sigdb;
    row_t    *rows;
    int       count;
    int       unresolved;
    int       recorded_match;
    int       recorded_total;
    int       loaded;
} dbcheck_t;

// Class vptrs per client build, read off the disassembly. These address data rather than
// code, so they are not signatures and get checked separately. The CompatManager message
// classes arrived with 1789086785, so the older build has only the one row.
static const struct { uint64_t build; const char *type_name; uintptr_t vptr; } expected_vptr[] = {
    {1788400362, "14CCompatManager",                              0x1715a00},

    {1789086785, "14CCompatManager",                              0x1743ed0},
    {1789086785, "21CMsgCompatManagerTool",                       0x16ad000},
    {1789086785, "22CMsgCompatManagerAlias",                      0x16ad0b0},
    {1789086785, "37CCompatManager_GetCompatTools_Request",        0x16ad160},
    {1789086785, "38CCompatManager_GetCompatTools_Response",       0x16ad210},
    {1789086785, "40CCompatManager_SpecifyCompatTool_Request",     0x16ad2c0},
    {1789086785, "41CCompatManager_SpecifyCompatTool_Response",    0x16ad370},
    {1789086785, "40CCompatManager_StateChanged_Notification",     0x16ad420},
};

static int run_rtti(const struct mach_header_64 *mh, intptr_t slide,
                    uintptr_t text, size_t text_sz, uint64_t build) {
    int ok = 0, bad = 0, checked = 0;

    for (size_t i = 0; i < sizeof(expected_vptr) / sizeof(expected_vptr[0]); i++) {
        if (expected_vptr[i].build != build) continue;
        checked++;

        const char *name = expected_vptr[i].type_name;
        uintptr_t got = np_rtti_vptr(mh, slide, text, text_sz, name);
        unsigned long got_u = got ? (unsigned long)(got - (uintptr_t)slide) : 0;
        unsigned long want  = (unsigned long)expected_vptr[i].vptr;

        const char *verdict = !got ? "UNRESOLVED" : (got_u == want ? "OK" : "WRONG");
        if (got && got_u == want) ok++; else bad++;

        printf("%-48s vptr=0x%-9lx want=0x%-9lx %s\n", name, got_u, want, verdict);
    }

    if (!checked) {
        printf("no vptr expectations recorded for build %llu\n", (unsigned long long)build);
        return 0;
    }
    printf("\n%d vptr correct, %d incorrect (of %d)\n", ok, bad, checked);
    return bad ? 1 : 0;
}

static int ends_with_json(const char *name) {
    size_t n = strlen(name);
    return n > 5 && strcmp(name + n - 5, ".json") == 0;
}

// Every database in the signature directory, sorted by name so the output runs
// oldest build first.
static int collect_dbs(char paths[][512], int max) {
    DIR *dh = opendir(SIGDB_DIR);
    if (!dh) return 0;

    int n = 0;
    struct dirent *e;
    while ((e = readdir(dh)) != NULL && n < max) {
        if (e->d_name[0] == '.' || !ends_with_json(e->d_name)) continue;
        snprintf(paths[n], 512, "%s/%s", SIGDB_DIR, e->d_name);
        n++;
    }
    closedir(dh);

    for (int i = 1; i < n; i++) {
        char tmp[512];
        snprintf(tmp, sizeof(tmp), "%s", paths[i]);
        int j = i - 1;
        while (j >= 0 && strcmp(paths[j], tmp) > 0) {
            snprintf(paths[j + 1], 512, "%s", paths[j]);
            j--;
        }
        snprintf(paths[j + 1], 512, "%s", tmp);
    }
    return n;
}

// One database against the live image: what its anchors found, and what its
// recorded evidence claims.
static int check_db(dbcheck_t *db) {
    if (!db->loaded && np_load_profile(db->path, &db->sigdb) != 0) {
        fprintf(stderr, "cannot load sigdb '%s'\n", db->path);
        return -1;
    }
    db->build = db->sigdb.steam_build;
    db->count = db->sigdb.sig_count;
    db->rows  = calloc((size_t)db->count, sizeof(row_t));
    if (!db->rows) { fprintf(stderr, "out of memory\n"); return -1; }

    for (int i = 0; i < db->count; i++) {
        np_sig_entry_t *sig = &db->sigdb.signatures[i];
        row_t *r = &db->rows[i];

        r->name        = sig->name;
        r->kind        = sig->anchor.kind;
        r->recorded    = sig->func_addr_this_build;
        r->has_pattern = sig->aob_hex[0] != '\0';

        const image_t *im = image_for(sig->module);
        if (!im) {
            fprintf(stderr, "no image loaded for module '%s'\n", sig->module);
            return -1;
        }

        uintptr_t anc = (sig->anchor.kind == NP_MATCH_NONE)
                          ? 0
                          : np_locate_anchor(im->mh, im->slide, im->text, im->text_sz,
                                             &sig->anchor);
        uintptr_t aob = resolve_by_aob(sig, im->text, im->text_sz);

        r->anchor = anc ? anc - (uintptr_t)im->slide : 0;
        r->aob    = aob ? aob - (uintptr_t)im->slide : 0;

        if (!r->anchor) db->unresolved++;
        if (r->recorded) {
            db->recorded_total++;
            if (r->anchor == r->recorded) db->recorded_match++;
        }
    }
    return 0;
}

// The database whose recorded addresses the anchors actually landed on describes
// the running client. Nothing in the app bundle reports the client build, so it
// has to be recognised rather than read.
static int pick_live(const dbcheck_t *dbs, int n) {
    int best = -1, best_hits = 0;
    for (int i = 0; i < n; i++) {
        if (dbs[i].recorded_match > best_hits) {
            best_hits = dbs[i].recorded_match;
            best = i;
        }
    }
    return best_hits ? best : -1;
}

static int report_db(const dbcheck_t *db, int is_live) {
    int bad = 0;

    printf("%s  build %llu%s\n", db->path, (unsigned long long)db->build,
           is_live ? "  [live client]" : "");

    for (int i = 0; i < db->count; i++) {
        const row_t *r = &db->rows[i];
        const char *verdict;

        if (r->kind == NP_MATCH_NONE)          { verdict = "NO ANCHOR";     bad++; }
        else if (!r->anchor)                   { verdict = (r->has_pattern && r->aob)
                                                             ? "anchor failed, aob resolves"
                                                             : "UNRESOLVED";
                                                 if (!(r->has_pattern && r->aob)) bad++; }
        else if (!is_live)                     { verdict = (r->has_pattern && r->aob && r->aob != r->anchor)
                                                             ? "stale pattern hit elsewhere"
                                                             : "resolved";           }
        else if (r->recorded && r->anchor != r->recorded) {
                                                 verdict = "WRONG";         bad++; }
        else if (!r->recorded)                 { verdict = "no recorded address";  }
        else if (r->has_pattern && r->aob != r->anchor) {
                                                 verdict = "AOB DISAGREES"; bad++; }
        else                                   { verdict = "OK";                   }

        printf("  %-56s %-13s anchor=0x%-8lx recorded=0x%-8lx aob=0x%-8lx  %s\n",
               r->name, kind_name(r->kind), (unsigned long)r->anchor,
               (unsigned long)r->recorded, (unsigned long)r->aob, verdict);
    }

    printf("  %d anchors resolved, %d unresolved", db->count - db->unresolved, db->unresolved);
    if (is_live)
        printf("; %d of %d recorded addresses matched\n", db->recorded_match, db->recorded_total);
    else
        printf("; recorded addresses and patterns describe another build\n");
    printf("\n");
    return bad;
}

// An anchor that finds a different function depending on which database it was
// read from would make the resolution order matter, and the dylib loads only one.
static int report_cross_db(const dbcheck_t *dbs, int n) {
    int bad = 0;
    for (int i = 0; i < n; i++) {
        for (int r = 0; r < dbs[i].count; r++) {
            const row_t *a = &dbs[i].rows[r];
            if (!a->anchor) continue;

            for (int j = i + 1; j < n; j++) {
                for (int s = 0; s < dbs[j].count; s++) {
                    const row_t *b = &dbs[j].rows[s];
                    if (strcmp(a->name, b->name) != 0 || !b->anchor) continue;
                    if (a->anchor == b->anchor) continue;

                    printf("CROSS-DB DISAGREEMENT %-40s %llu=0x%lx %llu=0x%lx\n",
                           a->name, (unsigned long long)dbs[i].build,
                           (unsigned long)a->anchor,
                           (unsigned long long)dbs[j].build,
                           (unsigned long)b->anchor);
                    bad++;
                }
            }
        }
    }
    if (bad) printf("\n");
    return bad;
}

// Exit 1 is a database with problems, 2 one that could not be read, 3 this machine being
// unable to answer. Callers feeding deliberately broken databases need those apart: a
// rejected database is a result, an unloadable client image means nothing was checked.
int main(int argc, char **argv) {
    const char *home = getenv("HOME");
    if (!home) { fprintf(stderr, "HOME unset\n"); return 3; }

    if (load_image(NP_MODULE_DEFAULT) != 0) return 3;

    char paths[MAX_DBS][512];
    int n = 0;
    for (int i = 1; i < argc && n < MAX_DBS; i++)
        snprintf(paths[n++], 512, "%s", argv[i]);
    if (!n) n = collect_dbs(paths, MAX_DBS);
    if (!n) { fprintf(stderr, "no signature databases in %s\n", SIGDB_DIR); return 3; }

    dbcheck_t dbs[MAX_DBS] = {0};
    for (int i = 0; i < n; i++) {
        snprintf(dbs[i].path, sizeof(dbs[i].path), "%s", paths[i]);
        if (np_load_profile(dbs[i].path, &dbs[i].sigdb) != 0) {
            fprintf(stderr, "cannot load sigdb '%s'\n", dbs[i].path);
            return 2;
        }
        dbs[i].loaded = 1;
        for (int j = 0; j < dbs[i].sigdb.sig_count; j++)
            if (load_image(dbs[i].sigdb.signatures[j].module) != 0) return 3;
    }
    for (int i = 0; i < n; i++) {
        if (check_db(&dbs[i]) != 0) return 2;
    }

    int live = pick_live(dbs, n);

    int bad = 0;
    for (int i = 0; i < n; i++) bad += report_db(&dbs[i], i == live);
    bad += report_cross_db(dbs, n);

    if (live < 0) {
        printf("no database describes the running client, so only the anchors were "
               "checked. Anchors are what the dylib resolves from, so this is not a "
               "failure.\n");
    } else {
        const image_t *sc = image_for(NP_MODULE_DEFAULT);
        bad += run_rtti(sc->mh, sc->slide, sc->text, sc->text_sz, dbs[live].build);
    }

    for (int i = 0; i < n; i++) {
        free(dbs[i].rows);
        np_free_profile(&dbs[i].sigdb);
    }
    return bad ? 1 : 0;
}
