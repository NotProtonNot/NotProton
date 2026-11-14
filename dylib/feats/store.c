// Mac compatibility on Steam's store and wishlist pages, by way of the web helper's own
// debugger. See store.h for why it has to be this way and what it costs.
#include "store.h"
#include "catalog.h"
#include "store_page.h"
#include "../util/file.h"
#include "../util/log.h"

#include "cJSON.h"

#include <arpa/inet.h>
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <netinet/in.h>
#include <poll.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <unistd.h>

#define NP_STORE_OFF_FILE    "no-store-badges"
#define NP_BADGES_OFF_FILE   "no-mac-badges"
#define NP_STORE_URL         "https://store.steampowered.com/"
#define NP_STORE_PLACE       "__NP_MAP__"
#define NP_STORE_VIEWS       8
#define NP_STORE_REPLY_MAX   (512u << 10)
#define NP_STORE_POLL_MS     3000
#define NP_STORE_IO_MS       2000

static int support_has(const char *name) {
    char path[PATH_MAX];
    const char *home = np_home_dir();
    np_support_path(path, sizeof path, home ? home : "", name);
    struct stat sb;
    return stat(path, &sb) == 0;
}

int np_store_switch(void) {
    return !support_has(NP_STORE_OFF_FILE);
}

int np_store_enabled(void) {
    return np_store_switch() && !support_has(NP_BADGES_OFF_FILE);
}

int np_store_set_enabled(int on) {
    char path[PATH_MAX];
    const char *home = np_home_dir();
    np_support_path(path, sizeof path, home ? home : "", NP_STORE_OFF_FILE);
    if (on) return unlink(path) == 0 || errno == ENOENT;
    FILE *f = fopen(path, "w");
    return f && fclose(f) == 0;
}

char **np_store_helper_args(const char *path, char *const argv[]) {
    if (!path || !argv || !np_store_enabled()) return NULL;
    const char *base = strrchr(path, '/');
    if (strcmp(base ? base + 1 : path, "Steam Helper") != 0) return NULL;
    int count = 0;
    for (; argv[count]; count++) {
        // A helper started with a --type is one of the first helper's own children, and
        // the debugger belongs to the first. One already told a port keeps the one it has.
        if (strncmp(argv[count], "--type=", 7) == 0) return NULL;
        if (strncmp(argv[count], "--remote-debugging-port", 23) == 0) return NULL;
    }
    char **full = malloc(sizeof(char *) * (size_t)(count + 3));
    if (!full) return NULL;
    for (int i = 0; i < count; i++) full[i] = argv[i];
    // On this machine only: the address is what keeps the port off the network.
    static char port[] = "--remote-debugging-port=27101";
    static char addr[] = "--remote-debugging-address=127.0.0.1";
    _Static_assert(NP_STORE_PORT == 27101, "the port argument above spells NP_STORE_PORT out");
    full[count] = port;
    full[count + 1] = addr;
    full[count + 2] = NULL;
    return full;
}

size_t np_store_frame(const char *text, size_t n, const uint8_t mask[4], uint8_t *out, size_t cap) {
    // A client's frames are always masked. The length is 7 bits, or 126 and 16 more, or
    // 127 and 64 more, which a page script with a library's worth of badges in it needs.
    size_t head = 2 + (n > 65535 ? 8 : n > 125 ? 2 : 0) + 4;
    if (!out || head + n > cap) return 0;
    size_t at = 0;
    out[at++] = 0x81;                                   // final frame, text
    if (n > 65535) {
        out[at++] = 0x80 | 127;
        for (int shift = 56; shift >= 0; shift -= 8) out[at++] = (uint8_t)((uint64_t)n >> shift);
    } else if (n > 125) {
        out[at++] = 0x80 | 126;
        out[at++] = (uint8_t)(n >> 8);
        out[at++] = (uint8_t)n;
    } else {
        out[at++] = (uint8_t)(0x80 | n);
    }
    memcpy(out + at, mask, 4);
    at += 4;
    for (size_t i = 0; i < n; i++) out[at + i] = (uint8_t)text[i] ^ mask[i & 3];
    return at + n;
}

int np_store_wants(const char *type, const char *url) {
    return type && url && strcmp(type, "page") == 0
        && strncmp(url, NP_STORE_URL, sizeof(NP_STORE_URL) - 1) == 0;
}

char *np_store_script(const char *page, const char *map) {
    if (!page || !map) return NULL;
    const char *at = strstr(page, NP_STORE_PLACE);
    // More than one place, or none, is a script this was not written for, and putting it
    // in would only throw inside Valve's page.
    if (!at || strstr(at + 1, NP_STORE_PLACE)) return NULL;
    size_t before = (size_t)(at - page), place = sizeof(NP_STORE_PLACE) - 1;
    size_t size = strlen(page) - place + strlen(map) + 1;
    char *out = malloc(size);
    if (!out) return NULL;
    memcpy(out, page, before);
    snprintf(out + before, size - before, "%s%s", map, at + place);
    return out;
}

// ---- sockets from here on ----

static int dial(void) {
    int fd = socket(AF_INET, SOCK_STREAM, 0);
    if (fd < 0) return -1;
    fcntl(fd, F_SETFD, FD_CLOEXEC);
    int on = 1;
    setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, sizeof on);
    struct timeval tv = { NP_STORE_IO_MS / 1000, (NP_STORE_IO_MS % 1000) * 1000 };
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof tv);
    setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, sizeof tv);
    struct sockaddr_in to = { 0 };
    to.sin_family = AF_INET;
    to.sin_port = htons(NP_STORE_PORT);
    to.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    if (connect(fd, (struct sockaddr *)&to, sizeof to) != 0) { close(fd); return -1; }
    return fd;
}

static int send_all(int fd, const void *data, size_t n) {
    const uint8_t *p = data;
    while (n) {
        ssize_t w = send(fd, p, n, 0);
        if (w < 0 && errno == EINTR) continue;
        if (w <= 0) return 0;
        p += w;
        n -= (size_t)w;
    }
    return 1;
}

// Reads up to the end of the headers, and returns where the body starts within what was read.
static ssize_t read_head(int fd, char *buf, size_t cap, size_t *got) {
    *got = 0;
    while (*got < cap - 1) {
        ssize_t r = recv(fd, buf + *got, cap - 1 - *got, 0);
        if (r < 0 && errno == EINTR) continue;
        if (r <= 0) return -1;
        *got += (size_t)r;
        buf[*got] = '\0';
        const char *end = strstr(buf, "\r\n\r\n");
        if (end) return (ssize_t)(end + 4 - buf);
    }
    return -1;
}

// One GET to the debugger. The caller frees the body.
static char *http_get(const char *path) {
    int fd = dial();
    if (fd < 0) return NULL;
    char req[256];
    int n = snprintf(req, sizeof req, "GET %s HTTP/1.1\r\nHost: 127.0.0.1:%d\r\nConnection: close\r\n\r\n",
                     path, NP_STORE_PORT);
    char *buf = malloc(NP_STORE_REPLY_MAX);
    char *body = NULL;
    size_t got = 0;
    ssize_t at = buf && send_all(fd, req, (size_t)n) ? read_head(fd, buf, NP_STORE_REPLY_MAX, &got) : -1;
    if (at > 0 && strncmp(buf, "HTTP/1.1 200", 12) == 0) {
        // The debugger says how long its answer is and then keeps the connection, so the
        // length is what ends the read.
        size_t want = 0;
        const char *len = strcasestr(buf, "Content-Length:");
        if (len && len < buf + at) want = (size_t)strtoul(len + 15, NULL, 10);
        while (want && got - (size_t)at < want && got < NP_STORE_REPLY_MAX - 1) {
            ssize_t r = recv(fd, buf + got, NP_STORE_REPLY_MAX - 1 - got, 0);
            if (r < 0 && errno == EINTR) continue;
            if (r <= 0) break;
            got += (size_t)r;
        }
        buf[got] = '\0';
        if (!want || got - (size_t)at >= want) body = strdup(buf + at);
    }
    free(buf);
    close(fd);
    return body;
}

static int send_text(int fd, const char *text) {
    size_t n = strlen(text), cap = n + 16;
    uint8_t *frame = malloc(cap);
    if (!frame) return 0;
    uint8_t mask[4];
    arc4random_buf(mask, sizeof mask);
    size_t len = np_store_frame(text, n, mask, frame, cap);
    int ok = len && send_all(fd, frame, len);
    free(frame);
    return ok;
}

static int send_call(int fd, int id, const char *method, const char *key, const char *value) {
    cJSON *msg = cJSON_CreateObject();
    if (!msg) return 0;
    cJSON_AddNumberToObject(msg, "id", id);
    cJSON_AddStringToObject(msg, "method", method);
    if (key) cJSON_AddStringToObject(cJSON_AddObjectToObject(msg, "params"), key, value);
    char *text = cJSON_PrintUnformatted(msg);
    cJSON_Delete(msg);
    int ok = text && send_text(fd, text);
    free(text);
    return ok;
}

// Opens the debugger's socket for one page and leaves the script on it: once for every
// page the view goes on to load, and once for the one it is on now. The registration
// lasts as long as the connection does, so the socket is kept.
static int attach(const char *ws_url, const char *script) {
    const char *path = strstr(ws_url, "/devtools/");
    if (!path) return -1;
    int fd = dial();
    if (fd < 0) return -1;
    char req[512];
    // No Origin: the helper refuses a debugger connection that names one it was not told
    // to allow, and a program that is not a page has none to name.
    int n = snprintf(req, sizeof req,
                     "GET %s HTTP/1.1\r\nHost: 127.0.0.1:%d\r\nUpgrade: websocket\r\n"
                     "Connection: Upgrade\r\nSec-WebSocket-Key: bm90cHJvdG9uLXN0b3JlIQ==\r\n"
                     "Sec-WebSocket-Version: 13\r\n\r\n", path, NP_STORE_PORT);
    char head[1024];
    size_t got = 0;
    if (n <= 0 || (size_t)n >= sizeof req || !send_all(fd, req, (size_t)n)
        || read_head(fd, head, sizeof head, &got) < 0 || strncmp(head, "HTTP/1.1 101", 12) != 0
        || !send_call(fd, 1, "Page.enable", NULL, NULL)
        || !send_call(fd, 2, "Page.addScriptToEvaluateOnNewDocument", "source", script)
        || !send_call(fd, 3, "Runtime.evaluate", "expression", script)) {
        close(fd);
        return -1;
    }
    return fd;
}

typedef struct { int fd; char id[64]; } view_t;

// Whatever the debugger says back is read and dropped: nothing here acts on it, but a
// socket nobody reads fills up, and a closed one is a view that has gone.
static void drain(view_t *views, int wait_ms) {
    struct pollfd fds[NP_STORE_VIEWS];
    int map[NP_STORE_VIEWS], n = 0;
    for (int i = 0; i < NP_STORE_VIEWS; i++)
        if (views[i].fd >= 0) { fds[n] = (struct pollfd){ views[i].fd, POLLIN, 0 }; map[n++] = i; }
    if (!n) { usleep((useconds_t)wait_ms * 1000); return; }
    if (poll(fds, (nfds_t)n, wait_ms) <= 0) return;
    for (int k = 0; k < n; k++) {
        if (!(fds[k].revents & (POLLIN | POLLHUP | POLLERR))) continue;
        char sink[4096];
        ssize_t r = recv(fds[k].fd, sink, sizeof sink, MSG_DONTWAIT);
        if (r == 0 || (r < 0 && errno != EAGAIN && errno != EWOULDBLOCK && errno != EINTR)) {
            close(fds[k].fd);
            views[map[k]].fd = -1;
        }
    }
}

static void drop_all(view_t *views) {
    for (int i = 0; i < NP_STORE_VIEWS; i++)
        if (views[i].fd >= 0) { close(views[i].fd); views[i].fd = -1; }
}

static void *store_thread(void *unused) {
    (void)unused;
    view_t views[NP_STORE_VIEWS];
    for (int i = 0; i < NP_STORE_VIEWS; i++) views[i].fd = -1;
    int known = 0, said = 0;

    for (;;) {
        if (!np_store_enabled()) { drop_all(views); known = 0; sleep(5); continue; }
        if (!known) {
            // Whatever is listening has to say it is Steam before anything is sent to it:
            // the port is a number, and something else could be sitting on it.
            char *version = http_get("/json/version");
            known = version && strstr(version, "Valve Steam Client") != NULL;
            free(version);
            if (!known) { sleep(5); continue; }
            if (!said++) NP_LOG("store: Steam's debugger is up on 127.0.0.1:%d", NP_STORE_PORT);
        }
        char *list = http_get("/json");
        cJSON *targets = list ? cJSON_Parse(list) : NULL;
        free(list);
        if (!cJSON_IsArray(targets)) {
            cJSON_Delete(targets);
            drop_all(views);
            known = 0;
            sleep(3);
            continue;
        }
        cJSON *t;
        cJSON_ArrayForEach(t, targets) {
            const char *type = cJSON_GetStringValue(cJSON_GetObjectItemCaseSensitive(t, "type"));
            const char *url = cJSON_GetStringValue(cJSON_GetObjectItemCaseSensitive(t, "url"));
            const char *id = cJSON_GetStringValue(cJSON_GetObjectItemCaseSensitive(t, "id"));
            const char *ws = cJSON_GetStringValue(cJSON_GetObjectItemCaseSensitive(t, "webSocketDebuggerUrl"));
            if (!id || !ws || !np_store_wants(type, url)) continue;
            int have = 0, slot = -1;
            for (int i = 0; i < NP_STORE_VIEWS; i++) {
                if (views[i].fd >= 0 && strcmp(views[i].id, id) == 0) have = 1;
                if (views[i].fd < 0 && slot < 0) slot = i;
            }
            if (have || slot < 0) continue;
            char *map = np_catalog_map();
            char *script = np_store_script(np_store_page_js, map ? map : "{}");
            free(map);
            int fd = script ? attach(ws, script) : -1;
            free(script);
            if (fd < 0) continue;
            views[slot].fd = fd;
            snprintf(views[slot].id, sizeof views[slot].id, "%s", id);
            NP_LOG("store: Mac compatibility added to a store view");
        }
        cJSON_Delete(targets);
        drain(views, NP_STORE_POLL_MS);
    }
    return NULL;
}

void np_store_start(void) {
    static pthread_mutex_t lock = PTHREAD_MUTEX_INITIALIZER;
    static int started;
    pthread_mutex_lock(&lock);
    int first = !started;
    started = 1;
    pthread_mutex_unlock(&lock);
    if (!first) return;
    pthread_t thread;
    pthread_attr_t attr;
    if (pthread_attr_init(&attr) != 0) return;
    pthread_attr_setdetachstate(&attr, PTHREAD_CREATE_DETACHED);
    if (pthread_create(&thread, &attr, store_thread, NULL) != 0)
        NP_WARN("store: cannot start the thread, the store shows no Mac compatibility");
    pthread_attr_destroy(&attr);
}
