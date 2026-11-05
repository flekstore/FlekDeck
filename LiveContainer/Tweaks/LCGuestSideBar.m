//
//  LCGuestSideBar.m
//  LiveContainer
//
//  Tells the host where a multitask guest's own side bar sits, on an iPhone Duo.
//
//  From iOS 27.1 an iPhone Duo stands an app's tab bar, back button and toolbar
//  items in the column its status bar runs down, below the time and Wi-Fi, and
//  FlekDeck's buttons over an app stand in that same column. Left where they are,
//  they cover the app's tab bar. The host can't see into the app to know where its
//  items are, so the app, which can, says.
//
//  UIKit draws the side bar in its floating bar container, each group of items —
//  the tab bar, the back button, a run of toolbar items — on a glass platter of
//  its own. This finds the platters standing in the column and hands the host the
//  lowest group, which is the tab bar where the app has one, and the bottom of
//  everything above it: where there is room for FlekDeck's buttons is the host's
//  to decide.
//
//  Measured whenever the container hears its groups change or lays itself out,
//  and once more after it has settled, since the platters are placed by the
//  container's own hosting view a moment after it hears.
//
@import UIKit;
@import ObjectiveC;

#import <notify.h>

#import "Tweaks.h"

static NSString *gSideBarName;
static int gSideBarToken = -1;
/// What the host was last told.
static uint64_t gLastState;
static BOOL gSoonPending;
static NSUInteger gTriggerCount;
static Class gContainerClass;
/// Every floating bar container the hooks below have seen, held weakly. Only
/// these are walked, never the app's whole window: a container lays itself out
/// as it arrives, so none is missed, and what is inside one is a few dozen views.
static NSHashTable<UIView *> *gContainers;

/// Groups closer together than this are taken as one: no gap this small could
/// hold FlekDeck's buttons, which leaves at most the room under the lowest group
/// and above it to report. iOS spaces its own groups 12pt apart, and the top
/// bar's items from a bottom toolbar's by about 70.
static const CGFloat LCSideBarGroupJoin = 100;

/// A glass platter: one group of items. A private Swift class, whose runtime
/// name carries a hash of its source file, so it is known by the end of it.
static BOOL LCIsGlassPlatter(UIView *view) {
    return [NSStringFromClass(view.class) hasSuffix:@"UIPlatformGlassInteractionView"];
}

typedef struct {
    CGFloat bandMinX, bandMaxX, maxHeight;
    NSUInteger visited;
} LCSideBarWalk;

/// Whether anything is showing `view`: none of it, up to its window, hidden.
static BOOL LCIsShown(UIView *view) {
    for(UIView *ancestor = view; ancestor; ancestor = ancestor.superview) {
        if(ancestor.hidden || ancestor.alpha < 0.01) return NO;
    }
    return YES;
}

/// Collects the platters inside a floating bar container that stand in the side
/// column. Nothing hidden counts, nor anything as tall as the window, which says
/// nothing about where the items are.
static void LCCollectSideBarGroups(UIView *view, UIWindow *window,
                                   LCSideBarWalk *walk, NSMutableArray<NSValue *> *groups) {
    if(view.hidden || view.alpha < 0.01) return;
    // A walk over someone else's views, so capped.
    if(++walk->visited > 2000) return;
    if(LCIsGlassPlatter(view)) {
        CGRect frame = [view convertRect:view.bounds toView:window];
        if(frame.size.width >= 8 && frame.size.height >= 8 && frame.size.height < walk->maxHeight &&
           CGRectGetMinX(frame) >= walk->bandMinX && CGRectGetMaxX(frame) <= walk->bandMaxX) {
            [groups addObject:[NSValue valueWithCGRect:frame]];
        }
        // A group's own items are all inside its platter.
        return;
    }
    for(UIView *subview in view.subviews) {
        LCCollectSideBarGroups(subview, window, walk, groups);
    }
}

/// The report for one window, packed for the host into the notification's state:
/// the lowest group's top and bottom in the low two 16-bit fields, the bottom of
/// everything above it in the third (0 for nothing), and the window's height in
/// the fourth, with its top bit set for a side bar down the right. 0 for a window
/// with no side bar, or nothing in it.
static uint64_t LCMeasureSideBarInWindow(UIWindow *window, NSArray<UIView *> *containers) API_AVAILABLE(ios(27.1)) {
    UITraitCollection *traits = window.traitCollection;
    UIVerticalBarEdge edge = traits.verticalBarEdge;
    if(edge == UIVerticalBarEdgeUnspecified) return 0;
    BOOL rightToLeft = traits.layoutDirection == UITraitEnvironmentLayoutDirectionRightToLeft;
    BOOL onRight = (edge == UIVerticalBarEdgeTrailing) != rightToLeft;

    // The column is the safe area's inset on its side.
    CGRect bounds = window.bounds;
    UIEdgeInsets insets = window.safeAreaInsets;
    CGFloat strip = onRight ? insets.right : insets.left;
    if(strip < 1) return 0;
    LCSideBarWalk walk = {
        .bandMinX = onRight ? CGRectGetMaxX(bounds) - strip - 2 : CGRectGetMinX(bounds) - 2,
        .bandMaxX = onRight ? CGRectGetMaxX(bounds) + 2 : CGRectGetMinX(bounds) + strip + 2,
        .maxHeight = bounds.size.height * 0.9,
    };
    NSMutableArray<NSValue *> *groups = [NSMutableArray array];
    for(UIView *container in containers) {
        if(container.window != window || !LCIsShown(container)) continue;
        LCCollectSideBarGroups(container, window, &walk, groups);
    }
    if(groups.count == 0) return 0;

    [groups sortUsingComparator:^NSComparisonResult(NSValue *a, NSValue *b) {
        CGFloat ay = CGRectGetMinY(a.CGRectValue), by = CGRectGetMinY(b.CGRectValue);
        return ay < by ? NSOrderedAscending : (ay > by ? NSOrderedDescending : NSOrderedSame);
    }];
    // Top to bottom, joining the groups that stand close together.
    CGFloat lowerTop = 0, lowerBottom = 0, upperBottom = 0;
    BOOL started = NO;
    for(NSValue *value in groups) {
        CGRect frame = value.CGRectValue;
        if(started && CGRectGetMinY(frame) - lowerBottom < LCSideBarGroupJoin) {
            lowerBottom = MAX(lowerBottom, CGRectGetMaxY(frame));
            continue;
        }
        // A new group lower down: everything so far is above it.
        if(started) upperBottom = lowerBottom;
        lowerTop = CGRectGetMinY(frame);
        lowerBottom = CGRectGetMaxY(frame);
        started = YES;
    }

    uint64_t top = (uint64_t)MIN(MAX(floor(lowerTop), 0), 0xFFFF);
    uint64_t bottom = (uint64_t)MIN(MAX(ceil(lowerBottom), 0), 0xFFFF);
    uint64_t above = (uint64_t)MIN(MAX(ceil(upperBottom), 0), 0xFFFF);
    uint64_t height = (uint64_t)MIN(MAX(round(bounds.size.height), 1), 0x7FFF);
    return top | (bottom << 16) | (above << 32) | (height << 48) | (onRight ? (1ULL << 63) : 0);
}

/// The windows holding a container, the app's key window first: the one its side
/// bar is in.
static uint64_t LCMeasureSideBar(void) API_AVAILABLE(ios(27.1)) {
    // A copy: nothing here should lay anything out, but a container laid out
    // meanwhile would add itself to the table being walked.
    NSArray<UIView *> *containers = gContainers.allObjects;
    NSMutableArray<UIWindow *> *windows = [NSMutableArray array];
    for(UIView *container in containers) {
        UIWindow *window = container.window;
        if(!window || window.hidden || [windows containsObject:window]) continue;
        if(window.isKeyWindow) [windows insertObject:window atIndex:0];
        else [windows addObject:window];
    }
    for(UIWindow *window in windows) {
        uint64_t state = LCMeasureSideBarInWindow(window, containers);
        if(state) return state;
    }
    return 0;
}

static void LCReportSideBar(void) {
    if(@available(iOS 27.1, *)) {
        uint64_t state = LCMeasureSideBar();
        if(state == gLastState) return;
        gLastState = state;
        if(gSideBarToken != -1) notify_set_state(gSideBarToken, state);
        notify_post(gSideBarName.UTF8String);
    }
}

/// On the next turn of the run loop, and again half a second after the last time
/// anything changed, by when the container's hosting view has placed the groups
/// it was told about and any animation of them has run.
static void LCScheduleSideBarReport(UIView *container) {
    if(!gSideBarName) return;
    [gContainers addObject:container];
    if(!gSoonPending) {
        gSoonPending = YES;
        dispatch_async(dispatch_get_main_queue(), ^{
            gSoonPending = NO;
            LCReportSideBar();
        });
    }
    NSUInteger trigger = ++gTriggerCount;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        if(trigger == gTriggerCount) LCReportSideBar();
    });
}

/// Runs the report after `selector` on the container, keeping what it did. The
/// container's own method where it has one, or its superclass's under a method of
/// its own where it only inherits it, so nothing outside the container is touched.
/// Left alone where the method isn't there, or doesn't take what it is expected to.
static void LCReportAfter(Class cls, SEL selector, unsigned int objectArguments, BOOL lastIsBool) {
    Method method = class_getInstanceMethod(cls, selector);
    if(!method || method_getNumberOfArguments(method) != 2 + objectArguments + (lastIsBool ? 1 : 0)) return;
    for(unsigned int index = 0; index < objectArguments + (lastIsBool ? 1 : 0); index++) {
        char type[16] = {0};
        method_getArgumentType(method, 2 + index, type, sizeof(type));
        BOOL isFlag = lastIsBool && index == objectArguments;
        if(isFlag ? (type[0] != 'B' && type[0] != 'c') : type[0] != '@') return;
    }
    IMP original = method_getImplementation(method);
    id block = nil;
    if(objectArguments == 0 && !lastIsBool) {
        block = ^(id view) {
            ((void (*)(id, SEL))original)(view, selector);
            LCScheduleSideBarReport(view);
        };
    } else if(objectArguments == 1 && !lastIsBool) {
        block = ^(id view, id first) {
            ((void (*)(id, SEL, id))original)(view, selector, first);
            LCScheduleSideBarReport(view);
        };
    } else if(objectArguments == 2 && !lastIsBool) {
        block = ^(id view, id first, id second) {
            ((void (*)(id, SEL, id, id))original)(view, selector, first, second);
            LCScheduleSideBarReport(view);
        };
    } else if(objectArguments == 1 && lastIsBool) {
        block = ^(id view, id first, BOOL flag) {
            ((void (*)(id, SEL, id, BOOL))original)(view, selector, first, flag);
            LCScheduleSideBarReport(view);
        };
    }
    if(!block) return;
    IMP replacement = imp_implementationWithBlock(block);
    if(!class_addMethod(cls, selector, replacement, method_getTypeEncoding(method))) {
        method_setImplementation(method, replacement);
    }
}

void LCGuestSideBarInit(NSString *dataUUID) {
    if(dataUUID.length == 0) return;
    if(@available(iOS 27.1, *)) {} else return;
    gContainerClass = NSClassFromString(@"_UIFloatingBarContainerView");
    if(!gContainerClass) return;
    gContainers = [NSHashTable weakObjectsHashTable];

    // A fixed literal prefix keyed by container, the shape LCGuestPiP's names
    // have, so the host and the guest arrive at it without asking each other.
    gSideBarName = [NSString stringWithFormat:@"com.kdt.livecontainer.sidebar.%@", dataUUID];
    // Registered once and kept: the state belongs to the name for as long as
    // someone holds a registration on it, and the host reads it as it starts
    // listening, not only when it hears a change.
    if(notify_register_check(gSideBarName.UTF8String, &gSideBarToken) != NOTIFY_STATUS_OK) {
        gSideBarToken = -1;
    }
    // Nothing to report yet, whatever an earlier run of the app left on the name:
    // an app with no bars at all never measures, and would otherwise leave it.
    gLastState = 0;
    if(gSideBarToken != -1) notify_set_state(gSideBarToken, 0);
    notify_post(gSideBarName.UTF8String);

    // Where the container lays itself out or comes and goes: a turn, a fold, a
    // window resized, a screen with its own bar presented or dismissed.
    LCReportAfter(gContainerClass, @selector(layoutSubviews), 0, NO);
    LCReportAfter(gContainerClass, @selector(didMoveToWindow), 0, NO);
    // And where it hears its groups change: a page pushed or popped, toolbar
    // items coming and going, a tab added.
    LCReportAfter(gContainerClass, NSSelectorFromString(@"setTabBarItemGroups:animated:"), 1, YES);
    LCReportAfter(gContainerClass, NSSelectorFromString(@"_groupDidUpdateItems:removedItems:"), 2, NO);
    LCReportAfter(gContainerClass, NSSelectorFromString(@"_groupDidUpdateVisibility:"), 1, NO);
    LCReportAfter(gContainerClass, NSSelectorFromString(@"_groupDidUpdateRepresentative:fromRepresentative:"), 2, NO);
    LCReportAfter(gContainerClass, NSSelectorFromString(@"removeNavigationBarRepresentation"), 0, NO);
}
