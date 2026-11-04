// Spawns argv[1] the way the client spawns its port check, through posix_spawn with its
// own environment. Named steam_osx or Steam Helper by the make target so the dylib
// installs its hooks.
#include <spawn.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/wait.h>
extern char **environ;
int main(int argc, char **argv) {
    if (argc < 2) return 2;
    char *a[] = { argv[1], NULL };
    char **env = environ;
    const char *insert = getenv("SPAWN_INSERT");
    if (insert) {
        size_t n = 0;
        while (environ[n]) n++;
        env = calloc(n + 2, sizeof(char *));
        size_t len = strlen(insert) + sizeof("DYLD_INSERT_LIBRARIES=");
        if (!env || !(env[n] = malloc(len))) return 111;
        memcpy(env, environ, n * sizeof(char *));
        snprintf(env[n], len, "DYLD_INSERT_LIBRARIES=%s", insert);
    }
    pid_t pid;
    int st = 0;
    if (posix_spawn(&pid, argv[1], NULL, NULL, a, env) != 0) return 111;
    waitpid(pid, &st, 0);
    return 0;
}
