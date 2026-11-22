#import <AppKit/AppKit.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/runtime.h>
#include <dlfcn.h>
#include <stdint.h>

#include "rounded_windows.h"

// Use the SDL3 already loaded by Steam Helper.
typedef struct SDL_Window SDL_Window;
enum {
    SDL_FULLSCREEN = 0x1,
    SDL_MODAL = 0x1000,
    SDL_ALWAYS_ON_TOP = 0x10000,
    SDL_UTILITY = 0x20000,
    SDL_TOOLTIP = 0x40000,
    SDL_POPUP_MENU = 0x80000,
};
static struct {
    SDL_Window **(*windows)(int *);
    uint32_t (*properties)(SDL_Window *);
    void *(*pointer)(uint32_t, const char *, void *);
    uint64_t (*flags)(SDL_Window *);
    void (*free)(void *);
} sdl;

static BOOL load_sdl(void) {
    sdl.windows = dlsym(RTLD_DEFAULT, "SDL_GetWindows");
    sdl.properties = dlsym(RTLD_DEFAULT, "SDL_GetWindowProperties");
    sdl.pointer = dlsym(RTLD_DEFAULT, "SDL_GetPointerProperty");
    sdl.flags = dlsym(RTLD_DEFAULT, "SDL_GetWindowFlags");
    sdl.free = dlsym(RTLD_DEFAULT, "SDL_free");
    return sdl.windows && sdl.properties && sdl.pointer && sdl.flags && sdl.free;
}

static BOOL is_desktop_sdl_window(NSWindow *window) {
    const uint64_t excluded = SDL_FULLSCREEN | SDL_MODAL | SDL_ALWAYS_ON_TOP |
        SDL_UTILITY | SDL_TOOLTIP | SDL_POPUP_MENU;
    int count = 0;
    SDL_Window **windows = sdl.windows(&count);
    if (!windows)
        return NO;

    BOOL eligible = NO;
    for (int i = 0; i < count; ++i) {
        uint32_t properties = sdl.properties(windows[i]);
        if (properties &&
            sdl.pointer(properties, "SDL.window.cocoa.window", NULL) == (__bridge void *)window) {
            eligible = (sdl.flags(windows[i]) & excluded) == 0;
            break;
        }
    }
    sdl.free(windows);
    return eligible;
}

static BOOL can_round(NSWindow *window) {
    const NSWindowStyleMask excluded = NSWindowStyleMaskTitled | NSWindowStyleMaskFullScreen |
        NSWindowStyleMaskUtilityWindow | NSWindowStyleMaskDocModalWindow | NSWindowStyleMaskNonactivatingPanel;
    return !(window.styleMask & excluded) && window.level == NSNormalWindowLevel &&
        window.isVisible && !window.isMiniaturized && !window.parentWindow && !window.isSheet &&
        ![window isKindOfClass:NSPanel.class] && window.contentView != nil;
}

static char restore_corners_key;

static void update_corners(NSWindow *window) {
    dispatch_block_t restore = objc_getAssociatedObject(window, &restore_corners_key);
    BOOL round = can_round(window) && is_desktop_sdl_window(window);
    if (round == (restore != nil))
        return;

    CALayer *layer = window.contentView.layer;
    if (round && (!layer || layer.mask || layer.cornerRadius != 0))
        return;

    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    if (restore) {
        restore();
        objc_setAssociatedObject(window, &restore_corners_key, nil, OBJC_ASSOCIATION_COPY_NONATOMIC);
    } else {
        __weak NSWindow *weak_window = window;
        NSColor *background = window.backgroundColor;
        BOOL window_opaque = window.opaque;
        BOOL layer_opaque = layer.opaque;
        BOOL clips = layer.masksToBounds;
        CALayerCornerCurve curve = layer.cornerCurve;
        objc_setAssociatedObject(window, &restore_corners_key, ^{
            weak_window.backgroundColor = background;
            weak_window.opaque = window_opaque;
            layer.opaque = layer_opaque;
            layer.masksToBounds = clips;
            layer.cornerCurve = curve;
            layer.cornerRadius = 0;
        }, OBJC_ASSOCIATION_COPY_NONATOMIC);

        // Keep SDL's borderless window and clip only its composited content.
        window.opaque = NO;
        window.backgroundColor = NSColor.clearColor;
        layer.opaque = NO;
        layer.cornerCurve = kCACornerCurveContinuous;
        layer.cornerRadius = 11;
        layer.masksToBounds = YES;
    }
    [CATransaction commit];
    [window invalidateShadow];
}

void np_rounded_windows_install(void) {
    if (!CFPreferencesGetAppBooleanValue(CFSTR("roundSteamWindows"), CFSTR("com.notproton.NotProton"), NULL))
        return;

    dispatch_async(dispatch_get_main_queue(), ^{
        if (!load_sdl())
            return;

        NSNotificationCenter *center = NSNotificationCenter.defaultCenter;
        for (NSNotificationName name in @[NSWindowDidBecomeKeyNotification, NSWindowDidResizeNotification,
                                          NSWindowDidEnterFullScreenNotification, NSWindowDidExitFullScreenNotification]) {
            [center addObserverForName:name object:nil queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *note) {
                NSWindow *window = note.object;
                if (!window.inLiveResize)
                    dispatch_async(dispatch_get_main_queue(), ^{ update_corners(window); });
            }];
        }

        for (NSWindow *window in NSApp.windows)
            update_corners(window);
    });
}
