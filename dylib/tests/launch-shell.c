#include "../hooks/hook_launch.c"

#include <stdio.h>

int   np_log_level = 0;
FILE *np_log_file  = NULL;

static int rebind_rc = -1;

int np_rebind_import(const struct mach_header_64 *mh, intptr_t slide,
                     const char *symbol, void *replacement) {
    (void)mh; (void)slide; (void)symbol; (void)replacement;
    return rebind_rc;
}

int fake_parse_shell(const char *cmd, void *argv, int max, const char **rest)
    __asm__("_" NP_PARSE_SYM_POSIX);

static char parsed[1024];

int fake_parse_shell(const char *cmd, void *argv, int max, const char **rest) {
    (void)argv; (void)max; (void)rest;
    snprintf(parsed, sizeof parsed, "%s", cmd);
    return 0;
}

static int launch_disabled = 0;

int np_hooks_env_lists_label(const char *var, const char *label) {
    (void)var;
    return launch_disabled && strcmp(label, "launch") == 0;
}

static int compat_tool = 1;

int np_compat_runs_tool(const char *cmd) {
    (void)cmd;
    return compat_tool;
}

static int app_tool = 1;

int np_compat_app_runs_tool(uint32_t appid) {
    (void)appid;
    return app_tool;
}

static const char *picked_args;

char *np_pluginlaunch_take(const char *cmd) {
    if (!picked_args) return NULL;
    char *out = malloc(strlen(cmd) + strlen(picked_args) + 2);
    sprintf(out, "%s %s", cmd, picked_args);
    picked_args = NULL;
    return out;
}

void *Plat_Realloc(void *p, size_t size) {
    return realloc(p, size);
}

static int vr_calls;

static uint64_t fake_vr_support(void *self, uint32_t appid, char **arguments) {
    (void)self; (void)appid; (void)arguments;
    vr_calls++;
    return 7;
}

static int         failures;
static const char *shell;

static char *sh_words(const char *args) {
    static char out[512];
    char        cmd[1024];

    snprintf(cmd, sizeof(cmd), "printf '[%%s]' %s", args);
    FILE  *p = popen(cmd, "r");
    size_t n = p ? fread(out, 1, sizeof(out) - 1, p) : 0;

    if (p)
        pclose(p);
    out[n] = 0;
    return out;
}

static void keeps(const char *in, const char *want, const char *words) {
    char *args = strdup(in);
    int   before = vr_calls;
    uint64_t ret = np_hook_vr_support(NULL, 2290, &args);

    if (ret != 7 || vr_calls != before + 1 || strcmp(args, want) != 0) {
        printf("FAIL %s\n  want: %s\n  got:  %s\n", in, want, args);
        failures++;
    } else if (words && strcmp(sh_words(args), words) != 0) {
        printf("FAIL %s\n  sh want: %s\n  sh got:  %s\n", in, words, sh_words(args));
        failures++;
    } else {
        printf("  ok    %s\n", in);
    }
    free(args);
}

static void wraps(const char *in, const char *want) {
    char *got = np_launch_shell(in, shell, -1, NULL);

    if (!got || strcmp(got, want) != 0) {
        printf("FAIL %s\n  want: %s\n  got:  %s\n", in, want, got ? got : "(unchanged)");
        failures++;
    } else {
        printf("  ok    %s\n", in);
    }
    free(got);
}

int main(void) {
    printf("== a NAME=VALUE prefix reaches the shell that promotes it ==\n");
    wraps("LSFGM_ENV=1 /g/game.exe", "/bin/sh -c 'LSFGM_ENV=1 /g/game.exe'");
    wraps("A=1 B=2 /g/game.exe", "/bin/sh -c 'A=1 B=2 /g/game.exe'");
    wraps("A=1 /g/game.exe -windowed", "/bin/sh -c 'A=1 /g/game.exe -windowed'");
    wraps("  A=1 /g/game.exe", "/bin/sh -c '  A=1 /g/game.exe'");

    wraps("A=1", "/bin/sh -c 'A=1'");

    printf("== the quotes Steam substitutes survive byte for byte ==\n");
    wraps("A=1 \"/Program Files/game.exe\"",
          "/bin/sh -c 'A=1 \"/Program Files/game.exe\"'");
    wraps("A='x y' /g/game.exe", "/bin/sh -c 'A='\\''x y'\\'' /g/game.exe'");
    wraps("A=1 '/p/.'/run waitforexitandrun '/g/g 64.exe'",
          "/bin/sh -c 'A=1 '\\''/p/.'\\''/run waitforexitandrun '\\''/g/g 64.exe'\\'''");

    printf("== what only a shell would act on reaches one ==\n");
    wraps("/g/game.exe > /tmp/log", "/bin/sh -c '/g/game.exe > /tmp/log'");
    wraps("/g/game.exe | tee /tmp/log", "/bin/sh -c '/g/game.exe | tee /tmp/log'");
    wraps("/g/game.exe && echo done", "/bin/sh -c '/g/game.exe && echo done'");
    wraps("/g/game.exe; echo done", "/bin/sh -c '/g/game.exe; echo done'");
    wraps("/g/game.exe $HOME", "/bin/sh -c '/g/game.exe $HOME'");
    wraps("/g/game.exe \"$HOME\"", "/bin/sh -c '/g/game.exe \"$HOME\"'");
    wraps("/g/game.exe ~/save", "/bin/sh -c '/g/game.exe ~/save'");
    wraps("/g/game.exe *.cfg", "/bin/sh -c '/g/game.exe *.cfg'");

    printf("== a plain command line reaches the shell too, as on Linux ==\n");
    wraps("/g/game.exe", "/bin/sh -c '/g/game.exe'");
    wraps("/g/game.exe -windowed", "/bin/sh -c '/g/game.exe -windowed'");
    wraps("\"/Program Files/game.exe\" -windowed",
          "/bin/sh -c '\"/Program Files/game.exe\" -windowed'");
    wraps("gamemoderun /g/game.exe", "/bin/sh -c 'gamemoderun /g/game.exe'");
    wraps("/g/game.exe '$HOME'", "/bin/sh -c '/g/game.exe '\\''$HOME'\\'''");
    wraps("", "/bin/sh -c ''");
    wraps(";touch ~", "/bin/sh -c ';touch ~'");

    printf("== STEAM_GAME_LAUNCH_SHELL stands in for /bin/sh -c as one argument ==\n");
    shell = "/usr/bin/env";
    wraps("A=1 /g/game.exe", "'/usr/bin/env' 'A=1 /g/game.exe'");
    shell = "/opt/my shell";
    wraps("/g/game.exe", "'/opt/my shell' '/g/game.exe'");
    shell = "";
    wraps("/g/game.exe", "'' '/g/game.exe'");
    shell = NULL;

    printf("== a native macOS game keeps Steam's own parsing ==\n");
    compat_tool = 0;
    const char *native[] = {
        "'/g/Game.app'",
        "'/g/Game.app' -windowed",
        "A=1 '/g/Game.app/Contents/MacOS/Game'",
        "'/g/Game' > /tmp/log",
    };
    for (size_t i = 0; i < sizeof(native) / sizeof(native[0]); i++) {
        char *kept = np_launch_shell(native[i], NULL, -1, NULL);
        if (kept) {
            printf("FAIL a native launch must not rewrite, but %s became: %s\n", native[i], kept);
            failures++;
        } else {
            printf("  ok    %s\n", native[i]);
        }
        free(kept);
    }
    shell = "/usr/bin/env";
    char *kept = np_launch_shell("'/g/Game.app'", shell, -1, NULL);
    if (kept) {
        printf("FAIL STEAM_GAME_LAUNCH_SHELL must not reach a native launch, but it became: %s\n", kept);
        failures++;
    } else {
        printf("  ok    STEAM_GAME_LAUNCH_SHELL leaves a native launch alone\n");
    }
    free(kept);
    shell = NULL;
    compat_tool = 1;

    printf("== a capped argument count keeps the caller on its own buffer ==\n");
    const char *rest = NULL;
    char       *got  = np_launch_shell("A=1 /g/game.exe", NULL, 2, NULL);

    if (got) {
        printf("FAIL a capped count must not rewrite, but it became: %s\n", got);
        failures++;
    } else {
        printf("  ok    a capped count is left alone\n");
    }
    free(got);

    got = np_launch_shell("A=1 /g/game.exe", NULL, -1, &rest);
    if (got) {
        printf("FAIL a remainder request must not rewrite, but it became: %s\n", got);
        failures++;
    } else {
        printf("  ok    a remainder request is left alone\n");
    }
    free(got);

    printf("== a choice picked in Steam's launch picker joins the launch it was picked for ==\n");
    orig_parse_shell = fake_parse_shell;
    picked_args      = "--game=a";
    np_hook_parse_shell("A=1 /g/launcher.exe", NULL, -1, NULL);
    if (strcmp(parsed, "/bin/sh -c 'A=1 /g/launcher.exe --game=a'") != 0 || picked_args) {
        printf("FAIL the pick did not reach the shell: %s\n", parsed);
        failures++;
    } else {
        printf("  ok    the picked arguments reach the shell with the command\n");
    }
    compat_tool = 0;
    picked_args = "--game=a";
    np_hook_parse_shell("'/g/Game.app'", NULL, -1, NULL);
    if (strcmp(parsed, "'/g/Game.app'") != 0 || !picked_args) {
        printf("FAIL a native launch used up the pick: %s\n", parsed);
        failures++;
    } else {
        printf("  ok    a native launch leaves the pick for its own launch\n");
    }
    compat_tool = 1;
    picked_args = NULL;

    printf("== an app's own arguments reach the game with their backslashes ==\n");
    orig_vr_support  = (void *)fake_vr_support;
    np_shell_wrapped = 1;
    plat_realloc     = Plat_Realloc;
    keeps("-conf .\\base\\plutoniam.conf -fullscreen -exit",
          "-conf .\\\\base\\\\plutoniam.conf -fullscreen -exit",
          "[-conf][.\\base\\plutoniam.conf][-fullscreen][-exit]");
    keeps("--bundle-dir ..\\bundle", "--bundle-dir ..\\\\bundle", "[--bundle-dir][..\\bundle]");
    keeps("-conf \"..\\PAGA.conf\"", "-conf \"..\\\\PAGA.conf\"", "[-conf][..\\PAGA.conf]");
    keeps("\\\\server\\share", "\\\\\\\\server\\\\share", "[\\\\server\\share]");
    keeps("-windowed", "-windowed", "[-windowed]");
    keeps("", "", NULL);

    printf("== a native macOS game keeps the client's arguments ==\n");
    app_tool = 0;
    keeps("--cwd client_pc\\root\\bin\\pc", "--cwd client_pc\\root\\bin\\pc", NULL);
    app_tool = 1;

    printf("== without the shell, the client's arguments stay as they are ==\n");
    np_shell_wrapped = 0;
    keeps("--cwd client_pc\\root\\bin\\pc", "--cwd client_pc\\root\\bin\\pc", NULL);
    np_shell_wrapped = 1;

    printf("== the shell is used only when an import slot was rebound ==\n");
    int rcs[] = { -1, 0, 1, 2 };
    for (size_t i = 0; i < sizeof(rcs) / sizeof(rcs[0]); i++) {
        rebind_rc        = rcs[i];
        np_shell_wrapped = -1;
        np_hooks_launch_install(NULL, 0);
        if (np_shell_wrapped != (rcs[i] > 0)
            || np_hooks_launch_count() != (rcs[i] > 0 ? 1 : 0)) {
            printf("FAIL rebind rc=%d left np_shell_wrapped=%d, %d hook(s)\n",
                   rcs[i], np_shell_wrapped, np_hooks_launch_count());
            failures++;
        } else {
            printf("  ok    rebind rc=%d, wrapped=%d, %d hook(s)\n",
                   rcs[i], np_shell_wrapped, np_hooks_launch_count());
        }
    }

    printf("== NOTPROTON_DISABLE=launch turns off the shell and the backslash hook ==\n");
    rebind_rc        = 1;
    np_shell_wrapped = 0;
    launch_disabled  = 1;
    np_hooks_launch_install(NULL, 0);
    launch_disabled  = 0;
    if (np_shell_wrapped || np_hooks_launch_count() != 0) {
        printf("FAIL disabled launch left np_shell_wrapped=%d, %d hook(s)\n",
               np_shell_wrapped, np_hooks_launch_count());
        failures++;
    } else {
        printf("  ok    disabled, wrapped=0, 0 hooks\n");
    }
    np_shell_wrapped = 1;

    if (failures) {
        printf("\n%d assertion(s) failed\n", failures);
        return 1;
    }
    printf("\n==> launch-shell: all assertions hold\n");
    return 0;
}
