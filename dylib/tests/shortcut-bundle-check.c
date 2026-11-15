#define posix_spawn fake_spawn
#include "../hooks/hook_shortcut_bundle.c"

#include <mach-o/dyld.h>

#include <assert.h>

int   np_log_level;
FILE *np_log_file;

static uint32_t updated[16];
static char     fixed[16][24];
static int      updated_count;
static uint64_t create_ret;
static int      create_calls;

const char *np_compat_tool_dir(void) { return "/nonexistent-tool"; }
int np_compat_app_runs_tool(uint32_t appid) { return appid != 1510 && appid != 0x80001510u; }

int fake_spawn(pid_t *pid, const char *path, const posix_spawn_file_actions_t *actions,
               const posix_spawnattr_t *attr, char *const argv[], char *const envp[]) {
    assert(strcmp(path, "/bin/sh") == 0 && strcmp(argv[1], "/nonexistent-tool/run") == 0);
    const char *image = _dyld_get_image_name(0);
    size_t dir = (size_t)(strrchr(image, '/') - image);
    int fix = strcmp(argv[2], "shortcut-fix") == 0;
    assert(fix || strcmp(argv[2], "shortcut-icons") == 0);
    assert(argv[5 + fix] == NULL);
    assert(strlen(argv[4 + fix]) == dir && strncmp(argv[4 + fix], image, dir) == 0);
    if (updated_count < 16) snprintf(fixed[updated_count], sizeof(fixed[0]), "%s", fix ? argv[4] : "");
    short flags = 0;
    sigset_t mask;
    assert(posix_spawnattr_getflags(attr, &flags) == 0 && posix_spawnattr_getsigmask(attr, &mask) == 0);
    assert(flags == (POSIX_SPAWN_SETSIGMASK | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_CLOEXEC_DEFAULT));
    assert(!sigismember(&mask, SIGTERM) && !sigismember(&mask, SIGCHLD));
    if (updated_count < 16) updated[updated_count] = (uint32_t)strtoul(argv[3], NULL, 10);
    updated_count++;
    return ENOENT;
}

static uint64_t fake_create(void *app, uint64_t desktop, uint64_t unused) {
    create_calls++;
    return create_ret;
}

typedef struct {
    np_app_id_fn *vtable;
    uint8_t       pad[NP_APP_KIND_OFF - sizeof(void *)];
    uint32_t      kind;
    uint32_t      id;
} fake_app_t;

static uint32_t fake_id(void *app) { return ((fake_app_t *)app)->id; }
static np_app_id_fn fake_vtable[] = { fake_id };

static uint64_t create(uint32_t id, uint32_t kind, int desktop) {
    fake_app_t app = { .vtable = fake_vtable, .kind = kind, .id = id };
    return np_shortcut_create(&app, (uint64_t)desktop, 0);
}

static void read_count(void *out) {
    *(int *)out = updated_count;
}

static int count(void) {
    int n = 0;
    if (g_queue) dispatch_sync_f(g_queue, &n, read_count);
    return n;
}

int main(void) {
    assert(np_hooks_shortcut_bundle_count() == 1);
    assert(strcmp(np_hooks_shortcut_bundle_defs()[0].signature, "steamui::ShortcutCreate") == 0);
    *(void **)np_hooks_shortcut_bundle_defs()[0].trampoline = (void *)fake_create;

    create_ret = 1;
    np_hooks_shortcut_bundle_bind(NULL);
    assert(create(440, 1, 1) == 1 && !g_queue);

    np_hooks_shortcut_bundle_bind((const struct mach_header_64 *)_dyld_get_image_header(0));
    assert(g_queue);
    create_ret = 0;
    assert(create(440, 1, 1) == 0);
    create_ret = 1;
    assert(create(440, NP_APP_KIND_DLC, 1) == 1);
    assert(create(0, 1, 1) == 1);
    assert(create(1510, 1, 1) == 1);
    assert(create(0x80001510u, 1, 1) == 1);
    assert(count() == 0);

    assert(create(440, 1, 1) == 1);
    assert(create(570, 1, 0) == 1);
    assert(count() == 2);
    assert(updated[0] == 440 && updated[1] == 570);

    assert(create(440, 1, 1) == 1);
    assert(count() == 3);
    assert(updated[2] == 440 && create_calls == 9);
    assert(fixed[0][0] == 0 && fixed[2][0] == 0);

    assert(create(2462597574u, 1, 1) == 1);
    assert(count() == 4);
    assert(updated[3] == 2462597574u && strcmp(fixed[3], "10576776043572494336") == 0);

    printf("shortcut-bundle-check: DLC, native, zero-ID, unbuilt and unbound shortcuts skipped, each create updated in order, non-Steam shortcuts fixed\n");
    return 0;
}
