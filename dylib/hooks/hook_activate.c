// Stops Steam from rudely stealing focus
#include "hooks.h"
#include "../util/log.h"

#include <CoreFoundation/CoreFoundation.h>
#include <dispatch/dispatch.h>
#include <dlfcn.h>
#include <mach-o/dyld.h>
#include <string.h>
#include <unistd.h>

typedef void (*fn_did_become_active)(void *self, void *cmd, void *note);

static void *(*np_get_class)(const char *);
static void *(*np_sel)(const char *);
static void *np_msg_send;
static fn_did_become_active orig_did_become_active;
static void *np_watcher;
static int np_menu_bar_lost;
static int np_vgui_seen;

static void *np_msg(void *obj, const char *sel) {
    return ((void *(*)(void *, void *))np_msg_send)(obj, np_sel(sel));
}

static int np_owns_menu_bar(void *workspace) {
    void *owner = np_msg(workspace, "menuBarOwningApplication");
    return owner && ((int (*)(void *, void *))np_msg_send)(owner, np_sel("processIdentifier")) == getpid();
}

static void np_menu_bar_sync(void *workspace) {
    __atomic_store_n(&np_menu_bar_lost, !np_owns_menu_bar(workspace), __ATOMIC_RELEASE);
}

static void np_menu_bar_owner_changed(void *self, void *cmd, void *path, void *workspace,
                                      void *change, void *context) {
    (void)self; (void)cmd; (void)path; (void)change; (void)context;
    if (!np_owns_menu_bar(workspace))
        __atomic_store_n(&np_menu_bar_lost, 1, __ATOMIC_RELEASE);
}

static void np_hook_did_become_active(void *self, void *cmd, void *note) {
    if (!__atomic_exchange_n(&np_menu_bar_lost, 0, __ATOMIC_ACQ_REL)) {
        NP_LOG("[activate] skipped, Steam kept the menu bar so this was a menu bar click");
        return;
    }
    orig_did_become_active(self, cmd, note);
}

static void np_activate_install_main(void *unused) {
    (void)unused;
    void *(*alloc_pair)(void *, const char *, size_t) = dlsym(RTLD_DEFAULT, "objc_allocateClassPair");
    void (*register_pair)(void *) = dlsym(RTLD_DEFAULT, "objc_registerClassPair");
    int (*add_method)(void *, void *, void *, const char *) = dlsym(RTLD_DEFAULT, "class_addMethod");
    void *(*get_method)(void *, void *) = dlsym(RTLD_DEFAULT, "class_getInstanceMethod");
    void *(*set_imp)(void *, void *) = dlsym(RTLD_DEFAULT, "method_setImplementation");
    if (!alloc_pair || !register_pair || !add_method || !get_method || !set_imp) {
        NP_WARN("[activate] objc class functions unavailable, not hooked");
        return;
    }

    void *delegate = np_get_class("VGUIApplicationDelegate");
    void *method = delegate ? get_method(delegate, np_sel("applicationDidBecomeActive:")) : NULL;
    void *ws_cls = np_get_class("NSWorkspace");
    void *workspace = ws_cls ? np_msg(ws_cls, "sharedWorkspace") : NULL;
    if (!method || !workspace) {
        NP_WARN("[activate] VGUIApplicationDelegate or NSWorkspace not found, not hooked");
        return;
    }

    void *watcher_cls = alloc_pair(np_get_class("NSObject"), "NPActivateWatcher", 0);
    if (!watcher_cls) {
        NP_WARN("[activate] cannot create the menu bar watcher, not hooked");
        return;
    }
    add_method(watcher_cls, np_sel("observeValueForKeyPath:ofObject:change:context:"),
               (void *)np_menu_bar_owner_changed, "v@:@@@^v");
    register_pair(watcher_cls);
    np_watcher = np_msg(np_msg(watcher_cls, "alloc"), "init");
    ((void (*)(void *, void *, void *, CFStringRef, unsigned long, void *))np_msg_send)(
        workspace, np_sel("addObserver:forKeyPath:options:context:"), np_watcher,
        CFSTR("menuBarOwningApplication"), 0, NULL);
    np_menu_bar_sync(workspace);

    orig_did_become_active = (fn_did_become_active)set_imp(method, (void *)np_hook_did_become_active);
    NP_LOG("[activate] hooked");
}

static void np_activate_image_added(const struct mach_header *mh, intptr_t slide) {
    (void)slide;
    Dl_info di;
    if (!dladdr(mh, &di) || !di.dli_fname)
        return;
    const char *base = strrchr(di.dli_fname, '/');
    if (strcmp(base ? base + 1 : di.dli_fname, "vgui2_s.dylib") != 0)
        return;
    if (__atomic_exchange_n(&np_vgui_seen, 1, __ATOMIC_ACQ_REL))
        return;
    dispatch_async_f(dispatch_get_main_queue(), NULL, np_activate_install_main);
}

void np_hooks_activate_install(void) {
    if (np_hooks_env_lists_label("NOTPROTON_DISABLE", "activate")) {
        NP_WARN("[activate] DISABLED via NOTPROTON_DISABLE");
        return;
    }

    np_get_class = (void *(*)(const char *))dlsym(RTLD_DEFAULT, "objc_getClass");
    np_sel       = (void *(*)(const char *))dlsym(RTLD_DEFAULT, "sel_registerName");
    np_msg_send  = dlsym(RTLD_DEFAULT, "objc_msgSend");
    if (!np_get_class || !np_sel || !np_msg_send) {
        NP_WARN("[activate] objc runtime unavailable, not hooked");
        return;
    }
    _dyld_register_func_for_add_image(np_activate_image_added);
}
