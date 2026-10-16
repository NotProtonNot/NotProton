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

    if (failures) {
        printf("==> activatecheck: %d check(s) failed\n", failures);
        return 1;
    }
    printf("==> activatecheck: Steam hands off after losing the menu bar and skips menu bar clicks\n");
    return 0;
}
