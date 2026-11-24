// Tests for pluginlaunch.c.
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

#define LAUNCHER 3000000001u
#define GAME     3000000002u

static char launcher_exe[PATH_MAX], game_exe[PATH_MAX];

static const char *tool_dir = "/t/notproton-fex-1";
const char *np_compat_app_tool_dir(uint32_t appid) { (void)appid; return tool_dir; }
void *np_compat_manager(void) { return NULL; }
void *np_compat_user(const void *compat_mgr) { (void)compat_mgr; return NULL; }
const char *np_usershortcuts_exe(const void *user, uint32_t appid) {
    (void)user;
    return appid == LAUNCHER ? launcher_exe : appid == GAME ? game_exe : NULL;
}

static void make_conf(void) {
    put_file("Library/Application Support/notproton/plugins/t.conf",
             "[NOTPROTON_T]\n"
             "label = T\n"
             "launch = Launcher = launcher.exe =\n"
             "launch = Game = games/g.exe = --game=g \"two words\"\n"
             "launch = Missing = games/none.exe = --game=none\n"
             "[NOTPROTON_ANY_GAME]\n"
             "label = Any game\n"
             "present = */g.exe\n"
             "[NOTPROTON_THIS_GAME]\n"
             "label = This game\n"
             "present = nothing.exe\n"
             "present = g.exe\n");
}

static void make_home(void) {
    snprintf(home, sizeof home, "%s", "/tmp/pluginlaunch-check.XXXXXX");
    if (!mkdtemp(home)) { perror("mkdtemp"); exit(2); }
    setenv("HOME", home, 1);
    snprintf(launcher_exe, sizeof launcher_exe, "\"%s/hub/launcher.exe\"", home);
    snprintf(game_exe, sizeof game_exe, "\"%s/hub/games/g.exe\"", home);

    put_file("hub/launcher.exe", "");
    put_file("hub/games/g.exe", "");
    make_conf();
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

    printf("== rows show where one of their files is ==\n");
    json = np_pluginlaunch_present_json(LAUNCHER);
    check(json && strcmp(json, "[\"NOTPROTON_ANY_GAME\"]") == 0, "a wildcard matches a game a folder down");
    free(json);
    json = np_pluginlaunch_present_json(GAME);
    check(json && strcmp(json, "[\"NOTPROTON_THIS_GAME\"]") == 0, "any one of a row's files is enough");
    free(json);
    json = np_pluginlaunch_present_json(220240);
    check(json && strcmp(json, "[]") == 0, "a Steam game has none");
    free(json);
    put_file("hub [x]/games/g.exe", "");
    snprintf(launcher_exe, sizeof launcher_exe, "\"%s/hub [x]/launcher.exe\"", home);
    json = np_pluginlaunch_present_json(LAUNCHER);
    check(json && strcmp(json, "[\"NOTPROTON_ANY_GAME\"]") == 0, "the shortcut's own folder is not a pattern");
    free(json);
    snprintf(launcher_exe, sizeof launcher_exe, "\"%s/hub/launcher.exe\"", home);

    printf("== a row's files gate its launch choices too ==\n");
    put_file("Library/Application Support/notproton/plugins/t.conf",
             "[NOTPROTON_T]\nlabel = T\npresent = elsewhere.exe\nlaunch = Launcher = launcher.exe =\n");
    json = np_pluginlaunch_json(LAUNCHER);
    check(json && strcmp(json, "[]") == 0, "none of them there, nothing offered");
    free(json);
    make_conf();

    printf("== a plugin that can't run offers nothing ==\n");
    tool_dir = NULL;
    json = np_pluginlaunch_json(LAUNCHER);
    check(json && strcmp(json, "[]") == 0, "a shortcut on another tool");
    free(json);
    tool_dir = "/t/notproton-fex-1";
    put_file("Library/Application Support/notproton/plugins/t.conf",
             "[NOTPROTON_T]\nlabel = T\ntools = notproton-26*\nlaunch = Launcher = launcher.exe =\n");
    json = np_pluginlaunch_json(LAUNCHER);
    check(json && strcmp(json, "[]") == 0, "a tool its patterns don't match");
    free(json);
    put_file("Library/Application Support/notproton/plugins/t.conf",
             "[NOTPROTON_T]\nlabel = T\ntools = notproton-fex*\nrequires = hub/gone.exe\n"
             "launch = Launcher = launcher.exe =\n");
    json = np_pluginlaunch_json(LAUNCHER);
    check(json && strcmp(json, "[]") == 0, "a required file that's missing");
    free(json);
    put_file("Library/Application Support/notproton/plugins/t.conf",
             "[NOTPROTON_T]\nlabel = T\ntools = notproton-fex*\nrequires = hub/gone.exe\n"
             "requires = ~/hub/launcher.exe\nlaunch = Launcher = launcher.exe =\n");
    json = np_pluginlaunch_json(LAUNCHER);
    check(json && strstr(json, "\"l\":\"Launcher\""), "with the tool and one required file there, it offers");
    free(json);
    make_conf();

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
