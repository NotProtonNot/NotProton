// The layout probes read instruction words straight out of the client, and everything else
// reaches it through a function pointer an installer sets. Including the unit rather than
// linking points the probes at synthesised instructions and the pointers at stubs. No Steam.
#include "../feats/compat.c"
#include "../feats/usershortcuts.c"

#include <stdio.h>
#include <pthread.h>
#include <stdatomic.h>

static atomic_int home_calls;
static atomic_int home_ready;

// Silent, because half of these checks drive paths whose whole job is to refuse and log.
int   np_log_level = -1;
FILE *np_log_file  = NULL;

int np_log_first_hit(const void *anchor, unsigned long tag) {
    (void)anchor; (void)tag;
    return 1;
}

const char *np_home_dir(void) {
    if (atomic_fetch_add(&home_calls, 1) == 0) {
        usleep(50000);
        atomic_store(&home_ready, 1);
    }
    return "/nonexistent";
}

int np_get_section_containing(const struct mach_header_64 *mh, intptr_t slide,
                              uintptr_t addr, uintptr_t *out_base, size_t *out_size) {
    (void)mh; (void)slide; (void)addr; (void)out_base; (void)out_size;
    return -1;
}

uintptr_t np_rtti_vptr(const struct mach_header_64 *mh, intptr_t slide,
                       uintptr_t text_base, size_t text_size, const char *type_name) {
    (void)mh; (void)slide; (void)text_base; (void)text_size; (void)type_name;
    return 0;
}

static int failures;

static void check(int ok, const char *what) {
    if (!ok) {
        printf("FAIL %s\n", what);
        failures++;
    }
}

static void *first_fallback(void *arg) {
    int *ok = arg;
    const char *name = np_compat_fallback_tool_name();
    *ok = atomic_load(&home_ready) && strcmp(name, "notproton") == 0;
    return NULL;
}

static void concurrent_fallback_cases(void) {
    pthread_t threads[16];
    int results[16] = {0};
    size_t started = 0;
    for (; started < 16; started++) {
        if (pthread_create(&threads[started], NULL, first_fallback, &results[started]) != 0) {
            check(0, "the fallback reader thread starts");
            break;
        }
    }
    for (size_t i = 0; i < started; i++) {
        pthread_join(threads[i], NULL);
        check(results[i], "every first fallback read waits for initialization");
    }
    check(atomic_load(&home_calls) == 2, "the tool list is initialized once");
}

// A64 encodings the probes look for.
#define NOP 0xD503201Fu
static uint32_t ldr32_x0(uint32_t off, uint32_t rt) { return 0xB9400000u | ((off / 4u) << 10) | rt; }
static uint32_t ldr64(uint32_t base, uint32_t off, uint32_t rt) {
    return 0xF9400000u | ((off / 8u) << 10) | (base << 5) | rt;
}
static uint32_t ldrb(uint32_t base, uint32_t off, uint32_t rt) {
    return 0x39400000u | (off << 10) | (base << 5) | rt;
}
static uint32_t mov_x0(uint32_t rd) { return 0xAA0003E0u | rd; }
static uint32_t cbz(int32_t words, uint32_t rt) {
    return 0x34000000u | (((uint32_t)words & 0x7FFFFu) << 5) | rt;
}

// The gate the probe is handed: the appid load, a branch past it, and the install load
// the branch lands near. Laid out in a fresh buffer so one case cannot feed the next.
#define CODE_WORDS 64
#define GATE_IDX   32
static uint32_t code[CODE_WORDS];

static uintptr_t build_gate(uint32_t appid_off, uint32_t install_off) {
    for (int i = 0; i < CODE_WORDS; i++) code[i] = NOP;
    code[GATE_IDX]     = ldr32_x0(appid_off, 3);
    code[GATE_IDX + 1] = cbz(4, 3);                       // lands on GATE_IDX + 5
    code[GATE_IDX + 5] = ldr64(0, install_off, 4);
    return (uintptr_t)&code[GATE_IDX];
}

// The far-end corroboration: two loads through x21 inside the window the probe scans.
static uint32_t oslist_code[CODE_WORDS];

static uintptr_t build_oslist(uint32_t from_off, uint32_t to_off) {
    for (int i = 0; i < CODE_WORDS; i++) oslist_code[i] = NOP;
    oslist_code[GATE_IDX]     = ldr64(21, from_off, 1);
    oslist_code[GATE_IDX + 1] = ldr64(21, to_off, 2);
    return (uintptr_t)&oslist_code[GATE_IDX];
}

static void probe_cases(void) {
    g_tool_shift = 0;
    check(np_compat_probe_tool_layout(build_gate(0x60, 0x58), 0) == 1,
          "the reference layout probes clean");
    check(g_tool_shift == 0, "the reference layout reports no shift");
    check(np_compat_tool_stride() == COMPAT_TOOL_STRIDE, "an unshifted entry keeps its stride");

    g_tool_shift = 0;
    check(np_compat_probe_tool_layout(build_gate(0x68, 0x60), 0) == 1,
          "a client that grew the entry by 8 probes clean");
    check(np_compat_tool_off(COMPAT_TOOL_APPID_OFF) == 0x68, "appid follows the shift");
    check(np_compat_tool_off(COMPAT_TOOL_INSTALL_OFF) == 0x60, "install follows the shift");
    check(np_compat_tool_off(COMPAT_TOOL_GATE_FLAGS_OFF) == COMPAT_TOOL_GATE_FLAGS_OFF,
          "a field ahead of the insertion point does not follow the shift");
    check(np_compat_tool_stride() == COMPAT_TOOL_STRIDE + 8, "the entry widens by what it moved");

    // A shift already established has to survive a probe that cannot agree with itself,
    // because a half-written layout is worse than the one being replaced.
    g_tool_shift = 8;
    check(np_compat_probe_tool_layout(build_gate(0x68, 0x58), 0) == 0,
          "appid and install disagreeing about the shift is refused");
    check(g_tool_shift == 8, "a refused probe leaves the shift alone");

    g_tool_shift = 0;
    check(np_compat_probe_tool_layout(0, 0) == 0, "no gate is refused");

    for (int i = 0; i < CODE_WORDS; i++) code[i] = NOP;
    check(np_compat_probe_tool_layout((uintptr_t)&code[GATE_IDX], 0) == 0,
          "a gate that is not the appid load is refused");

    uintptr_t gate = build_gate(0x60, 0x58);
    code[GATE_IDX + 1] = NOP;
    check(np_compat_probe_tool_layout(gate, 0) == 0, "an appid load with no branch after it is refused");

    gate = build_gate(0x60, 0x58);
    code[GATE_IDX + 5] = NOP;
    check(np_compat_probe_tool_layout(gate, 0) == 0, "a branch landing on no install load is refused");
}

static void oslist_cases(void) {
    g_tool_shift = 0;
    check(np_compat_probe_tool_layout(build_gate(0x68, 0x60), build_oslist(0x78, 0x80)) == 1,
          "the far end agreeing on the shift probes clean");
    check(g_tool_shift == 8, "agreement at both ends keeps the shift");

    g_tool_shift = 0;
    check(np_compat_probe_tool_layout(build_gate(0x68, 0x60), build_oslist(0x70, 0x78)) == 0,
          "the near fields moving and the oslist not is refused");
    check(g_tool_shift == 0, "a far-end disagreement writes no shift");

    // Whichever order the comparison loads them in, the higher offset is to_oslist.
    g_tool_shift = 0;
    check(np_compat_probe_tool_layout(build_gate(0x68, 0x60), build_oslist(0x80, 0x78)) == 1,
          "the oslist pair is read by offset rather than by load order");
}

static void enabled_cases(void) {
    g_enabled_off = COMPAT_MANAGER_ENABLED_OFF;

    for (int i = 0; i < CODE_WORDS; i++) code[i] = NOP;
    code[0] = mov_x0(21);
    code[1] = ldrb(21, 0x7C0, 8);
    check(np_compat_probe_enabled_off((uintptr_t)code) == 1, "the enabled flag probes clean");
    check(np_compat_enabled_off() == 0x7C0, "the probed flag offset is what gets reported");

    g_enabled_off = COMPAT_MANAGER_ENABLED_OFF;
    for (int i = 0; i < CODE_WORDS; i++) code[i] = NOP;
    code[0] = mov_x0(21);
    code[1] = ldrb(21, 0x20, 8);
    check(np_compat_probe_enabled_off((uintptr_t)code) == 0,
          "a byte read too early in the object is not taken for the flag");
    check(np_compat_enabled_off() == COMPAT_MANAGER_ENABLED_OFF,
          "a refused flag probe leaves the baseline in place");

    for (int i = 0; i < CODE_WORDS; i++) code[i] = NOP;
    code[0] = ldrb(21, 0x7C0, 8);
    check(np_compat_probe_enabled_off((uintptr_t)code) == 0,
          "a body that never parks this in a register is refused");

    check(np_compat_probe_enabled_off(0) == 0, "no function is refused");
}

// A manager holding `count` entries, the one at `named_slot` carrying the tool name.
static uint8_t manager[0x400];
static uint8_t entries[(COMPAT_MANAGER_TOOLS_HEADROOM + 64) * (COMPAT_TOOL_STRIDE + 64)];

static void *build_manager(uint32_t count, int named_slot) {
    memset(manager, 0, sizeof manager);
    memset(entries, 0, sizeof entries);
    *(uint8_t **)(manager + COMPAT_MANAGER_TOOL_ARRAY_OFF) = entries;
    *(uint32_t *)(manager + COMPAT_MANAGER_TOOL_COUNT_OFF) = count;
    if (named_slot >= 0) {
        uint8_t *entry = entries + (size_t)named_slot * np_compat_tool_stride();
        *(const char **)(entry + COMPAT_TOOL_NAME_OFF) = TOOL_DIR_NAME;
    }
    return manager;
}

static void manager_cases(void) {
    g_tool_shift = 0;

    void *mgr = build_manager(3, 1);
    void *want = entries + np_compat_tool_stride();
    check(np_compat_registered_tool(mgr) == want, "the entry registered under the tool name is found");

    check(np_compat_registered_tool(build_manager(3, -1)) == NULL,
          "a manager holding no entry of ours reports none");
    check(np_compat_registered_tool(NULL) == NULL, "no manager reports no entry");

    // A count this large means the offset it was read from moved, so the array it
    // describes is not one to walk.
    uint32_t cap = np_compat_manager_tools_max();
    check(cap <= COMPAT_MANAGER_TOOLS_HEADROOM + 64, "the manager fixture holds the cap");
    check(np_compat_registered_tool(build_manager(cap + 1, 1)) == NULL,
          "a count past the cap is refused rather than walked");
    check(np_compat_registered_tool(build_manager(cap, -1)) == NULL,
          "a count at the cap is still walked");

    mgr = build_manager(3, 1);
    *(uint8_t **)((uint8_t *)mgr + COMPAT_MANAGER_TOOL_ARRAY_OFF) = NULL;
    check(np_compat_registered_tool(mgr) == NULL, "a manager with no array is refused");

    // The walk steps by the live stride, so an entry that grew is still found.
    g_tool_shift = 8;
    mgr = build_manager(3, 2);
    check(np_compat_registered_tool(mgr) == entries + 2 * np_compat_tool_stride(),
          "the walk steps by the live stride rather than the baseline");
    g_tool_shift = 0;
}

static void tool_list_cases(void) {
    static const char path[] = "out/compatcheck-tools";
    FILE *f = fopen(path, "w");
    if (!f) {
        check(0, "the tool list fixture can be written");
        return;
    }
    fputs("notproton\t27.0.0.40921-fex\tfex\tCrossOver Preview (FEX)\n"
          "notproton-fex-41069\t27.0.0.41069-fex\tfex\tCrossOver Preview 41069 (FEX)\n"
          "notproton-fex-rosetta\t27.0.0.40921-fex\trosetta\tCrossOver Preview (Rosetta)\n"
          "notproton-26.3\t26.3.0.39832\trosetta\tCrossOver 26.3\n"
          "notproton\t26.3.0.39832\trosetta\tDuplicate\n"
          "proton-other\t1\trosetta\tForeign\n"
          "notproton-x\t1\tarm\tBad flavor\n"
          "notproton-q\t1\trosetta\tQuote\"d\n"
          "notproton-short\t1\trosetta\n"
          "\n", f);
    fclose(f);

    int kept = np_compat_load_tool_list(path, "/tools");
    unlink(path);

    check(kept == 4, "only well-formed, unique, notproton-named lines are kept");
    check(strcmp(g_tools[0].name, "notproton") == 0
          && strcmp(g_tools[0].flavor, "fex") == 0, "the first line stays first");
    check(strcmp(g_tools[3].build, "26.3.0.39832") == 0
          && strcmp(g_tools[3].dir, "/tools/notproton-26.3") == 0,
          "each tool carries its build and directory");

    uint8_t *mgr = build_manager(3, -1);
    *(const char **)(entries + np_compat_tool_stride() + COMPAT_TOOL_NAME_OFF) = "notproton-26.3";
    check(np_compat_registered_tool(mgr) == entries + np_compat_tool_stride(),
          "the most preferred tool the manager holds is the default");
    *(const char **)(entries + COMPAT_TOOL_NAME_OFF) = "notproton";
    check(np_compat_registered_tool(mgr) == entries,
          "the first listed tool wins when the manager holds it");

    const char *fex[3] = { NULL, NULL, NULL };
    check(np_compat_fex_tools(fex, 3) == 2 && strcmp(fex[0], "notproton") == 0
          && strcmp(fex[1], "notproton-fex-41069") == 0 && !fex[2],
          "only the fex flavor counts as FEX, not a FEX build's Rosetta tool");
    fex[0] = fex[1] = NULL;
    check(np_compat_fex_tools(fex, 1) == 1 && strcmp(fex[0], "notproton") == 0 && !fex[1],
          "the FEX list stops at its limit, keeping the first listed");

    f = fopen(path, "w");
    if (!f) {
        check(0, "the long tool list fixture can be written");
        return;
    }
    for (int i = 0; i < 40; i++)
        fprintf(f, "notproton-%d\t1\trosetta\tTool %d\n", i, i);
    fclose(f);
    kept = np_compat_load_tool_list(path, "/tools");
    unlink(path);
    check(kept == 40 && strcmp(g_tools[39].name, "notproton-39") == 0
          && strcmp(g_tools[0].dir, "/tools/notproton-0") == 0, "a long list keeps every tool");
    check(strcmp(np_compat_fallback_tool_name(), "notproton-0") == 0,
          "the fallback is the first configured tool");
    check(np_compat_fex_tools(fex, 3) == 0, "a list with no FEX tool has no FEX names");

    check(np_compat_load_tool_list("out/compatcheck-missing", "/tools") == 0
          && !g_tool_list_present, "a missing list keeps no tools and says so");
}

static void tool_launch_cases(void) {
    static const char *tool[] = {
        "'/tools/compatibilitytools.d/notproton/.'/run waitforexitandrun  '/g/game.exe'",
        "A=1 '/tools/compatibilitytools.d/notproton-26.3/.'/run waitforexitandrun  '/g/game.exe' -x",
        "'/tools/compatibilitytools.d/notproton-fex-rosetta/.'/run run ",
        "'/tools/compatibilitytools.d/notproton'/run waitforexitandrun  '/g/game.exe'",
        "'/Volumes/Ext/Steam/compatibilitytools.d/notproton/.'/run waitforexitandrun '/g/game.exe'",
    };
    static const char *native[] = {
        "'/g/Game.app' -windowed",
        "'/g/Game.app/Contents/MacOS/Game'",
        "'/tools/compatibilitytools.d/proton-other/.'/run waitforexitandrun '/g/game.exe'",
        "'/tools/compatibilitytools.d/notproton/Game' -x",
        "'/tools/compatibilitytools.d/notproton/sub/.'/run waitforexitandrun '/g/game.exe'",
        "'/tools/compatibilitytools.d/notproton'/other '/g/game.exe'",
        "",
    };
    for (size_t i = 0; i < sizeof(tool) / sizeof(tool[0]); i++)
        check(np_compat_runs_tool(tool[i]), tool[i]);
    for (size_t i = 0; i < sizeof(native) / sizeof(native[0]); i++)
        check(!np_compat_runs_tool(native[i]), native[i]);
    check(!np_compat_runs_tool(NULL), "no command line is no tool launch");
}

static int put(const char *dir, const char *name, const char *text) {
    char path[768];
    snprintf(path, sizeof(path), "%s/%s", dir, name);
    FILE *f = fopen(path, "w");
    if (!f) return -1;
    fputs(text, f);
    return fclose(f);
}

static int exists(const char *path) {
    return access(path, F_OK) == 0;
}

static void stale_tool_cases(void) {
    char root[] = "out/compatcheck-toolsd.XXXXXX";
    if (!mkdtemp(root)) {
        check(0, "the tools directory fixture can be made");
        return;
    }
    char current[700], legacy[700], user[700], lookalike[700];
    snprintf(current, sizeof(current), "%s/notproton-26.3", root);
    snprintf(legacy, sizeof(legacy), "%s/notproton", root);
    snprintf(user, sizeof(user), "%s/notproton-mine", root);
    snprintf(lookalike, sizeof(lookalike), "%s/notproton-copy", root);
    const char *dirs[] = { current, legacy, user, lookalike };
    for (size_t i = 0; i < 4; i++) mkdir(dirs[i], 0755);

    put(current, "flavor", "rosetta\n");
    put(current, "run", "#!/bin/sh\n# notproton CrossOver compatibility tool shim\n");
    put(legacy, "run", "#!/bin/sh\n# notproton CrossOver compatibility tool shim\nset -e\n");
    put(legacy, "toolmanifest.vdf", "\"manifest\" {}\n");
    put(legacy, "compatibilitytool.vdf", "\"compatibilitytools\" {}\n");
    put(user, "run", "#!/bin/sh\nexec my-wine \"$@\"\n");
    put(lookalike, "run", "#!/bin/sh\n# notproton CrossOver compatibility tool shim\n");
    put(lookalike, "notes.txt", "mine\n");

    g_tool_count = 0;
    remove_unlisted_tools(root);

    check(!exists(current), "an unlisted tool with a flavor file is removed");
    check(!exists(legacy), "the single-tool dylib's directory is removed");
    check(exists(user), "a notproton directory the user wrote stays");
    char notes[768];
    snprintf(notes, sizeof(notes), "%s/notes.txt", lookalike);
    check(exists(notes), "files this project did not write stay with their directory");

    remove(notes);
    char path[768];
    snprintf(path, sizeof(path), "%s/run", user);
    remove(path);
    rmdir(user);
    rmdir(lookalike);
    rmdir(root);
}

static uint32_t stub_platforms_value;
static uint32_t stub_platforms(void *mgr, uint32_t appid) {
    (void)mgr; (void)appid;
    return stub_platforms_value;
}

static const char *stub_mapping_entry[3];
static void *stub_find_mapping(void *mgr, uint32_t appid) {
    (void)mgr; (void)appid;
    return stub_mapping_entry;
}

static uint32_t last_priority;
static uint32_t last_appid;
static void stub_set_mapping(void *mgr, uint32_t appid, const char *tool_name,
                             const char *config, uint32_t priority) {
    (void)mgr; (void)tool_name; (void)config;
    last_appid = appid;
    last_priority = priority;
}

static void installed_fn_cases(void) {
    // Nothing installed is the state before the client has given the function up, and
    // every one of these reads as "cannot say" rather than as an answer.
    g_get_valid_platforms = NULL;
    g_find_mapping = NULL;
    check(np_compat_valid_platforms(manager, 7) == 0, "no platforms function reports no platform");
    check(np_compat_would_force(manager, 7) == false, "no platforms function forces nothing");
    check(np_compat_app_mapping(manager, 7) == NULL, "no mapping function reports no mapping");

    np_compat_set_valid_platforms_fn((uintptr_t)stub_platforms);
    stub_platforms_value = COMPAT_PLATFORM_WINDOWS;
    check(np_compat_would_force(manager, 7), "a windows-only app takes the default");

    stub_platforms_value = COMPAT_PLATFORM_WINDOWS | COMPAT_PLATFORM_MACOS;
    check(!np_compat_would_force(manager, 7), "an app with a macOS build is left alone");

    stub_platforms_value = COMPAT_PLATFORM_MACOS;
    check(!np_compat_would_force(manager, 7), "a macOS-only app is left alone");

    stub_platforms_value = COMPAT_PLATFORM_WINDOWS;
    check(!np_compat_would_force(manager, 0), "appid zero is not an app to force");
    check(np_compat_valid_platforms(NULL, 7) == 0, "no manager reports no platform");

    np_compat_set_app_mapping_fn((uintptr_t)stub_find_mapping);
    stub_mapping_entry[0] = "notproton";
    check(np_compat_app_mapping(manager, 7) != NULL, "a mapped app reports its entry");
    check(strcmp(np_compat_app_mapping(manager, 7), "notproton") == 0,
          "the name in the entry is what comes back");
    check(np_compat_app_mapping(manager, 0) == NULL,
          "appid zero is refused rather than reaching the global entry");

    // An entry naming nothing is how the client holds an app that was taken off tools.
    stub_mapping_entry[0] = "";
    check(np_compat_app_mapping(manager, 7) == NULL, "an empty name reports no mapping");
    stub_mapping_entry[0] = NULL;
    check(np_compat_app_mapping(manager, 7) == NULL, "an entry naming nothing reports no mapping");

    np_compat_set_mapping_fn((uintptr_t)stub_set_mapping);
    last_priority = 0;
    np_compat_map_tool(manager, 7, "notproton");
    check(last_appid == 7 && last_priority == COMPAT_MAPPING_PRIORITY_APP,
          "an app mapping outranks the global one");

    last_priority = 0;
    np_compat_map_tool(manager, 0, "notproton");
    check(last_appid == 0 && last_priority == COMPAT_MAPPING_PRIORITY_GLOBAL,
          "the global mapping stays under the threshold that skips the platform check");

    last_priority = 0;
    np_compat_map_tool(manager, 7, NULL);
    check(last_priority == 0, "mapping an app to no tool at all reaches the client as nothing");
}

static const uint32_t SET_SHORTCUT_EXE[] = {
    0xD10103FF, 0xA90157F6, 0xA9024FF4, 0xA9037BFD, 0x9100C3FD, 0xAA0303F3, 0xB940380A,
    0x3100055F, 0x54000200, 0xAA0003F4, 0xF9402808, 0x91001109, 0x93407D4A, 0x8B0A150B,
    0xB940116D, 0xAA0803EC, 0x6B0101BF, 0x54000068, 0xAA0903EC, 0x54000222, 0xD37BE94A,
    0xB86A698A, 0x3100055F, 0x54FFFEA1, 0xB40000D3, 0xF90003E1, 0x900056E1, 0x912B9021,
    0xAA1303E0, 0x94167236, 0x52800000, 0xA9437BFD, 0xA9424FF4, 0xA94157F6, 0x910103FF,
    0xD65F03C0, 0xF9400D75, 0x910042A0, 0xAA0203E1, 0x9416718C, 0xAA1503E0, 0xAA1303E1,
    0x9400000B, 0xB40000B3, 0xF9400268, 0xB4000068, 0x39400108, 0x35FFFDE8, 0xAA1403E0,
    0xAA1503E1, 0x97FFFDB6, 0x52800020, 0x17FFFFEB,
};
#define SET_EXE_NOTIFY_BL 50

static const uint32_t SHORTCUT_NOTIFY[] = {
    0xD100C3FF, 0xA9014FF4, 0xA9027BFD, 0x910083FD, 0xAA0003F3, 0xB9400028, 0xB9000BE8,
    0xF9403428, 0xF100011F, 0x1A9F07E8, 0x390033E8, 0xF9400414,
};

static const uint32_t GET_WILDCARD_MAPPING[] = {
    0xD10143FF, 0xA90257F6, 0xA9034FF4, 0xA9047BFD, 0x910103FD, 0x34000541, 0xAA0103F4,
    0xAA0003F5, 0xB90017FF, 0x910FE000, 0x910053E1, 0x97FFFF0B, 0xAA0003F3, 0xB4000180,
    0xF9400268, 0xB9401108, 0x7103E91F, 0x5400010B, 0xF90003F4, 0xF0008E20, 0x912A6000,
    0x900077E1, 0x91024C21, 0x97E8D865, 0x14000023, 0xB9001FF4, 0x39006FFF, 0x911A62A0,
    0x910073E1, 0x91006FE2, 0x97FF0A8C, 0x340003C0,
};
#define WILDCARD_LOOKUP_BL 30

#define NOTIFY_AT 64

static uintptr_t bl_dest(const uint32_t *at) {
    uintptr_t target = 0;
    a64_bl((uintptr_t)at, *at, &target);
    return target;
}

static void shortcut_probe_cases(void) {
    static uint32_t code[NOTIFY_AT + 16];
    memcpy(code, SET_SHORTCUT_EXE, sizeof(SET_SHORTCUT_EXE));
    memcpy(code + NOTIFY_AT, SHORTCUT_NOTIFY, sizeof(SHORTCUT_NOTIFY));
    code[SET_EXE_NOTIFY_BL] = 0x94000000u | (uint32_t)(NOTIFY_AT - SET_EXE_NOTIFY_BL);

    check(probe_layout((uintptr_t)code, (uintptr_t)code, sizeof(code)) == 1,
          "SetShortcutExe gives up the table layout");
    check(g_layout.root == 0x38 && g_layout.nodes == 0x50 && g_layout.stride == 32,
          "the tree root, node array and stride come from the walk");
    check(g_layout.key == 0x10 && g_layout.value == 0x18,
          "a node keys on the appid and points at the shortcut");
    check(g_layout.exe == 0x10 && g_layout.remote == 0x68,
          "the exe string and the remote id come from the setter and its notify");

    layout_t kept = g_layout;
    code[SET_EXE_NOTIFY_BL] = 0xD503201Fu;
    check(probe_layout((uintptr_t)code, (uintptr_t)code, sizeof(code)) == 0,
          "a setter that never notifies is refused");
    check(memcmp(&g_layout, &kept, sizeof(kept)) == 0, "a refused walk keeps the last layout");
    check(probe_layout(0, 0, 0) == 0, "an unresolved setter is refused");
    code[SET_EXE_NOTIFY_BL] = 0x94000000u | (uint32_t)(NOTIFY_AT - SET_EXE_NOTIFY_BL);
    check(probe_layout((uintptr_t)code, (uintptr_t)code, NOTIFY_AT * 4) == 0,
          "a notify outside the text section is refused");

    const uint32_t *call = &GET_WILDCARD_MAPPING[WILDCARD_LOOKUP_BL];
    check(np_compat_probe_windows_only_off((uintptr_t)GET_WILDCARD_MAPPING,
                                           bl_dest(call)) == 1,
          "the lookup call in GetWildcardMapping gives up its table");
    check(g_windows_only_off == 0x698, "the table is the call's first argument");

    g_windows_only_off = 0;
    check(np_compat_probe_windows_only_off((uintptr_t)GET_WILDCARD_MAPPING,
                                           bl_dest(call) + 4) == 0,
          "a lookup GetWildcardMapping never calls is refused");
    check(g_windows_only_off == 0, "a refused probe leaves no table");
}

#define TEST_USER_SIZE       0x10000
#define TEST_SHORTCUTS_OFF   0x5CC8
#define TEST_GATE_OFF        0x698
#define TEST_MANAGER_SIZE    0x800

typedef struct {
    uint8_t *mgr;
    uint8_t *user;
    uint8_t  nodes[3][32];
    uint8_t *shortcut[3];
} shortcut_world_t;

static const uint32_t world_appid[3] = { 0x80000002u, 0x80000001u, 0x80000003u };

static void put_node(shortcut_world_t *w, int i, int32_t left, int32_t right) {
    memcpy(w->nodes[i] + NODE_LEFT_OFF, &left, sizeof(left));
    memcpy(w->nodes[i] + NODE_RIGHT_OFF, &right, sizeof(right));
    memcpy(w->nodes[i] + 0x10, &world_appid[i], sizeof(uint32_t));
    memcpy(w->nodes[i] + 0x18, &w->shortcut[i], sizeof(uint8_t *));
}

static void set_exe(shortcut_world_t *w, int i, const char *exe) {
    memcpy(w->shortcut[i] + 0x10, &exe, sizeof(exe));
}

static void build_world(shortcut_world_t *w) {
    w->mgr  = calloc(1, TEST_MANAGER_SIZE);
    w->user = calloc(1, TEST_USER_SIZE);
    memcpy(w->mgr + COMPAT_MANAGER_USER_OFF, &w->user, sizeof(w->user));

    uint8_t *shortcuts = w->user + TEST_SHORTCUTS_OFF;
    memcpy(shortcuts, &g_vptr, sizeof(g_vptr));
    int32_t root = 0;
    memcpy(shortcuts + 0x38, &root, sizeof(root));
    uint8_t *nodes = &w->nodes[0][0];
    memcpy(shortcuts + 0x50, &nodes, sizeof(nodes));

    for (int i = 0; i < 3; i++) w->shortcut[i] = calloc(1, 0x80);
    put_node(w, 0, 1, 2);
    put_node(w, 1, NODE_NONE, NODE_NONE);
    put_node(w, 2, NODE_NONE, NODE_NONE);
}

static void free_world(shortcut_world_t *w) {
    for (int i = 0; i < 3; i++) free(w->shortcut[i]);
    free(w->user);
    free(w->mgr);
}

static void shortcut_exe_cases(void) {
    static const char vptr_target = 0;
    g_vptr = (uintptr_t)&vptr_target;
    atomic_store(&g_shortcuts_off, 0);
    atomic_store(&g_scan_missed, 0);

    shortcut_world_t w = {0};
    build_world(&w);

    set_exe(&w, 0, "\"C:\\Games\\Game.EXE\"");
    set_exe(&w, 1, "/Applications/Game/run.exe");
    set_exe(&w, 2, "\"/Applications/Game.app\"");

    check(np_usershortcuts_runs_exe(w.user, world_appid[0]), "a quoted browsed exe takes the default");
    check(atomic_load(&g_shortcuts_off) == TEST_SHORTCUTS_OFF,
          "the table is found inside CUser by its vptr");
    check(np_usershortcuts_runs_exe(w.user, world_appid[1]), "a typed unquoted exe takes the default");
    check(!np_usershortcuts_runs_exe(w.user, world_appid[2]), "a Mac app is left alone");
    check(!np_usershortcuts_runs_exe(w.user, 0x80000004u), "an appid with no shortcut is left alone");
    check(!np_usershortcuts_runs_exe(w.user, 0x00000002u), "a Steam appid is never a shortcut");
    check(!np_usershortcuts_runs_exe(NULL, world_appid[0]), "no user answers no");

    set_exe(&w, 2, "C:\\Games\\setup.Exe");
    check(np_usershortcuts_runs_exe(w.user, world_appid[2]), "the extension matches in any case");
    set_exe(&w, 2, "C:\\Games\\launch.exe.bat");
    check(!np_usershortcuts_runs_exe(w.user, world_appid[2]), "only the last extension counts");
    set_exe(&w, 2, "C:\\Games.exe\\launcher");
    check(!np_usershortcuts_runs_exe(w.user, world_appid[2]), "a dot in a folder name is no extension");
    set_exe(&w, 2, "");
    check(!np_usershortcuts_runs_exe(w.user, world_appid[2]), "an empty exe is left alone");
    set_exe(&w, 2, NULL);
    check(!np_usershortcuts_runs_exe(w.user, world_appid[2]), "a shortcut with no exe is left alone");
    set_exe(&w, 2, (const char *)(uintptr_t)0x10);
    check(!np_usershortcuts_runs_exe(w.user, world_appid[2]), "an exe pointer below 4 GB is not read");
    set_exe(&w, 2, &"C:\\Games\\setup.exe"[1]);
    check(np_usershortcuts_runs_exe(w.user, world_appid[2]), "an unaligned exe string is still read");

    put_node(&w, 2, NODE_NONE, 0);
    check(!np_usershortcuts_runs_exe(w.user, 0x80000004u), "a looping tree stops at the depth cap");
    put_node(&w, 2, NODE_NONE, -2);
    check(!np_usershortcuts_runs_exe(w.user, 0x80000004u), "a corrupt node index stops the walk");
    put_node(&w, 2, NODE_NONE, NODE_NONE);

    uint64_t remote = 0x1234;
    memcpy(w.shortcut[1] + 0x68, &remote, sizeof(remote));
    check(!np_usershortcuts_runs_exe(w.user, world_appid[1]), "a remote client's shortcut is left alone");
    remote = 0;
    memcpy(w.shortcut[1] + 0x68, &remote, sizeof(remote));

    check(np_compat_user(w.mgr) == w.user, "the manager hands over its CUser");
    g_windows_only_off = TEST_GATE_OFF;
    check(np_compat_is_windows_only_table(w.mgr, w.mgr + TEST_GATE_OFF),
          "the probed table is the windows-only one");
    check(!np_compat_is_windows_only_table(w.mgr, w.mgr + TEST_GATE_OFF - 0x60),
          "any other table is not");
    check(!np_compat_is_windows_only_table(NULL, w.mgr + TEST_GATE_OFF),
          "no manager has no table");
    g_windows_only_off = 0;
    check(!np_compat_is_windows_only_table(w.mgr, w.mgr),
          "without a probed table nothing matches");

    memset(w.user + TEST_SHORTCUTS_OFF, 0, sizeof(uintptr_t));
    atomic_store(&g_shortcuts_off, 0);
    check(!np_usershortcuts_runs_exe(w.user, world_appid[0]), "a CUser with no table answers no");
    check(atomic_load(&g_scan_missed) == (uintptr_t)w.user, "the failed search is remembered");

    uint8_t *other = calloc(1, TEST_USER_SIZE);
    memcpy(other + TEST_SHORTCUTS_OFF, w.user + TEST_SHORTCUTS_OFF, 0x60);
    memcpy(other + TEST_SHORTCUTS_OFF, &g_vptr, sizeof(g_vptr));
    check(np_usershortcuts_runs_exe(other, world_appid[0]), "a new CUser is searched again");

    int32_t empty = NODE_NONE;
    memcpy(other + TEST_SHORTCUTS_OFF + 0x38, &empty, sizeof(empty));
    check(!np_usershortcuts_runs_exe(other, world_appid[0]), "an empty tree has no shortcuts");
    free(other);

    free_world(&w);
}

int main(void) {
    concurrent_fallback_cases();
    probe_cases();
    oslist_cases();
    enabled_cases();
    manager_cases();
    tool_list_cases();
    tool_launch_cases();
    stale_tool_cases();
    installed_fn_cases();
    shortcut_probe_cases();
    shortcut_exe_cases();

    if (failures) {
        printf("==> compat: %d check(s) failed\n", failures);
        return 1;
    }
    printf("==> compat: layout probes hold, the tool array walk is bounded, "
           "installed functions answer\n");
    return 0;
}
