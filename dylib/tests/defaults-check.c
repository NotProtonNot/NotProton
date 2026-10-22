#include "../feats/defaults.c"

#include <stdio.h>
#include <string.h>
#include <sys/stat.h>

int np_log_level = 0;
FILE *np_log_file = NULL;

static int failures;

static void check(int ok, const char *what) {
    printf("  %s  %s\n", ok ? "ok  " : "FAIL", what);
    if (!ok) failures++;
}

static int valid(uint32_t runner, const char *line) {
    const char *eq = strchr(line, '=');
    int i = setting_index(runner, line, (size_t)(eq - line));
    return i >= 0 && valid_value((size_t)i, runner, eq + 1, strlen(eq + 1));
}

static char g_dir[PATH_MAX];

static char *file_text(const char *name) {
    static char text[NP_DEFAULTS_TEXT_MAX + 2];
    char path[PATH_MAX];
    snprintf(path, sizeof path, "%s/%s", g_dir, name);
    FILE *f = fopen(path, "r");
    if (!f) return NULL;
    size_t n = fread(text, 1, sizeof text - 1, f);
    text[n] = '\0';
    fclose(f);
    return text;
}

static void put_file(const char *name, const char *text) {
    char path[PATH_MAX];
    snprintf(path, sizeof path, "%s/%s", g_dir, name);
    FILE *f = fopen(path, "w");
    fputs(text, f);
    fclose(f);
}

static void drop_file(const char *name) {
    char path[PATH_MAX];
    snprintf(path, sizeof path, "%s/%s", g_dir, name);
    remove(path);
}

static void chmod_file(const char *name, mode_t mode) {
    char path[PATH_MAX];
    snprintf(path, sizeof path, "%s/%s", g_dir, name);
    chmod(path, mode);
}
static void lock_file(const char *name) { chmod_file(name, 0); }
static void unlock_file(const char *name) { chmod_file(name, 0644); }

static void put_big(const char *name) {
    static char big[NP_DEFAULTS_TEXT_MAX + 64];
    big[0] = '\0';
    while (strlen(big) + 12 < sizeof big) strcat(big, "WINEMSYNC=1\n");
    put_file(name, big);
}

static int exists(const char *name) {
    char path[PATH_MAX];
    struct stat st;
    snprintf(path, sizeof path, "%s/%s", g_dir, name);
    return stat(path, &st) == 0;
}

static void valid_cases(void) {
    check(valid(NP_DEFAULTS_ROSETTA, "MTL_HUD_ENABLED=1") && valid(NP_DEFAULTS_FEX, "MTL_HUD_ENABLED=0"),
          "both runners take a shared row");
    check(valid(NP_DEFAULTS_ROSETTA, "CX_GRAPHICS_BACKEND=d3dmetal") &&
          !valid(NP_DEFAULTS_FEX, "CX_GRAPHICS_BACKEND=d3dmetal"),
          "only Rosetta takes D3DMetal");
    check(valid(NP_DEFAULTS_FEX, "CX_GRAPHICS_BACKEND=dxvk") &&
          !valid(NP_DEFAULTS_ROSETTA, "CX_GRAPHICS_BACKEND=auto") &&
          !valid(NP_DEFAULTS_ROSETTA, "CX_GRAPHICS_BACKEND=vulkan"),
          "Automatic and unknown backends are not saved");
    check(!valid(NP_DEFAULTS_FEX, "ROSETTA_ADVERTISE_AVX=1") &&
          !valid(NP_DEFAULTS_FEX, "D3DM_ENABLE_METALFX=1") &&
          !valid(NP_DEFAULTS_ROSETTA, "FEX_X87REDUCEDPRECISION=1") &&
          valid(NP_DEFAULTS_FEX, "FEX_X87REDUCEDPRECISION=0"),
          "runner-only rows stay with their runner");
    check(!valid(NP_DEFAULTS_ROSETTA, "WINEMSYNC=") && !valid(NP_DEFAULTS_ROSETTA, "WINEMSYNC=2") &&
          !valid(NP_DEFAULTS_ROSETTA, "WINEMSYNC=10"),
          "a row takes only 0 or 1");
    check(valid(NP_DEFAULTS_ROSETTA, "DXMT_CONFIG=d3d11.metalSpatialUpscaleFactor=1.72"),
          "DXMT_CONFIG takes a factor");
    check(!valid(NP_DEFAULTS_ROSETTA, "DXMT_CONFIG=d3d11.metalSpatialUpscaleFactor=") &&
          !valid(NP_DEFAULTS_ROSETTA, "DXMT_CONFIG=d3d11.metalSpatialUpscaleFactor=.") &&
          !valid(NP_DEFAULTS_ROSETTA, "DXMT_CONFIG=d3d11.metalSpatialUpscaleFactor=1;x=1") &&
          !valid(NP_DEFAULTS_ROSETTA, "DXMT_CONFIG=d3d11.metalSpatialUpscaleFactor=1234567") &&
          !valid(NP_DEFAULTS_ROSETTA, "DXMT_CONFIG=d3d11.preferredMaxFrameRate=60"),
          "DXMT_CONFIG takes nothing else");
    check(!valid(NP_DEFAULTS_ROSETTA, "WINEDEBUG=+all") && !valid(2, "WINEMSYNC=1"),
          "other keys and runners are refused");
    check(!valid(NP_DEFAULTS_ROSETTA, "DXMT_CONFIG=d3d11.metalSpatialUpscaleFactor=0") &&
          !valid(NP_DEFAULTS_ROSETTA, "DXMT_CONFIG=d3d11.metalSpatialUpscaleFactor=1.2.3") &&
          !valid(NP_DEFAULTS_ROSETTA, "DXMT_CONFIG=d3d11.metalSpatialUpscaleFactor=2") &&
          valid(NP_DEFAULTS_FEX, "DXMT_CONFIG=d3d11.metalSpatialUpscaleFactor=3.0"),
          "only the factors the page offers are taken");
}

static void build_cases(void) {
    check(np_defaults_save_build("26.1.0", NP_DEFAULTS_FEX, "WINEMSYNC=1\nFEX_X87REDUCEDPRECISION=0"),
          "a build saves its own set");
    const char *t = file_text("defaults-override-26.1.0-fex");
    check(t && strcmp(t, "WINEMSYNC=1\nFEX_X87REDUCEDPRECISION=0\n") == 0,
          "the build's file holds its lines");
    check(!exists("defaults-override-26.1.0-rosetta"), "the other runner's file is left alone");

    check(!np_defaults_save_build("26.1.0", NP_DEFAULTS_FEX, "ROSETTA_ADVERTISE_AVX=1"),
          "a build takes only its runner's settings");
    t = file_text("defaults-override-26.1.0-fex");
    check(t && strcmp(t, "WINEMSYNC=1\nFEX_X87REDUCEDPRECISION=0\n") == 0,
          "a refused build save keeps the old file");

    check(np_defaults_save_build("25.0", NP_DEFAULTS_ROSETTA, ""), "a build saves an empty set");
    check(exists("defaults-override-25.0-rosetta"), "an empty set still leaves its file");

    const char *bad[] = { "", "../defaults-rosetta", "a/b", "a b", "26_1", "x\ny",
        "0123456789012345678901234567890123456789012345678901234567890123" };
    int refused = 1;
    for (size_t i = 0; i < sizeof bad / sizeof bad[0]; i++)
        refused &= !np_defaults_save_build(bad[i], NP_DEFAULTS_ROSETTA, "WINEMSYNC=1");
    check(refused && !np_defaults_save_build(NULL, NP_DEFAULTS_ROSETTA, ""),
          "anything but a build ID is refused");
    check(!np_defaults_save_build("26.1.0", 7, "WINEMSYNC=1"), "a build save needs a runner");

    drop_file("defaults-override-26.1.0-fex");
}

static void planted_cases(void) {
    char victim[PATH_MAX], link_path[PATH_MAX];
    snprintf(victim, sizeof victim, "%s/victim", g_dir);
    snprintf(link_path, sizeof link_path, "%s/defaults-rosetta.new", g_dir);
    put_file("victim", "keep");
    symlink(victim, link_path);
    check(np_defaults_save(NP_DEFAULTS_ROSETTA, "WINEMSYNC=1"), "a leftover .new does not stop a save");
    const char *t = file_text("victim");
    check(t && strcmp(t, "keep") == 0, "a planted .new link is not followed");
    drop_file("victim");
}

static void save_cases(void) {
    check(np_defaults_save(NP_DEFAULTS_ROSETTA, "WINEMSYNC=1\n\nCX_GRAPHICS_BACKEND=dxmt"),
          "a valid set saves");
    const char *t = file_text("defaults-rosetta");
    check(t && strcmp(t, "WINEMSYNC=1\nCX_GRAPHICS_BACKEND=dxmt\n") == 0,
          "the file holds one line per setting");
    check(!exists("defaults-rosetta.new"), "nothing is left behind");

    check(!np_defaults_save(NP_DEFAULTS_ROSETTA, "WINEMSYNC=1\nFEX_X87REDUCEDPRECISION=0"),
          "a line the runner does not take refuses the save");
    check(!np_defaults_save(NP_DEFAULTS_ROSETTA, "WINEMSYNC=1\nWINEMSYNC=0"),
          "a key set twice refuses the save");
    t = file_text("defaults-rosetta");
    check(t && strcmp(t, "WINEMSYNC=1\nCX_GRAPHICS_BACKEND=dxmt\n") == 0,
          "a refused save keeps the old file");

    char big[NP_DEFAULTS_TEXT_MAX + 16];
    memset(big, '\n', sizeof big - 1);
    big[sizeof big - 1] = '\0';
    check(!np_defaults_save(NP_DEFAULTS_FEX, big), "an oversized request is refused");
    check(!np_defaults_save(7, "WINEMSYNC=1"), "an unknown runner is refused");
    check(!np_defaults_save(NP_DEFAULTS_ROSETTA, NULL), "no text is refused");

    check(np_defaults_save(NP_DEFAULTS_ROSETTA, ""), "an empty set saves");
    t = file_text("defaults-rosetta");
    check(t && t[0] == '\0', "an empty set leaves an empty file");
}

static void read_cases(void) {
    char text[NP_DEFAULTS_TEXT_MAX + 1];
    drop_file("defaults-rosetta");
    np_defaults_read(NP_DEFAULTS_ROSETTA, text, sizeof text);
    check(text[0] == '\0', "no file reads as no defaults");

    put_file("defaults-fex", "WINEMSYNC=1\nROSETTA_ADVERTISE_AVX=0\nFOO=\"});alert(1);({\nWINEMSYNC=0");
    np_defaults_read(NP_DEFAULTS_FEX, text, sizeof text);
    check(strcmp(text, "WINEMSYNC=1\n") == 0, "only the lines that would save are read");

    char small[8];
    check(!np_defaults_read(NP_DEFAULTS_FEX, small, sizeof small) && small[0] == '\0',
          "lines that do not fit are a failed read");
    check(!np_defaults_read(7, text, sizeof text) && text[0] == '\0', "an unknown runner is a failed read");
    check(np_defaults_read(NP_DEFAULTS_ROSETTA, text, sizeof text), "a missing file is a read");
    put_file("defaults-rosetta", "");
    check(np_defaults_read(NP_DEFAULTS_ROSETTA, text, sizeof text) && text[0] == '\0',
          "an empty file is a read with nothing in it");

    lock_file("defaults-fex");
    check(!np_defaults_read(NP_DEFAULTS_FEX, text, sizeof text) && text[0] == '\0',
          "a file that cannot be opened is a failed read, not an empty one");
    unlock_file("defaults-fex");
    put_big("defaults-fex");
    check(!np_defaults_read(NP_DEFAULTS_FEX, text, sizeof text), "an oversized file is a failed read");
    drop_file("defaults-rosetta");

    check(np_defaults_read_build("27.0", NP_DEFAULTS_ROSETTA, text, sizeof text) == 0 && text[0] == '\0',
          "a build without a file has no own set");
    put_file("defaults-override-27.0-rosetta", "");
    check(np_defaults_read_build("27.0", NP_DEFAULTS_ROSETTA, text, sizeof text) == 1 && text[0] == '\0',
          "an empty file is an own set with nothing in it");
    put_file("defaults-override-27.0-rosetta", "MTL_HUD_ENABLED=1\nFEX_X87REDUCEDPRECISION=1\n");
    check(np_defaults_read_build("27.0", NP_DEFAULTS_ROSETTA, text, sizeof text) == 1 &&
          strcmp(text, "MTL_HUD_ENABLED=1\n") == 0, "a build's own set reads its valid lines");
    lock_file("defaults-override-27.0-rosetta");
    check(np_defaults_read_build("27.0", NP_DEFAULTS_ROSETTA, text, sizeof text) == -1 && text[0] == '\0',
          "a build's own set that cannot be opened is a failed read");
    unlock_file("defaults-override-27.0-rosetta");
    drop_file("defaults-override-27.0-rosetta");

    char dir[PATH_MAX];
    snprintf(dir, sizeof dir, "%s/defaults-override-30.0-rosetta", g_dir);
    mkdir(dir, 0755);
    check(np_defaults_read_build("30.0", NP_DEFAULTS_ROSETTA, text, sizeof text) == 0,
          "a folder is not a build's own set, as in compat_run.sh");
    rmdir(dir);
    check(np_defaults_read_build("../defaults-fex", NP_DEFAULTS_FEX, text, sizeof text) == -1,
          "reading takes only a build ID");
    drop_file("defaults-fex");
}

static void apply_cases(void) {
    put_file("defaults-rosetta", "WINEMSYNC=0\n");
    put_file("defaults-override-26.1-rosetta", "MTL_HUD_ENABLED=1\nNOTPROTON_RETINA=1\n");
    put_file("defaults-override-25.0-rosetta", "");
    put_file("defaults-override-old-rosetta", "WINEMSYNC=1\n");
    put_file("defaults-override-26.1-fex", "WINEMSYNC=1\n");
    check(np_defaults_apply_build("26.1", NP_DEFAULTS_ROSETTA), "a build's set applies");
    const char *t = file_text("defaults-rosetta");
    check(t && strcmp(t, "MTL_HUD_ENABLED=1\nNOTPROTON_RETINA=1\n") == 0,
          "the runner's file takes the build's set");
    check(!exists("defaults-override-26.1-rosetta") && !exists("defaults-override-25.0-rosetta") &&
          !exists("defaults-override-old-rosetta"),
          "every build's own set for the runner is gone, installed or not");
    check(exists("defaults-override-26.1-fex"), "the other runner's builds keep theirs");

    put_file("defaults-override-24.0-rosetta", "WINEMSYNC=1\n");
    check(np_defaults_apply_build("26.1", NP_DEFAULTS_ROSETTA), "a build without its own set applies");
    t = file_text("defaults-rosetta");
    check(t && strcmp(t, "MTL_HUD_ENABLED=1\nNOTPROTON_RETINA=1\n") == 0,
          "applying a build without its own set keeps the runner's");
    check(!exists("defaults-override-24.0-rosetta"), "and still drops the others");

    put_file("defaults-override-24.0-fex", "WINEMSYNC=0\n");
    drop_file("defaults-fex");
    char dir[PATH_MAX];
    snprintf(dir, sizeof dir, "%s/defaults-fex", g_dir);
    mkdir(dir, 0755);
    check(!np_defaults_apply_build("26.1", NP_DEFAULTS_FEX), "a failed save refuses the apply");
    check(exists("defaults-override-26.1-fex") && exists("defaults-override-24.0-fex"),
          "a failed save removes no build's own set");
    rmdir(dir);
    drop_file("defaults-override-26.1-fex");
    drop_file("defaults-override-24.0-fex");

    put_file("defaults-rosetta", "WINEMSYNC=1\n");
    put_file("defaults-override-26.1-rosetta", "MTL_HUD_ENABLED=1\n");
    put_file("defaults-override-25.0-rosetta", "WINEMSYNC=0\n");
    lock_file("defaults-override-26.1-rosetta");
    check(!np_defaults_apply_build("26.1", NP_DEFAULTS_ROSETTA), "a set that cannot be read is not applied");
    unlock_file("defaults-override-26.1-rosetta");
    t = file_text("defaults-rosetta");
    check(t && strcmp(t, "WINEMSYNC=1\n") == 0 && exists("defaults-override-26.1-rosetta") &&
          exists("defaults-override-25.0-rosetta"), "a failed read keeps every file as it was");
    drop_file("defaults-override-26.1-rosetta");
    lock_file("defaults-rosetta");
    check(!np_defaults_apply_build("26.1", NP_DEFAULTS_ROSETTA) && exists("defaults-override-25.0-rosetta"),
          "a runner's set that cannot be read is not applied either");
    unlock_file("defaults-rosetta");
    put_big("defaults-rosetta");
    check(!np_defaults_apply_build("26.1", NP_DEFAULTS_ROSETTA) && exists("defaults-override-25.0-rosetta"),
          "an oversized set is not applied");
    drop_file("defaults-override-25.0-rosetta");
    drop_file("defaults-rosetta");

    put_file("defaults-override-26.1-rosetta", "NOTPROTON_RETINA=1\n");
    put_file("defaults-override-24.0-rosetta", "WINEMSYNC=1\n");
    put_file("defaults-override-23.0-rosetta", "WINEMSYNC=0\n");
    char stuck[PATH_MAX], folder[PATH_MAX];
    snprintf(stuck, sizeof stuck, "%s/defaults-override-24.0-rosetta", g_dir);
    snprintf(folder, sizeof folder, "%s/defaults-override-31.0-rosetta", g_dir);
    mkdir(folder, 0755);
    chflags(stuck, UF_IMMUTABLE);
    check(np_defaults_apply_build("26.1", NP_DEFAULTS_ROSETTA) == -1,
          "an own set that cannot be removed makes the apply partial");
    chflags(stuck, 0);
    t = file_text("defaults-rosetta");
    check(t && strcmp(t, "NOTPROTON_RETINA=1\n") == 0 && !exists("defaults-override-23.0-rosetta") &&
          exists("defaults-override-24.0-rosetta"), "a partial apply saved the set and dropped what it could");
    drop_file("defaults-override-24.0-rosetta");
    check(np_defaults_apply_build("26.1", NP_DEFAULTS_ROSETTA) == 1 && exists("defaults-override-31.0-rosetta"),
          "a folder is not an own set, so it does not stop the apply");
    rmdir(folder);
    drop_file("defaults-rosetta");

    check(!np_defaults_apply_build("../x", NP_DEFAULTS_ROSETTA) && !np_defaults_apply_build("26.1", 7),
          "applying takes a build ID and a runner");
}

static void print_settings(void) {
    for (size_t i = 0; i < SETTING_COUNT; i++) {
        printf("key %s%s%s\n", g_settings[i].key, g_settings[i].runners & ROSETTA ? " rosetta" : "",
               g_settings[i].runners & FEX ? " fex" : "");
        printf("values %s", g_settings[i].key);
        for (const char *const *v = g_settings[i].values; *v; v++) printf(" %s", *v);
        printf("\nrosetta-values %s", g_settings[i].key);
        for (const char *const *v = g_settings[i].rosetta_values; v && *v; v++) printf(" %s", *v);
        printf("\n");
    }
}

int main(int argc, char **argv) {
    if (argc == 2 && strcmp(argv[1], "--settings") == 0) {
        print_settings();
        return 0;
    }
    const char *tmp = getenv("TMPDIR");
    char tmpl[PATH_MAX];
    snprintf(tmpl, sizeof tmpl, "%s/np-defaults-XXXXXX", tmp && tmp[0] ? tmp : "/tmp");
    const char *home = mkdtemp(tmpl);
    if (!home) { perror("mkdtemp"); return 1; }
    setenv("HOME", home, 1);
    np_support_path(g_dir, sizeof g_dir, home, NULL);
    char lib[PATH_MAX];
    snprintf(lib, sizeof lib, "%s/Library", home);
    mkdir(lib, 0755);
    strcat(lib, "/Application Support");
    mkdir(lib, 0755);
    mkdir(g_dir, 0755);

    valid_cases();
    save_cases();
    read_cases();
    build_cases();
    planted_cases();
    apply_cases();

    char cmd[PATH_MAX + 16];
    snprintf(cmd, sizeof cmd, "rm -rf '%s'", home);
    system(cmd);

    if (failures) {
        printf("==> defaults: %d failed\n", failures);
        return 1;
    }
    printf("==> defaults: the runners take their own settings, saves are whole, Apply keeps every set until it saved\n");
    return 0;
}
