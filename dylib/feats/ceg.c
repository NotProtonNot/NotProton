// Support for Steam CEG
#include "ceg.h"
#include "../util/a64.h"
#include "../util/file.h"
#include "../util/log.h"
#include "../util/pe.h"
#include "../util/spawn.h"

#include <errno.h>
#include <fcntl.h>
#include <pthread.h>
#include <signal.h>
#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>

extern char **environ;

#ifndef NP_CEG_CALL_TIMEOUT_S
#define NP_CEG_CALL_TIMEOUT_S 300
#endif

#define NP_CEG_EXE_MAX (256u << 20)

static int read_guid(const np_pe_view_t *pe, const char *name, uint8_t out[16]) {
    size_t at;
    uint32_t size;
    if (!np_pe_rcdata(pe, name, &at, &size) || size != 16) return 0;
    memcpy(out, pe->p + at, 16);
    return 1;
}

int np_ceg_guids_from_image(const uint8_t *image, size_t len, np_ceg_guids_t *out) {
    memset(out, 0, sizeof(*out));
    np_pe_view_t pe;
    if (!np_pe_open(&pe, image, len) || !read_guid(&pe, "STEAM_GUIDD", out->drm))
        return -1;
    read_guid(&pe, "STEAM_SPLIT_GUID", out->split);
    read_guid(&pe, "STEAM_MINSTANCE", out->merge);
    return 0;
}

int np_ceg_read_guids(const char *exe, np_ceg_guids_t *out) {
    memset(out, 0, sizeof(*out));
    size_t len = 0;
    uint8_t *image = np_read_file_max(exe, NP_CEG_EXE_MAX, 0, &len);
    if (!image) return -1;
    int rc = np_ceg_guids_from_image(image, len, out);
    free(image);
    return rc;
}

// Steam build 1792618285
static const np_ceg_job_layout_t np_ceg_job_baseline = {
    .appid = 364, .flags = 392, .guids = 424, .path = 472,
};

#define NP_CEG_FLAG_PROTON_BIT 7

int np_ceg_probe_job_layout(const uint32_t *code, size_t count, np_ceg_job_layout_t *out) {
    uint32_t bases = 1u << 0;
    uint32_t appid = 0, flags = 0, path = 0;
    for (size_t i = 0; i < count && !(appid && flags && path); i++) {
        uint32_t w = code[i], rd, rn, rt, off, bit;
        uintptr_t unused;
        if (a64_bl(0, w, &unused) || w == 0xD65F03C0u)
            break;
        if (a64_mov(w, &rd, &rn)) {
            if (bases & (1u << rn)) bases |= 1u << rd;
        } else if (a64_ldrb_uimm(w, &rn, &rt, &off)) {
            if (!flags && (bases & (1u << rn)) && i + 1 < count &&
                a64_tbz(code[i + 1], &rd, &bit) && rd == rt && bit == NP_CEG_FLAG_PROTON_BIT)
                flags = off;
            bases &= ~(1u << rt);
        } else if (a64_ldr_uimm(w, 1, &rn, &rt, &off)) {
            if (!path && (bases & (1u << rn))) path = off;
            bases &= ~(1u << rt);
        } else if (a64_ldr_uimm(w, 0, &rn, &rt, &off)) {
            if (!appid && (bases & (1u << rn))) appid = off;
            bases &= ~(1u << rt);
        }
    }
    if (!appid || !flags || !path) {
        NP_ERR("ceg: ExtractGUIDsFromFile has no appid, flags and path loads "
               "(found %u, %u, %u)", appid, flags, path);
        return -1;
    }

    int32_t shift = (int32_t)path - (int32_t)np_ceg_job_baseline.path;
    if ((int32_t)appid - (int32_t)np_ceg_job_baseline.appid != shift ||
        (int32_t)flags - (int32_t)np_ceg_job_baseline.flags != shift) {
        NP_ERR("ceg: the download job's fields no longer move together (appid %u, "
               "flags %u, path %u)", appid, flags, path);
        return -1;
    }
    out->appid = appid;
    out->flags = flags;
    out->guids = (uint32_t)((int32_t)np_ceg_job_baseline.guids + shift);
    out->path  = path;
    if (shift)
        NP_LOG("ceg: download job fields are %+d from the baseline", shift);
    return 0;
}

typedef struct {
    uint32_t appid;
    char     tool[1024];
    char     install[1024];
    char     library[1024];
} np_ceg_app_t;

#define NP_CEG_APPS 16

static pthread_mutex_t g_lock = PTHREAD_MUTEX_INITIALIZER;
static np_ceg_app_t    g_apps[NP_CEG_APPS];
static unsigned        g_next_app;

static char g_client_dir[1024];

static np_ceg_app_t *slot_for(uint32_t appid) {
    for (int i = 0; i < NP_CEG_APPS; i++) {
        if (g_apps[i].appid == appid) return &g_apps[i];
    }
    np_ceg_app_t *app = &g_apps[g_next_app++ % NP_CEG_APPS];
    memset(app, 0, sizeof(*app));
    app->appid = appid;
    return app;
}

void np_ceg_note_tool(uint32_t appid, const char *tool_dir) {
    if (!appid) return;
    pthread_mutex_lock(&g_lock);
    np_ceg_app_t *app = slot_for(appid);
    snprintf(app->tool, sizeof(app->tool), "%s", tool_dir ? tool_dir : "");
    app->install[0] = app->library[0] = '\0';
    pthread_mutex_unlock(&g_lock);
}

int np_ceg_tool_for_app(uint32_t appid, char *buf, size_t size) {
    int found = 0;
    pthread_mutex_lock(&g_lock);
    for (int i = 0; i < NP_CEG_APPS && !found; i++) {
        if (appid && g_apps[i].appid == appid && g_apps[i].tool[0]) {
            snprintf(buf, size, "%s", g_apps[i].tool);
            found = 1;
        }
    }
    pthread_mutex_unlock(&g_lock);
    return found;
}

int np_ceg_note_app(uint32_t appid, const char *exe) {
    static const char common[] = "/steamapps/common/";
    const char *at = exe ? strstr(exe, common) : NULL;
    if (!at) return -1;
    const char *name = at + sizeof(common) - 1;
    const char *end = strchr(name, '/');
    if (!end || end == name) return -1;

    int ok = 0;
    pthread_mutex_lock(&g_lock);
    for (int i = 0; i < NP_CEG_APPS && !ok; i++) {
        np_ceg_app_t *app = &g_apps[i];
        if (!appid || app->appid != appid || !app->tool[0]) continue;
        snprintf(app->install, sizeof(app->install), "%.*s", (int)(end - exe), exe);
        snprintf(app->library, sizeof(app->library), "%.*s/steamapps", (int)(at - exe), exe);
        ok = 1;
    }
    pthread_mutex_unlock(&g_lock);
    return ok ? 0 : -1;
}

static int find_app(uint32_t appid, np_ceg_app_t *out) {
    int found = 0;
    pthread_mutex_lock(&g_lock);
    for (int i = 0; i < NP_CEG_APPS && !found; i++) {
        if (appid && g_apps[i].appid == appid && g_apps[i].tool[0] && g_apps[i].install[0]) {
            *out = g_apps[i];
            found = 1;
        }
    }
    pthread_mutex_unlock(&g_lock);
    return found;
}

static char **g_env;

static char **copy_environ(void) {
    size_t count = 0;
    while (environ[count]) count++;
    char **copy = calloc(count + 1, sizeof(char *));
    if (!copy) return NULL;
    for (size_t i = 0; i < count; i++) {
        if (!(copy[i] = strdup(environ[i]))) {
            while (i--) free(copy[i]);
            free(copy);
            return NULL;
        }
    }
    return copy;
}

void np_ceg_snapshot_env(void) {
    if (!g_env)
        g_env = copy_environ();
}

void np_ceg_set_service(const char *client_dir) {
    snprintf(g_client_dir, sizeof(g_client_dir), "%s", client_dir ? client_dir : "");
}

static const char *const np_game_identity[] = { "SteamGameId=", "SteamAppId=" };

static int env_has_key(const char *entry, const char *key_eq) {
    return strncmp(entry, key_eq, strlen(key_eq)) == 0;
}

#define NP_RUN_FAILED  (-1)
#define NP_RUN_UNKNOWN (-2)

static pid_t           g_call_pgid;
static pthread_mutex_t g_pgid_lock = PTHREAD_MUTEX_INITIALIZER;
static atomic_int      g_stopping;

static void set_call_pgid(pid_t pgid) {
    pthread_mutex_lock(&g_pgid_lock);
    g_call_pgid = pgid;
    pthread_mutex_unlock(&g_pgid_lock);
}

static pthread_mutex_t g_call_lock   = PTHREAD_MUTEX_INITIALIZER;
static pthread_mutex_t g_active_lock = PTHREAD_MUTEX_INITIALIZER;
static char            g_active_in[1200], g_active_out[1200];

static int reap(pid_t pid, int *status) {
    set_call_pgid(0);
    while (waitpid(pid, status, 0) < 0) {
        if (errno == ECHILD) return NP_RUN_UNKNOWN;
        if (errno != EINTR) return NP_RUN_FAILED;
    }
    return 0;
}

static int wait_for_helper(pid_t pid) {
    set_call_pgid(pid);
    struct timespec now;
    clock_gettime(CLOCK_MONOTONIC, &now);
    time_t deadline = now.tv_sec + NP_CEG_CALL_TIMEOUT_S;
    for (;;) {
        siginfo_t si = { 0 };
        if (waitid(P_PID, (id_t)pid, &si, WEXITED | WNOHANG | WNOWAIT) == 0) {
            if (si.si_pid == pid)
                break;
        } else if (errno == ECHILD) {
            set_call_pgid(0);
            return NP_RUN_UNKNOWN;
        } else if (errno != EINTR) {
            set_call_pgid(0);
            return NP_RUN_FAILED;
        }
        clock_gettime(CLOCK_MONOTONIC, &now);
        int stopping = atomic_load(&g_stopping);
        if (stopping || now.tv_sec > deadline) {
            if (stopping)
                NP_LOG("ceg: Steam is stopping, ending service call group %d", pid);
            else
                NP_ERR("ceg: service call still running after %ds, stopping process group %d",
                       NP_CEG_CALL_TIMEOUT_S, pid);
            kill(-pid, SIGTERM);
            for (int i = 0; i < 50 && !stopping; i++) {
                siginfo_t done = { 0 };
                if (waitid(P_PID, (id_t)pid, &done, WEXITED | WNOHANG | WNOWAIT) == 0 &&
                    done.si_pid == pid)
                    break;
                usleep(100 * 1000);
            }
            kill(-pid, SIGKILL);
            int ignored;
            reap(pid, &ignored);
            return NP_RUN_FAILED;
        }
        usleep(100 * 1000);
    }

    int status = 0;
    int rc = reap(pid, &status);
    if (rc != 0) return rc;
    return WIFEXITED(status) ? WEXITSTATUS(status) : NP_RUN_FAILED;
}

static int run_in_prefix(const np_ceg_app_t *app, char *const argv[]) {
    char vars[8][1100];
    snprintf(vars[0], sizeof(vars[0]), "STEAM_COMPAT_APP_ID=%u", app->appid);
    snprintf(vars[1], sizeof(vars[1]), "STEAM_COMPAT_DATA_PATH=%s/compatdata/%u", app->library, app->appid);
    snprintf(vars[2], sizeof(vars[2]), "STEAM_COMPAT_INSTALL_PATH=%s", app->install);
    snprintf(vars[3], sizeof(vars[3]), "STEAM_COMPAT_CLIENT_INSTALL_PATH=%s", g_client_dir);
    snprintf(vars[4], sizeof(vars[4]), "STEAM_COMPAT_LIBRARY_PATHS=%s", app->library);
    snprintf(vars[5], sizeof(vars[5]), "STEAM_COMPAT_TOOL_PATHS=%s", app->tool);
    snprintf(vars[6], sizeof(vars[6]), "STEAM_COMPAT_PROTON=1");
    snprintf(vars[7], sizeof(vars[7]), "PROTON_HIDE_PROCESS_WINDOW=1");
    const size_t nvars = sizeof(vars) / sizeof(vars[0]);

    if (!g_env) return NP_RUN_FAILED;
    size_t count = 0;
    while (g_env[count]) count++;
    char **envp = calloc(count + nvars + 1, sizeof(char *));
    if (!envp) return NP_RUN_FAILED;
    size_t n = 0;
    for (size_t i = 0; i < count; i++) {
        int drop = 0;
        for (size_t v = 0; v < nvars && !drop; v++) {
            size_t key = (size_t)(strchr(vars[v], '=') - vars[v]) + 1;
            drop = strncmp(g_env[i], vars[v], key) == 0;
        }
        for (size_t k = 0; k < sizeof(np_game_identity) / sizeof(*np_game_identity) && !drop; k++)
            drop = env_has_key(g_env[i], np_game_identity[k]);
        if (!drop) envp[n++] = g_env[i];
    }
    for (size_t v = 0; v < nvars; v++) envp[n++] = vars[v];
    envp[n] = NULL;

    posix_spawn_file_actions_t fa;
    posix_spawn_file_actions_init(&fa);
    // steamservice.exe looks for legacycompat in the directory steamservice was started from
    posix_spawn_file_actions_addchdir_np(&fa, g_client_dir);
    posix_spawn_file_actions_addopen(&fa, STDIN_FILENO, "/dev/null", O_RDONLY, 0);
    posix_spawn_file_actions_addinherit_np(&fa, STDOUT_FILENO);
    posix_spawn_file_actions_addinherit_np(&fa, STDERR_FILENO);

    posix_spawnattr_t attr;
    if (np_spawn_attr_clean(&attr, NP_SPAWN_OWN_GROUP) != 0) {
        posix_spawn_file_actions_destroy(&fa);
        free(envp);
        return NP_RUN_FAILED;
    }

    pid_t pid = 0;
    int rc = posix_spawn(&pid, argv[0], &fa, &attr, argv, envp);
    posix_spawnattr_destroy(&attr);
    posix_spawn_file_actions_destroy(&fa);
    free(envp);
    if (rc != 0) {
        NP_ERR("ceg: cannot start %s: %s", argv[0], strerror(rc));
        return NP_RUN_FAILED;
    }
    return wait_for_helper(pid);
}

static int place_module(const char *dll, const void *module, uint32_t module_size) {
    size_t len = 0;
    uint8_t *have = np_read_file_max(dll, module_size, NP_FILE_NOFOLLOW, &len);
    int same = have && len == module_size && memcmp(have, module, module_size) == 0;
    free(have);
    return same ? 0 : np_write_file_new(dll, module, module_size);
}

uint32_t np_ceg_service_call(const void *module, uint32_t module_size, uint32_t crc,
                             uint32_t appid, uint32_t fn, uint32_t callid,
                             const void *in, uint32_t in_size,
                             uint8_t **out, uint32_t *out_size) {
    uint32_t max_out = *out_size;
    *out = NULL;
    *out_size = 0;

    np_ceg_app_t app;
    if (!find_app(appid, &app)) {
        NP_ERR("ceg: service call for appID %u, which no CEG job set up", appid);
        return NP_CEG_CALL_FAILED;
    }
    if (!g_client_dir[0]) {
        NP_ERR("ceg: service call for appID %u before the service was bound", appid);
        return NP_CEG_CALL_FAILED;
    }

    char legacy[1100], dll[1200], in_path[1200], out_path[1200], exe[1200], run[1200];
    snprintf(legacy, sizeof(legacy), "%s/legacycompat", g_client_dir);
    snprintf(dll, sizeof(dll), "%s/servicecall_%u.dll", legacy, crc);
    snprintf(in_path, sizeof(in_path), "%s/servicecall_%u.in", legacy, callid);
    snprintf(out_path, sizeof(out_path), "%s/servicecall_%u.out", legacy, callid);
    snprintf(exe, sizeof(exe), "%s/SteamService.exe", legacy);
    snprintf(run, sizeof(run), "%s/run", app.tool);

    char a_crc[16], a_fn[16], a_id[16], a_max[16];
    snprintf(a_crc, sizeof(a_crc), "%u", crc);
    snprintf(a_fn, sizeof(a_fn), "%u", fn);
    snprintf(a_id, sizeof(a_id), "%u", callid);
    snprintf(a_max, sizeof(a_max), "%u", max_out);
    char *argv[] = { run, "run", exe, "/runfunc", a_crc, a_fn, a_id, a_max, NULL };

    pthread_mutex_lock(&g_call_lock);

    uint32_t result = NP_CEG_CALL_FAILED;
    struct stat st;
    if (atomic_load(&g_stopping)) {
        NP_WARN("ceg: appID %u: Steam is stopping, call %u not run", appid, callid);
        goto done;
    }
    if (mkdir(legacy, 0755) != 0 && errno != EEXIST) {
        NP_ERR("ceg: cannot create %s: %s", legacy, strerror(errno));
        goto done;
    }
    pthread_mutex_lock(&g_active_lock);
    snprintf(g_active_in, sizeof(g_active_in), "%s", in_path);
    snprintf(g_active_out, sizeof(g_active_out), "%s", out_path);
    pthread_mutex_unlock(&g_active_lock);

    if (place_module(dll, module, module_size) != 0) {
        NP_ERR("ceg: cannot write %s: %s", dll, strerror(errno));
        goto done;
    }
    unlink(out_path);
    if (np_write_file_new(in_path, in, in_size) != 0) {
        NP_ERR("ceg: cannot write %s: %s", in_path, strerror(errno));
        goto done;
    }

    NP_LOG("ceg: appID %u: running module %08x function %u (call %u, %u bytes in, "
           "up to %u out) in the prefix", appid, crc, fn, callid, in_size, max_out);
    int status = run_in_prefix(&app, argv);

    // A killed run can leave servicecall_*.out half written.
    if (status != 0 && status != NP_RUN_UNKNOWN) {
        NP_ERR("ceg: appID %u: call %u did not finish (run exited %d)", appid, callid, status);
        goto done;
    }
    if (lstat(out_path, &st) != 0 || !S_ISREG(st.st_mode)) {
        NP_ERR("ceg: appID %u: call %u wrote no output (run exited %d)", appid, callid, status);
        goto done;
    }
    if ((uint64_t)st.st_size > max_out) {
        NP_ERR("ceg: appID %u: call %u output is %lld bytes, over the %u allowed",
               appid, callid, (long long)st.st_size, max_out);
        result = NP_CEG_CALL_TOO_BIG;
        goto done;
    }
    if (st.st_size > 0) {
        size_t len = 0;
        uint8_t *buf = np_read_file_max(out_path, max_out, NP_FILE_NOFOLLOW, &len);
        if (!buf) {
            NP_ERR("ceg: appID %u: cannot read %s", appid, out_path);
            goto done;
        }
        *out = buf;
        *out_size = (uint32_t)len;
    }
    result = NP_CEG_CALL_OK;
    NP_LOG("ceg: appID %u: call %u returned %u bytes (run exited %d)",
           appid, callid, *out_size, status);

done:
    pthread_mutex_lock(&g_active_lock);
    unlink(in_path);
    unlink(out_path);
    g_active_in[0] = g_active_out[0] = '\0';
    pthread_mutex_unlock(&g_active_lock);
    pthread_mutex_unlock(&g_call_lock);
    return result;
}

void np_ceg_stop(void) {
    atomic_store(&g_stopping, 1);
    pthread_mutex_lock(&g_pgid_lock);
    if (g_call_pgid > 0)
        kill(-g_call_pgid, SIGKILL);
    pthread_mutex_unlock(&g_pgid_lock);
    pthread_mutex_lock(&g_call_lock);
    pthread_mutex_unlock(&g_call_lock);
    pthread_mutex_lock(&g_active_lock);
    if (g_active_in[0]) unlink(g_active_in);
    if (g_active_out[0]) unlink(g_active_out);
    pthread_mutex_unlock(&g_active_lock);
}
