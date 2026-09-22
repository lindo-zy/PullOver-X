#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

@class POHostedWindowChromeView;

// 分屏/悬浮托管窗口的卡片 chrome:关闭按钮与悬浮拖动条。
typedef NS_ENUM(NSInteger, POHostedWindowChromeMode) {
    POHostedWindowChromeModeHidden = 0,
    POHostedWindowChromeModeCompact, // 分屏钉底形态:仅角标关闭按钮,不占卡片内容。
    POHostedWindowChromeModeBar,     // 悬浮形态:顶部拖动条(把手胶囊+关闭按钮)。
};

@protocol POHostedWindowChromeViewDelegate <NSObject>
- (void)hostedWindowChromeDidTapClose:(POHostedWindowChromeView *)chromeView;
// 悬浮形态拖动条上的单指拖动,控制器负责按位移移动窗口 frame。
- (void)hostedWindowChrome:(POHostedWindowChromeView *)chromeView
       didReceiveMovePan:(UIPanGestureRecognizer *)recognizer;
@end

@interface POHostedWindowChromeView : UIView
@property (nonatomic, weak) id<POHostedWindowChromeViewDelegate> delegate;
@property (nonatomic, assign) POHostedWindowChromeMode mode;
// 视觉上关闭按钮靠右手边;左手模式整窗镜像,由控制器取反传入。
@property (nonatomic, assign) BOOL closeOnTrailingSide;
+ (CGFloat)barHeight;
+ (CGFloat)compactBadgeSize;
@end

NS_ASSUME_NONNULL_END
