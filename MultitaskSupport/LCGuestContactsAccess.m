//
//  LCGuestContactsAccess.m
//  LiveContainer
//

#import "LCGuestContactsAccess.h"
#import <dlfcn.h>
#import <notify.h>
#import <objc/message.h>

// Contacts is not linked into FlekDeck, so none of its selectors are declared
// here. See LCContactStoreClass.
#pragma clang diagnostic ignored "-Wundeclared-selector"

// CNEntityTypeContacts.
static const NSInteger kLCEntityTypeContacts = 0;

/// Loaded on the first request rather than linked: FlekDeck itself never reads
/// contacts, and most sessions never see a guest ask.
static Class LCContactStoreClass(void) {
    static Class storeClass;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        dlopen("/System/Library/Frameworks/Contacts.framework/Contacts", RTLD_LAZY);
        storeClass = NSClassFromString(@"CNContactStore");
    });
    return storeClass;
}

@implementation LCGuestContactsAccess {
    NSString *_ackName;
    NSString *_doneName;
    int _token;
    BOOL _listening;
    /// The store asking on the guest's behalf, for as long as iOS has the question.
    id _store;
}

- (instancetype)initWithDataUUID:(NSString *)dataUUID {
    self = [super init];
    if(!self || dataUUID.length == 0) return self;

    // The same fixed literal keyed by container that the other guest channels
    // use: both processes work the name out for themselves, from nothing but the
    // container id.
    NSString *base = [NSString stringWithFormat:@"com.kdt.livecontainer.contacts.%@", dataUUID];
    _ackName = [base stringByAppendingString:@".ack"];
    _doneName = [base stringByAppendingString:@".done"];
    int token = 0;
    __weak typeof(self) weakSelf = self;
    if(notify_register_dispatch([base stringByAppendingString:@".request"].UTF8String, &token, dispatch_get_main_queue(), ^(int t) {
        [weakSelf handleRequest];
    }) == NOTIFY_STATUS_OK) {
        _token = token;
        _listening = YES;
    }
    return self;
}

- (void)dealloc {
    [self invalidate];
}

- (void)invalidate {
    if(!_listening) return;
    _listening = NO;
    notify_cancel(_token);
}

- (void)handleRequest {
    if(!_listening) return;
    // Acknowledged at once, so the guest stops repeating itself and waits for as
    // long as the user takes over the two steps.
    notify_post(_ackName.UTF8String);
    // Already asking: the answer to that covers every request the guest makes
    // meanwhile.
    if(_store) return;

    NSString *doneName = _doneName;
    Class storeClass = LCContactStoreClass();
    if(!storeClass) {
        NSLog(@"[LCGuestContacts] host: Contacts did not load, leaving the guest to ask for itself");
        notify_post(doneName.UTF8String);
        return;
    }

    // Asked from here because this is an app's own process: iOS shows both steps
    // over FlekDeck, the second as an overlay it would not raise for the guest.
    id store = [storeClass new];
    _store = store;
    NSLog(@"[LCGuestContacts] host: asking iOS for contacts on the guest's behalf");
    __weak typeof(self) weakSelf = self;
    void (^completion)(BOOL, NSError *) = ^(BOOL granted, NSError *error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            // Kept alive until iOS answers, even if the window has gone by then.
            (void)store;
            NSLog(@"[LCGuestContacts] host: iOS answered, granted %d, error %@", granted, error);
            typeof(self) strongSelf = weakSelf;
            if(strongSelf) strongSelf->_store = nil;
            // Posted whether or not anyone is still listening: the name belongs to
            // the container, and a guest still waiting on it needs the answer.
            notify_post(doneName.UTF8String);
        });
    };
    ((void (*)(id, SEL, NSInteger, void (^)(BOOL, NSError *)))objc_msgSend)(store, @selector(requestAccessForEntityType:completionHandler:), kLCEntityTypeContacts, completion);
}

@end
