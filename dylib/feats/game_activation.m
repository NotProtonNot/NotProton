#import <AppKit/AppKit.h>
#include <limits.h>
#include "game_activation.h"
#include "../util/log.h"

static BOOL game_loader_matches(NSString *identity, NSURL *executable, NSURL *launchers) {
    NSString *prefix = @"com.notproton.launcher.";
    if (![identity hasPrefix:prefix] || !executable.isFileURL) return NO;
    NSString *appID = [identity substringFromIndex:prefix.length];
    NSCharacterSet *nonDigits =
        [[NSCharacterSet characterSetWithCharactersInString:@"0123456789"] invertedSet];
    if (!appID.length || [appID rangeOfCharacterFromSet:nonDigits].location != NSNotFound) return NO;

    NSArray<NSString *> *root = launchers.URLByResolvingSymlinksInPath.pathComponents;
    NSArray<NSString *> *path = executable.URLByResolvingSymlinksInPath.pathComponents;
    if (path.count != root.count + 5 ||
        ![[path subarrayWithRange:NSMakeRange(0, root.count)] isEqual:root]) return NO;
    NSUInteger i = root.count;
    return [path[i] isEqual:appID] && [path[i + 1] hasSuffix:@".app"] &&
           [path[i + 2] isEqual:@"Contents"] && [path[i + 3] isEqual:@"MacOS"] &&
           [path[i + 4] isEqual:@"wine"];
}

static void observe_game_activation(NSURL *launchers) {
    NSMutableDictionary<NSNumber *, NSRunningApplication *> *seen = [NSMutableDictionary new];
    [NSDistributedNotificationCenter.defaultCenter
        addObserverForName:@"WineAppWillActivateNotification"
        object:nil queue:NSOperationQueue.mainQueue
        usingBlock:^(NSNotification *note) {
            id value = note.userInfo[@"ActivatingAppPID"];
            if (![value isKindOfClass:NSNumber.class] || [value longLongValue] <= 0 ||
                [value longLongValue] > INT_MAX) return;
            NSRunningApplication *game =
                [NSRunningApplication runningApplicationWithProcessIdentifier:[value intValue]];
            if (!game || game.terminated ||
                !game_loader_matches(game.bundleIdentifier, game.executableURL, launchers)) return;

            for (NSNumber *pid in seen.allKeys) {
                if (seen[pid].terminated) [seen removeObjectForKey:pid];
            }
            NSNumber *pid = @(game.processIdentifier);
            if ([seen[pid] isEqual:game]) return;
            seen[pid] = game;

            // Consume the first request even in the background, so later requests cannot steal focus.
            NSRunningApplication *steam = NSRunningApplication.currentApplication;
            if (!NSApp.active ||
                ![NSWorkspace.sharedWorkspace.frontmostApplication isEqual:steam]) return;
            [NSApp yieldActivationToApplication:game];
            // Wine's activate request can arrive before this asynchronous notification.
            BOOL activated = [game activateFromApplication:steam options:0];
            NP_LOG("[game-mode] activation handoff to pid %d: %s", game.processIdentifier,
                   activated ? "accepted" : "declined");
        }];
}

void np_game_activation_install(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        dispatch_async(dispatch_get_main_queue(), ^{
            NSURL *root = [NSURL fileURLWithPath:[NSHomeDirectory()
                stringByAppendingPathComponent:@"Library/Application Support/notproton/launchers"] isDirectory:YES];
            observe_game_activation(root);
        });
    });
}
