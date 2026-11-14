#include "verdict.h"

#include <stdio.h>
#include <string.h>

// One clean session is a game that started. Two, with nothing crashed between them, is a
// game that runs, which is as much as a machine can say without being told.
#define NP_VERDICT_SESSIONS 2
// And it has to have run for long enough to have been played rather than looked at.
#define NP_VERDICT_MINUTES 20

// Counts no run could reach, so a record that was edited or half written cannot make the
// page show a number it would have to be wrong about.
#define NP_VERDICT_COUNT_MAX   100000
#define NP_VERDICT_SECONDS_MAX 100000000

#define NP_VERDICT_FORMAT "1"

static int take_line(FILE *f, char *out, size_t size) {
    if (!fgets(out, (int)size, f)) return 0;
    size_t n = strlen(out);
    if (n && out[n - 1] == '\n') out[--n] = '\0';
    else if (n == size - 1) return 0;  // a line longer than the field is not the field
    return 1;
}

static int take_count(FILE *f, long limit, long *out) {
    char line[32];
    if (!take_line(f, line, sizeof line) || !line[0]) return 0;
    long v = 0;
    for (const char *p = line; *p; p++) {
        if (*p < '0' || *p > '9') return 0;
        v = v * 10 + (*p - '0');
        if (v > limit) return 0;
    }
    *out = v;
    return 1;
}

// A field the page prints, so it carries no quote, backslash or control character of its
// own: the JSON escapes those, and a value holding them is a record to distrust anyway.
static int take_field(FILE *f, char *out, size_t size) {
    if (!take_line(f, out, size)) return 0;
    for (const char *p = out; *p; p++)
        if ((unsigned char)*p < 0x20 || *p == '"' || *p == '\\') return 0;
    return 1;
}

static np_verdict_tier_t tier_of(const np_verdict_t *v) {
    if (!v->healthy && !v->failed) return NP_VERDICT_UNKNOWN;
    if (!v->healthy) return NP_VERDICT_BROKEN;
    if (v->failed || strcmp(v->last, "failed") == 0) return NP_VERDICT_PLAYABLE;
    if (v->healthy >= NP_VERDICT_SESSIONS && v->minutes >= NP_VERDICT_MINUTES)
        return NP_VERDICT_VERIFIED;
    return NP_VERDICT_PLAYABLE;
}

int np_verdict_read(const char *compatdata, np_verdict_t *out) {
    if (!out) return 0;
    memset(out, 0, sizeof *out);
    snprintf(out->last, sizeof out->last, "unknown");
    if (!compatdata || !*compatdata) return 0;

    char path[1024];
    if ((size_t)snprintf(path, sizeof path, "%s/notproton-sessions", compatdata) >= sizeof path)
        return 0;
    FILE *f = fopen(path, "r");
    if (!f) return 0;

    np_verdict_t v;
    memset(&v, 0, sizeof v);
    char format[16], last[16];
    long healthy = 0, failed = 0, seconds = 0;
    int ok = take_line(f, format, sizeof format) && strcmp(format, NP_VERDICT_FORMAT) == 0
          && take_count(f, NP_VERDICT_COUNT_MAX, &healthy)
          && take_count(f, NP_VERDICT_COUNT_MAX, &failed)
          && take_count(f, NP_VERDICT_SECONDS_MAX, &seconds)
          && take_field(f, last, sizeof last)
          && take_field(f, v.build, sizeof v.build)
          && take_field(f, v.backend, sizeof v.backend);
    fclose(f);
    if (!ok) return 0;

    v.healthy = (int)healthy;
    v.failed = (int)failed;
    v.minutes = (int)(seconds / 60);
    if (strcmp(last, "healthy") != 0 && strcmp(last, "failed") != 0) snprintf(last, sizeof last, "unknown");
    snprintf(v.last, sizeof v.last, "%s", last);
    v.tier = tier_of(&v);
    *out = v;
    return 1;
}

const char *np_verdict_name(np_verdict_tier_t tier) {
    switch (tier) {
        case NP_VERDICT_VERIFIED: return "verified";
        case NP_VERDICT_PLAYABLE: return "playable";
        case NP_VERDICT_BROKEN:   return "broken";
        default:                  return "unknown";
    }
}
