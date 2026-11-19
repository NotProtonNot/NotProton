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
typedef void *(*fn_running_app)(void *self, void *cmd, pid_t pid);
typedef int (*fn_proc_listchildpids)(pid_t, void *, int);

static void *(*np_get_class)(const char *);
static void *(*np_sel)(const char *);
static void *np_msg_send;
static fn_did_become_active orig_did_become_active;
static fn_running_app orig_running_app;
static fn_proc_listchildpids np_proc_listchildpids;
static void *np_watcher;
static int np_menu_bar_lost;
static int np_vgui_seen;
static int np_running_app_hooked;

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

static void *np_find_descendant_app(void *self, void *cmd, pid_t pid) {
    if (pid <= 1 || !np_proc_listchildpids)
        return NULL;

    pid_t queue[64];
    int head = 0, tail = 0;
    queue[tail++] = pid;

    while (head < tail && tail < 64) {
        pid_t cur = queue[head++];
        pid_t children[32];
        int count = np_proc_listchildpids(cur, children, (int)sizeof(children));
        if (count <= 0)
            continue;
        if (count > 32)
            count = 32;

        for (int i = 0; i < count; i++) {
            pid_t cpid = children[i];
            if (cpid <= 1 || cpid == pid)
                continue;

            void *app = orig_running_app(self, cmd, cpid);
            if (app)
                return app;

            if (tail < 64) {
                int seen = 0;
                for (int j = 0; j < tail; j++) {
                    if (queue[j] == cpid) {
                        seen = 1;
                        break;
                    }
                }
                if (!seen)
                    queue[tail++] = cpid;
            }
        }
    }
    return NULL;
}

static void *np_find_notproton_launcher_app(void) {
    void *ws_cls = np_get_class("NSWorkspace");
    if (!ws_cls)
        return NULL;
    void *workspace = np_msg(ws_cls, "sharedWorkspace");
    if (!workspace)
        return NULL;
    void *apps = np_msg(workspace, "runningApplications");
    if (!apps)
        return NULL;

    unsigned long count = ((unsigned long (*)(void *, void *))np_msg_send)(apps, np_sel("count"));
    void *latest_app = NULL;
    for (unsigned long i = 0; i < count; i++) {
        void *app = ((void *(*)(void *, void *, unsigned long))np_msg_send)(apps, np_sel("objectAtIndex:"), i);
        if (!app)
            continue;

        if (((int (*)(void *, void *))np_msg_send)(app, np_sel("isTerminated")))
            continue;

        void *bid = np_msg(app, "bundleIdentifier");
        if (!bid)
            continue;

        const char *bid_str = ((const char *(*)(void *, void *))np_msg_send)(bid, np_sel("UTF8String"));
        if (bid_str && strncmp(bid_str, "com.notproton.launcher.", 23) == 0) {
            if (latest_app) {
                void *latest_date = np_msg(latest_app, "launchDate");
                void *cur_date = np_msg(app, "launchDate");
                if (latest_date && cur_date) {
                    long cmp = ((long (*)(void *, void *, void *))np_msg_send)(cur_date, np_sel("compare:"), latest_date);
                    if (cmp > 0)
                        latest_app = app;
                    continue;
                }
            }
            latest_app = app;
        }
    }
    return latest_app;
}

static void *np_hook_running_app(void *self, void *cmd, pid_t pid) {
    if (orig_running_app) {
        void *app = orig_running_app(self, cmd, pid);
        if (app)
            return app;
    }

    if (pid <= 1)
        return NULL;

    void *descendant = np_find_descendant_app(self, cmd, pid);
    if (descendant) {
        NP_LOG("[activate] resolved running app from descendant of pid %d", pid);
        return descendant;
    }

    void *launcher = np_find_notproton_launcher_app();
    if (launcher) {
        NP_LOG("[activate] resolved running app from notproton launcher for pid %d", pid);
        return launcher;
    }

    return NULL;
}

static void np_activate_hook_running_app(void) {
    if (__atomic_exchange_n(&np_running_app_hooked, 1, __ATOMIC_ACQ_REL))
        return;

    void *(*get_class_method)(void *, void *) = dlsym(RTLD_DEFAULT, "class_getClassMethod");
    void *(*set_imp)(void *, void *)          = dlsym(RTLD_DEFAULT, "method_setImplementation");
    if (!get_class_method || !set_imp) {
        NP_WARN("[activate] class_getClassMethod or method_setImplementation unavailable");
        return;
    }

    void *app_cls = np_get_class("NSRunningApplication");
    if (!app_cls) {
        NP_WARN("[activate] NSRunningApplication not found");
        return;
    }

    void *method = get_class_method(app_cls, np_sel("runningApplicationWithProcessIdentifier:"));
    if (!method) {
        NP_WARN("[activate] runningApplicationWithProcessIdentifier: not found");
        return;
    }

    orig_running_app = (fn_running_app)set_imp(method, (void *)np_hook_running_app);
    NP_LOG("[activate] NSRunningApplication runningApplicationWithProcessIdentifier: hooked");
}

static void np_activate_install_main(void *unused) {
    (void)unused;
    np_activate_hook_running_app();
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
    np_proc_listchildpids = (fn_proc_listchildpids)dlsym(RTLD_DEFAULT, "proc_listchildpids");
    if (!np_get_class || !np_sel || !np_msg_send) {
        NP_WARN("[activate] objc runtime unavailable, not hooked");
        return;
    }
    np_activate_hook_running_app();
    _dyld_register_func_for_add_image(np_activate_image_added);
}
