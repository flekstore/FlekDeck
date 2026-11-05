#import "DecoratedAppSceneViewController.h"
#import "ResizeHandleView.h"
#import "LiveContainerSwiftUI-Swift.h"
#import "AppSceneViewController.h"
#import "UIKitPrivate+MultitaskSupport.h"
#import "PiPManager.h"
#import "VirtualWindowsHostView.h"
#import "../LiveContainer/Localization.h"
#import "utils.h"

@interface DecoratedAppSceneViewController()
@property(nonatomic) NSArray* activatedVerticalConstraints;
@property(nonatomic) NSString* windowName;
@property(nonatomic) NSString* dataUUID;
@property(nonatomic) int pid;
@property(nonatomic) CGRect originalFrame;
@property(nonatomic) UIBarButtonItem *maximizeButton;
@property(nonatomic) bool isAppTerminationRequested;
/// Whether the guest has already been reported as drawing its own content. The
/// cue can arrive from more than one place, so the first one wins and the rest
/// are ignored.
@property(nonatomic) BOOL didReportContentArrived;
- (void)applySceneFrameToSettings:(UIMutableApplicationSceneSettings *)settings orientation:(UIInterfaceOrientation)orientation;
- (void)applyMaximizedLayout;
- (void)applyMaximizedGeometryToSettings:(UIMutableApplicationSceneSettings *)settings;
@end

/// How long after its scene is presented the window keeps the launch screen it
/// opened with. The guest is drawing by then — a launch screen of its own if it
/// is still starting up — so what replaces ours is, for most apps, the same
/// picture. Long enough for that first frame to land, short enough that a guest
/// whose picture differs is not sat behind ours.
static const NSTimeInterval kContentGraceAfterScene = 0.45;

/// The last word, for a guest whose scene never gets presented at all — one that
/// dies on the way up. Nothing may leave a stand-in covering a window for good.
static const NSTimeInterval kContentArrivalLimit = 4.0;

/// Quarter-turns clockwise from upright, in the same sense the dock manager
/// counts them.
static NSInteger LCInterfaceSteps(UIInterfaceOrientation orientation) {
    switch(orientation) {
        case UIInterfaceOrientationLandscapeLeft:      return 1;
        case UIInterfaceOrientationPortraitUpsideDown: return 2;
        case UIInterfaceOrientationLandscapeRight:     return 3;
        default:                                       return 0;
    }
}

static NSInteger LCDeviceSteps(UIDeviceOrientation orientation) {
    switch(orientation) {
        case UIDeviceOrientationLandscapeRight:        return 1;
        case UIDeviceOrientationPortraitUpsideDown:    return 2;
        case UIDeviceOrientationLandscapeLeft:         return 3;
        default:                                       return 0;
    }
}

/// Rolls a set of insets `steps` quarter-turns clockwise: what sat along the left
/// edge ends up along the top, and so on round.
static UIEdgeInsets LCInsetsRotated(UIEdgeInsets insets, NSInteger steps) {
    for(NSInteger i = 0; i < ((steps % 4) + 4) % 4; i++) {
        insets = UIEdgeInsetsMake(insets.left, insets.bottom, insets.right, insets.top);
    }
    return insets;
}

/// The orientation the guest's scene is actually in, which is not always the
/// host's. A landscape-only guest runs sideways inside a portrait host — its
/// scene carries its own orientation, and every piece of geometry we hand it
/// (its frame, and the insets it is told to keep clear) is expressed in that
/// orientation, not in ours. The host's orientation describes the bar and the
/// launcher, not the app being laid out.
///
/// Falls back to the host's while a scene is still coming up and has yet to say
/// which way it is facing.
static UIInterfaceOrientation LCGuestSceneOrientation(UIMutableApplicationSceneSettings *settings) {
    UIInterfaceOrientation orientation = settings.interfaceOrientation;
    if(orientation == UIInterfaceOrientationUnknown) {
        return LCHostInterfaceOrientation(nil);
    }
    return orientation;
}

/// The last device orientation that could describe how the guest is being *read*.
///
/// `UIDevice.currentDevice.orientation` also reports face-up and face-down, which
/// a phone tilted far enough back onto its own back will hit. Neither is an
/// answer to "which way round is the user holding this" — they describe the
/// phone's relationship to the ground, not to the viewer.
///
/// That distinction is load-bearing here because the device is consulted at
/// exactly the moment the scene's own reported orientation has been found
/// untrustworthy. Letting face-up fall through to the guess below swaps one
/// unreliable answer for a different one: a phone read as `landscapeRight`
/// resolves the guest to `landscapeLeft` while it is being held, and to
/// `landscapeRight` the instant it is tilted past face-up — flipping the guest
/// 180° for no reason the user caused, and only in multitask, since nothing else
/// derives an orientation this way.
///
/// Holding the last real answer makes tilt mean nothing, which is what iOS does
/// natively: an app laid flat on a table keeps the orientation it had.
/// Whether guest geometry may currently be re-derived.
///
/// Delegates to `LCRotationLock`, which answers no both while the phone is lying
/// flat — where the device is not saying which way the screen is being read, so
/// anything derived from it is a guess — and while the on-screen panel is holding
/// the lock by hand. Both routes go through this one predicate on purpose: a
/// manual lock that took a different path through the geometry code would be a
/// second thing to get right.
static BOOL LCRotationIsLocked(void) {
    return LCRotationLock.isLocked;
}

static UIDeviceOrientation LCLastViewingDeviceOrientation(void) {
    static UIDeviceOrientation last = UIDeviceOrientationPortrait;
    UIDeviceOrientation current = UIDevice.currentDevice.orientation;
    if(UIDeviceOrientationIsValidInterfaceOrientation(current)) {
        last = current;
    }
    return last;
}

/// How far the guest has turned its own content against the scene it lives in.
///
/// A guest autorotates on `deviceOrientation`. When this host is pinned upright
/// the scene never follows, so the guest is turned inside a window that is not —
/// and anything expressed in the guest's own frame is carried around with it.
static NSInteger LCGuestSelfRotationSteps(UIMutableApplicationSceneSettings *settings) {
    // Sticky reading, like every other orientation consumer in this file: face-up
    // would otherwise report zero steps and describe a turned guest as upright.
    UIDeviceOrientation device = LCLastViewingDeviceOrientation();
    if(!UIDeviceOrientationIsValidInterfaceOrientation(device)) return 0;
    NSInteger steps = LCDeviceSteps(device) - LCInterfaceSteps(LCGuestSceneOrientation(settings));
    return ((steps % 4) + 4) % 4;
}

/// The orientation the guest's window is actually in.
///
/// `settings.interfaceOrientation` — and the host's orientation behind it — can
/// say portrait while the window it describes is 874x402. Every piece of geometry
/// here is derived from that answer: which way the scene frame is measured, which
/// edge of the screen the island is on, which insets the guest is handed. Derived
/// from a stale one, all of it lands crosswise, which is what leaves a strip of
/// the host's backdrop beside a turned guest.
///
/// The window's own shape cannot be stale — it is the rectangle the content is
/// being drawn into, and its safe area agrees with it. So when the two disagree
/// the window wins, and the device says which of the two landscape directions it
/// is. Device and interface landscape names are mirror images; see
/// `restoreOrientationAfterSwitcher`.
static UIInterfaceOrientation LCWindowOrientation(UIView *view, UIMutableApplicationSceneSettings *settings) {
    UIInterfaceOrientation reported = LCGuestSceneOrientation(settings);
    CGSize size = view.window.bounds.size;
    if(size.width <= 0 || size.height <= 0) return reported;

    BOOL windowIsLandscape = size.width > size.height;
    if(windowIsLandscape == UIInterfaceOrientationIsLandscape(reported)) return reported;

    switch(LCLastViewingDeviceOrientation()) {
        case UIDeviceOrientationLandscapeLeft:      return UIInterfaceOrientationLandscapeRight;
        case UIDeviceOrientationLandscapeRight:     return UIInterfaceOrientationLandscapeLeft;
        case UIDeviceOrientationPortraitUpsideDown: return UIInterfaceOrientationPortraitUpsideDown;
        default: break;
    }
    return windowIsLandscape ? UIInterfaceOrientationLandscapeRight : UIInterfaceOrientationPortrait;
}

@implementation DecoratedAppSceneViewController {
    /// The last orientation this guest was known to be in while the phone was
    /// actually being held. The hard lock's memory.
    ///
    /// Held here rather than read back out of the scene settings on purpose: the
    /// settings object is copied, merged and overwritten by several writers on
    /// every host diff, and every previous attempt at this bug failed because it
    /// trusted that object to still hold the guest's orientation when it came to
    /// be read. An ivar cannot be clobbered by a settings merge.
    UIInterfaceOrientation _lockedGuestOrientation;
    /// The window was to be re-framed while it flew into its icon, and was left
    /// where it stood instead; it is caught up once it has landed, out of sight.
    BOOL _geometryHeldInFlight;
}
- (instancetype)initWindowName:(NSString*)windowName bundleId:(NSString*)bundleId dataUUID:(NSString*)dataUUID rootVC:(UIViewController*)rootVC {
    self = [super initWithNibName:nil bundle:nil];
    self.view = [[UIStackView alloc] initWithFrame:self.view.frame];
    [MultitaskDockManager.shared.windowHostingView addSubview:self.view];
    [rootVC addChildViewController:self];
    
    _dataUUID = dataUUID;
    _scaleRatio = 1.0;
    _isMaximized = YES;
    [rootVC addChildViewController:self];
    [MultitaskDockManager.shared.windowHostingView addSubview:self.view];
    _appSceneVC = [[AppSceneViewController alloc] initWithBundleId:bundleId dataUUID:dataUUID delegate:self];
    self.title = windowName;
    [self setupDecoratedView];
    
    [MultitaskDockManager.shared addRunningApp:windowName appUUID:dataUUID view:self.view];

    // The window opens immediately, carrying the app's launch screen, and drops
    // it once the guest is drawing its own. This is the last resort for a guest
    // that never gets that far.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kContentArrivalLimit * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [self reportContentArrived];
    });


    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(switcherBarVisibilityChanged)
                                                 name:@"MultitaskBarVisibilityChanged"
                                               object:nil];
    
    self.dataUUID = dataUUID;
    self.windowName = windowName;
    self.navigationItem.title = windowName;
    
    return self;
}

- (void)setupDecoratedView {
    CGFloat navBarHeight = 44;
    BOOL isLandscape = UIInterfaceOrientationIsLandscape(LCHostInterfaceOrientation(self.view));
    CGRect frame = CGRectMake(0, 0, isLandscape ? 480 : 320, (isLandscape ? 320 : 480) + navBarHeight);
    CGPoint rootViewCenter = self.view.superview.center;
    frame.origin = CGPointMake(rootViewCenter.x - frame.size.width / 2, rootViewCenter.y - frame.size.height / 2);
    
    if(_isMaximized) {
        // Don't call updateMaximizedFrameWithSettings here — navBar not created yet.
        // The frame will be set after updateVerticalConstraints below.
        CGRect maxFrame = UIEdgeInsetsInsetRect(self.view.window.frame, self.view.window.safeAreaInsets);
        // save origin as normalized coordinates
        frame.origin.x /= maxFrame.size.width;
        frame.origin.y /= maxFrame.size.height;
        self.originalFrame = frame;
    } else {
        self.view.frame = frame;
    }
    
    // Navigation bar
    UINavigationBar *navigationBar = [[UINavigationBar alloc] initWithFrame:CGRectMake(0, 0, self.view.frame.size.width, navBarHeight)];
    navigationBar.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    UINavigationItem *navigationItem = [[UINavigationItem alloc] initWithTitle:self.title];
    navigationBar.items = @[navigationItem];
    
    self.view.axis = UILayoutConstraintAxisVertical;
    // Backdrop behind the guest scene. Black rather than systemBackground: when
    // the guest doesn't fill the container — commonly in landscape, where an app
    // that renders at a different aspect (or hasn't caught up to a rotation yet)
    // leaves strips on the sides — this is what shows through, and white strips
    // read as broken. Black matches the letterboxing every other app does.
    self.view.backgroundColor = UIColor.blackColor;
    self.view.layer.cornerRadius = 0;
    self.view.layer.masksToBounds = YES;

    self.navigationBar = navigationBar;
    self.navigationItem = navigationBar.items.firstObject;
    if (!self.navigationBar.superview) {
        [self.view addArrangedSubview:self.navigationBar];
    }
    
    CGRect contentFrame = CGRectMake(0, 0, self.view.frame.size.width, self.view.frame.size.height - navBarHeight);
    UIView *fixedPositionContentView = [[UIView alloc] initWithFrame:contentFrame];
    self.contentView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    if([NSUserDefaults.lcSharedDefaults boolForKey:@"LCMultitaskBottomWindowBar"]) {
        [self.view insertArrangedSubview:fixedPositionContentView atIndex:0];
    } else {
        [self.view addArrangedSubview:fixedPositionContentView];
    }
    [self.view sendSubviewToBack:fixedPositionContentView];
    
    self.contentView = [[UIView alloc] initWithFrame:contentFrame];
    self.contentView.layer.anchorPoint = self.contentView.layer.position = CGPointMake(0, 0);
    self.contentView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [fixedPositionContentView addSubview:self.contentView];
    
    self.view.layer.borderWidth = 0;
    
    [self addChildViewController:_appSceneVC];
    [self.view insertSubview:_appSceneVC.view atIndex:0];
    _appSceneVC.view.translatesAutoresizingMaskIntoConstraints = NO;
    
    [self updateVerticalConstraints];
    [NSLayoutConstraint activateConstraints:@[
        [_appSceneVC.view.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [_appSceneVC.view.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor]
    ]];
    
    // Set the maximized frame now that navBar is created and hidden
    if(_isMaximized) {
        [self updateMaximizedFrameWithSettings:self.appSceneVC.settings];
    }
    
    [self updateOriginalFrame];
}


- (UIMenu *)customizeMenu {
    __weak typeof(self) weakSelf = self;

    UIAction *copyPid = [UIAction actionWithTitle:[NSString stringWithFormat:@"%@ %d", @"lc.multitask.copyPid".loc, self.appSceneVC.pid]
                                            image:[UIImage systemImageNamed:@"doc.on.doc"]
                                       identifier:nil
                                          handler:^(UIAction *action) {
        UIPasteboard.generalPasteboard.string = @(weakSelf.appSceneVC.pid).stringValue;
    }];

    // Asked through hasShared first, as the dock does: if there is no manager
    // there is no PiP, and the answer is known without building one.
    BOOL isPiPActive = PiPManager.hasShared && [PiPManager.shared isPiPWithVC:self.appSceneVC];
    UIAction *togglePiP = [UIAction actionWithTitle:isPiPActive ? @"lc.multitask.disablePip".loc : @"lc.multitask.enablePip".loc
                                              image:[UIImage systemImageNamed:isPiPActive ? @"pip.exit" : @"pip.enter"]
                                         identifier:nil
                                            handler:^(UIAction *action) {
        if(PiPManager.hasShared && [PiPManager.shared isPiPWithVC:weakSelf.appSceneVC]) {
            [PiPManager.shared stopPiP];
        } else {
            [PiPManager.shared startPiPWithVC:weakSelf.appSceneVC];
        }
    }];

    // A real slider living inside a real menu — the reason this menu is built in
    // UIKit rather than as a SwiftUI `Menu`, which takes actions and submenus only.
    UICustomViewMenuElement *scaleSlider = [UICustomViewMenuElement elementWithViewProvider:^UIView *(UICustomViewMenuElement *element) {
        return [weakSelf scaleSliderViewWithTitle:@"lc.multitask.scale".loc
                                              min:0.5
                                              max:2.0
                                            value:weakSelf.scaleRatio
                                     stepInterval:0.01];
    }];

    return [UIMenu menuWithTitle:@"" children:@[copyPid, togglePiP, scaleSlider]];
}

- (UIView *)scaleSliderViewWithTitle:(NSString *)title min:(CGFloat)minValue max:(CGFloat)maxValue value:(CGFloat)initialValue stepInterval:(CGFloat)step {
    __weak typeof(self) weakSelf = self;
    return [DecoratedAppSceneViewController scaleSliderViewWithTitle:title min:minValue max:maxValue value:initialValue stepInterval:step onChange:^(CGFloat newValue) {
        [weakSelf applyScaleRatio:newValue];
    }];
}

// Stolen from UIKitester
+ (UIView *)scaleSliderViewWithTitle:(NSString *)title min:(CGFloat)minValue max:(CGFloat)maxValue value:(CGFloat)initialValue stepInterval:(CGFloat)step onChange:(void (^)(CGFloat newValue))onChange {
    UIView *containerView = [[UIView alloc] init];
    containerView.translatesAutoresizingMaskIntoConstraints = NO;
    containerView.exclusiveTouch = YES;

    UIStackView *stackView = [[UIStackView alloc] init];
    stackView.axis = UILayoutConstraintAxisVertical;
    stackView.spacing = 0.0;
    stackView.translatesAutoresizingMaskIntoConstraints = NO;
    [containerView addSubview:stackView];
    
    [NSLayoutConstraint activateConstraints:@[
        [stackView.topAnchor constraintEqualToAnchor:containerView.topAnchor constant:10.0],
        [stackView.bottomAnchor constraintEqualToAnchor:containerView.bottomAnchor constant:-8.0],
        [stackView.leadingAnchor constraintEqualToAnchor:containerView.leadingAnchor constant:16.0],
        [stackView.trailingAnchor constraintEqualToAnchor:containerView.trailingAnchor constant:-16.0]
    ]];
    
    UILabel *label = [[UILabel alloc] init];
    label.text = title;
    label.translatesAutoresizingMaskIntoConstraints = NO;
    label.font = [UIFont boldSystemFontOfSize:12.0];
    [stackView addArrangedSubview:label];
    
    _UIPrototypingMenuSlider *slider = [[_UIPrototypingMenuSlider alloc] init];
    slider.minimumValue = minValue;
    slider.maximumValue = maxValue;
    slider.value = initialValue;
    slider.stepSize = step;
    
    NSLayoutConstraint *sliderHeight = [slider.heightAnchor constraintEqualToConstant:40.0];
    sliderHeight.active = YES;
    
    [stackView addArrangedSubview:slider];
    
    // UIAction rather than target/action: this builder is a class method, so there's
    // no instance to act as the target — the caller supplies the behaviour instead.
    [slider addAction:[UIAction actionWithHandler:^(UIAction *action) {
        onChange(((UISlider *)action.sender).value);
    }] forControlEvents:UIControlEventValueChanged];

    return containerView;
}

- (void)scaleSliderChanged:(_UIPrototypingMenuSlider *)slider {
    [self applyScaleRatio:slider.value];
}

- (void)applyScaleRatio:(CGFloat)newValue {
    self.scaleRatio = newValue;
    self.appSceneVC.scaleRatio = _scaleRatio;
    if(self.appSceneVC.usesHostingControllerAPI) {
        self.appSceneVC.contentView.transform = CGAffineTransformMakeScale(_scaleRatio, _scaleRatio);
    } else {
        self.appSceneVC.contentView.layer.sublayerTransform = CATransform3DMakeScale(_scaleRatio, _scaleRatio, 1.0);
    }
    __weak typeof(self) weakSelf = self;
    [self.appSceneVC updateFrameWithSettingsBlock:^(UIMutableApplicationSceneSettings *settings) {
        if(weakSelf.isMaximized) {
            [weakSelf updateMaximizedSafeAreaWithSettings:settings];
        } else {
            // it seems some apps don't honor these settings so we don't cover the top of the app
            settings.peripheryInsets = UIEdgeInsetsZero;
            settings.safeAreaInsetsPortrait = UIEdgeInsetsZero;
        }
    }];
}

- (void)closeWindow {
    _isAppTerminationRequested = true;
    if([_appSceneVC isAppRunning] || !_appSceneVC.isAppTerminationCleanUpCalled) {
        // -terminate covers both a running guest and one that never started —
        // the second happens when the window is closed while the app's files are
        // still being staged, and going through the teardown is what releases
        // them. Either way the teardown calls us back to close the window.
        [_appSceneVC terminate];
    } else {
        // The app already exited on its own and the teardown has run, so nothing
        // will call back; close the window directly.
        [self appSceneVCAppDidExit:self.appSceneVC];
    }
}

- (void)minimizeWindow {
    if (self.view.hidden) return;
    // Reduce Motion: the window gives way where it stands instead of collapsing
    // to a tenth of its size. The counterpart of the fade it comes back with, so
    // a guest window leaves the way it arrives.
    BOOL reduceMotion = UIAccessibilityIsReduceMotionEnabled();
    [UIView animateWithDuration:0.3 delay:0 options:UIViewAnimationOptionCurveEaseInOut animations:^{
        self.view.alpha = 0;
        if (!reduceMotion) {
            self.view.transform = CGAffineTransformMakeScale(0.1, 0.1);
        }
    } completion:^(BOOL finished) {
        if (!finished) return;
        [self finishMinimizeWindow];
    }];
}

/// Reports, once, that the guest is drawing its own content — the cue to drop the
/// launch screen the window opened with.
- (void)reportContentArrived {
    if (self.didReportContentArrived) return;
    self.didReportContentArrived = YES;
    // Posted rather than called, the way the bar's visibility travels the other
    // way between these two files — the dock is Swift and this is not, and a
    // notification needs neither side's generated header.
    [NSNotificationCenter.defaultCenter postNotificationName:@"LCWindowContentDidArrive" object:self.view];
}

- (void)finishMinimizeWindow {
    self.view.hidden = YES;
    self.view.transform = CGAffineTransformIdentity;
    [self.view.superview sendSubviewToBack:self.view];
    if(_geometryHeldInFlight) {
        _geometryHeldInFlight = NO;
        [self applyMaximizedLayout];
    }
}

- (void)minimizeWindowPiP {
    // Told to the dock the way `minimizeWindow`'s callers tell it: a window is
    // leaving the stage, and what the dock shows next depends on what that
    // leaves behind. Before the fade rather than after it, so the bar goes down
    // with the window as it does on the way home — the dock reads visibility
    // from the alpha, which the animation block sets at once.
    [MultitaskDockManager.shared windowDidEnterPiP:self.dataUUID];
    [UIView animateWithDuration:0.3 delay:0 options:UIViewAnimationOptionCurveEaseInOut animations:^{
        self.view.alpha = 0;
    } completion:^(BOOL finished) {
        // Cut short means brought back mid-fade — PiP stopped within a third of
        // a second of starting — and hiding the window now would undo that.
        if (!finished) return;
        self.view.hidden = YES;
    }];
}

- (void)unminimizeWindowPiP {
    [self unminimizeWindowPiPWithCompletion:nil];
}

- (void)unminimizeWindowPiPWithCompletion:(void (^)(void))completion {
    [UIView animateWithDuration:0.3 delay:0 options:UIViewAnimationOptionCurveEaseInOut animations:^{
        self.view.hidden = NO;
        self.view.alpha = 1;
    } completion:^(BOOL finished) {
        // Whether or not the fade ran its course: AVKit is waiting on this
        // before it finishes taking the PiP window down.
        if (completion) completion();
    }];
    // The other half of the note in `minimizeWindowPiP`. After the values above
    // are set, which the animation block does at once, so the dock finds a
    // window on stage when it looks.
    [MultitaskDockManager.shared windowDidExitPiP:self.dataUUID];
}

- (void)maximizeWindow {
    // Windows are always maximized in chromeless mode — no-op
    return;
}

- (void)appSceneVCAppDidExit:(AppSceneViewController*)vc {
    BOOL skipTerminationScreen = MultitaskRelaunchManager.skipsTerminatedScreen;
    BOOL isManual = _isAppTerminationRequested;
    if(isManual || skipTerminationScreen) {
        
        MultitaskDockManager *dock = [MultitaskDockManager shared];
        [dock removeRunningApp:self.dataUUID];
        
        // Gone without a send-off. Whatever closed this window has already drawn
        // the exit — the card swiped away, the sweep of Close All, the flight into
        // an icon — and this is only the teardown catching up afterwards. A page
        // curl here used to go unseen behind the switcher's backdrop; now that
        // Close All fades that backdrop while the windows are still tearing down,
        // it plays out in the open, several windows curling away one after another
        // once the cards have already gone.
        self.view.hidden = YES;
        [self.view removeFromSuperview];
        
        if(skipTerminationScreen) {
            [MultitaskRelaunchManager scheduleRelaunchIfNeededWithBundleId:self.appSceneVC.bundleId dataUUID:self.dataUUID isManualTermination:isManual];
        }
    } else {
        UILabel *label = [[UILabel alloc] initWithFrame:self.view.bounds];
        label.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        label.lineBreakMode = NSLineBreakByWordWrapping;
        label.numberOfLines = 0;
        label.text = NSLocalizedString(@"lc.multitaskAppWindow.appTerminated", @"");
        label.textAlignment = NSTextAlignmentCenter;
        [self.view insertSubview:label atIndex:0];
    }

    // A guest that was floating leaves its PiP window behind, showing a scene
    // nobody draws into any more, until the user finds the window's buttons.
    // It goes with the guest. Last, once the window has been dealt with above:
    // stopping brings the window back through the same path the restore button
    // uses, and that path has to find a window already closed, or one showing
    // the notice — not one on its way out.
    if(PiPManager.hasShared && [PiPManager.shared isPiPWithVC:vc]) {
        [PiPManager.shared stopPiP];
    } else if(PiPManager.hasShared) {
        // Armed but never floated. The controller is bound to a window that has
        // gone, and holds it; dropping it lets both go.
        [PiPManager.shared disarmIfInactiveForVC:vc];
    }
}

- (void)appSceneVC:(AppSceneViewController*)vc didInitializeWithError:(NSError *)error {
    dispatch_async(dispatch_get_main_queue(), ^{
        if(error) {
            // Nothing is coming, so take the launch screen down rather than leave
            // it standing in for an app that failed to start.
            [self reportContentArrived];
            [vc appTerminationCleanUp];
            UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"lc.common.error".loc message:error.localizedDescription preferredStyle:UIAlertControllerStyleAlert];
            [alert addAction:[UIAlertAction actionWithTitle:@"lc.common.ok".loc style:UIAlertActionStyleCancel handler:nil]];
            [alert addAction:[UIAlertAction actionWithTitle:@"lc.common.copy".loc style:UIAlertActionStyleDefault handler:^(UIAlertAction * _Nonnull action) {
                UIPasteboard.generalPasteboard.string = error.localizedDescription;
            }]];
            [self presentViewController:alert animated:YES completion:nil];
        } else {
            self.pid = vc.pid;
            [self updateOriginalFrame];
            if (self.pidAvailableHandler) {
                self.pidAvailableHandler(@(self.pid), nil);
            }
        }
    });
}

- (void)appSceneVC:(AppSceneViewController*)vc willPresentSceneWithSettings:(UIMutableApplicationSceneSettings *)settings {
    if(!_isMaximized) return;
    // Re-derived rather than trusted: these settings were filled in when the
    // window was built, and the switcher bar may have been laid out — and taken
    // its strip — at any point since.
    [self applyMaximizedGeometryToSettings:settings];
}

- (void)appSceneVCDidPresentScene:(AppSceneViewController*)vc {
    // The guest's scene is on screen now and it is drawing into it. Give that
    // first frame a moment to land, then let go of the launch screen this window
    // opened with. This is the cue that fires for every guest; the settings
    // update below is merely an earlier one when the guest happens to send it.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kContentGraceAfterScene * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [self reportContentArrived];
    });
    // The window was brought to the front when it was created, which is before
    // there was anything in it to float, so the arming that ran then declined.
    // This is the moment it can be taken up.
    [MultitaskDockManager.shared refreshPiPArming];
}

- (void)appSceneVCWillActivateScene:(AppSceneViewController *)vc {
    // Set up initial settings such as frame, safe area, etc
    [self appSceneVC:vc didUpdateFromSettings:vc.presenter.scene.settings.mutableCopy transitionContext:nil lifecycleActionType:0];
}

- (void)appSceneVC:(AppSceneViewController*)vc didUpdateFromSettings:(UIMutableApplicationSceneSettings *)baseSettings transitionContext:(id)newContext lifecycleActionType:(uint32_t)actionType {
    UIMutableApplicationSceneSettings *newSettings = [vc.presenter.scene.settings mutableCopy];
    newSettings.userInterfaceStyle = baseSettings.userInterfaceStyle;
    // Only when the guest has not yet said which way it is facing.
    //
    // This is a diff of the *host's* settings, and the guest's orientation is not
    // the host's. A landscape guest inside an upright host is the normal case here
    // (see LCWindowOrientation above), so stamping the host's value over it is not
    // a copy — it is a deletion. `vc.presenter.scene.settings.interfaceOrientation`
    // is the only record anywhere in this process that the guest is turned, and
    // this line is where it was being erased, on every host diff.
    //
    // What made that fatal is a few lines below: `updateMaximizedFrameWithSettings:`
    // hands this same field to `LCWindowOrientation` as `reported`. Stamped
    // portrait against an upright host window, the two agree, and that function
    // returns at its early guard — so the sticky device reading it falls back on
    // is never consulted. The guest is re-derived as upright.
    //
    // While the phone is genuinely held sideways this was survivable, because the
    // guest's landscape was carried by `deviceOrientation` below, which the host
    // kept re-asserting. At face-up that field stops carrying an answer (and the
    // guard below correctly refuses to copy the non-answer), so the orientation
    // has to be *remembered* rather than re-derived — and by then this line has
    // already erased the memory. Portrait is all that is left. That is the snap.
    if(newSettings.interfaceOrientation == UIInterfaceOrientationUnknown) {
        newSettings.interfaceOrientation = baseSettings.interfaceOrientation;
    }
    // Face-up and face-down are not viewing orientations, and must not be copied.
    //
    // This is the authoritative writer of the guest's orientation: it pushes
    // straight to the scene at the bottom of this method, so whatever it says
    // overrules anything computed in AppSceneViewController. And it is driven by a
    // host scene-settings *diff*, not by UIDeviceOrientationDidChangeNotification —
    // which is why guarding that notification changed nothing.
    //
    // The host's own scene settings carry the raw SpringBoard reading, face-up
    // included. Copying it verbatim tells the guest process "the device is now
    // face-up", and the guest's UIKit — unhooked in multitask, since the guest
    // hooks are gated on !isLiveProcess — resolves that non-answer to portrait and
    // rotates itself. Nothing in the host moved, which is exactly why the host's
    // own interfaceOrientation never changed while the guest visibly turned.
    //
    // Not assigning leaves the guest holding the orientation it already had, which
    // is what a native app does when it is laid on a table.
    if(UIDeviceOrientationIsValidInterfaceOrientation(baseSettings.deviceOrientation)) {
        newSettings.deviceOrientation = baseSettings.deviceOrientation;
    }
    newSettings.foreground = YES;
    
    // HARD LOCK: same rule on the host-diff path — hold the shape while flat.
    BOOL frozen = LCRotationIsLocked() && _lockedGuestOrientation != UIInterfaceOrientationUnknown;
    // And while the window flies into its icon; see -applyMaximizedGeometryToSettings:.
    if(!frozen && [LCWindowFlight holdsGeometryOfView:self.view]) {
        frozen = YES;
        _geometryHeldInFlight = YES;
    }
    if(!frozen) {
        if(self.isMaximized) {
            [self updateMaximizedFrameWithSettings:newSettings];
        } else {
            [self updateWindowedFrameWithSettings:newSettings];
        }
    }
    // The orientation the guest was just told it is in — not the host's. When the
    // two differ (a landscape guest inside an upright host) `updateMaximizedFrameWithSettings:`
    // has already corrected `newSettings.interfaceOrientation` via `LCWindowOrientation`,
    // and reaching past that for the host's value re-derives the drawable's
    // width/height swap from the orientation the guest is *not* in.
    if(!frozen) {
        [self applySceneFrameToSettings:newSettings orientation:newSettings.interfaceOrientation];
    }

    [_appSceneVC.presenter.scene updateSettings:newSettings withTransitionContext:newContext completion:nil];

    // An early cue when it comes, but only that: a settings update arrives when
    // the guest changes something about its scene, and an app that changes
    // nothing never sends one. `appSceneVCDidPresentScene:` is what this actually
    // relies on.
    [self reportContentArrived];
}

// Resizes the guest scene's drawable to match the current container view size.
// Must be called whenever self.view.frame changes (rotation, bar show/hide),
// otherwise apps that don't push their own settings update keep rendering at the
// old size and leave a blank strip where the view grew.
- (void)applySceneFrameToSettings:(UIMutableApplicationSceneSettings *)settings orientation:(UIInterfaceOrientation)orientation {
    // Measured from bounds, never from frame. A window carries a transform while
    // it is growing out of its icon, and `frame` is undefined under one — the
    // guest's scene is presented during exactly that stretch, so reading the frame
    // told it that it was icon-sized. It would lay out for that and stay wrong
    // until something forced a fresh settings update, which is why toggling the
    // bar appeared to repair it. Bounds is the size the window really occupies,
    // transform or no transform.
    CGSize windowSize = self.view.bounds.size;
    // A hidden bar takes up none of the window, whatever its own frame still
    // says. It is built at its full height and collapsed to nothing by a
    // constraint, and a stack view does not lay out an arranged subview it is not
    // showing — so early on, before anything has laid it out, the frame still
    // reads its full height. Taking that off the guest's drawable leaves the
    // picture short of the window it is drawn into, centred, with a strip of the
    // black backdrop above and below it.
    CGFloat barHeight = self.navigationBar.hidden ? 0 : self.navigationBar.frame.size.height;
    CGRect newFrame = CGRectMake(0, 0, windowSize.width/self.scaleRatio, (windowSize.height - barHeight)/self.scaleRatio);
    if(UIInterfaceOrientationIsLandscape(orientation)) {
        settings.frame = CGRectMake(0, 0, newFrame.size.height, newFrame.size.width);
    } else {
        settings.frame = CGRectMake(0, 0, newFrame.size.width, newFrame.size.height);
    }
}

- (void)adjustNavigationBarButtonSpacingWithNegativeSpacing:(CGFloat)spacing rightMargin:(CGFloat)margin {
    if (!self.navigationBar) return;
    [self findAndAdjustButtonBarStackView:self.navigationBar withSpacing:spacing rightMargin:margin];
}

- (void)findAndAdjustButtonBarStackView:(UIView *)view withSpacing:(CGFloat)spacing rightMargin:(CGFloat)margin {
    for (UIView *subview in view.subviews) {
        if ([subview isKindOfClass:NSClassFromString(@"_UIButtonBarStackView")]) {
            if ([subview respondsToSelector:@selector(setSpacing:)]) {
                [(_UIButtonBarStackView *)subview setSpacing:spacing];
            }
            
            if (subview.superview) {
                for (NSLayoutConstraint *constraint in subview.superview.constraints) {
                    if ((constraint.firstItem == subview && constraint.firstAttribute == NSLayoutAttributeTrailing) ||
                        (constraint.secondItem == subview && constraint.secondAttribute == NSLayoutAttributeTrailing)) {
                        constraint.constant = (constraint.firstItem == subview) ? -margin : margin;
                        break;
                    }
                }
                
                [subview setNeedsLayout];
                [subview.superview setNeedsLayout];
            }
            
            return;
        }
        
        [self findAndAdjustButtonBarStackView:subview withSpacing:spacing rightMargin:margin];
    }
}




- (void)moveWindow:(UIPanGestureRecognizer*)sender {
    if(_isMaximized) return;
    
    CGPoint point = [sender translationInView:self.view];
    [sender setTranslation:CGPointZero inView:self.view];

    self.view.center = CGPointMake(self.view.center.x + point.x, self.view.center.y + point.y);
    [self updateOriginalFrame];
}

- (void)resizeWindow:(UIPanGestureRecognizer*)sender {
    if(_isMaximized) return;
    
    CGPoint point = [sender translationInView:self.view];
    [sender setTranslation:CGPointZero inView:self.view];

    CGRect frame = self.view.frame;
    frame.size.width = MAX(50, frame.size.width + point.x);
    frame.size.height = MAX(50, frame.size.height + point.y);
    self.view.frame = frame;
    [self updateOriginalFrame];
}

- (void)touchesBegan:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    [super touchesBegan:touches withEvent:event];
    // FIXME: how to bring view to front when touching the passthrough view?
    [self.view.superview bringSubviewToFront:self.view];
}

- (void)updateVerticalConstraints {
    // Update safe area insets
    if(_isMaximized) {
        __weak typeof(self) weakSelf = self;
        self.appSceneVC.nextUpdateSettingsBlock = ^(UIMutableApplicationSceneSettings *settings) {
            [weakSelf updateMaximizedFrameWithSettings:settings];
        };
    }
    
    self.navigationBar.hidden = YES;
    
    [NSLayoutConstraint deactivateConstraints:self.activatedVerticalConstraints];
    self.activatedVerticalConstraints = @[
        [self.appSceneVC.view.topAnchor constraintEqualToAnchor:self.view.topAnchor],
        [self.appSceneVC.view.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],
        [self.navigationBar.heightAnchor constraintEqualToConstant:0]
    ];
    [NSLayoutConstraint activateConstraints:self.activatedVerticalConstraints];
}

- (void)switcherBarVisibilityChanged {
    [UIView animateWithDuration:0.3 animations:^{
        [self applyMaximizedLayout];
    }];
}

- (void)refreshMaximizedLayout {
    [self applyMaximizedLayout];
}

- (BOOL)awaitingFirstLayout {
    return _lockedGuestOrientation == UIInterfaceOrientationUnknown;
}

/// Re-derives everything about a maximized window's geometry from the screen, the
/// switcher bar and the orientation as they are now, and gets it to the guest.
///
/// Safe to call before the guest's scene exists, which is most of a window's
/// opening. A window is built, framed and told the bar has arrived long before
/// its guest has started, and pushing settings into a scene that is not there yet
/// is a silent no-op — which is how a freshly opened app came up laid out for the
/// screen the window was given at construction, from before the bar had been laid
/// out and so had no strip to reserve. It drew underneath the bar until something
/// later pushed settings of its own and put the frame right; toggling the bar was
/// that something, which is why it looked like a repair. With no scene yet the
/// same answer is written into the settings the scene will be created from, so
/// the guest is laid out for the window it is really going into from its first
/// frame.
- (void)applyMaximizedLayout {
    if(!_isMaximized) return;
    FBScene *scene = self.appSceneVC.presenter.scene;
    if(scene) {
        [scene updateSettingsWithBlock:^(UIMutableApplicationSceneSettings *settings) {
            [self applyMaximizedGeometryToSettings:settings];
        }];
    } else {
        [self applyMaximizedGeometryToSettings:self.appSceneVC.settings];
    }
}

/// The window's own frame and the insets the guest keeps clear, then the guest's
/// drawable. In that order: the drawable is measured from the frame set above it,
/// and resizing the window without resizing the picture inside it is what leaves
/// the backdrop showing wherever the two disagree.
- (void)applyMaximizedGeometryToSettings:(UIMutableApplicationSceneSettings *)settings {
    // Everything below is measured from the screen this window is on, so there is
    // nothing to derive while it is not on one. A closed window's controller
    // outlives the view being taken out of the hierarchy, and answering that with
    // zeroes would collapse it rather than leave it be.
    if(!self.view.window) return;
    // HARD LOCK: no geometry is re-derived while the phone is flat.
    //
    // Freezing the orientation alone was not enough, and the reason is that the
    // guest does not need to be *told* it rotated in order to look rotated. It is
    // handed a drawable of a given shape, and a responsive app given a 402x874
    // drawable draws its portrait layout whatever its orientation says. So the
    // shape is the thing that has to hold still, not the label on it.
    //
    // Gated on having a settled orientation so a guest opened while the phone is
    // already flat still gets its initial layout; only re-derivation is blocked.
    if(LCRotationIsLocked() && _lockedGuestOrientation != UIInterfaceOrientationUnknown) return;
    // Nor while the window flies into its icon. The flight was aimed from where
    // the window stood as it set off, and a window moved under it lands off its
    // icon by as much as it moved. That is what the bar sliding away on the way
    // home did: its strip measures nothing as it goes, so a window re-framed then
    // grew by the bar's height and dropped by half of it. Caught up in
    // -finishMinimizeWindow, once the window is out of sight.
    if([LCWindowFlight holdsGeometryOfView:self.view]) {
        _geometryHeldInFlight = YES;
        return;
    }
    _geometryHeldInFlight = NO;
    [self updateMaximizedFrameWithSettings:settings];
    [self applySceneFrameToSettings:settings orientation:LCGuestSceneOrientation(settings)];
}

- (UIEdgeInsets)updateMaximizedSafeAreaWithSettings:(UIMutableApplicationSceneSettings *)settings {
    BOOL bottomWindowBar = [NSUserDefaults.lcSharedDefaults boolForKey:@"LCMultitaskBottomWindowBar"];
    UIEdgeInsets safeAreaInsets = self.view.window.safeAreaInsets;
    if(self.navigationBar.hidden) {
        // Whatever the bar already covers is not the guest's to keep clear a second
        // time — but the edge it covers is not always the bottom. It is the viewer's
        // right in landscape, which is the window's top or its bottom depending on
        // which way the phone was turned, so the reservation comes off every edge
        // rather than being assumed onto one. Portrait is unchanged by arithmetic:
        // the reservation there is larger than the home-indicator inset it cancels.
        //
        // The sides are handed on as the window has them. A turned window runs under
        // the sensor housing as a real app does (see -updateMaximizedFrameWithSettings:),
        // and the guest keeps its content clear of the island through the inset iOS
        // gives any app turned on its side: the island's clearance on both long
        // edges. An iPhone Duo's status bar comes through the same way — its strip is
        // the window's inset on that side, and the guest keeps out of it as it would
        // anywhere.
        //
        // The top is dropped in a wide window, which is asked of the window's own
        // shape, not of how the device is being held. The two were the same answer
        // while the window always turned with the phone, and the top inset was read
        // from the device — a sticky reading, because the raw one turns face-up on a
        // tilt and would put the inset back and shift the guest's content for it.
        // Neither is right once the host can be pinned: an orientation-locked guest
        // keeps a landscape window while the phone is turned upright, and the device
        // reading then restored the top inset and laid a strip of the black backdrop
        // across the top of a guest that had not moved. It fails the other way too —
        // a portrait window under a sideways phone had its housing clearance taken
        // away and drew under the island. The window's shape cannot be wrong about
        // the window.
        CGSize windowSize = self.view.window.bounds.size;
        if(windowSize.width > windowSize.height) {
            safeAreaInsets.top = 0;
        }
        UIEdgeInsets barInsets = MultitaskDockManager.shared.barReservedInsets;
        safeAreaInsets.top    = MAX(safeAreaInsets.top    - barInsets.top,    0);
        safeAreaInsets.left   = MAX(safeAreaInsets.left   - barInsets.left,   0);
        safeAreaInsets.bottom = MAX(safeAreaInsets.bottom - barInsets.bottom, 0);
        safeAreaInsets.right  = MAX(safeAreaInsets.right  - barInsets.right,  0);
        settings.peripheryInsets = safeAreaInsets;
        safeAreaInsets = UIEdgeInsetsZero;
    } else if(bottomWindowBar) {
        // allow the control bar to overlap the bottom safe area
        safeAreaInsets.bottom = 0;
        settings.peripheryInsets = safeAreaInsets;
        safeAreaInsets.top = safeAreaInsets.left = safeAreaInsets.right = 0;
    } else {
        settings.peripheryInsets = UIEdgeInsetsMake(0, safeAreaInsets.left, safeAreaInsets.bottom, safeAreaInsets.right);
        safeAreaInsets.bottom = safeAreaInsets.left = safeAreaInsets.right = 0;
    }
    
    // scale peripheryInsets to match the scale ratio
    settings.peripheryInsets = UIEdgeInsetsMake(settings.peripheryInsets.top/_scaleRatio, settings.peripheryInsets.left/_scaleRatio, settings.peripheryInsets.bottom/_scaleRatio, settings.peripheryInsets.right/_scaleRatio);
    if(UIDevice.currentDevice.userInterfaceIdiom != UIUserInterfaceIdiomPad) {
        // HARD LOCK: while the phone is flat, do not re-derive the guest's
        // orientation at all — reassert the one it had when the phone was last
        // actually being held.
        //
        // Everything that decides a guest's orientation funnels through here, so
        // this is where "flat means frozen" is cheapest to guarantee. It is a
        // deliberate refusal to compute rather than a better computation: every
        // earlier attempt at this bug tried to make the derivation smarter, and
        // each one still had some input that resolved a face-up reading to
        // portrait. Nothing derived from a device that is not answering can be
        // trusted, so while it is not answering, nothing is derived.
        UIInterfaceOrientation currentOrientation;
        if(LCRotationIsLocked() && _lockedGuestOrientation != UIInterfaceOrientationUnknown) {
            currentOrientation = _lockedGuestOrientation;
        } else {
            // The window's orientation, not the one the settings claim: they
            // disagree exactly when this goes wrong.
            currentOrientation = LCWindowOrientation(self.view, settings);
            // Only remember an answer reached while the phone was being held.
            if(!LCRotationIsLocked() && currentOrientation != UIInterfaceOrientationUnknown) {
                _lockedGuestOrientation = currentOrientation;
            }
        }
        settings.interfaceOrientation = currentOrientation;
        if(UIInterfaceOrientationIsLandscape(currentOrientation)) {
            safeAreaInsets.top = 0;
        }
        settings.safeAreaInsetsPortrait = LCUIEdgeInsetsRotateToOrientation(settings.peripheryInsets, currentOrientation);

    } else {
        settings.safeAreaInsetsPortrait = UIEdgeInsetsMake(settings.peripheryInsets.top, settings.peripheryInsets.left, settings.peripheryInsets.bottom, settings.peripheryInsets.right);
    }

    [self applyHostStatusBarHeightsToSettings:settings];

    safeAreaInsets.bottom = 0;
    return safeAreaInsets;
}

/// Hands the host's status bar heights to the guest's scene.
///
/// SpringBoard tells an app how tall its status bar is through the app's scene,
/// and a hosted scene carries no heights unless it is given them. The guest's
/// status bar manager then reports no status bar at all — UIKit takes a height of
/// zero to mean the bar is hidden, and its frame is empty — although ours is drawn
/// across the top of a maximized window, over the guest. An app that places its
/// top bar by that frame puts it underneath ours, where it can be neither seen
/// nor tapped. Instagram reads its status bar height from that frame.
///
/// Every orientation is handed on as the host has it, so a guest turned against
/// the host still asks for its own: a landscape guest on a phone is told there is
/// no status bar, as it would be in a scene of its own. A window that starts
/// below the switcher bar is not under the status bar at all.
- (void)applyHostStatusBarHeightsToSettings:(UIMutableApplicationSceneSettings *)settings {
    UIStatusBarManager *hostStatusBar = self.view.window.windowScene.statusBarManager;
    if(![hostStatusBar respondsToSelector:@selector(defaultStatusBarHeightInOrientation:)] ||
       ![settings respondsToSelector:@selector(setDefaultStatusBarHeight:forOrientation:)]) {
        return;
    }
    BOOL underStatusBar = MultitaskDockManager.shared.barReservedInsets.top <= 0;
    const UIInterfaceOrientation orientations[] = {
        UIInterfaceOrientationPortrait, UIInterfaceOrientationPortraitUpsideDown,
        UIInterfaceOrientationLandscapeLeft, UIInterfaceOrientationLandscapeRight,
    };
    for(size_t i = 0; i < sizeof(orientations) / sizeof(orientations[0]); i++) {
        CGFloat height = underStatusBar ? [hostStatusBar defaultStatusBarHeightInOrientation:orientations[i]] : 0;
        [settings setDefaultStatusBarHeight:height / _scaleRatio forOrientation:orientations[i]];
    }
}

- (void)updateMaximizedFrameWithSettings:(UIMutableApplicationSceneSettings *)settings {
    // Bounds, not frame: `frame` is in screen coordinates, and what is built here is
    // a rectangle inside the window. The two agree exactly while the window is full
    // screen, which on a phone it always is — and disagree by the window's origin
    // when it is not, placing the guest off by that much.
    CGRect maxFrame = UIEdgeInsetsInsetRect(self.view.window.bounds, [self updateMaximizedSafeAreaWithSettings:settings]);
    // Reserve exactly the bar's strip thickness so the app sits flush with it — no
    // background gap showing through. The dock reports the strip as insets on the
    // edge the bar is actually drawn along, which is the only thing that answers
    // this correctly once the layout and the device are not turned the same way;
    // the interface orientation used to be asked instead, and it names an edge the
    // bar may not be on. Zero insets when no bar is up.
    UIEdgeInsets barInsets = MultitaskDockManager.shared.barReservedInsets;
    maxFrame = UIEdgeInsetsInsetRect(maxFrame, barInsets);

    // Not held off the sensor housing when turned. A real app turned on its side
    // runs under the island and keeps its own controls clear of it through its
    // safe area, which the guest is handed as the window has it (see
    // -updateMaximizedSafeAreaWithSettings:). A window cut short beside the island
    // was narrower than the app expected by the island's clearance, and an app
    // that keeps the same margin on both sides of its window, as YouTube's player
    // does, kept that clearance a second time inside it: the controls on the
    // island's side stood twice as far in, and the picture sat off centre.
    [self setWindowFrame:maxFrame];
}

/// Places the window through bounds and centre rather than `frame`.
///
/// A window carries a transform while it is growing out of its icon, or
/// shrinking back into it, and `frame` is undefined under a transform —
/// assigning it there is read back through the transform and leaves the window's
/// bounds distorted for good. The scene reports its settings as the guest starts
/// up, which is exactly when the opening animation is still running, so this path
/// has to be safe to take mid-flight. With no transform it is identical to
/// setting the frame.
- (void)setWindowFrame:(CGRect)frame {
    self.view.bounds = CGRectMake(0, 0, frame.size.width, frame.size.height);
    self.view.center = CGPointMake(CGRectGetMidX(frame), CGRectGetMidY(frame));
}

- (void)updateWindowedFrameWithSettings:(UIMutableApplicationSceneSettings *)settings {
    UIEdgeInsets safeAreaInsets = self.view.window.safeAreaInsets;
    CGRect maxFrame = UIEdgeInsetsInsetRect(self.view.window.frame, safeAreaInsets);
    settings.peripheryInsets = UIEdgeInsetsZero;
    settings.safeAreaInsetsPortrait = UIEdgeInsetsZero;
    
    CGRect newFrame = CGRectMake(self.originalFrame.origin.x * maxFrame.size.width, self.originalFrame.origin.y * maxFrame.size.height, self.originalFrame.size.width, self.originalFrame.size.height);
    CGPoint center = self.view.center;
    CGRect frame = CGRectZero;
    frame.size.width = MIN(newFrame.size.width, maxFrame.size.width);
    frame.size.height = MIN(newFrame.size.height, maxFrame.size.height);
    CGFloat oobOffset = MAX(30, frame.size.width - 30);
    frame.origin.x = MAX(maxFrame.origin.x - oobOffset, MIN(CGRectGetMaxX(maxFrame) - frame.size.width + oobOffset, center.x - frame.size.width / 2));
    frame.origin.y = MAX(maxFrame.origin.y, MIN(center.y - frame.size.height / 2, CGRectGetMaxY(maxFrame) - frame.size.height));
    [UIView animateWithDuration:0.3 animations:^{
        [self setWindowFrame:frame];
    }];
}

- (void)updateOriginalFrame {
    if(_isMaximized) return;
    CGRect maxFrame = UIEdgeInsetsInsetRect(self.view.window.frame, self.view.window.safeAreaInsets);
    // Derived from bounds and centre rather than frame, which is undefined while
    // the window is animating into or out of its icon.
    CGSize size = self.view.bounds.size;
    CGPoint origin = CGPointMake(self.view.center.x - size.width / 2, self.view.center.y - size.height / 2);
    // save origin as normalized coordinates
    self.originalFrame = CGRectMake(origin.x / maxFrame.size.width, origin.y / maxFrame.size.height, size.width, size.height);
}

@end
