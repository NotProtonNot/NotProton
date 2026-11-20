#import <AppKit/AppKit.h>
#import <objc/runtime.h>
#include <crt_externs.h>

#include <ApplicationServices/ApplicationServices.h>

static BOOL (*originalPolicy)(id, SEL, NSApplicationActivationPolicy);

static BOOL clientPolicy(id application, SEL selector, NSApplicationActivationPolicy policy) {
    if (policy == NSApplicationActivationPolicyRegular) policy = NSApplicationActivationPolicyAccessory;
    return originalPolicy(application, selector, policy);
}

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
// Libraries loaded into a game (native game Space, overlays) can promote the
// process with TransformProcessType, which skips -setActivationPolicy:. A Wine
// process outside a bundle then gets its own generic "EXE" Dock tile. Keep this
// session's processes accessory; the launcher host owns the only game tile.
static OSStatus clientTransform(const ProcessSerialNumber *process, ProcessApplicationTransformState state) {
    pid_t pid = 0;
    if (state == kProcessTransformToForegroundApplication && getenv("NOTPROTON_GAME_CHANNEL") &&
        process && GetProcessPID(process, &pid) == noErr && pid == getpid())
        return noErr;
    return TransformProcessType(process, state);
}

__attribute__((used, section("__DATA,__interpose")))
static const struct { const void *replacement, *original; } clientInterpose[] = {
    { (const void *)clientTransform, (const void *)TransformProcessType },
};
#pragma clang diagnostic pop

static NSString *processImage(void) {
    // Wine can rewrite its process name after dylib constructors run. Read the
    // launch arguments directly instead of caching an early "wine" identity.
    int argc = *_NSGetArgc();
    char **argv = *_NSGetArgv();
    for (int i = 0; i < argc; ++i) {
        NSString *argument = [NSString stringWithUTF8String:argv[i]];
        if (argument && [argument.pathExtension caseInsensitiveCompare:@"exe"] == NSOrderedSame)
            return argument;
    }
    return NSProcessInfo.processInfo.processName;
}

static void announceClient(BOOL windowed) {
    NSString *channel = NSProcessInfo.processInfo.environment[@"NOTPROTON_GAME_CHANNEL"];
    if (!channel.length) return;
    NSString *image = processImage();
    NSString *executable = [[image stringByReplacingOccurrencesOfString:@"\\" withString:@"/"] lastPathComponent];
    [[NSDistributedNotificationCenter defaultCenter] postNotificationName:channel object:nil
        userInfo:@{@"pid": @(getpid()), @"executable": executable, @"windowed": @(windowed), @"image": image} deliverImmediately:YES];
}

__attribute__((constructor)) static void setupClient(void) {
    @autoreleasepool {
        if (!getenv("NOTPROTON_GAME_CHANNEL")) return;
        // Register before AppKit starts: startup failures may never create a window.
        announceClient(NO);
        // Wine promotes its UI processes to regular apps as windows appear.
        Method method = class_getInstanceMethod(NSApplication.class, @selector(setActivationPolicy:));
        originalPolicy = (void *)method_getImplementation(method);
        method_setImplementation(method, (IMP)clientPolicy);
        dispatch_async(dispatch_get_main_queue(), ^{
            [NSApp setActivationPolicy:NSApplicationActivationPolicyAccessory];
            announceClient(NO);
            NSNotificationCenter *center = NSNotificationCenter.defaultCenter;
            [center addObserverForName:NSApplicationDidFinishLaunchingNotification object:nil
                queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *notification) {
                    [NSApp setActivationPolicy:NSApplicationActivationPolicyAccessory];
                    announceClient(NO);
                }];
            [center addObserverForName:NSWindowDidBecomeKeyNotification object:nil
                queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *notification) {
                    announceClient(YES);
                }];
        });
    }
}
