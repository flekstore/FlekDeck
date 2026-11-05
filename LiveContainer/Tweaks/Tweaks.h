//
//  Tweaks.h
//  LiveContainer
//
//  Created by s s on 2025/2/7.
//

void swizzle(Class class, SEL originalAction, SEL swizzledAction);
bool performHookDyldApi(const char* functionName, uint32_t adrpOffset, void** origFunction, void* hookFunction);

void NUDGuestHooksInit(void);
void NUDGuestFlushOnTerminationInit(void);
void NUDGuestFlushWhileRunningInit(void);
void SecItemGuestHooksInit(void);
void DyldHooksInit(bool hideLiveContainer, bool hookDlopen, uint32_t spoofSDKVersion);
void NSFMGuestHooksInit(void);
void NSBundleGuestHooksInit(void);
void NSURLSCGuestHooksInit(void);
void initDead10ccFix(void);
void IDFVHookInit(NSUUID* uuid);
void LCHostIdentityInit(void);
void LCAudioMuteInit(NSString* dataUUID);
void LCGuestPiPInit(NSString* dataUUID);
void LCGuestCaptureInit(NSString* dataUUID);
void LCGuestSideBarInit(NSString* dataUUID);

@interface NSBundle(LiveContainer)
- (instancetype)initWithPathForMainBundle:(NSString *)path;
@end


extern uint32_t appMainImageIndex;
extern void* appExecutableHandle;
extern bool tweakLoaderLoaded;
void* getGuestAppHeader(void);
void* getDSCAddr(void);
void* getCachedSymbol(NSString* symbolName, struct mach_header_64* header);
void saveCachedSymbol(NSString* symbolName, struct mach_header_64* header, uint64_t offset);
void* dlopen_nolock(const char *path, int mode);
void bypass_seg_count_check(void (^block)(void));

static void hook_do_nothing(void) {}
