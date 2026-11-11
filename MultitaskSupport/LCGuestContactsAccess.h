//
//  LCGuestContactsAccess.h
//  LiveContainer
//

@import Foundation;

NS_ASSUME_NONNULL_BEGIN

/// The host end of one guest's contacts permission request.
///
/// Since iOS 18 the contacts permission is asked in two steps, and iOS shows the
/// second — share all contacts or pick some — only to an app's own process,
/// never to the app extension a multitask guest runs in. There the request stops
/// after the first step and the app is refused. LCGuestContacts hands the
/// guest's request here instead: the host asks iOS itself, gets both steps over
/// FlekDeck, and tells the guest once iOS has answered. The permission is
/// FlekDeck's in both modes, so the guest then reads the user's answer as its
/// own.
@interface LCGuestContactsAccess : NSObject

- (instancetype)initWithDataUUID:(NSString *)dataUUID;

/// Stops listening for the guest. A question already put to iOS still gets its
/// answer passed on. Safe to call more than once.
- (void)invalidate;

@end

NS_ASSUME_NONNULL_END
