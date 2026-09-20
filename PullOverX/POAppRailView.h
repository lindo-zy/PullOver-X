//
//  POAppRailView.h
//  PullOverX
//
//  小窗打开时常驻显示的应用竖栏:把当前记录的全部 APP 以图标形式列在
//  把手所在的一列,点击图标即可切换小窗内容。平移手势转发给控制器用于
//  拖拽关闭小窗,长按手势转发用于调出原快速切换菜单。竖栏最底部固定一个
//  把手左右切换按钮(受"把手左右切换"开关控制),点击后把手换边、竖直位置不变。
//  开启"把手展开居中"后,小窗展开时第一个图标钉在竖栏顶部、其余图标下移到
//  屏幕中部,此时控制器会把竖栏 frame 撑满上下可用空间;缩点把手唤出的
//  关闭态竖栏不居中,由控制器通过 centeredIcons 写入当前是否生效。
//

#import <UIKit/UIKit.h>

@protocol POAppRailViewDelegate <NSObject>
- (void)appRailView:(UIView *)railView didTapBundleId:(NSString *)bundleId;
- (void)appRailView:(UIView *)railView didReceivePan:(UIPanGestureRecognizer *)recognizer;
- (void)appRailView:(UIView *)railView didReceiveLongPress:(UILongPressGestureRecognizer *)recognizer;
// 点击竖栏底部的把手左右切换按钮。
- (void)appRailViewDidTapSideSwitch:(UIView *)railView;
@end

@interface POAppRailView : UIScrollView

@property (nonatomic, weak) id<POAppRailViewDelegate> railDelegate;

// 当前面是否采用"把手展开居中"排布(第一个图标钉顶、其余从可视区中点往下排)。
// 由控制器按"小窗展开 && 设置开启"写入;翻转时会自动触发一次重排。
@property (nonatomic, assign) BOOL centeredIcons;

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

// 快速切换菜单的呈现锚点:长按落点竖直方向就近命中的图标瓦片,让菜单落在
// 长按位置而不是把手位置;没有可命中的图标时返回竖栏自身。
- (UIView *)longPressAnchorViewForRecognizer:(UILongPressGestureRecognizer *)recognizer;

@end
