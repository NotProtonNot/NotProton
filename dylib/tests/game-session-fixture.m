#import <AppKit/AppKit.h>

int main(int argc, const char **argv) {
    @autoreleasepool {
        if (argc == 3 && strcmp(argv[1], "--quit") == 0) {
            NSRunningApplication *app = [NSRunningApplication runningApplicationWithProcessIdentifier:atoi(argv[2])];
            return app && [app terminate] ? 0 : 1;
        }
        NSString *handoff = NSProcessInfo.processInfo.environment[@"NP_GAME_TEST_HANDOFF"];
        if (handoff.length && !NSProcessInfo.processInfo.environment[@"NP_GAME_TEST_CHILD"]) {
            NSTask *child = [NSTask new];
            child.executableURL = [NSURL fileURLWithPath:handoff];
            child.arguments = [NSProcessInfo.processInfo.arguments subarrayWithRange:NSMakeRange(1, argc - 1)];
            NSMutableDictionary *environment = [NSProcessInfo.processInfo.environment mutableCopy];
            [environment removeObjectForKey:@"NP_GAME_TEST_HANDOFF"];
            child.environment = environment;
            return [child launchAndReturnError:nil] ? 0 : 1;
        }
        if (getenv("NP_GAME_TEST_EARLY_EXIT") && !getenv("NP_GAME_TEST_CHILD")) {
            // No NSApplication, LaunchServices registration, or window at all.
            NSDictionary *state = @{@"pid": @(getpid()), @"policy": @(-1),
                @"arguments": NSProcessInfo.processInfo.arguments,
                @"libraries": NSProcessInfo.processInfo.environment[@"DYLD_INSERT_LIBRARIES"] ?: @""};
            [[NSJSONSerialization dataWithJSONObject:state options:0 error:nil]
                writeToFile:NSProcessInfo.processInfo.environment[@"NP_GAME_TEST_STATE"] atomically:YES];
            for (;;) pause();
        }
        NSApplication *app = NSApplication.sharedApplication;
        [app setActivationPolicy:NSApplicationActivationPolicyRegular];
        NSString *childPath = NSProcessInfo.processInfo.environment[@"NP_GAME_TEST_CHILD"];
        if (childPath.length) {
            // Mimic Wine's bootstrap: the real GUI child can exit while this
            // process remains alive waiting on background helper processes.
            NSTask *child = [NSTask new];
            child.executableURL = [NSURL fileURLWithPath:childPath];
            child.arguments = [NSProcessInfo.processInfo.arguments subarrayWithRange:NSMakeRange(1, argc - 1)];
            NSMutableDictionary *environment = [NSProcessInfo.processInfo.environment mutableCopy];
            [environment removeObjectForKey:@"NP_GAME_TEST_CHILD"];
            child.environment = environment;
            if (![child launchAndReturnError:nil]) return 1;
            [app run];
            return 0;
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            // Repeated promotion must still leave the Wine client off the Dock.
            [app setActivationPolicy:NSApplicationActivationPolicyRegular];
            if (getenv("NP_GAME_TEST_WINDOW")) {
                NSWindow *window = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 240, 100)
                    styleMask:NSWindowStyleMaskTitled backing:NSBackingStoreBuffered defer:NO];
                window.releasedWhenClosed = NO;
                [window makeKeyAndOrderFront:nil];
                [app activateIgnoringOtherApps:YES];
            }
            NSDictionary *state = @{
                @"pid": @(getpid()),
                @"policy": @(app.activationPolicy),
                @"arguments": NSProcessInfo.processInfo.arguments,
                @"libraries": NSProcessInfo.processInfo.environment[@"DYLD_INSERT_LIBRARIES"] ?: @""
            };
            NSData *data = [NSJSONSerialization dataWithJSONObject:state options:0 error:nil];
            [data writeToFile:NSProcessInfo.processInfo.environment[@"NP_GAME_TEST_STATE"] atomically:YES];
        });
        [app run];
    }
    return 0;
}
