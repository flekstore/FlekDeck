#import "LCSharedUtils.h"
#import "FoundationPrivate.h"
#import "UIKitPrivate.h"
#import "utils.h"
#import <dlfcn.h>
@import MachO;
#include <notify.h>
#include <stdio.h>
#include <sys/stdio.h>
#include <sys/clonefile.h>
#include <sys/stat.h>
#include <sys/xattr.h>

extern NSUserDefaults *lcUserDefaults;
extern NSString *lcAppUrlScheme;
extern NSBundle *lcMainBundle;

// What startBuiltInVPN uses of NetworkExtension. The framework is reached by
// name rather than linked: this code is loaded into every guest, and only the
// launch of one that needs JIT has any use for it.
@interface LCVPNConnection : NSObject
// An NEVPNStatus: 2 is connecting, 3 connected, 4 reasserting.
@property(readonly) NSInteger status;
- (BOOL)startVPNTunnelAndReturnError:(NSError **)error;
@end
@interface LCVPNManager : NSObject
@property(getter=isEnabled) BOOL enabled;
@property(readonly) LCVPNConnection *connection;
+ (void)loadAllFromPreferencesWithCompletionHandler:(void (^)(NSArray *managers, NSError *error))completionHandler;
- (void)saveToPreferencesWithCompletionHandler:(void (^)(NSError *error))completionHandler;
- (void)loadFromPreferencesWithCompletionHandler:(void (^)(NSError *error))completionHandler;
@end

NSString* FBSOpenApplicationOptionKeyActivateAsClassic = @"__ActivateAsClassic";
NSString* FBSOpenApplicationOptionKeyPayloadURL = @"__PayloadURL";

@implementation LCSharedUtils

+ (NSString*) teamIdentifier {
    static NSString* ans = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
#if !TARGET_OS_SIMULATOR
        void* taskSelf = SecTaskCreateFromSelf(NULL);
        CFErrorRef error = NULL;
        CFTypeRef cfans = SecTaskCopyValueForEntitlement(taskSelf, CFSTR("com.apple.developer.team-identifier"), &error);
        // NULL where the signature has no team: CFGetTypeID would trap on it.
        if(cfans && CFGetTypeID(cfans) == CFStringGetTypeID()) {
            ans = (__bridge NSString*)cfans;
        }
        CFRelease(taskSelf);
#endif
        if(!ans) {
            // the above seems not to work if the device is jailbroken by Palera1n, so we use the public api one as backup
            // https://stackoverflow.com/a/11841898
            // Named for this process. A guest comes here as it starts (in the
            // simulator, always), and two starting together, as a pair opening
            // in Split View, shared one item: one added it, the other's add
            // failed as a duplicate, and that guest was left with no team.
            NSString *tempAccountName = [NSString stringWithFormat:@"bundleSeedID.%d", getpid()];
            NSDictionary *query = @{
                (__bridge NSString *)kSecClass : (__bridge NSString *)kSecClassGenericPassword,
                (__bridge NSString *)kSecAttrAccount : tempAccountName,
                (__bridge NSString *)kSecAttrService : @"",
                (__bridge NSString *)kSecReturnAttributes: (__bridge NSNumber *)kCFBooleanTrue,
            };
            CFDictionaryRef result = nil;
            OSStatus status = SecItemCopyMatching((__bridge CFDictionaryRef)query, (CFTypeRef *)&result);
            if (status == errSecItemNotFound)
                status = SecItemAdd((__bridge CFDictionaryRef)query, (CFTypeRef *)&result);
            if (status == errSecSuccess) {
                status = SecItemDelete((__bridge CFDictionaryRef)query); // remove temp item
                NSDictionary *dict = (__bridge_transfer NSDictionary *)result;
                NSString *accessGroup = dict[(__bridge NSString *)kSecAttrAccessGroup];
                NSArray *components = [accessGroup componentsSeparatedByString:@"."];
                NSString *bundleSeedID = [[components objectEnumerator] nextObject];
                ans = bundleSeedID;
            }
        }
    });
    return ans;
}

+ (NSString *)appGroupID {
    static dispatch_once_t once;
    static NSString *appGroupID = @"Unknown";
    dispatch_once(&once, ^{
        NSArray* possibleAppGroups = @[
            [@"group.com.SideStore.SideStore." stringByAppendingString:[self teamIdentifier]],
            [@"group.com.rileytestut.AltStore." stringByAppendingString:[self teamIdentifier]]
        ];
        
        // we prefer app groups with "Apps" in it, which indicate this app group is actually used by the store.
        for (NSString *group in possibleAppGroups) {
            NSURL *path = [NSFileManager.defaultManager containerURLForSecurityApplicationGroupIdentifier:group];
            if(!path) {
                continue;
            }
            NSURL *bundlePath = [path URLByAppendingPathComponent:@"Apps"];
            if ([NSFileManager.defaultManager fileExistsAtPath:bundlePath.path]) {
                // This will fail if LiveContainer is installed in both stores, but it should never be the case
                appGroupID = group;
                return;
            }
        }
        
        // if no "Apps" is found, we choose a valid group
        for (NSString *group in possibleAppGroups) {
            NSURL *path = [NSFileManager.defaultManager containerURLForSecurityApplicationGroupIdentifier:group];
            if(!path) {
                continue;
            }
            appGroupID = group;
            return;
        }
        
        // if no possibleAppGroup is found, we detect app group from entitlement file
        // Cache app group after importing cert so we don't have to analyze executable every launch
        NSString *cached = [lcUserDefaults objectForKey:@"LCAppGroupID"];
        if (cached && [NSFileManager.defaultManager containerURLForSecurityApplicationGroupIdentifier:cached]) {
            appGroupID = cached;
            return;
        }
        CFErrorRef error = NULL;
        void* taskSelf = SecTaskCreateFromSelf(NULL);
        CFTypeRef value = SecTaskCopyValueForEntitlement(taskSelf, CFSTR("com.apple.security.application-groups"), &error);
        CFRelease(taskSelf);
        
        if(!value) {
            return;
        }
        NSArray* appGroups = (__bridge NSArray *)value;
        if(appGroups.count > 0) {
            appGroupID = [appGroups firstObject];
        }
    });
    return appGroupID;
}

+ (NSURL*) appGroupPath {
    static NSURL *appGroupPath = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        appGroupPath = [NSFileManager.defaultManager containerURLForSecurityApplicationGroupIdentifier:[LCSharedUtils appGroupID]];
    });
    return appGroupPath;
}

// Where the share extension parks a file it is handing over to be installed.
// It cannot hand over the file it was given: that URL is reachable only from
// the extension -- it is either a file provider's, which only the extension
// holds a scope for, or a copy iOS made inside the extension's own container,
// and the extension is torn down the moment it opens the install URL. The app
// group is the one place both processes can read, so the file is copied here
// and LiveContainer installs from -- and then removes -- the copy.
//
// nil when there is no app group, which leaves the extension to hand over the
// original URL as it did before.
+ (NSURL*) shareInboxPath {
    NSURL* appGroupPath = [self appGroupPath];
    if(!appGroupPath) {
        return nil;
    }
    return [appGroupPath URLByAppendingPathComponent:@"LiveContainer/ShareInbox"];
}

+ (NSString *)certificatePassword {
    NSUserDefaults* nud = NSUserDefaults.lcSharedDefaults ?: NSUserDefaults.standardUserDefaults;
    return [nud objectForKey:@"LCCertificatePassword"];
}

+ (void)requestGuestFlush {
    notify_post(LCGuestFlushNotification);
}

+ (BOOL)launchToGuestAppWithClassicMode:(NSUInteger)classicMode {
    void (^completionHandler)(BOOL) = ^(BOOL success) {
        // syscall(SYS_ptrace, PT_DENY_ATTACH, 0, 0, 0);
        __asm__ __volatile__ (
                              "mov x0, #31\n"
                              "mov x16, #26\n"
                              "svc #0x80"
                              );
        raise(SIGKILL);
    };
    
    if (!self.certificatePassword) {
        NSString *urlScheme = nil;
        NSString *tsPath = [NSString stringWithFormat:@"%@/../_TrollStore", NSBundle.mainBundle.bundlePath];
        if (!access(tsPath.UTF8String, F_OK)) {
            urlScheme = @"apple-magnifier://enable-jit?bundle-id=%@";
        }
        
        if(urlScheme) {
            NSURL *launchURL = [NSURL URLWithString:[NSString stringWithFormat:urlScheme, NSBundle.mainBundle.bundleIdentifier]];
            UIApplication *application = [NSClassFromString(@"UIApplication") sharedApplication];
            [application openURL:launchURL options:@{} completionHandler:completionHandler];
            return YES;
        }
    }

    int tries = 2;
    _LSOpenConfiguration *configuration = [[PrivClass(_LSOpenConfiguration) alloc] init];
    if(classicMode) {
        NSMutableDictionary* dict = [NSMutableDictionary new];
        dict[FBSOpenApplicationOptionKeyActivateAsClassic] = @(classicMode);
        configuration.frontBoardOptions = dict;
    }
    LSApplicationWorkspace* workspace = [PrivClass(LSApplicationWorkspace) defaultWorkspace];
    
    for (int i = 0; i < tries; i++) {
        [workspace openApplicationWithBundleIdentifier:NSUserDefaults.lcMainBundle.bundleIdentifier
                                         configuration:configuration
                                     completionHandler:^(BOOL success, NSError* error) {
            NSLog(@"success=%d error=%@", success, error);
            completionHandler(success);
        }];
    }
    return YES;
}

// Adds a launch of the app in folder `bundleName` to the history FlekDeck's
// Apps widget orders its Most Used apps by. FlekDeck records the launches it
// starts itself (WidgetLaunchHistory in WidgetAppList.swift, which this must
// match: same file, Unix times, 60 days, 100 per app, a minute between two);
// this covers a running app switching to another, which FlekDeck never sees.
+ (void)recordWidgetLaunchOfApp:(NSString *)bundleName {
    // Only in FlekDeck's own process, whose bundle ID the history is filed under.
    if(NSUserDefaults.isLiveProcess) {
        return;
    }
    NSURL *groupPath = [self appGroupPath];
    NSString *appBundleID = NSUserDefaults.lcMainBundle.bundleIdentifier;
    if(!groupPath || !appBundleID) {
        return;
    }
    NSURL *folder = [[groupPath URLByAppendingPathComponent:@"LiveContainer/Widget"] URLByAppendingPathComponent:appBundleID];
    NSURL *historyURL = [folder URLByAppendingPathComponent:@"Launches.json"];

    NSMutableDictionary *launches = [NSMutableDictionary new];
    NSData *data = [NSData dataWithContentsOfURL:historyURL];
    id saved = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
    if([saved isKindOfClass:NSDictionary.class]) {
        [launches addEntriesFromDictionary:saved];
    }

    NSTimeInterval now = NSDate.date.timeIntervalSince1970;
    NSMutableArray<NSNumber *> *times = [NSMutableArray new];
    id savedTimes = launches[bundleName];
    for(id time in [savedTimes isKindOfClass:NSArray.class] ? savedTimes : @[]) {
        if([time isKindOfClass:NSNumber.class] && now - [time doubleValue] < 60 * 24 * 60 * 60) {
            [times addObject:time];
        }
    }
    if(times.count > 0 && now - times.lastObject.doubleValue < 60) {
        return;
    }
    [times addObject:@(now)];
    if(times.count > 100) {
        [times removeObjectsInRange:NSMakeRange(0, times.count - 100)];
    }
    launches[bundleName] = times;

    NSData *newData = [NSJSONSerialization dataWithJSONObject:launches options:0 error:nil];
    [NSFileManager.defaultManager createDirectoryAtURL:folder withIntermediateDirectories:YES attributes:nil error:nil];
    [newData writeToURL:historyURL atomically:YES];
}

+ (BOOL)launchToGuestAppWithURL:(NSURL *)url {
    NSURLComponents* components = [NSURLComponents componentsWithURL:url resolvingAgainstBaseURL:NO];
    if(![components.host isEqualToString:@"livecontainer-launch"]) return NO;

    NSString* launchBundleId = nil;
    NSString* openUrl = nil;
    NSString* containerFolderName = nil;
    for (NSURLQueryItem* queryItem in components.queryItems) {
        if ([queryItem.name isEqualToString:@"bundle-name"]) {
            launchBundleId = queryItem.value;
        } else if ([queryItem.name isEqualToString:@"open-url"]){
            NSData *decodedData = [[NSData alloc] initWithBase64EncodedString:queryItem.value options:0];
            openUrl = [[NSString alloc] initWithData:decodedData encoding:NSUTF8StringEncoding];
        } else if ([queryItem.name isEqualToString:@"container-folder-name"]) {
            containerFolderName = queryItem.value;
        }
    }
    if(launchBundleId) {
        if (openUrl) {
            [lcUserDefaults setObject:openUrl forKey:@"launchAppUrlScheme"];
        }
        [self recordWidgetLaunchOfApp:launchBundleId];
        
        // Attempt to restart LiveContainer with the selected guest app
        [lcUserDefaults setObject:launchBundleId forKey:@"selected"];
        [lcUserDefaults setObject:containerFolderName forKey:@"selectedContainer"];
        bool isSharedApp = false;
        NSBundle *appBundle = [self findBundleWithBundleId:launchBundleId isSharedAppOut:&isSharedApp];
        NSDictionary *appInfo = [NSDictionary dictionaryWithContentsOfFile:
            [appBundle.bundlePath stringByAppendingPathComponent:@"LCAppInfo.plist"]];
        NSUInteger classicMode = [appInfo[@"classicMode"] boolValue]
            ? [appInfo[@"LCClassicModeCache"][@"defaultClassicMode"] unsignedIntegerValue]
            : 0;
        return [self launchToGuestAppWithClassicMode:classicMode];
    }
    
    return NO;
}

+ (void)setWebPageUrlForNextLaunch:(NSString*) urlString {
    [lcUserDefaults setObject:urlString forKey:@"webPageToOpen"];
}

+ (NSURL*)containerLockPath {
    static dispatch_once_t once;
    static NSURL *infoPath;
    
    dispatch_once(&once, ^{
        infoPath = [[LCSharedUtils appGroupPath] URLByAppendingPathComponent:@"LiveContainer/containerLock.plist"];
    });
    return infoPath;
}

+ (BOOL)isLCSchemeInUse:(NSString*)lc {
    NSURL* infoPath = [self containerLockPath];
    NSMutableDictionary *info = [NSMutableDictionary dictionaryWithContentsOfFile:infoPath.path];
    if (!info) {
        return NO;
    }
    
    NSNumber* num57 = info[lc];
    if(![num57 isKindOfClass:NSNumber.class]) {
        return NO;
    }
    
    uint64_t val57 = [num57 longLongValue];
    audit_token_t token;
    token.val[5] = val57 >> 32;
    token.val[7] = val57 & 0xffffffff;
    
    errno = 0;
    csops_audittoken(token.val[5], 0, NULL, 0, &token);
    return errno != ESRCH;
}

+ (NSString*)getContainerUsingLCSchemeWithFolderName:(NSString*)folderName {
    NSURL* infoPath = [self containerLockPath];
    NSMutableDictionary *info = [NSMutableDictionary dictionaryWithContentsOfFile:infoPath.path];
    if (!info) {
        return nil;
    }
    
    NSDictionary* appUsageInfo = info[folderName];
    if (!appUsageInfo) {
        return nil;
    }
    uint64_t val57 = [appUsageInfo[@"auditToken57"] longLongValue];
    audit_token_t token;
    token.val[5] = val57 >> 32;
    token.val[7] = val57 & 0xffffffff;
    
    errno = 0;
    csops_audittoken(token.val[5], 0, NULL, 0, &token);
    return errno==ESRCH ? nil : appUsageInfo[@"runningLC"];
}

// lc can be something like flekdeck or flekdeck2.liveprocess, such that one LC can jump to another LC hosting the multitask app when user presses run while it's running
+ (void)setContainerUsingByLC:(NSString*)lc folderName:(NSString*)folderName auditToken:(uint64_t)val57 {
    NSURL* infoPath = [self containerLockPath];
    
    NSMutableDictionary *info = [NSMutableDictionary dictionaryWithContentsOfFile:infoPath.path];
    if (!info) {
        info = [NSMutableDictionary new];
    }
    
    if(val57 == 0) {
        audit_token_t token;
        mach_msg_type_number_t size = TASK_AUDIT_TOKEN_COUNT;
        
        kern_return_t kr = task_info(mach_task_self(), TASK_AUDIT_TOKEN, (task_info_t)&token, &size);
        if (kr != KERN_SUCCESS) {
            NSLog(@"Error getting task audit_token");
        }
        val57 = token.val[7] | ((uint64_t)token.val[5] << 32);
    }
    info[folderName] = @{
        @"runningLC": lc,
        @"auditToken57": @(val57)
    };
    
    info[lc] = @(val57);

    [info writeBinToFile:infoPath.path atomically:YES];
}

// move app data to private folder to prevent 0xdead10cc https://forums.developer.apple.com/forums/thread/126438
// This method is here for backward compatability, 0xdead10cc is already resolved.
+ (void)moveSharedAppFolderBack {
    NSFileManager *fm = NSFileManager.defaultManager;
    NSURL *libraryPathUrl = [fm URLsForDirectory:NSLibraryDirectory inDomains:NSUserDomainMask]
        .lastObject;
    NSURL *docPathUrl = [fm URLsForDirectory:NSDocumentDirectory inDomains:NSUserDomainMask]
        .lastObject;
    NSURL *appGroupFolder = [[LCSharedUtils appGroupPath] URLByAppendingPathComponent:@"LiveContainer"];
    
    NSError *error;
    NSString *sharedAppDataFolderPath = [libraryPathUrl.path stringByAppendingPathComponent:@"SharedDocuments"];
    if(![fm fileExistsAtPath:sharedAppDataFolderPath]){
        return;
    }
    // move all apps in shared folder back
    NSArray<NSString *> * sharedDataFoldersToMove = [fm contentsOfDirectoryAtPath:sharedAppDataFolderPath error:&error];
    
    // something went wrong with app group
    if(!appGroupFolder && sharedDataFoldersToMove.count > 0) {
        [lcUserDefaults setObject:@"FlekDeck was unable to move the data of shared app back because FlekDeck cannot access app group. Please check JITLess diagnose page in FlekDeck settings for more information." forKey:@"error"];
        return;
    }
    
    for(int i = 0; i < [sharedDataFoldersToMove count]; ++i) {
        NSString* destPath = [appGroupFolder.path stringByAppendingPathComponent:[NSString stringWithFormat:@"Data/Application/%@", sharedDataFoldersToMove[i]]];
        if([fm fileExistsAtPath:destPath]) {
            [fm
             moveItemAtPath:[sharedAppDataFolderPath stringByAppendingPathComponent:sharedDataFoldersToMove[i]]
             toPath:[docPathUrl.path stringByAppendingPathComponent:[NSString stringWithFormat:@"FOLDER_EXISTS_AT_APP_GROUP_%@", sharedDataFoldersToMove[i]]]
             error:&error
            ];
            
        } else {
            [fm
             moveItemAtPath:[sharedAppDataFolderPath stringByAppendingPathComponent:sharedDataFoldersToMove[i]]
             toPath:destPath
             error:&error
            ];
        }
    }
    
}

// Puts back the copy of a private app's data container that a window was
// running the app on, before the app starts in single mode. Otherwise only the
// window closing, or FlekDeck's home screen opening, settles such a copy, and a
// single-mode launch comes by neither when FlekDeck relaunches itself to make
// it, or is started by a shortcut: the app started on the older container in
// Documents, while what it keeps outside that container — its app group
// folders, its keychain — had gone on with the copy. Then the copy, the later
// session, was thrown away as the older of the two the next time the home
// screen opened.
+ (void)settleStagedContainer:(NSString*)folderName {
    NSURL *appGroupPath = [self appGroupPath];
    if(!appGroupPath || folderName.length == 0) {
        return;
    }
    NSURL *appGroupLC = [appGroupPath URLByAppendingPathComponent:@"LiveContainer"];
    NSURL *stagedData = [LCStagingRootURL(appGroupLC) URLByAppendingPathComponent:[NSString stringWithFormat:@"Data/Application/%@", folderName]];
    if(![NSFileManager.defaultManager fileExistsAtPath:stagedData.path]) {
        return;
    }
    // A window still running on the copy owns it, and settling it from under
    // that window would lose whatever it writes next.
    if(LCContainerIsInUse(folderName)) {
        NSLog(@"[LC] staging: container %@ is still in use by a window, starting the app without it", folderName);
        return;
    }
    NSString *docPath = [NSString stringWithFormat:@"%s/Documents", getenv("LC_HOME_PATH")];
    NSURL *localData = [NSURL fileURLWithPath:[docPath stringByAppendingPathComponent:[NSString stringWithFormat:@"Data/Application/%@", folderName]]];
    NSLog(@"[LC] staging: settling container %@ before it starts in single mode", folderName);
    LCReclaimStagedContainer(stagedData, localData, appGroupLC);
    LCSweepStagingTrash(appGroupLC);
}

+ (NSBundle*)findBundleWithBundleId:(NSString*)bundleId isSharedAppOut:(bool*)isSharedAppOut {
    NSString *docPath = [NSString stringWithFormat:@"%s/Documents", getenv("LC_HOME_PATH")];
    
    NSURL *appGroupFolder = nil;
    
    NSString *bundlePath = [NSString stringWithFormat:@"%@/Applications/%@", docPath, bundleId];
    NSBundle *appBundle;
    if([NSFileManager.defaultManager fileExistsAtPath:bundlePath]) {
        appBundle = [[NSBundle alloc] initWithPath:bundlePath];
    }

    // not found locally, let's look for the app in shared folder
    if (!appBundle) {
        appGroupFolder = [[LCSharedUtils appGroupPath] URLByAppendingPathComponent:@"LiveContainer"];
        
        bundlePath = [NSString stringWithFormat:@"%@/Applications/%@", appGroupFolder.path, bundleId];
        if([NSFileManager.defaultManager fileExistsAtPath:bundlePath]) {
            appBundle = [[NSBundle alloc] initWithPath:bundlePath];
        }
        if(appBundle) {
            *isSharedAppOut = true;
        }
    } else {
        *isSharedAppOut = false;
    }
    return appBundle;
}

// This method is here for backward compatability, preferences is direcrly saved to app's preference folder.
+ (void)dumpPreferenceToPath:(NSString*)plistLocationTo dataUUID:(NSString*)dataUUID {
    NSFileManager* fm = [[NSFileManager alloc] init];
    NSError* error1;
    
    NSDictionary* preferences = [lcUserDefaults objectForKey:dataUUID];
    if(!preferences) {
        return;
    }
    
    [fm createDirectoryAtPath:plistLocationTo withIntermediateDirectories:YES attributes:@{} error:&error1];
    for(NSString* identifier in preferences) {
        NSDictionary* preference = preferences[identifier];
        NSString *itemPath = [plistLocationTo stringByAppendingPathComponent:[NSString stringWithFormat:@"%@.plist", identifier]];
        if([preference count] == 0) {
            // Attempt to delete the file
            [fm removeItemAtPath:itemPath error:&error1];
            continue;
        }
        [preference writeToFile:itemPath atomically:YES];
    }
    [lcUserDefaults removeObjectForKey:dataUUID];
}

+ (NSString*)findDefaultContainerWithBundleId:(NSString*)bundleId {
    // find app's default container
    NSURL* appGroupFolder = [[LCSharedUtils appGroupPath] URLByAppendingPathComponent:@"LiveContainer"];
    
    NSString* bundleInfoPath = [NSString stringWithFormat:@"%@/Applications/%@/LCAppInfo.plist", appGroupFolder.path, bundleId];
    NSDictionary* infoDict = [NSDictionary dictionaryWithContentsOfFile:bundleInfoPath];
    return infoDict[@"LCDataUUID"];
}

+ (NSArray<NSString*>*)lcUnorderedUrlSchemes {
    NSArray<NSString *> *defaultSchemes = @[@"flekdeck", @"flekdeck2", @"flekdeck3"];
    return defaultSchemes;
}

+ (NSArray<NSString*>*)lcUrlSchemes {
    NSArray<NSString *> *defaultSchemes = [self lcUnorderedUrlSchemes];
    NSSet<NSString *> *allowedSchemes = [NSSet setWithArray:defaultSchemes];
    NSMutableArray<NSString *> *result = [NSMutableArray array];

    id savedValue = [NSUserDefaults.lcSharedDefaults objectForKey:@"LCMultiLaunchPriority"];
    if([savedValue isKindOfClass:NSArray.class]) {
        for(id value in (NSArray *)savedValue) {
            if(![value isKindOfClass:NSString.class]) {
                continue;
            }

            NSString *scheme = [(NSString *)value lowercaseString];
            if(![allowedSchemes containsObject:scheme] || [result containsObject:scheme]) {
                continue;
            }

            [result addObject:scheme];
        }
    }

    for(NSString *scheme in defaultSchemes) {
        if(![result containsObject:scheme]) {
            [result addObject:scheme];
        }
    }

    return result;
}

+ (NSString *)liveProcessBundleIdentifier {
    // LiveProcess asks this itself when a window enables JIT through a second
    // instance of the extension. Its bundle ID is whatever this copy was
    // re-signed as, so it is read rather than guessed.
    NSBundle *mainBundle = lcMainBundle ?: NSBundle.mainBundle;
    if([mainBundle.bundlePath hasSuffix:@"PlugIns/LiveProcess.appex"]) {
        return mainBundle.bundleIdentifier;
    }
    
    // first check if we have LiveProcess extension in our own bundle
    NSBundle *liveProcessBundle = [NSBundle bundleWithPath:[NSBundle.mainBundle.builtInPlugInsPath stringByAppendingPathComponent:@"LiveProcess.appex"]];
    if(liveProcessBundle) {
        return liveProcessBundle.bundleIdentifier;
    }
    
    // in LC2, attempt to guess LC1's LiveProcess extension
    NSString *bundleID = [NSString stringWithFormat:@"com.kdt.livecontainer.%@.LiveProcess", LCSharedUtils.teamIdentifier];
    if([NSExtension extensionWithIdentifier:bundleID error:nil]) {
        return bundleID;
    }
    
    return nil;
}

+ (void)startBuiltInVPNWithCompletionHandler:(void (^)(BOOL requested))completionHandler {
    void (^finish)(BOOL) = ^(BOOL requested) {
        if(completionHandler) completionHandler(requested);
    };
    // Set by Settings once the user has allowed the VPN configuration. Without
    // it there is nothing to start, and no reason to load the framework.
    if(![NSUserDefaults.lcSharedDefaults boolForKey:@"LCBuiltInVPNConfigured"]) {
        finish(NO);
        return;
    }
    // Written before anything else, as the guest reads it to tell its helper
    // that the VPN is on its way up and worth waiting a moment for.
    [NSUserDefaults.lcSharedDefaults setObject:NSDate.date forKey:@"LCBuiltInVPNStartRequested"];
    
    dlopen("/System/Library/Frameworks/NetworkExtension.framework/NetworkExtension", RTLD_LAZY);
    Class managerClass = NSClassFromString(@"NETunnelProviderManager");
    if(!managerClass) {
        finish(NO);
        return;
    }
    [managerClass loadAllFromPreferencesWithCompletionHandler:^(NSArray *managers, NSError *error) {
        // An app is only ever given its own configurations, and FlekDeck has one.
        LCVPNManager *manager = managers.firstObject;
        if(!manager) {
            finish(NO);
            return;
        }
        void (^start)(void) = ^{
            NSInteger status = manager.connection.status;
            if(status >= 2 && status <= 4) {
                finish(YES);
                return;
            }
            finish([manager.connection startVPNTunnelAndReturnError:nil]);
        };
        if(manager.isEnabled) {
            start();
            return;
        }
        // Another VPN has been chosen in Settings since, and iOS only starts
        // the chosen one.
        manager.enabled = YES;
        [manager saveToPreferencesWithCompletionHandler:^(NSError *saveError) {
            [manager loadFromPreferencesWithCompletionHandler:^(NSError *loadError) {
                start();
            }];
        }];
    }];
}

@end

#pragma mark - Window staging

// A window runs a private app on a copy of its data container in the app group
// ("App group staging" in AppSceneViewController.m explains why). What moves
// those copies and settles them back lives here rather than there, so that a
// single-mode launch, which never loads the window code, can settle a copy a
// window left behind before the app starts on the older container.

static NSURL *LCStagingTrashURL(NSURL *appGroupLC) {
    return [appGroupLC URLByAppendingPathComponent:@".StagingTrash"];
}

// Deleting a large tree is one unlink per file. Renaming it into the trash is a
// single operation, which is all the caller has to wait for; the deletion
// itself happens later, off any path the user can see.
BOOL LCDiscardTree(NSURL *url, NSURL *appGroupLC) {
    NSFileManager *fm = NSFileManager.defaultManager;
    if(![fm fileExistsAtPath:url.path]) {
        return YES;
    }
    NSURL *trashDir = LCStagingTrashURL(appGroupLC);
    [fm createDirectoryAtURL:trashDir withIntermediateDirectories:YES attributes:nil error:nil];
    NSURL *grave = [trashDir URLByAppendingPathComponent:NSUUID.UUID.UUIDString];
    if(rename(url.path.fileSystemRepresentation, grave.path.fileSystemRepresentation) == 0) {
        return YES;
    }
    // Same-volume rename should not fail here, but never leave the caller with
    // a path it believes is clear.
    return [fm removeItemAtURL:url error:nil];
}

void LCSweepStagingTrash(NSURL *appGroupLC) {
    NSURL *trashDir = LCStagingTrashURL(appGroupLC);
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        // Its own manager: NSFileManager.defaultManager is not safe to drive
        // from an arbitrary queue while the rest of the app is using it.
        NSFileManager *fm = [NSFileManager new];
        NSArray<NSURL *> *graves = [fm contentsOfDirectoryAtURL:trashDir includingPropertiesForKeys:nil options:0 error:nil];
        for(NSURL *grave in graves) {
            [fm removeItemAtURL:grave error:nil];
        }
    });
}

// clonefile gives an APFS copy-on-write clone of an entire tree in one call: no
// file data is duplicated and no per-file copy work is done, so it costs a
// fraction of NSFileManager's copy and almost no disk.
BOOL LCCloneTree(NSURL *src, NSURL *dst) {
    if(clonefile(src.path.fileSystemRepresentation, dst.path.fileSystemRepresentation, 0) == 0) {
        return YES;
    }
    // Not APFS, or the two ended up on different volumes. Correctness first.
    // Logged because the copy is orders of magnitude slower: if staging is ever
    // sluggish again, this line is the difference between "the clone stopped
    // working" and "something else is at fault".
    NSLog(@"[LC] staging: clonefile unavailable for %@ (%s), falling back to a full copy",
          src.lastPathComponent, strerror(errno));
    // Clear anything a half-finished clone may have left, or the copy would only
    // fail again on a destination that already exists.
    NSError *error = nil;
    [NSFileManager.defaultManager removeItemAtURL:dst error:nil];
    if([NSFileManager.defaultManager copyItemAtURL:src toURL:dst error:&error]) {
        return YES;
    }
    NSLog(@"[LC] staging: failed to stage %@: %@", src.lastPathComponent, error);
    return NO;
}

// Where this FlekDeck's windows stage their files, relative to the app group's
// LiveContainer folder. LiveProcess is handed this path, and looks for a staged
// app there and nowhere else.
NSString *LCStagingRelativePath(void) {
    NSString *scheme = NSUserDefaults.lcAppUrlScheme;
    return [@"Staging" stringByAppendingPathComponent:scheme.length > 0 ? scheme : @"flekdeck"];
}

NSURL *LCStagingRootURL(NSURL *appGroupLC) {
    return [appGroupLC URLByAppendingPathComponent:LCStagingRelativePath() isDirectory:YES];
}

// Timestamps that move when an app starts in a data container. The launcher
// recreates the `tmp` symlink at the container's root on every start
// (invokeAppMain in LCBootstrap.m), which moves both the link's own time and the
// folder's. FlekDeck writing the container's settings file moves only the
// folder's, so the link is the one to trust for a container in our Documents.
typedef struct {
    struct timespec tmpLink;   // {0, 0} when there is no link
    struct timespec folder;
} LCContainerStamp;

// Both containers' stamps as they were when the copy was made, kept on the copy.
typedef struct {
    LCContainerStamp staged;
    LCContainerStamp local;
} LCStagingMark;

static const char *const LCStagingMarkName = "com.flekdeck.staging-mark";

static LCContainerStamp LCReadContainerStamp(NSURL *container) {
    LCContainerStamp stamp = {{0, 0}, {0, 0}};
    struct stat st;
    NSString *tmpLink = [container.path stringByAppendingPathComponent:@"tmp"];
    if(lstat(tmpLink.fileSystemRepresentation, &st) == 0) {
        stamp.tmpLink = st.st_mtimespec;
    }
    if(stat(container.path.fileSystemRepresentation, &st) == 0) {
        stamp.folder = st.st_mtimespec;
    }
    return stamp;
}

static BOOL LCTimespecEqual(struct timespec a, struct timespec b) {
    return a.tv_sec == b.tv_sec && a.tv_nsec == b.tv_nsec;
}

static BOOL LCTimespecIsLater(struct timespec a, struct timespec b) {
    return a.tv_sec != b.tv_sec ? a.tv_sec > b.tv_sec : a.tv_nsec > b.tv_nsec;
}

void LCWriteStagingMark(NSURL *staged, NSURL *local) {
    LCStagingMark mark = { LCReadContainerStamp(staged), LCReadContainerStamp(local) };
    if(setxattr(staged.path.fileSystemRepresentation, LCStagingMarkName, &mark, sizeof(mark), 0, 0) != 0) {
        NSLog(@"[LC] staging: could not mark %@: %s", staged.lastPathComponent, strerror(errno));
    }
}

// Whether a staged copy of a data container holds a later session than the
// container in our Documents, and so should replace it.
//
// A copy made by this build carries a mark with both containers' stamps from
// when it was made, so the question is only which of them an app has started in
// since. That compares each container with itself, which moving the device
// clock in between cannot upset, and some games are played with the clock moved
// back and forth. The copy wins if an app started in it and not in the one in
// Documents. An app started in both means the one in Documents was opened in
// single mode after the copy's window was lost with FlekDeck, so it is the later
// of the two. Single mode settles the copy before it starts now (see
// +settleStagedContainer:), which leaves that to copies from builds before it,
// and to a copy a window still held when single mode began.
//
// Copies left by older builds carry no mark, and all there is to compare then is
// when each was last started.
static BOOL LCStagedContainerIsNewer(NSURL *staged, NSURL *local) {
    LCContainerStamp stagedNow = LCReadContainerStamp(staged);
    LCContainerStamp localNow = LCReadContainerStamp(local);
    LCStagingMark mark;
    if(getxattr(staged.path.fileSystemRepresentation, LCStagingMarkName, &mark, sizeof(mark), 0, 0) == sizeof(mark)) {
        BOOL startedInCopy = !LCTimespecEqual(stagedNow.tmpLink, mark.staged.tmpLink) ||
                             !LCTimespecEqual(stagedNow.folder, mark.staged.folder);
        BOOL startedInLocal = !LCTimespecEqual(localNow.tmpLink, mark.local.tmpLink);
        return startedInCopy && !startedInLocal;
    }
    struct timespec stagedStart = stagedNow.tmpLink.tv_sec || stagedNow.tmpLink.tv_nsec ? stagedNow.tmpLink : stagedNow.folder;
    struct timespec localStart = localNow.tmpLink.tv_sec || localNow.tmpLink.tv_nsec ? localNow.tmpLink : localNow.folder;
    return LCTimespecIsLater(stagedStart, localStart);
}

// Whether a process that is still running holds this container. The lock names
// the process that took it and reads as free once that process has gone, so a
// copy left by a FlekDeck that was killed is not mistaken for one in use.
BOOL LCContainerIsInUse(NSString *folderName) {
    return [LCSharedUtils getContainerUsingLCSchemeWithFolderName:folderName] != nil;
}

// Settles a staged copy of a data container against the one in our Documents,
// keeping whichever holds the later session and discarding the other. The caller
// makes sure no running process still holds the copy.
//
// Runs when a window closes, and for a copy whose window never got to close,
// because FlekDeck was killed with it open: when the home screen opens, before
// the same container is staged again, and before the app starts in single mode.
// Putting the copy back unconditionally lost data
// both ways round. A copy found at launch can be older than the container in
// Documents if the app has been opened in single mode since. And with "Allow
// Private Data access from LiveProcess" on, a window can run on the container in
// Documents directly, leaving its copy untouched to be swapped back over it.
void LCReclaimStagedContainer(NSURL *stagedData, NSURL *localData, NSURL *appGroupLC) {
    NSFileManager *fm = NSFileManager.defaultManager;
    if(![fm fileExistsAtPath:stagedData.path]) {
        return;
    }
    BOOL localExists = [fm fileExistsAtPath:localData.path];
    if(localExists && !LCStagedContainerIsNewer(stagedData, localData)) {
        LCDiscardTree(stagedData, appGroupLC);
        return;
    }
    // Swapped back rather than deleted-and-copied. Besides trading a walk of
    // every file for a single rename, this removes the window in which the
    // local container had been deleted and its replacement not yet written:
    // being killed in there used to lose the guest's data outright.
    //
    // Nothing below clears the local container until its replacement is
    // somewhere safe, so a failure at any step costs the session's changes
    // at worst, never the container.
    if(!localExists) {
        [fm createDirectoryAtURL:localData.URLByDeletingLastPathComponent withIntermediateDirectories:YES attributes:nil error:nil];
    }
    if(localExists &&
       renameatx_np(AT_FDCWD, stagedData.path.fileSystemRepresentation,
                    AT_FDCWD, localData.path.fileSystemRepresentation,
                    RENAME_SWAP) == 0) {
        // The swap left the older copy where the staged one was.
        LCDiscardTree(stagedData, appGroupLC);
    } else if(!localExists &&
              rename(stagedData.path.fileSystemRepresentation, localData.path.fileSystemRepresentation) == 0) {
        // First run of this container, so there was nothing to swap with.
    } else {
        // Swapping is unsupported here. Land a copy beside the container
        // first and only then put it in place.
        NSURL *incoming = [localData URLByAppendingPathExtension:@"incoming"];
        LCDiscardTree(incoming, appGroupLC);
        if(!LCCloneTree(stagedData, incoming)) {
            NSLog(@"[LC] staging: could not copy container %@ back, leaving it staged", localData.lastPathComponent);
            return;
        }
        LCDiscardTree(localData, appGroupLC);
        if(rename(incoming.path.fileSystemRepresentation, localData.path.fileSystemRepresentation) != 0) {
            NSLog(@"[LC] staging: failed to reclaim container %@: %s", localData.lastPathComponent, strerror(errno));
            return;
        }
        LCDiscardTree(stagedData, appGroupLC);
    }
    // The mark describes a copy, and this is the container in Documents now.
    removexattr(localData.path.fileSystemRepresentation, LCStagingMarkName, 0);
}
