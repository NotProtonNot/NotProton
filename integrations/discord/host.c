// Relay the prefix's authenticated loopback connections to the user's Discord socket.
#include "protocol.h"
#include <arpa/inet.h>
#include <errno.h>
#include <fcntl.h>
#include <poll.h>
#include <signal.h>
#include <spawn.h>
#include <stdbool.h>
#include <stddef.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/un.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>

extern char **environ;
static volatile sig_atomic_t stopping;

struct buffer {
    unsigned char bytes[BRIDGE_BUFFER];
    size_t start, end;
    bool eof;
};

struct connection {
    int fd[2];
    struct buffer pending[2];
    unsigned char hello[BRIDGE_HELLO_SIZE];
    size_t received;
    double deadline;
    bool control;
};

static double now(void)
{
    struct timespec t;
    clock_gettime(CLOCK_MONOTONIC, &t);
    return t.tv_sec + t.tv_nsec / 1e9;
}

static void stop(int signal_number)
{
    (void)signal_number;
    stopping = 1;
}

static bool configure_socket(int fd)
{
    return fcntl(fd, F_SETFD, FD_CLOEXEC) == 0 &&
           fcntl(fd, F_SETFL, O_NONBLOCK) == 0;
}

static void close_connection(struct connection *c)
{
    for (int side = 0; side < 2; ++side) {
        if (c->fd[side] >= 0) close(c->fd[side]);
    }
    memset(c, 0, sizeof(*c));
    c->fd[0] = c->fd[1] = -1;
}

static int connect_discord(void)
{
    char user_temp[1024];
    size_t temp_size = confstr(_CS_DARWIN_USER_TEMP_DIR, user_temp, sizeof(user_temp));
    if (!temp_size || temp_size > sizeof(user_temp)) user_temp[0] = 0;
    const char *override = getenv("NOTPROTON_DISCORD_SOCKET_DIR");
    const char *roots[] = {getenv("TMPDIR"), user_temp, "/tmp"};
    if (override) { roots[0] = override; roots[1] = roots[2] = NULL; }
    for (size_t root = 0; root < sizeof(roots) / sizeof(roots[0]); ++root) {
        if (!roots[root] || !*roots[root]) continue;
        for (int index = 0; index < 10; ++index) {
            struct sockaddr_un address = {.sun_family = AF_UNIX};
            int length = snprintf(address.sun_path, sizeof(address.sun_path),
                                  "%s/discord-ipc-%d", roots[root], index);
            if (length < 0 || length >= (int)sizeof(address.sun_path)) continue;
            struct stat info;
            if (stat(address.sun_path, &info) || !S_ISSOCK(info.st_mode) || info.st_uid != getuid()) continue;
            int fd = socket(AF_UNIX, SOCK_STREAM, 0);
            if (fd < 0) continue;
            if (!configure_socket(fd)) { close(fd); continue; }
            address.sun_len = (unsigned char)(offsetof(struct sockaddr_un, sun_path) + length + 1);
            int result = connect(fd, (struct sockaddr *)&address, address.sun_len);
            if (result < 0 && errno == EINPROGRESS) {
                struct pollfd p = {.fd = fd, .events = POLLOUT};
                int error = 0;
                socklen_t size = sizeof(error);
                result = poll(&p, 1, 100);
                if (result > 0 && !getsockopt(fd, SOL_SOCKET, SO_ERROR, &error, &size) && !error)
                    result = 0;
                else result = -1;
            }
            uid_t uid;
            gid_t gid;
            if (!result && !getpeereid(fd, &uid, &gid) && uid == getuid()) return fd;
            close(fd);
        }
    }
    return -1;
}

static bool authenticate(struct connection *c, const char *token, bool *ready)
{
    ssize_t n = recv(c->fd[0], c->hello + c->received, sizeof(c->hello) - c->received, 0);
    if (n < 0) return errno == EAGAIN || errno == EINTR;
    if (!n) return false;
    c->received += (size_t)n;
    if (c->received != sizeof(c->hello)) return true;
    unsigned difference = 0;
    for (size_t i = 0; i < BRIDGE_TOKEN_LENGTH; ++i) difference |= c->hello[i] ^ (unsigned char)token[i];
    if (difference) return false;
    if (c->hello[BRIDGE_TOKEN_LENGTH] == BRIDGE_CONTROL && !*ready) {
        c->control = true;
        *ready = true;
        puts("ready");
        fflush(stdout);
        return true;
    }
    if (c->hello[BRIDGE_TOKEN_LENGTH] != BRIDGE_STREAM) return false;
    c->fd[1] = connect_discord();
    return c->fd[1] >= 0;
}

// Each direction has a bounded buffer. Stop reading a full buffer until its peer drains it.
static bool relay(struct connection *c, short events[2])
{
    for (int side = 0; side < 2; ++side) {
        struct buffer *out = &c->pending[1 - side];
        struct buffer *in = &c->pending[side];
        if (events[side] & (POLLERR | POLLNVAL)) return false;
        if ((events[side] & POLLOUT) && out->start < out->end) {
            ssize_t n = send(c->fd[side], out->bytes + out->start, out->end - out->start, 0);
            if (n < 0 && errno != EAGAIN && errno != EINTR) return false;
            if (n > 0) out->start += (size_t)n;
            if (out->start == out->end) {
                out->start = out->end = 0;
                if (out->eof) shutdown(c->fd[side], SHUT_WR);
            }
        }
        if ((events[side] & (POLLIN | POLLHUP)) && !in->eof && in->end < sizeof(in->bytes)) {
            ssize_t n = recv(c->fd[side], in->bytes + in->end, sizeof(in->bytes) - in->end, 0);
            if (n < 0 && errno != EAGAIN && errno != EINTR) return false;
            if (n > 0) in->end += (size_t)n;
            if (!n) {
                in->eof = true;
                if (in->start == in->end) shutdown(c->fd[1 - side], SHUT_WR);
            }
        }
    }
    // Discord does not use half-closed sessions. Deliver already-buffered replies, then close.
    return !(c->pending[0].eof || c->pending[1].eof) ||
           c->pending[0].start != c->pending[0].end || c->pending[1].start != c->pending[1].end;
}

static void stop_child(pid_t child)
{
    // Closing the control connection lets the PE cancel pending pipe I/O and exit normally.
    for (int i = 0; i < 30; ++i) {
        pid_t result = waitpid(child, NULL, WNOHANG);
        if (result == child || (result < 0 && errno == ECHILD)) return;
        struct timespec delay = {0, 100000000};
        nanosleep(&delay, NULL);
    }
    kill(child, SIGTERM);
    for (int i = 0; i < 10; ++i) {
        pid_t result = waitpid(child, NULL, WNOHANG);
        if (result == child || (result < 0 && errno == ECHILD)) return;
        struct timespec delay = {0, 100000000};
        nanosleep(&delay, NULL);
    }
    kill(child, SIGKILL);
    while (waitpid(child, NULL, 0) < 0 && errno == EINTR) {}
}

int main(int argc, char **argv)
{
    if (argc != 3) { fprintf(stderr, "usage: discord-host WINELOADER bridge.exe\n"); return 64; }
    signal(SIGPIPE, SIG_IGN);
    signal(SIGTERM, stop);
    signal(SIGINT, stop);
    signal(SIGHUP, stop);
    pid_t parent = getppid();
    int listener = socket(AF_INET, SOCK_STREAM, 0);
    struct sockaddr_in address = {.sin_family = AF_INET, .sin_addr.s_addr = htonl(INADDR_LOOPBACK)};
    socklen_t size = sizeof(address);
    if (listener < 0 || !configure_socket(listener) ||
        bind(listener, (struct sockaddr *)&address, sizeof(address)) ||
        getsockname(listener, (struct sockaddr *)&address, &size) || listen(listener, BRIDGE_CLIENTS)) {
        perror("NotProton Discord: listen");
        if (listener >= 0) close(listener);
        return 1;
    }
    unsigned char random[BRIDGE_TOKEN_LENGTH / 2];
    char token[BRIDGE_TOKEN_LENGTH + 1], port[16];
    arc4random_buf(random, sizeof(random));
    for (size_t i = 0; i < sizeof(random); ++i) snprintf(token + i * 2, 3, "%02x", random[i]);
    snprintf(port, sizeof(port), "%u", ntohs(address.sin_port));
    if (setenv("NOTPROTON_DISCORD_PORT", port, 1) || setenv("NOTPROTON_DISCORD_TOKEN", token, 1)) {
        perror("NotProton Discord: helper environment");
        close(listener);
        return 1;
    }
    // The IPC helper must not initialize Steam's overlay or claim a physical controller.
    unsetenv("DYLD_INSERT_LIBRARIES");
    unsetenv("STEAM_DYLD_INSERT_LIBRARIES");
    unsetenv("NOTPROTON_GAME_LOADER");
    char *arguments[] = {argv[1], argv[2], NULL};
    pid_t child;
    int error = posix_spawn(&child, argv[1], NULL, NULL, arguments, environ);
    unsetenv("NOTPROTON_DISCORD_PORT");
    unsetenv("NOTPROTON_DISCORD_TOKEN");
    if (error) { fprintf(stderr, "NotProton Discord: %s\n", strerror(error)); close(listener); return 1; }
    struct connection clients[BRIDGE_CLIENTS + 1] = {0};
    for (size_t i = 0; i < BRIDGE_CLIENTS + 1; ++i) clients[i].fd[0] = clients[i].fd[1] = -1;
    bool ready = false;
    double startup_deadline = now() + 10;
    int status = 0;
    while (!stopping && getppid() == parent) {
        if (waitpid(child, NULL, WNOHANG) == child) { child = -1; status = 1; break; }
        if (!ready && now() > startup_deadline) { status = 1; break; }
        struct pollfd fds[1 + 2 * (BRIDGE_CLIENTS + 1)] = {{.fd = listener, .events = POLLIN}};
        for (size_t i = 0; i < BRIDGE_CLIENTS + 1; ++i) {
            struct connection *c = &clients[i];
            for (int side = 0; side < 2; ++side) {
                struct pollfd *p = &fds[1 + 2 * i + side];
                p->fd = c->fd[side];
                if (!c->pending[side].eof && c->pending[side].end < BRIDGE_BUFFER) p->events |= POLLIN;
                if (c->pending[1 - side].start < c->pending[1 - side].end) p->events |= POLLOUT;
                if (!p->events) p->fd = -1;
            }
        }
        if (poll(fds, sizeof(fds) / sizeof(fds[0]), 100) < 0 && errno != EINTR) { status = 1; break; }
        for (size_t i = 0; i < BRIDGE_CLIENTS + 1; ++i) {
            struct connection *c = &clients[i];
            if (c->fd[0] < 0) continue;
            short events[] = {fds[1 + 2 * i].revents, fds[2 + 2 * i].revents};
            bool alive = true;
            if (c->received < BRIDGE_HELLO_SIZE) {
                if (now() > c->deadline) alive = false;
                else if (events[0]) alive = authenticate(c, token, &ready);
            } else if (c->control) {
                if (events[0]) { stopping = 1; alive = false; }
            } else alive = relay(c, events);
            if (!alive) close_connection(c);
        }
        if (fds[0].revents & POLLIN) {
            int fd = accept(listener, NULL, NULL);
            if (fd < 0) continue;
            size_t slot = 0;
            while (slot < BRIDGE_CLIENTS + 1 && clients[slot].fd[0] >= 0) ++slot;
            if (slot == BRIDGE_CLIENTS + 1 || !configure_socket(fd)) close(fd);
            else { clients[slot].fd[0] = fd; clients[slot].deadline = now() + 2; }
        }
    }
    close(listener);
    for (size_t i = 0; i < BRIDGE_CLIENTS + 1; ++i) close_connection(&clients[i]);
    if (child > 0) stop_child(child);
    if (!ready) fprintf(stderr, "NotProton Discord: pipe helper unavailable\n");
    return status;
}
