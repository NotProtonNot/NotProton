// Launch rules: that a rule only reaches the game it names, that what it passes is one
// word at a time, and that a rule naming nothing at all is refused.
#include "../feats/rules.c"

#include <limits.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

int np_log_level = 0;
FILE *np_log_file = NULL;

static int failures;
static char dir[PATH_MAX];

static void check(const char *what, const char *want, const char *got) {
    int ok = strcmp(want, got) == 0;
    printf("  %s  %s\n", ok ? "ok  " : "FAIL", what);
    if (!ok) { printf("        want [%s]\n        got  [%s]\n", want, got); failures++; }
}

static void put(const char *name, const char *text) {
    char path[PATH_MAX];
    snprintf(path, sizeof path, "%s/%s", dir, name);
    FILE *f = fopen(path, "w");
    if (!f) { perror(path); exit(1); }
    fputs(text, f);
    fclose(f);
}

static np_game_t game(np_engine_t engine, np_launcher_t launcher, const char *exe) {
    np_game_t g = { 0 };
    g.scanned = 1;
    g.engine = engine;
    g.launcher = launcher;
    snprintf(g.exe, sizeof g.exe, "/Games/Thing/%s", exe);
    return g;
}

static const char *options(unsigned appid, const np_game_t *g) {
    static char out[NP_RULES_OPTIONS_MAX];
    np_rules_t r;
    np_rules_apply(dir, NULL, appid, g, &r);
    snprintf(out, sizeof out, "%s", r.options);
    return out;
}

int main(void) {
    snprintf(dir, sizeof dir, "%s/rules.XXXXXX", getenv("TMPDIR") ? getenv("TMPDIR") : "/tmp");
    if (!mkdtemp(dir)) { perror("mkdtemp"); return 1; }

    printf("== a rule reaches the game it names ==\n");
    put("10-appid.conf", "[one-game]\nappid = 480\noption = -skipLauncher\n");
    np_game_t plain = game(NP_ENGINE_NONE, NP_LAUNCHER_NONE, "Thing.exe");
    check("the game it names", "-skipLauncher", options(480, &plain));
    check("and no other", "", options(620, &plain));

    put("20-engine.conf", "[unreal-movies]\nengine = unreal\noption = -nostartupmovies\n");
    np_game_t unreal = game(NP_ENGINE_UNREAL, NP_LAUNCHER_NONE, "Thing-Win64-Shipping.exe");
    check("an engine rule reaches that engine", "-nostartupmovies", options(1, &unreal));
    check("and not another", "", options(1, &plain));

    // Two conditions is both of them, not either.
    put("30-both.conf", "[ea-unity]\nengine = unity\nlauncher = ea\noption = -force-d3d11\n");
    np_game_t unity_ea = game(NP_ENGINE_UNITY, NP_LAUNCHER_EA, "Thing.exe");
    np_game_t unity_only = game(NP_ENGINE_UNITY, NP_LAUNCHER_NONE, "Thing.exe");
    check("both conditions match", "-force-d3d11", options(1, &unity_ea));
    check("one of two does not", "", options(1, &unity_only));

    // A field given twice is a list, and any entry matches.
    put("40-list.conf", "[a-few]\nappid = 10\nappid = 20\noption = -x\n");
    check("the first of a list", "-x", options(10, &plain));
    check("the second of a list", "-x", options(20, &plain));
    check("and nothing else in it", "", options(30, &plain));

    put("50-exe.conf", "[by-exe]\nexe = Blacklist_DX11_game.exe\noption = -dx11\n");
    np_game_t blacklist = game(NP_ENGINE_NONE, NP_LAUNCHER_NONE, "Blacklist_DX11_game.exe");
    check("a rule for one binary", "-dx11", options(1, &blacklist));
    check("and not for another", "", options(1, &plain));

    printf("== what the rules add up to ==\n");
    {
        char path[PATH_MAX];
        const char *gone[] = { "10-appid.conf", "20-engine.conf", "30-both.conf",
                               "40-list.conf", "50-exe.conf", NULL };
        for (int i = 0; gone[i]; i++) {
            snprintf(path, sizeof path, "%s/%s", dir, gone[i]);
            unlink(path);
        }
    }
    put("10-two.conf", "[first]\nengine = unreal\noption = -a\noption = -b\n"
                       "\n[second]\nengine = unreal\noption = -b\noption = -c\nnote = Started oddly.\n");
    np_rules_t r;
    np_rules_apply(dir, NULL, 1, &unreal, &r);
    check("two rules join, and a word said twice is said once", "-a -b -c", r.options);
    check("the note comes along", "Started oddly.", r.note);
    check("and both rules counted", "2", (char[8]){ (char)('0' + r.matched), 0 });

    printf("== a rule that is not one ==\n");
    put("10-two.conf", "");
    // Nothing to match on would be a rule for every game ever installed.
    put("60-no-match.conf", "[everything]\noption = -x\n");
    check("a rule that names no game is refused", "", options(480, &plain));
    put("60-no-match.conf", "");
    // And nothing to say is nothing to do.
    put("61-nothing.conf", "[silent]\nappid = 480\n");
    check("a rule with nothing to pass is refused", "", options(480, &plain));
    put("61-nothing.conf", "");
    // An option is one word, passed to a game, so a shell's punctuation is not one.
    put("62-shell.conf", "[sneaky]\nappid = 480\noption = -x;rm -rf /\n");
    check("an option carrying a shell's punctuation is refused", "", options(480, &plain));
    put("62-shell.conf", "");
    put("63-unknown.conf", "[odd]\nappid = 480\nengine = cryengine\noption = -x\n");
    check("an engine nothing reads is refused", "", options(480, &plain));
    put("63-unknown.conf", "");
    put("64-appid.conf", "[words]\nappid = four-eighty\noption = -x\n");
    check("an appid that is not a number is refused", "", options(480, &plain));
    put("64-appid.conf", "");

    printf("== nowhere to read ==\n");
    np_rules_apply("/nope/not/here", NULL, 480, &plain, &r);
    check("a folder that is not there says nothing", "", r.options);
    np_rules_apply(NULL, NULL, 480, &plain, &r);
    check("and neither does no folder", "", r.options);

    printf("== the examples that ship ==\n");
    np_rules_apply("examples/rules", NULL, 1, &unreal, &r);
    check("the shipped example reaches an Unreal game", "-nostartupmovies", r.options);
    np_rules_apply("examples/rules", NULL, 1, &plain, &r);
    check("and nothing else", "", r.options);

    printf(failures ? "==> rules-check: %d failure(s)\n" : "==> rules-check: rules reach their own games\n",
           failures);
    return failures ? 1 : 0;
}
