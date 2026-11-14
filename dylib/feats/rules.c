// Launch rules.
//
// The commands that get a particular game past its own launcher are things people find
// out one game at a time, so they live in files rather than in this binary: a rule names
// the game it is for and the words to pass it, and anyone can add one without a build.
#include "rules.h"
#include "conf.h"
#include "../util/log.h"

#include <stdio.h>
#include <string.h>
#include <strings.h>

typedef struct {
    unsigned        appid;
    const np_game_t *game;
    np_rules_t      *out;
} match_t;

static const char *engine_word(np_engine_t e) {
    switch (e) {
        case NP_ENGINE_UNREAL: return "unreal";
        case NP_ENGINE_UNITY:  return "unity";
        default:               return "";
    }
}

static const char *launcher_word(np_launcher_t l) {
    switch (l) {
        case NP_LAUNCHER_EA:       return "ea";
        case NP_LAUNCHER_UBISOFT:  return "ubisoft";
        case NP_LAUNCHER_EPIC:     return "epic";
        case NP_LAUNCHER_ROCKSTAR: return "rockstar";
        default:                   return "";
    }
}

static const char *base_name(const char *path) {
    const char *slash = strrchr(path, '/');
    return slash ? slash + 1 : path;
}

// A field given more than once is a list, and the rule matches when any entry does.
static int any_is(const np_conf_rec_t *rec, const char *field, const char *want,
                  int fold, int *given) {
    const char *n, *v;
    int it = 0;
    *given = 0;
    int hit = 0;
    while (np_conf_next(rec, &it, &n, &v)) {
        if (strcmp(n, field) != 0) continue;
        *given = 1;
        if (fold ? strcasecmp(v, want) == 0 : strcmp(v, want) == 0) hit = 1;
    }
    return hit;
}

static int matches(const np_conf_rec_t *rec, const match_t *m) {
    char appid[16];
    snprintf(appid, sizeof appid, "%u", m->appid);
    int given = 0;

    if (!any_is(rec, "appid", appid, 0, &given) && given) return 0;
    if (!any_is(rec, "engine", engine_word(m->game->engine), 0, &given) && given) return 0;
    if (!any_is(rec, "launcher", launcher_word(m->game->launcher), 0, &given) && given) return 0;
    if (!any_is(rec, "exe", base_name(m->game->exe), 1, &given) && given) return 0;
    return 1;
}

static void add_option(np_rules_t *out, const char *option) {
    // The same word twice is the same word: two rules may agree without saying it twice.
    size_t n = strlen(option);
    for (const char *at = out->options; *at; ) {
        const char *sp = strchr(at, ' ');
        size_t len = sp ? (size_t)(sp - at) : strlen(at);
        if (len == n && strncmp(at, option, n) == 0) return;
        at += len + (sp ? 1 : 0);
    }
    size_t at = strlen(out->options);
    if (at + n + 2 > sizeof out->options) return;
    snprintf(out->options + at, sizeof out->options - at, "%s%s", at ? " " : "", option);
}

static const char *take_record(const np_conf_rec_t *rec, void *ctx, const char **detail) {
    match_t *m = ctx;
    if (!matches(rec, m)) return NULL;
    m->out->matched++;
    const char *n, *v;
    int it = 0;
    while (np_conf_next(rec, &it, &n, &v)) {
        if (strcmp(n, "option") == 0) add_option(m->out, v);
        else if (strcmp(n, "note") == 0 && !m->out->note[0])
            snprintf(m->out->note, sizeof m->out->note, "%s", v);
    }
    NP_LOG("rules: %s matches app %u", rec->id, m->appid);
    return NULL;
}

static void refused(const char *scope, const char *code, const char *detail, void *ctx) {
    NP_WARN("rules: %s refused (%s%s%s)", scope, code, detail ? ": " : "", detail ? detail : "");
}

void np_rules_apply(const char *dir, const char *shown_dir, unsigned appid,
                    const np_game_t *game, np_rules_t *out) {
    if (!out) return;
    memset(out, 0, sizeof *out);
    if (!dir || !game) return;
    match_t m = { appid, game, out };
    const np_conf_sink_t sink = { take_record, refused, NULL };
    np_conf_read_dir(dir, shown_dir ? shown_dir : dir, NP_CONF_RULE, &sink, &m);
}
