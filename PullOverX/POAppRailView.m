//
//  POAppRailView.m
//  PullOverX
//
//

#import "POAppRailView.h"
#import "POApplicationHelper.h"
#import "POLocalization.h"
#import "headers.h"
#import <objc/runtime.h>

#define PO_APP_RAIL_TILE_GAP 4.0
#define PO_APP_RAIL_ICON_INSET 5.0
#define PO_APP_RAIL_CORNER_RADIUS_RATIO (8.0 / 34.0)

@interface POAppRailTile : UIView

@property (nonatomic, copy) NSString *bundleId;
@property (nonatomic, strong) UIVisualEffectView *blurView;
@property (nonatomic, strong) UIImageView *iconView;

- (instancetype)initWithTileSize:(CGFloat)tileSize;
- (void)setHighlighted:(BOOL)highlighted;

@end

@implementation POAppRailTile

- (instancetype)initWithTileSize:(CGFloat)tileSize {
    if (self = [super initWithFrame:CGRectMake(0, 0, tileSize, tileSize)]) {
        self.layer.cornerRadius = tileSize * PO_APP_RAIL_CORNER_RADIUS_RATIO;
        self.layer.cornerCurve = kCACornerCurveContinuous;
        self.layer.shadowColor = [UIColor blackColor].CGColor;
        self.layer.shadowOpacity = 0.32;
        self.layer.shadowRadius = 3.5;
        self.layer.shadowOffset = CGSizeZero;

        UIBlurEffect *blur = [UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemThinMaterial];
        self.blurView = [[UIVisualEffectView alloc] initWithEffect:blur];
        self.blurView.userInteractionEnabled = NO;
        self.blurView.layer.cornerRadius = self.layer.cornerRadius;
        self.blurView.layer.cornerCurve = kCACornerCurveContinuous;
        self.blurView.clipsToBounds = YES;
        self.blurView.frame = self.bounds;
        [self addSubview:self.blurView];

        CGFloat iconSize = MAX(0, tileSize - PO_APP_RAIL_ICON_INSET * 2.0);
        self.iconView = [[UIImageView alloc] initWithFrame:CGRectMake(PO_APP_RAIL_ICON_INSET,
                                                                     PO_APP_RAIL_ICON_INSET,
                                                                     iconSize,
                                                                     iconSize)];
        self.iconView.contentMode = UIViewContentModeScaleAspectFit;
        self.iconView.clipsToBounds = YES;
        [self.blurView.contentView addSubview:self.iconView];

        self.isAccessibilityElement = YES;
        self.accessibilityTraits = UIAccessibilityTraitButton;
    }
    return self;
}

- (void)setHighlighted:(BOOL)highlighted {
    self.layer.borderWidth = highlighted ? 1.25 : 0;
    self.layer.borderColor = highlighted ? [UIColor.whiteColor colorWithAlphaComponent:0.65].CGColor : nil;
    self.layer.shadowOpacity = highlighted ? 0.40 : 0.32;
}

@end

@interface POAppRailView () <UIGestureRecognizerDelegate>

@end

@implementation POAppRailView {
    NSMutableArray<POAppRailTile *> *tiles;
    CGFloat tileSide;
    NSString *activeBundleId;
    UIPanGestureRecognizer *railPanGestureRecognizer;
    UILongPressGestureRecognizer *railLongPressGestureRecognizer;
    UIImpactFeedbackGenerator *impactGenerator;
    BOOL hapticsEnabled;
    POAppRailTile *sideSwitchButton;
    BOOL sideSwitchEnabled;
    // 悬浮网格的毛玻璃底衬:铺在可视区底层,把图标网格和当前界面区分开。
    UIVisualEffectView *gridBackdropView;
    // 重排守卫记录的"布局轴长度":竖排存可视区高度,横排存可视区宽度。
    CGFloat lastLayoutAxisLength;
}

- (instancetype)initWithFrame:(CGRect)frame {
    if (self = [super initWithFrame:frame]) {
        tiles = [NSMutableArray array];
        tileSide = 34.0;
        activeBundleId = nil;

        self.backgroundColor = UIColor.clearColor;
        self.showsVerticalScrollIndicator = NO;
        self.showsHorizontalScrollIndicator = NO;
        self.alwaysBounceVertical = NO;
        self.bounces = NO;
        self.delaysContentTouches = NO;
        self.contentInsetAdjustmentBehavior = UIScrollViewContentInsetAdjustmentNever;
        self.scrollsToTop = NO;
        self.clipsToBounds = YES;
        self.layer.cornerRadius = tileSide * PO_APP_RAIL_CORNER_RADIUS_RATIO;
        self.layer.cornerCurve = kCACornerCurveContinuous;

        UIBlurEffect *backdropBlur = [UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemThinMaterial];
        gridBackdropView = [[UIVisualEffectView alloc] initWithEffect:backdropBlur];
        gridBackdropView.userInteractionEnabled = NO;
        gridBackdropView.hidden = YES;
        gridBackdropView.layer.cornerRadius = self.layer.cornerRadius;
        gridBackdropView.layer.cornerCurve = kCACornerCurveContinuous;
        gridBackdropView.clipsToBounds = YES;
        // 第一个加入,保证始终垫在后续添加的图标瓦片和换边按钮底下。
        [self addSubview:gridBackdropView];

        railPanGestureRecognizer = [[UIPanGestureRecognizer alloc] initWithTarget:self
                                                                         action:@selector(railPan:)];
        railPanGestureRecognizer.delegate = self;
        railPanGestureRecognizer.maximumNumberOfTouches = 1;
        [self addGestureRecognizer:railPanGestureRecognizer];

        railLongPressGestureRecognizer = [[UILongPressGestureRecognizer alloc] initWithTarget:self
                                                                                     action:@selector(railLongPress:)];
        railLongPressGestureRecognizer.minimumPressDuration = 0.3;
        railLongPressGestureRecognizer.delegate = self;
        [self addGestureRecognizer:railLongPressGestureRecognizer];

        impactGenerator = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleLight];
        hapticsEnabled = [[POApplicationHelper settings][@"hapticFeedback"] boolValue];
    }
    return self;
}

- (CGFloat)tileSize {
    return tileSide;
}

// 换边按钮只在贴边竖栏显示;悬浮居中网格不显示,几何占位一并去掉。
- (BOOL)sideSwitchVisible {
    return sideSwitchEnabled && !self.horizontalLayout;
}

- (CGSize)preferredContentSize {
    NSUInteger count = tiles.count;
    CGFloat height = count > 0 ? tileSide * count + PO_APP_RAIL_TILE_GAP * (count - 1) : 0;
    if (sideSwitchEnabled) {
        height = height > 0 ? height + PO_APP_RAIL_TILE_GAP + tileSide : tileSide;
    }
    if (height <= 0) {
        height = tileSide;
    }
    return CGSizeMake(tileSide, height);
}

// 网格折行列数:与 layoutTiles 的横排分支共用同一公式,保证控制器据此
// 定下的 frame 宽度和视图内部折行结果一致。
- (CGFloat)gridColumnsForWidth:(CGFloat)width {
    CGFloat columns = floor((MAX(width, tileSide) + PO_APP_RAIL_TILE_GAP) /
                            (tileSide + PO_APP_RAIL_TILE_GAP));
    return MAX(1.0, columns);
}

- (CGSize)gridContentSizeForMaxWidth:(CGFloat)maxWidth {
    NSUInteger count = tiles.count;
    CGFloat columns = [self gridColumnsForWidth:maxWidth];
    CGFloat tileCount = (CGFloat)count;
    CGFloat rows = MAX(1.0, ceil(tileCount / columns));
    // 图标不足一整行时按实际占用的列数收窄,避免出现很宽的空胶囊。
    CGFloat filledColumns = MIN(tileCount, columns);
    CGFloat contentWidth = MIN(maxWidth,
                               filledColumns * tileSide + (filledColumns - 1) * PO_APP_RAIL_TILE_GAP);
    CGFloat contentHeight = rows * tileSide + (rows - 1) * PO_APP_RAIL_TILE_GAP;
    if (sideSwitchEnabled && !self.horizontalLayout) {
        // 贴边竖栏的换边按钮钉在底部,留出一行按钮占位;悬浮网格不显示按钮。
        contentHeight += PO_APP_RAIL_TILE_GAP + tileSide;
    }
    contentWidth = MAX(contentWidth, tileSide);
    contentHeight = MAX(contentHeight, tileSide);
    return CGSizeMake(contentWidth, contentHeight);
}

// 底部"把手左右切换"按钮:开关关闭时整体移除,不显示也不响应。
- (void)reloadSideSwitchButton {
    sideSwitchEnabled = [[POApplicationHelper settings][@"railSideSwitch"] boolValue];
    if (!sideSwitchEnabled) {
        [sideSwitchButton removeFromSuperview];
        sideSwitchButton = nil;
        return;
    }
    if (sideSwitchButton && CGRectGetWidth(sideSwitchButton.frame) != tileSide) {
        // 把手大小变化后按新尺寸重建,瓦片的圆角/图标内边距都在构造时按尺寸确定。
        [sideSwitchButton removeFromSuperview];
        sideSwitchButton = nil;
    }
    if (sideSwitchButton) {
        return;
    }
    sideSwitchButton = [[POAppRailTile alloc] initWithTileSize:tileSide];
    CGFloat iconSize = MAX(0, tileSide - PO_APP_RAIL_ICON_INSET * 2.0);
    UIImageSymbolConfiguration *configuration =
        [UIImageSymbolConfiguration configurationWithPointSize:iconSize
                                                        weight:UIImageSymbolWeightSemibold];
    UIImage *symbol = [UIImage systemImageNamed:@"arrow.left.arrow.right"
                              withConfiguration:configuration];
    sideSwitchButton.iconView.image = [symbol imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate];
    sideSwitchButton.iconView.tintColor = UIColor.labelColor;
    sideSwitchButton.accessibilityLabel = POLocalizedString(@"Switch Handle Side", @"Tweak");
    UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc] initWithTarget:self
                                                                            action:@selector(sideSwitchTapped:)];
    [sideSwitchButton addGestureRecognizer:tap];
    sideSwitchButton.hidden = ![self sideSwitchVisible];
    [self addSubview:sideSwitchButton];
    [self setNeedsLayout];
}

- (void)reloadWithBundleIdentifiers:(NSArray<NSString *> *)bundleIdentifiers
                     activeBundleId:(NSString *)newActiveBundleId
                           tileSize:(CGFloat)tileSize {
    tileSide = MAX(1, tileSize);
    activeBundleId = [newActiveBundleId copy];
    hapticsEnabled = [[POApplicationHelper settings][@"hapticFeedback"] boolValue];
    // 瓦片尺寸变化后(悬浮网格放大一倍)同步自身与底衬圆角,大卡片配大圆角。
    self.layer.cornerRadius = tileSide * PO_APP_RAIL_CORNER_RADIUS_RATIO;
    gridBackdropView.layer.cornerRadius = self.layer.cornerRadius;
    [self reloadSideSwitchButton];

    for (POAppRailTile *tile in tiles) {
        [tile removeFromSuperview];
    }
    [tiles removeAllObjects];

    for (NSString *bundleId in bundleIdentifiers) {
        if (![bundleId isKindOfClass:[NSString class]] || bundleId.length == 0) {
            continue;
        }
        POAppRailTile *tile = [[POAppRailTile alloc] initWithTileSize:tileSide];
        tile.bundleId = bundleId;
        tile.iconView.image = [POApplicationHelper imageForBundleId:bundleId];
        tile.iconView.transform = [self iconLayoutTransform];

        SBApplication *application = [[objc_getClass("SBApplicationController") sharedInstance]
            applicationWithBundleIdentifier:bundleId];
        tile.accessibilityLabel = application.displayName ?: bundleId;

        UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc] initWithTarget:self
                                                                            action:@selector(tileTapped:)];
        [tile addGestureRecognizer:tap];
        [self addSubview:tile];
        [tiles addObject:tile];
    }

    [self layoutTiles];
    [self setContentOffset:CGPointZero animated:NO];
}

// 居中排布由控制器按"小窗展开 && 设置开启"写入;翻转后强制下次布局重排,
// 否则可视区高度没变时下面的高度守卫不会触发。
- (void)setCenteredIcons:(BOOL)centeredIcons {
    if (_centeredIcons == centeredIcons) {
        return;
    }
    _centeredIcons = centeredIcons;
    lastLayoutAxisLength = -1.0;
    [self setNeedsLayout];
}

// 横排/竖排切换同样强制重排:布局轴从高度换成宽度,旧守卫值不可信。
- (void)setHorizontalLayout:(BOOL)horizontalLayout {
    if (_horizontalLayout == horizontalLayout) {
        return;
    }
    _horizontalLayout = horizontalLayout;
    lastLayoutAxisLength = -1.0;
    [self setNeedsLayout];
}

- (void)layoutTiles {
    NSUInteger count = tiles.count;
    CGFloat sideInset = [self sideSwitchVisible] ? tileSide + PO_APP_RAIL_TILE_GAP : 0;
    CGAffineTransform iconTransform = [self iconLayoutTransform];
    if (self.horizontalLayout) {
        // 悬浮网格:按可视区宽度从左往右折行成多排,超高时竖向滚动;不显示
        // 换边按钮,底部无占位内边距,最后一排可以贴着毛玻璃底衬滚到底。
        CGFloat columns = [self gridColumnsForWidth:CGRectGetWidth(self.bounds)];
        CGFloat rows = MAX(1.0, ceil((CGFloat)count / columns));
        CGFloat contentHeight = rows * tileSide + (rows - 1) * PO_APP_RAIL_TILE_GAP;
        self.contentSize = CGSizeMake(CGRectGetWidth(self.bounds), contentHeight);
        self.contentInset = UIEdgeInsetsZero;
        self.scrollEnabled = contentHeight + sideInset > CGRectGetHeight(self.bounds) + 0.5;
        // 整窗在左手模式下水平镜像(PullOverX.mm 的 POApplyOrdinarySettings),
        // 瓦片按网格宽度反向落位,屏幕上才保持从左往右的阅读顺序,
        // 不满一排的末行也会靠屏幕左侧起排。
        BOOL mirrorTiles = [[POApplicationHelper settings][@"leftHanded"] boolValue];
        CGFloat gridWidth = CGRectGetWidth(self.bounds);
        for (NSUInteger index = 0; index < count; index++) {
            POAppRailTile *tile = tiles[index];
            CGFloat column = floor(index % (NSUInteger)columns);
            CGFloat row = floor(index / (NSUInteger)columns);
            CGFloat tileX = column * (tileSide + PO_APP_RAIL_TILE_GAP);
            if (mirrorTiles) {
                tileX = gridWidth - tileX - tileSide;
            }
            tile.frame = CGRectMake(tileX,
                                    row * (tileSide + PO_APP_RAIL_TILE_GAP),
                                    tileSide, tileSide);
            tile.iconView.transform = iconTransform;
            [tile setHighlighted:[tile.bundleId isEqualToString:activeBundleId]];
        }
        lastLayoutAxisLength = CGRectGetWidth(self.bounds);
        return;
    }
    CGFloat contentHeight;
    // 居中展开:第一个图标钉在竖栏顶部,其余图标从可视区垂直中点开始往下排。
    CGFloat middleOriginY = 0;
    CGFloat middleHeight = count > 1 ? tileSide * (count - 1) + PO_APP_RAIL_TILE_GAP * (count - 2) : 0;
    CGFloat availableHeight = CGRectGetHeight(self.bounds);
    // 应用过多时中部图标组放不下可视区,会压到换边按钮上或被底边截断,
    // 此时整体退回紧凑排布,靠滚动展示全部图标,不再做首尾分离布局。
    BOOL centered = self.centeredIcons && count > 1 &&
        floor(availableHeight / 2.0) >= tileSide + PO_APP_RAIL_TILE_GAP &&
        floor(availableHeight / 2.0) + middleHeight <= availableHeight - sideInset + 0.5;
    if (centered) {
        middleOriginY = floor(availableHeight / 2.0);
        contentHeight = MAX(tileSide, middleOriginY + middleHeight);
    } else {
        middleOriginY = 0;
        contentHeight = tileSide * count + PO_APP_RAIL_TILE_GAP * MAX(0, (NSInteger)count - 1);
    }
    self.contentSize = CGSizeMake(tileSide, contentHeight);
    // 换边按钮固定在竖栏底部不随内容滚动,底部内边距让最后的图标可以滚到按钮上方。
    self.contentInset = UIEdgeInsetsMake(0, 0, sideInset, 0);
    self.scrollEnabled = contentHeight + sideInset > CGRectGetHeight(self.bounds) + 0.5;
    for (NSUInteger index = 0; index < count; index++) {
        POAppRailTile *tile = tiles[index];
        CGFloat tileY = tileSide * index + PO_APP_RAIL_TILE_GAP * index;
        if (index > 0 && middleOriginY > 0) {
            tileY = middleOriginY + tileSide * (index - 1) + PO_APP_RAIL_TILE_GAP * (index - 1);
        }
        tile.frame = CGRectMake(0, tileY, tileSide, tileSide);
        tile.iconView.transform = iconTransform;
        [tile setHighlighted:[tile.bundleId isEqualToString:activeBundleId]];
    }
    lastLayoutAxisLength = CGRectGetHeight(self.bounds);
}

- (void)layoutSubviews {
    [super layoutSubviews];
    // reload 时 frame 还没定,排布起点取决于可视区尺寸(竖排看高度、横排看宽度),
    // 控制器定完 frame 后这里按最新尺寸重排一次,首秀和旋转都靠这一步纠正。
    CGFloat axisLength = self.horizontalLayout
        ? CGRectGetWidth(self.bounds)
        : CGRectGetHeight(self.bounds);
    if (axisLength != lastLayoutAxisLength) {
        [self layoutTiles];
    }
    CGFloat sideInset = [self sideSwitchVisible] ? tileSide + PO_APP_RAIL_TILE_GAP : 0;
    // 竖排与悬浮网格都在高度方向滚动(网格宽度折行后不超可视区宽)。
    self.scrollEnabled = self.contentSize.height + sideInset > CGRectGetHeight(self.bounds) + 0.5;
    // 悬浮网格的毛玻璃底衬只在该形态显示;bounds.origin 随滚动变化,
    // 按可视区取框让底衬始终铺满可视区而不随内容滚动。
    gridBackdropView.hidden = !self.horizontalLayout;
    gridBackdropView.frame = self.bounds;
    // 悬浮网格不显示换边按钮,隐藏后触摸也不会命中。
    BOOL sideSwitchVisible = [self sideSwitchVisible];
    sideSwitchButton.hidden = !sideSwitchVisible;
    if (sideSwitchButton && sideSwitchVisible) {
        // bounds.origin 随滚动变化,按其最大 Y 取框让按钮始终钉在可视区底部。
        sideSwitchButton.frame = CGRectMake(0, CGRectGetMaxY(self.bounds) - tileSide, tileSide, tileSide);
    }
}

// 整窗在左手模式下水平镜像,栏内图标统一反向镜像抵消,屏幕上才显示正向原图。
- (CGAffineTransform)iconLayoutTransform {
    return [[POApplicationHelper settings][@"leftHanded"] boolValue]
        ? CGAffineTransformMakeScale(-1.0, 1.0)
        : CGAffineTransformIdentity;
}

- (void)refreshLayoutDirection {
    CGAffineTransform iconTransform = [self iconLayoutTransform];
    for (POAppRailTile *tile in tiles) {
        tile.iconView.transform = iconTransform;
    }
}

- (BOOL)isInteracting {
    UIGestureRecognizerState panState = railPanGestureRecognizer.state;
    UIGestureRecognizerState longPressState = railLongPressGestureRecognizer.state;
    return panState == UIGestureRecognizerStateBegan ||
        panState == UIGestureRecognizerStateChanged ||
        longPressState == UIGestureRecognizerStateBegan ||
        longPressState == UIGestureRecognizerStateChanged;
}

- (UIView *)longPressAnchorViewForRecognizer:(UILongPressGestureRecognizer *)recognizer {
    CGPoint point = [recognizer locationInView:self];
    POAppRailTile *nearest = nil;
    CGFloat nearestDistance = CGFLOAT_MAX;
    for (POAppRailTile *tile in tiles) {
        // 网格多排共用列,按瓦片中心到落点的二维距离就近命中,竖排单列也适用。
        CGFloat dx = CGRectGetMidX(tile.frame) - point.x;
        CGFloat dy = CGRectGetMidY(tile.frame) - point.y;
        CGFloat distance = dx * dx + dy * dy;
        if (distance < nearestDistance) {
            nearestDistance = distance;
            nearest = tile;
        }
    }
    return nearest ?: (UIView *)self;
}

- (void)tileTapped:(UITapGestureRecognizer *)recognizer {
    POAppRailTile *tile = (POAppRailTile *)recognizer.view;
    if (![tile isKindOfClass:[POAppRailTile class]] || tile.bundleId.length == 0) {
        return;
    }
    if (hapticsEnabled) {
        [impactGenerator impactOccurred];
    }
    [self.railDelegate appRailView:self didTapBundleId:tile.bundleId];
}

- (void)sideSwitchTapped:(UITapGestureRecognizer *)recognizer {
    if (hapticsEnabled) {
        [impactGenerator impactOccurred];
    }
    [self.railDelegate appRailViewDidTapSideSwitch:self];
}

- (void)railPan:(UIPanGestureRecognizer *)recognizer {
    [self.railDelegate appRailView:self didReceivePan:recognizer];
}

- (void)railLongPress:(UILongPressGestureRecognizer *)recognizer {
    [self.railDelegate appRailView:self didReceiveLongPress:recognizer];
}

- (BOOL)gestureRecognizerShouldBegin:(UIGestureRecognizer *)gestureRecognizer {
    if (gestureRecognizer == railPanGestureRecognizer) {
        // 横排时横向拖拽是列表自身的滚动,驱动小窗开合的转发手势不再接管。
        if (self.horizontalLayout) {
            return NO;
        }
        CGPoint velocity = [railPanGestureRecognizer velocityInView:self];
        return fabs(velocity.x) > fabs(velocity.y);
    }
    return YES;
}

- (BOOL)gestureRecognizer:(UIGestureRecognizer *)gestureRecognizer
    shouldRecognizeSimultaneouslyWithGestureRecognizer:(UIGestureRecognizer *)otherGestureRecognizer {
    // 横向拖拽交给 railPan 驱动小窗关闭,同时不妨碍内部列表的竖向滚动。
    if (gestureRecognizer == railPanGestureRecognizer &&
        otherGestureRecognizer == self.panGestureRecognizer) {
        return YES;
    }
    return NO;
}

@end
