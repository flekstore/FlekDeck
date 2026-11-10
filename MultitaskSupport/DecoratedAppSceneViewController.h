#import "FoundationPrivate.h"
#import "AppSceneViewController.h"

API_AVAILABLE(ios(16.0))
@interface DecoratedAppSceneViewController : UIViewController<AppSceneViewControllerDelegate>
@property(nonatomic) AppSceneViewController* appSceneVC;
@property(nonatomic) UIStackView *view;
@property(nonatomic) UINavigationBar *navigationBar;
@property(nonatomic) UINavigationItem *navigationItem;
@property(nonatomic) UIView* contentView;

@property(nonatomic) BOOL isMaximized;
@property(nonatomic) CGFloat scaleRatio;
- (instancetype)initWindowName:(NSString*)windowName bundleId:(NSString*)bundleId dataUUID:(NSString*)dataUUID rootVC:(UIViewController*)rootVC;
- (void)closeWindow;
- (void)minimizeWindow;
/// Puts an already-animated-away window into its resting minimized state. Split
/// out of `minimizeWindow` so a caller that supplies its own animation — the
/// home button, which shrinks the window into its springboard icon — can still
/// leave the window exactly as this class expects to find it.
- (void)finishMinimizeWindow;
- (void)minimizeWindowPiP;
- (void)unminimizeWindowPiP;
/// `unminimizeWindowPiP` with word once the window's fade back has run — what
/// AVKit waits for before it finishes taking the PiP window down.
- (void)unminimizeWindowPiPWithCompletion:(void (^)(void))completion;
- (void)updateVerticalConstraints;
/// Re-frames a maximized window to the host's current size and resizes the
/// guest's drawable to match. Call after anything that changes the space the
/// window has to fill — a rotation, a Split View resize — since a guest that
/// pushes no settings update of its own would otherwise keep drawing at the
/// old size, leaving the host's black backdrop showing along the edge that grew.
- (void)refreshMaximizedLayout;
/// `refreshMaximizedLayout` for a change of the window's page: the window has
/// been given one side of an iPhone Duo opened out, or the whole screen back.
/// Applied even while the phone lies flat, which holds every other re-framing:
/// that hold is about the device not saying which way it is being read, and
/// nothing about this change asks it.
- (void)refreshPaneLayout;
/// True until this guest has settled on an orientation while the device was being
/// held — i.e. it has never had a layout worth keeping. The rotation lock exists to
/// stop geometry being *re-derived* from a device that is not answering; it was
/// never meant to stop a window being laid out for the first time.
@property(nonatomic, readonly) BOOL awaitingFirstLayout;
/// Menu for the switcher card's Customize button: copy PID, toggle PiP, and a live
/// UI-scale slider. Built here because it's a real `UIMenu` — the slider goes in via
/// `UICustomViewMenuElement`, which is private UIKit and only visible to this target.
- (UIMenu *)customizeMenu;
@property(nonatomic, copy) void (^pidAvailableHandler)(NSNumber *pid, NSError *error);
@end

