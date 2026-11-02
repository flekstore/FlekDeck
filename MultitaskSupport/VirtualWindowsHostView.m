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
}
/// Opaque black filler shown behind the app windows. Guest windows don't always
/// cover the screen — a landscape-only app on a portrait device is laid out as a
/// scaled landscape strip, and even a maximized one leaves slivers outside its
/// rounded corners. Without this, what shows in those gaps is the launcher behind
/// the host view, which is white in light mode. Hidden whenever no app window is
/// visible, so the springboard and its wallpaper are untouched on the home state.
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
    // Never a hit-test candidate, so hitTest: below still reports "nothing here"
    // and lets taps fall through to the springboard when no window is up.
    _backdropView.userInteractionEnabled = NO;
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
    [self sendSubviewToBack:_backdropView];
    [self updateBackdropVisibility];
}

- (void)willRemoveSubview:(UIView *)subview {
    [super willRemoveSubview:subview];
    if(subview == _backdropView) return;
    [subview removeObserver:self forKeyPath:@"hidden" context:kBackdropObservationContext];
    [subview removeObserver:self forKeyPath:@"alpha" context:kBackdropObservationContext];
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
    BOOL anyWindowVisible = NO;
    for(UIView *subview in self.subviews) {
        if(subview == _backdropView) continue;
        if(!subview.hidden && subview.alpha > 0.1) {
            anyWindowVisible = YES;
            break;
        }
    }
    _backdropView.hidden = !anyWindowVisible;
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
        // the bar: the next swipe starts from the apps' order as it then is.
        if(hitView && event.type == UIEventTypeTouches) {
            [MultitaskDockManager.shared quickSwitchWindowTouched];
        }
        return hitView;
    }
}
@end
