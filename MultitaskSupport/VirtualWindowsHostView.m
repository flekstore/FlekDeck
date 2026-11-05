//
//  VirtualWindowsHostView.m
//  LiveContainer
//
//  Created by Duy Tran on 22/2/26.
//
#import "DecoratedAppSceneViewController.h"
#import "VirtualWindowsHostView.h"
#import "LiveContainerSwiftUI-Swift.h"

static void *kBackdropObservationContext = &kBackdropObservationContext;

@interface VirtualWindowsHostView() {
    /// The size the windows were last laid out against, so a layout pass that
    /// changes nothing costs nothing.
    CGRect _lastLaidOutBounds;
    /// Set while the backdrop itself is being moved, so the reordering methods
    /// below do not set about moving it again.
    BOOL _placingBackdrop;
    /// A window on its way out of the host, which the backdrop is placed as if it
    /// had already left.
    __weak UIView *_leavingWindow;
}
/// Opaque black filler, laid directly under the window in front. Guest windows
/// don't always cover the screen — a landscape-only app on a portrait device is
/// laid out as a scaled landscape strip, and even a maximized one leaves
/// slivers outside its rounded corners. Without this, what shows in those gaps
/// is whatever is behind the window: the launcher behind the host view, which is
/// white in light mode, or another window. Hidden whenever no app window is
/// visible, so the springboard and its wallpaper are untouched on the home state.
///
/// Under the window in front rather than under them all. Switching apps leaves
/// the one switched from visible behind the new one, and from the back the
/// backdrop covered the launcher only, so that window showed through every gap
/// of the one in front: the app or FlekDeck page before it.
@property(nonatomic) UIView *backdropView;
@end

@implementation VirtualWindowsHostView
- (instancetype)init {
    CGRect frame = ((UIWindowScene *)UIApplication.sharedApplication.connectedScenes.anyObject).keyWindow.bounds;
    self = [super initWithFrame:frame];
    self.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    self.shouldForwardTapAction = YES;

    _backdropView = [[UIView alloc] initWithFrame:self.bounds];
    _backdropView.backgroundColor = UIColor.blackColor;
    _backdropView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    // Takes the touches that land on it. It only shows with a window up, and a
    // finger in one of that window's gaps otherwise reached whatever lay unseen
    // underneath: the window behind, or the springboard's icons. Hidden, it is no
    // hit-test candidate, so with no window up hitTest: below still reports
    // "nothing here" and taps fall through to the springboard.
    _backdropView.userInteractionEnabled = YES;
    _backdropView.hidden = YES;
    [self addSubview:_backdropView];

    return self;
}

- (void)dealloc {
    for(UIView *subview in self.subviews) {
        if(subview == _backdropView) continue;
        [subview removeObserver:self forKeyPath:@"hidden" context:kBackdropObservationContext];
        [subview removeObserver:self forKeyPath:@"alpha" context:kBackdropObservationContext];
    }
}

#pragma mark Backdrop

// Windows are shown/hidden from a dozen places (launch, minimize, restore, PiP,
// "one app on stage", termination). Observing the two properties that decide
// visibility keeps the backdrop correct without having to hook every one of them.
- (void)didAddSubview:(UIView *)subview {
    [super didAddSubview:subview];
    if(subview == _backdropView) return;
    [subview addObserver:self forKeyPath:@"hidden" options:0 context:kBackdropObservationContext];
    [subview addObserver:self forKeyPath:@"alpha" options:0 context:kBackdropObservationContext];
    [self updateBackdropVisibility];
}

- (void)willRemoveSubview:(UIView *)subview {
    [super willRemoveSubview:subview];
    if(subview == _backdropView) return;
    [subview removeObserver:self forKeyPath:@"hidden" context:kBackdropObservationContext];
    [subview removeObserver:self forKeyPath:@"alpha" context:kBackdropObservationContext];
    // Straight away, as if it had gone already. The backdrop lies directly under
    // the window in front, and with that window gone it would be lying over the
    // rest, blacking them out until the check below.
    _leavingWindow = subview;
    [self updateBackdropVisibility];
    _leavingWindow = nil;
    // The subview is still in self.subviews at this point; re-check once it's gone.
    dispatch_async(dispatch_get_main_queue(), ^{
        [self updateBackdropVisibility];
    });
}

- (void)observeValueForKeyPath:(NSString *)keyPath ofObject:(id)object change:(NSDictionary *)change context:(void *)context {
    if(context != kBackdropObservationContext) {
        [super observeValueForKeyPath:keyPath ofObject:object change:change context:context];
        return;
    }
    [self updateBackdropVisibility];
}

- (void)setBackdropSuspended:(BOOL)backdropSuspended {
    _backdropSuspended = backdropSuspended;
    [self updateBackdropVisibility];
}

- (void)setBackdropHeldForQuickSwitch:(BOOL)backdropHeldForQuickSwitch {
    _backdropHeldForQuickSwitch = backdropHeldForQuickSwitch;
    [self updateBackdropVisibility];
}

- (void)updateBackdropVisibility {
    if(self.backdropSuspended || self.backdropHeldForQuickSwitch) {
        // A window is on its way into or out of an icon, or being swiped aside;
        // what is behind it should be the home screen, not a black field.
        _backdropView.hidden = YES;
        return;
    }
    UIView *frontmostWindow = nil;
    for(UIView *subview in self.subviews.reverseObjectEnumerator) {
        if(subview == _backdropView || subview == _leavingWindow) continue;
        if(!subview.hidden && subview.alpha > 0.1) {
            frontmostWindow = subview;
            break;
        }
    }
    if(frontmostWindow) [self placeBackdropUnder:frontmostWindow];
    _backdropView.hidden = !frontmostWindow;
}

/// Puts the backdrop directly under `window`, the window in front, so it covers
/// every window behind as well as the launcher. Windows here are all maximized,
/// so what it hides of the ones behind is only what showed through the gaps.
- (void)placeBackdropUnder:(UIView *)window {
    NSArray<UIView *> *subviews = self.subviews;
    NSUInteger index = [subviews indexOfObjectIdenticalTo:window];
    if(index == NSNotFound || (index > 0 && subviews[index - 1] == _backdropView)) return;
    _placingBackdrop = YES;
    [super insertSubview:_backdropView belowSubview:window];
    _placingBackdrop = NO;
}

#pragma mark Window order

// A window brought forward, or sent back, changes which one is in front and so
// where the backdrop belongs. Nothing about the order can be observed the way
// `hidden` and `alpha` are, so every way of changing it puts the backdrop back
// under the window now in front.
- (void)addSubview:(UIView *)view {
    [super addSubview:view];
    [self windowOrderDidChange];
}

- (void)bringSubviewToFront:(UIView *)view {
    [super bringSubviewToFront:view];
    [self windowOrderDidChange];
}

- (void)sendSubviewToBack:(UIView *)view {
    [super sendSubviewToBack:view];
    [self windowOrderDidChange];
}

- (void)insertSubview:(UIView *)view atIndex:(NSInteger)index {
    [super insertSubview:view atIndex:index];
    [self windowOrderDidChange];
}

- (void)insertSubview:(UIView *)view belowSubview:(UIView *)siblingSubview {
    [super insertSubview:view belowSubview:siblingSubview];
    [self windowOrderDidChange];
}

- (void)insertSubview:(UIView *)view aboveSubview:(UIView *)siblingSubview {
    [super insertSubview:view aboveSubview:siblingSubview];
    [self windowOrderDidChange];
}

- (void)exchangeSubviewAtIndex:(NSInteger)index1 withSubviewAtIndex:(NSInteger)index2 {
    [super exchangeSubviewAtIndex:index1 withSubviewAtIndex:index2];
    [self windowOrderDidChange];
}

- (void)windowOrderDidChange {
    if(_placingBackdrop || !_backdropView) return;
    [self updateBackdropVisibility];
}

#pragma mark Layout

/// Rotation is the case that matters: the host resizes with the window, but a
/// guest window is framed explicitly and a guest's drawable is sized from a
/// scene settings update. Neither happens on its own when the device turns —
/// the only thing that used to refresh them was a settings update pushed by the
/// guest itself, so an app that pushes none kept the shape it had and the black
/// backdrop showed along the edge that grew.
///
/// Driven from layout rather than from an orientation notification because this
/// fires when the geometry has actually changed — the notification can arrive
/// before the window has resized, and it says nothing at all about a Split View
/// or Slide Over resize, which needs exactly the same repair.
/// Whether guest geometry may currently be re-derived. Mirrors the predicate in
/// the scene controllers; both read the same `LCRotationLock`.
static BOOL LCRotationIsLocked(void) {
    return LCRotationLock.isLocked;
}

- (void)layoutSubviews {
    [super layoutSubviews];
    // HARD LOCK: while the phone is flat, do not propagate a bounds change to the
    // guests — and deliberately return BEFORE recording it as laid out.
    //
    // Recording it would mark the new bounds as handled while the guests were
    // never told, so lifting the phone would find nothing left to reconcile and
    // the freeze would become permanent. Leaving `_lastLaidOutBounds` stale means
    // the very next layout pass after the phone is picked up still sees a
    // difference and repairs everything in one go.
    BOOL locked = LCRotationIsLocked();
    if(!locked && CGRectEqualToRect(self.bounds, _lastLaidOutBounds)) return;
    if(!locked) _lastLaidOutBounds = self.bounds;
    for(UIView *subview in self.subviews) {
        if(subview == _backdropView) continue;
        DecoratedAppSceneViewController *decoratedVC = (id)subview._viewDelegate;
        if(![decoratedVC isKindOfClass:DecoratedAppSceneViewController.class]) continue;
        // While the lock holds, only a guest that has never settled on an
        // orientation is laid out. That is its first layout, which the lock was
        // never meant to block — both scene controllers say so explicitly and gate
        // their own guards on having something to hold. This one did not, so a phone
        // lying on a desk while an app opened left that app with whatever geometry
        // it was presented with: sized before the bar had taken its strip, or
        // against a safe area that had not resolved yet, and cut off with no later
        // pass to repair it.
        if(locked && !decoratedVC.awaitingFirstLayout) continue;
        [decoratedVC refreshMaximizedLayout];
    }
}

#pragma mark Touch handling

- (BOOL)handleStatusBarTapAction:(UIAction *)action {
    if(!self.shouldForwardTapAction) return NO;
    // grab the frontmost app window, if it's visible pass this event to it
    UIView *frontmostView = self.subviews.lastObject;
    if(!frontmostView.hidden) {
        DecoratedAppSceneViewController *decoratedVC = (id)frontmostView._viewDelegate;
        // Settings, Installer and FlekSt0re share this host as SwiftUI pages,
        // not guest apps. Leave their tap to UIKit.
        if(![decoratedVC isKindOfClass:DecoratedAppSceneViewController.class]) return NO;
        [decoratedVC.appSceneVC handleStatusBarTapAction:action];
    }
    return !frontmostView.hidden;
}
- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    UIView* hitView = [super hitTest:point withEvent:event];
    if(hitView == self) {
        self.shouldForwardTapAction = NO;
        return nil;
    } else {
        self.shouldForwardTapAction = YES;
        // A finger on an app is that app in use, which ends a run of swipes along
        // the bar: the next swipe starts from the apps' order as it then is. One
        // in a gap beside it, on the backdrop, is not.
        if(hitView && hitView != _backdropView && event.type == UIEventTypeTouches) {
            [MultitaskDockManager.shared quickSwitchWindowTouched];
        }
        return hitView;
    }
}
@end
