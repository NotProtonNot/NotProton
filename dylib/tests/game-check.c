// The scan of an installed game, against a folder laid out the way the engines lay one
// out, and a PE built by hand so the header walk is read against known bytes.
#include "../feats/game.c"

#include <limits.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

int np_log_level = 0;
FILE *np_log_file = NULL;

static int failures;
static char root[PATH_MAX];

static void check(int ok, const char *what) {
    printf("  %s  %s\n", ok ? "ok  " : "FAIL", what);
    if (!ok) failures++;
}

static void put32(uint8_t *p, uint32_t v) {
    p[0] = (uint8_t)v; p[1] = (uint8_t)(v >> 8); p[2] = (uint8_t)(v >> 16); p[3] = (uint8_t)(v >> 24);
}
static void put16(uint8_t *p, uint16_t v) { p[0] = (uint8_t)v; p[1] = (uint8_t)(v >> 8); }

static void mkdirs(const char *rel) {
    char path[PATH_MAX];
    snprintf(path, sizeof path, "%s/%s", root, rel);
    for (char *at = path + strlen(root) + 1; *at; at++) {
        if (*at != '/') continue;
        *at = '\0';
        mkdir(path, 0755);
        *at = '/';
    }
    mkdir(path, 0755);
}

static void put_file(const char *rel, const void *data, size_t len) {
    char path[PATH_MAX];
    snprintf(path, sizeof path, "%s/%s", root, rel);
    FILE *f = fopen(path, "wb");
    if (!f) { perror(path); exit(1); }
    if (len) fwrite(data, 1, len, f);
    fclose(f);
}

// A PE just complete enough to walk: one section, one import descriptor, one DLL name.
// `pad` makes one binary bigger than another, which is how the scan picks between them.
#define PE_SIZE 0x400
static void put_pe(const char *rel, uint16_t machine, uint16_t magic, const char *dll, size_t pad) {
    uint8_t *pe = calloc(1, PE_SIZE + pad);
    const uint32_t peo = 0x80;
    memcpy(pe, "MZ", 2);
    put32(pe + 0x3C, peo);
    memcpy(pe + peo, "PE\0\0", 4);
    put16(pe + peo + 4, machine);
    put16(pe + peo + 6, 1);              // one section
    put16(pe + peo + 20, 240);           // optional header size
    put16(pe + peo + 24, magic);
    size_t dir_base = peo + 24 + (magic == 0x20B ? 112 : 96);
    put32(pe + dir_base - 4, 16);        // number of data directories
    put32(pe + dir_base + 8, 0x1000);    // import table RVA
    size_t sect = peo + 24 + 240;
    memcpy(pe + sect, ".text", 5);
    put32(pe + sect + 8, 0x1000);        // virtual size
    put32(pe + sect + 12, 0x1000);       // virtual address
    put32(pe + sect + 16, 0x200);        // raw size
    put32(pe + sect + 20, 0x200);        // raw pointer
    put32(pe + 0x200 + 12, 0x1050);      // first descriptor's name RVA
    memcpy(pe + 0x250, dll, strlen(dll));
    put_file(rel, pe, PE_SIZE + pad);
    free(pe);
}

static np_game_t scan(const char *rel) {
    char path[PATH_MAX];
    snprintf(path, sizeof path, "%s/%s", root, rel);
    np_game_t g;
    np_game_scan(path, &g);
    return g;
}

static const char *base(const char *path) {
    const char *slash = strrchr(path, '/');
    return slash ? slash + 1 : path;
}

int main(void) {
    snprintf(root, sizeof root, "%s/game.XXXXXX", getenv("TMPDIR") ? getenv("TMPDIR") : "/tmp");
    if (!mkdtemp(root)) { perror("mkdtemp"); return 1; }

    printf("== an Unreal game ==\n");
    // Unreal keeps the binary that matters four folders down, with a smaller shim on top.
    mkdirs("ue/Game/Binaries/Win64");
    mkdirs("ue/Engine");
    put_pe("ue/Game/Binaries/Win64/Game-Win64-Shipping.exe", 0x8664, 0x20B, "d3d12.dll", 0);
    put_pe("ue/GameLauncher.exe", 0x8664, 0x20B, "d3d11.dll", 0x2000);
    np_game_t ue = scan("ue");
    check(ue.scanned, "the folder is read");
    check(strcmp(base(ue.exe), "Game-Win64-Shipping.exe") == 0,
          "the shipping binary is picked over the bigger shim");
    check(ue.engine == NP_ENGINE_UNREAL, "the engine is Unreal");
    check(ue.bits == 64, "it is 64-bit");
    check((ue.gfx & NP_GFX_D3D12) != 0, "and it asks for Direct3D 12");

    printf("== a Unity game ==\n");
    mkdirs("unity");
    put_pe("unity/Game.exe", 0x014C, 0x10B, "d3d11.dll", 0);
    put_file("unity/UnityPlayer.dll", "", 0);
    np_game_t unity = scan("unity");
    check(unity.engine == NP_ENGINE_UNITY, "the engine is Unity");
    check(unity.bits == 32, "a 32-bit binary is read as one");
    check((unity.gfx & NP_GFX_D3D11) != 0, "and it asks for Direct3D 11");
    check((unity.gfx & NP_GFX_D3D12) == 0, "and for nothing it does not");

    printf("== what the folder gives away ==\n");
    mkdirs("ac/EasyAntiCheat");
    put_pe("ac/Game.exe", 0x8664, 0x20B, "d3d11.dll", 0);
    check(scan("ac").anticheat == NP_AC_EASYANTICHEAT, "Easy Anti-Cheat is seen");
    mkdirs("be");
    put_pe("be/Game.exe", 0x8664, 0x20B, "d3d11.dll", 0);
    put_file("be/BEService.exe", "", 0);
    check(scan("be").anticheat == NP_AC_BATTLEYE, "BattlEye is seen");
    mkdirs("ubi");
    put_pe("ubi/Game.exe", 0x8664, 0x20B, "d3d11.dll", 0);
    put_file("ubi/UbisoftConnectInstaller.exe", "", 0);
    np_game_t ubi = scan("ubi");
    check(ubi.launcher == NP_LAUNCHER_UBISOFT, "Ubisoft Connect is seen");
    check(strcmp(base(ubi.exe), "Game.exe") == 0, "and its installer is not taken for the game");
    // The EOS SDK is in half the catalogue and starts nothing.
    mkdirs("eos");
    put_pe("eos/Game.exe", 0x8664, 0x20B, "d3d11.dll", 0);
    put_file("eos/EOSSDK-Win64-Shipping.dll", "", 0);
    check(scan("eos").launcher == NP_LAUNCHER_NONE, "the EOS SDK is not a launcher");

    printf("== a game with its own macOS build ==\n");
    mkdirs("native/Game.app");
    put_pe("native/Game.exe", 0x8664, 0x20B, "d3d11.dll", 0);
    check(scan("native").native, "the app bundle is seen");

    printf("== a shipped library names the API too ==\n");
    mkdirs("shipped");
    put_pe("shipped/Game.exe", 0x8664, 0x20B, "opengl32.dll", 0);
    put_file("shipped/d3d12core.dll", "", 0);
    check((scan("shipped").gfx & NP_GFX_D3D12) != 0, "a shipped D3D12 layer counts");

    printf("== nothing to read ==\n");
    np_game_t none;
    check(!np_game_scan("/nope/not/here", &none) && !none.scanned, "a folder that is not there");
    check(!np_game_scan(NULL, &none), "and no folder at all");
    mkdirs("empty");
    np_game_t empty = scan("empty");
    check(empty.scanned && !empty.exe[0] && !empty.gfx, "an empty folder is read and says nothing");

    printf(failures ? "==> game-check: %d failure(s)\n" : "==> game-check: installs read as expected\n",
           failures);
    return failures ? 1 : 0;
}
