#ifndef PLUGIN_HOST_CHECK_H
#define PLUGIN_HOST_CHECK_H

#include <fcntl.h>
#include <glob.h>
#include <spawn.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/wait.h>
#include <time.h>

extern char **environ;

static int failures;

static unsigned char *slurp(const char *path, size_t *len) {
    FILE *f = fopen(path, "rb");
    if (!f) return NULL;
    fseek(f, 0, SEEK_END);
    long n = ftell(f);
    fseek(f, 0, SEEK_SET);
    unsigned char *b = n > 0 ? malloc((size_t)n + 1) : NULL;
    if (b && fread(b, 1, (size_t)n, f) != (size_t)n) { free(b); b = NULL; }
    fclose(f);
    if (b) { b[n] = 0; *len = (size_t)n; }
    return b;
}

static int run(char *const argv[], const char *log, char *out, size_t outsz) {
    posix_spawn_file_actions_t fa;
    posix_spawn_file_actions_init(&fa);
    posix_spawn_file_actions_addopen(&fa, 1, log, O_WRONLY | O_CREAT | O_TRUNC, 0644);
    posix_spawn_file_actions_adddup2(&fa, 1, 2);
    pid_t pid;
    int status = -1;
    if (posix_spawn(&pid, argv[0], &fa, NULL, argv, environ) == 0) waitpid(pid, &status, 0);
    posix_spawn_file_actions_destroy(&fa);
    size_t len = 0;
    char *text = (char *)slurp(log, &len);
    snprintf(out, outsz, "%s", text ? text : "");
    free(text);
    return WIFEXITED(status) ? WEXITSTATUS(status) : 99;
}

static int count_of(const char *text, const char *needle) {
    int n = 0;
    for (const char *p = text; (p = strstr(p, needle)); p += strlen(needle)) n++;
    return n;
}

static void expect(const char *what, int rc, const char *out, int want_rc, const char *needle, int times) {
    int ok = rc == want_rc && (!needle || (times ? count_of(out, needle) == times : strstr(out, needle) != NULL));
    static double last;
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    double now = ts.tv_sec + ts.tv_nsec / 1e9;
    if (!last) last = now;
    if (!ok) failures++;
    printf("  %s  %s (%.1fs)\n", ok ? "PASS" : "FAIL", what, now - last);
    last = now;
    if (!ok) {
        printf("      exit %d, wanted %d%s%s\n", rc, want_rc, needle ? ", and the log to say: " : "", needle ? needle : "");
        for (const char *l = out; *l;) {
            const char *e = strchr(l, '\n');
            int n = e ? (int)(e - l) : (int)strlen(l);
            printf("      | %.*s\n", n, l);
            l += n + (e ? 1 : 0);
        }
    }
    fflush(stdout);
}

static inline const char *runner_of(const char *path) {
    static char name[128];
    const char *r = strstr(path, "/runners/");
    const char *e = r ? strchr(r + 9, '/') : NULL;
    snprintf(name, sizeof(name), "%.*s%s", e ? (int)(e - r - 9) : 0, r ? r + 9 : "",
             strstr(path, "apple_gptk3") ? " GPTK 3" : "");
    return name;
}

static inline void runner_files(const char *tail, glob_t *g) {
    char pattern[1024];
    snprintf(pattern, sizeof(pattern), "%s/Library/Application Support/notproton/runners/*/CrossOver/%s",
             getenv("HOME"), tail);
    memset(g, 0, sizeof(*g));
    glob(pattern, 0, NULL, g);
}

#define D3DMETALS "lib*/apple_gptk*/external/D3DMetal.framework/Versions/A/D3DMetal"

static int finish(const char *name, const char *passed) {
    if (failures) printf("==> %s: %d check(s) failed\n", name, failures);
    else printf("==> %s: %s\n", name, passed);
    return failures ? 1 : 0;
}

#endif
