// Plugin launch choices and picks, against a made-up home with its own shortcuts.vdf.
#include "../feats/pluginlaunch.c"

#include <stdarg.h>
#include <unistd.h>

int   np_log_level = 0;
FILE *np_log_file  = NULL;

static int  failures;
static char home[PATH_MAX];

static void check(int cond, const char *what) {
    if (!cond) failures++;
    printf("  %s  %s\n", cond ? "ok  " : "FAIL", what);
}

static void put_file(const char *rel, const char *text) {
    char path[PATH_MAX], dir[PATH_MAX];
    snprintf(path, sizeof path, "%s/%s", home, rel);
    snprintf(dir, sizeof dir, "mkdir -p \"$(dirname '%s')\"", path);
    if (system(dir) != 0) { perror("mkdir"); exit(2); }
    FILE *f = fopen(path, "w");
    if (!f) { perror(path); exit(2); }
    fputs(text, f);
    fclose(f);
}

static size_t vdf_shortcut(uint8_t *p, int index, uint32_t appid, const char *exe) {
    size_t n = 0;
    n += (size_t)sprintf((char *)p + n, "%c%d", 0, index) + 1;
    p[n++] = 0x02;
    n += (size_t)sprintf((char *)p + n, "appid") + 1;
    memcpy(p + n, &appid, 4);
    n += 4;
    p[n++] = 0x01;
    n += (size_t)sprintf((char *)p + n, "AppName") + 1;
    n += (size_t)sprintf((char *)p + n, "Shortcut %d", index) + 1;
    p[n++] = 0x01;
    n += (size_t)sprintf((char *)p + n, "Exe") + 1;
    n += (size_t)sprintf((char *)p + n, "\"%s/%s\"", home, exe) + 1;
    p[n++] = 0x08;
    return n;
}

#define LAUNCHER 3000000001u
#define GAME     3000000002u

static void make_home(void) {
    snprintf(home, sizeof home, "%s", "/tmp/pluginlaunch-check.XXXXXX");
    if (!mkdtemp(home)) { perror("mkdtemp"); exit(2); }
    setenv("HOME", home, 1);

    uint8_t vdf[4096];
    size_t n = 0;
    n += (size_t)sprintf((char *)vdf, "%cshortcuts", 0) + 1;
    n += vdf_shortcut(vdf + n, 0, LAUNCHER, "hub/launcher.exe");
    n += vdf_shortcut(vdf + n, 1, GAME, "hub/games/g.exe");
    vdf[n++] = 0x08;
    vdf[n++] = 0x08;
    put_file("Library/Application Support/Steam/userdata/1/config/shortcuts.vdf", "");
    char path[PATH_MAX];
    snprintf(path, sizeof path, "%s/Library/Application Support/Steam/userdata/1/config/shortcuts.vdf", home);
    FILE *f = fopen(path, "wb");
    fwrite(vdf, 1, n, f);
    fclose(f);

    put_file("hub/launcher.exe", "");
    put_file("hub/games/g.exe", "");
    put_file("Library/Application Support/notproton/plugins/t.conf",
             "[NOTPROTON_T]\n"
             "label = T\n"
             "launch = Launcher = launcher.exe =\n"
             "launch = Game = games/g.exe = --game=g \"two words\"\n"
             "launch = Missing = games/none.exe = --game=none\n");
}

static char *cmd_for(const char *exe, const char *tail) {
    static char cmd[PATH_MAX * 2];
    snprintf(cmd, sizeof cmd, "A=1 '/t/.'/run waitforexitandrun \"%s/%s\"%s", home, exe, tail);
    return cmd;
}

static int took(const char *cmd, const char *want_tail) {
    char *got = np_pluginlaunch_take(cmd);
    char want[PATH_MAX * 2];
    if (!want_tail) {
        free(got);
        return got == NULL;
    }
    snprintf(want, sizeof want, "%s", want_tail);
    int ok = got && strcmp(got, want) == 0;
    if (!ok) printf("    want: %s\n    got:  %s\n", want, got ? got : "(nothing)");
    free(got);
    return ok;
}

int main(void) {
    make_home();

    printf("== a shortcut offers the choices whose files are next to its exe ==\n");
    char *json = np_pluginlaunch_json(LAUNCHER);
    check(json && strcmp(json, "[{\"k\":\"NOTPROTON_T\",\"on\":\"1\",\"l\":\"Launcher\",\"a\":\"\"},"
                               "{\"k\":\"NOTPROTON_T\",\"on\":\"1\",\"l\":\"Game\",\"a\":\"--game=g \\\"two words\\\"\"}]") == 0,
          "the launcher lists itself and the installed game, not the missing one");
    free(json);
    json = np_pluginlaunch_json(GAME);
    check(json && strcmp(json, "[]") == 0, "a shortcut with none of the files offers nothing");
    free(json);
    json = np_pluginlaunch_json(220240);
    check(json && strcmp(json, "[]") == 0, "a Steam game offers nothing");
    free(json);

    printf("== a pick must be one of the shortcut's choices ==\n");
    check(!np_pluginlaunch_pick(LAUNCHER, "--game=none"), "a choice whose file is missing is refused");
    check(!np_pluginlaunch_pick(LAUNCHER, "; rm -rf ~"), "arguments no plugin declared are refused");
    check(!np_pluginlaunch_pick(GAME, "--game=g \"two words\""), "another shortcut's choice is refused");
    check(!np_pluginlaunch_pick(220240, "--game=g \"two words\""), "a Steam game can't be picked for");
    check(np_pluginlaunch_pick(LAUNCHER, ""), "an empty pick is fine");
    check(took(cmd_for("hub/launcher.exe", ""), NULL), "and adds nothing");

    printf("== the pick reaches that shortcut's next launch, once ==\n");
    check(np_pluginlaunch_pick(LAUNCHER, "--game=g \"two words\""), "the game's choice is taken");
    check(took(cmd_for("hub/games/g.exe", ""), NULL), "another shortcut's launch is left alone");
    char want[PATH_MAX * 2];
    snprintf(want, sizeof want, "A=1 '/t/.'/run waitforexitandrun \"%s/hub/launcher.exe\""
             " --game=g \"two words\" | tee /tmp/log", home);
    check(took(cmd_for("hub/launcher.exe", " | tee /tmp/log"), want),
          "they land as written right after the exe, ahead of the rest of the line");
    check(took(cmd_for("hub/launcher.exe", ""), NULL), "the next launch is plain again");

    printf("== a pick that isn't used goes away ==\n");
    np_pluginlaunch_pick(LAUNCHER, "--game=g \"two words\"");
    np_pluginlaunch_pick(LAUNCHER, "");
    check(took(cmd_for("hub/launcher.exe", ""), NULL), "picking the plain choice forgets it");
    np_pluginlaunch_pick(LAUNCHER, "--game=g \"two words\"");
    np_pluginlaunch_pick(LAUNCHER, "--game=none");
    check(took(cmd_for("hub/launcher.exe", ""), NULL), "so does a refused pick");
    np_pluginlaunch_pick(LAUNCHER, "--game=g \"two words\"");
    g_pick_at -= PICK_TTL_SECONDS + 1;
    check(took(cmd_for("hub/launcher.exe", ""), NULL), "and one that's too old");

    char rm[PATH_MAX + 16];
    snprintf(rm, sizeof rm, "rm -rf '%s'", home);
    if (system(rm) != 0) fprintf(stderr, "could not remove %s\n", home);

    if (failures) {
        printf("\n%d assertion(s) failed\n", failures);
        return 1;
    }
    printf("\n==> pluginlaunch-check: all assertions hold\n");
    return 0;
}
