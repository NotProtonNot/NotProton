#import <AppKit/AppKit.h>
#include <assert.h>

@interface TestRunningApplication : NSObject
@property pid_t processIdentifier;
@property(copy) NSString *bundleIdentifier;
@property(copy) NSURL *executableURL;
@property BOOL terminated;
@property NSUInteger activations;
@property BOOL acceptsActivation;
+ (instancetype)currentApplication;
+ (instancetype)runningApplicationWithProcessIdentifier:(pid_t)pid;
- (BOOL)activateFromApplication:(TestRunningApplication *)source options:(NSApplicationActivationOptions)options;
@end

@interface TestApplication : NSObject
@property BOOL active;
@property NSUInteger yields;
@property(strong) TestRunningApplication *yieldedTo;
- (void)yieldActivationToApplication:(TestRunningApplication *)game;
@end

@interface TestWorkspace : NSObject
@property(strong) TestRunningApplication *frontmostApplication;
+ (instancetype)sharedWorkspace;
@end

static NSMutableDictionary<NSNumber *, TestRunningApplication *> *applications;
static TestRunningApplication *currentApplication;
static TestApplication *testApp;
static TestWorkspace *workspace;

@implementation TestRunningApplication
+ (instancetype)currentApplication { return currentApplication; }
+ (instancetype)runningApplicationWithProcessIdentifier:(pid_t)pid { return applications[@(pid)]; }
- (BOOL)activateFromApplication:(TestRunningApplication *)source options:(NSApplicationActivationOptions)options {
    assert(source == currentApplication);
    assert(testApp.yieldedTo == self);
    assert(options == 0);
    self.activations++;
    return self.acceptsActivation;
}
@end

@implementation TestApplication
- (void)yieldActivationToApplication:(TestRunningApplication *)game {
    self.yields++;
    self.yieldedTo = game;
}
@end

@implementation TestWorkspace
+ (instancetype)sharedWorkspace { return workspace; }
@end

// Deliver notifications locally and record activation calls without changing desktop focus.
#define NSRunningApplication TestRunningApplication
#define NSWorkspace TestWorkspace
#define NSApp testApp
#define NSDistributedNotificationCenter NSNotificationCenter
#import "../feats/game_activation.m"
#undef NSDistributedNotificationCenter
#undef NSApp
#undef NSWorkspace
#undef NSRunningApplication

int np_log_level = -1;
FILE *np_log_file;

static TestRunningApplication *register_game(pid_t pid, NSURL *executable) {
    TestRunningApplication *game = [TestRunningApplication new];
    game.processIdentifier = pid;
    game.bundleIdentifier = @"com.notproton.launcher.42";
    game.executableURL = executable;
    game.acceptsActivation = YES;
    applications[@(pid)] = game;
    return game;
}

static void request_activation(id pid) {
    NSDictionary *info = pid ? @{@"ActivatingAppPID": pid} : @{};
    [NSNotificationCenter.defaultCenter postNotificationName:@"WineAppWillActivateNotification"
                                                      object:nil userInfo:info];
}

static void check_handoff(NSURL *root, NSURL *executable) {
    applications = [NSMutableDictionary new];
    currentApplication = [TestRunningApplication new];
    testApp = [TestApplication new];
    workspace = [TestWorkspace new];
    testApp.active = YES;
    workspace.frontmostApplication = currentApplication;
    observe_game_activation(root);

    TestRunningApplication *game = register_game(101, executable);
    request_activation(nil);
    for (id invalid in @[@"101", @0, @(-1), @((long long)INT_MAX + 1), NSNull.null, @999]) {
        request_activation(invalid);
    }
    assert(testApp.yields == 0);

    request_activation(@101);
    request_activation(@101);
    assert(game.activations == 1 && testApp.yields == 1);

    TestRunningApplication *background = register_game(102, executable);
    testApp.active = NO;
    request_activation(@102);
    testApp.active = YES;
    request_activation(@102);
    assert(background.activations == 0);

    TestRunningApplication *otherForeground = register_game(103, executable);
    workspace.frontmostApplication = otherForeground;
    request_activation(@103);
    workspace.frontmostApplication = currentApplication;
    request_activation(@103);
    assert(otherForeground.activations == 0);

    TestRunningApplication *helper = register_game(104, executable);
    helper.executableURL = [executable.URLByDeletingLastPathComponent URLByAppendingPathComponent:@"launcher"];
    request_activation(@104);
    assert(helper.activations == 0);

    TestRunningApplication *terminated = register_game(105, executable);
    terminated.terminated = YES;
    request_activation(@105);
    assert(terminated.activations == 0);

    // A recycled PID must not inherit a previous process's consumed request.
    TestRunningApplication *replacement = register_game(101, executable);
    request_activation(@101);
    assert(replacement.activations == 1);

    TestRunningApplication *declined = register_game(106, executable);
    declined.acceptsActivation = NO;
    request_activation(@106);
    request_activation(@106);
    assert(declined.activations == 1);
    assert(testApp.yields == 3);
}

static void check(BOOL expected, NSString *identity, NSString *path, NSURL *root) {
    BOOL actual = game_loader_matches(identity, [NSURL fileURLWithPath:path], root);
    if (actual != expected) {
        fprintf(stderr, "FAIL activation eligibility for %s at %s\n",
                identity.UTF8String, path.UTF8String);
        exit(1);
    }
}

int main(void) {
    @autoreleasepool {
        NSString *folder = [NSTemporaryDirectory() stringByAppendingPathComponent:NSUUID.UUID.UUIDString];
        NSFileManager *files = NSFileManager.defaultManager;
        [files createDirectoryAtPath:folder withIntermediateDirectories:YES attributes:nil error:NULL];
        NSURL *root = [NSURL fileURLWithPath:folder isDirectory:YES];
        NSString *game = [folder stringByAppendingPathComponent:@"42/Game Name.app/Contents/MacOS/wine"];
        NSString *identity = @"com.notproton.launcher.42";
        check(YES, identity, game, root);
        for (NSString *wrong in @[@"com.notproton.launcher.43", @"com.notproton.launcher.",
                                  @"com.notproton.launcher.-42", @"com.notproton.launcher.４２",
                                  @"com.notproton.launcher.42.helper", @"org.winehq.wine"]) {
            check(NO, wrong, game, root);
        }
        for (NSString *tail in @[@"42/Game Name.app/Contents/MacOS/launcher",
                                 @"42/Game Name.app/Contents/MacOS/wineserver",
                                 @"42/Game Name/Contents/MacOS/wine",
                                 @"42/Other/Game Name.app/Contents/MacOS/wine",
                                 @"43/Game Name.app/Contents/MacOS/wine"]) {
            check(NO, identity, [folder stringByAppendingPathComponent:tail], root);
        }
        check(NO, identity, [folder stringByAppendingString:@"-other/42/Game.app/Contents/MacOS/wine"], root);
        check(NO, nil, game, root);
        if (game_loader_matches(identity, [NSURL URLWithString:@"https://example.com/wine"], root)) return 1;

        check_handoff(root, [NSURL fileURLWithPath:game]);

        NSString *outside = [folder stringByAppendingPathComponent:@"runner"];
        [@"" writeToFile:outside atomically:YES encoding:NSUTF8StringEncoding error:NULL];
        [files createDirectoryAtPath:game.stringByDeletingLastPathComponent
            withIntermediateDirectories:YES attributes:nil error:NULL];
        [files createSymbolicLinkAtPath:game withDestinationPath:outside error:NULL];
        check(NO, identity, game, root);
        [files removeItemAtPath:folder error:NULL];
        puts("==> game activation: identity, paths, focus ownership, one-shot handoff and PID reuse hold");
    }
}
