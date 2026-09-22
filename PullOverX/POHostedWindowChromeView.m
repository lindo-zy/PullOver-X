#import "POHostedWindowChromeView.h"

// chrome 自身只占用条内交互元素的热区,其余面积点穿给托管 App。
#define PO_CHROME_BAR_HEIGHT 30.0
#define PO_CHROME_COMPACT_BADGE_SIZE 30.0
#define PO_CHROME_BUTTON_SIZE 26.0
#define PO_CHROME_BUTTON_EDGE_INSET 3.0
#define PO_CHROME_CHIP_SIZE CGSizeMake(68.0, 18.0)
#define PO_CHROME_PILL_SIZE CGSizeMake(40.0, 5.0)

@interface POHostedWindowChromeView ()
@property (nonatomic, strong) UIButton *closeButton;
@property (nonatomic, strong) UIView *grabberChip;
@property (nonatomic, strong) UIView *grabberPill;
@end

@implementation POHostedWindowChromeView

+ (CGFloat)barHeight {
    return PO_CHROME_BAR_HEIGHT;
}

+ (CGFloat)compactBadgeSize {
    return PO_CHROME_COMPACT_BADGE_SIZE;
}

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        self.backgroundColor = [UIColor clearColor];

        _grabberChip = [[UIView alloc] initWithFrame:(CGRect){CGPointZero, PO_CHROME_CHIP_SIZE}];
        _grabberChip.layer.cornerRadius = PO_CHROME_CHIP_SIZE.height / 2.0;
        _grabberChip.backgroundColor = [UIColor colorWithWhite:0.0 alpha:0.34];
        _grabberChip.userInteractionEnabled = NO;
        [self addSubview:_grabberChip];

        _grabberPill = [[UIView alloc] initWithFrame:(CGRect){CGPointZero, PO_CHROME_PILL_SIZE}];
        _grabberPill.layer.cornerRadius = PO_CHROME_PILL_SIZE.height / 2.0;
        _grabberPill.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.88];
        _grabberPill.userInteractionEnabled = NO;
        [_grabberChip addSubview:_grabberPill];

        _closeButton = [UIButton buttonWithType:UIButtonTypeCustom];
        _closeButton.layer.cornerCurve = kCACornerCurveContinuous;
        _closeButton.backgroundColor = [UIColor colorWithWhite:0.10 alpha:0.62];
        _closeButton.tintColor = UIColor.whiteColor;
        UIImage *closeImage = [[UIImage systemImageNamed:@"xmark"]
            imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate];
        [_closeButton setImage:closeImage forState:UIControlStateNormal];
        _closeButton.accessibilityLabel = @"close";
        [_closeButton addTarget:self
                         action:@selector(closeButtonTapped)
               forControlEvents:UIControlEventTouchUpInside];
        [self addSubview:_closeButton];

        UIPanGestureRecognizer *movePan =
            [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(movePan:)];
        movePan.maximumNumberOfTouches = 1;
        [self addGestureRecognizer:movePan];

        self.mode = POHostedWindowChromeModeHidden;
    }
    return self;
}

- (void)setMode:(POHostedWindowChromeMode)mode {
    _mode = mode;
    self.grabberChip.hidden = mode != POHostedWindowChromeModeBar;
    [self setNeedsLayout];
}

- (void)layoutSubviews {
    [super layoutSubviews];
    CGFloat width = CGRectGetWidth(self.bounds);
    CGFloat height = CGRectGetHeight(self.bounds);
    if (width <= 0 || height <= 0) {
        return;
    }
    switch (self.mode) {
        case POHostedWindowChromeModeBar: {
            CGFloat buttonSize = PO_CHROME_BUTTON_SIZE;
            CGFloat buttonX = self.closeOnTrailingSide
                ? width - buttonSize - PO_CHROME_BUTTON_EDGE_INSET
                : PO_CHROME_BUTTON_EDGE_INSET;
            self.closeButton.frame = CGRectMake(buttonX,
                                                floor((height - buttonSize) / 2.0),
                                                buttonSize, buttonSize);
            self.closeButton.layer.cornerRadius = buttonSize / 2.0;
            CGRect chipFrame = CGRectMake(floor((width - PO_CHROME_CHIP_SIZE.width) / 2.0),
                                          floor((height - PO_CHROME_CHIP_SIZE.height) / 2.0),
                                          PO_CHROME_CHIP_SIZE.width, PO_CHROME_CHIP_SIZE.height);
            self.grabberChip.frame = chipFrame;
            self.grabberPill.frame = CGRectMake(floor((PO_CHROME_CHIP_SIZE.width - PO_CHROME_PILL_SIZE.width) / 2.0),
                                                floor((PO_CHROME_CHIP_SIZE.height - PO_CHROME_PILL_SIZE.height) / 2.0),
                                                PO_CHROME_PILL_SIZE.width, PO_CHROME_PILL_SIZE.height);
            break;
        }
        case POHostedWindowChromeModeCompact: {
            self.closeButton.frame = self.bounds;
            self.closeButton.layer.cornerRadius = MIN(width, height) / 2.0;
            self.grabberChip.frame = CGRectZero;
            break;
        }
        case POHostedWindowChromeModeHidden:
        default:
            break;
    }
}

// 只让关闭按钮与拖动胶囊热区拦截触摸,其余面积透传给下层的托管 Scene。
- (BOOL)pointInside:(CGPoint)point withEvent:(UIEvent *)event {
    CGRect hitRect = CGRectNull;
    if (self.mode == POHostedWindowChromeModeBar) {
        CGRect chipHot = CGRectInset(self.grabberChip.frame, -10.0, -8.0);
        CGRect buttonHot = CGRectInset(self.closeButton.frame, -5.0, -5.0);
        hitRect = CGRectUnion(chipHot, buttonHot);
    } else if (self.mode == POHostedWindowChromeModeCompact) {
        hitRect = CGRectInset(self.closeButton.frame, -4.0, -4.0);
    }
    if (CGRectIsNull(hitRect)) {
        return NO;
    }
    return CGRectContainsPoint(hitRect, point);
}

- (void)closeButtonTapped {
    if ([self.delegate respondsToSelector:@selector(hostedWindowChromeDidTapClose:)]) {
        [self.delegate hostedWindowChromeDidTapClose:self];
    }
}

- (void)movePan:(UIPanGestureRecognizer *)recognizer {
    if (self.mode != POHostedWindowChromeModeBar) {
        return;
    }
    if ([self.delegate respondsToSelector:@selector(hostedWindowChrome:didReceiveMovePan:)]) {
        [self.delegate hostedWindowChrome:self didReceiveMovePan:recognizer];
    }
}

@end
