#include <stdio.h>
#include <unistd.h>
#include <objc/runtime.h>
#include <objc/message.h>

int   np_log_level = -1;
FILE *np_log_file  = NULL;

int np_hooks_env_lists_label(const char *var, const char *label) {
    (void)var; (void)label;
    return 0;
}

#include "../hooks/hook_activate.c"

static int failures;
static int handoffs;
static id fake_owner;
static int fake_pid;

static void check(int ok, const char *what) {
    if (!ok) {
        printf("FAIL %s\n", what);
        failures++;
    }
}

static void fake_did_become_active(id self, SEL cmd, id note) {
    handoffs++;
}

static id fake_menu_bar_owner(id self, SEL cmd) { return fake_owner; }
static int fake_process_identifier(id self, SEL cmd) { return fake_pid; }

static id msg(id obj, const char *sel) {
    return ((id (*)(id, SEL))objc_msgSend)(obj, sel_registerName(sel));
}

static Class make_class(const char *name, const char *sel, IMP imp, const char *types) {
    Class cls = objc_allocateClassPair(objc_getClass("NSObject"), name, 0);
    class_addMethod(cls, sel_registerName(sel), imp, types);
    objc_registerClassPair(cls);
    return cls;
}

static void become_active(id delegate) {
    ((void (*)(id, SEL, id))objc_msgSend)(delegate, sel_registerName("applicationDidBecomeActive:"), nil);
}

static void menu_bar_owner(id workspace, id owner, int pid) {
    fake_owner = owner;
    fake_pid = pid;
    ((void (*)(id, SEL, id, id, id, void *))objc_msgSend)(
        (id)np_watcher, sel_registerName("observeValueForKeyPath:ofObject:change:context:"),
        (id)CFSTR("menuBarOwningApplication"), workspace, nil, NULL);
}

static Class mock_ws_cls;
static Class mock_app_cls;
static id fake_workspace_inst;
static id fake_workspace_apps;
static id fake_direct_app;
static fn_running_app saved_orig_running_app;
static void *(*saved_get_class)(const char *);

static id mock_shared_workspace(id self, SEL cmd) {
    return fake_workspace_inst;
}

static id mock_running_applications(id self, SEL cmd) {
    return fake_workspace_apps;
}

static id mock_app_bid(id self, SEL cmd) {
    return (id)objc_getAssociatedObject(self, "bid");
}

static int mock_app_terminated(id self, SEL cmd) {
    id term = objc_getAssociatedObject(self, "term");
    return term ? 1 : 0;
}

static id mock_app_launch_date(id self, SEL cmd) {
    return (id)objc_getAssociatedObject(self, "date");
}

static id create_mock_app(const char *bid, int terminated, double timestamp) {
    id app = msg(msg((id)mock_app_cls, "alloc"), "init");
    if (bid) {
        CFStringRef cf_bid = CFStringCreateWithCString(NULL, bid, kCFStringEncodingUTF8);
        objc_setAssociatedObject(app, "bid", (id)cf_bid, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        CFRelease(cf_bid);
    }
    if (terminated) {
        objc_setAssociatedObject(app, "term", (id)1, OBJC_ASSOCIATION_ASSIGN);
    }
    if (timestamp > 0) {
        Class date_cls = objc_getClass("NSDate");
        id d = ((id (*)(id, SEL, double))objc_msgSend)(
            (id)date_cls, sel_registerName("dateWithTimeIntervalSince1970:"), timestamp);
        objc_setAssociatedObject(app, "date", d, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    return app;
}

static void *test_get_class(const char *name) {
    if (mock_ws_cls && strcmp(name, "NSWorkspace") == 0)
        return (void *)mock_ws_cls;
    return saved_get_class(name);
}

static void *test_orig_running_app(void *self, void *cmd, pid_t pid) {
    if (pid == 10001)
        return (void *)fake_direct_app;
    return saved_orig_running_app ? saved_orig_running_app(self, cmd, pid) : NULL;
}

static int test_proc_listchildpids(pid_t ppid, void *buffer, int buffersize) {
    pid_t *pids = (pid_t *)buffer;
    if (ppid == 20001) {
        pids[0] = 10001;
        return 1;
    }
    if (ppid == 30001) {
        pids[0] = 30002;
        return 1;
    }
    if (ppid == 30002) {
        pids[0] = 10001;
        return 1;
    }
    return 0;
}

int main(void) {
    Class delegate_cls = make_class("VGUIApplicationDelegate", "applicationDidBecomeActive:",
                                    (IMP)fake_did_become_active, "v@:@");
    Class app_cls = make_class("FakeRunningApplication", "processIdentifier",
                               (IMP)fake_process_identifier, "i@:");
    Class ws_cls = make_class("FakeWorkspace", "menuBarOwningApplication",
                              (IMP)fake_menu_bar_owner, "@@:");

    id delegate = msg(msg((id)delegate_cls, "alloc"), "init");
    id app = msg(msg((id)app_cls, "alloc"), "init");
    id workspace = msg(msg((id)ws_cls, "alloc"), "init");

    np_hooks_activate_install();
    np_activate_install_main(NULL);
    check(orig_did_become_active != NULL && np_watcher != NULL,
          "the hook installs on VGUIApplicationDelegate");

    fake_owner = app;
    fake_pid = getpid();
    np_menu_bar_sync(workspace);
    become_active(delegate);
    check(handoffs == 0, "a menu bar click is skipped when Steam already owned the menu bar at install");

    fake_pid = getpid() + 1;
    np_menu_bar_sync(workspace);
    become_active(delegate);
    check(handoffs == 1, "the first activation hands off when another app owned the menu bar at install");

    become_active(delegate);
    check(handoffs == 1, "an activation while Steam kept the menu bar is skipped");

    menu_bar_owner(workspace, app, getpid());
    become_active(delegate);
    check(handoffs == 1, "Steam owning the menu bar again does not count");

    menu_bar_owner(workspace, app, getpid() + 1);
    become_active(delegate);
    check(handoffs == 2, "an activation after another app took the menu bar hands off");

    become_active(delegate);
    check(handoffs == 2, "the next menu bar click is skipped again");

    menu_bar_owner(workspace, nil, 0);
    become_active(delegate);
    check(handoffs == 3, "an activation after nobody owned the menu bar hands off");

    // --- NSRunningApplication Big Picture resume tests ---
    check(orig_running_app != NULL, "runningApplicationWithProcessIdentifier: is hooked");

    Class real_running_app_cls = objc_getClass("NSRunningApplication");
    SEL sel_app_pid = sel_registerName("runningApplicationWithProcessIdentifier:");

    id res_zero = ((id (*)(id, SEL, pid_t))objc_msgSend)((id)real_running_app_cls, sel_app_pid, 0);
    check(res_zero == nil, "runningApplicationWithProcessIdentifier: returns nil for pid 0");

    id res_neg = ((id (*)(id, SEL, pid_t))objc_msgSend)((id)real_running_app_cls, sel_app_pid, -1);
    check(res_neg == nil, "runningApplicationWithProcessIdentifier: returns nil for negative pid");

    fake_direct_app = msg(msg((id)app_cls, "alloc"), "init");
    saved_orig_running_app = orig_running_app;
    orig_running_app = test_orig_running_app;

    id res_direct = ((id (*)(id, SEL, pid_t))objc_msgSend)((id)real_running_app_cls, sel_app_pid, 10001);
    check(res_direct == fake_direct_app, "runningApplicationWithProcessIdentifier: returns direct app");

    np_proc_listchildpids = test_proc_listchildpids;

    id res_child = ((id (*)(id, SEL, pid_t))objc_msgSend)((id)real_running_app_cls, sel_app_pid, 20001);
    check(res_child == fake_direct_app, "runningApplicationWithProcessIdentifier: resolves child process app");

    id res_grandchild = ((id (*)(id, SEL, pid_t))objc_msgSend)((id)real_running_app_cls, sel_app_pid, 30001);
    check(res_grandchild == fake_direct_app, "runningApplicationWithProcessIdentifier: resolves multi-level descendant app");

    id res_none = ((id (*)(id, SEL, pid_t))objc_msgSend)((id)real_running_app_cls, sel_app_pid, 40001);
    check(res_none == nil, "runningApplicationWithProcessIdentifier: returns nil for unrelated process");

    // Setup mock workspace and apps for launcher fallback
    mock_app_cls = objc_allocateClassPair(objc_getClass("NSObject"), "MockLauncherApp", 0);
    class_addMethod(mock_app_cls, sel_registerName("bundleIdentifier"), (IMP)mock_app_bid, "@@:");
    class_addMethod(mock_app_cls, sel_registerName("isTerminated"), (IMP)mock_app_terminated, "c@:");
    class_addMethod(mock_app_cls, sel_registerName("launchDate"), (IMP)mock_app_launch_date, "@@:");
    objc_registerClassPair(mock_app_cls);

    mock_ws_cls = objc_allocateClassPair(objc_getClass("NSObject"), "MockWorkspaceForLauncher", 0);
    class_addMethod(mock_ws_cls, sel_registerName("runningApplications"), (IMP)mock_running_applications, "@@:");
    objc_registerClassPair(mock_ws_cls);
    Class mock_ws_meta = object_getClass((id)mock_ws_cls);
    class_addMethod(mock_ws_meta, sel_registerName("sharedWorkspace"), (IMP)mock_shared_workspace, "@@:");

    fake_workspace_inst = msg(msg((id)mock_ws_cls, "alloc"), "init");

    id mock_finder = create_mock_app("com.apple.Finder", 0, 0);
    id mock_term = create_mock_app("com.notproton.launcher.old", 1, 0);
    id mock_launcher1 = create_mock_app("com.notproton.launcher.game1", 0, 1000.0);
    id mock_launcher2 = create_mock_app("com.notproton.launcher.game2", 0, 2000.0);

    Class array_cls = objc_getClass("NSArray");
    id apps_arr[4] = { mock_finder, mock_term, mock_launcher1, mock_launcher2 };
    fake_workspace_apps = ((id (*)(id, SEL, const id *, unsigned long))objc_msgSend)(
        (id)array_cls, sel_registerName("arrayWithObjects:count:"), apps_arr, 4);

    saved_get_class = np_get_class;
    np_get_class = test_get_class;

    id res_launcher = ((id (*)(id, SEL, pid_t))objc_msgSend)((id)real_running_app_cls, sel_app_pid, 50001);
    check(res_launcher == mock_launcher2, "runningApplicationWithProcessIdentifier: falls back to newest non-terminated launcher app");

    // Clean up test hooks
    np_get_class = saved_get_class;
    orig_running_app = saved_orig_running_app;

    if (failures) {
        printf("==> activatecheck: %d check(s) failed\n", failures);
        return 1;
    }
    printf("==> activatecheck: Steam hands off after losing the menu bar, skips menu bar clicks, and resolves running applications for Big Picture resume\n");
    return 0;
}
