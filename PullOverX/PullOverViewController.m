//
//  PullOverViewController.m
//  PullOverX
//
//  Created by Will Smillie on 4/8/19.
//

#import "PullOverViewController.h"
#import "POHostSessionController.h"
#import "POHostedWindowChromeView.h"
#import "POQuickSwitchDragCoordinator.h"
#import "POQuickSwitchMetrics.h"
#import "POSplitSessionController.h"
#import "QuickSwitchHorizontalBarView.h"
#import "POAppRailView.h"
#import "../POPPath.h"
#import "../POLocalization.h"
#import <objc/message.h>
#include <stdlib.h>
#define HANDLE_EDGE_GAP 5
#define CONTENT_EDGE_GAP 5
#define CONTENT_CORNER_RADIUS 20
#define CONTENT_SHADOW_OPACITY 0.28
#define CONTENT_SHADOW_FADE_DISTANCE 12.0
#define CLOSED_CONTENT_OFFSET_EPSILON 0.5
#define PO_KEYBOARD_ZOOM_REQUESTED_SCALE 1.60
#define PO_KEYBOARD_ZOOM_MINIMUM_USEFUL_SCALE 1.12
#define PO_CARD_SCALE_EPSILON 0.001
#define PO_HANDLE_CARD_SCALE_ANIMATION_DURATION 0.25
#define PO_SCALED_PROGRAMMATIC_CLOSE_DURATION 0.28
#define PO_SCALED_CLOSE_POST_COMMIT_CLEANUP_DELAY 0.035
#define PO_HANDLE_GUARD_MINIMUM_REVEAL_DURATION 2.0
// 分屏悬浮窗口(DynamicStage 式真悬浮):进入悬浮的最小外扩倍数、回到钉底的最大
// 收缩比例(相对悬浮默认框)、双指超限拉伸(预夹紧尺寸越过窗口上限的倍数)触发全屏接管。
#define PO_HOSTED_FLOAT_ANIMATION_DURATION 0.24
#define PO_HOSTED_FLOAT_ENTER_FACTOR 1.12
#define PO_HOSTED_FLOAT_EXIT_FRACTION 0.80
#define PO_HOSTED_FLOAT_TAKEOVER_OVERSPREAD_FACTOR 1.25
#define PO_HOSTED_FLOAT_MIN_WIDTH 140.0

typedef NS_OPTIONS(NSUInteger, POKeyboardZoomSuspensionReason) {
    POKeyboardZoomSuspensionNone     = 0,
    POKeyboardZoomSuspensionDragging = 1 << 0,
    POKeyboardZoomSuspensionRotation = 1 << 1,
    POKeyboardZoomSuspensionClosing  = 1 << 2,
};

typedef NS_ENUM(NSInteger, POKeyboardNotificationState) {
    POKeyboardNotificationStateUnknown = 0,
    POKeyboardNotificationStateHidden,
    POKeyboardNotificationStateVisible,
};

typedef NS_ENUM(NSUInteger, POCardScaleContext) {
    POCardScaleContextNone,
    POCardScaleContextLandscapeShellPortraitHosted,
};

typedef NS_ENUM(NSUInteger, POCardScaleTransitionSource) {
    POCardScaleTransitionSourceKeyboard,
    POCardScaleTransitionSourceHandle,
    POCardScaleTransitionSourceReconcile,
};

typedef NS_ENUM(NSUInteger, POPanelState) {
    POPanelStateClosed,
    POPanelStateOpening,
    POPanelStateInteractive,
    POPanelStateOpen,
    POPanelStateClosing,
};

typedef NS_ENUM(NSUInteger, POQuickSwitchLayoutMode) {
    POQuickSwitchLayoutModeVerticalSide,
    POQuickSwitchLayoutModeHorizontalBottom,
};

typedef NS_ENUM(NSUInteger, POInteractionMode) {
    POInteractionModeSplitPassthrough,
    POInteractionModeDrawerModal,
    POInteractionModeQuickSwitchModal,
};

typedef NS_ENUM(NSUInteger, POHandlePanIntent) {
    POHandlePanIntentNone,
    POHandlePanIntentRevealHandle,
    POHandlePanIntentNubHandle,
    POHandlePanIntentOpenPanel,
    POHandlePanIntentClosePanel,
    POHandlePanIntentVerticalCardMove,
};

static BOOL POIsConcretePresentationOrientation(UIInterfaceOrientation orientation) {
    return orientation == UIInterfaceOrientationPortrait ||
        orientation == UIInterfaceOrientationPortraitUpsideDown ||
        orientation == UIInterfaceOrientationLandscapeLeft ||
        orientation == UIInterfaceOrientationLandscapeRight;
}

static CGFloat POPresentationAngleForOrientation(UIInterfaceOrientation orientation) {
    switch (orientation) {
        case UIInterfaceOrientationLandscapeLeft:
            return (CGFloat)M_PI_2;
        case UIInterfaceOrientationLandscapeRight:
            return (CGFloat)-M_PI_2;
        case UIInterfaceOrientationPortraitUpsideDown:
            return (CGFloat)M_PI;
        case UIInterfaceOrientationPortrait:
        default:
            return 0;
    }
}

@interface PullOverViewController ()<POHostSessionControllerDelegate, UIGestureRecognizerDelegate, POAppRailViewDelegate, POHostedWindowChromeViewDelegate>{
    NSString *pinnedBundleId;
    UIView *contextView;
    UIView *externalSceneStack;
    
    UIView *mirrorZoneView;
    CAShapeLayer *mirrorZoneBorder;
    UIImageView *mirrorZoneIconView;
    BOOL mirrorZoneHighlighted;
    UIView *panelBackdropView;
    UIView *quickSwitchBackdropView;
    UITapGestureRecognizer *panelBackdropTapGestureRecognizer;
    UIPanGestureRecognizer *panelBackdropPanGestureRecognizer;
    UIView *shadowView;
    UIView *keyboardZoomContainer;
    UIView *cantHostCanvas;
    UIImageView *cantHostIconView;
    UILabel *cantHostLabel;
    
    POHostSessionController *hostSession;
    POPanelState panelState;
    BOOL interactiveHostIntentIssued;
    BOOL interactiveHostResumeRequired;
    NSString *presentationBundleId;
    FBScene *presentationSceneIdentity;
    CGSize presentationCanvasSize;
    UIInterfaceOrientation presentationOrientation;
    CGSize presentationSourceCanvasSize;
    UIInterfaceOrientation presentationSourceOrientation;
    UIView *presentationSnapshotView;
    NSString *presentationSnapshotBundleId;
    FBScene *presentationSnapshotSceneIdentity;
    BOOL presentationSnapshotIsTargetPlaceholder;
    BOOL presentationSnapshotCapturedLeftHanded;
    BOOL runtimeCategoryTransitionSnapshotActive;
    BOOL runtimeCategoryTransitionSnapshotFallbackArmed;
    BOOL runtimeCategoryTransitionSnapshotFading;
    CGSize presentationSnapshotSize;
    UIInterfaceOrientation presentationSnapshotOrientation;
    UIInterfaceOrientation presentationSnapshotRenderSourceOrientation;
    NSMutableDictionary<NSString *, NSDictionary *> *presentationSnapshotCache;
    NSMutableArray<NSString *> *presentationSnapshotCacheOrder;
    CADisplayLink *presentationHandoffDisplayLink;
    NSUInteger presentationHandoffGeneration;
    NSUInteger presentationHandoffStableFrames;
    NSString *presentationHandoffBundleId;
    BOOL presentationRetainedAfterRelease;
    int retainedPresentationProcessPID;
    CGPoint handlePoint;
    CGFloat chromeScale;
    CGFloat scale;
    CGFloat contentLayoutWidth;
    UIInterfaceOrientation hostedLayoutOrientation;
    BOOL pendingOpenState;
    BOOL splitLayoutActive;
    CGFloat panelPanStartOffsetX;
    POHandlePanIntent handlePanIntent;
    BOOL handlePanStartedNubbed;
    BOOL nubRevealRailActive;
    CGFloat panelVerticalMoveStartAnchorY;
    BOOL scrollSnapAnimationInProgress;
    BOOL quickSwitchOpeningApp;
    QuickSwitchHorizontalBarView *quickSwitchHorizontalBarView;
    POAppRailView *appRailView;
    UIView *quickSwitchInteractionOverlayView;
    UIView<POQuickSwitchMenuPresenting> *presentedQuickSwitchMenu;
    POQuickSwitchDragCoordinator *quickSwitchDragCoordinator;
    NSUInteger quickSwitchPrewarmGeneration;
    NSString *quickSwitchPrewarmBundleId;
    NSUInteger deferredOpenGeneration;
    NSString *externallyActivatedBundleId;
    NSUInteger externallyActivatedGeneration;
    NSUInteger handleIconRefreshGeneration;
    BOOL showingCantHost;
    BOOL quickSwitchYieldActive;
    CGRect quickSwitchSavedContainerFrame;
    CGRect keyboardZoomBaseFrame;
    UIView *handleVisualHandoffSnapshotView;
    NSUInteger handleVisualHandoffGeneration;
    BOOL runtimeHostedCategoryTransitionAnimating;
    NSUInteger runtimeHostedCategoryTransitionGeneration;
    BOOL hostedCategoryTransitionPending;
    FBScene *deferredRuntimePublishedScene;
    UIView *deferredRuntimePublishedSceneStack;
    NSString *deferredRuntimePublishedBundleId;
    NSUInteger deferredRuntimePublishedGeneration;
    BOOL runtimeDeferredPublicationStageScheduled;
    BOOL runtimeScenePublicationStaging;
    CGFloat portraitHostedLandscapeHandleAnchorY;
    POKeyboardNotificationState keyboardNotificationState;
    CGRect floatingRailKeyboardFrame;
    BOOL hostedKeyboardLayerPresent;
    BOOL keyboardHideAnimationInFlight;
    NSUInteger keyboardStateHostGeneration;
    BOOL keyboardZoomApplied;
    POKeyboardZoomSuspensionReason keyboardZoomSuspensionReasons;
    NSUInteger keyboardZoomGeneration;
    BOOL keyboardZoomSuppressedForCurrentSession;
    CGFloat appliedCardScale;
    CGFloat closingFrozenCardScale;
    BOOL scaledProgrammaticCloseAnimating;
    BOOL scaledProgrammaticCloseNeedsLayout;
    BOOL deferScaledCloseSessionCleanup;
    NSTimeInterval lastKeyboardAnimationDuration;
    UIViewAnimationOptions lastKeyboardAnimationOptions;
    NSNumber *origOffset;
    CGSize lastLaidOutSize;
    // 分屏会话内的悬浮窗口状态:卡片脱离下半区钉底后可拖动/双指缩放。
    POHostedWindowChromeView *hostedWindowChrome;
    UIPinchGestureRecognizer *hostedWindowPinchGestureRecognizer;
    BOOL hostedWindowFloating;
    CGRect hostedFloatingWindowFrame;
    CGRect splitPinnedCardFrame;
    BOOL hostedWindowPinchActive;
    BOOL hostedWindowPinchStartedFloating;
    CGRect hostedWindowPinchBaseFrame;
}

-(void)retainPresentationAfterReleaseIfPossible;
-(BOOL)hasLiveRetainedPresentationForBundleId:(NSString *)bundleId;
-(UIInterfaceOrientation)cachedPresentationOrientationForBundleId:(NSString *)bundleId;
-(UIInterfaceOrientation)resolvedHostedOrientationForBundleId:(NSString *)bundleId
                                                     manager:(ContextHostManager *)manager;
-(void)flushDeferredRuntimeScenePublicationIfNeeded;
-(void)scheduleRuntimeScenePublicationStagingIfNeeded;
-(BOOL)prepareRuntimeCategoryTransitionSnapshotFromSourceOrientation:(UIInterfaceOrientation)sourceOrientation;
-(void)prewarmRuntimeCategoryTransitionSnapshot;
-(void)retargetRuntimeCategoryTransitionSnapshotForOrientation:(UIInterfaceOrientation)orientation;
-(void)beginQuickSwitchSessionForMenu:(UIView<POQuickSwitchMenuPresenting> *)menu;
-(void)finishQuickSwitchSessionForMenu:(UIView<POQuickSwitchMenuPresenting> *)menu;
-(void)dismissPresentedQuickSwitchMenuImmediately;
-(void)hideQuickSwitchBackdropImmediately;
-(void)refreshHandleIconIfNeeded;
-(void)resetAutoNubTimerWithMinimumDelay:(NSTimeInterval)minimumDelay;

@end

@implementation PullOverViewController
@synthesize scrollView, handleScrollView;

- (void)viewDidLoad {
    [super viewDidLoad];
    panelBackdropView = [[UIView alloc] initWithFrame:self.view.bounds];
    panelBackdropView.backgroundColor = UIColor.blackColor;
    panelBackdropView.alpha = 0;
    panelBackdropView.userInteractionEnabled = YES;
    [self.view addSubview:panelBackdropView];

    panelBackdropTapGestureRecognizer = [[UITapGestureRecognizer alloc]
        initWithTarget:self action:@selector(panelBackdropDidTap:)];
    panelBackdropTapGestureRecognizer.delegate = self;
    [panelBackdropView addGestureRecognizer:panelBackdropTapGestureRecognizer];

    panelBackdropPanGestureRecognizer = [[UIPanGestureRecognizer alloc]
        initWithTarget:self action:@selector(panelBackdropDidPan:)];
    panelBackdropPanGestureRecognizer.delegate = self;
    [panelBackdropView addGestureRecognizer:panelBackdropPanGestureRecognizer];

    mirrorZoneView = [[UIView alloc] initWithFrame:CGRectZero];
    mirrorZoneView.backgroundColor = [UIColor colorWithWhite:1 alpha:0.08];
    mirrorZoneView.layer.cornerCurve = kCACornerCurveContinuous;
    mirrorZoneView.alpha = 0;
    [self.view addSubview:mirrorZoneView];

    mirrorZoneBorder = [CAShapeLayer layer];
    mirrorZoneBorder.strokeColor = UIColor.whiteColor.CGColor;
    mirrorZoneBorder.fillColor = nil;
    mirrorZoneBorder.lineWidth = PO_QUICKSWITCH_DROP_BORDER_WIDTH;
    mirrorZoneBorder.lineDashPattern = PO_QUICKSWITCH_DROP_DASH_PATTERN;
    mirrorZoneBorder.lineCap = kCALineCapRound;
    [mirrorZoneView.layer addSublayer:mirrorZoneBorder];

    mirrorZoneIconView = [[UIImageView alloc] initWithFrame:CGRectMake(0, 0, 24, 24)];
    mirrorZoneIconView.image = [[UIImage systemImageNamed:@"arrow.left.arrow.right"]
                                imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate];
    mirrorZoneIconView.tintColor = UIColor.whiteColor;
    mirrorZoneIconView.contentMode = UIViewContentModeScaleAspectFit;
    [mirrorZoneView addSubview:mirrorZoneIconView];

    scrollView = [[UIScrollView alloc] initWithFrame:CGRectZero];
    [scrollView setDecelerationRate:UIScrollViewDecelerationRateFast];
    [scrollView setBackgroundColor:[UIColor clearColor]];
    [scrollView setShowsHorizontalScrollIndicator:NO];
    scrollView.contentInsetAdjustmentBehavior = UIScrollViewContentInsetAdjustmentNever;
    [scrollView setPagingEnabled:NO];
    scrollView.bounces = YES;
    scrollView.alwaysBounceHorizontal = YES;
    scrollView.scrollEnabled = NO;
    [scrollView setDelegate:self];
    [self.view addSubview:scrollView];
    
    handleScrollView = [[BaseScrollView alloc] initWithFrame:CGRectZero];
    [handleScrollView setShowsVerticalScrollIndicator:NO];
    [handleScrollView setBackgroundColor:[UIColor clearColor]];
    [handleScrollView setDecelerationRate:UIScrollViewDecelerationRateFast];
    [handleScrollView setClipsToBounds:NO];
    handleScrollView.contentInsetAdjustmentBehavior = UIScrollViewContentInsetAdjustmentNever;
    [handleScrollView setDelegate:self];
    [scrollView addSubview:handleScrollView];

    
    self.handle = [[POHandle alloc] initWithController:self];
    [self.handle setDelegate:self];
    [handleScrollView addSubview:self.handle];
    
    self.quickSwitchTableView = [[QuickSwitchTableView alloc] init];
    self.quickSwitchTableView.selectionDelegate = self;
    [handleScrollView addSubview:self.quickSwitchTableView];

    quickSwitchInteractionOverlayView = [[UIView alloc] initWithFrame:self.view.bounds];
    quickSwitchInteractionOverlayView.backgroundColor = [UIColor clearColor];
    quickSwitchInteractionOverlayView.clipsToBounds = NO;
    quickSwitchInteractionOverlayView.userInteractionEnabled = NO;
    quickSwitchInteractionOverlayView.hidden = YES;
    [self.view addSubview:quickSwitchInteractionOverlayView];

    quickSwitchDragCoordinator = [[POQuickSwitchDragCoordinator alloc]
        initWithOverlayView:quickSwitchInteractionOverlayView];
    [mirrorZoneView removeFromSuperview];
    [quickSwitchInteractionOverlayView addSubview:mirrorZoneView];

    quickSwitchHorizontalBarView = [[QuickSwitchHorizontalBarView alloc] init];
    quickSwitchHorizontalBarView.selectionDelegate = self;
    [quickSwitchInteractionOverlayView addSubview:quickSwitchHorizontalBarView];

    appRailView = [[POAppRailView alloc] initWithFrame:CGRectZero];
    appRailView.railDelegate = self;
    appRailView.hidden = YES;
    appRailView.alpha = 0;
    [self.view addSubview:appRailView];

    self.contentView = [[UIView alloc] initWithFrame:CGRectZero];
    self.contentView.backgroundColor = [UIColor secondarySystemBackgroundColor];
    self.contentView.layer.cornerRadius = CONTENT_CORNER_RADIUS;
    if (@available(iOS 13.0, *)) {
        self.contentView.layer.cornerCurve = kCACornerCurveContinuous;
    }
    self.contentView.clipsToBounds = YES;

    keyboardZoomContainer = [[UIView alloc] initWithFrame:CGRectZero];
    keyboardZoomContainer.backgroundColor = [UIColor clearColor];
    keyboardZoomContainer.clipsToBounds = NO;    keyboardZoomContainer.hidden = YES;
    [scrollView addSubview:keyboardZoomContainer];

    quickSwitchBackdropView = [[UIView alloc] initWithFrame:scrollView.bounds];
    quickSwitchBackdropView.backgroundColor = UIColor.blackColor;
    quickSwitchBackdropView.alpha = 0;
    quickSwitchBackdropView.userInteractionEnabled = YES;
    [scrollView addSubview:quickSwitchBackdropView];
    [scrollView bringSubviewToFront:handleScrollView];
    
    shadowView = [[UIView alloc] initWithFrame:keyboardZoomContainer.bounds];
    shadowView.backgroundColor = [UIColor clearColor];
    shadowView.layer.shadowColor = [UIColor blackColor].CGColor;
    shadowView.layer.shadowOffset = CGSizeMake(0, 1);
    shadowView.layer.shadowRadius = 8;
    shadowView.layer.shadowOpacity = 0;
    shadowView.layer.shadowPath = [UIBezierPath bezierPathWithRoundedRect:shadowView.bounds cornerRadius:CONTENT_CORNER_RADIUS].CGPath;
    [keyboardZoomContainer addSubview:shadowView];

    [keyboardZoomContainer addSubview:self.contentView];

    // 分屏/悬浮窗口 chrome:关闭按钮 + 悬浮拖动条;双指捏合做形态缩放。
    hostedWindowChrome = [[POHostedWindowChromeView alloc] initWithFrame:CGRectZero];
    hostedWindowChrome.delegate = self;
    hostedWindowChrome.mode = POHostedWindowChromeModeHidden;
    hostedWindowChrome.hidden = YES;
    [self.contentView addSubview:hostedWindowChrome];

    hostedWindowPinchGestureRecognizer = [[UIPinchGestureRecognizer alloc]
        initWithTarget:self action:@selector(handleHostedWindowPinch:)];
    hostedWindowPinchGestureRecognizer.delegate = self;
    [keyboardZoomContainer addGestureRecognizer:hostedWindowPinchGestureRecognizer];

    NSString *savedPinnedBundleId = [[NSUserDefaults standardUserDefaults] stringForKey:@"lastPinnedBundleId"];
    if ([POApplicationHelper isUserFacingApplicationBundleId:savedPinnedBundleId]) {
        pinnedBundleId = savedPinnedBundleId;
    } else {
        if (savedPinnedBundleId.length > 0) {
            [[NSUserDefaults standardUserDefaults] removeObjectForKey:@"lastPinnedBundleId"];
        }
        pinnedBundleId = @"com.apple.MobileSMS";
    }
    [self refreshHandleIconIfNeeded];
    
    panelState = POPanelStateClosed;
    interactiveHostIntentIssued = NO;
    interactiveHostResumeRequired = NO;
    hostSession = [[POHostSessionController alloc] initWithManager:[ContextHostManager sharedInstance]];
    hostSession.delegate = self;
    
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(keyboardWillShow:) name:UIKeyboardWillShowNotification object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(keyboardWillChangeFrame:) name:UIKeyboardWillChangeFrameNotification object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(keyboardWillHide:) name:UIKeyboardWillHideNotification object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(keyboardDidShow:) name:UIKeyboardDidShowNotification object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(keyboardDidChangeFrame:) name:UIKeyboardDidChangeFrameNotification object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(keyboardDidHide:) name:UIKeyboardDidHideNotification object:nil];

    lastKeyboardAnimationDuration = 0.25;
    lastKeyboardAnimationOptions = UIViewAnimationOptionBeginFromCurrentState |
        UIViewAnimationOptionAllowUserInteraction |
        (UIViewAnimationOptionCurveEaseInOut << 16);
    keyboardZoomSuppressedForCurrentSession = NO;
    appliedCardScale = 1.0;
    closingFrozenCardScale = 1.0;
    scaledProgrammaticCloseAnimating = NO;
    scaledProgrammaticCloseNeedsLayout = NO;
    deferScaledCloseSessionCleanup = NO;

    [self applyCurrentSettings];
}

-(void)applyCurrentSettings{
    if (!self.isViewLoaded) {
        return;
    }
    if (scaledProgrammaticCloseAnimating) {
        scaledProgrammaticCloseNeedsLayout = YES;
        return;
    }
    [self dismissPresentedQuickSwitchMenuImmediately];
    BOOL isLeftHanded = [[POApplicationHelper settings][@"leftHanded"] boolValue];
    CGAffineTransform contentTransform = isLeftHanded
        ? CGAffineTransformMakeScale(-1.0, 1.0)
        : CGAffineTransformIdentity;
    self.handle.imageView.transform = contentTransform;
    [self.quickSwitchTableView refreshLayoutDirection];
    [quickSwitchHorizontalBarView refreshLayoutDirection];
    [quickSwitchDragCoordinator refreshLayoutDirection];
    [appRailView refreshLayoutDirection];

    if (![[POApplicationHelper settings][@"keyboardAvoiding"] boolValue] && origOffset) {
        [handleScrollView setContentOffset:CGPointMake(0, [self clampedHandleOffset:origOffset.floatValue]) animated:YES];
        origOffset = nil;
    }

    [self.handle refreshHandleSizeAnimated:NO];
    [self applyLayoutPreservingHandlePosition:YES];
    [self.handle refreshNubbedPositionAnimated:NO];
    if (appRailView && !appRailView.hidden) {
        [self layoutAppRail];
    }
    [self reevaluateKeyboardZoomAnimated:YES];
    if (self.view.window && self.view.window.userInteractionEnabled && self.view.alpha > 0.01) {
        [self resetAutoNubTimer];
    } else {
        [self cancelAutoNubTimer];
    }
}

-(void)dealloc{
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

-(void)refreshHandleIconIfNeeded{
    NSUInteger generation = ++handleIconRefreshGeneration;
    NSString *bundleId = [pinnedBundleId copy];
    if (bundleId.length == 0) {
        self.handle.imageView.image = nil;
        return;
    }

    UIImage *image = [POApplicationHelper imageForBundleId:bundleId];
    if (image) {
        self.handle.imageView.image = image;
        return;
    }

    for (NSNumber *delay in @[@0.15, @0.5, @1.5, @3.0]) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                      (int64_t)(delay.doubleValue * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            if (generation != self->handleIconRefreshGeneration ||
                ![self->pinnedBundleId isEqualToString:bundleId]) {
                return;
            }
            UIImage *retryImage = [POApplicationHelper imageForBundleId:bundleId];
            if (retryImage) {
                self.handle.imageView.image = retryImage;
            }
        });
    }
}

-(void)viewDidLayoutSubviews{
    [super viewDidLayoutSubviews];

    if (!CGSizeEqualToSize(lastLaidOutSize, self.view.bounds.size)) {
        [self applyLayoutPreservingHandlePosition:YES];
    }
    [self reconcilePresentedContainerGeometry];
}

-(void)viewSafeAreaInsetsDidChange{
    [super viewSafeAreaInsetsDidChange];
    [self applyLayoutPreservingHandlePosition:YES];
}

-(void)reconcilePresentedContainerGeometry{
    if (panelState == POPanelStateClosed || keyboardZoomContainer.hidden ||
        quickSwitchYieldActive || keyboardZoomApplied ||
        runtimeHostedCategoryTransitionAnimating ||
        !CGAffineTransformEqualToTransform(keyboardZoomContainer.transform,
                                            CGAffineTransformIdentity) ||
        CGRectIsEmpty(keyboardZoomBaseFrame)) {
        return;
    }

    CGRect currentFrame = keyboardZoomContainer.frame;
    if (fabs(CGRectGetMinX(currentFrame) - CGRectGetMinX(keyboardZoomBaseFrame)) <= 0.25 &&
        fabs(CGRectGetMinY(currentFrame) - CGRectGetMinY(keyboardZoomBaseFrame)) <= 0.25 &&
        fabs(CGRectGetWidth(currentFrame) - CGRectGetWidth(keyboardZoomBaseFrame)) <= 0.25 &&
        fabs(CGRectGetHeight(currentFrame) - CGRectGetHeight(keyboardZoomBaseFrame)) <= 0.25) {
        return;
    }

    [keyboardZoomContainer.layer removeAllAnimations];
    keyboardZoomContainer.frame = keyboardZoomBaseFrame;
    shadowView.frame = keyboardZoomContainer.bounds;
    self.contentView.frame = keyboardZoomContainer.bounds;
    shadowView.layer.shadowPath = [UIBezierPath bezierPathWithRoundedRect:shadowView.bounds
                                                              cornerRadius:CONTENT_CORNER_RADIUS].CGPath;
    [self layoutContextView];
}

#pragma mark - Geometry

-(CGFloat)trailingSafeAreaInset{
    UIEdgeInsets viewInsets = self.view.safeAreaInsets;
    UIEdgeInsets windowInsets = self.view.window.safeAreaInsets;
    BOOL isLeftHanded = [[POApplicationHelper settings][@"leftHanded"] boolValue];
    CGFloat viewTrailingInset = isLeftHanded ? viewInsets.left : viewInsets.right;
    CGFloat windowTrailingInset = isLeftHanded ? windowInsets.left : windowInsets.right;    return MAX(0, MAX(viewTrailingInset, windowTrailingInset));
}

-(CGFloat)leadingSafeAreaInset{
    UIEdgeInsets viewInsets = self.view.safeAreaInsets;
    UIEdgeInsets windowInsets = self.view.window.safeAreaInsets;
    BOOL isLeftHanded = [[POApplicationHelper settings][@"leftHanded"] boolValue];
    CGFloat viewLeadingInset = isLeftHanded ? viewInsets.right : viewInsets.left;
    CGFloat windowLeadingInset = isLeftHanded ? windowInsets.right : windowInsets.left;
    return MAX(0, MAX(viewLeadingInset, windowLeadingInset));
}

-(BOOL)isPanelActive{
    return panelState != POPanelStateClosed;
}

-(POInteractionMode)baseInteractionModeForHostedOrientation:(UIInterfaceOrientation)hostedOrientation{
    if (splitLayoutActive && panelState != POPanelStateClosed) {
        // 上下分屏:卡片外区域透传给底层 App,不铺遮罩。
        return POInteractionModeSplitPassthrough;
    }
    if (!POIsConcretePresentationOrientation(hostedOrientation)) {
        return POInteractionModeSplitPassthrough;
    }
    CGRect bounds = self.view.bounds;
    BOOL shellIsLandscape = CGRectGetWidth(bounds) > CGRectGetHeight(bounds);
    BOOL hostedIsLandscape = UIInterfaceOrientationIsLandscape(hostedOrientation);
    return shellIsLandscape == hostedIsLandscape
        ? POInteractionModeDrawerModal
        : POInteractionModeSplitPassthrough;
}

-(POInteractionMode)currentInteractionMode{
    if (presentedQuickSwitchMenu) {
        return POInteractionModeQuickSwitchModal;
    }
    if (panelState == POPanelStateClosed) {
        return POInteractionModeSplitPassthrough;
    }
    if (hostedCategoryTransitionPending || runtimeHostedCategoryTransitionAnimating) {
        return POInteractionModeSplitPassthrough;
    }
    return [self baseInteractionModeForHostedOrientation:[self resolvedHostedLayoutOrientation]];
}

-(UIInterfaceOrientation)resolvedHostedLayoutOrientation{
    if (POIsConcretePresentationOrientation(hostedLayoutOrientation)) {
        return hostedLayoutOrientation;
    }

    UIInterfaceOrientation orientation = [self contextManagerPreferredHostedInterfaceOrientation:nil];
    if (POIsConcretePresentationOrientation(orientation)) {
        hostedLayoutOrientation = orientation;
    }
    return orientation;
}

-(void)updateInteractionBackdropsAnimated:(BOOL)animated{
    if (!panelBackdropView || !quickSwitchBackdropView || !scrollView) {
        return;
    }
    panelBackdropView.frame = self.view.bounds;
    quickSwitchBackdropView.frame = scrollView.bounds;

    POInteractionMode mode = [self currentInteractionMode];
    CGFloat panelTargetAlpha = scaledProgrammaticCloseAnimating
        ? 0
        : (mode == POInteractionModeDrawerModal ? 0.5 * [self horizontalOpenProgress] : 0);
    CGFloat quickSwitchTargetAlpha = scaledProgrammaticCloseAnimating
        ? 0
        : (mode == POInteractionModeQuickSwitchModal ? 0.5 : 0);

    if (mode == POInteractionModeQuickSwitchModal) {
        [scrollView bringSubviewToFront:quickSwitchBackdropView];
        [scrollView bringSubviewToFront:handleScrollView];
    }

    void (^changes)(void) = ^{
        self->panelBackdropView.alpha = panelTargetAlpha;
        self->quickSwitchBackdropView.alpha = quickSwitchTargetAlpha;
    };
    if (animated) {
        [UIView animateWithDuration:0.20
                              delay:0
                            options:(UIViewAnimationOptionCurveEaseOut |
                                     UIViewAnimationOptionBeginFromCurrentState |
                                     UIViewAnimationOptionAllowUserInteraction)
                         animations:changes
                         completion:nil];
    } else {
        [panelBackdropView.layer removeAllAnimations];
        [quickSwitchBackdropView.layer removeAllAnimations];
        [UIView performWithoutAnimation:changes];
    }
}

-(void)panelBackdropDidTap:(UITapGestureRecognizer *)recognizer{
    if (recognizer.state != UIGestureRecognizerStateEnded ||
        [self currentInteractionMode] != POInteractionModeDrawerModal ||
        panelState != POPanelStateOpen || [self isPanelTransitioning]) {
        return;
    }
    [self close];
}

-(void)panelBackdropDidPan:(UIPanGestureRecognizer *)recognizer{
    if ([self currentInteractionMode] != POInteractionModeDrawerModal &&
        recognizer.state == UIGestureRecognizerStateBegan) {
        return;
    }
    [self handle:self.handle didPanPanel:recognizer];
}

-(BOOL)gestureRecognizerShouldBegin:(UIGestureRecognizer *)gestureRecognizer{
    if (gestureRecognizer == hostedWindowPinchGestureRecognizer) {
        // 双指捏合仅用于分屏会话内的卡片形态缩放,其余形态让手势穿透给托管 App。
        return [self isHostedFloatingWindowEligible];
    }
    if (gestureRecognizer == panelBackdropTapGestureRecognizer) {
        return [self currentInteractionMode] == POInteractionModeDrawerModal &&
            panelState == POPanelStateOpen && ![self isPanelTransitioning];
    }
    if (gestureRecognizer == panelBackdropPanGestureRecognizer) {
        if ([self currentInteractionMode] != POInteractionModeDrawerModal ||
            panelState != POPanelStateOpen || [self isPanelTransitioning]) {
            return NO;
        }
        CGPoint velocity = [(UIPanGestureRecognizer *)gestureRecognizer velocityInView:self.view];
        return fabs(velocity.x) > fabs(velocity.y) && fabs(velocity.x) > 20.0;
    }
    return YES;
}

-(UIView *)interactiveViewForWindowPoint:(CGPoint)point event:(UIEvent *)event{
    if (!self.isViewLoaded || self.view.hidden || self.view.alpha <= 0.01) {
        return nil;
    }

    CGPoint pointInView = [self.view convertPoint:point fromView:self.view.window];
    CGPoint handlePointInHandle = [self.handle convertPoint:point fromView:self.view.window];
    if (!self.handle.hidden && self.handle.alpha > 0.01 &&
        [self.handle pointInside:handlePointInHandle withEvent:event]) {
        return self.handle;
    }

    UIView *candidate = [self.view hitTest:pointInView withEvent:event];
    if (candidate && candidate != self.view && candidate != scrollView &&
        candidate != quickSwitchInteractionOverlayView && candidate != panelBackdropView &&
        candidate != quickSwitchBackdropView) {
        for (UIView *view = candidate; view; view = view.superview) {
            if (view == keyboardZoomContainer || view == self.contentView ||
                view == self.quickSwitchTableView || view == quickSwitchHorizontalBarView ||
                view == appRailView) {
                return candidate;
            }
            if (view == self.view) {
                break;
            }
        }
    }

    switch ([self currentInteractionMode]) {
        case POInteractionModeQuickSwitchModal:
            return quickSwitchBackdropView;
        case POInteractionModeDrawerModal:
            return panelBackdropView;
        case POInteractionModeSplitPassthrough:
        default:
            return nil;
    }
}

-(BOOL)shouldUsePortraitHostedLandscapeOptimizationForOrientation:(UIInterfaceOrientation)orientation{
    if (splitLayoutActive) {
        // 分屏形态卡片钉在下半区,不做竖向移动与底部横条快速切换。
        return NO;
    }
    CGRect bounds = self.view.bounds;
    BOOL shellIsPortrait = CGRectGetHeight(bounds) > CGRectGetWidth(bounds);
    return shellIsPortrait && UIInterfaceOrientationIsLandscape(orientation);
}

-(BOOL)isPortraitHostedLandscapeOptimizationActiveForOrientation:(UIInterfaceOrientation)orientation{
    return panelState != POPanelStateClosed &&
        [self shouldUsePortraitHostedLandscapeOptimizationForOrientation:orientation];
}

-(POQuickSwitchLayoutMode)currentQuickSwitchLayoutMode{
    UIInterfaceOrientation orientation = [self resolvedHostedLayoutOrientation];
    return [self isPortraitHostedLandscapeOptimizationActiveForOrientation:orientation]
        ? POQuickSwitchLayoutModeHorizontalBottom
        : POQuickSwitchLayoutModeVerticalSide;
}

-(BOOL)isHorizontalQuickSwitchLayoutMode{
    return [self currentQuickSwitchLayoutMode] == POQuickSwitchLayoutModeHorizontalBottom;
}

-(UIView<POQuickSwitchMenuPresenting> *)quickSwitchMenuForLayoutMode:(POQuickSwitchLayoutMode)mode{
    return mode == POQuickSwitchLayoutModeHorizontalBottom
        ? (UIView<POQuickSwitchMenuPresenting> *)quickSwitchHorizontalBarView
        : (UIView<POQuickSwitchMenuPresenting> *)self.quickSwitchTableView;
}

-(BOOL)isHorizontalQuickSwitchMenu:(UIView<POQuickSwitchMenuPresenting> *)menu{
    return menu == (UIView<POQuickSwitchMenuPresenting> *)quickSwitchHorizontalBarView;
}

-(BOOL)isPanelFullyOpen{
    return panelState == POPanelStateOpen &&
        !scrollSnapAnimationInProgress && !scrollView.dragging && !scrollView.decelerating &&
        fabs(scrollView.contentOffset.x - [self maximumContentOffsetX]) <= CLOSED_CONTENT_OFFSET_EPSILON;
}

-(BOOL)isPanelTransitioning{
    return panelState == POPanelStateOpening || panelState == POPanelStateClosing ||
        panelState == POPanelStateInteractive || scrollSnapAnimationInProgress;
}

-(BOOL)isHandleVisiblyNubbed{
    return self.handle.layoutMode == POHandleLayoutModeVerticalRail && self.handle.isNubbed;
}

-(BOOL)isHandleActivationGuardActive{
    return panelState == POPanelStateClosed && [self isHandleVisiblyNubbed] &&
        [[POApplicationHelper settings][@"handleActivationGuard"] boolValue];
}

-(POHandlePanIntent)horizontalHandlePanIntentForVelocityX:(CGFloat)velocityX{
    if (panelState == POPanelStateClosed) {
        if (velocityX < 0) {
            return [self isHandleActivationGuardActive]
                ? POHandlePanIntentRevealHandle
                : POHandlePanIntentOpenPanel;
        }
        if (velocityX > 0 && self.handle.layoutMode == POHandleLayoutModeVerticalRail &&
            !self.handle.isNubbed) {
            return POHandlePanIntentNubHandle;
        }
        return POHandlePanIntentNone;
    }
    if (panelState == POPanelStateOpen && velocityX > 0) {
        return POHandlePanIntentClosePanel;
    }
    return POHandlePanIntentNone;
}

-(void)cancelPresentationHandoff{
    [presentationHandoffDisplayLink invalidate];
    presentationHandoffDisplayLink = nil;
    presentationHandoffGeneration = 0;
    presentationHandoffStableFrames = 0;
    presentationHandoffBundleId = nil;
}

-(void)clearPresentationSnapshot{
    [self cancelPresentationHandoff];
    [presentationSnapshotView removeFromSuperview];
    presentationSnapshotView = nil;
    presentationSnapshotBundleId = nil;
    presentationSnapshotSceneIdentity = nil;
    presentationSnapshotIsTargetPlaceholder = NO;
    presentationSnapshotCapturedLeftHanded = NO;
    runtimeCategoryTransitionSnapshotActive = NO;
    runtimeCategoryTransitionSnapshotFallbackArmed = NO;
    runtimeCategoryTransitionSnapshotFading = NO;
    presentationSnapshotSize = CGSizeZero;
    presentationSnapshotOrientation = UIInterfaceOrientationUnknown;
    presentationSnapshotRenderSourceOrientation = UIInterfaceOrientationUnknown;
}

-(void)showRuntimeCategoryTransitionSnapshotFallback{
    if (!runtimeCategoryTransitionSnapshotFallbackArmed ||
        !presentationSnapshotView || presentationSnapshotIsTargetPlaceholder) {
        return;
    }
    [presentationSnapshotView.layer removeAllAnimations];
    presentationSnapshotView.alpha = 1;
    presentationSnapshotView.hidden = NO;
    runtimeCategoryTransitionSnapshotFading = NO;
    runtimeCategoryTransitionSnapshotActive = YES;
    UIInterfaceOrientation targetOrientation =
        [self contextManagerPreferredHostedInterfaceOrientation:nil];
    [self retargetRuntimeCategoryTransitionSnapshotForOrientation:targetOrientation];
    [presentationSnapshotView layoutIfNeeded];
    [presentationSnapshotView.layer setNeedsDisplay];
    [presentationSnapshotView.layer displayIfNeeded];
    UIView *sourceView = presentationSnapshotView.subviews.firstObject;
    [sourceView layoutIfNeeded];
    [sourceView.layer setNeedsDisplay];
    [sourceView.layer displayIfNeeded];
    [self.contentView bringSubviewToFront:presentationSnapshotView];
}

-(void)prewarmRuntimeCategoryTransitionSnapshot{
    if (NSProcessInfo.processInfo.operatingSystemVersion.majorVersion < 26 ||
        !presentationSnapshotView || presentationSnapshotIsTargetPlaceholder ||
        runtimeCategoryTransitionSnapshotActive || runtimeCategoryTransitionSnapshotFading) {
        return;
    }
    presentationSnapshotView.hidden = NO;
    presentationSnapshotView.alpha = 1.0;
    [self layoutPresentationSnapshotView];
    [presentationSnapshotView layoutIfNeeded];
    [presentationSnapshotView.layer setNeedsDisplay];
    [presentationSnapshotView.layer displayIfNeeded];
    UIView *sourceView = presentationSnapshotView.subviews.firstObject;
    [sourceView layoutIfNeeded];
    [sourceView.layer setNeedsDisplay];
    [sourceView.layer displayIfNeeded];
    [self.contentView bringSubviewToFront:presentationSnapshotView];
}

-(void)schedulePresentationSnapshotRetirementForBundleId:(NSString *)bundleId
                                               generation:(NSUInteger)generation{
    if (bundleId.length == 0 || generation == 0 || !presentationSnapshotView ||
        presentationSnapshotView.hidden || !contextView || contextView.hidden) {
        return;
    }
    presentationHandoffGeneration = generation;
    presentationHandoffBundleId = [bundleId copy];
    presentationHandoffStableFrames = 0;
    if (!presentationHandoffDisplayLink) {
        presentationHandoffDisplayLink = [CADisplayLink displayLinkWithTarget:self
                                                                     selector:@selector(handlePresentationHandoffDisplayLink:)];
        [presentationHandoffDisplayLink addToRunLoop:NSRunLoop.mainRunLoop forMode:NSRunLoopCommonModes];
    }
}

-(void)handlePresentationHandoffDisplayLink:(CADisplayLink *)__unused displayLink{
    if (!presentationSnapshotView || presentationSnapshotView.hidden ||
        presentationHandoffGeneration == 0 ||
        presentationHandoffGeneration != hostSession.currentGeneration ||
        ![presentationHandoffBundleId isEqualToString:hostSession.requestedBundleId]) {
        [self cancelPresentationHandoff];
        return;
    }
    if (panelState != POPanelStateOpen || scrollSnapAnimationInProgress ||
        hostSession.state != POHostSessionStateLive || !contextView || contextView.hidden ||
        contextView.superview != self.contentView) {
        presentationHandoffStableFrames = 0;
        return;
    }

    ContextHostManager *manager = [ContextHostManager sharedInstance];
    BOOL requiresStableContentHandoff = runtimeCategoryTransitionSnapshotActive ||
        runtimeCategoryTransitionSnapshotFallbackArmed;
    if (NSProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 26 &&
        requiresStableContentHandoff &&
        ![manager isHostedPresentationContentStableForBundleId:presentationHandoffBundleId
                                               minimumDuration:0.15]) {
        presentationHandoffStableFrames = 0;
        return;
    }

    presentationHandoffStableFrames += 1;
    if (presentationHandoffStableFrames < 3) {
        return;
    }

    if (runtimeCategoryTransitionSnapshotActive) {
        UIView *snapshot = presentationSnapshotView;
        NSUInteger generation = presentationHandoffGeneration;
        NSString *bundleId = [presentationHandoffBundleId copy];
        runtimeCategoryTransitionSnapshotActive = NO;
        runtimeCategoryTransitionSnapshotFading = NO;
        [self cancelPresentationHandoff];
        [UIView performWithoutAnimation:^{
            snapshot.alpha = 0;
            snapshot.hidden = YES;
        }];
        if (snapshot == self->presentationSnapshotView &&
            generation == self->hostSession.currentGeneration &&
            [bundleId isEqualToString:self->hostSession.requestedBundleId]) {
            [self clearPresentationSnapshot];
        }
        return;
    }

    [self clearPresentationSnapshot];
}

-(void)layoutPresentationSnapshotView{
    if (!presentationSnapshotView) {
        return;
    }

    BOOL currentLeftHanded = [[POApplicationHelper settings][@"leftHanded"] boolValue];
    BOOL shouldMirrorLocally = presentationSnapshotIsTargetPlaceholder
        ? currentLeftHanded
        : (presentationSnapshotCapturedLeftHanded != currentLeftHanded);
    [UIView performWithoutAnimation:^{
        presentationSnapshotView.transform = CGAffineTransformIdentity;
        presentationSnapshotView.bounds = (CGRect){CGPointZero, self.contentView.bounds.size};
        presentationSnapshotView.center = CGPointMake(CGRectGetMidX(self.contentView.bounds),
                                                       CGRectGetMidY(self.contentView.bounds));
        presentationSnapshotView.transform = shouldMirrorLocally
            ? CGAffineTransformMakeScale(-1.0, 1.0)
            : CGAffineTransformIdentity;

        if (NSProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 26 &&
            !presentationSnapshotIsTargetPlaceholder && self->contextView) {
            UIView *sourceView = presentationSnapshotView.subviews.firstObject;
            if ([sourceView isKindOfClass:[UIImageView class]]) {
                UIInterfaceOrientation sourceOrientation = presentationSnapshotRenderSourceOrientation;
                UIInterfaceOrientation targetOrientation = presentationSnapshotOrientation;
                if (!POIsConcretePresentationOrientation(sourceOrientation)) {
                    sourceOrientation = targetOrientation;
                }
                if (!POIsConcretePresentationOrientation(targetOrientation)) {
                    targetOrientation = hostedLayoutOrientation;
                }
                CGSize sourceCanvas = sourceView.bounds.size;
                BOOL sourceAndTargetCategoriesDiffer =
                    POIsConcretePresentationOrientation(sourceOrientation) &&
                    POIsConcretePresentationOrientation(targetOrientation) &&
                    UIInterfaceOrientationIsLandscape(sourceOrientation) !=
                        UIInterfaceOrientationIsLandscape(targetOrientation);
                BOOL targetMatchesShell =
                    POIsConcretePresentationOrientation(targetOrientation) &&
                    UIInterfaceOrientationIsLandscape(targetOrientation) ==
                        (CGRectGetWidth(self.view.bounds) > CGRectGetHeight(self.view.bounds));
                if (!sourceAndTargetCategoriesDiffer || !targetMatchesShell) {
                    sourceView.bounds = self->contextView.bounds;
                    sourceView.center = self->contextView.center;
                    sourceView.transform = self->contextView.transform;
                    return;
                }

                UIImage *image = ((UIImageView *)sourceView).image;
                if (image.size.width > 0 && image.size.height > 0) {
                    sourceCanvas = image.size;
                }
                if (sourceCanvas.width <= 0 || sourceCanvas.height <= 0) {
                    sourceCanvas = self->contextView.bounds.size;
                }
                sourceView.bounds = (CGRect){CGPointZero, sourceCanvas};
                sourceView.center = self->contextView.center;

                CGAffineTransform contextTransform = self->contextView.transform;
                CGFloat scaleX = hypot(contextTransform.a, contextTransform.b);
                CGFloat scaleY = hypot(contextTransform.c, contextTransform.d);
                if (!isfinite(scaleX) || scaleX <= 0) {
                    scaleX = 1;
                }
                if (!isfinite(scaleY) || scaleY <= 0) {
                    scaleY = 1;
                }
                CGFloat rotationAngle = 0;
                if (POIsConcretePresentationOrientation(sourceOrientation) &&
                    POIsConcretePresentationOrientation(targetOrientation)) {
                    rotationAngle = POPresentationAngleForOrientation(targetOrientation) -
                        POPresentationAngleForOrientation(sourceOrientation);
                }
                CGAffineTransform sourceTransform = CGAffineTransformMakeRotation(rotationAngle);
                sourceTransform = CGAffineTransformScale(sourceTransform, scaleX, scaleY);
                if (contextTransform.a * contextTransform.d -
                    contextTransform.b * contextTransform.c < 0) {
                    sourceTransform = CGAffineTransformConcat(
                        sourceTransform, CGAffineTransformMakeScale(-1.0, 1.0));
                }
                sourceView.transform = sourceTransform;
            }
        }
    }];
}

-(void)cachePresentationSnapshotView:(UIView *)snapshotView
                            bundleId:(NSString *)bundleId
                               scene:(FBScene *)scene
                                size:(CGSize)size
                         orientation:(UIInterfaceOrientation)orientation
                  capturedLeftHanded:(BOOL)capturedLeftHanded{
    if (!snapshotView || bundleId.length == 0) {
        return;
    }
    if (!presentationSnapshotCache) {
        presentationSnapshotCache = [NSMutableDictionary dictionary];
        presentationSnapshotCacheOrder = [NSMutableArray array];
    }
    int processPID = [[ContextHostManager sharedInstance] processIdentifierForBundleId:bundleId];
    presentationSnapshotCache[bundleId] = @{
        @"view": snapshotView,
        @"scene": scene ?: (id)NSNull.null,
        @"pid": @(processPID),
        @"size": [NSValue valueWithCGSize:size],
        @"orientation": @(orientation),
        @"leftHanded": @(capturedLeftHanded)
    };
    [presentationSnapshotCacheOrder removeObject:bundleId];
    [presentationSnapshotCacheOrder addObject:bundleId];
    while (presentationSnapshotCacheOrder.count > 6) {
        NSString *oldestBundleId = presentationSnapshotCacheOrder.firstObject;
        [presentationSnapshotCacheOrder removeObjectAtIndex:0];
        [presentationSnapshotCache removeObjectForKey:oldestBundleId];
    }
}

-(UIInterfaceOrientation)cachedPresentationOrientationForBundleId:(NSString *)bundleId{
    if (bundleId.length == 0) {
        return UIInterfaceOrientationUnknown;
    }
    NSDictionary *entry = presentationSnapshotCache[bundleId];
    if (!entry) {
        return UIInterfaceOrientationUnknown;
    }

    ContextHostManager *manager = [ContextHostManager sharedInstance];
    int currentPID = [manager processIdentifierForBundleId:bundleId];
    int cachedPID = [entry[@"pid"] intValue];
    FBScene *cachedScene = entry[@"scene"] == NSNull.null ? nil : entry[@"scene"];
    FBScene *currentScene = currentPID > 0 ? [manager probeSceneForBundleId:bundleId] : nil;
    if (currentPID <= 0 || cachedPID <= 0 || currentPID != cachedPID ||
        !currentScene || (cachedScene && currentScene != cachedScene)) {
        [presentationSnapshotCache removeObjectForKey:bundleId];
        [presentationSnapshotCacheOrder removeObject:bundleId];
        return UIInterfaceOrientationUnknown;
    }

    UIInterfaceOrientation orientation = [entry[@"orientation"] integerValue];
    return POIsConcretePresentationOrientation(orientation)
        ? orientation
        : UIInterfaceOrientationUnknown;
}

-(UIInterfaceOrientation)resolvedHostedOrientationForBundleId:(NSString *)bundleId
                                                     manager:(ContextHostManager *)manager{
    ContextHostManager *hostManager = manager ?: [ContextHostManager sharedInstance];
    UIInterfaceOrientation liveOrientation = hostManager.hostedInterfaceOrientation;
    if (hostManager.isForegroundLeaseActive &&
        [hostManager.activeHostedBundleId isEqualToString:bundleId] &&
        POIsConcretePresentationOrientation(liveOrientation)) {
        return liveOrientation;
    }
    if (!hostManager.isForegroundLeaseActive &&
        [self hasLiveRetainedPresentationForBundleId:bundleId] &&
        POIsConcretePresentationOrientation(presentationOrientation)) {
        return presentationOrientation;
    }
    UIInterfaceOrientation cachedOrientation = [self cachedPresentationOrientationForBundleId:bundleId];
    if (POIsConcretePresentationOrientation(cachedOrientation)) {
        return cachedOrientation;
    }
    return [hostManager preferredHostedInterfaceOrientationForBundleId:bundleId];
}

-(NSDictionary *)validCachedPresentationSnapshotForBundleId:(NSString *)bundleId{
    NSDictionary *entry = presentationSnapshotCache[bundleId];
    NSString *frontId = [POApplicationHelper frontMostBundleId];
    if (frontId.length > 0 && [frontId isEqualToString:bundleId]) {
        return nil;
    }
    UIInterfaceOrientation cachedOrientation = [self cachedPresentationOrientationForBundleId:bundleId];
    entry = presentationSnapshotCache[bundleId];
    if (!entry || !POIsConcretePresentationOrientation(cachedOrientation)) {
        return nil;
    }
    CGSize cachedSize = [entry[@"size"] CGSizeValue];
    CGSize expectedSize = self.contentView.bounds.size;
    UIInterfaceOrientation expectedOrientation =
        [self resolvedHostedOrientationForBundleId:bundleId manager:nil];
    if (fabs(cachedSize.width - expectedSize.width) > CLOSED_CONTENT_OFFSET_EPSILON ||
        fabs(cachedSize.height - expectedSize.height) > CLOSED_CONTENT_OFFSET_EPSILON ||
        cachedOrientation != expectedOrientation) {
        return nil;
    }
    return entry;
}

-(BOOL)revealCachedPresentationSnapshotForBundleId:(NSString *)bundleId{
    NSDictionary *entry = [self validCachedPresentationSnapshotForBundleId:bundleId];
    UIView *snapshotView = entry[@"view"];
    if (!snapshotView) {
        return NO;
    }
    [self clearPresentationSnapshot];
    presentationSnapshotView = snapshotView;
    presentationSnapshotBundleId = [bundleId copy];
    presentationSnapshotSceneIdentity = entry[@"scene"] == NSNull.null ? nil : entry[@"scene"];
    presentationSnapshotIsTargetPlaceholder = NO;
    presentationSnapshotCapturedLeftHanded = [entry[@"leftHanded"] boolValue];
    presentationSnapshotSize = [entry[@"size"] CGSizeValue];
    presentationSnapshotOrientation = [entry[@"orientation"] integerValue];
    presentationSnapshotRenderSourceOrientation = presentationSnapshotOrientation;
    [self layoutPresentationSnapshotView];
    presentationSnapshotView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    presentationSnapshotView.hidden = NO;
    if (presentationSnapshotView.superview != self.contentView) {
        [self.contentView addSubview:presentationSnapshotView];
    }
    [self.contentView bringSubviewToFront:presentationSnapshotView];
    [presentationSnapshotCacheOrder removeObject:bundleId];
    [presentationSnapshotCacheOrder addObject:bundleId];
    return YES;
}

-(void)showTargetTransitionPresentationForBundleId:(NSString *)bundleId{
    if (bundleId.length == 0) {
        return;
    }
    [self clearPresentationSnapshot];

    UIView *placeholder = [[UIView alloc] initWithFrame:self.contentView.bounds];
    placeholder.backgroundColor = [UIColor systemGray6Color];
    placeholder.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;

    UIImageView *iconView = [[UIImageView alloc] initWithImage:[POApplicationHelper imageForBundleId:bundleId]];
    CGFloat iconSide = MIN(72.0, MIN(CGRectGetWidth(placeholder.bounds), CGRectGetHeight(placeholder.bounds)) * 0.24);
    iconView.bounds = CGRectMake(0, 0, iconSide, iconSide);
    iconView.center = CGPointMake(CGRectGetMidX(placeholder.bounds), CGRectGetMidY(placeholder.bounds));
    iconView.contentMode = UIViewContentModeScaleAspectFit;
    iconView.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin | UIViewAutoresizingFlexibleRightMargin |
        UIViewAutoresizingFlexibleTopMargin | UIViewAutoresizingFlexibleBottomMargin;
    [placeholder addSubview:iconView];

    presentationSnapshotView = placeholder;
    presentationSnapshotBundleId = [bundleId copy];
    presentationSnapshotSceneIdentity = [[ContextHostManager sharedInstance] probeSceneForBundleId:bundleId];
    presentationSnapshotIsTargetPlaceholder = YES;
    presentationSnapshotCapturedLeftHanded = [[POApplicationHelper settings][@"leftHanded"] boolValue];
    presentationSnapshotSize = self.contentView.bounds.size;
    presentationSnapshotOrientation =
        [self resolvedHostedOrientationForBundleId:bundleId manager:nil];
    presentationSnapshotRenderSourceOrientation = presentationSnapshotOrientation;
    [self.contentView addSubview:presentationSnapshotView];
    [self layoutPresentationSnapshotView];
    [self.contentView bringSubviewToFront:presentationSnapshotView];
}

-(void)retainPresentationAfterReleaseIfPossible{
    BOOL canRetain = contextView != nil && presentationBundleId.length > 0;
    presentationRetainedAfterRelease = canRetain;
    retainedPresentationProcessPID = canRetain
        ? [[ContextHostManager sharedInstance] processIdentifierForBundleId:presentationBundleId]
        : 0;
    if (retainedPresentationProcessPID <= 0) {
        presentationRetainedAfterRelease = NO;
        retainedPresentationProcessPID = 0;
    }
}

-(BOOL)hasLiveRetainedPresentationForBundleId:(NSString *)bundleId{
    if (!presentationRetainedAfterRelease || retainedPresentationProcessPID <= 0 ||
        bundleId.length == 0 || ![presentationBundleId isEqualToString:bundleId]) {
        return NO;
    }
    int currentPID = [[ContextHostManager sharedInstance] processIdentifierForBundleId:bundleId];
    if (currentPID != retainedPresentationProcessPID) {
        presentationRetainedAfterRelease = NO;
        retainedPresentationProcessPID = 0;
        return NO;
    }
    return YES;
}

-(void)flushDeferredRuntimeScenePublicationIfNeeded{
    FBScene *scene = deferredRuntimePublishedScene;
    UIView *sceneStack = deferredRuntimePublishedSceneStack;
    NSString *bundleId = [deferredRuntimePublishedBundleId copy];
    NSUInteger generation = deferredRuntimePublishedGeneration;

    deferredRuntimePublishedScene = nil;
    deferredRuntimePublishedSceneStack = nil;
    deferredRuntimePublishedBundleId = nil;
    deferredRuntimePublishedGeneration = 0;

    if (!scene || !sceneStack || bundleId.length == 0 || generation == 0 ||
        generation != hostSession.currentGeneration ||
        ![bundleId isEqualToString:hostSession.requestedBundleId] ||
        panelState == POPanelStateClosed || panelState == POPanelStateClosing) {
        return;
    }
    [self hostSessionController:hostSession
               didPublishScene:scene
                    sceneStack:sceneStack
                          bundleId:bundleId
                        generation:generation];
}

-(void)scheduleRuntimeScenePublicationStagingIfNeeded{
    if (runtimeDeferredPublicationStageScheduled || !runtimeHostedCategoryTransitionAnimating ||
        !runtimeCategoryTransitionSnapshotActive || !presentationSnapshotView ||
        presentationSnapshotView.hidden) {
        return;
    }

    runtimeDeferredPublicationStageScheduled = YES;
    dispatch_async(dispatch_get_main_queue(), ^{
        self->runtimeDeferredPublicationStageScheduled = NO;
        if (!self->runtimeHostedCategoryTransitionAnimating ||
            !self->runtimeCategoryTransitionSnapshotActive ||
            !self->presentationSnapshotView || self->presentationSnapshotView.hidden) {
            return;
        }

        FBScene *scene = self->deferredRuntimePublishedScene;
        UIView *sceneStack = self->deferredRuntimePublishedSceneStack;
        NSString *bundleId = [self->deferredRuntimePublishedBundleId copy];
        NSUInteger generation = self->deferredRuntimePublishedGeneration;
        if (!scene || !sceneStack || bundleId.length == 0 || generation == 0 ||
            generation != self->hostSession.currentGeneration ||
            ![bundleId isEqualToString:self->hostSession.requestedBundleId]) {
            return;
        }

        self->runtimeScenePublicationStaging = YES;
        [self hostSessionController:self->hostSession
                   didPublishScene:scene
                        sceneStack:sceneStack
                          bundleId:bundleId
                        generation:generation];
        self->runtimeScenePublicationStaging = NO;

        if (self->deferredRuntimePublishedSceneStack == sceneStack &&
            self->deferredRuntimePublishedGeneration == generation) {
            self->deferredRuntimePublishedScene = nil;
            self->deferredRuntimePublishedSceneStack = nil;
            self->deferredRuntimePublishedBundleId = nil;
            self->deferredRuntimePublishedGeneration = 0;
        }
    });
}

-(BOOL)hasCompatiblePresentationSnapshotForBundleId:(NSString *)bundleId{
    if (bundleId.length == 0 || !presentationSnapshotView ||
        ![presentationSnapshotBundleId isEqualToString:bundleId]) {
        return NO;
    }
    NSString *frontId = [POApplicationHelper frontMostBundleId];
    if (frontId.length > 0 && [frontId isEqualToString:bundleId]) {
        return NO;
    }
    ContextHostManager *manager = [ContextHostManager sharedInstance];
    if (![manager isProcessRunningForBundleId:bundleId]) {
        return NO;
    }
    FBScene *currentScene = [manager probeSceneForBundleId:bundleId];
    if (!currentScene || (presentationSnapshotSceneIdentity && currentScene != presentationSnapshotSceneIdentity)) {
        return NO;
    }
    CGSize expectedSize = self.contentView.bounds.size;
    UIInterfaceOrientation expectedOrientation = [self contextManagerPreferredHostedInterfaceOrientation:nil];
    return fabs(presentationSnapshotSize.width - expectedSize.width) <= CLOSED_CONTENT_OFFSET_EPSILON &&
        fabs(presentationSnapshotSize.height - expectedSize.height) <= CLOSED_CONTENT_OFFSET_EPSILON &&
        presentationSnapshotOrientation == expectedOrientation;
}

-(BOOL)prepareRuntimeCategoryTransitionSnapshotFromSourceOrientation:(UIInterfaceOrientation)sourceOrientation{
    if (!contextView || contextView.hidden || presentationBundleId.length == 0 ||
        !POIsConcretePresentationOrientation(sourceOrientation) ||
        ![presentationBundleId isEqualToString:hostSession.activeBundleId]) {
        return NO;
    }

    UIImage *snapshotImage = [[ContextHostManager sharedInstance]
        captureSnapshotImageForActiveBundleId:presentationBundleId
                             sourceOrientation:sourceOrientation];
    if (!snapshotImage) {
        return NO;
    }

    [self clearPresentationSnapshot];
    UIView *snapshotView = [[UIView alloc] initWithFrame:self.contentView.bounds];
    snapshotView.backgroundColor = UIColor.clearColor;
    snapshotView.userInteractionEnabled = NO;
    snapshotView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;

    UIImageView *sourceImageView = [[UIImageView alloc] initWithImage:snapshotImage];
    sourceImageView.contentMode = UIViewContentModeScaleToFill;
    sourceImageView.bounds = contextView.bounds;
    sourceImageView.center = contextView.center;
    sourceImageView.transform = contextView.transform;
    [snapshotView addSubview:sourceImageView];

    presentationSnapshotView = snapshotView;
    presentationSnapshotBundleId = [presentationBundleId copy];
    presentationSnapshotSceneIdentity = presentationSceneIdentity;
    presentationSnapshotIsTargetPlaceholder = NO;
    presentationSnapshotCapturedLeftHanded = [[POApplicationHelper settings][@"leftHanded"] boolValue];
    runtimeCategoryTransitionSnapshotActive = YES;
    presentationSnapshotSize = self.contentView.bounds.size;
    presentationSnapshotOrientation = sourceOrientation;
    presentationSnapshotRenderSourceOrientation = sourceOrientation;
    [self.contentView addSubview:presentationSnapshotView];
    presentationSnapshotView.hidden = NO;
    [self.contentView bringSubviewToFront:presentationSnapshotView];
    return YES;
}

-(void)retargetRuntimeCategoryTransitionSnapshotForOrientation:(UIInterfaceOrientation)orientation{
    if (!presentationSnapshotView || presentationSnapshotIsTargetPlaceholder ||
        !POIsConcretePresentationOrientation(orientation) || !contextView) {
        return;
    }
    UIView *sourceView = presentationSnapshotView.subviews.firstObject;
    if (![sourceView isKindOfClass:[UIImageView class]]) {
        return;
    }

    if (!POIsConcretePresentationOrientation(presentationSnapshotRenderSourceOrientation)) {
        presentationSnapshotRenderSourceOrientation = presentationSnapshotOrientation;
    }
    presentationSnapshotOrientation = orientation;
    [self layoutPresentationSnapshotView];
    presentationSnapshotSize = self.contentView.bounds.size;
    [self cachePresentationSnapshotView:presentationSnapshotView
                               bundleId:presentationSnapshotBundleId
                                  scene:presentationSnapshotSceneIdentity
                                   size:presentationSnapshotSize
                            orientation:presentationSnapshotOrientation
                     capturedLeftHanded:presentationSnapshotCapturedLeftHanded];
    presentationSnapshotView.hidden = NO;
    [self.contentView bringSubviewToFront:presentationSnapshotView];
}

-(void)capturePresentationSnapshotIfPossible{
    if (!contextView || contextView.hidden || showingCantHost || self.contentView.bounds.size.width <= 0 ||
        self.contentView.bounds.size.height <= 0 ||
        ![presentationBundleId isEqualToString:hostSession.activeBundleId]) {
        return;
    }

    CGSize expectedCanvasSize = [self contextManagerPreferredSceneStackSize:nil];
    UIInterfaceOrientation expectedOrientation = [self contextManagerPreferredHostedInterfaceOrientation:nil];
    BOOL presentationContractMatches = presentationOrientation == expectedOrientation &&
        fabs(presentationCanvasSize.width - expectedCanvasSize.width) <= CLOSED_CONTENT_OFFSET_EPSILON &&
        fabs(presentationCanvasSize.height - expectedCanvasSize.height) <= CLOSED_CONTENT_OFFSET_EPSILON;
    if (!presentationContractMatches) {
        return;
    }

    CGSize size = self.contentView.bounds.size;
    UIImage *snapshotImage = [[ContextHostManager sharedInstance]
        captureSnapshotImageForActiveBundleId:presentationBundleId];
    if (!snapshotImage) {
        return;
    }
    UIView *snapshotView = [[UIView alloc] initWithFrame:self.contentView.bounds];
    snapshotView.backgroundColor = UIColor.clearColor;
    snapshotView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    UIImageView *sourceImageView = [[UIImageView alloc] initWithImage:snapshotImage];
    sourceImageView.contentMode = UIViewContentModeScaleToFill;
    sourceImageView.bounds = contextView.bounds;
    sourceImageView.center = contextView.center;
    sourceImageView.transform = contextView.transform;
    [snapshotView addSubview:sourceImageView];

    [self clearPresentationSnapshot];
    presentationSnapshotView = snapshotView;
    presentationSnapshotView.hidden = YES;
    [self.contentView addSubview:presentationSnapshotView];
    presentationSnapshotBundleId = [presentationBundleId copy];
    presentationSnapshotSceneIdentity = presentationSceneIdentity;
    presentationSnapshotIsTargetPlaceholder = NO;
    presentationSnapshotCapturedLeftHanded = [[POApplicationHelper settings][@"leftHanded"] boolValue];
    presentationSnapshotSize = size;
    presentationSnapshotOrientation = presentationOrientation;
    presentationSnapshotRenderSourceOrientation = presentationOrientation;
    [self cachePresentationSnapshotView:snapshotView
                               bundleId:presentationSnapshotBundleId
                                  scene:presentationSnapshotSceneIdentity
                               size:presentationSnapshotSize
                            orientation:presentationSnapshotOrientation
                     capturedLeftHanded:presentationSnapshotCapturedLeftHanded];
}

-(BOOL)isPresentationCompatibleForBundleId:(NSString *)bundleId{
    if (bundleId.length == 0 || !contextView || ![presentationBundleId isEqualToString:bundleId]) {
        return NO;
    }
    if (presentationRetainedAfterRelease &&
        ![self hasLiveRetainedPresentationForBundleId:bundleId]) {
        return NO;
    }
    if (presentationSceneIdentity &&
        [presentationSceneIdentity respondsToSelector:@selector(isValid)] &&
        ![(id)presentationSceneIdentity isValid]) {
        return NO;
    }
    NSString *frontId = [POApplicationHelper frontMostBundleId];
    if (frontId.length > 0 && [frontId isEqualToString:bundleId]) {
        return NO;
    }
    CGSize expectedSize = [self contextManagerPreferredSceneStackSize:nil];
    UIInterfaceOrientation expectedOrientation = [self contextManagerPreferredHostedInterfaceOrientation:nil];
    return fabs(presentationCanvasSize.width - expectedSize.width) <= CLOSED_CONTENT_OFFSET_EPSILON &&
        fabs(presentationCanvasSize.height - expectedSize.height) <= CLOSED_CONTENT_OFFSET_EPSILON &&
        presentationOrientation == expectedOrientation;
}

-(BOOL)revealPresentationForBundleIdIfCompatible:(NSString *)bundleId{
    keyboardZoomContainer.hidden = NO;
    if (cantHostCanvas) {
        cantHostCanvas.hidden = YES;
    }
    BOOL compatible = [self isPresentationCompatibleForBundleId:bundleId];
    BOOL snapshotCompatible = [self hasCompatiblePresentationSnapshotForBundleId:bundleId];
    if (compatible && presentationRetainedAfterRelease) {
        presentationRetainedAfterRelease = NO;
        retainedPresentationProcessPID = 0;
    }
    if (contextView) {
        contextView.hidden = !compatible;
        if (compatible) {
            [self.contentView bringSubviewToFront:contextView];
        }
    }
    if (presentationSnapshotView) {
        presentationSnapshotView.hidden = !snapshotCompatible;
        if (snapshotCompatible) {
            [self layoutPresentationSnapshotView];
            [self.contentView bringSubviewToFront:presentationSnapshotView];
        }
    }
    return compatible || snapshotCompatible;
}

-(void)hidePresentationContainer{
    keyboardZoomContainer.hidden = YES;
    if (contextView) {
        contextView.hidden = NO;
    }
}

-(void)issueInteractiveHostIntentIfNeeded{
    if (interactiveHostIntentIssued || pinnedBundleId.length == 0) {
        return;
    }
    interactiveHostIntentIssued = YES;
    BOOL revealed = [self revealPresentationForBundleIdIfCompatible:pinnedBundleId];
    if (!revealed) {
        [self showTargetTransitionPresentationForBundleId:pinnedBundleId];
    }
    [hostSession activateBundleId:pinnedBundleId];
}

// 上下分屏:把手点击时前台存在其他 App,底层 App 保活在上半区、托管 App 占下半区。
// 关闭态用前台 App 预测下一次打开的形态,让托管层的画布/初始 frame 提前按半屏准备。
-(BOOL)isSplitLayoutActiveOrPending{
    if (splitLayoutActive) {
        return YES;
    }
    if (panelState != POPanelStateClosed && panelState != POPanelStateClosing) {
        return NO;
    }
    NSString *frontMostBundleId = [POApplicationHelper frontMostBundleId];
    if (frontMostBundleId.length == 0) {
        return NO;
    }
    NSString *targetBundleId = pinnedBundleId.length > 0 ? pinnedBundleId : hostSession.requestedBundleId;
    return targetBundleId.length == 0 || ![frontMostBundleId isEqualToString:targetBundleId];
}

// 分屏卡片高度:全宽贴边,占据可用区域(去上下安全区)的下半份。
-(CGFloat)splitLayoutBottomCardHeightForShellBounds:(CGRect)bounds{
    UIEdgeInsets viewInsets = self.view.safeAreaInsets;
    UIEdgeInsets windowInsets = self.view.window.safeAreaInsets;
    CGFloat topInset = MAX(viewInsets.top, windowInsets.top) + CONTENT_EDGE_GAP;
    CGFloat bottomInset = MAX(viewInsets.bottom, windowInsets.bottom) + CONTENT_EDGE_GAP;
    CGFloat usableHeight = CGRectGetHeight(bounds) - topInset - bottomInset;
    return MAX(1.0, floorf(usableHeight * 0.5));
}

-(BOOL)beginSplitSessionIfNeeded{
    POSplitSessionController *splitSession = [POSplitSessionController sharedInstance];
    if (splitSession.isActive) {
        return splitSession.baseBundleIdentifier.length > 0 &&
            ![splitSession.baseBundleIdentifier isEqualToString:@"com.apple.springboard"];
    }
    NSString *frontMostBundleId = [POApplicationHelper frontMostBundleId];
    if (frontMostBundleId.length > 0 && [frontMostBundleId isEqualToString:pinnedBundleId]) {
        return NO;
    }
    NSString *baseBundleId = frontMostBundleId;
    id baseScene = nil;
    if (baseBundleId.length > 0) {
        baseScene = [[ContextHostManager sharedInstance] probeSceneForBundleId:baseBundleId];
    } else {
        baseBundleId = @"com.apple.springboard";
        SEL mainDisplaySceneSelector = NSSelectorFromString(@"_mainDisplayWindowScene");
        if ([UIApplication.sharedApplication respondsToSelector:mainDisplaySceneSelector]) {
            baseScene = ((id (*)(id, SEL))objc_msgSend)(UIApplication.sharedApplication,
                                                       mainDisplaySceneSelector);
        }
        if (!baseScene) {
            for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
                if ([scene isKindOfClass:[UIWindowScene class]] &&
                    [scene.session.persistentIdentifier isEqualToString:baseBundleId]) {
                    baseScene = scene;
                    break;
                }
            }
        }
    }
    [splitSession beginWithBaseBundleIdentifier:baseBundleId scene:baseScene];
    return frontMostBundleId.length > 0;
}

-(BOOL)isLandscapePanelFullyOpenAndIdle{
    CGRect bounds = self.view.bounds;
    if (CGRectGetWidth(bounds) <= CGRectGetHeight(bounds) || ![self isPanelFullyOpen]) {
        return NO;
    }
    if (scrollSnapAnimationInProgress || scrollView.dragging || scrollView.decelerating) {
        return NO;
    }
    return fabs(scrollView.contentOffset.x - [self maximumContentOffsetX]) <= CLOSED_CONTENT_OFFSET_EPSILON;
}

-(POCardScaleContext)currentCardScaleContext{
    if (splitLayoutActive) {
        // 分屏卡片已占满半屏,键盘时不再放大。
        return POCardScaleContextNone;
    }
    UIInterfaceOrientation hostedOrientation = [self resolvedHostedLayoutOrientation];
    if (!POIsConcretePresentationOrientation(hostedOrientation)) {
        return POCardScaleContextNone;
    }
    CGRect bounds = self.view.bounds;
    BOOL shellIsLandscape = CGRectGetWidth(bounds) > CGRectGetHeight(bounds);
    BOOL hostedIsLandscape = UIInterfaceOrientationIsLandscape(hostedOrientation);
    if (shellIsLandscape && !hostedIsLandscape) {
        return POCardScaleContextLandscapeShellPortraitHosted;
    }
    return POCardScaleContextNone;
}

-(CGFloat)effectiveLandscapePortraitKeyboardZoomScale{
    if (CGRectGetWidth(keyboardZoomBaseFrame) <= 0 || CGRectGetHeight(keyboardZoomBaseFrame) <= 0) {
        return 1.0;
    }
    CGRect baseFrameInView = [scrollView convertRect:keyboardZoomBaseFrame toView:self.view];
    CGFloat leadingLimit = [self leadingSafeAreaInset] + CONTENT_EDGE_GAP +
        CGRectGetWidth(self.handle.bounds) + HANDLE_EDGE_GAP;
    CGFloat availableWidth = CGRectGetMaxX(baseFrameInView) - leadingLimit;
    CGFloat maxZoomByWidth = availableWidth / CGRectGetWidth(keyboardZoomBaseFrame);
    if (!isfinite(maxZoomByWidth)) {
        return 1.0;
    }
    CGFloat zoom = MIN((CGFloat)PO_KEYBOARD_ZOOM_REQUESTED_SCALE, maxZoomByWidth);
    return MAX(1.0, MIN(PO_KEYBOARD_ZOOM_REQUESTED_SCALE, zoom));
}

-(BOOL)canApplyCardScale{
    if (![self isPanelFullyOpen] || contextView == nil || contextView.hidden ||
        keyboardZoomContainer.hidden || hostedCategoryTransitionPending ||
        runtimeHostedCategoryTransitionAnimating ||
        keyboardZoomSuspensionReasons != POKeyboardZoomSuspensionNone ||
        CGRectGetWidth(keyboardZoomBaseFrame) <= 0 || CGRectGetHeight(keyboardZoomBaseFrame) <= 0) {
        return NO;
    }
    return [self currentCardScaleContext] == POCardScaleContextLandscapeShellPortraitHosted;
}

-(BOOL)keyboardAutomaticScaleRequested{
    if ([self currentCardScaleContext] != POCardScaleContextLandscapeShellPortraitHosted ||
        keyboardZoomSuppressedForCurrentSession ||
        ![[POApplicationHelper settings][@"landscapeKeyboardZoom"] boolValue]) {
        return NO;
    }
    return hostedKeyboardLayerPresent &&
        keyboardNotificationState == POKeyboardNotificationStateVisible &&
        !keyboardHideAnimationInFlight;
}

-(CGFloat)keyboardZoomScaleForCardScaleContext:(POCardScaleContext)context{
    if (context != POCardScaleContextLandscapeShellPortraitHosted) {
        return 1.0;
    }
    CGFloat scaleValue = [self effectiveLandscapePortraitKeyboardZoomScale];
    return scaleValue >= PO_KEYBOARD_ZOOM_MINIMUM_USEFUL_SCALE ? scaleValue : 1.0;
}

-(CGFloat)resolvedCardScale{
    BOOL closingScaleFrozen = panelState == POPanelStateClosing ||
        (keyboardZoomSuspensionReasons & POKeyboardZoomSuspensionClosing) != 0;
    if (closingScaleFrozen && !keyboardZoomContainer.hidden) {
        CGFloat frozenScale = isfinite(closingFrozenCardScale) && closingFrozenCardScale > 0
            ? closingFrozenCardScale
            : appliedCardScale;
        return isfinite(frozenScale) && frozenScale > 0 ? frozenScale : 1.0;
    }
    if (![self canApplyCardScale]) {
        return 1.0;
    }
    POCardScaleContext context = [self currentCardScaleContext];
    if ([self keyboardAutomaticScaleRequested]) {
        return [self keyboardZoomScaleForCardScaleContext:context];
    }
    return 1.0;
}

-(BOOL)shouldApplyKeyboardZoom{
    return [self currentCardScaleContext] == POCardScaleContextLandscapeShellPortraitHosted &&
        [self resolvedCardScale] > 1.0 + PO_CARD_SCALE_EPSILON;
}

-(CGFloat)handleCompanionTranslationXForScale:(CGFloat)scaleValue{
    if (fabs(scaleValue - 1.0) <= PO_CARD_SCALE_EPSILON || CGRectIsEmpty(keyboardZoomBaseFrame)) {
        return 0;
    }
    return CGRectGetWidth(keyboardZoomBaseFrame) * (1.0 - scaleValue);
}

-(CGPoint)keyboardZoomTargetCenterForBaseFrame:(CGRect)baseFrame scale:(CGFloat)zoom{
    CGPoint anchor = CGPointMake(CGRectGetMaxX(baseFrame), CGRectGetMaxY(baseFrame));
    CGPoint targetCenter = CGPointMake(anchor.x - CGRectGetWidth(baseFrame) * zoom / 2.0,
                                        anchor.y - CGRectGetHeight(baseFrame) * zoom / 2.0);
    CGFloat screenScale = UIScreen.mainScreen.scale;
    targetCenter.x = round(targetCenter.x * screenScale) / screenScale;
    targetCenter.y = round(targetCenter.y * screenScale) / screenScale;
    return targetCenter;
}

-(void)updateKeyboardAnimationFromNotification:(NSNotification *)notification{
    NSDictionary *userInfo = notification.userInfo;
    NSTimeInterval duration = [userInfo[UIKeyboardAnimationDurationUserInfoKey] doubleValue];
    NSInteger curve = [userInfo[UIKeyboardAnimationCurveUserInfoKey] integerValue];
    lastKeyboardAnimationDuration = duration > 0 ? duration : 0.25;
    if (curve < UIViewAnimationCurveEaseInOut || curve > UIViewAnimationCurveLinear) {
        curve = UIViewAnimationCurveEaseInOut;
    }
    lastKeyboardAnimationOptions = UIViewAnimationOptionBeginFromCurrentState |
        UIViewAnimationOptionAllowUserInteraction |
        ((UIViewAnimationOptions)curve << 16);
}

-(BOOL)keyboardFrameHasNonzeroSizeInNotification:(NSNotification *)notification{
    NSValue *frameValue = notification.userInfo[UIKeyboardFrameEndUserInfoKey];
    if (![frameValue isKindOfClass:[NSValue class]]) {
        return YES;
    }
    CGRect keyboardFrame = frameValue.CGRectValue;
    return !CGRectIsEmpty(keyboardFrame) &&
        CGRectGetWidth(keyboardFrame) > 0 &&
        CGRectGetHeight(keyboardFrame) > 0;
}

-(BOOL)keyboardFrameIsVisibleInNotification:(NSNotification *)notification{
    return [self keyboardFrameHasNonzeroSizeInNotification:notification];
}

-(NSTimeInterval)cardScaleAnimationDurationForSource:(POCardScaleTransitionSource)source{
    return source == POCardScaleTransitionSourceKeyboard
        ? lastKeyboardAnimationDuration
        : PO_HANDLE_CARD_SCALE_ANIMATION_DURATION;
}

-(UIViewAnimationOptions)cardScaleAnimationOptionsForSource:(POCardScaleTransitionSource)source{
    if (source == POCardScaleTransitionSourceKeyboard) {
        return lastKeyboardAnimationOptions;
    }
    return UIViewAnimationOptionBeginFromCurrentState |
        UIViewAnimationOptionAllowUserInteraction |
        UIViewAnimationOptionCurveEaseInOut;
}

-(void)reconcileCardChromeZOrder{
    [scrollView bringSubviewToFront:handleScrollView];
}

-(void)applyCardScaleTarget:(CGFloat)targetScale
                   animated:(BOOL)animated
                     source:(POCardScaleTransitionSource)source{
    if (!isfinite(targetScale) || targetScale <= 0) {
        targetScale = 1.0;
    }
    BOOL targetIsBase = fabs(targetScale - 1.0) <= PO_CARD_SCALE_EPSILON;
    if (targetIsBase) {
        targetScale = 1.0;
    }

    CGRect baseFrame = quickSwitchYieldActive && !CGRectIsEmpty(quickSwitchSavedContainerFrame)
        ? quickSwitchSavedContainerFrame
        : keyboardZoomBaseFrame;
    CGPoint targetCenter = targetIsBase
        ? CGPointMake(CGRectGetMidX(baseFrame), CGRectGetMidY(baseFrame))
        : [self keyboardZoomTargetCenterForBaseFrame:keyboardZoomBaseFrame scale:targetScale];
    CGFloat handleTranslationX = targetIsBase ? 0 : [self handleCompanionTranslationXForScale:targetScale];
    POInteractionMode interactionMode = [self currentInteractionMode];
    CGFloat panelBackdropTargetAlpha = interactionMode == POInteractionModeDrawerModal
        ? 0.5 * [self horizontalOpenProgress]
        : 0;

    CGAffineTransform modelTransform = keyboardZoomContainer.transform;
    BOOL cardTransformMatches = targetIsBase
        ? CGAffineTransformEqualToTransform(modelTransform, CGAffineTransformIdentity)
        : fabs(modelTransform.a - targetScale) <= PO_CARD_SCALE_EPSILON &&
          fabs(modelTransform.d - targetScale) <= PO_CARD_SCALE_EPSILON &&
          fabs(modelTransform.b) <= PO_CARD_SCALE_EPSILON && fabs(modelTransform.c) <= PO_CARD_SCALE_EPSILON;
    BOOL handleTransformMatches = fabs(handleScrollView.transform.tx - handleTranslationX) <= 0.25 &&
        fabs(handleScrollView.transform.ty) <= 0.25;
    BOOL backdropMatches = fabs(panelBackdropView.alpha - panelBackdropTargetAlpha) <= 0.001;
    if (fabs(appliedCardScale - targetScale) <= PO_CARD_SCALE_EPSILON &&
        cardTransformMatches && handleTransformMatches && backdropMatches) {
        keyboardZoomApplied = !targetIsBase;
        [self reconcileCardChromeZOrder];
        return;
    }

    NSUInteger generation = ++keyboardZoomGeneration;
    keyboardZoomApplied = !targetIsBase;
    appliedCardScale = targetScale;
    [self reconcileCardChromeZOrder];

    void (^changes)(void) = ^{
        self->keyboardZoomContainer.transform = targetIsBase
            ? CGAffineTransformIdentity
            : CGAffineTransformMakeScale(targetScale, targetScale);
        if (!CGRectIsEmpty(baseFrame)) {
            self->keyboardZoomContainer.center = targetCenter;
        }
        self->handleScrollView.transform = CGAffineTransformMakeTranslation(handleTranslationX, 0);
        if (self->appRailView && !self->appRailView.hidden) {
            [self positionAppRail];
        }
        self->panelBackdropView.alpha = panelBackdropTargetAlpha;
    };

    void (^completion)(__unused BOOL finished) = ^(__unused BOOL finished) {
        if (generation != self->keyboardZoomGeneration) {
            return;
        }
        if (targetIsBase && !CGRectIsEmpty(baseFrame)) {
            [UIView performWithoutAnimation:^{
                self->keyboardZoomContainer.transform = CGAffineTransformIdentity;
                self->keyboardZoomContainer.frame = baseFrame;
                self->handleScrollView.transform = CGAffineTransformIdentity;
            }];
        }
        [self reconcileCardChromeZOrder];
    };

    if (animated) {
        [UIView animateWithDuration:[self cardScaleAnimationDurationForSource:source]
                              delay:0
                            options:[self cardScaleAnimationOptionsForSource:source]
                         animations:changes
                         completion:completion];
    } else {
        [UIView performWithoutAnimation:changes];
        completion(YES);
    }
}

-(void)applyResolvedCardScaleAnimated:(BOOL)animated source:(POCardScaleTransitionSource)source{
    [self applyCardScaleTarget:[self resolvedCardScale] animated:animated source:source];
}

-(void)applyKeyboardZoomAnimated:(BOOL)animated{
    [self applyResolvedCardScaleAnimated:animated source:POCardScaleTransitionSourceKeyboard];
}

-(void)restoreKeyboardZoomAnimated:(BOOL)animated{
    if (scaledProgrammaticCloseAnimating) {
        return;
    }
    [self applyCardScaleTarget:1.0 animated:animated source:POCardScaleTransitionSourceReconcile];
}

-(void)restoreKeyboardZoomImmediately{
    if (scaledProgrammaticCloseAnimating) {
        return;
    }
    [self applyCardScaleTarget:1.0 animated:NO source:POCardScaleTransitionSourceReconcile];
}

-(void)reevaluateCardScaleAnimated:(BOOL)animated source:(POCardScaleTransitionSource)source{
    UIGestureRecognizerState panState = scrollView.panGestureRecognizer.state;
    BOOL scrollPanActive = panState == UIGestureRecognizerStateBegan ||
        panState == UIGestureRecognizerStateChanged;
    if (!scrollView.dragging && !scrollView.decelerating &&
        !scrollSnapAnimationInProgress && !scrollPanActive && handlePanIntent == POHandlePanIntentNone) {
        keyboardZoomSuspensionReasons &= ~POKeyboardZoomSuspensionDragging;
    }
    [self applyResolvedCardScaleAnimated:animated source:source];
}

-(void)reevaluateKeyboardZoomAnimated:(BOOL)animated{
    [self reevaluateCardScaleAnimated:animated source:POCardScaleTransitionSourceReconcile];
}

-(BOOL)shouldHandleTapRestoreKeyboardZoom{
    if (panelState != POPanelStateOpen || [self isPanelTransitioning] ||
        scrollView.dragging || scrollView.decelerating || presentedQuickSwitchMenu ||
        self.handle.layoutMode != POHandleLayoutModeVerticalRail) {
        return NO;
    }
    return [self keyboardAutomaticScaleRequested] &&
        appliedCardScale > 1.0 + PO_CARD_SCALE_EPSILON;
}

-(void)restoreKeyboardZoomFromHandleTap{
    if (![self shouldHandleTapRestoreKeyboardZoom]) {
        return;
    }
    keyboardZoomSuppressedForCurrentSession = YES;
    [self applyResolvedCardScaleAnimated:YES source:POCardScaleTransitionSourceHandle];
}

-(void)addKeyboardZoomSuspension:(POKeyboardZoomSuspensionReason)reason{
    if (reason == POKeyboardZoomSuspensionClosing) {
        closingFrozenCardScale = isfinite(appliedCardScale) && appliedCardScale > 0
            ? appliedCardScale
            : 1.0;
        keyboardZoomSuspensionReasons |= reason;
        return;
    }
    keyboardZoomSuspensionReasons |= reason;
    [self applyResolvedCardScaleAnimated:NO source:POCardScaleTransitionSourceReconcile];
}

-(void)removeKeyboardZoomSuspension:(POKeyboardZoomSuspensionReason)reason{
    keyboardZoomSuspensionReasons &= ~reason;
    if (reason == POKeyboardZoomSuspensionClosing) {
        closingFrozenCardScale = 1.0;
    }
}

-(void)finishPanelDragZoomIfIdle{
    if (scrollView.dragging || scrollView.decelerating || scrollSnapAnimationInProgress ||
        handlePanIntent != POHandlePanIntentNone) {
        return;
    }
    [self removeKeyboardZoomSuspension:POKeyboardZoomSuspensionDragging];
    if (pendingOpenState && [self isPanelFullyOpen]) {
        [self reevaluateKeyboardZoomAnimated:YES];
    }
}

-(void)scheduleFinishPanelDragZoomIfIdle{
    dispatch_async(dispatch_get_main_queue(), ^{
        [self finishPanelDragZoomIfIdle];
    });
}

-(CGFloat)maximumContentOffsetX{
    return MAX(0, scrollView.contentSize.width - scrollView.bounds.size.width);
}

-(CGFloat)handleRailWidth{
    return CGRectGetWidth(self.handle.bounds) + HANDLE_EDGE_GAP * 2.0 + CONTENT_EDGE_GAP;
}

-(CGFloat)maximumHandleOffset{
    return MAX(0, handleScrollView.contentSize.height - handleScrollView.bounds.size.height);
}

-(CGFloat)clampedHandleOffset:(CGFloat)offset{
    return MIN(MAX(0, offset), [self maximumHandleOffset]);
}

-(void)storeHandlePosition{
    if ([self isHorizontalQuickSwitchLayoutMode]) {
        return;
    }
    handlePoint = handleScrollView.contentOffset;
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    [defaults setValue:NSStringFromCGPoint(handlePoint) forKey:@"handlePoint"];
    CGFloat maximumOffset = [self maximumHandleOffset];
    if (maximumOffset > 0) {
        [defaults setDouble:(handlePoint.y / maximumOffset) forKey:@"handlePointRatio"];
    }
}

-(void)inheritVerticalHandleScreenY:(CGFloat)screenY{
    if (self.handle.layoutMode != POHandleLayoutModeVerticalRail || !isfinite(screenY)) {
        return;
    }

    CGFloat targetOffset = CGRectGetMinY(handleScrollView.frame) +
        CGRectGetMinY(self.handle.frame) - screenY;
    [handleScrollView setContentOffset:CGPointMake(0, [self clampedHandleOffset:targetOffset])
                                animated:NO];
}

-(CGFloat)horizontalOpenProgress{
    CGFloat maximumOffset = [self maximumContentOffsetX];
    if (maximumOffset <= 0) {
        return 0;
    }
    return MIN(MAX(0, scrollView.contentOffset.x / maximumOffset), 1);
}

-(UIView *)beginHandleVisualHandoffSnapshot{
    [self clearHandleVisualHandoff];

    CGRect handleInView = [handleScrollView convertRect:self.handle.frame toView:self.view];
    if (CGRectIsEmpty(handleInView) || !isfinite(CGRectGetMinX(handleInView)) ||
        !isfinite(CGRectGetMinY(handleInView))) {
        return nil;
    }

    UIView *snapshot = [self.handle snapshotViewAfterScreenUpdates:NO];
    if (!snapshot) {
        return nil;
    }
    snapshot.frame = handleInView;
    snapshot.userInteractionEnabled = NO;
    snapshot.alpha = MAX(self.handle.alpha, 0.02);
    [self.view addSubview:snapshot];
    [self.view bringSubviewToFront:snapshot];
    handleVisualHandoffSnapshotView = snapshot;

    self.handle.alpha = 0.02;
    return snapshot;
}

-(void)clearHandleVisualHandoff{
    handleVisualHandoffGeneration += 1;
    [handleVisualHandoffSnapshotView.layer removeAllAnimations];
    [handleVisualHandoffSnapshotView removeFromSuperview];
    handleVisualHandoffSnapshotView = nil;
    self.handle.alpha = 1;
}

-(void)completeHandleVisualHandoffFromSnapshot:(UIView *)snapshot{
    if (!snapshot || snapshot != handleVisualHandoffSnapshotView) {
        self.handle.alpha = 1;
        return;
    }

    NSUInteger generation = handleVisualHandoffGeneration;
    [UIView animateWithDuration:0.12
                          delay:0
                        options:(UIViewAnimationOptionCurveEaseOut |
                                 UIViewAnimationOptionBeginFromCurrentState |
                                 UIViewAnimationOptionAllowUserInteraction)
                     animations:^{
        snapshot.alpha = 0;
        self.handle.alpha = 1;
    } completion:^(BOOL finished) {
        if (generation == self->handleVisualHandoffGeneration &&
            snapshot == self->handleVisualHandoffSnapshotView) {
            [snapshot removeFromSuperview];
            self->handleVisualHandoffSnapshotView = nil;
        }
    }];
}

-(void)cancelRuntimeHostedCategoryTransition{
    BOOL wasAnimating = runtimeHostedCategoryTransitionAnimating;
    BOOL hadRuntimeBridge = runtimeCategoryTransitionSnapshotActive || runtimeCategoryTransitionSnapshotFading;
    NSString *runtimeBridgeBundleId = hadRuntimeBridge ? [presentationSnapshotBundleId copy] : nil;
    if (!wasAnimating && !hostedCategoryTransitionPending && !handleVisualHandoffSnapshotView &&
        !hadRuntimeBridge) {
        return;
    }
    if (wasAnimating) {
        runtimeHostedCategoryTransitionGeneration += 1;
        runtimeHostedCategoryTransitionAnimating = NO;
        [keyboardZoomContainer.layer removeAllAnimations];
        [panelBackdropView.layer removeAllAnimations];
        [self.handle.layer removeAnimationForKey:@"po.runtimeRotationOpacity"];
        [UIView performWithoutAnimation:^{
            self->keyboardZoomContainer.transform = CGAffineTransformIdentity;
            if (!CGRectIsEmpty(self->keyboardZoomBaseFrame)) {
                self->keyboardZoomContainer.frame = self->keyboardZoomBaseFrame;
            }
        }];
    }
    hostedCategoryTransitionPending = NO;
    [self clearHandleVisualHandoff];
    if (hadRuntimeBridge) {
        [self clearPresentationSnapshot];
        if (runtimeBridgeBundleId.length > 0) {
            [presentationSnapshotCache removeObjectForKey:runtimeBridgeBundleId];
            [presentationSnapshotCacheOrder removeObject:runtimeBridgeBundleId];
        }
    }
    if (wasAnimating) {
        [self updateInteractionBackdropsAnimated:NO];
        [self removeKeyboardZoomSuspension:POKeyboardZoomSuspensionRotation];
        [self reevaluateKeyboardZoomAnimated:NO];
        [self flushDeferredRuntimeScenePublicationIfNeeded];
    }
}

-(BOOL)canAnimateRuntimeHostedCategoryTransitionFromOrientation:(UIInterfaceOrientation)fromOrientation
                                                  toOrientation:(UIInterfaceOrientation)toOrientation{
    if (panelState != POPanelStateOpen || !contextView || contextView.hidden ||
        keyboardZoomContainer.hidden || presentationRetainedAfterRelease ||
        handlePanIntent != POHandlePanIntentNone || scrollSnapAnimationInProgress ||
        presentedQuickSwitchMenu || (quickSwitchInteractionOverlayView && !quickSwitchInteractionOverlayView.hidden)) {
        return NO;
    }
    if (!POIsConcretePresentationOrientation(fromOrientation) ||
        !POIsConcretePresentationOrientation(toOrientation) ||
        UIInterfaceOrientationIsLandscape(fromOrientation) == UIInterfaceOrientationIsLandscape(toOrientation)) {
        return NO;
    }
    if (![presentationBundleId isEqualToString:pinnedBundleId] ||
        ![hostSession.activeBundleId isEqualToString:pinnedBundleId] ||
        ![ContextHostManager sharedInstance].isForegroundLeaseActive) {
        return NO;
    }
    return YES;
}

-(BOOL)beginRuntimeHostedCategoryTransitionFromOrientation:(UIInterfaceOrientation)fromOrientation
                                             toOrientation:(UIInterfaceOrientation)toOrientation
                                     startingBackdropAlpha:(CGFloat)startingBackdropAlpha
                                  systemAnimationParameters:(id)animationParameters{
    Class animatorClass = NSClassFromString(@"UIStatusBarAnimationParameters");
    SEL animateSelector = NSSelectorFromString(@"animateWithParameters:fromCurrentState:animations:completion:");
    if (!animationParameters || !animatorClass || ![animatorClass respondsToSelector:animateSelector] ||
        ![self canAnimateRuntimeHostedCategoryTransitionFromOrientation:fromOrientation
                                                           toOrientation:toOrientation]) {
        return NO;
    }

    if (NSProcessInfo.processInfo.operatingSystemVersion.majorVersion == 15) {
        return NO;
    }

    NSUInteger hostGeneration = hostSession.currentGeneration;
    CGPoint oldScreenCenter = [scrollView convertPoint:keyboardZoomContainer.center toView:self.view];
    CGSize oldBoundsSize = keyboardZoomContainer.bounds.size;
    UIView *handleSnapshot = [self beginHandleVisualHandoffSnapshot];
    [self applyLayoutPreservingHandlePosition:YES];
    CGPoint finalCenter = keyboardZoomContainer.center;
    CGPoint initialCenter = [self.view convertPoint:oldScreenCenter toView:scrollView];
    CGSize finalBoundsSize = keyboardZoomContainer.bounds.size;
    POInteractionMode finalInteractionMode = [self baseInteractionModeForHostedOrientation:toOrientation];
    CGFloat finalBackdropAlpha = finalInteractionMode == POInteractionModeDrawerModal
        ? 0.5 * [self horizontalOpenProgress]
        : 0;
    BOOL fadeInBackdropAfterRotation = UIInterfaceOrientationIsLandscape(fromOrientation) &&
        !UIInterfaceOrientationIsLandscape(toOrientation) &&
        finalInteractionMode == POInteractionModeDrawerModal && finalBackdropAlpha > 0.001;
    CGFloat rotationBackdropAlpha = fadeInBackdropAfterRotation ? 0 : finalBackdropAlpha;

    CGFloat rotatedFinalWidth = finalBoundsSize.height;
    CGFloat rotatedFinalHeight = finalBoundsSize.width;
    if (oldBoundsSize.width <= 0 || oldBoundsSize.height <= 0 ||
        rotatedFinalWidth <= 0 || rotatedFinalHeight <= 0) {
        if (handleSnapshot == handleVisualHandoffSnapshotView) {
            [handleSnapshot removeFromSuperview];
            handleVisualHandoffSnapshotView = nil;
        }
        self.handle.alpha = 1;
        return NO;
    }

    CGFloat scaleX = oldBoundsSize.width / rotatedFinalWidth;
    CGFloat scaleY = oldBoundsSize.height / rotatedFinalHeight;
    CGFloat inverseScale = MIN(scaleX, scaleY);
    if (!isfinite(inverseScale) || inverseScale <= 0) {
        if (handleSnapshot == handleVisualHandoffSnapshotView) {
            [handleSnapshot removeFromSuperview];
            handleVisualHandoffSnapshotView = nil;
        }
        self.handle.alpha = 1;
        return NO;
    }

    CGFloat inverseAngle = POPresentationAngleForOrientation(fromOrientation) -
        POPresentationAngleForOrientation(toOrientation);
    CGAffineTransform initialTransform = CGAffineTransformMakeRotation(inverseAngle);
    initialTransform = CGAffineTransformScale(initialTransform, inverseScale, inverseScale);

    [keyboardZoomContainer.layer removeAllAnimations];
    [panelBackdropView.layer removeAllAnimations];
    [self.handle.layer removeAllAnimations];
    [UIView performWithoutAnimation:^{
        self->keyboardZoomContainer.transform = initialTransform;
        self->keyboardZoomContainer.center = initialCenter;
        self->panelBackdropView.alpha = startingBackdropAlpha;
        self.handle.alpha = handleSnapshot ? 0.02 : 1;
    }];

    runtimeHostedCategoryTransitionAnimating = YES;
    NSUInteger generation = ++runtimeHostedCategoryTransitionGeneration;
    void (^animations)(void) = ^{
        self->keyboardZoomContainer.transform = CGAffineTransformIdentity;
        self->keyboardZoomContainer.center = finalCenter;
        self->panelBackdropView.alpha = rotationBackdropAlpha;
        if (handleSnapshot && handleSnapshot == self->handleVisualHandoffSnapshotView) {
            handleSnapshot.alpha = 0;
            self.handle.alpha = 1;
        }
    };
    void (^completion)(BOOL) = ^(__unused BOOL finished) {
        if (generation != self->runtimeHostedCategoryTransitionGeneration) {
            return;
        }
        self->runtimeHostedCategoryTransitionAnimating = NO;
        [UIView performWithoutAnimation:^{
            self->keyboardZoomContainer.transform = CGAffineTransformIdentity;
            self->keyboardZoomContainer.center = finalCenter;
            self->panelBackdropView.alpha = rotationBackdropAlpha;
            self.handle.alpha = 1;
        }];
        if (handleSnapshot == self->handleVisualHandoffSnapshotView) {
            [handleSnapshot removeFromSuperview];
            self->handleVisualHandoffSnapshotView = nil;
        }
        [self removeKeyboardZoomSuspension:POKeyboardZoomSuspensionRotation];
        [self reevaluateKeyboardZoomAnimated:NO];
        if (fadeInBackdropAfterRotation) {
            dispatch_async(dispatch_get_main_queue(), ^{
                if (generation != self->runtimeHostedCategoryTransitionGeneration ||
                    self->runtimeHostedCategoryTransitionAnimating) {
                    return;
                }

                [self updateInteractionBackdropsAnimated:NO];
                [self->panelBackdropView.layer removeAnimationForKey:@"po.runtimeBackdropFadeIn"];
                CABasicAnimation *fade = [CABasicAnimation animationWithKeyPath:@"opacity"];
                fade.fromValue = @0;
                fade.toValue = @(self->panelBackdropView.alpha);
                fade.duration = 0.20;
                fade.timingFunction = [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseOut];
                [self->panelBackdropView.layer addAnimation:fade forKey:@"po.runtimeBackdropFadeIn"];
            });
        } else {
            [self updateInteractionBackdropsAnimated:NO];
        }

        [self flushDeferredRuntimeScenePublicationIfNeeded];

        if (hostGeneration == self->hostSession.currentGeneration) {
            ContextHostManager *manager = [ContextHostManager sharedInstance];
            UIInterfaceOrientation sourceOrientation =
                manager.currentHostedPresentationSourceOrientation;
            BOOL sourceNeedsCanonicalization =
                POIsConcretePresentationOrientation(sourceOrientation) &&
                POIsConcretePresentationOrientation(toOrientation) &&
                UIInterfaceOrientationIsLandscape(sourceOrientation) !=
                    UIInterfaceOrientationIsLandscape(toOrientation);
            if (sourceNeedsCanonicalization) {
                if (NSProcessInfo.processInfo.operatingSystemVersion.majorVersion == 15) {
                    self->runtimeScenePublicationStaging = YES;
                    [manager canonicalizeHostedSourceForCurrentOrientationWithGeneration:hostGeneration];
                    self->runtimeScenePublicationStaging = NO;
                } else {
                    BOOL snapshotReady =
                        [self prepareRuntimeCategoryTransitionSnapshotFromSourceOrientation:sourceOrientation];
                    if (snapshotReady) {
                        [self retargetRuntimeCategoryTransitionSnapshotForOrientation:toOrientation];
                    }
                    BOOL canonicalizationStarted = snapshotReady &&
                        [manager canonicalizeHostedSourceForCurrentOrientationWithGeneration:hostGeneration];
                    if (snapshotReady && !canonicalizationStarted) {
                        [self clearPresentationSnapshot];
                    }
                }
            }
        }
    };

    ((void (*)(id, SEL, id, BOOL, id, id))objc_msgSend)(
        animatorClass, animateSelector, animationParameters, YES, animations, completion);
    return YES;
}

-(void)updatePortraitHostedLandscapeHandleForCurrentOffset{
    if (self.handle.layoutMode != POHandleLayoutModeLandscapeFixedBottomLeft ||
        CGRectIsEmpty(keyboardZoomBaseFrame)) {
        return;
    }

    CGFloat maximumOffset = [self maximumContentOffsetX];
    CGFloat progress = maximumOffset > 0
        ? MIN(MAX(scrollView.contentOffset.x / maximumOffset, 0), 1)
        : 0;

    CGFloat openCardX = CGRectGetMinX(keyboardZoomBaseFrame) - maximumOffset;
    CGFloat openHandleX = openCardX;
    CGFloat closedHandleX = CGRectGetWidth(self.view.bounds) - CONTENT_EDGE_GAP - CGRectGetWidth(self.handle.bounds);
    CGFloat desiredScreenX = closedHandleX + (openHandleX - closedHandleX) * progress;

    CGFloat desiredScreenY = CGRectGetMaxY(keyboardZoomBaseFrame) + HANDLE_EDGE_GAP;

    CGRect railFrame = handleScrollView.frame;
    railFrame.origin.x = desiredScreenX + scrollView.contentOffset.x;
    handleScrollView.frame = railFrame;

    self.handle.restingOriginX = 0;
    CGRect handleFrame = self.handle.frame;
    handleFrame.origin.x = 0;
    handleFrame.origin.y = desiredScreenY - CGRectGetMinY(handleScrollView.frame);
    self.handle.frame = handleFrame;
}

-(CGFloat)currentHandleScreenY{
    CGRect handleInView = [handleScrollView convertRect:self.handle.frame toView:self.view];
    return !CGRectIsEmpty(handleInView) && isfinite(CGRectGetMinY(handleInView))
        ? CGRectGetMinY(handleInView)
        : NAN;
}

-(BOOL)isPanelFullyClosedAndIdle{
    return panelState == POPanelStateClosed &&
        !scrollSnapAnimationInProgress && !scrollView.dragging && !scrollView.decelerating &&
        fabs(scrollView.contentOffset.x) <= CLOSED_CONTENT_OFFSET_EPSILON;
}

-(BOOL)canBeginQuickSwitchSession{
    if (presentedQuickSwitchMenu || scrollSnapAnimationInProgress ||
        scrollView.dragging || scrollView.decelerating ||
        handlePanIntent != POHandlePanIntentNone || hostedCategoryTransitionPending ||
        runtimeHostedCategoryTransitionAnimating || handleVisualHandoffSnapshotView) {
        return NO;
    }
    return [self isPanelFullyClosedAndIdle] || [self isPanelFullyOpen];
}

-(void)finishPanelSnapToOpenState:(BOOL)shouldOpen{
    scrollSnapAnimationInProgress = NO;
    interactiveHostIntentIssued = NO;
    interactiveHostResumeRequired = NO;

    if (shouldOpen) {
        panelState = POPanelStateOpen;
        keyboardZoomContainer.hidden = NO;
        [self updateAppRailVisibilityAnimated:YES];
        if (presentationSnapshotView && !presentationSnapshotView.hidden &&
            hostSession.state == POHostSessionStateLive) {
            [self schedulePresentationSnapshotRetirementForBundleId:hostSession.requestedBundleId
                                                          generation:hostSession.currentGeneration];
        }
        if ([self isPanelFullyOpen]) {
            [self removeKeyboardZoomSuspension:POKeyboardZoomSuspensionDragging];
            [self reevaluateCardScaleAnimated:YES source:POCardScaleTransitionSourceReconcile];
        }
    } else {
        [scrollView setContentOffset:CGPointZero animated:NO];
        [self hidePresentationContainer];
        shadowView.layer.shadowOpacity = 0;
        splitLayoutActive = NO;
        [self resetHostedFloatingWindowState];
        BOOL deferSessionCleanup = deferScaledCloseSessionCleanup;
        deferScaledCloseSessionCleanup = NO;
        if (!deferSessionCleanup) {
            [self capturePresentationSnapshotIfPossible];
        }
        POQuickSwitchLayoutMode previousLayoutMode = [self currentQuickSwitchLayoutMode];
        CGFloat inheritedHandleScreenY = NAN;
        if (previousLayoutMode == POQuickSwitchLayoutModeHorizontalBottom) {
            CGRect handleInView = [handleScrollView convertRect:self.handle.frame toView:self.view];
            if (!CGRectIsEmpty(handleInView) && isfinite(CGRectGetMinY(handleInView))) {
                inheritedHandleScreenY = CGRectGetMinY(handleInView);
            }
        }
        UIView *handleHandoffSnapshot = nil;
        if (previousLayoutMode == POQuickSwitchLayoutModeHorizontalBottom) {
            handleHandoffSnapshot = [self beginHandleVisualHandoffSnapshot];
        }
        panelState = POPanelStateClosed;
        [self updateAppRailVisibilityAnimated:NO];
        if (previousLayoutMode != [self currentQuickSwitchLayoutMode]) {
            [self applyLayoutPreservingHandlePosition:YES];
            [self inheritVerticalHandleScreenY:inheritedHandleScreenY];
        }
        [self completeHandleVisualHandoffFromSnapshot:handleHandoffSnapshot];
        keyboardNotificationState = POKeyboardNotificationStateUnknown;
        hostedKeyboardLayerPresent = NO;
        keyboardHideAnimationInFlight = NO;
        keyboardStateHostGeneration = 0;
        keyboardZoomSuppressedForCurrentSession = NO;
        [self restoreKeyboardZoomImmediately];
        [self removeKeyboardZoomSuspension:POKeyboardZoomSuspensionDragging];
        showingCantHost = NO;
        if (externalSceneStack) {
            [externalSceneStack removeFromSuperview];
            externalSceneStack = nil;
        }
        if (deferSessionCleanup) {
            NSUInteger cleanupGeneration = deferredOpenGeneration;
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                         (int64_t)(PO_SCALED_CLOSE_POST_COMMIT_CLEANUP_DELAY * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{
                if (cleanupGeneration != self->deferredOpenGeneration ||
                    self->panelState != POPanelStateClosed) {
                    return;
                }
                [self capturePresentationSnapshotIfPossible];
                [self retainPresentationAfterReleaseIfPossible];
                [self->hostSession releaseActiveSessionPreservingPresentation];
                [[POSplitSessionController sharedInstance] end];
            });
        } else {
            [self retainPresentationAfterReleaseIfPossible];
            [hostSession releaseActiveSessionPreservingPresentation];
            [[POSplitSessionController sharedInstance] end];
        }
        [self storeHandlePosition];
        [self resetAutoNubTimer];
    }
    [self scheduleFinishPanelDragZoomIfIdle];
}

-(void)preparePanelForOpenPresentationIfNeeded{
    if (panelState != POPanelStateClosed) {
        return;
    }

    if ([self isHandleVisiblyNubbed]) {
        self.handle.isNubbed = NO;
    }

    POQuickSwitchLayoutMode previousLayoutMode = [self currentQuickSwitchLayoutMode];
    UIView *handleHandoffSnapshot = nil;
    if ([self shouldUsePortraitHostedLandscapeOptimizationForOrientation:
            [self resolvedHostedLayoutOrientation]]) {
        handleHandoffSnapshot = [self beginHandleVisualHandoffSnapshot];
    }

    panelState = POPanelStateOpening;
    if (previousLayoutMode != [self currentQuickSwitchLayoutMode]) {
        [self applyLayoutPreservingHandlePosition:YES];
    }
    if (handleHandoffSnapshot) {
        [self completeHandleVisualHandoffFromSnapshot:handleHandoffSnapshot];
    }
}

-(void)snapPanelToOpenState:(BOOL)shouldOpen{
    POPanelState previousState = panelState;
    pendingOpenState = shouldOpen;

    if (shouldOpen && previousState == POPanelStateClosed) {
        [self preparePanelForOpenPresentationIfNeeded];
    }
    if (!shouldOpen && previousState != POPanelStateClosed && previousState != POPanelStateClosing) {
        [self clearPresentationSnapshot];
        [hostSession beginClosingPreservingActiveLease];
    }
    POQuickSwitchLayoutMode previousLayoutMode = [self currentQuickSwitchLayoutMode];
    panelState = shouldOpen ? POPanelStateOpening : POPanelStateClosing;
    if (previousLayoutMode != [self currentQuickSwitchLayoutMode]) {
        [self applyLayoutPreservingHandlePosition:YES];
    }
    CGFloat maximumOffset = [self maximumContentOffsetX];
    CGFloat targetOffset = shouldOpen ? maximumOffset : 0;
    CGFloat rawOffsetX = scrollView.contentOffset.x;
    CGFloat rawOffsetY = scrollView.contentOffset.y;

    BOOL xAlreadyOnTarget = fabs(rawOffsetX - targetOffset) <= CLOSED_CONTENT_OFFSET_EPSILON;
    BOOL yAlreadyClean = fabs(rawOffsetY) <= CLOSED_CONTENT_OFFSET_EPSILON;
    if (xAlreadyOnTarget && yAlreadyClean) {
        [self finishPanelSnapToOpenState:shouldOpen];
        return;
    }

    if (xAlreadyOnTarget && !yAlreadyClean) {
        [scrollView setContentOffset:CGPointMake(targetOffset, 0) animated:NO];
        [self finishPanelSnapToOpenState:shouldOpen];
        return;
    }

    scrollSnapAnimationInProgress = YES;
    if (scrollView.decelerating) {
        [scrollView setContentOffset:scrollView.contentOffset animated:NO];
    }
    [scrollView setContentOffset:CGPointMake(targetOffset, 0) animated:YES];
}

- (BOOL)gestureRecognizer:(UIGestureRecognizer *)gestureRecognizer
    shouldRecognizeSimultaneouslyWithGestureRecognizer:(UIGestureRecognizer *)otherGestureRecognizer {
    return NO;
}

-(BOOL)canUseDirectScaledProgrammaticCloseAnimation{
    return panelState == POPanelStateOpen &&
        !scrollSnapAnimationInProgress && !scrollView.dragging && !scrollView.decelerating &&
        self.handle.layoutMode == POHandleLayoutModeVerticalRail &&
        !keyboardZoomContainer.hidden &&
        fabs(appliedCardScale - 1.0) > PO_CARD_SCALE_EPSILON &&
        fabs(scrollView.contentOffset.x - [self maximumContentOffsetX]) <= CLOSED_CONTENT_OFFSET_EPSILON &&
        !CGRectIsEmpty(keyboardZoomBaseFrame);
}

-(void)performDirectScaledProgrammaticCloseAnimation{
    if (![self canUseDirectScaledProgrammaticCloseAnimation]) {
        [self snapPanelToOpenState:NO];
        return;
    }

    pendingOpenState = NO;
    [self cancelPresentationHandoff];
    [hostSession beginClosingPreservingActiveLease];
    panelState = POPanelStateClosing;
    scrollSnapAnimationInProgress = YES;
    scaledProgrammaticCloseAnimating = YES;
    scaledProgrammaticCloseNeedsLayout = NO;
    CALayer *cardPresentationLayer = keyboardZoomContainer.layer.presentationLayer;
    CALayer *handlePresentationLayer = handleScrollView.layer.presentationLayer;
    CGPoint cardStartCenter = cardPresentationLayer ? cardPresentationLayer.position : keyboardZoomContainer.center;
    CGPoint handleStartCenter = handlePresentationLayer ? handlePresentationLayer.position : handleScrollView.center;
    CGAffineTransform cardVisualTransform = cardPresentationLayer
        ? cardPresentationLayer.affineTransform
        : keyboardZoomContainer.transform;
    CGAffineTransform handleVisualTransform = handlePresentationLayer
        ? handlePresentationLayer.affineTransform
        : handleScrollView.transform;

    keyboardZoomGeneration += 1;
    [keyboardZoomContainer.layer removeAllAnimations];
    [handleScrollView.layer removeAllAnimations];
    [panelBackdropView.layer removeAllAnimations];
    [quickSwitchBackdropView.layer removeAllAnimations];
    [shadowView.layer removeAllAnimations];
    [UIView performWithoutAnimation:^{
        self->keyboardZoomContainer.center = cardStartCenter;
        self->keyboardZoomContainer.transform = cardVisualTransform;
        self->handleScrollView.center = handleStartCenter;
        self->handleScrollView.transform = handleVisualTransform;
    }];

    CGFloat visualScale = fabs(cardVisualTransform.a);
    if (!isfinite(visualScale) || visualScale <= 0) {
        visualScale = isfinite(appliedCardScale) && appliedCardScale > 0 ? appliedCardScale : 1.0;
    }
    appliedCardScale = visualScale;
    closingFrozenCardScale = visualScale;

    CGFloat maximumOffset = [self maximumContentOffsetX];
    CGFloat handleCompanionX = handleVisualTransform.tx;
    CGFloat enlargementOverflow = MAX(0.0, CGRectGetWidth(keyboardZoomBaseFrame) * (visualScale - 1.0));
    CGFloat cardTravelX = maximumOffset + enlargementOverflow + CONTENT_SHADOW_FADE_DISTANCE;
    CGFloat handleTravelX = maximumOffset - handleCompanionX;

    CGPoint cardEndCenter = CGPointMake(cardStartCenter.x + cardTravelX, cardStartCenter.y);
    CGPoint handleEndCenter = CGPointMake(handleStartCenter.x + handleTravelX, handleStartCenter.y);

    [UIView animateWithDuration:PO_SCALED_PROGRAMMATIC_CLOSE_DURATION
                          delay:0
                        options:(UIViewAnimationOptionCurveEaseInOut |
                                 UIViewAnimationOptionBeginFromCurrentState |
                                 UIViewAnimationOptionAllowUserInteraction)
                     animations:^{
        self->keyboardZoomContainer.center = cardEndCenter;
        self->handleScrollView.center = handleEndCenter;
        self->panelBackdropView.alpha = 0;
        self->quickSwitchBackdropView.alpha = 0;
        self->shadowView.layer.shadowOpacity = 0;
    } completion:^(__unused BOOL finished) {
        if (!self->scaledProgrammaticCloseAnimating) {
            return;
        }

        BOOL replayDeferredLayout = self->scaledProgrammaticCloseNeedsLayout;
        [UIView performWithoutAnimation:^{
            [self hidePresentationContainer];
            [self->scrollView setContentOffset:CGPointZero animated:NO];
            self->keyboardZoomContainer.center = cardStartCenter;
            self->handleScrollView.center = handleStartCenter;
            self->handleScrollView.transform = CGAffineTransformIdentity;
        }];
        self->scaledProgrammaticCloseAnimating = NO;
        self->scaledProgrammaticCloseNeedsLayout = NO;
        self->deferScaledCloseSessionCleanup = YES;
        [self finishPanelSnapToOpenState:NO];
        if (replayDeferredLayout) {
            [self applyCurrentSettings];
        }
    }];
}

-(CGFloat)portraitHostedLandscapeReservedBottomChromeHeight{
    return MAX(CGRectGetHeight(self.handle.bounds), [QuickSwitchHorizontalBarView preferredBarHeight]);
}

-(CGFloat)clampedPortraitHostedLandscapeCardBottomYForHandleAnchorY:(CGFloat)handleAnchorY
                                                          cardHeight:(CGFloat)cardHeight{
    CGRect bounds = self.view.bounds;
    UIEdgeInsets viewInsets = self.view.safeAreaInsets;
    UIEdgeInsets windowInsets = self.view.window.safeAreaInsets;
    CGFloat topInset = MAX(viewInsets.top, windowInsets.top) + CONTENT_EDGE_GAP;
    CGFloat bottomInset = MAX(viewInsets.bottom, windowInsets.bottom) + CONTENT_EDGE_GAP;
    CGFloat minimumCardBottomY = topInset + cardHeight;
    CGFloat maximumCardBottomY = CGRectGetHeight(bounds) - bottomInset -
        [self portraitHostedLandscapeReservedBottomChromeHeight] - HANDLE_EDGE_GAP;
    if (maximumCardBottomY < minimumCardBottomY) {
        return minimumCardBottomY;
    }
    CGFloat desiredCardBottomY = handleAnchorY - HANDLE_EDGE_GAP;
    return MIN(MAX(desiredCardBottomY, minimumCardBottomY), maximumCardBottomY);
}

-(void)syncHorizontalQuickSwitchPresentationAnchor{
    if (!quickSwitchHorizontalBarView ||
        [self currentQuickSwitchLayoutMode] != POQuickSwitchLayoutModeHorizontalBottom ||
        CGRectIsEmpty(keyboardZoomBaseFrame)) {
        return;
    }
    quickSwitchHorizontalBarView.presentationAnchorFrame =
        CGRectOffset(keyboardZoomBaseFrame, -[self maximumContentOffsetX], 0);
}

-(BOOL)canMovePortraitHostedLandscapeCardVertically{
    return panelState == POPanelStateOpen &&
        [self currentQuickSwitchLayoutMode] == POQuickSwitchLayoutModeHorizontalBottom &&
        !presentedQuickSwitchMenu &&
        (quickSwitchInteractionOverlayView == nil || quickSwitchInteractionOverlayView.hidden) &&
        !scrollSnapAnimationInProgress && !scrollView.dragging && !scrollView.decelerating &&
        !CGRectIsEmpty(keyboardZoomBaseFrame);
}

-(void)applyPortraitHostedLandscapeVerticalHandleAnchorY:(CGFloat)handleAnchorY{
    if (![self canMovePortraitHostedLandscapeCardVertically] &&
        handlePanIntent != POHandlePanIntentVerticalCardMove) {
        return;
    }
    CGFloat cardHeight = CGRectGetHeight(keyboardZoomBaseFrame);
    if (cardHeight <= 0) {
        return;
    }
    CGFloat cardBottomY = [self clampedPortraitHostedLandscapeCardBottomYForHandleAnchorY:handleAnchorY
                                                                                     cardHeight:cardHeight];
    CGFloat screenScale = UIScreen.mainScreen.scale;
    CGRect baseFrame = keyboardZoomBaseFrame;
    baseFrame.origin.y = round((cardBottomY - cardHeight) * screenScale) / screenScale;
    portraitHostedLandscapeHandleAnchorY = cardBottomY + HANDLE_EDGE_GAP;
    keyboardZoomBaseFrame = baseFrame;

    [UIView performWithoutAnimation:^{
        self->keyboardZoomContainer.transform = CGAffineTransformIdentity;
        self->keyboardZoomContainer.frame = baseFrame;
    }];
    [self updatePortraitHostedLandscapeHandleForCurrentOffset];
    [self syncHorizontalQuickSwitchPresentationAnchor];
}

#pragma mark - 分屏悬浮窗口(DynamicStage 式真悬浮:可关闭/拖动/双指缩放)

// 悬浮窗口只在分屏会话内可用:面板完全打开、空闲且托管内容已发布。
-(BOOL)isHostedFloatingWindowEligible{
    return panelState == POPanelStateOpen && splitLayoutActive && contextView != nil &&
        !hostedCategoryTransitionPending && !runtimeHostedCategoryTransitionAnimating &&
        !scrollSnapAnimationInProgress && !scrollView.dragging && !scrollView.decelerating;
}

// 悬浮窗口的画布宽高比:优先发布源画布,保证任意尺寸下保持比例。
-(CGSize)hostedFloatingAspectCanvasSize{
    CGSize canvas = presentationSourceCanvasSize;
    if (canvas.width <= 0 || canvas.height <= 0) {
        canvas = [self contextManagerPreferredSceneStackSize:nil];
    }
    if (canvas.width <= 0 || canvas.height <= 0) {
        canvas = self.view.bounds.size;
    }
    return canvas;
}

// 画布等比放入盒子内的最大尺寸。
-(CGSize)hostedFloatingSizeByFittingCanvas:(CGSize)canvas intoBox:(CGSize)box{
    if (canvas.width <= 0 || canvas.height <= 0 || box.width <= 0 || box.height <= 0) {
        return CGSizeMake(MAX(1.0, box.width), MAX(1.0, box.height));
    }
    CGFloat fitScale = MIN(box.width / canvas.width, box.height / canvas.height);
    return CGSizeMake(floorf(canvas.width * fitScale), floorf(canvas.height * fitScale));
}

-(CGFloat)hostedFloatingTopInsetForBounds:(CGRect)bounds{
    UIEdgeInsets viewInsets = self.view.safeAreaInsets;
    UIEdgeInsets windowInsets = self.view.window.safeAreaInsets;
    return MAX(viewInsets.top, windowInsets.top);
}

-(CGFloat)hostedFloatingBottomInsetForBounds:(CGRect)bounds{
    UIEdgeInsets viewInsets = self.view.safeAreaInsets;
    UIEdgeInsets windowInsets = self.view.window.safeAreaInsets;
    return MAX(viewInsets.bottom, windowInsets.bottom);
}

// 悬浮默认形态("半屏"锚点):画布等比放入屏宽 92% × 可用高 52%,水平居中、贴顶部安全区。
-(CGRect)hostedFloatingDefaultFrameForBounds:(CGRect)bounds{
    CGFloat topInset = [self hostedFloatingTopInsetForBounds:bounds];
    CGFloat bottomInset = [self hostedFloatingBottomInsetForBounds:bounds];
    CGSize box = CGSizeMake(CGRectGetWidth(bounds) * 0.92,
                            MAX(1.0, (CGRectGetHeight(bounds) - topInset - bottomInset) * 0.52));
    CGSize target = [self hostedFloatingSizeByFittingCanvas:[self hostedFloatingAspectCanvasSize]
                                                     intoBox:box];
    CGFloat originX = floorf((CGRectGetWidth(bounds) - target.width) / 2.0);
    CGFloat originY = floorf(topInset + POHostedWindowChromeView.barHeight + CONTENT_EDGE_GAP);
    return CGRectMake(originX, originY, target.width, target.height);
}

// 悬浮框夹紧:尺寸超限按画布比例收敛(上限为全屏宽/可用高,与钉底卡同宽级),
// 位置限制在屏幕安全区内。
-(CGRect)clampedHostedFloatingFrameForBounds:(CGRect)bounds frame:(CGRect)frame{
    CGFloat topInset = [self hostedFloatingTopInsetForBounds:bounds];
    CGFloat bottomInset = [self hostedFloatingBottomInsetForBounds:bounds];
    CGFloat maxWidth = CGRectGetWidth(bounds);
    CGFloat maxHeight = CGRectGetHeight(bounds) - topInset - bottomInset;
    if (maxWidth <= 0 || maxHeight <= 0) {
        return frame;
    }
    CGSize canvas = [self hostedFloatingAspectCanvasSize];
    CGFloat aspect = canvas.width > 0 ? canvas.height / canvas.width : 1.0;

    CGFloat width = MIN(MAX(CGRectGetWidth(frame), PO_HOSTED_FLOAT_MIN_WIDTH), maxWidth);
    CGFloat height = width * aspect;
    if (height > maxHeight) {
        height = maxHeight;
        width = MIN(maxWidth, height / MAX(0.0001, aspect));
        width = MAX(width, MIN(PO_HOSTED_FLOAT_MIN_WIDTH, maxWidth));
    }
    CGFloat originX = CGRectGetMinX(frame);
    CGFloat originY = CGRectGetMinY(frame);
    originX = MIN(MAX(originX, 0.0), CGRectGetWidth(bounds) - width);
    originY = MIN(MAX(originY, topInset), CGRectGetHeight(bounds) - bottomInset - height);
    return CGRectMake(floorf(originX), floorf(originY), floorf(width), floorf(height));
}

// 悬浮 frame(self.view 坐标)落到卡片容器(scrollView 坐标,开态偏移 maximumContentOffsetX)。
-(void)applyHostedFloatingWindowFrame:(CGRect)frameInView animated:(BOOL)animated{
    if (!keyboardZoomContainer || !shadowView || !self.contentView) {
        return;
    }
    hostedWindowFloating = YES;
    hostedFloatingWindowFrame = frameInView;
    CGFloat maximumOffset = [self maximumContentOffsetX];
    CGFloat screenScale = UIScreen.mainScreen.scale;
    CGRect containerFrame = CGRectOffset(frameInView, maximumOffset, 0);
    containerFrame = CGRectMake(roundf(containerFrame.origin.x * screenScale) / screenScale,
                                roundf(containerFrame.origin.y * screenScale) / screenScale,
                                roundf(containerFrame.size.width * screenScale) / screenScale,
                                roundf(containerFrame.size.height * screenScale) / screenScale);
    keyboardZoomBaseFrame = containerFrame;

    void (^applyBlock)(void) = ^{
        self->keyboardZoomContainer.frame = containerFrame;
        self->shadowView.frame = self->keyboardZoomContainer.bounds;
        self.contentView.frame = self->keyboardZoomContainer.bounds;
        self->shadowView.layer.shadowPath =
            [UIBezierPath bezierPathWithRoundedRect:self->shadowView.bounds
                                       cornerRadius:CONTENT_CORNER_RADIUS].CGPath;
        [self layoutContextView];
        [self updateHostedWindowChrome];
    };
    if (animated) {
        [UIView animateWithDuration:PO_HOSTED_FLOAT_ANIMATION_DURATION
                              delay:0
                            options:(UIViewAnimationOptionCurveEaseOut |
                                     UIViewAnimationOptionBeginFromCurrentState)
                         animations:applyBlock
                         completion:nil];
    } else {
        [UIView performWithoutAnimation:applyBlock];
    }
}

-(void)enterHostedFloatingWindowAnimated:(BOOL)animated{
    if (![self isHostedFloatingWindowEligible]) {
        return;
    }
    CGRect target = [self hostedFloatingDefaultFrameForBounds:self.view.bounds];
    [self applyHostedFloatingWindowFrame:target animated:animated];
}

// 回到分屏钉底形态:借 applyLayout 重算钉底 frame,再从当前位置动画归位。
-(void)exitHostedFloatingWindowAnimated:(BOOL)animated{
    hostedWindowFloating = NO;
    hostedFloatingWindowFrame = CGRectZero;
    if (!animated || !keyboardZoomContainer) {
        [self applyLayoutPreservingHandlePosition:YES];
        return;
    }
    CGRect previousFrame = keyboardZoomContainer.frame;
    [self applyLayoutPreservingHandlePosition:YES];
    CGRect targetFrame = keyboardZoomContainer.frame;
    if (CGRectEqualToRect(previousFrame, targetFrame)) {
        return;
    }
    keyboardZoomContainer.frame = previousFrame;
    [UIView animateWithDuration:PO_HOSTED_FLOAT_ANIMATION_DURATION
                          delay:0
                        options:(UIViewAnimationOptionCurveEaseOut |
                                 UIViewAnimationOptionBeginFromCurrentState)
                     animations:^{
        self->keyboardZoomContainer.frame = targetFrame;
        [self updateHostedWindowChrome];
    } completion:nil];
}

-(void)resetHostedFloatingWindowState{
    hostedWindowFloating = NO;
    hostedFloatingWindowFrame = CGRectZero;
    hostedWindowPinchActive = NO;
    hostedWindowPinchStartedFloating = NO;
    if (hostedWindowChrome) {
        [UIView performWithoutAnimation:^{
            self->hostedWindowChrome.mode = POHostedWindowChromeModeHidden;
            self->hostedWindowChrome.hidden = YES;
        }];
    }
}

-(void)updateHostedWindowChrome{
    if (!hostedWindowChrome) {
        return;
    }
    BOOL shouldShow = panelState == POPanelStateOpen && splitLayoutActive && contextView != nil;
    if (!shouldShow) {
        hostedWindowChrome.mode = POHostedWindowChromeModeHidden;
        hostedWindowChrome.hidden = YES;
        return;
    }
    BOOL leftHanded = [[POApplicationHelper settings][@"leftHanded"] boolValue];
    hostedWindowChrome.closeOnTrailingSide = !leftHanded;
    if (hostedWindowFloating) {
        hostedWindowChrome.mode = POHostedWindowChromeModeBar;
        hostedWindowChrome.frame = CGRectMake(0, 0,
                                              CGRectGetWidth(self.contentView.bounds),
                                              POHostedWindowChromeView.barHeight);
    } else {
        hostedWindowChrome.mode = POHostedWindowChromeModeCompact;
        CGFloat badgeSize = POHostedWindowChromeView.compactBadgeSize;
        CGFloat badgeInset = 6.0;
        CGFloat badgeX = hostedWindowChrome.closeOnTrailingSide
            ? CGRectGetWidth(self.contentView.bounds) - badgeSize - badgeInset
            : badgeInset;
        hostedWindowChrome.frame = CGRectMake(badgeX, badgeInset, badgeSize, badgeSize);
    }
    hostedWindowChrome.hidden = NO;
    [self.contentView addSubview:hostedWindowChrome];
}

-(void)handleHostedWindowPinch:(UIPinchGestureRecognizer *)recognizer{
    switch (recognizer.state) {
        case UIGestureRecognizerStateBegan: {
            if (![self isHostedFloatingWindowEligible]) {
                return;
            }
            hostedWindowPinchActive = YES;
            hostedWindowPinchStartedFloating = hostedWindowFloating;
            hostedWindowPinchBaseFrame =
                [keyboardZoomContainer convertRect:keyboardZoomContainer.bounds toView:self.view];
            break;
        }
        case UIGestureRecognizerStateChanged: {
            if (!hostedWindowPinchActive) {
                break;
            }
            CGFloat factor = recognizer.scale;
            if (!isfinite(factor) || factor <= 0) {
                break;
            }
            // 钉底形态下捏合(收缩)不进入悬浮,只有外扩才脱离钉底。
            if (!hostedWindowFloating && factor <= 1.0) {
                break;
            }
            CGRect base = hostedWindowPinchBaseFrame;
            CGRect candidate = CGRectMake(CGRectGetMidX(base) - CGRectGetWidth(base) * factor / 2.0,
                                          CGRectGetMidY(base) - CGRectGetHeight(base) * factor / 2.0,
                                          CGRectGetWidth(base) * factor,
                                          CGRectGetHeight(base) * factor);
            candidate = [self clampedHostedFloatingFrameForBounds:self.view.bounds frame:candidate];
            if (!hostedWindowFloating && !CGRectIsEmpty(splitPinnedCardFrame)) {
                // 刚脱离钉底时不允许直接缩得比钉底卡小太多。
                CGFloat minimumWidth = CGRectGetWidth(splitPinnedCardFrame) * 0.62;
                if (CGRectGetWidth(candidate) < minimumWidth) {
                    CGFloat aspect =
                        MAX(0.0001, CGRectGetHeight(candidate) / MAX(1.0, CGRectGetWidth(candidate)));
                    candidate = CGRectMake(CGRectGetMidX(candidate) - minimumWidth / 2.0,
                                           CGRectGetMidY(candidate) - minimumWidth * aspect / 2.0,
                                           minimumWidth, minimumWidth * aspect);
                    candidate = [self clampedHostedFloatingFrameForBounds:self.view.bounds
                                                                    frame:candidate];
                }
            }
            [self applyHostedFloatingWindowFrame:candidate animated:NO];
            break;
        }
        case UIGestureRecognizerStateEnded: {
            if (!hostedWindowPinchActive) {
                break;
            }
            hostedWindowPinchActive = NO;
            CGRect bounds = self.view.bounds;
            CGRect finalFrame =
                [keyboardZoomContainer convertRect:keyboardZoomContainer.bounds toView:self.view];
            CGFloat stretchedWidth = CGRectGetWidth(hostedWindowPinchBaseFrame) * recognizer.scale;
            CGFloat stretchedHeight = CGRectGetHeight(hostedWindowPinchBaseFrame) * recognizer.scale;
            CGFloat maxWidth = CGRectGetWidth(bounds);
            CGFloat maxHeight = CGRectGetHeight(bounds) -
                [self hostedFloatingTopInsetForBounds:bounds] -
                [self hostedFloatingBottomInsetForBounds:bounds];
            // 超限拉伸(预夹紧尺寸明显越过窗口上限)→ 全屏:走原生接管,
            // split session 与面板随接管流程收尾。
            BOOL overspreadToFullscreen = pinnedBundleId.length > 0 && maxHeight > 0 &&
                (stretchedWidth >= maxWidth * PO_HOSTED_FLOAT_TAKEOVER_OVERSPREAD_FACTOR ||
                 stretchedHeight >= maxHeight * PO_HOSTED_FLOAT_TAKEOVER_OVERSPREAD_FACTOR);
            if (overspreadToFullscreen) {
                [self playHostedWindowSnapHaptic];
                [self openApplicationExternallyFromQuickSwitch:pinnedBundleId];
                break;
            }
            BOOL grewEnough = recognizer.scale >= PO_HOSTED_FLOAT_ENTER_FACTOR;
            if (!hostedWindowPinchStartedFloating) {
                // 从钉底发起的手势:外拉落到默认"半屏"锚点,不够外拉回弹钉底。
                if (grewEnough) {
                    [self playHostedWindowSnapHaptic];
                    [self enterHostedFloatingWindowAnimated:YES];
                } else {
                    [self exitHostedFloatingWindowAnimated:YES];
                }
                break;
            }
            CGRect defaultFrame = [self hostedFloatingDefaultFrameForBounds:bounds];
            BOOL shrunkTowardSplit =
                CGRectGetWidth(finalFrame) <= CGRectGetWidth(defaultFrame) * PO_HOSTED_FLOAT_EXIT_FRACTION;
            if (shrunkTowardSplit) {
                // 悬浮中捏合到足够小 → 回分屏钉底。
                [self playHostedWindowSnapHaptic];
                [self exitHostedFloatingWindowAnimated:YES];
            } else {
                [self applyHostedFloatingWindowFrame:
                    [self clampedHostedFloatingFrameForBounds:bounds frame:finalFrame] animated:YES];
            }
            break;
        }
        case UIGestureRecognizerStateCancelled:
        case UIGestureRecognizerStateFailed: {
            if (hostedWindowPinchActive) {
                hostedWindowPinchActive = NO;
                if (hostedWindowFloating) {
                    [self exitHostedFloatingWindowAnimated:YES];
                } else {
                    [self applyLayoutPreservingHandlePosition:YES];
                }
            }
            break;
        }
        default:
            break;
    }
}

-(void)playHostedWindowSnapHaptic{
    UISelectionFeedbackGenerator *generator = [[UISelectionFeedbackGenerator alloc] init];
    [generator selectionChanged];
}

-(void)hostedWindowChromeDidTapClose:(POHostedWindowChromeView *)chromeView{
    if (hostedWindowPinchActive || panelState != POPanelStateOpen) {
        return;
    }
    // 与把手/Home 关闭同一条链路:收起面板并拆除 split session、释放托管 App。
    [self close];
}

-(void)hostedWindowChrome:(POHostedWindowChromeView *)chromeView
      didReceiveMovePan:(UIPanGestureRecognizer *)recognizer{
    if (!hostedWindowFloating || hostedWindowPinchActive) {
        return;
    }
    if (recognizer.state != UIGestureRecognizerStateChanged) {
        return;
    }
    CGPoint translation = [recognizer translationInView:self.view];
    if (translation.x == 0 && translation.y == 0) {
        return;
    }
    [recognizer setTranslation:CGPointZero inView:self.view];
    CGRect frame = hostedFloatingWindowFrame;
    frame.origin.x += translation.x;
    frame.origin.y += translation.y;
    [self applyHostedFloatingWindowFrame:
        [self clampedHostedFloatingFrameForBounds:self.view.bounds frame:frame] animated:NO];
}

-(void)applyLayoutPreservingHandlePosition:(BOOL)preserveHandlePosition{
    CGRect bounds = self.view.bounds;
    if (CGRectGetWidth(bounds) <= 0 || CGRectGetHeight(bounds) <= 0 || !self.handle) {
        return;
    }
    if (scaledProgrammaticCloseAnimating) {
        scaledProgrammaticCloseNeedsLayout = YES;
        return;
    }

    CGFloat previousMaximumOffset = [self maximumHandleOffset];
    CGFloat handleRatio = previousMaximumOffset > 0
        ? [self clampedHandleOffset:handleScrollView.contentOffset.y] / previousMaximumOffset
        : 0;
    CGFloat previousProgress = scrollView.contentSize.width > scrollView.bounds.size.width
        ? scrollView.contentOffset.x / (scrollView.contentSize.width - scrollView.bounds.size.width)
        : 0;
    BOOL preserveInteractiveOffset =
        scrollView.dragging || scrollView.decelerating || scrollSnapAnimationInProgress ||
        handlePanIntent != POHandlePanIntentNone;

    keyboardZoomGeneration += 1;
    [keyboardZoomContainer.layer removeAllAnimations];
    [handleScrollView.layer removeAllAnimations];
    [UIView performWithoutAnimation:^{
        self->keyboardZoomContainer.transform = CGAffineTransformIdentity;
        self->handleScrollView.transform = CGAffineTransformIdentity;
    }];
    keyboardZoomApplied = NO;
    appliedCardScale = 1.0;

    CGFloat portraitCanvasWidth = MIN(CGRectGetWidth(bounds), CGRectGetHeight(bounds));
    CGFloat portraitCanvasHeight = MAX(CGRectGetWidth(bounds), CGRectGetHeight(bounds));
    CGFloat handleRailWidth = [self handleRailWidth];
    chromeScale = (portraitCanvasWidth - handleRailWidth) / portraitCanvasWidth;
    BOOL shellIsLandscape = CGRectGetWidth(bounds) > CGRectGetHeight(bounds);
    UIInterfaceOrientation resolvedOrientation = [self contextManagerPreferredHostedInterfaceOrientation:nil];
    if (!POIsConcretePresentationOrientation(resolvedOrientation)) {
        resolvedOrientation = [self resolvedHostedLayoutOrientation];
    }
    if (!POIsConcretePresentationOrientation(resolvedOrientation)) {
        resolvedOrientation = UIInterfaceOrientationPortrait;
    }
    hostedLayoutOrientation = resolvedOrientation;
    BOOL portraitHostedLandscapeOptimization =
        [self isPortraitHostedLandscapeOptimizationActiveForOrientation:hostedLayoutOrientation];
    if (portraitHostedLandscapeOptimization &&
        self.handle.layoutMode == POHandleLayoutModeVerticalRail) {
        CGFloat currentHandleScreenY = [self currentHandleScreenY];
        if (isfinite(currentHandleScreenY)) {
            portraitHostedLandscapeHandleAnchorY = currentHandleScreenY;
        }
    } else if (!portraitHostedLandscapeOptimization) {
        portraitHostedLandscapeHandleAnchorY = NAN;
    }
    BOOL splitLayout = splitLayoutActive;
    CGSize logicalCanvas = [self contextManagerPreferredSceneStackSize:nil];
    CGFloat leadingInset = [self leadingSafeAreaInset] + CONTENT_EDGE_GAP;
    CGFloat trailingInset = [self trailingSafeAreaInset] + CONTENT_EDGE_GAP;
    CGFloat availableCardWidth;
    CGFloat availableCardHeight;
    if (splitLayout) {
        // 上下分屏:卡片全宽贴边,占据可用区域下半份;同朝向托管画布与卡片 1:1。
        availableCardWidth = CGRectGetWidth(bounds);
        availableCardHeight = [self splitLayoutBottomCardHeightForShellBounds:bounds];
    } else {
        availableCardWidth = portraitHostedLandscapeOptimization
            ? CGRectGetWidth(bounds) - leadingInset - trailingInset
            : CGRectGetWidth(bounds) - CONTENT_EDGE_GAP - self.handle.frame.size.width - HANDLE_EDGE_GAP - trailingInset;
        availableCardHeight = shellIsLandscape
            ? CGRectGetHeight(bounds) - (CONTENT_EDGE_GAP * 2)
            : portraitCanvasHeight * chromeScale;
    }
    availableCardWidth = MAX(1, availableCardWidth);
    availableCardHeight = MAX(1, availableCardHeight);

    CGFloat widthScale = availableCardWidth / MAX(1, logicalCanvas.width);
    CGFloat heightScale = availableCardHeight / MAX(1, logicalCanvas.height);
    scale = MIN(1.0, MIN(widthScale, heightScale));

    CGFloat screenScale = UIScreen.mainScreen.scale;
    contentLayoutWidth = round(logicalCanvas.width * scale * screenScale) / screenScale;
    CGFloat contentLayoutHeight = round(logicalCanvas.height * scale * screenScale) / screenScale;
    CGFloat anchoredCardBottomY = CGRectGetMidY(bounds);
    if (portraitHostedLandscapeOptimization) {
        CGFloat handleAnchorY = isfinite(portraitHostedLandscapeHandleAnchorY)
            ? portraitHostedLandscapeHandleAnchorY
            : CGRectGetMidY(bounds);
        anchoredCardBottomY = [self clampedPortraitHostedLandscapeCardBottomYForHandleAnchorY:handleAnchorY
                                                                                          cardHeight:contentLayoutHeight];
        portraitHostedLandscapeHandleAnchorY = anchoredCardBottomY + HANDLE_EDGE_GAP;
    }

    quickSwitchInteractionOverlayView.frame = bounds;
    [quickSwitchDragCoordinator layoutForBounds:bounds safeAreaInsets:self.view.safeAreaInsets];

    scrollView.frame = bounds;
    scrollView.contentSize = CGSizeMake(CGRectGetWidth(bounds) + contentLayoutWidth +
                                            (splitLayout ? 0 : trailingInset),
                                        CGRectGetHeight(bounds));
    CGFloat maximumContentOffsetX = [self maximumContentOffsetX];
    CGFloat restoredOffset = 0;
    if (preserveInteractiveOffset) {
        restoredOffset = MIN(MAX(0, previousProgress), 1) * maximumContentOffsetX;
    } else {
        restoredOffset = previousProgress >= 0.5 ? maximumContentOffsetX : 0;
    }
    if (fabs(scrollView.contentOffset.x - restoredOffset) > CLOSED_CONTENT_OFFSET_EPSILON ||
        fabs(scrollView.contentOffset.y) > CLOSED_CONTENT_OFFSET_EPSILON) {
        [scrollView setContentOffset:CGPointMake(restoredOffset, 0) animated:NO];
    }

    CGRect normalCardFrame = CGRectMake(CGRectGetWidth(bounds), 0, contentLayoutWidth, contentLayoutHeight);
    if (splitLayout) {
        // 分屏卡片贴屏幕下半区:滑入后卡片左缘正好落在屏幕 x=0。
        normalCardFrame.origin.x = contentLayoutWidth;
        UIEdgeInsets splitViewInsets = self.view.safeAreaInsets;
        UIEdgeInsets splitWindowInsets = self.view.window.safeAreaInsets;
        CGFloat splitBottomInset = MAX(splitViewInsets.bottom, splitWindowInsets.bottom) + CONTENT_EDGE_GAP;
        normalCardFrame.origin.y = CGRectGetHeight(bounds) - splitBottomInset - CGRectGetHeight(normalCardFrame);
    } else if (portraitHostedLandscapeOptimization) {
        normalCardFrame.origin.y = anchoredCardBottomY - CGRectGetHeight(normalCardFrame);
    } else {
        normalCardFrame.origin.y = CGRectGetMidY(bounds) - CGRectGetHeight(normalCardFrame) / 2.0;
    }
    normalCardFrame.origin.y = round(normalCardFrame.origin.y * screenScale) / screenScale;
    if (splitLayout) {
        splitPinnedCardFrame = normalCardFrame;
    }

    BOOL horizontalMode = portraitHostedLandscapeOptimization;
    self.handle.layoutMode = horizontalMode
        ? POHandleLayoutModeLandscapeFixedBottomLeft
        : POHandleLayoutModeVerticalRail;
    handleScrollView.scrollEnabled = !horizontalMode;
    handleScrollView.bounces = !horizontalMode;
    handleScrollView.alwaysBounceVertical = !horizontalMode;

    CGFloat handleViewportHeight = horizontalMode
        ? CGRectGetHeight(bounds)
        : CGRectGetHeight(bounds) * chromeScale;
    handleScrollView.frame = CGRectMake(CGRectGetWidth(bounds) - handleRailWidth, 0, handleRailWidth, handleViewportHeight);
    if (!horizontalMode) {
        handleScrollView.center = CGPointMake(handleScrollView.center.x, CGRectGetMidY(bounds));
        handleScrollView.contentSize = CGSizeMake(handleRailWidth, (handleViewportHeight * 2) - self.handle.frame.size.height);

        CGFloat targetHandleOffset = 0;
        if (preserveHandlePosition) {
            if (previousMaximumOffset <= 0) {
                NSNumber *storedRatio = [[NSUserDefaults standardUserDefaults] objectForKey:@"handlePointRatio"];
                CGFloat ratio = storedRatio ? storedRatio.doubleValue : 0.5;
                targetHandleOffset = ratio * [self maximumHandleOffset];
            } else {
                targetHandleOffset = handleRatio * [self maximumHandleOffset];
            }
        } else {
            NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
            NSNumber *storedRatio = [defaults objectForKey:@"handlePointRatio"];
            NSString *storedPoint = [defaults valueForKey:@"handlePoint"];
            if (storedRatio) {
                targetHandleOffset = storedRatio.doubleValue * [self maximumHandleOffset];
            } else if (storedPoint) {
                targetHandleOffset = CGPointFromString(storedPoint).y;
            } else {
                targetHandleOffset = [self maximumHandleOffset] / 2.0;
            }
        }
        [handleScrollView setContentOffset:CGPointMake(0, [self clampedHandleOffset:targetHandleOffset]) animated:NO];

        self.handle.restingOriginX = handleRailWidth - HANDLE_EDGE_GAP - self.handle.frame.size.width;
        CGRect handleLayoutFrame = self.handle.frame;
        handleLayoutFrame.origin.y = handleViewportHeight - CGRectGetHeight(self.handle.bounds);
        if (!self.handle.isNubbed) {
            handleLayoutFrame.origin.x = self.handle.restingOriginX;
        }
        self.handle.frame = handleLayoutFrame;
        quickSwitchHorizontalBarView.presentationAnchorFrame = CGRectZero;
    } else {
        handleScrollView.contentSize = handleScrollView.bounds.size;
        [handleScrollView setContentOffset:CGPointZero animated:NO];

        keyboardZoomBaseFrame = normalCardFrame;
        [self updatePortraitHostedLandscapeHandleForCurrentOffset];
        [scrollView bringSubviewToFront:handleScrollView];

        [self syncHorizontalQuickSwitchPresentationAnchor];
    }

    [self.handle refreshNubbedPositionAnimated:NO];
    [self storeHandlePosition];

    [UIView performWithoutAnimation:^{
        keyboardZoomContainer.transform = CGAffineTransformIdentity;
        handleScrollView.transform = CGAffineTransformIdentity;
        keyboardZoomContainer.frame = normalCardFrame;
        self->keyboardZoomBaseFrame = normalCardFrame;
        shadowView.frame = keyboardZoomContainer.bounds;
        self.contentView.frame = keyboardZoomContainer.bounds;
        shadowView.layer.shadowPath = [UIBezierPath bezierPathWithRoundedRect:shadowView.bounds
                                                                  cornerRadius:CONTENT_CORNER_RADIUS].CGPath;
    }];
    if (splitLayout) {
        // 分屏卡片全宽,把手一列提到卡片之上保持可点。
        [scrollView bringSubviewToFront:handleScrollView];
    }
    if (splitLayout && hostedWindowFloating && panelState == POPanelStateOpen &&
        !CGRectIsEmpty(hostedFloatingWindowFrame)) {
        // 悬浮形态:按当前 bounds 重新夹紧窗口 frame(旋转/安全区变化后仍保持比例)。
        [self applyHostedFloatingWindowFrame:
            [self clampedHostedFloatingFrameForBounds:bounds frame:hostedFloatingWindowFrame]
            animated:NO];
    } else {
        [self updateHostedWindowChrome];
    }
    CGFloat shadowProgress = MIN(MAX(scrollView.contentOffset.x / CONTENT_SHADOW_FADE_DISTANCE, 0), 1);
    shadowView.layer.shadowOpacity = CONTENT_SHADOW_OPACITY * shadowProgress;
    if (presentationSnapshotView) {
        [self layoutPresentationSnapshotView];
    }
    if (contextView) {
        [self layoutContextView];
    }
    if (showingCantHost) {
        [self layoutCantHostView];
    }
    lastLaidOutSize = bounds.size;
    [self updateInteractionBackdropsAnimated:NO];
    [self updateAppRailVisibilityAnimated:NO];
    if (appRailView && !appRailView.hidden) {
        [self positionAppRail];
    }
    [self reevaluateKeyboardZoomAnimated:NO];
    if (panelState == POPanelStateOpen &&
        self.quickSwitchTableView &&
        presentedQuickSwitchMenu == (UIView<POQuickSwitchMenuPresenting> *)self.quickSwitchTableView &&
        !self.quickSwitchTableView.hidden) {
        quickSwitchYieldActive = NO;
        [self applyQuickSwitchContentYieldIfNeededAnimated:NO];
    }

    if (scrollSnapAnimationInProgress && !scrollView.dragging && !scrollView.decelerating) {
        [self snapPanelToOpenState:pendingOpenState];
    }
}

-(void)dismissTransientInteractionUI{
    if (hostedCategoryTransitionPending || runtimeHostedCategoryTransitionAnimating || handleVisualHandoffSnapshotView) {
        [self cancelRuntimeHostedCategoryTransition];
    }
    if (handlePanIntent == POHandlePanIntentVerticalCardMove) {
        handlePanIntent = POHandlePanIntentNone;
        panelVerticalMoveStartAnchorY = 0;
    }
    if (presentedQuickSwitchMenu) {
        [self dismissPresentedQuickSwitchMenuImmediately];
        return;
    }
    [self restoreQuickSwitchContentYieldIfNeededAnimated:NO];
    quickSwitchInteractionOverlayView.hidden = YES;
    [quickSwitchDragCoordinator cancelAnimated:NO];
    [mirrorZoneView.layer removeAllAnimations];
    mirrorZoneView.transform = CGAffineTransformIdentity;
    mirrorZoneView.backgroundColor = [UIColor colorWithWhite:1 alpha:0.08];
    mirrorZoneView.alpha = 0;
    mirrorZoneHighlighted = NO;
    [self updateInteractionBackdropsAnimated:NO];
    [self updateAppRailVisibilityAnimated:NO];
    [scrollView bringSubviewToFront:keyboardZoomContainer];
    if (splitLayoutActive) {
        [scrollView bringSubviewToFront:handleScrollView];
    }
}

-(void)prepareForOrientationChange{
    if (!self.isViewLoaded) {
        return;
    }

    BOOL shouldBridgeIOS26Rotation =
        NSProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 26 &&
        panelState != POPanelStateClosed && panelState != POPanelStateClosing &&
        contextView && !contextView.hidden && contextView.superview == self.contentView &&
        presentationBundleId.length > 0 &&
        [presentationBundleId isEqualToString:hostSession.activeBundleId];
    if (shouldBridgeIOS26Rotation && !presentationSnapshotView) {
        [self capturePresentationSnapshotIfPossible];
    }
    if (shouldBridgeIOS26Rotation && presentationSnapshotView &&
        runtimeCategoryTransitionSnapshotFallbackArmed &&
        presentationSnapshotView.hidden && !runtimeCategoryTransitionSnapshotActive) {
        [self clearPresentationSnapshot];
        [self capturePresentationSnapshotIfPossible];
    }
    if (shouldBridgeIOS26Rotation && presentationSnapshotView &&
        !presentationSnapshotIsTargetPlaceholder) {
        [self prewarmRuntimeCategoryTransitionSnapshot];
    }
    if (shouldBridgeIOS26Rotation && presentationSnapshotView &&
        !presentationSnapshotIsTargetPlaceholder &&
        [presentationSnapshotBundleId isEqualToString:presentationBundleId]) {
        runtimeCategoryTransitionSnapshotFallbackArmed = YES;
        if (runtimeCategoryTransitionSnapshotActive) {
            presentationSnapshotView.userInteractionEnabled = NO;
            presentationSnapshotView.hidden = NO;
            [self layoutPresentationSnapshotView];
            [self.contentView bringSubviewToFront:presentationSnapshotView];
        }
    }

    keyboardZoomSuppressedForCurrentSession = NO;
    [self addKeyboardZoomSuspension:POKeyboardZoomSuspensionRotation];
    [self restoreKeyboardZoomImmediately];

    origOffset = nil;
    [self dismissTransientInteractionUI];
}

-(void)handleOrientationChange{
    if (!self.isViewLoaded) {
        return;
    }
    [self applyLayoutPreservingHandlePosition:YES];
    [self removeKeyboardZoomSuspension:POKeyboardZoomSuspensionRotation];
    [self reevaluateKeyboardZoomAnimated:NO];
}

-(CGSize)contextManagerPreferredSceneStackSize:(id)manager{
    CGRect bounds = self.view.bounds;
    CGFloat shortSide = MIN(CGRectGetWidth(bounds), CGRectGetHeight(bounds));
    CGFloat longSide = MAX(CGRectGetWidth(bounds), CGRectGetHeight(bounds));
    UIInterfaceOrientation orientation = [self contextManagerPreferredHostedInterfaceOrientation:manager];
    if ([self isSplitLayoutActiveOrPending]) {
        BOOL hostedIsLandscape = UIInterfaceOrientationIsLandscape(orientation);
        BOOL shellIsLandscape = CGRectGetWidth(bounds) > CGRectGetHeight(bounds);
        // 同朝向类别才做真实半屏画布;跨朝向托管维持全屏画布缩放。
        if (hostedIsLandscape == shellIsLandscape) {
            return CGSizeMake(CGRectGetWidth(bounds), [self splitLayoutBottomCardHeightForShellBounds:bounds]);
        }
    }
    return UIInterfaceOrientationIsLandscape(orientation)
        ? CGSizeMake(longSide, shortSide)
        : CGSizeMake(shortSide, longSide);
}

-(CGSize)hostSessionPreferredSystemSceneStackSize:(POHostSessionController *)__unused controller{
    UIWindowScene *scene = self.view.window.windowScene;
    CGRect bounds = scene ? scene.coordinateSpace.bounds : UIScreen.mainScreen.bounds;
    if (CGRectIsEmpty(bounds)) {
        bounds = UIScreen.mainScreen.bounds;
    }

    UIInterfaceOrientation orientation = [[ContextHostManager sharedInstance] currentSystemInterfaceOrientation];
    if (!POIsConcretePresentationOrientation(orientation) && scene) {
        orientation = scene.interfaceOrientation;
    }
    CGFloat shortSide = MIN(CGRectGetWidth(bounds), CGRectGetHeight(bounds));
    CGFloat longSide = MAX(CGRectGetWidth(bounds), CGRectGetHeight(bounds));
    return UIInterfaceOrientationIsLandscape(orientation)
        ? CGSizeMake(longSide, shortSide)
        : CGSizeMake(shortSide, longSide);
}

-(UIInterfaceOrientation)contextManagerPreferredHostedInterfaceOrientation:(id)manager{
    ContextHostManager *hostManager = [manager isKindOfClass:[ContextHostManager class]]
        ? (ContextHostManager *)manager
        : [ContextHostManager sharedInstance];

    NSString *requestedBundleId = hostSession.requestedBundleId;
    NSString *activeBundleId = hostSession.activeBundleId;
    BOOL committedQuickSwitchTargetPending = pinnedBundleId.length > 0 &&
        activeBundleId.length > 0 &&
        [requestedBundleId isEqualToString:activeBundleId] &&
        ![pinnedBundleId isEqualToString:activeBundleId];
    NSString *hostingBundleId = committedQuickSwitchTargetPending
        ? pinnedBundleId
        : (requestedBundleId.length > 0 ? requestedBundleId : pinnedBundleId);

    return [self resolvedHostedOrientationForBundleId:hostingBundleId manager:hostManager];
}

-(BOOL)shouldAutorotate
{
    return YES;
}

-(UIInterfaceOrientationMask)supportedInterfaceOrientations{
    return UIInterfaceOrientationMaskAll;
}

-(void)viewWillTransitionToSize:(CGSize)size withTransitionCoordinator:(id<UIViewControllerTransitionCoordinator>)coordinator{
    [super viewWillTransitionToSize:size withTransitionCoordinator:coordinator];
    [coordinator animateAlongsideTransition:nil completion:^(__unused id<UIViewControllerTransitionCoordinatorContext> context) {
        [self applyLayoutPreservingHandlePosition:YES];
    }];
}

-(void)keyboardWillShow:(NSNotification *)notification{
    [self updateKeyboardAnimationFromNotification:notification];
    if (panelState == POPanelStateOpen && hostSession.state == POHostSessionStateLive &&
        hostSession.currentGeneration != 0) {
        [[ContextHostManager sharedInstance]
            canonicalizeHostedSourceForCurrentOrientationWithGeneration:hostSession.currentGeneration];
    }
    if (keyboardNotificationState != POKeyboardNotificationStateVisible) {
        keyboardZoomSuppressedForCurrentSession = NO;
    }
    keyboardNotificationState = POKeyboardNotificationStateVisible;
    keyboardHideAnimationInFlight = NO;
    [self trackFloatingRailKeyboardFrameFromNotification:notification];
    [self avoidClosedHandleForKeyboardWillShow:notification];
    [self updateFloatingAppRailForKeyboardAnimated:YES];
    [self reevaluateCardScaleAnimated:YES source:POCardScaleTransitionSourceKeyboard];
}

-(void)keyboardWillChangeFrame:(NSNotification *)notification{
    [self updateKeyboardAnimationFromNotification:notification];
    if (keyboardHideAnimationInFlight) {
        return;
    }
    BOOL frameVisible = [self keyboardFrameIsVisibleInNotification:notification];
    if (keyboardNotificationState == POKeyboardNotificationStateVisible &&
        [self keyboardFrameHasNonzeroSizeInNotification:notification]) {
        frameVisible = YES;
    }
    keyboardNotificationState = frameVisible
        ? POKeyboardNotificationStateVisible
        : POKeyboardNotificationStateHidden;
    keyboardHideAnimationInFlight = keyboardNotificationState != POKeyboardNotificationStateVisible;
    [self trackFloatingRailKeyboardFrameFromNotification:notification];
    [self updateFloatingAppRailForKeyboardAnimated:YES];
    [self reevaluateCardScaleAnimated:YES source:POCardScaleTransitionSourceKeyboard];
}

-(void)keyboardWillHide:(NSNotification *)notification{
    [self updateKeyboardAnimationFromNotification:notification];
    keyboardNotificationState = POKeyboardNotificationStateHidden;
    keyboardHideAnimationInFlight = YES;
    [self reevaluateCardScaleAnimated:YES source:POCardScaleTransitionSourceKeyboard];
    if ([[POApplicationHelper settings][@"keyboardAvoiding"] boolValue] && origOffset) {
        [handleScrollView setContentOffset:CGPointMake(0, [self clampedHandleOffset:origOffset.floatValue]) animated:YES];
        origOffset = nil;
    }
    // 键盘收起:悬浮竖栏沿键盘动画落回屏幕中央。
    [self updateFloatingAppRailForKeyboardAnimated:YES];
}

-(void)keyboardDidShow:(NSNotification *)notification{
    [self updateKeyboardAnimationFromNotification:notification];
    keyboardNotificationState = POKeyboardNotificationStateVisible;
    keyboardHideAnimationInFlight = NO;
    [self trackFloatingRailKeyboardFrameFromNotification:notification];
    [self reevaluateCardScaleAnimated:NO source:POCardScaleTransitionSourceKeyboard];
}

-(void)keyboardDidChangeFrame:(NSNotification *)notification{
    [self updateKeyboardAnimationFromNotification:notification];
    if (keyboardHideAnimationInFlight) {
        return;
    }
    BOOL frameVisible = [self keyboardFrameIsVisibleInNotification:notification];
    if (keyboardNotificationState == POKeyboardNotificationStateVisible &&
        [self keyboardFrameHasNonzeroSizeInNotification:notification]) {
        frameVisible = YES;
    }
    keyboardNotificationState = frameVisible
        ? POKeyboardNotificationStateVisible
        : POKeyboardNotificationStateHidden;
    [self trackFloatingRailKeyboardFrameFromNotification:notification];
    [self reevaluateCardScaleAnimated:NO source:POCardScaleTransitionSourceKeyboard];
}

-(void)keyboardDidHide:(NSNotification *)notification{
    [self updateKeyboardAnimationFromNotification:notification];
    keyboardNotificationState = POKeyboardNotificationStateHidden;
    keyboardHideAnimationInFlight = NO;
    keyboardZoomSuppressedForCurrentSession = NO;
    [self reevaluateCardScaleAnimated:NO source:POCardScaleTransitionSourceKeyboard];
}

-(void)avoidClosedHandleForKeyboardWillShow:(NSNotification *)notification{
    if ([self isHorizontalQuickSwitchLayoutMode] ||
        ![[POApplicationHelper settings][@"keyboardAvoiding"] boolValue] || [self isPanelActive]) {
        return;
    }
    CGRect keyboardFrame = [[notification userInfo][UIKeyboardFrameEndUserInfoKey] CGRectValue];
    CGRect keyboardFrameInView = [self.view convertRect:keyboardFrame fromView:nil];
    CGRect handleInView = [handleScrollView convertRect:self.handle.frame toView:self.view];
    if (!CGRectIntersectsRect(handleInView, keyboardFrameInView)) {
        origOffset = nil;
        return;
    }
    CGFloat overlap = CGRectGetMaxY(handleInView) + HANDLE_EDGE_GAP - CGRectGetMinY(keyboardFrameInView);
    if (overlap > 0) {
        origOffset = @(handleScrollView.contentOffset.y);
        CGFloat adjustedOffset = [self clampedHandleOffset:handleScrollView.contentOffset.y + overlap];
        [handleScrollView setContentOffset:CGPointMake(0, adjustedOffset) animated:YES];
    } else {
        origOffset = nil;
    }
}


-(void)commitPinnedBundleId:(NSString *)bundleId{
    if (bundleId.length == 0 ||
        ![POApplicationHelper isUserFacingApplicationBundleId:bundleId]) {
        return;
    }
    pinnedBundleId = bundleId;
    [[NSUserDefaults standardUserDefaults] setObject:bundleId forKey:@"lastPinnedBundleId"];
    [self refreshHandleIconIfNeeded];
    if (appRailView && !appRailView.hidden) {
        [self layoutAppRail];
    }
}

-(void)restoreExternallyActivatedApplicationNatively:(NSString *)bundleId{
    if (bundleId.length == 0) {
        return;
    }
    externallyActivatedGeneration += 1;
    externallyActivatedBundleId = nil;
    [self prepareForNativeApplicationTakeover:bundleId];
    [[UIApplication sharedApplication] launchApplicationWithIdentifier:bundleId suspended:NO];
}

-(void)completeExternallyActivatedApplicationIfNeeded:(NSString *)bundleId{
    if (bundleId.length == 0 || ![externallyActivatedBundleId isEqualToString:bundleId]) {
        return;
    }
    externallyActivatedGeneration += 1;
    externallyActivatedBundleId = nil;
}

-(BOOL)openExternallyActivatedApplicationInPullOver:(NSString *)bundleId{
    if (!NSThread.isMainThread || bundleId.length == 0 ||
        ![POApplicationHelper isUserFacingApplicationBundleId:bundleId] ||
        panelState != POPanelStateClosed || [self isPanelTransitioning] ||
        presentedQuickSwitchMenu || scaledProgrammaticCloseAnimating) {
        return NO;
    }

    externallyActivatedGeneration += 1;
    NSUInteger activationGeneration = externallyActivatedGeneration;
    externallyActivatedBundleId = [bundleId copy];
    [self pinAppWithBundleId:bundleId];
    if (![pinnedBundleId isEqualToString:bundleId]) {
        externallyActivatedGeneration += 1;
        externallyActivatedBundleId = nil;
        return NO;
    }

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3.0 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        if (activationGeneration != self->externallyActivatedGeneration ||
            ![self->externallyActivatedBundleId isEqualToString:bundleId]) {
            return;
        }
        BOOL scenePublished = self->hostSession.state == POHostSessionStateLive &&
            [self->hostSession.activeBundleId isEqualToString:bundleId] &&
            [self->presentationBundleId isEqualToString:bundleId];
        if (scenePublished) {
            [self completeExternallyActivatedApplicationIfNeeded:bundleId];
            return;
        }
        [self restoreExternallyActivatedApplicationNatively:bundleId];
    });
    return YES;
}

-(void)pinAppWithBundleId:(NSString *)bundleId{
    if (bundleId.length == 0 ||
        ![POApplicationHelper isUserFacingApplicationBundleId:bundleId]) {
        return;
    }

    BOOL hasVisibleLivePresentation = contextView && !contextView.hidden &&
        contextView.superview == self.contentView && presentationBundleId.length > 0;
    BOOL switchingVisibleTarget = panelState == POPanelStateOpen && hasVisibleLivePresentation &&
        ![hostSession.activeBundleId isEqualToString:bundleId];
    UIInterfaceOrientation previousHostedOrientation =
        [self contextManagerPreferredHostedInterfaceOrientation:nil];
    if (switchingVisibleTarget) {
        [self capturePresentationSnapshotIfPossible];
    }

    [self commitPinnedBundleId:bundleId];

    UIInterfaceOrientation nextHostedOrientation =
        [self contextManagerPreferredHostedInterfaceOrientation:nil];
    if (UIInterfaceOrientationIsLandscape(previousHostedOrientation) !=
        UIInterfaceOrientationIsLandscape(nextHostedOrientation)) {
        [self applyLayoutPreservingHandlePosition:YES];
    }
    if (switchingVisibleTarget) {
        if (![self revealCachedPresentationSnapshotForBundleId:bundleId]) {
            [self showTargetTransitionPresentationForBundleId:bundleId];
        }
    }

    if (panelState == POPanelStateOpen) {
        [hostSession activateBundleId:bundleId];
        return;
    }

    [hostSession prepareBundleId:bundleId];
    NSUInteger openGeneration = ++deferredOpenGeneration;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.3 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        if (openGeneration == self->deferredOpenGeneration &&
            self->panelState == POPanelStateClosed &&
            [self->pinnedBundleId isEqualToString:bundleId]) {
            [self open];
        }
    });
}

-(void)open{
    if (pinnedBundleId.length == 0 || scaledProgrammaticCloseAnimating ||
        panelState == POPanelStateOpening || panelState == POPanelStateOpen) {
        return;
    }
    deferredOpenGeneration += 1;
    // 从悬浮网格进入小窗:立即收起常驻竖栏,否则竖栏会带着悬浮形态和放大
    // 瓦片一路"已显示"到面板打开完成,setAppRailShown 因状态未变只重定位
    // 不重载,大图标残留。收起后由 finishPanelSnapToOpenState 以边缘列形态
    // 重新唤出并按正常尺寸 reload。
    BOOL railWasNubRevealed = nubRevealRailActive;
    nubRevealRailActive = NO;
    if (railWasNubRevealed) {
        [self updateAppRailVisibilityAnimated:YES];
    }
    [self cancelAutoNubTimer];
    [self removeKeyboardZoomSuspension:POKeyboardZoomSuspensionClosing];
    // 每次打开都从分屏钉底形态起步,上次会话的悬浮 frame 不跨会话保留。
    [self resetHostedFloatingWindowState];
    BOOL splitLayout = [self beginSplitSessionIfNeeded];
    if (splitLayout != splitLayoutActive) {
        splitLayoutActive = splitLayout;
        [self applyLayoutPreservingHandlePosition:YES];
    }

    [self preparePanelForOpenPresentationIfNeeded];

    BOOL revealed = [self revealPresentationForBundleIdIfCompatible:pinnedBundleId];
    if (!revealed) {
        [self showTargetTransitionPresentationForBundleId:pinnedBundleId];
    }
    [hostSession activateBundleId:pinnedBundleId];
    [self snapPanelToOpenState:YES];
}

-(void)close{
    if (panelState == POPanelStateClosed || panelState == POPanelStateClosing) {
        return;
    }
    deferredOpenGeneration += 1;
    [self addKeyboardZoomSuspension:POKeyboardZoomSuspensionClosing];
    [self dismissPresentedQuickSwitchMenuImmediately];
    [self setAppRailShown:NO animated:YES];
    if ([self canUseDirectScaledProgrammaticCloseAnimation]) {
        [self performDirectScaledProgrammaticCloseAnimation];
    } else {
        [self snapPanelToOpenState:NO];
    }
}

// 外部 Darwin 通知唤醒:仅当把手处于缩点态时展开把手并唤出常驻竖栏;
// 其余状态(面板展开、把手正常显示)不做动作。守卫与竖栏展开复用点击缩点把手的那条路径。
-(void)applyExternalWakeRequest{
    if ([self isPanelTransitioning] || scrollView.dragging || scrollView.decelerating) {
        return;
    }
    if (panelState != POPanelStateClosed || ![self isHandleVisiblyNubbed]) {
        return;
    }
    [self cancelAutoNubTimer];
    self.handle.isNubbed = NO;
    nubRevealRailActive = [self railHasRecordedApps];
    [self resetAutoNubTimerWithMinimumDelay:PO_HANDLE_GUARD_MINIMUM_REVEAL_DURATION];
    [self updateAppRailVisibilityAnimated:YES];
}
     

#pragma mark - AppRail

// 小窗完全打开且无任何菜单/过渡时,把手一列展开为常驻应用竖栏;
// 小窗关闭时,点击隐藏把手唤出的常驻竖栏同样保持展开,直到再次隐藏把手或打开小窗。
-(BOOL)shouldShowAppRail{
    if (!appRailView ||
        presentedQuickSwitchMenu ||
        scrollSnapAnimationInProgress || scrollView.dragging || scrollView.decelerating ||
        scaledProgrammaticCloseAnimating ||
        hostedCategoryTransitionPending || runtimeHostedCategoryTransitionAnimating ||
        handleVisualHandoffSnapshotView ||
        showingCantHost) {
        return NO;
    }
    if (panelState == POPanelStateOpen) {
        return self.handle.layoutMode == POHandleLayoutModeVerticalRail;
    }
    if (panelState == POPanelStateClosed) {
        return nubRevealRailActive &&
            self.handle.layoutMode == POHandleLayoutModeVerticalRail &&
            !self.handle.isNubbed;
    }
    return NO;
}

-(void)updateAppRailVisibilityAnimated:(BOOL)animated{
    [self setAppRailShown:[self shouldShowAppRail] animated:animated];
}

-(void)setAppRailShown:(BOOL)shown animated:(BOOL)animated{
    if (!appRailView) {
        return;
    }
    BOOL isVisible = !appRailView.hidden && appRailView.alpha > 0.01;
    if (shown == isVisible) {
        if (shown) {
            [self positionAppRail];
        }
        return;
    }

    if (shown) {
        appRailView.hidden = NO;
        [self layoutAppRail];
        if (!handleVisualHandoffSnapshotView) {
            self.handle.alpha = 0;
        }
        CGRect targetFrame = appRailView.frame;
        CGRect handleFrame = [handleScrollView convertRect:self.handle.frame toView:self.view];
        CGFloat startScaleY = MIN(1.0, MAX(1.0, CGRectGetHeight(handleFrame)) / MAX(1.0, CGRectGetHeight(targetFrame)));
        appRailView.transform = CGAffineTransformMakeScale(1.0, startScaleY);
        appRailView.alpha = 0;
        void (^changes)(void) = ^{
            self->appRailView.transform = CGAffineTransformIdentity;
            self->appRailView.alpha = 1;
        };
        if (animated) {
            [UIView animateWithDuration:0.22
                                  delay:0
                                options:(UIViewAnimationOptionCurveEaseOut |
                                         UIViewAnimationOptionBeginFromCurrentState |
                                         UIViewAnimationOptionAllowUserInteraction)
                             animations:changes
                             completion:nil];
        } else {
            [UIView performWithoutAnimation:changes];
        }
        return;
    }

    if (!presentedQuickSwitchMenu && !handleVisualHandoffSnapshotView) {
        self.handle.alpha = 1;
    }
    if (isVisible) {
        void (^changes)(void) = ^{
            self->appRailView.alpha = 0;
        };
        void (^completion)(__unused BOOL finished) = ^(__unused BOOL finished) {
            // 菜单会话或栏内手势进行中时只淡出,不能 hidden,否则会取消驱动交互的触摸。
            if (!self->presentedQuickSwitchMenu && ![self->appRailView isInteracting]) {
                self->appRailView.hidden = YES;
            }
            self->appRailView.transform = CGAffineTransformIdentity;
        };
        if (animated) {
            [UIView animateWithDuration:0.15
                                  delay:0
                                options:(UIViewAnimationOptionCurveEaseOut |
                                         UIViewAnimationOptionBeginFromCurrentState |
                                         UIViewAnimationOptionAllowUserInteraction)
                             animations:changes
                             completion:completion];
        } else {
            [appRailView.layer removeAllAnimations];
            [UIView performWithoutAnimation:changes];
            completion(YES);
        }
    } else if (!appRailView.hidden && ![appRailView isInteracting] && !presentedQuickSwitchMenu) {
        appRailView.hidden = YES;
    }
}

// "把手展开居中"只在小窗展开时生效:缩点把手唤出的关闭态竖栏保持原排布,
// 点选 APP、小窗展开后才切换为第一个图标钉顶、其余图标下移屏幕中部的布局。
-(BOOL)railUsesCenteredIcons{
    return panelState == POPanelStateOpen &&
        [[POApplicationHelper settings][@"railExpandCentered"] boolValue];
}

// 缩点把手唤出的关闭态竖栏是否悬浮屏幕中央:与 railUsesCenteredIcons 互斥
// (后者仅小窗展开态),横屏快速切换布局维持把手边缘列的原排布。
-(BOOL)railFloatsCenteredInClosedState{
    return panelState == POPanelStateClosed && nubRevealRailActive &&
        self.handle.layoutMode == POHandleLayoutModeVerticalRail &&
        ![self isHorizontalQuickSwitchLayoutMode] &&
        [[POApplicationHelper settings][@"nubRailFloatCentered"] boolValue];
}

-(void)layoutAppRail{
    if (!appRailView) {
        return;
    }
    NSMutableOrderedSet<NSString *> *bundleIds =
        [NSMutableOrderedSet orderedSetWithArray:[POApplicationHelper quickSwitchBundleIdentifiers]];
    if (pinnedBundleId.length > 0 &&
        [POApplicationHelper isUserFacingApplicationBundleId:pinnedBundleId]) {
        [bundleIds removeObject:pinnedBundleId];
        [bundleIds insertObject:pinnedBundleId atIndex:0];
    }
    appRailView.centeredIcons = [self railUsesCenteredIcons];
    appRailView.horizontalLayout = [self railFloatsCenteredInClosedState];
    // 悬浮网格放大一倍图标尺寸,方便直接点按;其余形态维持把手原宽。
    CGFloat railTileSize = CGRectGetWidth(self.handle.frame);
    if ([self railFloatsCenteredInClosedState]) {
        railTileSize *= 2.0;
    }
    [appRailView reloadWithBundleIdentifiers:bundleIds.array
                              activeBundleId:pinnedBundleId
                                    tileSize:railTileSize];
    [self positionAppRail];
}

// 竖栏是否有可展示的图标,与 layoutAppRail 的列表口径保持一致。
-(BOOL)railHasRecordedApps{
    if ([POApplicationHelper quickSwitchBundleIdentifiers].count > 0) {
        return YES;
    }
    return pinnedBundleId.length > 0 &&
        [POApplicationHelper isUserFacingApplicationBundleId:pinnedBundleId];
}

-(void)positionAppRail{
    if (!appRailView || appRailView.hidden) {
        return;
    }
    CGRect handleFrame = [handleScrollView convertRect:self.handle.frame toView:self.view];
    if (CGRectIsEmpty(handleFrame) || !isfinite(CGRectGetMinX(handleFrame)) ||
        !isfinite(CGRectGetMinY(handleFrame))) {
        return;
    }
    CGFloat tileSize = CGRectGetWidth(self.handle.frame);
    // 形态切换(悬浮网格 ↔ 边缘列)可能不经过"隐藏再显示"循环,瓦片尺寸
    // 没跟上时强制整体重载,避免上一形态的放大图标残留。重载末尾会再次走到
    // 这里,尺寸一致后正常继续,不会递归。
    CGFloat expectedTileSize = [self railFloatsCenteredInClosedState] ? tileSize * 2.0 : tileSize;
    if (expectedTileSize > 0 && appRailView.tileSize != expectedTileSize) {
        [self layoutAppRail];
        return;
    }
    CGFloat margin = 10.0;
    CGFloat topLimit = self.view.safeAreaInsets.top + margin;
    CGFloat bottomLimit = CGRectGetHeight(self.view.bounds) - self.view.safeAreaInsets.bottom - margin;
    // 同步居中开关(小窗展开 && 设置开启)再定高度:小窗从关闭态展开的瞬间
    // 靠这里翻转 centeredIcons 并切换为全跨度 frame,竖栏顶部钳在 topLimit。
    BOOL centeredIcons = [self railUsesCenteredIcons];
    appRailView.centeredIcons = centeredIcons;
    BOOL floatsCentered = [self railFloatsCenteredInClosedState];
    appRailView.horizontalLayout = floatsCentered;
    if (floatsCentered) {
        [self positionAppRailFloatingCenteredWithTileSize:tileSize
                                                 topLimit:topLimit
                                              bottomLimit:bottomLimit];
        return;
    }
    CGFloat railHeight;
    if (centeredIcons) {
        // 把手展开居中:竖栏占满上下可用空间,顶部图标与中部图标组都相对屏幕定位,
        // 与 POAppRailView 里按可视区中点排图标配套。
        railHeight = MAX(0, bottomLimit - topLimit);
    } else {
        railHeight = MIN(appRailView.preferredContentSize.height, MAX(0, bottomLimit - topLimit));
    }
    railHeight = MAX(railHeight, tileSize);
    CGFloat railY = CGRectGetMidY(handleFrame) - railHeight / 2.0;
    railY = MIN(MAX(railY, topLimit), MAX(topLimit, bottomLimit - railHeight));
    appRailView.frame = CGRectMake(CGRectGetMinX(handleFrame), railY, tileSize, railHeight);
}

// 缩点唤出的悬浮竖栏:放大一倍的图标网格,水平居中、垂直在可用空间内居中;
// 图标超出一行时按宽度折成多排,放不下时竖向滚动(内部布局)。键盘可见且
// 自然落位会压到键盘时,把可用底界抬到键盘上缘上方再重新居中。键盘收起后由
// updateFloatingAppRailForKeyboard 带着键盘动画落回屏幕中央。
-(void)positionAppRailFloatingCenteredWithTileSize:(CGFloat)tileSize
                                          topLimit:(CGFloat)topLimit
                                       bottomLimit:(CGFloat)bottomLimit{
    // 网格瓦片是把手宽的两倍(layoutAppRail 放大传入),这里的最小尺寸同步用两倍值。
    CGFloat gridTileSize = tileSize * 2.0;
    CGFloat margin = 10.0;
    CGFloat maxWidth = MAX(0, CGRectGetWidth(self.view.bounds) - margin * 2.0);
    CGSize gridSize = [appRailView gridContentSizeForMaxWidth:maxWidth];
    CGFloat availableHeight = MAX(0, bottomLimit - topLimit);
    CGFloat railWidth = MAX(MIN(gridSize.width, maxWidth), gridTileSize);
    CGFloat railHeight = MIN(gridSize.height, MAX(availableHeight, gridTileSize));
    CGFloat railY = topLimit + MAX(0, (availableHeight - railHeight) / 2.0);
    if (keyboardNotificationState == POKeyboardNotificationStateVisible &&
        !CGRectIsEmpty(floatingRailKeyboardFrame)) {
        CGFloat keyboardGap = 10.0;
        CGFloat keyboardTopLimit = CGRectGetMinY(floatingRailKeyboardFrame) - keyboardGap;
        if (keyboardTopLimit >= topLimit && railY + railHeight > keyboardTopLimit) {
            CGFloat keyboardAvailableHeight = MAX(0, keyboardTopLimit - topLimit);
            railHeight = MIN(railHeight, MAX(keyboardAvailableHeight, gridTileSize));
            railY = topLimit + MAX(0, (keyboardAvailableHeight - railHeight) / 2.0);
        }
    }
    CGFloat railX = (CGRectGetWidth(self.view.bounds) - railWidth) / 2.0;
    appRailView.frame = CGRectMake(railX, railY, railWidth, railHeight);
}

// 键盘通知里的目标 frame 换算到控制器视图坐标,供悬浮竖栏避让使用;
// 不管竖栏当前是否可见都持续记录,缩点唤出瞬间才能直接落对位置。
-(void)trackFloatingRailKeyboardFrameFromNotification:(NSNotification *)notification{
    NSValue *frameValue = notification.userInfo[UIKeyboardFrameEndUserInfoKey];
    if (![frameValue isKindOfClass:[NSValue class]]) {
        return;
    }
    CGRect keyboardFrame = frameValue.CGRectValue;
    if (CGRectIsEmpty(keyboardFrame)) {
        return;
    }
    floatingRailKeyboardFrame = [self.view convertRect:keyboardFrame fromView:nil];
}

// 悬浮竖栏跟随键盘动画重排:仅悬浮态且竖栏可见时生效;动画时长/曲线用键盘
// 通知解析出的值,与宿主键盘的出入场保持同步。
-(void)updateFloatingAppRailForKeyboardAnimated:(BOOL)animated{
    if (!appRailView || appRailView.hidden || ![self railFloatsCenteredInClosedState]) {
        return;
    }
    if (animated && lastKeyboardAnimationDuration > 0) {
        [UIView animateWithDuration:lastKeyboardAnimationDuration
                              delay:0
                            options:lastKeyboardAnimationOptions
                         animations:^{
            [self positionAppRail];
        }
                         completion:nil];
    } else {
        [self positionAppRail];
    }
}

-(void)appRailView:(UIView *)railView didTapBundleId:(NSString *)bundleId{
    if (presentedQuickSwitchMenu || [self isPanelTransitioning] || scrollView.dragging ||
        scrollView.decelerating) {
        return;
    }
    [self cancelAutoNubTimer];
    if ([bundleId isEqualToString:pinnedBundleId]) {
        [self handle:self.handle didReceiveTap:nil];
        return;
    }
    // 悬浮网格点选后立即收起,不让网格悬在打开过渡上;面板就绪后竖栏以
    // 边缘列形态重新唤出并按正常尺寸重载。
    if ([self railFloatsCenteredInClosedState]) {
        nubRevealRailActive = NO;
        [self updateAppRailVisibilityAnimated:YES];
    }
    [self pinAppWithBundleId:bundleId];
}

-(void)appRailView:(UIView *)railView didReceivePan:(UIPanGestureRecognizer *)recognizer{
    if (presentedQuickSwitchMenu) {
        return;
    }
    [self handle:self.handle didPanPanel:recognizer];
}

-(void)appRailView:(UIView *)railView didReceiveLongPress:(UILongPressGestureRecognizer *)recognizer{
    // 小窗打开时长按菜单由这路长按手势全程驱动,菜单弹出后 Changed/Ended/Cancelled
    // 仍必须转发,否则菜单收不起来并挡住全部交互(表现为卡死);只需拦住重复的 Began,
    // 该情形由 canBeginQuickSwitchSession 兜底。
    if (recognizer.state == UIGestureRecognizerStateBegan && presentedQuickSwitchMenu) {
        return;
    }
    // 菜单锚点取被长按的图标瓦片:竖栏图标分居上下后,菜单要落在长按位置而不是把手处。
    [self presentQuickSwitchMenuFromAnchorView:
        [appRailView longPressAnchorViewForRecognizer:recognizer] recognizer:recognizer];
}

-(void)appRailViewDidTapSideSwitch:(UIView *)railView{
    // 长按/拖拽进行中不换边:换边会异步触发 layoutAppRail 重建图标,
    // 不能与驱动菜单或拖拽关闭的手势叠加;菜单会话期间遮罩本已拦住按钮,双保险。
    if (presentedQuickSwitchMenu || [self isPanelTransitioning] || scrollView.dragging ||
        scrollView.decelerating || [appRailView isInteracting]) {
        return;
    }
    [self cancelAutoNubTimer];
    // 复用镜像换边:翻转 leftHanded 并广播设置变更,窗口镜像动画后把手水平换边、竖直位置不变。
    [self commitMirrorSideSwitch];
}

#pragma mark - MHHandleDelegate

-(void)handle:(POHandle *)handle didReceiveTap:(UIGestureRecognizer *)recognizer{
    [self cancelAutoNubTimer];
    if (panelState == POPanelStateInteractive && !scrollSnapAnimationInProgress &&
        !scrollView.dragging && !scrollView.decelerating) {
        // 拖拽被打断后面板残留在 Interactive(被 isPanelTransitioning 挡住无法关闭):
        // 按当前位移落定开/关,保证把手点击始终有出路。
        BOOL mostlyOpen = scrollView.contentOffset.x >= [self maximumContentOffsetX] / 2.0;
        [self snapPanelToOpenState:mostlyOpen];
        return;
    }
    if ([self isPanelTransitioning] || scrollView.dragging || scrollView.decelerating) {
        return;
    }
    if (panelState == POPanelStateClosed) {
        if ([self isHandleVisiblyNubbed]) {
            // 点击隐藏的小把手:显示把手并展开全部记录 APP 的竖栏,不直接打开小窗;
            // 点选竖栏里的 APP 或拖拽把手才进入小窗,拖拽逻辑不变。
            self.handle.isNubbed = NO;
            nubRevealRailActive = [self railHasRecordedApps];
            [self resetAutoNubTimerWithMinimumDelay:PO_HANDLE_GUARD_MINIMUM_REVEAL_DURATION];
            [self updateAppRailVisibilityAnimated:YES];
            return;
        }
        nubRevealRailActive = NO;
        [self open];
        return;
    }
    if (panelState == POPanelStateOpen && [self shouldHandleTapRestoreKeyboardZoom]) {
        [self restoreKeyboardZoomFromHandleTap];
        [self resetAutoNubTimer];
        return;
    }
    if (panelState == POPanelStateOpen) {
        [self close];
    }
}

-(void)handle:(POHandle *)handle didPanPanel:(UIPanGestureRecognizer *)recognizer{
    if (recognizer.state == UIGestureRecognizerStateBegan) {
        handlePanIntent = POHandlePanIntentNone;
        handlePanStartedNubbed = self.handle.isNubbed;
        if ([self isPanelTransitioning]) {
            return;
        }

        CGPoint velocity = [recognizer velocityInView:self.view];
        BOOL verticalIntent = fabs(velocity.y) > fabs(velocity.x);
        if (verticalIntent) {
            if (![self canMovePortraitHostedLandscapeCardVertically]) {
                return;
            }
            CGFloat currentHandleY = [self currentHandleScreenY];
            if (!isfinite(currentHandleY)) {
                return;
            }
            handlePanIntent = POHandlePanIntentVerticalCardMove;
            portraitHostedLandscapeHandleAnchorY = currentHandleY;
            panelVerticalMoveStartAnchorY = currentHandleY;
            [self cancelAutoNubTimer];
            [self restoreKeyboardZoomImmediately];
            return;
        }

        handlePanIntent = [self horizontalHandlePanIntentForVelocityX:velocity.x];
        switch (handlePanIntent) {
            case POHandlePanIntentRevealHandle:
                [self cancelAutoNubTimer];
                self.handle.isNubbed = NO;
                return;

            case POHandlePanIntentNubHandle:
                [self cancelAutoNubTimer];
                self.handle.isNubbed = YES;
                nubRevealRailActive = NO;
                [self updateAppRailVisibilityAnimated:YES];
                return;

            case POHandlePanIntentOpenPanel:
                if ([self isHandleVisiblyNubbed]) {
                    self.handle.isNubbed = NO;
                }
                nubRevealRailActive = NO;
                pendingOpenState = NO;
                {
                    BOOL splitLayout = [self beginSplitSessionIfNeeded];
                    if (splitLayout != splitLayoutActive) {
                        splitLayoutActive = splitLayout;
                        [self applyLayoutPreservingHandlePosition:YES];
                    }
                }
                break;

            case POHandlePanIntentClosePanel:
                pendingOpenState = YES;
                break;

            case POHandlePanIntentNone:
            case POHandlePanIntentVerticalCardMove:
                return;
        }

        panelPanStartOffsetX = scrollView.contentOffset.x;
        [self scrollViewWillBeginDragging:scrollView];
        return;
    }

    if (recognizer.state == UIGestureRecognizerStateChanged) {
        if (handlePanIntent == POHandlePanIntentVerticalCardMove) {
            CGFloat translationY = [recognizer translationInView:self.view].y;
            [self applyPortraitHostedLandscapeVerticalHandleAnchorY:
                panelVerticalMoveStartAnchorY + translationY];
            return;
        }
        if (handlePanIntent != POHandlePanIntentOpenPanel &&
            handlePanIntent != POHandlePanIntentClosePanel) {
            return;
        }
        CGFloat translationX = [recognizer translationInView:self.view].x;
        CGFloat maximumOffset = [self maximumContentOffsetX];
        CGFloat nextOffset = MIN(MAX(0, panelPanStartOffsetX - translationX), maximumOffset);
        [scrollView setContentOffset:CGPointMake(nextOffset, 0) animated:NO];
        return;
    }

    if (recognizer.state == UIGestureRecognizerStateEnded ||
        recognizer.state == UIGestureRecognizerStateCancelled ||
        recognizer.state == UIGestureRecognizerStateFailed) {
        if (handlePanIntent == POHandlePanIntentVerticalCardMove) {
            CGFloat translationY = [recognizer translationInView:self.view].y;
            [self applyPortraitHostedLandscapeVerticalHandleAnchorY:
                panelVerticalMoveStartAnchorY + translationY];
            handlePanIntent = POHandlePanIntentNone;
            [self resetAutoNubTimer];
            return;
        }
        if (handlePanIntent == POHandlePanIntentRevealHandle) {
            BOOL cancelled = recognizer.state == UIGestureRecognizerStateCancelled ||
                recognizer.state == UIGestureRecognizerStateFailed;
            handlePanIntent = POHandlePanIntentNone;
            if (cancelled) {
                self.handle.isNubbed = handlePanStartedNubbed;
            } else {
                [self resetAutoNubTimerWithMinimumDelay:PO_HANDLE_GUARD_MINIMUM_REVEAL_DURATION];
            }
            return;
        }
        if (handlePanIntent == POHandlePanIntentNubHandle) {
            if (recognizer.state == UIGestureRecognizerStateCancelled ||
                recognizer.state == UIGestureRecognizerStateFailed) {
                self.handle.isNubbed = handlePanStartedNubbed;
            }
            handlePanIntent = POHandlePanIntentNone;
            return;
        }
        if (handlePanIntent != POHandlePanIntentOpenPanel &&
            handlePanIntent != POHandlePanIntentClosePanel) {
            handlePanIntent = POHandlePanIntentNone;
            return;
        }

        if (recognizer.state == UIGestureRecognizerStateCancelled ||
            recognizer.state == UIGestureRecognizerStateFailed) {
            pendingOpenState = handlePanIntent == POHandlePanIntentClosePanel;
        } else {
            CGFloat maximumOffset = [self maximumContentOffsetX];
            CGFloat velocityX = [recognizer velocityInView:self.view].x;
            if (fabs(velocityX) > 120) {
                pendingOpenState = velocityX < 0;
            } else {
                pendingOpenState = scrollView.contentOffset.x >= maximumOffset / 2.0;
            }
        }
        handlePanIntent = POHandlePanIntentNone;
        [self scrollViewDidEndDragging:scrollView willDecelerate:NO];
    }
}

-(void)handle:(POHandle *)handle didLongPress:(UILongPressGestureRecognizer *)recognizer{
    [self presentQuickSwitchMenuFromAnchorView:handle recognizer:recognizer];
}

// anchorView 决定快速切换菜单的呈现位置:把手长按传把手本身;竖栏长按传被按的
// 图标瓦片,菜单因此垂直落在长按位置,而不是隐藏把手所在的上方位置。
-(void)presentQuickSwitchMenuFromAnchorView:(UIView *)anchorView
                                 recognizer:(UILongPressGestureRecognizer *)recognizer{
    if (recognizer.state == UIGestureRecognizerStateBegan) {
        if (![self canBeginQuickSwitchSession]) {
            return;
        }

        POQuickSwitchLayoutMode candidateMode = [self currentQuickSwitchLayoutMode];
        POQuickSwitchLayoutMode selectedMode = (panelState == POPanelStateOpen)
            ? candidateMode
            : POQuickSwitchLayoutModeVerticalSide;
        [self cancelAutoNubTimer];

        if (selectedMode == POQuickSwitchLayoutModeVerticalSide && self.handle.isNubbed) {
            self.handle.isNubbed = NO;
        }

        UIView<POQuickSwitchMenuPresenting> *candidateMenu =
            [self quickSwitchMenuForLayoutMode:selectedMode];
        BOOL menuHandledGesture = [candidateMenu presentFromHandle:anchorView withRecognizer:recognizer];
        if (!menuHandledGesture && selectedMode == POQuickSwitchLayoutModeHorizontalBottom) {
            selectedMode = POQuickSwitchLayoutModeVerticalSide;
            if (self.handle.isNubbed) {
                self.handle.isNubbed = NO;
            }
            candidateMenu = [self quickSwitchMenuForLayoutMode:selectedMode];
            menuHandledGesture = [candidateMenu presentFromHandle:anchorView withRecognizer:recognizer];
        }
        if (!menuHandledGesture) {
            [self restoreQuickSwitchContentYieldIfNeededAnimated:NO];
            [scrollView bringSubviewToFront:keyboardZoomContainer];
            [quickSwitchDragCoordinator cancelAnimated:NO];
            [self resetAutoNubTimer];
        }
        return;
    }

    UIView<POQuickSwitchMenuPresenting> *presentingMenu = presentedQuickSwitchMenu;
    if (!presentingMenu) {
        return;
    }

    [presentingMenu presentFromHandle:anchorView withRecognizer:recognizer];
}


#pragma mark - QuickSwitch

-(void)cancelQuickSwitchPrewarm{
    quickSwitchPrewarmGeneration += 1;
    quickSwitchPrewarmBundleId = nil;
}

-(void)quickSwitchTableView:(UIView<POQuickSwitchMenuPresenting> *)quickSwitchTableView didHoverBundleId:(NSString *)bundleId{
    [self cancelQuickSwitchPrewarm];
    if (panelState != POPanelStateOpen || bundleId.length == 0 ||
        [bundleId isEqualToString:hostSession.activeBundleId] ||
        [[POApplicationHelper frontMostBundleId] isEqualToString:bundleId]) {
        return;
    }

    quickSwitchPrewarmBundleId = [bundleId copy];
    UIView<POQuickSwitchMenuPresenting> *presentingMenu = quickSwitchTableView;
    NSUInteger generation = quickSwitchPrewarmGeneration;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.08 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        if (generation != self->quickSwitchPrewarmGeneration ||
            ![self->quickSwitchPrewarmBundleId isEqualToString:bundleId] ||
            self->panelState != POPanelStateOpen || presentingMenu.alpha < 0.01 || presentingMenu.hidden) {
            return;
        }
        [self->hostSession prewarmBundleId:bundleId];
    });
}

-(void)quickSwitchTableViewDidClearHover:(UIView<POQuickSwitchMenuPresenting> *)quickSwitchTableView{
    [self cancelQuickSwitchPrewarm];
}

-(void)quickSwitchTableView:(UIView<POQuickSwitchMenuPresenting> *)quickSwitchTableView didSelectBundleId:(NSString *)bundleId{
    [self cancelQuickSwitchPrewarm];
    quickSwitchOpeningApp = YES;
    [self cancelAutoNubTimer];
    [self pinAppWithBundleId:bundleId];
}

-(void)syncHostedContentGeometryToContentView{
    if (contextView) {
        CGRect hostBounds = self.contentView.bounds;
        contextView.center = CGPointMake(CGRectGetMidX(hostBounds), CGRectGetMidY(hostBounds));
        for (UIView *v in contextView.subviews) {
            v.frame = contextView.bounds;
            v.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        }
    }
    if (showingCantHost && cantHostCanvas) {
        cantHostCanvas.center = CGPointMake(CGRectGetMidX(self.contentView.bounds),
                                            CGRectGetMidY(self.contentView.bounds));
    }
}

-(void)applyQuickSwitchContentYieldIfNeeded{
    [self applyQuickSwitchContentYieldIfNeededAnimated:YES];
}

-(void)applyQuickSwitchContentYieldIfNeededAnimated:(BOOL)animated{
    if (panelState != POPanelStateOpen || !self.quickSwitchTableView ||
        presentedQuickSwitchMenu != (UIView<POQuickSwitchMenuPresenting> *)self.quickSwitchTableView) {
        return;
    }

    CGRect menuInScroll = [self.quickSwitchTableView convertRect:self.quickSwitchTableView.bounds
                                                          toView:scrollView];
    CGRect baseContainerFrame = quickSwitchYieldActive ? quickSwitchSavedContainerFrame : keyboardZoomContainer.frame;

    CGRect containerFrame = baseContainerFrame;
    CGFloat gap = CONTENT_EDGE_GAP; // 5pt
    CGFloat menuMidX = CGRectGetMidX(menuInScroll);
    CGFloat contentMidX = CGRectGetMidX(containerFrame);
    BOOL menuIsLeftOfContent = menuMidX <= contentMidX;
    CGFloat deltaX = 0;

    if (menuIsLeftOfContent) {
        CGFloat desiredMinX = CGRectGetMaxX(menuInScroll) + gap;
        deltaX = desiredMinX - CGRectGetMinX(containerFrame);
    } else {
        CGFloat desiredMaxX = CGRectGetMinX(menuInScroll) - gap;
        deltaX = desiredMaxX - CGRectGetMaxX(containerFrame);
    }

    if (fabs(deltaX) <= 0.5) {
        if (quickSwitchYieldActive) {
            [self restoreQuickSwitchContentYieldIfNeededAnimated:animated];
        }
        return;
    }

    if (!quickSwitchYieldActive) {
        quickSwitchSavedContainerFrame = baseContainerFrame;
        quickSwitchYieldActive = YES;
    }

    containerFrame.origin.x += deltaX;
    CGFloat screenScale = UIScreen.mainScreen.scale;
    containerFrame.origin.x = round(containerFrame.origin.x * screenScale) / screenScale;

    void (^applyFrames)(void) = ^{
        self->keyboardZoomContainer.frame = containerFrame;
    };

    if (animated) {
        [UIView animateWithDuration:0.22
                              delay:0
                            options:(UIViewAnimationOptionCurveEaseOut | UIViewAnimationOptionBeginFromCurrentState)
                         animations:applyFrames
                         completion:nil];
    } else {
        applyFrames();
    }
}

-(void)restoreQuickSwitchContentYieldIfNeeded{
    [self restoreQuickSwitchContentYieldIfNeededAnimated:YES];
}

-(void)restoreQuickSwitchContentYieldIfNeededAnimated:(BOOL)animated{
    if (!quickSwitchYieldActive) {
        return;
    }
    quickSwitchYieldActive = NO;
    CGRect containerFrame = CGRectIsEmpty(keyboardZoomBaseFrame)
        ? quickSwitchSavedContainerFrame
        : keyboardZoomBaseFrame;

    void (^applyFrames)(void) = ^{
        self->keyboardZoomContainer.frame = containerFrame;
    };

    if (animated) {
        [UIView animateWithDuration:0.22
                              delay:0
                            options:(UIViewAnimationOptionCurveEaseOut | UIViewAnimationOptionBeginFromCurrentState)
                         animations:applyFrames
                         completion:nil];
    } else {
        [keyboardZoomContainer.layer removeAllAnimations];
        [UIView performWithoutAnimation:applyFrames];
    }
}

-(void)beginQuickSwitchSessionForMenu:(UIView<POQuickSwitchMenuPresenting> *)menu{
    if (!menu || presentedQuickSwitchMenu) {
        if (menu && presentedQuickSwitchMenu && menu != presentedQuickSwitchMenu) {
            [menu dismissImmediately];
        }
        return;
    }

    presentedQuickSwitchMenu = menu;
    [self setAppRailShown:NO animated:NO];
    [self cancelQuickSwitchPrewarm];
    [quickSwitchBackdropView.layer removeAllAnimations];
    quickSwitchBackdropView.alpha = 0;
    quickSwitchInteractionOverlayView.hidden = NO;
    [self.view bringSubviewToFront:quickSwitchInteractionOverlayView];
    [quickSwitchDragCoordinator cancelAnimated:NO];
    self.handle.alpha = 0;
    [self updateInteractionBackdropsAnimated:YES];

    if ([self isHorizontalQuickSwitchMenu:menu]) {
        [quickSwitchInteractionOverlayView bringSubviewToFront:quickSwitchHorizontalBarView];
        [self hideMirrorZone];
        return;
    }

    [scrollView bringSubviewToFront:handleScrollView];
    [handleScrollView insertSubview:self.handle belowSubview:self.quickSwitchTableView];
    [handleScrollView bringSubviewToFront:self.quickSwitchTableView];
    if (fabs([self resolvedCardScale] - 1.0) <= PO_CARD_SCALE_EPSILON) {
        [self applyQuickSwitchContentYieldIfNeededAnimated:YES];
    }
}

-(void)finishQuickSwitchSessionForMenu:(UIView<POQuickSwitchMenuPresenting> *)menu{
    if (!menu || menu != presentedQuickSwitchMenu) {
        return;
    }

    presentedQuickSwitchMenu = nil;
    [self cancelQuickSwitchPrewarm];
    [self restoreQuickSwitchContentYieldIfNeededAnimated:NO];
    [self hideQuickSwitchBackdropImmediately];
    quickSwitchInteractionOverlayView.hidden = YES;
    self.handle.alpha = 1;
    [self updateAppRailVisibilityAnimated:NO];
    [self updateInteractionBackdropsAnimated:NO];
    [self reconcileCardChromeZOrder];
    [self reevaluateKeyboardZoomAnimated:NO];
    [self hideMirrorZone];
    [quickSwitchDragCoordinator cancelAnimated:NO];
    if (quickSwitchOpeningApp) {
        if (panelState != POPanelStateClosed) {
            quickSwitchOpeningApp = NO;
            return;
        }
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            self->quickSwitchOpeningApp = NO;
            if (self->panelState == POPanelStateClosed) {
                [self resetAutoNubTimer];
            }
        });
        return;
    }
    [self resetAutoNubTimer];
}

-(void)dismissPresentedQuickSwitchMenuImmediately{
    if (!presentedQuickSwitchMenu) {
        return;
    }
    [presentedQuickSwitchMenu dismissImmediately];
}

-(void)hideQuickSwitchBackdropImmediately{
    if (!quickSwitchBackdropView) {
        return;
    }
    [quickSwitchBackdropView.layer removeAllAnimations];
    quickSwitchBackdropView.alpha = 0;
}

-(void)quickSwitchTableViewWillAppear:(UIView<POQuickSwitchMenuPresenting> *)quickSwitchTableView{
    [self beginQuickSwitchSessionForMenu:quickSwitchTableView];
}

-(void)quickSwitchTableView:(UIView<POQuickSwitchMenuPresenting> *)quickSwitchTableView draggingDidChangeForQuickSwitchItem:(SBApplication *)app withPoint:(CGPoint)point{
    [self cancelQuickSwitchPrewarm];
    BOOL startedDragging = !quickSwitchDragCoordinator.isDragging;
    [quickSwitchDragCoordinator beginDraggingBundleId:app.bundleIdentifier
                                           displayName:app.displayName
                                            sourceView:quickSwitchTableView
                                            sourcePoint:point];
    [quickSwitchDragCoordinator updateDraggingFromView:quickSwitchTableView atPoint:point];
    if ([self isHorizontalQuickSwitchMenu:quickSwitchTableView]) {
        mirrorZoneView.alpha = 0;
    } else {
        if (startedDragging) {
            [self showMirrorZoneForMenu:quickSwitchTableView];
        }
        [self setMirrorZoneHighlighted:[self mirrorZoneContainsPoint:point fromView:quickSwitchTableView]];
    }
}

-(void)quickSwitchTableView:(UIView<POQuickSwitchMenuPresenting> *)quickSwitchTableView didDropApp:(SBApplication *)app atPoint:(CGPoint)point{
    [self cancelQuickSwitchPrewarm];
    BOOL shouldOpenApp = [quickSwitchDragCoordinator finishDraggingFromView:quickSwitchTableView atPoint:point];
    BOOL shouldSwitchSide = !shouldOpenApp &&
        ![self isHorizontalQuickSwitchMenu:quickSwitchTableView] &&
        [self mirrorZoneContainsPoint:point fromView:quickSwitchTableView];
    quickSwitchOpeningApp = shouldOpenApp;
    if (shouldOpenApp) {
        [self cancelAutoNubTimer];
    }

    if (shouldSwitchSide) {
        mirrorZoneView.alpha = 0;
        [self commitMirrorSideSwitch];
        return;
    }

    [self hideMirrorZone];
    if (shouldOpenApp) {
        NSString *bundleId = [app.bundleIdentifier copy];
        dispatch_async(dispatch_get_main_queue(), ^{
            [self openApplicationExternallyFromQuickSwitch:bundleId];
        });
    }
}

-(void)routeExternalApplicationInsidePullOver:(NSString *)bundleId{
    if (bundleId.length == 0 || [bundleId isEqualToString:pinnedBundleId] ||
        ![POApplicationHelper isUserFacingApplicationBundleId:bundleId]) {
        return;
    }

    BOOL sourcePresentationVisible = contextView && !contextView.hidden &&
        contextView.superview == self.contentView &&
        [presentationBundleId isEqualToString:pinnedBundleId] &&
        [hostSession.activeBundleId isEqualToString:pinnedBundleId];
    if (!sourcePresentationVisible) {
        [self showTargetTransitionPresentationForBundleId:bundleId];
    }

    [hostSession activateBundleId:bundleId];
}

-(void)showCantHostAfterNativeTakeover{
    if (panelState == POPanelStateClosed) {
        return;
    }

    deferredOpenGeneration += 1;
    [self cancelAutoNubTimer];
    [self dismissTransientInteractionUI];
    splitLayoutActive = NO;
    [self resetHostedFloatingWindowState];
    scrollSnapAnimationInProgress = NO;
    [scrollView setContentOffset:CGPointMake([self maximumContentOffsetX], 0) animated:NO];
    panelState = POPanelStateOpen;
    [self applyLayoutPreservingHandlePosition:YES];
    [self hidePresentationContainer];
    shadowView.layer.shadowOpacity = 0;
    [hostSession releaseActiveSessionForExternalTakeoverPreservingPresentation];
    [[POSplitSessionController sharedInstance] end];
    [self cleanUpSubviews];
    presentationBundleId = nil;
    presentationSceneIdentity = nil;
    presentationCanvasSize = CGSizeZero;
    presentationOrientation = UIInterfaceOrientationUnknown;
    presentationSourceCanvasSize = CGSizeZero;
    presentationSourceOrientation = UIInterfaceOrientationUnknown;
    presentationRetainedAfterRelease = NO;
    keyboardZoomContainer.hidden = NO;
    keyboardZoomSuspensionReasons = POKeyboardZoomSuspensionNone;
    [self restoreKeyboardZoomImmediately];
    [self showCantHostView];
    [self updateInteractionBackdropsAnimated:NO];
    [self updateAppRailVisibilityAnimated:NO];
}

-(void)prepareForNativeApplicationTakeover:(NSString *)bundleId{
    if (bundleId.length == 0) {
        return;
    }

    NSString *activeHostedBundleId = [ContextHostManager activeHostedBundleId];
    BOOL targetIsCurrentHostedApp = activeHostedBundleId.length > 0 &&
        [activeHostedBundleId isEqualToString:bundleId];

    deferredOpenGeneration += 1;
    splitLayoutActive = NO;
    [self resetHostedFloatingWindowState];
    [[POSplitSessionController sharedInstance] end];
    [self cancelQuickSwitchPrewarm];

    if (targetIsCurrentHostedApp && panelState != POPanelStateClosed) {
        [self showCantHostAfterNativeTakeover];
        return;
    }

    BOOL panelHasVisibleTransaction = panelState != POPanelStateClosed;
    if (panelHasVisibleTransaction) {
        [self cancelAutoNubTimer];
        [self addKeyboardZoomSuspension:POKeyboardZoomSuspensionClosing];
        [self restoreQuickSwitchContentYieldIfNeededAnimated:NO];

        mirrorZoneView.alpha = 0;
        [quickSwitchDragCoordinator cancelAnimated:NO];

        if (panelState != POPanelStateClosing) {
            [self snapPanelToOpenState:NO];
            [self capturePresentationSnapshotIfPossible];
        }
        [self hidePresentationContainer];
        shadowView.layer.shadowOpacity = 0;
        [self retainPresentationAfterReleaseIfPossible];
    }

    if (activeHostedBundleId.length == 0) {
        return;
    }

    if (targetIsCurrentHostedApp) {
        [hostSession releaseActiveSessionForExternalTakeoverPreservingPresentation];
    } else {
        [hostSession releaseActiveSessionPreservingPresentation];
    }
}

-(void)openApplicationExternallyFromQuickSwitch:(NSString *)bundleId{
    if (bundleId.length == 0) {
        quickSwitchOpeningApp = NO;
        return;
    }

    [self prepareForNativeApplicationTakeover:bundleId];
    [[UIApplication sharedApplication] launchApplicationWithIdentifier:bundleId suspended:NO];
}

-(void)draggingDidEnterBoundsOfQuickSwitchTableView:(UIView<POQuickSwitchMenuPresenting> *)quickSwitchTableView{
    [quickSwitchDragCoordinator cancelAnimated:YES];
    [self hideMirrorZone];
}

#pragma mark - 镜像投放区（拖拽切换停靠side）

-(CGRect)mirrorZoneFrameForMenu:(UIView *)menu{
    CGRect menuInOverlay = [quickSwitchInteractionOverlayView convertRect:menu.bounds fromView:menu];
    CGFloat overlayWidth = CGRectGetWidth(quickSwitchInteractionOverlayView.bounds);
    CGFloat mirroredX = overlayWidth - CGRectGetMaxX(menuInOverlay);
    return CGRectMake(mirroredX, CGRectGetMinY(menuInOverlay),
                     CGRectGetWidth(menuInOverlay), CGRectGetHeight(menuInOverlay));
}

-(void)showMirrorZoneForMenu:(UIView *)menu{
    if ([self isHorizontalQuickSwitchMenu:(UIView<POQuickSwitchMenuPresenting> *)menu]) {
        mirrorZoneView.alpha = 0;
        mirrorZoneHighlighted = NO;
        return;
    }
    [mirrorZoneView.layer removeAllAnimations];
    mirrorZoneView.transform = CGAffineTransformIdentity;
    mirrorZoneView.frame = [self mirrorZoneFrameForMenu:menu];
    CGFloat cornerRadius = POQuickSwitchMenuCornerRadius;
    mirrorZoneView.layer.cornerRadius = cornerRadius;
    mirrorZoneBorder.frame = mirrorZoneView.bounds;
    mirrorZoneBorder.path = [UIBezierPath bezierPathWithRoundedRect:mirrorZoneView.bounds
                                                       cornerRadius:cornerRadius].CGPath;
    mirrorZoneIconView.center = CGPointMake(CGRectGetWidth(mirrorZoneView.bounds) / 2.0,
                                            CGRectGetHeight(mirrorZoneView.bounds) / 2.0);
    mirrorZoneHighlighted = NO;
    mirrorZoneView.backgroundColor = [UIColor colorWithWhite:1 alpha:0.08];
    mirrorZoneView.alpha = 0;
    [UIView animateWithDuration:0.18
                          delay:0
                        options:(UIViewAnimationOptionCurveEaseOut | UIViewAnimationOptionBeginFromCurrentState)
                     animations:^{
        self->mirrorZoneView.alpha = 1;
    } completion:nil];
}

-(void)hideMirrorZone{
    [mirrorZoneView.layer removeAllAnimations];
    mirrorZoneView.alpha = 0;
    mirrorZoneView.transform = CGAffineTransformIdentity;
    mirrorZoneView.backgroundColor = [UIColor colorWithWhite:1 alpha:0.08];
    mirrorZoneHighlighted = NO;
}

-(void)setMirrorZoneHighlighted:(BOOL)highlighted{
    if (mirrorZoneHighlighted == highlighted) return;
    mirrorZoneHighlighted = highlighted;
    [UIView animateWithDuration:0.16
                          delay:0
                        options:(UIViewAnimationOptionCurveEaseOut | UIViewAnimationOptionBeginFromCurrentState)
                     animations:^{
        self->mirrorZoneView.backgroundColor = [UIColor colorWithWhite:1 alpha:highlighted ? 0.22 : 0.08];
        self->mirrorZoneView.transform = highlighted ? CGAffineTransformMakeScale(1.12, 1.05)
                                               : CGAffineTransformIdentity;
    } completion:nil];
}

-(BOOL)mirrorZoneContainsPoint:(CGPoint)point fromView:(UIView *)view{
    if (view == quickSwitchHorizontalBarView || presentedQuickSwitchMenu == quickSwitchHorizontalBarView) {
        return NO;
    }
    CGPoint local = [mirrorZoneView convertPoint:point fromView:view];
    return CGRectContainsPoint(mirrorZoneView.bounds, local);
}

-(void)commitMirrorSideSwitch{
    if (presentedQuickSwitchMenu == quickSwitchHorizontalBarView) {
        return;
    }
    NSUserDefaults *defaults = [POApplicationHelper settingsDefaults];
    BOOL leftHanded = [defaults boolForKey:@"leftHanded"];
    [defaults setBool:!leftHanded forKey:@"leftHanded"];
    CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
                                         CFSTR("com.mlgm.pulloverx.settings-changed"),
                                         NULL, NULL, YES);
}

-(void)quickSwitchTableViewDidDisappear:(UIView<POQuickSwitchMenuPresenting> *)quickSwitchTableView{
    [self finishQuickSwitchSessionForMenu:quickSwitchTableView];
}



#pragma mark - UIScrollViewDelegate

-(void)scrollViewWillEndDragging:(UIScrollView *)sv
                     withVelocity:(CGPoint)velocity
              targetContentOffset:(inout CGPoint *)targetContentOffset{
    if (sv != scrollView) {
        return;
    }

    CGFloat maximumOffset = [self maximumContentOffsetX];
    if (maximumOffset <= 0) {
        targetContentOffset->x = 0;
        targetContentOffset->y = 0;
        return;
    }

    CGFloat projectedOffset = MIN(MAX(0, targetContentOffset->x), maximumOffset);
    BOOL shouldOpen = velocity.x > 0.15 ||
        (velocity.x >= -0.15 && projectedOffset >= maximumOffset / 2.0);
    pendingOpenState = shouldOpen;
    targetContentOffset->x = sv.contentOffset.x;
    targetContentOffset->y = 0;
}

-(void)scrollViewWillBeginDragging:(UIScrollView *)sv{
    if (sv == scrollView || sv == handleScrollView) {
        [self cancelAutoNubTimer];
    }
    if (sv == scrollView) {
        BOOL startedClosed = panelState == POPanelStateClosed &&
            fabs(scrollView.contentOffset.x) <= CLOSED_CONTENT_OFFSET_EPSILON;
        BOOL interruptedClosing = panelState == POPanelStateClosing;
        interactiveHostIntentIssued = !startedClosed;
        interactiveHostResumeRequired = interruptedClosing;
        [self setAppRailShown:NO animated:YES];
        POQuickSwitchLayoutMode previousLayoutMode = [self currentQuickSwitchLayoutMode];
        UIView *handleHandoffSnapshot = nil;
        if (startedClosed &&
            [self shouldUsePortraitHostedLandscapeOptimizationForOrientation:
                [self resolvedHostedLayoutOrientation]]) {
            handleHandoffSnapshot = [self beginHandleVisualHandoffSnapshot];
        }
        panelState = POPanelStateInteractive;
        if (previousLayoutMode != [self currentQuickSwitchLayoutMode]) {
            [self applyLayoutPreservingHandlePosition:YES];
        }
        if (handleHandoffSnapshot) {
            [self completeHandleVisualHandoffFromSnapshot:handleHandoffSnapshot];
        }
        [self addKeyboardZoomSuspension:POKeyboardZoomSuspensionDragging];
        [self restoreKeyboardZoomImmediately];
        scrollSnapAnimationInProgress = NO;
    }
}

-(void)scrollViewDidEndDragging:(UIScrollView *)sv willDecelerate:(BOOL)decelerate{
    if (sv == handleScrollView) {
        [self storeHandlePosition];
        [self resetAutoNubTimer];
        return;
    }
    if (sv != scrollView) {
        return;
    }
    (void)decelerate;
    if (pendingOpenState) {
        if (interactiveHostResumeRequired) {
            interactiveHostIntentIssued = NO;
        }
        [self issueInteractiveHostIntentIfNeeded];
    }
    interactiveHostResumeRequired = NO;
    [self snapPanelToOpenState:pendingOpenState];
    [self scheduleFinishPanelDragZoomIfIdle];
}

-(void)scrollViewDidEndDecelerating:(UIScrollView *)sv{
    if (sv != scrollView) {
        return;
    }
    if (!pendingOpenState && [self isPanelFullyClosedAndIdle]) {
        [self storeHandlePosition];
        [self resetAutoNubTimer];
    }
    [self scheduleFinishPanelDragZoomIfIdle];
}

-(void)scrollViewDidEndScrollingAnimation:(UIScrollView *)sv{
    if (sv != scrollView) {
        return;
    }
    if (!scrollSnapAnimationInProgress) {
        [self scheduleFinishPanelDragZoomIfIdle];
        return;
    }

    CGFloat targetOffset = pendingOpenState ? [self maximumContentOffsetX] : 0;
    if (fabs(scrollView.contentOffset.x - targetOffset) <= CLOSED_CONTENT_OFFSET_EPSILON &&
        fabs(scrollView.contentOffset.y) <= CLOSED_CONTENT_OFFSET_EPSILON) {
        [self finishPanelSnapToOpenState:pendingOpenState];
        return;
    }

    [self snapPanelToOpenState:pendingOpenState];
}

-(void)scrollViewDidScroll:(UIScrollView *)sv{
    if (sv == scrollView) {
        [self updatePortraitHostedLandscapeHandleForCurrentOffset];
        [self updateInteractionBackdropsAnimated:NO];

        CGFloat shadowProgress = MIN(MAX(sv.contentOffset.x / CONTENT_SHADOW_FADE_DISTANCE, 0), 1);
        shadowView.layer.shadowOpacity = CONTENT_SHADOW_OPACITY * shadowProgress;

        CGFloat rawOffsetX = sv.contentOffset.x;
        if (panelState == POPanelStateClosing && !scaledProgrammaticCloseAnimating &&
            !scrollView.dragging && !scrollView.decelerating &&
            fabs(rawOffsetX) <= CLOSED_CONTENT_OFFSET_EPSILON &&
            fabs(sv.contentOffset.y) <= CLOSED_CONTENT_OFFSET_EPSILON) {
            [self finishPanelSnapToOpenState:NO];
            return;
        }
        if (panelState == POPanelStateInteractive && !interactiveHostIntentIssued && rawOffsetX > 0.5) {
            [self issueInteractiveHostIntentIfNeeded];
        }
    }
}

-(void)cancelAutoNubTimer{
    [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(autoNubAfterDelay) object:nil];
}

-(void)resetAutoNubTimer{
    [self resetAutoNubTimerWithMinimumDelay:0];
}

-(void)resetAutoNubTimerWithMinimumDelay:(NSTimeInterval)minimumDelay{
    [self cancelAutoNubTimer];
    if ([self isHorizontalQuickSwitchLayoutMode] ||
        ![[POApplicationHelper settings][@"autoNub"] boolValue] || [self isPanelActive] || self.handle.isNubbed) {
        return;
    }

    NSTimeInterval configuredDelay = MAX(0, [[POApplicationHelper settings][@"autoNub-time"] doubleValue]);
    NSTimeInterval delay = MAX(configuredDelay, minimumDelay);
    [self performSelector:@selector(autoNubAfterDelay) withObject:nil afterDelay:delay];
}

-(void)autoNubAfterDelay{
    if (![self isHorizontalQuickSwitchLayoutMode] &&
        [[POApplicationHelper settings][@"autoNub"] boolValue] && ![self isPanelActive] && !self.handle.isNubbed) {
        [self.handle setIsNubbed:YES];
        // 自动隐藏把手时,点击隐藏把手唤出的常驻竖栏一并收起。
        nubRevealRailActive = NO;
        [self updateAppRailVisibilityAnimated:YES];
    }
}


-(void)layoutExternalSceneStack{
    if (!externalSceneStack || externalSceneStack.superview != self.contentView) {
        return;
    }

    UIInterfaceOrientation targetOrientation = [self resolvedHostedLayoutOrientation];
    CGSize sourceCanvas = hostedKeyboardLayerPresent
        ? externalSceneStack.bounds.size
        : [self hostSessionPreferredSystemSceneStackSize:hostSession];
    if (sourceCanvas.width <= 0 || sourceCanvas.height <= 0) {
        sourceCanvas = externalSceneStack.bounds.size;
    }
    if (sourceCanvas.width <= 0 || sourceCanvas.height <= 0) {
        return;
    }

    UIInterfaceOrientation sourceOrientation = targetOrientation;
    if (!hostedKeyboardLayerPresent) {
        sourceOrientation = [[ContextHostManager sharedInstance] currentSystemInterfaceOrientation];
        if (!POIsConcretePresentationOrientation(sourceOrientation)) {
            sourceOrientation = self.view.window.windowScene.interfaceOrientation;
        }
        if (!POIsConcretePresentationOrientation(sourceOrientation)) {
            sourceOrientation = sourceCanvas.width > sourceCanvas.height
                ? UIInterfaceOrientationLandscapeLeft
                : UIInterfaceOrientationPortrait;
        }
    }
    if (!POIsConcretePresentationOrientation(targetOrientation)) {
        targetOrientation = sourceOrientation;
    }
    BOOL crossCategory = UIInterfaceOrientationIsLandscape(sourceOrientation) !=
        UIInterfaceOrientationIsLandscape(targetOrientation);
    CGSize displayedSourceSize = crossCategory
        ? CGSizeMake(sourceCanvas.height, sourceCanvas.width)
        : sourceCanvas;
    CGFloat targetScale = MIN(CGRectGetWidth(self.contentView.bounds) / MAX(1, displayedSourceSize.width),
                              CGRectGetHeight(self.contentView.bounds) / MAX(1, displayedSourceSize.height));
    CGFloat rotationAngle = POPresentationAngleForOrientation(targetOrientation) -
        POPresentationAngleForOrientation(sourceOrientation);
    CGAffineTransform transform = CGAffineTransformMakeRotation(rotationAngle);
    transform = CGAffineTransformScale(transform, targetScale, targetScale);
    if ([[POApplicationHelper settings][@"leftHanded"] boolValue]) {
        transform = CGAffineTransformConcat(transform, CGAffineTransformMakeScale(-1.0, 1.0));
    }

    [UIView performWithoutAnimation:^{
        externalSceneStack.transform = CGAffineTransformIdentity;
        externalSceneStack.bounds = (CGRect){CGPointZero, sourceCanvas};
        externalSceneStack.center = CGPointMake(CGRectGetMidX(self.contentView.bounds),
                                                CGRectGetMidY(self.contentView.bounds));
        externalSceneStack.transform = transform;
    }];
}

-(void)layoutContextView{
    if (!contextView) {
        return;
    }

    BOOL wasAlreadyAttached = contextView.superview == self.contentView;
    if (!wasAlreadyAttached) {
        [self.contentView addSubview:contextView];
    }

    CGSize logicalCanvas = [self contextManagerPreferredSceneStackSize:nil];
    UIInterfaceOrientation targetOrientation = [self resolvedHostedLayoutOrientation];

    CGSize sourceCanvas = presentationSourceCanvasSize;
    if (sourceCanvas.width <= 0 || sourceCanvas.height <= 0) {
        sourceCanvas = contextView.bounds.size;
    }
    if (sourceCanvas.width <= 0 || sourceCanvas.height <= 0) {
        sourceCanvas = logicalCanvas;
    }
    UIInterfaceOrientation sourceOrientation = POIsConcretePresentationOrientation(presentationSourceOrientation)
        ? presentationSourceOrientation
        : targetOrientation;

    BOOL sourceAndTargetCategoriesDiffer =
        POIsConcretePresentationOrientation(sourceOrientation) &&
        POIsConcretePresentationOrientation(targetOrientation) &&
        UIInterfaceOrientationIsLandscape(sourceOrientation) != UIInterfaceOrientationIsLandscape(targetOrientation);
    CGSize displayedSourceSize = sourceAndTargetCategoriesDiffer
        ? CGSizeMake(sourceCanvas.height, sourceCanvas.width)
        : sourceCanvas;
    CGFloat hostScale = MIN(CGRectGetWidth(self.contentView.bounds) / MAX(1, displayedSourceSize.width),
                            CGRectGetHeight(self.contentView.bounds) / MAX(1, displayedSourceSize.height));

    CGFloat rotationAngle = 0;
    if (POIsConcretePresentationOrientation(sourceOrientation) &&
        POIsConcretePresentationOrientation(targetOrientation)) {
        rotationAngle = POPresentationAngleForOrientation(targetOrientation) -
            POPresentationAngleForOrientation(sourceOrientation);
    }
    CGAffineTransform transform = CGAffineTransformMakeRotation(rotationAngle);
    transform = CGAffineTransformScale(transform, hostScale, hostScale);
    if ([[POApplicationHelper settings][@"leftHanded"] boolValue]) {
        transform = CGAffineTransformConcat(transform, CGAffineTransformMakeScale(-1.0, 1.0));
    }
    [UIView performWithoutAnimation:^{
        contextView.transform = CGAffineTransformIdentity;
        contextView.bounds = (CGRect){CGPointZero, sourceCanvas};
        contextView.center = CGPointMake(CGRectGetMidX(self.contentView.bounds),
                                         CGRectGetMidY(self.contentView.bounds));
        contextView.transform = transform;
    }];

    for (UIView *v in contextView.subviews) {
        v.frame = contextView.bounds;
        v.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    }
    [self layoutExternalSceneStack];

    if (wasAlreadyAttached) {
        self->contextView.alpha = 1;
    } else {
        [UIView animateWithDuration:0.3 animations:^{
            self->contextView.alpha = 1;
        }];
    }

    if (NSProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 26 &&
        presentationSnapshotView && !presentationSnapshotIsTargetPlaceholder) {
        [self layoutPresentationSnapshotView];
    }
}

-(void)cleanUpSubviews{
    keyboardNotificationState = POKeyboardNotificationStateUnknown;
    hostedKeyboardLayerPresent = NO;
    keyboardHideAnimationInFlight = NO;
    keyboardStateHostGeneration = 0;
    keyboardZoomSuppressedForCurrentSession = NO;
    [self restoreKeyboardZoomImmediately];
    UIView *oldContextView = contextView;
    if (oldContextView) {
        [[ContextHostManager sharedInstance] invalidateIOS26PresentationContainersInSceneStack:oldContextView];
    }
    for (UIView *v in self.contentView.subviews) {
        if (v == cantHostCanvas) {
            cantHostCanvas = nil;
            cantHostIconView = nil;
            cantHostLabel = nil;
        }
        [v removeFromSuperview];
    }
    // chrome 会被上面的子视图清扫移除,悬浮状态一并复位,下次发布后再挂回。
    [self resetHostedFloatingWindowState];
    if (oldContextView) {
        contextView = nil;
        presentationBundleId = nil;
        presentationSceneIdentity = nil;
        presentationCanvasSize = CGSizeZero;
        presentationOrientation = UIInterfaceOrientationUnknown;
        presentationSourceCanvasSize = CGSizeZero;
        presentationSourceOrientation = UIInterfaceOrientationUnknown;
        presentationRetainedAfterRelease = NO;
    }
    [self clearPresentationSnapshot];
    if (externalSceneStack) {
        [externalSceneStack removeFromSuperview];
        externalSceneStack = nil;
    }
}

-(void)forceCloseAndReleaseImmediately{
    deferredOpenGeneration += 1;
    [self resetHostedFloatingWindowState];
    [self cancelAutoNubTimer];
    scrollSnapAnimationInProgress = NO;
    scaledProgrammaticCloseAnimating = NO;
    scaledProgrammaticCloseNeedsLayout = NO;
    deferScaledCloseSessionCleanup = NO;
    [keyboardZoomContainer.layer removeAllAnimations];
    [handleScrollView.layer removeAllAnimations];
    handlePanIntent = POHandlePanIntentNone;
    pendingOpenState = NO;
    interactiveHostIntentIssued = NO;
    interactiveHostResumeRequired = NO;
    quickSwitchOpeningApp = NO;
    splitLayoutActive = NO;
    POQuickSwitchLayoutMode previousLayoutMode = [self currentQuickSwitchLayoutMode];
    CGFloat inheritedHandleScreenY = NAN;
    if (previousLayoutMode == POQuickSwitchLayoutModeHorizontalBottom) {
        CGRect handleInView = [handleScrollView convertRect:self.handle.frame toView:self.view];
        if (!CGRectIsEmpty(handleInView) && isfinite(CGRectGetMinY(handleInView))) {
            inheritedHandleScreenY = CGRectGetMinY(handleInView);
        }
    }
    panelState = POPanelStateClosed;
    [scrollView setContentOffset:CGPointZero animated:NO];
    if (previousLayoutMode != [self currentQuickSwitchLayoutMode]) {
        [self applyLayoutPreservingHandlePosition:YES];
        [self inheritVerticalHandleScreenY:inheritedHandleScreenY];
        [self storeHandlePosition];
    }
    shadowView.layer.shadowOpacity = 0;
    [self dismissTransientInteractionUI];
    showingCantHost = NO;
    if (origOffset && handleScrollView) {
        [handleScrollView setContentOffset:CGPointMake(0, [self clampedHandleOffset:origOffset.floatValue]) animated:NO];
        if (self.handle) {
            [self storeHandlePosition];
        }
    }
    origOffset = nil;
    keyboardNotificationState = POKeyboardNotificationStateUnknown;
    hostedKeyboardLayerPresent = NO;
    keyboardHideAnimationInFlight = NO;
    keyboardStateHostGeneration = 0;
    keyboardZoomSuppressedForCurrentSession = NO;
    [self restoreKeyboardZoomImmediately];
    keyboardZoomSuspensionReasons = POKeyboardZoomSuspensionNone;
    [self hidePresentationContainer];
    [hostSession invalidate];
    [[POSplitSessionController sharedInstance] end];
    [self cleanUpSubviews];
    presentationBundleId = nil;
    presentationSceneIdentity = nil;
    presentationCanvasSize = CGSizeZero;
    presentationOrientation = UIInterfaceOrientationUnknown;
    presentationSourceCanvasSize = CGSizeZero;
    presentationSourceOrientation = UIInterfaceOrientationUnknown;
    presentationRetainedAfterRelease = NO;
    [self updateInteractionBackdropsAnimated:NO];
}

-(void)showCantHostView{
    showingCantHost = YES;

    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self showCantHostView];
        });
        return;
    }

    if (!cantHostCanvas) {
        cantHostCanvas = [[UIView alloc] initWithFrame:CGRectZero];
        cantHostCanvas.backgroundColor = [UIColor clearColor];
        [self.contentView addSubview:cantHostCanvas];

        UIImageConfiguration *config = [UIImageSymbolConfiguration configurationWithPointSize:96 weight:UIImageSymbolWeightRegular];
        UIImage *scannerImage = [UIImage systemImageNamed:@"scanner" withConfiguration:config]
            ?: [UIImage systemImageNamed:@"scanner.fill" withConfiguration:config];
        cantHostIconView = [[UIImageView alloc] initWithImage:scannerImage];
        cantHostIconView.contentMode = UIViewContentModeScaleAspectFit;
        cantHostIconView.tintColor = [UIColor labelColor];
        [cantHostIconView sizeToFit];
        [cantHostCanvas addSubview:cantHostIconView];

        cantHostLabel = [[UILabel alloc] initWithFrame:CGRectZero];
        cantHostLabel.numberOfLines = 1;
        cantHostLabel.textAlignment = NSTextAlignmentCenter;
        cantHostLabel.font = [UIFont systemFontOfSize:16 weight:UIFontWeightMedium];
        cantHostLabel.textColor = [UIColor labelColor];
        cantHostLabel.text = POLocalizedString(@"The current app is already open and can't be shown.", @"Tweak");
        [cantHostCanvas addSubview:cantHostLabel];
    }
    cantHostCanvas.hidden = NO;
    [self.contentView bringSubviewToFront:cantHostCanvas];
    [self layoutCantHostView];
}

-(void)layoutCantHostView{
    if (!cantHostCanvas || !cantHostIconView || !cantHostLabel) {
        return;
    }

    cantHostCanvas.transform = CGAffineTransformScale(CGAffineTransformIdentity, scale, scale);
    if ([[POApplicationHelper settings][@"leftHanded"] boolValue]){
        cantHostCanvas.transform = CGAffineTransformConcat(cantHostCanvas.transform, CGAffineTransformMakeScale(-1.0, 1.0));
    }
    CGRect canvasFrame = cantHostCanvas.frame;
    canvasFrame.origin = CGPointZero;
    canvasFrame.size = self.contentView.bounds.size;
    cantHostCanvas.frame = canvasFrame;

    CGFloat width = cantHostCanvas.bounds.size.width;
    CGFloat height = cantHostCanvas.bounds.size.height;
    cantHostIconView.center = CGPointMake(width/2.0, height/2.0 - 40);
    cantHostLabel.frame = CGRectMake(0, 0, MAX(0, width-32), 30);
    cantHostLabel.center = CGPointMake(width/2.0, CGRectGetMaxY(cantHostIconView.frame) + 32);
}

#pragma mark - POHostSessionControllerDelegate

-(void)hostSessionController:(POHostSessionController *)controller
hostedPresentationContentDidBecomeUnavailableForBundleId:(NSString *)bundleId
                    generation:(NSUInteger)generation{
    if (NSProcessInfo.processInfo.operatingSystemVersion.majorVersion < 26 ||
        controller != hostSession || generation != controller.currentGeneration ||
        ![bundleId isEqualToString:controller.requestedBundleId] ||
        panelState == POPanelStateClosed || panelState == POPanelStateClosing ||
        !runtimeCategoryTransitionSnapshotFallbackArmed ||
        !presentationSnapshotView ||
        ![presentationSnapshotBundleId isEqualToString:bundleId]) {
        return;
    }
    [self showRuntimeCategoryTransitionSnapshotFallback];
}

-(CGSize)hostSessionPreferredSceneStackSize:(POHostSessionController *)controller{
    return [self contextManagerPreferredSceneStackSize:nil];
}

-(UIInterfaceOrientation)hostSessionPreferredHostedInterfaceOrientation:(POHostSessionController *)controller{
    return [self contextManagerPreferredHostedInterfaceOrientation:nil];
}

-(void)hostSessionController:(POHostSessionController *)controller
hostedInterfaceOrientationDidChange:(UIInterfaceOrientation)orientation
   systemAnimationParameters:(id)animationParameters
                      bundleId:(NSString *)bundleId
                    generation:(NSUInteger)generation{
    if (![bundleId isEqualToString:controller.requestedBundleId] || generation != controller.currentGeneration ||
        panelState == POPanelStateClosed || panelState == POPanelStateClosing) {
        return;
    }
    BOOL layoutOrientationKnown = hostedLayoutOrientation == UIInterfaceOrientationPortrait ||
        hostedLayoutOrientation == UIInterfaceOrientationPortraitUpsideDown ||
        UIInterfaceOrientationIsLandscape(hostedLayoutOrientation);
    if (layoutOrientationKnown &&
        UIInterfaceOrientationIsLandscape(hostedLayoutOrientation) == UIInterfaceOrientationIsLandscape(orientation)) {
        return;
    }

    BOOL hasPreRotationSnapshot = presentationSnapshotView && !presentationSnapshotIsTargetPlaceholder &&
        [presentationSnapshotBundleId isEqualToString:bundleId] &&
        (presentationSnapshotOrientation == UIInterfaceOrientationPortrait ||
         presentationSnapshotOrientation == UIInterfaceOrientationPortraitUpsideDown ||
         UIInterfaceOrientationIsLandscape(presentationSnapshotOrientation)) &&
        UIInterfaceOrientationIsLandscape(presentationSnapshotOrientation) != UIInterfaceOrientationIsLandscape(orientation);
    if (hasPreRotationSnapshot) {
        runtimeCategoryTransitionSnapshotActive = YES;
    }

    UIInterfaceOrientation previousLayoutOrientation = hostedLayoutOrientation;
    CGFloat previousBackdropAlpha = panelBackdropView.alpha;
    [self dismissTransientInteractionUI];

    hostedLayoutOrientation = orientation;
    hostedCategoryTransitionPending = YES;
    [self updateInteractionBackdropsAnimated:NO];
    [self addKeyboardZoomSuspension:POKeyboardZoomSuspensionRotation];
    [self restoreKeyboardZoomImmediately];

    BOOL transitionAnimated =
        [self beginRuntimeHostedCategoryTransitionFromOrientation:previousLayoutOrientation
                                                    toOrientation:orientation
                                            startingBackdropAlpha:previousBackdropAlpha
                                         systemAnimationParameters:animationParameters];
    hostedCategoryTransitionPending = NO;
    if (!transitionAnimated) {
        [self applyLayoutPreservingHandlePosition:YES];
        ContextHostManager *manager = [ContextHostManager sharedInstance];
        UIInterfaceOrientation sourceOrientation =
            manager.currentHostedPresentationSourceOrientation;
        BOOL sourceNeedsCanonicalization =
            POIsConcretePresentationOrientation(sourceOrientation) &&
            POIsConcretePresentationOrientation(orientation) &&
            UIInterfaceOrientationIsLandscape(sourceOrientation) !=
                UIInterfaceOrientationIsLandscape(orientation);
        if (sourceNeedsCanonicalization) {
            if (NSProcessInfo.processInfo.operatingSystemVersion.majorVersion == 15) {
                runtimeScenePublicationStaging = YES;
                [manager canonicalizeHostedSourceForCurrentOrientationWithGeneration:generation];
                runtimeScenePublicationStaging = NO;
            } else {
                BOOL snapshotReady =
                    [self prepareRuntimeCategoryTransitionSnapshotFromSourceOrientation:sourceOrientation];
                if (snapshotReady) {
                    [self retargetRuntimeCategoryTransitionSnapshotForOrientation:orientation];
                }
                BOOL canonicalizationStarted =
                    [manager canonicalizeHostedSourceForCurrentOrientationWithGeneration:generation];
                if (snapshotReady && !canonicalizationStarted) {
                    [self clearPresentationSnapshot];
                }
            }
        }
    }
    if (hasPreRotationSnapshot && presentationSnapshotView &&
        [presentationSnapshotBundleId isEqualToString:bundleId]) {
        [self retargetRuntimeCategoryTransitionSnapshotForOrientation:orientation];
        runtimeCategoryTransitionSnapshotActive = YES;
    }
    if (contextView && !presentationRetainedAfterRelease &&
        [presentationBundleId isEqualToString:bundleId] &&
        [controller.activeBundleId isEqualToString:bundleId]) {
        presentationCanvasSize = [self contextManagerPreferredSceneStackSize:nil];
        presentationOrientation = orientation;
        contextView.hidden = NO;
        [self.contentView bringSubviewToFront:contextView];
        if (presentationSnapshotView && !presentationSnapshotView.hidden &&
            presentationSnapshotView.superview == self.contentView) {
            [self.contentView bringSubviewToFront:presentationSnapshotView];
        }
    }
    if (!transitionAnimated) {
        [self removeKeyboardZoomSuspension:POKeyboardZoomSuspensionRotation];
        [self reevaluateKeyboardZoomAnimated:NO];
    }

}

-(void)hostSessionController:(POHostSessionController *)controller
             didPublishScene:(FBScene *)scene
                 sceneStack:(UIView *)sceneStack
                   bundleId:(NSString *)bundleId
                 generation:(NSUInteger)generation{
    if (!sceneStack || generation != controller.currentGeneration ||
        ![bundleId isEqualToString:controller.requestedBundleId]) {
        return;
    }

    BOOL usesIOS15LiveRuntimeScenePublication =
        NSProcessInfo.processInfo.operatingSystemVersion.majorVersion == 15 &&
        (runtimeHostedCategoryTransitionAnimating || runtimeScenePublicationStaging);
    if (runtimeHostedCategoryTransitionAnimating && !runtimeScenePublicationStaging &&
        !usesIOS15LiveRuntimeScenePublication) {
        deferredRuntimePublishedScene = scene;
        deferredRuntimePublishedSceneStack = sceneStack;
        deferredRuntimePublishedBundleId = [bundleId copy];
        deferredRuntimePublishedGeneration = generation;
        if (runtimeCategoryTransitionSnapshotActive) {
            [self scheduleRuntimeScenePublicationStagingIfNeeded];
        }
        return;
    }

    if (![bundleId isEqualToString:pinnedBundleId]) {
        [self commitPinnedBundleId:bundleId];
    }

    if (keyboardStateHostGeneration != generation) {
        keyboardStateHostGeneration = generation;
        keyboardNotificationState = POKeyboardNotificationStateUnknown;
        hostedKeyboardLayerPresent = NO;
        keyboardHideAnimationInFlight = NO;
        keyboardZoomSuppressedForCurrentSession = NO;
    }

    UIView *previousContextView = contextView;
    UIView *previousCantHostCanvas = cantHostCanvas;
    BOOL replacingVisibleMainStack = previousContextView && previousContextView != sceneStack &&
        previousContextView.superview == self.contentView && !previousContextView.hidden &&
        !presentationSnapshotView && panelState != POPanelStateClosed;
    if (replacingVisibleMainStack && !usesIOS15LiveRuntimeScenePublication) {
        [self capturePresentationSnapshotIfPossible];
        if (presentationSnapshotView) {
            presentationSnapshotView.hidden = NO;
        }
    }
    UIInterfaceOrientation currentHostedOrientation = [self contextManagerPreferredHostedInterfaceOrientation:nil];
    ContextHostManager *manager = [ContextHostManager sharedInstance];
    UIInterfaceOrientation publishedSourceOrientation =
        [manager publishedSourceOrientationForScene:scene];
    CGSize publishedSourceCanvas = [manager publishedSourceCanvasSizeForScene:scene];
    if (POIsConcretePresentationOrientation(publishedSourceOrientation) &&
        publishedSourceCanvas.width > 0 && publishedSourceCanvas.height > 0) {
        presentationSourceOrientation = publishedSourceOrientation;
        presentationSourceCanvasSize = publishedSourceCanvas;
    } else if (presentationSourceCanvasSize.width <= 0 || presentationSourceCanvasSize.height <= 0 ||
               !POIsConcretePresentationOrientation(presentationSourceOrientation)) {
        UIInterfaceOrientation sourceOrientation =
            [manager preferredHostedInterfaceOrientationForBundleId:bundleId];
        if (!POIsConcretePresentationOrientation(sourceOrientation)) {
            sourceOrientation = currentHostedOrientation;
        }
        presentationSourceCanvasSize = sceneStack.bounds.size;
        presentationSourceOrientation = sourceOrientation;
    }

    presentationBundleId = [bundleId copy];
    presentationSceneIdentity = scene;
    presentationCanvasSize = [self contextManagerPreferredSceneStackSize:nil];
    presentationOrientation = currentHostedOrientation;

    contextView = sceneStack;
    sceneStack.hidden = NO;
    sceneStack.alpha = 1;

    BOOL layoutOrientationKnown = POIsConcretePresentationOrientation(hostedLayoutOrientation);
    BOOL publishedOrientationKnown = POIsConcretePresentationOrientation(currentHostedOrientation);
    BOOL layoutCategoryMismatch = publishedOrientationKnown &&
        (!layoutOrientationKnown ||
         UIInterfaceOrientationIsLandscape(hostedLayoutOrientation) !=
             UIInterfaceOrientationIsLandscape(currentHostedOrientation));
    BOOL pendingRuntimeOrientationHandoff =
        [manager hasPendingRuntimeOrientationHandoffForScene:scene generation:generation];
    if (layoutCategoryMismatch && panelState != POPanelStateClosed &&
        panelState != POPanelStateClosing && !pendingRuntimeOrientationHandoff) {
        [self addKeyboardZoomSuspension:POKeyboardZoomSuspensionRotation];
        [self restoreKeyboardZoomImmediately];
        [self applyLayoutPreservingHandlePosition:YES];
        [self removeKeyboardZoomSuspension:POKeyboardZoomSuspensionRotation];
        [self reevaluateKeyboardZoomAnimated:NO];
    } else if (!pendingRuntimeOrientationHandoff) {
        [self layoutContextView];
    }
    [self reconcilePresentedContainerGeometry];

    if (previousContextView && previousContextView != sceneStack && previousContextView.superview) {
        [manager invalidateIOS26PresentationContainersInSceneStack:previousContextView];
        [previousContextView removeFromSuperview];
    }
    if (previousCantHostCanvas && previousCantHostCanvas.superview) {
        [previousCantHostCanvas removeFromSuperview];
    }
    if (cantHostCanvas == previousCantHostCanvas) {
        cantHostCanvas = nil;
        cantHostIconView = nil;
        cantHostLabel = nil;
    }

    presentationRetainedAfterRelease = NO;
    showingCantHost = NO;
    [self.contentView bringSubviewToFront:contextView];
    // 新 scene stack 挂到 contentView 后,把窗口 chrome 重新提回最上层。
    [self updateHostedWindowChrome];

    if (NSProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 26 &&
        runtimeCategoryTransitionSnapshotActive && presentationSnapshotView &&
        !presentationSnapshotIsTargetPlaceholder &&
        [presentationSnapshotBundleId isEqualToString:bundleId] &&
        presentationSnapshotSceneIdentity == scene) {
        UIInterfaceOrientation snapshotTargetOrientation = currentHostedOrientation;
        [self retargetRuntimeCategoryTransitionSnapshotForOrientation:snapshotTargetOrientation];
    }

    BOOL snapshotCanBridgeHandoff = presentationSnapshotView && !presentationSnapshotView.hidden &&
        [self hasCompatiblePresentationSnapshotForBundleId:bundleId];
    BOOL snapshotCanRemainForOrientationHandoff = presentationSnapshotView &&
        !presentationSnapshotIsTargetPlaceholder && runtimeCategoryTransitionSnapshotFallbackArmed &&
        [presentationSnapshotBundleId isEqualToString:bundleId] &&
        (!presentationSnapshotSceneIdentity || presentationSnapshotSceneIdentity == scene);
    if (snapshotCanBridgeHandoff || snapshotCanRemainForOrientationHandoff) {
        presentationSnapshotView.hidden = NO;
        presentationSnapshotView.alpha = 1.0;
        [self layoutPresentationSnapshotView];
        [self.contentView bringSubviewToFront:presentationSnapshotView];
        [self schedulePresentationSnapshotRetirementForBundleId:bundleId generation:generation];
    } else if (presentationSnapshotView) {
        [self clearPresentationSnapshot];
    }

    [self completeExternallyActivatedApplicationIfNeeded:bundleId];
}

-(void)hostSessionController:(POHostSessionController *)controller
             didPublishScene:(FBScene *)scene
          externalSceneStack:(UIView *)sceneStack
       containsKeyboardLayer:(BOOL)containsKeyboardLayer
                   bundleId:(NSString *)bundleId
                 generation:(NSUInteger)generation{
    if (generation != controller.currentGeneration ||
        ![bundleId isEqualToString:controller.requestedBundleId]) {
        return;
    }

    hostedKeyboardLayerPresent = containsKeyboardLayer;
    if (containsKeyboardLayer &&
        keyboardNotificationState == POKeyboardNotificationStateUnknown &&
        !keyboardHideAnimationInFlight) {
        keyboardNotificationState = POKeyboardNotificationStateVisible;
        keyboardHideAnimationInFlight = NO;
    } else if (!containsKeyboardLayer) {
        if (keyboardNotificationState == POKeyboardNotificationStateUnknown) {
            keyboardNotificationState = POKeyboardNotificationStateHidden;
        }
    }

    if (!contextView || !sceneStack) {
        [self reevaluateKeyboardZoomAnimated:NO];
        return;
    }

    if (externalSceneStack && externalSceneStack != sceneStack) {
        [externalSceneStack removeFromSuperview];
    }
    externalSceneStack = sceneStack;
    if (sceneStack.subviews.count > 0) {
        [self.contentView addSubview:sceneStack];
        [self layoutExternalSceneStack];
        [self.contentView bringSubviewToFront:sceneStack];
        if (presentationSnapshotView && !presentationSnapshotView.hidden &&
            presentationSnapshotView.superview == self.contentView) {
            [self.contentView bringSubviewToFront:presentationSnapshotView];
        }
    }
    [self reevaluateKeyboardZoomAnimated:YES];
    [self completeExternallyActivatedApplicationIfNeeded:bundleId];
}

-(void)hostSessionController:(POHostSessionController *)controller
cannotHostFrontmostBundleId:(NSString *)bundleId
                  generation:(NSUInteger)generation{
    if ([externallyActivatedBundleId isEqualToString:bundleId]) {
        [self restoreExternallyActivatedApplicationNatively:bundleId];
        return;
    }
    BOOL pendingExternalRoute = pinnedBundleId.length > 0 &&
        ![bundleId isEqualToString:pinnedBundleId];
    if (pendingExternalRoute) {
        if (presentationSnapshotIsTargetPlaceholder &&
            [presentationSnapshotBundleId isEqualToString:bundleId]) {
            [self clearPresentationSnapshot];
        }
        [hostSession activateBundleId:pinnedBundleId];
        return;
    }
    if (![bundleId isEqualToString:pinnedBundleId]) {
        return;
    }
    splitLayoutActive = NO;
    [[POSplitSessionController sharedInstance] end];
    [self cleanUpSubviews];
    presentationBundleId = nil;
    presentationSceneIdentity = nil;
    presentationCanvasSize = CGSizeZero;
    presentationOrientation = UIInterfaceOrientationUnknown;
    presentationSourceCanvasSize = CGSizeZero;
    presentationSourceOrientation = UIInterfaceOrientationUnknown;
    presentationRetainedAfterRelease = NO;
    if (panelState != POPanelStateClosed) {
        keyboardZoomContainer.hidden = NO;
        [self showCantHostView];
    }
    [self reevaluateKeyboardZoomAnimated:NO];
}

@end
