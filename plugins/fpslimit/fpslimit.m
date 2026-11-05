#import <QuartzCore/CAMetalLayer.h>
#import <mach/mach_time.h>
#import <pthread.h>
#import <objc/runtime.h>
#import <os/lock.h>
#import <stdlib.h>
#import <stdbool.h>
#import <stdio.h>
#import <string.h>

typedef struct {
    uint64_t last_frame_time;
    uint64_t interval_ticks;
    uint64_t tick_rem;
    uint64_t rem_accum;
    uint64_t fps;
    os_unfair_lock lock;
    bool     initialized;
} layer_pace_state_t;

@interface NPLayerPaceWrapper : NSObject {
@public
    layer_pace_state_t state;
}
@end

@implementation NPLayerPaceWrapper
@end

static const char kPaceKey = 0;
static os_unfair_lock g_wrap_lock = OS_UNFAIR_LOCK_INIT;
static id<CAMetalDrawable> (*orig_nextDrawable)(id, SEL) = NULL;

static uint64_t g_fps = 0;
static uint64_t g_interval_ticks = 0;
static uint64_t g_tick_rem = 0;
static bool g_disable_vsync = false;
static mach_timebase_info_data_t g_timebase;

static inline NPLayerPaceWrapper *get_or_create_wrap(id layer) {
    NPLayerPaceWrapper *wrap = (NPLayerPaceWrapper *)objc_getAssociatedObject(layer, &kPaceKey);
    if (__builtin_expect(wrap != nil, 1)) {
        return wrap;
    }

    os_unfair_lock_lock(&g_wrap_lock);
    wrap = (NPLayerPaceWrapper *)objc_getAssociatedObject(layer, &kPaceKey);
    if (!wrap) {
        wrap = [[NPLayerPaceWrapper alloc] init];
        wrap->state.fps = g_fps;
        wrap->state.interval_ticks = g_interval_ticks;
        wrap->state.tick_rem = g_tick_rem;
        wrap->state.rem_accum = 0;
        wrap->state.lock = OS_UNFAIR_LOCK_INIT;
        wrap->state.initialized = false;
        objc_setAssociatedObject(layer, &kPaceKey, wrap, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        [wrap release];
    }
    os_unfair_lock_unlock(&g_wrap_lock);
    return wrap;
}

static id<CAMetalDrawable> hook_nextDrawable(id self, SEL _cmd) {
    if (g_disable_vsync) {
        CAMetalLayer *layer = (CAMetalLayer *)self;
        if (layer.displaySyncEnabled) {
            layer.displaySyncEnabled = NO;
        }
    }

    if (g_fps == 0) {
        return orig_nextDrawable(self, _cmd);
    }

    // 1. Acquire the drawable from Metal FIRST.
    // Any swapchain or GPU wait time happens here and is absorbed as work.
    id<CAMetalDrawable> drawable = orig_nextDrawable(self, _cmd);
    if (!drawable) {
        return nil;
    }

    NPLayerPaceWrapper *wrap = get_or_create_wrap(self);
    layer_pace_state_t *st = &wrap->state;

    os_unfair_lock_lock(&st->lock);

    uint64_t now = mach_absolute_time();
    if (!st->initialized) {
        st->last_frame_time = now;
        st->initialized = true;
        os_unfair_lock_unlock(&st->lock);
        return drawable;
    }

    // Fractional Bresenham remainder carryover
    st->rem_accum += st->tick_rem;
    uint64_t extra = st->rem_accum / st->fps;
    st->rem_accum %= st->fps;

    uint64_t target = st->last_frame_time + st->interval_ticks + extra;

    // Work-Compensated Check:
    // If the GPU/driver already took longer than the frame interval (now >= target),
    // DO NOT SLEEP. Return immediately so the pipeline never cascades into hitches.
    if (now >= target) {
        st->last_frame_time = now;
        os_unfair_lock_unlock(&st->lock);
        return drawable;
    }

    st->last_frame_time = target;
    os_unfair_lock_unlock(&st->lock);

    // Sleep only the remaining headroom without burning CPU cores in a spin loop
    mach_wait_until(target);

    return drawable;
}

__attribute__((constructor))
static void np_fpslimit_init(void) {
    const char *fps_env = getenv("NOTPROTON_FPS_LIMIT");
    if (!fps_env || !*fps_env || atof(fps_env) <= 1.0) {
        fps_env = getenv("NOTPROTON_ENV_FPS_LIMIT");
    }
    if (!fps_env || !*fps_env || atof(fps_env) <= 1.0) {
        fps_env = getenv("FPS_LIMIT");
    }
    if (!fps_env || !*fps_env) {
        return;
    }

    double fps_val = atof(fps_env);
    if (fps_val <= 0.0) {
        return;
    }

    g_fps = (uint64_t)(fps_val + 0.5);
    if (g_fps == 0) return;

    const char *no_vsync_env = getenv("NOTPROTON_FPS_NO_VSYNC");
    if (!no_vsync_env) no_vsync_env = getenv("NOTPROTON_NO_VSYNC");
    if (!no_vsync_env) no_vsync_env = getenv("NOTPROTON_ENV_FPS_NO_VSYNC");
    if (!no_vsync_env) no_vsync_env = getenv("FPS_NO_VSYNC");
    if (no_vsync_env && (strcmp(no_vsync_env, "1") == 0 || strcmp(no_vsync_env, "true") == 0)) {
        g_disable_vsync = true;
    }
    const char *vsync_off = getenv("NOTPROTON_FPS_VSYNC");
    if (!vsync_off) vsync_off = getenv("FPS_VSYNC");
    if (vsync_off && strcmp(vsync_off, "0") == 0) {
        g_disable_vsync = true;
    }

    mach_timebase_info(&g_timebase);

    uint64_t ticks_per_sec = (1000000000ULL * (uint64_t)g_timebase.denom) / (uint64_t)g_timebase.numer;
    g_interval_ticks = ticks_per_sec / g_fps;
    g_tick_rem = ticks_per_sec % g_fps;

    Class layer_cls = objc_getClass("CAMetalLayer");
    if (layer_cls) {
        Method m = class_getInstanceMethod(layer_cls, sel_registerName("nextDrawable"));
        if (m) {
            orig_nextDrawable = (id<CAMetalDrawable>(*)(id, SEL))method_getImplementation(m);
            method_setImplementation(m, (IMP)hook_nextDrawable);
        }
    }

    fprintf(stderr, "[notproton-fpslimit] Active: target %llu FPS (vsync: %s)\n",
            g_fps, g_disable_vsync ? "disabled" : "enabled");
}
