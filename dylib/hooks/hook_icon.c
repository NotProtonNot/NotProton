// Icon logic for non-Steam shortcuts
#include "hooks.h"
#include "../util/log.h"
#include "../util/peicon.h"

#include <dlfcn.h>
#include <limits.h>
#include <pthread.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>

#define NP_ICON_MAX_SIDE 4096

typedef void *(*np_icon_render_fn)(const char *const *path_slot, int size);

static np_icon_render_fn g_render_orig;

typedef struct { double x, y; } np_pt_t;
typedef struct { double w, h; } np_sz_t;
typedef struct { np_pt_t origin; np_sz_t size; } np_rect_t;

typedef void *(*msg_0_t)(void *, void *);
typedef void *(*msg_id_t)(void *, void *, void *);
typedef void *(*msg_bytes_t)(void *, void *, void *, unsigned long, signed char);
typedef void  (*msg_long_t)(void *, void *, long);
typedef void  (*msg_size_t)(void *, void *, np_sz_t);
typedef void  (*msg_draw_t)(void *, void *, np_rect_t, np_rect_t, unsigned long, double);
typedef void *(*msg_rep_t)(void *, void *, unsigned char **, long, long, long, long,
                           signed char, signed char, void *, long, long);

static void *(*np_get_class)(const char *);
static void *(*np_sel)(const char *);
static void  *g_msg_send;
static void  (*np_release)(void *);
static void *(*np_pool_push)(void);
static void  (*np_pool_pop)(void *);
static void  *g_device_rgb;

static pthread_mutex_t g_lock = PTHREAD_MUTEX_INITIALIZER;
static char           *g_cache_path;
static void           *g_cache_ico;
static size_t          g_cache_len;
static long            g_cache_mtime;
static long long       g_cache_size;

static int runtime_ready(void) {
    static int checked;
    static int ok;

    if (checked) return ok;
    checked = 1;

    np_get_class = (void *(*)(const char *))dlsym(RTLD_DEFAULT, "objc_getClass");
    np_sel       = (void *(*)(const char *))dlsym(RTLD_DEFAULT, "sel_registerName");
    g_msg_send   = dlsym(RTLD_DEFAULT, "objc_msgSend");
    np_release   = (void (*)(void *))dlsym(RTLD_DEFAULT, "objc_release");
    np_pool_push = (void *(*)(void))dlsym(RTLD_DEFAULT, "objc_autoreleasePoolPush");
    np_pool_pop  = (void (*)(void *))dlsym(RTLD_DEFAULT, "objc_autoreleasePoolPop");

    void **rgb = (void **)dlsym(RTLD_DEFAULT, "NSDeviceRGBColorSpace");
    if (rgb) g_device_rgb = *rgb;

    ok = np_get_class && np_sel && g_msg_send && np_release &&
         np_pool_push && np_pool_pop && g_device_rgb;
    if (!ok) NP_WARN("icon: AppKit runtime unavailable, leaving icons to Steam");
    return ok;
}

static void *ico_copy_for_path(const char *path, size_t *out_len) {
    struct stat st;
    char unquoted[PATH_MAX];

    if (!path || !*path) return NULL;

    size_t len = strlen(path);
    if (len >= 2 && path[0] == '"' && path[len - 1] == '"') {
        if (len - 2 >= sizeof(unquoted)) return NULL;
        memcpy(unquoted, path + 1, len - 2);
        unquoted[len - 2] = '\0';
        path = unquoted;
    }

    if (stat(path, &st) != 0 || !S_ISREG(st.st_mode)) return NULL;

    pthread_mutex_lock(&g_lock);

    int hit = g_cache_ico && g_cache_path &&
              strcmp(g_cache_path, path) == 0 &&
              g_cache_mtime == (long)st.st_mtime &&
              g_cache_size == (long long)st.st_size;

    if (!hit) {
        pthread_mutex_unlock(&g_lock);

        size_t len = 0;
        void  *ico = np_pe_icon_ico(path, &len);
        if (!ico) return NULL;
        char *dup = strdup(path);
        NP_LOG("icon: read an icon out of '%s'", path);

        pthread_mutex_lock(&g_lock);
        free(g_cache_ico);
        free(g_cache_path);
        g_cache_ico   = ico;
        g_cache_len   = len;
        g_cache_path  = dup;
        g_cache_mtime = (long)st.st_mtime;
        g_cache_size  = (long long)st.st_size;
    }

    void *copy = NULL;
    if (g_cache_len) {
        copy = malloc(g_cache_len);
        if (copy) {
            memcpy(copy, g_cache_ico, g_cache_len);
            *out_len = g_cache_len;
        }
    }
    pthread_mutex_unlock(&g_lock);
    return copy;
}

static void *render(void *bytes, size_t len, int side) {
    void *pool = np_pool_push();

    void *data = ((msg_bytes_t)g_msg_send)(
        np_get_class("NSData"),
        np_sel("dataWithBytesNoCopy:length:freeWhenDone:"),
        bytes, (unsigned long)len, 1);

    if (!data) {
        free(bytes);
        np_pool_pop(pool);
        return NULL;
    }

    void *img = ((msg_id_t)g_msg_send)(
        ((msg_0_t)g_msg_send)(np_get_class("NSImage"), np_sel("alloc")),
        np_sel("initWithData:"), data);
    if (!img) {
        np_pool_pop(pool);
        return NULL;
    }

    void *rep = ((msg_rep_t)g_msg_send)(
        ((msg_0_t)g_msg_send)(np_get_class("NSBitmapImageRep"), np_sel("alloc")),
        np_sel("initWithBitmapDataPlanes:pixelsWide:pixelsHigh:bitsPerSample:"
               "samplesPerPixel:hasAlpha:isPlanar:colorSpaceName:bytesPerRow:"
               "bitsPerPixel:"),
        NULL, side, side, 8, 4, 1, 0, g_device_rgb, 4L * side, 32);

    if (!rep) {
        np_release(img);
        np_pool_pop(pool);
        return NULL;
    }

    void *gc  = np_get_class("NSGraphicsContext");
    void *ctx = ((msg_id_t)g_msg_send)(gc, np_sel("graphicsContextWithBitmapImageRep:"), rep);
    if (!ctx) {
        np_release(img);
        np_release(rep);
        np_pool_pop(pool);
        return NULL;
    }

    ((msg_long_t)g_msg_send)(ctx, np_sel("setImageInterpolation:"), 2);
    ((msg_0_t)g_msg_send)(gc, np_sel("saveGraphicsState"));
    ((msg_id_t)g_msg_send)(gc, np_sel("setCurrentContext:"), ctx);

    np_sz_t   size = { (double)side, (double)side };
    np_rect_t dst  = { { 0.0, 0.0 }, { (double)side, (double)side } };
    np_rect_t src  = { { 0.0, 0.0 }, { 0.0, 0.0 } };

    ((msg_size_t)g_msg_send)(img, np_sel("setSize:"), size);
    ((msg_draw_t)g_msg_send)(img, np_sel("drawInRect:fromRect:operation:fraction:"),
                             dst, src, 1, 1.0);

    ((msg_0_t)g_msg_send)(gc, np_sel("restoreGraphicsState"));

    np_release(img);
    np_pool_pop(pool);
    return rep;
}

static void *np_icon_render(const char *const *path_slot, int side) {
    const char *path = path_slot ? *path_slot : NULL;

    if (side <= 0 || side > NP_ICON_MAX_SIDE || !path || !runtime_ready())
        return g_render_orig ? g_render_orig(path_slot, side) : NULL;

    size_t len   = 0;
    void  *bytes = ico_copy_for_path(path, &len);
    if (!bytes)
        return g_render_orig ? g_render_orig(path_slot, side) : NULL;

    void *rep = render(bytes, len, side);
    if (!rep)
        return g_render_orig ? g_render_orig(path_slot, side) : NULL;

    return rep;
}

static np_patch_entry_t g_hooks[] = {
    {
        .label            = "shortcut-icon",
        .signature        = "steamui::ShortcutIconRender",
        .entry            = (void *)np_icon_render,
        .trampoline       = (void **)&g_render_orig,
        .tolerate_missing = 1,
        .mode             = NP_PATCH_REPLACE,
    },
};

int np_hooks_icon_count(void) {
    return (int)(sizeof(g_hooks) / sizeof(g_hooks[0]));
}

np_patch_entry_t *np_hooks_icon_defs(void) {
    return g_hooks;
}
