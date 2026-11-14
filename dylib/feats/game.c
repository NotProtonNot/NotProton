// What a game is, read from the files Steam installed: the executable's word size, the
// graphics API it asks for, and the anti-cheat, launcher or engine its folder gives away.
// Nothing here is a judgement; it is what is on disk.
#include "game.h"
#include "../util/file.h"
#include "../util/log.h"
#include "../util/pe.h"

#include <dirent.h>
#include <fcntl.h>
#include <sys/mman.h>
#include <unistd.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <strings.h>
#include <sys/stat.h>

// A game's folder is walked, not read whole: enough to reach where the engines keep
// their binaries -- Unreal's are four deep, under <Game>/Binaries/Win64 -- without
// turning Steam's startup into a disk crawl.
#define NP_SCAN_DEPTH   5
#define NP_SCAN_ENTRIES 20000
// The executable is mapped rather than read, so a 2 GB binary costs the pages that are
// actually touched. The plain-text sweep for dynamically loaded names stops here.
#define NP_PE_TEXT_MAX  (64u << 20)

typedef struct {
    np_game_t *game;
    long long  best;     // the largest candidate seen, by size
    int        shipping;  // an engine's own binary was found, which outranks any size
    int        entries;
} scan_t;

static int ends_with_ci(const char *s, const char *suffix) {
    size_t n = strlen(s), m = strlen(suffix);
    return n >= m && strcasecmp(s + n - m, suffix) == 0;
}

static int has_ci(const char *s, const char *needle) {
    size_t n = strlen(s), m = strlen(needle);
    for (size_t i = 0; m && n >= m && i <= n - m; i++)
        if (strncasecmp(s + i, needle, m) == 0) return 1;
    return 0;
}

// Names that are in the folder for everyone's sake rather than the game's: an installer,
// a crash reporter, a prerequisite. Picking one of these would read the wrong binary.
static int is_side_binary(const char *name) {
    static const char *const side[] = {
        "unitycrashhandler", "crashreport", "crashhandler", "vcredist", "dxsetup",
        "directx", "dotnetfx", "oalinst", "uninstall", "setup", "installscript",
        "easyanticheat", "beservice", "be_service", "touchup", "prereq", "redist",
        "benchmark", "editor", "server", "install", "activation", "cleanup",
        "ubisoftconnect", "uplay", "eadesktop", "ealauncher", "epicgameslauncher",
        "dotnet", "openal", "physx", "quicksfv", "unitysetup", NULL,
    };
    for (size_t i = 0; side[i]; i++)
        if (has_ci(name, side[i])) return 1;
    return 0;
}

static void note_markers(np_game_t *g, const char *name) {
    if (has_ci(name, "easyanticheat") || has_ci(name, "eac_launcher") || has_ci(name, "_eac"))
        g->anticheat = NP_AC_EASYANTICHEAT;
    else if (has_ci(name, "battleye") || strcasecmp(name, "beservice.exe") == 0
             || strcasecmp(name, "beclient.dll") == 0)
        g->anticheat = NP_AC_BATTLEYE;
    else if (has_ci(name, "vanguard") || strcasecmp(name, "vgc.exe") == 0)
        g->anticheat = NP_AC_VANGUARD;

    if (has_ci(name, "eadesktop") || has_ci(name, "ealauncher") || has_ci(name, "eacore")
        || strcasecmp(name, "activation.exe") == 0)
        g->launcher = NP_LAUNCHER_EA;
    else if (has_ci(name, "ubisoft") || has_ci(name, "uplay"))
        g->launcher = NP_LAUNCHER_UBISOFT;
    // Not the EOS SDK: half the catalogue ships it for crossplay and friends lists, and
    // none of those games start through the Epic launcher.
    else if (has_ci(name, "epicgameslauncher"))
        g->launcher = NP_LAUNCHER_EPIC;
    else if (has_ci(name, "rockstar") || has_ci(name, "socialclub"))
        g->launcher = NP_LAUNCHER_ROCKSTAR;

    if (strcasecmp(name, "unityplayer.dll") == 0 || strcasecmp(name, "mono.dll") == 0)
        g->engine = NP_ENGINE_UNITY;
    else if (ends_with_ci(name, "-shipping.exe") || strcasecmp(name, "engine") == 0)
        g->engine = NP_ENGINE_UNREAL;
}

// A shipped DLL names the API as plainly as an import does, and a game that carries its
// own d3d12 layer is a game that reaches for D3D12.
static void note_library(np_game_t *g, const char *name) {
    if (strcasecmp(name, "d3d12.dll") == 0 || strcasecmp(name, "d3d12core.dll") == 0)
        g->gfx |= NP_GFX_D3D12;
    else if (strcasecmp(name, "d3d11.dll") == 0) g->gfx |= NP_GFX_D3D11;
    else if (strcasecmp(name, "d3d9.dll") == 0) g->gfx |= NP_GFX_D3D9;
    else if (strcasecmp(name, "vulkan-1.dll") == 0) g->gfx |= NP_GFX_VULKAN;
}

static void walk(const char *dir, int depth, scan_t *st, char *best_path, size_t best_size) {
    if (depth > NP_SCAN_DEPTH || st->entries >= NP_SCAN_ENTRIES) return;
    DIR *d = opendir(dir);
    if (!d) return;
    for (struct dirent *e; (e = readdir(d)) && st->entries < NP_SCAN_ENTRIES; ) {
        if (e->d_name[0] == '.') continue;
        st->entries++;
        char path[NP_GAME_PATH_MAX];
        if ((size_t)snprintf(path, sizeof path, "%s/%s", dir, e->d_name) >= sizeof path) continue;
        note_markers(st->game, e->d_name);

        struct stat sb;
        if (stat(path, &sb) != 0) continue;
        // A macOS bundle beside the Windows files is the game's own native build, which
        // Steam runs without any of this.
        if (ends_with_ci(e->d_name, ".app")) { st->game->native = 1; continue; }
        if (S_ISDIR(sb.st_mode)) {
            walk(path, depth + 1, st, best_path, best_size);
            continue;
        }
        if (!S_ISREG(sb.st_mode)) continue;
        if (ends_with_ci(e->d_name, ".dll")) note_library(st->game, e->d_name);
        // The game's own executable is the biggest one that is not there for the
        // installer, the crash reporter or the anti-cheat.
        if (!ends_with_ci(e->d_name, ".exe") || is_side_binary(e->d_name)) continue;
        // Unreal names the binary it actually ships, and that one outranks whatever
        // shim or trampoline sits at the top of the folder being bigger.
        int shipping = ends_with_ci(e->d_name, "-shipping.exe");
        if (shipping) st->game->engine = NP_ENGINE_UNREAL;
        if (st->shipping && !shipping) continue;
        if (shipping && !st->shipping) st->best = -1;
        if ((long long)sb.st_size > st->best) {
            st->shipping = shipping;
            st->best = (long long)sb.st_size;
            snprintf(best_path, best_size, "%s", path);
        }
    }
    closedir(d);
}

// The DLL names an import descriptor points at, and the names the binary carries for the
// libraries it loads itself. A game that calls LoadLibrary("d3d12.dll") imports nothing,
// so the plain text is read too.
static void note_api_name(np_game_t *g, const char *name) {
    if (strcasecmp(name, "d3d9.dll") == 0) g->gfx |= NP_GFX_D3D9;
    else if (strcasecmp(name, "d3d11.dll") == 0) g->gfx |= NP_GFX_D3D11;
    else if (strcasecmp(name, "d3d12.dll") == 0) g->gfx |= NP_GFX_D3D12;
    else if (strncasecmp(name, "dxgi.dll", 8) == 0) g->gfx |= NP_GFX_DXGI;
    else if (strcasecmp(name, "vulkan-1.dll") == 0) g->gfx |= NP_GFX_VULKAN;
    else if (strcasecmp(name, "opengl32.dll") == 0) g->gfx |= NP_GFX_OPENGL;
}

static void read_imports(np_game_t *g, const np_pe_view_t *pe, size_t peo, uint16_t magic) {
    size_t dir_base = peo + 24 + (magic == 0x20B ? 112 : 96);
    uint32_t count = 0, table = 0;
    if (!np_pe_rd32(pe, dir_base - 4, &count) || count < 2) return;
    if (!np_pe_rd32(pe, dir_base + 8, &table) || !table) return;
    size_t at;
    if (!np_pe_rva_off(pe, table, &at)) return;
    // Each descriptor is 20 bytes and the list ends on an all-zero one.
    for (int i = 0; i < 512; i++, at += 20) {
        uint32_t name_rva = 0;
        if (!np_pe_rd32(pe, at + 12, &name_rva) || !name_rva) return;
        size_t name_at;
        if (!np_pe_rva_off(pe, name_rva, &name_at) || name_at >= pe->n) return;
        char name[64];
        size_t k = 0;
        while (k < sizeof name - 1 && name_at + k < pe->n && pe->p[name_at + k]) {
            name[k] = (char)pe->p[name_at + k];
            k++;
        }
        name[k] = '\0';
        note_api_name(g, name);
    }
}

// The names a binary loads by hand, looked for as plain bytes. Bounded to what was read.
static void read_loaded_names(np_game_t *g, const uint8_t *p, size_t n) {
    static const char *const names[] = { "d3d9.dll", "d3d11.dll", "d3d12.dll", "dxgi.dll",
                                         "vulkan-1.dll", "opengl32.dll", NULL };
    for (size_t i = 0; names[i]; i++) {
        size_t m = strlen(names[i]);
        for (size_t at = 0; n >= m && at <= n - m; at++) {
            // Case folded by hand: the table is lowercase and a binary may carry either.
            size_t k = 0;
            while (k < m && (p[at + k] | 0x20) == (unsigned char)names[i][k]) k++;
            if (k == m) { note_api_name(g, names[i]); break; }
        }
    }
}

static void read_executable(np_game_t *g) {
    int fd = open(g->exe, O_RDONLY | O_CLOEXEC);
    if (fd < 0) return;
    struct stat sb;
    if (fstat(fd, &sb) != 0 || !S_ISREG(sb.st_mode) || sb.st_size <= 0) { close(fd); return; }
    size_t len = (size_t)sb.st_size;
    // Mapped, not read: only the pages the header and the import table fall on are paid
    // for, which is what makes reading a multi-gigabyte binary cheap.
    uint8_t *buf = mmap(NULL, len, PROT_READ, MAP_PRIVATE, fd, 0);
    close(fd);
    if (buf == MAP_FAILED) return;

    np_pe_view_t pe = { buf, len, 0, 0, 0, 0 };
    uint16_t mz = 0, nsects = 0, opt_size = 0, magic = 0, machine = 0;
    uint32_t peo32 = 0, sig = 0;
    if (np_pe_rd16(&pe, 0, &mz) && mz == 0x5A4D && np_pe_rd32(&pe, 0x3C, &peo32)) {
        size_t peo = peo32;
        if (np_pe_rd32(&pe, peo, &sig) && sig == 0x00004550
            && np_pe_rd16(&pe, peo + 4, &machine) && np_pe_rd16(&pe, peo + 6, &nsects)
            && np_pe_rd16(&pe, peo + 20, &opt_size) && np_pe_rd16(&pe, peo + 24, &magic)
            && nsects && nsects <= NP_PE_MAX_SECTIONS) {
            g->bits = machine == 0x8664 || machine == 0xAA64 || magic == 0x20B ? 64
                    : machine == 0x014C ? 32 : 0;
            size_t sects = peo + 24 + opt_size;
            if (sects <= pe.n && (pe.n - sects) / 40 >= nsects) {
                pe.sects = sects;
                pe.nsects = nsects;
                read_imports(g, &pe, peo, magic);
            }
        }
    }
    read_loaded_names(g, buf, len < NP_PE_TEXT_MAX ? len : NP_PE_TEXT_MAX);
    munmap(buf, len);
}

int np_game_scan(const char *install_dir, np_game_t *out) {
    if (!out) return 0;
    memset(out, 0, sizeof *out);
    if (!install_dir || !*install_dir) return 0;
    struct stat sb;
    if (stat(install_dir, &sb) != 0 || !S_ISDIR(sb.st_mode)) return 0;

    scan_t st = { out, -1, 0, 0 };
    char best[NP_GAME_PATH_MAX] = "";
    walk(install_dir, 1, &st, best, sizeof best);
    snprintf(out->exe, sizeof out->exe, "%s", best);
    if (out->exe[0]) read_executable(out);
    out->scanned = 1;
    NP_LOG("game: %s is %d-bit, gfx 0x%x, anti-cheat %s, launcher %s, engine %s",
           out->exe[0] ? out->exe : install_dir, out->bits, out->gfx,
           np_game_anticheat_name(out->anticheat), np_game_launcher_name(out->launcher),
           np_game_engine_name(out->engine));
    return 1;
}

const char *np_game_anticheat_name(np_anticheat_t a) {
    switch (a) {
        case NP_AC_EASYANTICHEAT: return "Easy Anti-Cheat";
        case NP_AC_BATTLEYE:      return "BattlEye";
        case NP_AC_VANGUARD:      return "Vanguard";
        default:                  return "";
    }
}

const char *np_game_launcher_name(np_launcher_t l) {
    switch (l) {
        case NP_LAUNCHER_EA:       return "the EA app";
        case NP_LAUNCHER_UBISOFT:  return "Ubisoft Connect";
        case NP_LAUNCHER_EPIC:     return "the Epic Games launcher";
        case NP_LAUNCHER_ROCKSTAR: return "the Rockstar launcher";
        default:                   return "";
    }
}

const char *np_game_engine_name(np_engine_t e) {
    switch (e) {
        case NP_ENGINE_UNREAL: return "Unreal Engine";
        case NP_ENGINE_UNITY:  return "Unity";
        default:               return "";
    }
}
