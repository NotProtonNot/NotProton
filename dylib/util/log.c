// Logs
#include "log.h"
#include "file.h"
#include <stdlib.h>
#include <stdint.h>
#include <pthread.h>
#include <unistd.h>
#include <sys/stat.h>

int np_log_level = NP_LVL_INFO;
FILE *np_log_file = NULL;

#define NP_LOG_MAX_BYTES (16 * 1024 * 1024)

#define NP_SEEN_SLOTS 8192

struct np_seen_slot {
    const void   *anchor;
    unsigned long tag;
    unsigned char filled;
};

static struct np_seen_slot np_seen[NP_SEEN_SLOTS];
static int np_seen_overflow;

static unsigned long np_seen_fold(const void *anchor, unsigned long tag) {
    unsigned long acc = 1469598103934665603UL; // FNV offset basis
    unsigned long bits = (unsigned long)(uintptr_t)anchor ^ (tag << 1);
    for (int b = 0; b < (int)sizeof(bits); b++) {
        acc ^= (bits & 0xFF);
        acc *= 1099511628211UL; // FNV prime
        bits >>= 8;
    }
    return acc;
}

int np_log_first_hit(const void *anchor, unsigned long tag) {
    unsigned long start = np_seen_fold(anchor, tag) % NP_SEEN_SLOTS;
    for (unsigned long step = 0; step < NP_SEEN_SLOTS; step++) {
        struct np_seen_slot *slot = &np_seen[(start + step) % NP_SEEN_SLOTS];
        if (slot->filled) {
            if (slot->anchor == anchor && slot->tag == tag)
                return 0; // seen before
            continue;
        }
        slot->anchor = anchor;
        slot->tag    = tag;
        slot->filled = 1;
        return 1; // first time
    }
    if (!np_seen_overflow) {
        np_seen_overflow = 1;
        NP_ERR("log dedupe table exhausted at %d entries; repeat lines now dropped",
               NP_SEEN_SLOTS);
    }
    return 0;
}

static void log_open(int may_rotate) {
    const char *want = getenv("NOTPROTON_LOG_LEVEL");
    if (want && want[0]) {
        int parsed = atoi(want);
        if (parsed >= NP_LVL_ERR && parsed <= NP_LVL_DBG)
            np_log_level = parsed;
    }

    if (np_log_file)
        return;

    const char *home = np_home_dir();
    if (!home)
        home = "/tmp";

    char folder[512];
    char logpath[512];
    np_support_path(folder, sizeof(folder), home, NULL);
    mkdir(folder, 0755);
    snprintf(logpath, sizeof(logpath), "%s/notproton.log", folder);

    struct stat info;
    int oversize = (may_rotate && stat(logpath, &info) == 0
                    && info.st_size > NP_LOG_MAX_BYTES);
    if (oversize) truncate(logpath, 0);
    np_log_file = fopen(logpath, "a");
    if (np_log_file)
        setlinebuf(np_log_file);
}

void np_log_init(void) {
    log_open(1);
}

static pthread_once_t np_attach_once = PTHREAD_ONCE_INIT;

static void log_attach_once(void) {
    log_open(0);
}

void np_log_attach(void) {
    pthread_once(&np_attach_once, log_attach_once);
}
