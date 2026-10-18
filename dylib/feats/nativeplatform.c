// Mac and Windows app lists for the Steam macOS library filter
#include "nativeplatform.h"
#include "../util/file.h"
#include "../util/log.h"

#include <crt_externs.h>
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <poll.h>
#include <signal.h>
#include <spawn.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>

#define OUTPUT_MAX (4u << 20)

// sp.js is held up until this returns.
#ifndef HELPER_TIMEOUT_MS
#define HELPER_TIMEOUT_MS 10000
#endif

static long long now_ms(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (long long)ts.tv_sec * 1000 + ts.tv_nsec / 1000000;
}

static char *read_output(int fd, pid_t pid, long long deadline) {
    char *buf = malloc(OUTPUT_MAX + 1);
    size_t len = 0;
    while (buf) {
        long long left = deadline - now_ms();
        struct pollfd p = { fd, POLLIN, 0 };
        int ready = left > 0 ? poll(&p, 1, (int)left) : 0;
        if (ready < 0 && errno == EINTR) continue;
        if (ready <= 0) {
            NP_WARN("nativeplatform: appinfo helper timed out");
            kill(pid, SIGKILL);
            free(buf);
            return NULL;
        }
        ssize_t n = read(fd, buf + len, OUTPUT_MAX - len);
        if (n < 0 && errno == EINTR) continue;
        if (n == 0) break;
        if (n < 0 || (len += (size_t)n) == OUTPUT_MAX) {
            kill(pid, SIGKILL);
            free(buf);
            return NULL;
        }
    }
    if (buf) buf[len] = '\0';
    return buf;
}

static char *run_helper(void) {
    const char *home = np_home_dir();
    if (!home) return NULL;
    char tool[PATH_MAX], vdf[PATH_MAX];
    np_support_path(tool, sizeof(tool), home, "appinfo");
    snprintf(vdf, sizeof(vdf), "%s/Library/Application Support/Steam/appcache/appinfo.vdf", home);

    int fds[2];
    if (pipe(fds) != 0) return NULL;
    fcntl(fds[0], F_SETFD, FD_CLOEXEC);
    fcntl(fds[1], F_SETFD, FD_CLOEXEC);

    posix_spawn_file_actions_t actions;
    posix_spawnattr_t attr;
    sigset_t none, all;
    sigemptyset(&none);
    sigfillset(&all);
    if (posix_spawn_file_actions_init(&actions) != 0) {
        close(fds[0]);
        close(fds[1]);
        return NULL;
    }
    if (posix_spawnattr_init(&attr) != 0) {
        posix_spawn_file_actions_destroy(&actions);
        close(fds[0]);
        close(fds[1]);
        return NULL;
    }
    posix_spawn_file_actions_addopen(&actions, STDIN_FILENO, "/dev/null", O_RDONLY, 0);
    posix_spawn_file_actions_adddup2(&actions, fds[1], STDOUT_FILENO);
    posix_spawn_file_actions_addopen(&actions, STDERR_FILENO, "/dev/null", O_WRONLY, 0);
    posix_spawnattr_setsigmask(&attr, &none);
    posix_spawnattr_setsigdefault(&attr, &all);
    posix_spawnattr_setflags(&attr, POSIX_SPAWN_SETSIGMASK | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_CLOEXEC_DEFAULT);
    char *argv[] = { tool, vdf, "--platforms", NULL };
    pid_t pid;
    long long deadline = now_ms() + HELPER_TIMEOUT_MS;
    int rc = posix_spawn(&pid, tool, &actions, &attr, argv, *_NSGetEnviron());
    posix_spawnattr_destroy(&attr);
    posix_spawn_file_actions_destroy(&actions);
    close(fds[1]);
    if (rc != 0) {
        close(fds[0]);
        NP_WARN("nativeplatform: cannot run %s (%d)", tool, rc);
        return NULL;
    }

    char *out = read_output(fds[0], pid, deadline);
    close(fds[0]);
    if (!out) kill(pid, SIGKILL);
    int status = 0;
    pid_t done;
    for (;;) {
        done = waitpid(pid, &status, WNOHANG);
        if (done == pid || (done < 0 && errno != EINTR)) break;
        long long left = deadline - now_ms();
        if (left <= 0) {
            if (out) NP_WARN("nativeplatform: appinfo helper timed out before exiting");
            kill(pid, SIGKILL);
            free(out);
            out = NULL;
            while ((done = waitpid(pid, &status, 0)) < 0 && errno == EINTR) {}
            break;
        }
        poll(NULL, 0, (int)(left < 10 ? left : 10));
    }
    if (done != pid || !WIFEXITED(status) || WEXITSTATUS(status) != 0) {
        if (out) NP_WARN("nativeplatform: appinfo helper failed (status %d)", status);
        free(out);
        return NULL;
    }
    return out;
}

static const char *take_list(const char **at, const char *key, size_t *len) {
    size_t key_len = strlen(key);
    if (strncmp(*at, key, key_len) != 0) return NULL;
    const char *list = *at + key_len;
    const char *p = list;
    while (*p >= '0' && *p <= '9') {
        while (*p >= '0' && *p <= '9') p++;
        if (*p != ',') break;
        if (p[1] < '0' || p[1] > '9') return NULL;
        p++;
    }
    if (*p != '\n') return NULL;
    *len = (size_t)(p - list);
    *at = p + 1;
    return list;
}

char *np_nativeplatform_javascript(void) {
    char *out = run_helper();
    if (!out) return NULL;
    const char *at = out;
    size_t mac_len = 0, windows_len = 0;
    const char *mac = take_list(&at, "mac=", &mac_len);
    const char *windows = mac ? take_list(&at, "windows=", &windows_len) : NULL;
    if (!windows || *at) {
        NP_WARN("nativeplatform: appinfo helper printed something unexpected");
        free(out);
        return NULL;
    }
    size_t cap = mac_len + windows_len + 128;
    char *js = malloc(cap);
    if (js)
        snprintf(js, cap,
                 "window.__NOTPROTON_NATIVE_PLATFORM__={mac:new Set([%.*s]),windows:new Set([%.*s])};\n",
                 (int)mac_len, mac, (int)windows_len, windows);
    free(out);
    return js;
}
