//
//  LCGuestContacts.m
//  LiveContainer
//
//  Lets an app in a multitask window finish asking for the user's contacts.
//
//  Since iOS 18 the contacts permission is asked in two steps. The first, "Allow
//  … to access your contacts?", is an ordinary system alert, and any process can
//  raise it. The second — share all contacts or pick some — is a separate system
//  app (LimitedAccessPromptView) that tccd asks SpringBoard to lay over the app
//  that asked. tccd does that for an app's own process, but not for a multitask
//  guest, which is an app extension: there it skips the second step and replies
//  with the in-between answer the first step left behind, and Contacts hands the
//  app a refusal. The app asks again, is refused again, and nothing appears.
//  Read off the phone's log on iOS 27.2: for LiveProcess, tccd goes from "found
//  usage string" straight to its reply, where for the host it goes on to
//  SpringBoard and the second step comes up.
//
//  Which of the two processes asks makes no difference to the answer: tccd files
//  a LiveProcess request under the containing app, so the permission is
//  FlekDeck's in both modes. This hands the request to the host, which is an app
//  and gets both steps. Once iOS has answered there, the app's own call goes
//  ahead, finds nothing left to ask, and returns the answer the user gave.
//
//  Installed during bootstrap, before the app binary is dlopened, and only for a
//  LiveProcess guest: in single mode the guest is the app process and gets both
//  steps itself.
//
@import Foundation;
@import ObjectiveC;

#import <dlfcn.h>
#import <mach-o/dyld.h>
#import <notify.h>
#import <os/lock.h>

#import "Tweaks.h"

// Contacts is looked up by name rather than imported, so that LiveContainer does
// not link it into every guest. Only an app that loads Contacts itself gets the
// hook, and none of its selectors are declared in this translation unit.
#pragma clang diagnostic ignored "-Wundeclared-selector"

// CNEntityTypeContacts, the CNAuthorizationStatus values that matter here, and
// CNErrorCodeAuthorizationDenied.
enum {
    kLCEntityTypeContacts = 0,
    kLCAuthorizationStatusNotDetermined = 0,
    kLCAuthorizationStatusAuthorized = 3,
    kLCAuthorizationStatusLimited = 4,
    kLCErrorCodeAuthorizationDenied = 100,
};

typedef void (^LCContactsAccessCompletion)(BOOL granted, NSError *error);

// The host starts listening before it launches the guest, so the first request
// is normally acknowledged at once. The repeats cover a registration that failed
// or came late; after them the app's call goes ahead as it would have without
// this.
static const int64_t kLCRepostInterval = 500 * NSEC_PER_MSEC;
static const int kLCMaxPosts = 6;
// Once the host has the request, the user may take as long as they like over
// the two steps — picking contacts one by one included. This is only a backstop
// for an answer that never arrives, so the app is not left waiting forever.
static const int64_t kLCAnswerBackstop = 15 * 60 * NSEC_PER_SEC;

/// A call to -requestAccessForEntityType:completionHandler: held back while the
/// host asks.
@interface LCContactsWaitingCall : NSObject
@property(nonatomic, strong) id store;
@property(nonatomic) NSInteger entityType;
@property(nonatomic, copy) LCContactsAccessCompletion completion;
@end

@implementation LCContactsWaitingCall
@end

static void (*orig_requestAccess)(id, SEL, NSInteger, LCContactsAccessCompletion);
static Class gContactStoreClass;

static NSString *gRequestName;
static NSString *gAckName;
static NSString *gDoneName;

// Everything below runs on gQueue. One hand-over at a time, and every call that
// arrives meanwhile joins it: there is one permission for the whole app, so one
// answer covers them all.
static dispatch_queue_t gQueue;
static NSMutableArray<LCContactsWaitingCall *> *gWaiting;
static bool gHandingOver = false;
static bool gHostHasIt = false;
// Moves on at the start and the end of every hand-over, so a reply or a timer
// left over from an earlier one is recognised and ignored.
static uint64_t gGeneration = 0;
static int gAckToken = -1;
static int gDoneToken = -1;

static NSInteger lcContactsStatus(void) {
    return ((NSInteger (*)(Class, SEL, NSInteger))objc_msgSend)(gContactStoreClass, @selector(authorizationStatusForEntityType:), kLCEntityTypeContacts);
}

// What Contacts hands an app whose request was not granted.
static NSError *lcNotGrantedError(void) {
    NSString * __unsafe_unretained const *domain = (NSString * __unsafe_unretained const *)dlsym(RTLD_DEFAULT, "CNErrorDomain");
    return [NSError errorWithDomain:(domain && *domain) ? *domain : @"CNErrorDomain"
                               code:kLCErrorCodeAuthorizationDenied
                           userInfo:@{NSLocalizedDescriptionKey: @"Access Denied"}];
}

// `hostAsked` is whether the host put the question to iOS: an answer arrived, or
// the backstop gave up waiting for one. Otherwise the host never picked the
// request up, and the app's calls go ahead exactly as they would have.
static void lcFinishHandOver(const char *why, bool hostAsked) {
    if(!gHandingOver) return;
    gHandingOver = false;
    gHostHasIt = false;
    gGeneration++;
    if(gAckToken != -1) {
        notify_cancel(gAckToken);
        gAckToken = -1;
    }
    if(gDoneToken != -1) {
        notify_cancel(gDoneToken);
        gDoneToken = -1;
    }
    NSArray<LCContactsWaitingCall *> *calls = [gWaiting copy];
    [gWaiting removeAllObjects];

    // Still undecided after the host asked: the user backed out of the second
    // step, which leaves the permission unanswered, or iOS never got as far as
    // showing it. The app's own call would then ask again from here — the first
    // alert a second time, and the very refusal this exists to avoid if the user
    // continues. So these calls get the answer the host's request got: not
    // granted. The next time the app asks, the host asks again.
    if(hostAsked && lcContactsStatus() == kLCAuthorizationStatusNotDetermined) {
        NSLog(@"[LCGuestContacts] %s, still undecided — answering %lu call(s) not granted", why, (unsigned long)calls.count);
        NSError *error = lcNotGrantedError();
        // Off this queue, as Contacts calls back on one of its own: an app's
        // handler is free to take its time.
        dispatch_queue_t queue = dispatch_get_global_queue(QOS_CLASS_DEFAULT, 0);
        for(LCContactsWaitingCall *call in calls) {
            LCContactsAccessCompletion completion = call.completion;
            if(completion) dispatch_async(queue, ^{ completion(NO, error); });
        }
        return;
    }

    NSLog(@"[LCGuestContacts] %s — letting %lu call(s) through", why, (unsigned long)calls.count);
    // The app's own calls, untouched. After an answer in the host there is
    // nothing left for iOS to ask, so each returns at once with what the user
    // chose; after a fallback they behave exactly as they did before this.
    for(LCContactsWaitingCall *call in calls) {
        orig_requestAccess(call.store, @selector(requestAccessForEntityType:completionHandler:), call.entityType, call.completion);
    }
}

static void lcPostRequest(uint64_t generation, int posted) {
    if(!gHandingOver || generation != gGeneration || gHostHasIt) return;
    if(posted >= kLCMaxPosts) {
        lcFinishHandOver("the host did not pick the request up", false);
        return;
    }
    notify_post(gRequestName.UTF8String);
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, kLCRepostInterval), gQueue, ^{
        lcPostRequest(generation, posted + 1);
    });
}

static void lcBeginHandOver(void) {
    gHandingOver = true;
    gHostHasIt = false;
    uint64_t generation = ++gGeneration;

    // Listening before asking, so that neither reply can arrive unheard.
    uint32_t ackStatus = notify_register_dispatch(gAckName.UTF8String, &gAckToken, gQueue, ^(int token) {
        if(!gHandingOver || generation != gGeneration || gHostHasIt) return;
        gHostHasIt = true;
        NSLog(@"[LCGuestContacts] the host is asking iOS");
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, kLCAnswerBackstop), gQueue, ^{
            if(generation == gGeneration) lcFinishHandOver("no answer from the host in 15 minutes", true);
        });
    });
    if(ackStatus != NOTIFY_STATUS_OK) gAckToken = -1;
    // The answer counts even if the acknowledgement never got here: the host
    // posts both, and a quick answer can overtake it.
    uint32_t doneStatus = notify_register_dispatch(gDoneName.UTF8String, &gDoneToken, gQueue, ^(int token) {
        if(gHandingOver && generation == gGeneration) lcFinishHandOver("iOS has answered in the host", true);
    });
    if(doneStatus != NOTIFY_STATUS_OK) gDoneToken = -1;

    if(gAckToken == -1 || gDoneToken == -1) {
        lcFinishHandOver("could not listen for the host", false);
        return;
    }
    NSLog(@"[LCGuestContacts] handing the contacts request to the host");
    lcPostRequest(generation, 0);
}

static void lc_requestAccess(id self, SEL _cmd, NSInteger entityType, LCContactsAccessCompletion completion) {
    if(entityType != kLCEntityTypeContacts || !gQueue) {
        orig_requestAccess(self, _cmd, entityType, completion);
        return;
    }
    // Already allowed, fully or in part: iOS answers at once and shows nothing,
    // so there is nothing for the host to do.
    NSInteger status = lcContactsStatus();
    if(status == kLCAuthorizationStatusAuthorized || status == kLCAuthorizationStatusLimited) {
        orig_requestAccess(self, _cmd, entityType, completion);
        return;
    }

    // Everything else goes through the host — a refusal included. The in-between
    // answer the first step leaves has no status of its own, and whichever one
    // it reads as, the host is the only place its second step can be shown. For an app the user really did refuse, the host's request comes
    // straight back without showing anything, so the detour costs nothing.
    LCContactsWaitingCall *call = [LCContactsWaitingCall new];
    call.store = self;
    call.entityType = entityType;
    call.completion = completion;
    dispatch_async(gQueue, ^{
        [gWaiting addObject:call];
        if(!gHandingOver) lcBeginHandOver();
    });
}

#pragma mark - Installation

static os_unfair_lock gInstallLock = OS_UNFAIR_LOCK_INIT;
static bool gHookInstalled = false;

static void lcInstallHook(void) {
    // Locked as well as flagged: installing twice would save the hook itself as
    // the original, and the app's request would then call itself forever.
    os_unfair_lock_lock(&gInstallLock);
    if(!gHookInstalled) {
        Class storeClass = NSClassFromString(@"CNContactStore");
        Method method = storeClass ? class_getInstanceMethod(storeClass, @selector(requestAccessForEntityType:completionHandler:)) : NULL;
        if(method) {
            gHookInstalled = true;
            gContactStoreClass = storeClass;
            orig_requestAccess = (void (*)(id, SEL, NSInteger, LCContactsAccessCompletion))method_getImplementation(method);
            method_setImplementation(method, (IMP)lc_requestAccess);
            NSLog(@"[LCGuestContacts] armed on %@", gRequestName);
        }
    }
    os_unfair_lock_unlock(&gInstallLock);
}

// An app that asks for contacts links Contacts the usual way, and that has not
// been loaded yet at bootstrap — this runs before the app binary is even
// dlopened. dyld replays this for every image already in the process, then calls
// it for each new one, so the hook goes in the moment Contacts arrives.
static void lcContactsImageAdded(const struct mach_header *header, intptr_t slide) {
    if(!gHookInstalled) lcInstallHook();
}

void LCGuestContactsInit(NSString *dataUUID) {
    if(dataUUID.length == 0) return;

    // A fixed literal prefix keyed by container, the same shape the other guest
    // channels use and for the same reason: the host and the guest each work the
    // name out for themselves, from nothing but the container id.
    NSString *base = [NSString stringWithFormat:@"com.kdt.livecontainer.contacts.%@", dataUUID];
    gRequestName = [base stringByAppendingString:@".request"];
    gAckName = [base stringByAppendingString:@".ack"];
    gDoneName = [base stringByAppendingString:@".done"];
    gWaiting = [NSMutableArray array];
    gQueue = dispatch_queue_create("com.kdt.livecontainer.contacts", DISPATCH_QUEUE_SERIAL);

    lcInstallHook();
    _dyld_register_func_for_add_image(lcContactsImageAdded);
}
