//
//  WidgetExtension-Bridging-Header.h
//  LiveContainer
//

#import <CoreFoundation/CoreFoundation.h>

// Security's SecTask calls, which the iOS SDK leaves out of its headers. The
// widget reads its own app groups with them, as LCSharedUtils does FlekDeck's.
typedef struct CF_BRIDGED_TYPE(id) __SecTask *SecTaskRef;
SecTaskRef SecTaskCreateFromSelf(CFAllocatorRef allocator) CF_RETURNS_RETAINED;
CFTypeRef SecTaskCopyValueForEntitlement(SecTaskRef task, CFStringRef entitlement, CFErrorRef *error) CF_RETURNS_RETAINED;
