#import <QuartzCore/CAMetalLayer.h>
#import <mach/mach_time.h>
#import <pthread.h>
#import <objc/runtime.h>
#import <os/lock.h>
#import <stdlib.h>
#import <stdbool.h>
#import <stdio.h>
#import <string.h>

#if defined(__arm64__) || defined(__aarch64__)
  #define CPU_YIELD() __builtin_arm_yield()
#else
  #include <immintrin.h>
  #define CPU_YIELD() _mm_pause()
#endif

typedef struct {
    uint64_t next_target;
    uint64_t interval_ticks;
    uint64_t spin_margin_ticks;
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
static id<CAMetalDrawable> (*orig_nextDrawable)(id, SEL) = NULL;
static void (*orig_present)(id, SEL) = NULL;

static uint64_t g_fps = 0;
static uint64_t g_interval_ticks = 0;
static uint64_t g_tick_rem = 0;
static uint64_t g_spin_margin_ticks = 0;
static CFTimeInterval g_target_duration = 0.0;
static bool g_disable_vsync = false;
static mach_timebase_info_data_t g_timebase;

static inline void pace_frame(layer_pace_state_t *st) {
    static _Thread_local bool s_qos_set = false;
    if (!s_qos_set) {
        pthread_set_qos_class_self_np(QOS_CLASS_USER_INTERACTIVE, 0);
        s_qos_set = true;
    }

    os_unfair_lock_lock(&st->lock);

    uint64_t now = mach_absolute_time();
    if (!st->initialized) {
        st->next_target = now;
        st->initialized = true;
        os_unfair_lock_unlock(&st->lock);
        return;
    }

    // Exact Bresenham clock remainder carryover
    st->rem_accum += st->tick_rem;
    uint64_t extra = st->rem_accum / st->fps;
    st->rem_accum %= st->fps;

    uint64_t target = st->next_target + st->interval_ticks + extra;

    // Only reset cadence if missed by more than a full frame (true lag spike / window pause)
    if (now >= target + st->interval_ticks) {
        st->next_target = now;
        os_unfair_lock_unlock(&st->lock);
        return;
    }

    st->next_target = target;
    os_unfair_lock_unlock(&st->lock);

    // Hybrid sleep: kernel wait until spin margin, then spin-yield for microsecond precision
    if (now < target) {
        if (target > now + st->spin_margin_ticks) {
            mach_wait_until(target - st->spin_margin_ticks);
        }

        while (mach_absolute_time() < target) {
            CPU_YIELD();
        }
    }
}

static void hook_present(id self, SEL _cmd) {
    static _Thread_local bool s_in_present = false;
    if (s_in_present) {
        if (orig_present) orig_present(self, _cmd);
        return;
    }

    s_in_present = true;
    if (g_target_duration > 0.0) {
        [(id<CAMetalDrawable>)self presentAfterMinimumDuration:g_target_duration];
        s_in_present = false;
        return;
    }

    if (orig_present) {
        orig_present(self, _cmd);
    }
    s_in_present = false;
}

static void ensure_drawable_swizzled(Class d_cls) {
    static os_unfair_lock swizzle_lock = OS_UNFAIR_LOCK_INIT;
    static Class swizzled_class = nil;
    if (!d_cls || swizzled_class == d_cls) return;

    os_unfair_lock_lock(&swizzle_lock);
    if (swizzled_class != d_cls) {
        Method m = class_getInstanceMethod(d_cls, sel_registerName("present"));
        if (m) {
            orig_present = (void (*)(id, SEL))method_getImplementation(m);
            method_setImplementation(m, (IMP)hook_present);
            fprintf(stderr, "[notproton-fpslimit] Swizzled [%s present] -> presentAfterMinimumDuration (%.4fs)\n",
                    class_getName(d_cls), g_target_duration);
        }
        swizzled_class = d_cls;
    }
    os_unfair_lock_unlock(&swizzle_lock);
}

static id<CAMetalDrawable> hook_nextDrawable(id self, SEL _cmd) {
    if (g_disable_vsync) {
        CAMetalLayer *layer = (CAMetalLayer *)self;
        if (layer.displaySyncEnabled) {
            layer.displaySyncEnabled = NO;
        }
    }

    id<CAMetalDrawable> drawable = orig_nextDrawable(self, _cmd);

    if (!drawable || g_fps == 0) {
        return drawable;
    }

    ensure_drawable_swizzled(object_getClass(drawable));

    NPLayerPaceWrapper *wrap = (NPLayerPaceWrapper *)objc_getAssociatedObject(self, &kPaceKey);
    if (!wrap) {
        wrap = [[NPLayerPaceWrapper alloc] init];
        wrap->state.fps = g_fps;
        wrap->state.interval_ticks = g_interval_ticks;
        wrap->state.tick_rem = g_tick_rem;
        wrap->state.spin_margin_ticks = g_spin_margin_ticks;
        wrap->state.lock = OS_UNFAIR_LOCK_INIT;
        wrap->state.initialized = false;
        objc_setAssociatedObject(self, &kPaceKey, wrap, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        [wrap release];
    }

    pace_frame(&wrap->state);
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

    // Safety margin of 2ms prevents clock jitter from missing a vblank multiple
    CFTimeInterval base_duration = 1.0 / (double)g_fps;
    CFTimeInterval margin = 0.002;
    g_target_duration = (base_duration > margin + 0.002) ? (base_duration - margin) : base_duration;

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

    // 0.75ms spin margin in Mach ticks for extra stability
    g_spin_margin_ticks = (750000ULL * (uint64_t)g_timebase.denom) / (uint64_t)g_timebase.numer;

    Class layer_cls = objc_getClass("CAMetalLayer");
    if (layer_cls) {
        Method m = class_getInstanceMethod(layer_cls, sel_registerName("nextDrawable"));
        if (m) {
            orig_nextDrawable = (id<CAMetalDrawable>(*)(id, SEL))method_getImplementation(m);
            method_setImplementation(m, (IMP)hook_nextDrawable);
        }
    }

    Class d_cls = objc_getClass("CAMetalDrawable");
    if (d_cls) {
        ensure_drawable_swizzled(d_cls);
    }

    fprintf(stderr, "[notproton-fpslimit] Active: target %llu FPS (cadence: %.4fs, vsync: %s)\n",
            g_fps, g_target_duration, g_disable_vsync ? "disabled" : "enabled");
}
