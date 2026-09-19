//
//  POAppRailView.h
//  PullOverX
//
//  小窗打开时常驻显示的应用竖栏:把当前记录的全部 APP 以图标形式列在
//  把手所在的一列,点击图标即可切换小窗内容。平移手势转发给控制器用于
//  拖拽关闭小窗,长按手势转发用于调出原快速切换菜单。
//

#import <UIKit/UIKit.h>

@protocol POAppRailViewDelegate <NSObject>
- (void)appRailView:(UIView *)railView didTapBundleId:(NSString *)bundleId;
- (void)appRailView:(UIView *)railView didReceivePan:(UIPanGestureRecognizer *)recognizer;
- (void)appRailView:(UIView *)railView didReceiveLongPress:(UILongPressGestureRecognizer *)recognizer;
@end

@interface POAppRailView : UIScrollView

@property (nonatomic, weak) id<POAppRailViewDelegate> railDelegate;

// 重建图标列。bundleIdentifiers 为要列出的全部 APP(可超过屏幕可容纳数,
// 超出部分由内部滚动查看),activeBundleId 对应的图标会加高亮描边。
- (void)reloadWithBundleIdentifiers:(NSArray<NSString *> *)bundleIdentifiers
                     activeBundleId:(NSString *)activeBundleId
                           tileSize:(CGFloat)tileSize;

// 重载后的自然内容高度(未按屏幕高度裁剪),供控制器计算最终 frame。
- (CGSize)preferredContentSize;

- (void)refreshLayoutDirection;

// 栏内拖拽/长按手势是否正在进行。进行中时视图不能被 hidden,否则触摸会被取消。
- (BOOL)isInteracting;

@end
