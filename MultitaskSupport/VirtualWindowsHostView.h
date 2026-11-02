//
//  VirtualWindowsHostView.h
//  LiveContainer
//
//  Created by Duy Tran on 22/2/26.
//
@import UIKit;

API_AVAILABLE(ios(16.0))
@interface VirtualWindowsHostView: UIView
@property(nonatomic) BOOL shouldForwardTapAction;
/// Holds the backdrop back while a window is travelling into or out of its icon.
///
/// The backdrop is there to letterbox a guest whose drawable does not fill the
/// screen, so it blacks out everything behind any visible window. A window in
/// flight is visible but much smaller than the screen, and blacking out the rest
/// hides the very thing the flight is crossing: the springboard. Worse, it
/// arrives in one frame, because a window's opacity reaches its final value the
/// moment its animation is committed rather than when it looks that way.
@property(nonatomic) BOOL backdropSuspended;
/// Holds the backdrop back while a swipe along the bar moves the window in front
/// aside. What that uncovers is the springboard, which the dock lays blurred
/// under this view for the length of the swipe, and the black would cover it.
/// Kept apart from `backdropSuspended`, which flights set and clear on their own
/// schedule, so neither lets the backdrop back while the other still holds it.
@property(nonatomic) BOOL backdropHeldForQuickSwitch;
- (BOOL)handleStatusBarTapAction:(UIAction *)action;
@end
