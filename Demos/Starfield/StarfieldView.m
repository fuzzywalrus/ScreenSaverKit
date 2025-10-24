#import "StarfieldView.h"

#import <AppKit/AppKit.h>

#import "ScreenSaverKit/SSKConfigurationWindowController.h"
#import "ScreenSaverKit/SSKDiagnostics.h"
#import "ScreenSaverKit/SSKPreferenceBinder.h"

static NSString * const kPrefStarCount          = @"classicStarCount";
static NSString * const kPrefSpeed              = @"classicStarSpeed";
static NSString * const kPrefFieldOfView        = @"classicStarFieldOfView";
static NSString * const kPrefMotionBlur         = @"classicStarMotionBlur";
static NSString * const kPrefBlurAmount         = @"classicStarBlurAmount";
static NSString * const kPrefDirectionShifts    = @"classicStarDirectionShifts";
static NSString * const kPrefStarSize           = @"classicStarSize";

typedef struct {
    float x;
    float y;
    float z;
    float prevX;
    float prevY;
    float prevZ;
} ClassicStar;

@interface StarfieldView ()
@property (nonatomic) NSMutableArray<NSValue *> *stars; // stores ClassicStar structs
@property (nonatomic) NSInteger starCount;
@property (nonatomic) CGFloat speedMultiplier;
@property (nonatomic) CGFloat fieldOfView;
@property (nonatomic) CGFloat blurAmount;
@property (nonatomic) CGFloat starSize;
@property (nonatomic) BOOL motionBlurEnabled;
@property (nonatomic) BOOL directionShiftsEnabled;
@property (nonatomic) NSPoint directionVector;
@property (nonatomic) NSPoint targetDirectionVector;
@property (nonatomic) NSTimeInterval timeUntilNextDirectionShift;
@property (nonatomic, strong) SSKConfigurationWindowController *configController;

- (void)applyPreferences:(NSDictionary<NSString *, id> *)preferences
             changedKeys:(nullable NSSet<NSString *> *)changedKeys;
@end

@implementation StarfieldView

- (NSDictionary<NSString *,id> *)defaultPreferences {
    return @{
        kPrefStarCount: @(320),
        kPrefSpeed: @(1.4),
        kPrefFieldOfView: @(1.35),
        kPrefMotionBlur: @(YES),
        kPrefBlurAmount: @(0.65),
        kPrefDirectionShifts: @(YES),
        kPrefStarSize: @(0.25)
    };
}

- (instancetype)initWithFrame:(NSRect)frame isPreview:(BOOL)isPreview {
    if ((self = [super initWithFrame:frame isPreview:isPreview])) {
        self.animationTimeInterval = 1.0 / 60.0;
        _directionVector = NSZeroPoint;
        _targetDirectionVector = NSZeroPoint;
        _timeUntilNextDirectionShift = 0.0;
        NSDictionary *prefs = [self currentPreferences];
        NSSet *allKeys = [NSSet setWithArray:prefs.allKeys];
        [self applyPreferences:prefs changedKeys:allKeys];
        [self rebuildStars];
    }
    return self;
}

- (BOOL)isOpaque {
    return YES;
}

- (void)setFrame:(NSRect)frame {
    [super setFrame:frame];
    [self rebuildStars];
}

- (void)animateOneFrame {
    NSTimeInterval dt = [self advanceAnimationClock];
    if (dt <= 0) { dt = 1.0 / 60.0; }

    [self updateDirectionVectorWithDelta:dt];
    [self updateStarsWithDelta:dt];

    [self setNeedsDisplay:YES];
}

- (void)drawRect:(NSRect)dirtyRect {
    [[NSColor blackColor] setFill];
    NSRectFill(dirtyRect);

    CGContextRef ctx = [[NSGraphicsContext currentContext] CGContext];
    if (!ctx) { return; }

    CGSize size = self.bounds.size;
    CGFloat centerX = size.width * 0.5;
    CGFloat centerY = size.height * 0.5;
    CGFloat aspect = (size.height == 0) ? 1.0 : (size.width / size.height);
    CGFloat fov = MAX(0.5, self.fieldOfView);

    CGContextSetLineCap(ctx, kCGLineCapRound);

    for (NSValue *value in self.stars) {
        ClassicStar star;
        [value getValue:&star];

        NSPoint prevPoint = [self projectStarWithX:star.prevX y:star.prevY z:star.prevZ centerX:centerX centerY:centerY aspect:aspect fov:fov];
        NSPoint currentPoint = [self projectStarWithX:star.x y:star.y z:star.z centerX:centerX centerY:centerY aspect:aspect fov:fov];

        if (!NSPointInRect(currentPoint, NSInsetRect(self.bounds, -50.0, -50.0)) ||
            star.z <= 0.02f) {
            continue;
        }

        CGFloat inverseDepth = 1.0 / MAX(0.2f, star.z);
        CGFloat radius = (self.isPreview ? 1.3 : 1.8);
        radius += inverseDepth * 7.0;
        radius *= MAX(0.1, self.starSize);

        CGFloat brightness = MIN(1.0, 0.25 + inverseDepth * 1.8);
        NSColor *color = [NSColor colorWithCalibratedWhite:brightness alpha:1.0];
        CGContextSetFillColorWithColor(ctx, color.CGColor);
        CGContextFillEllipseInRect(ctx, CGRectMake(currentPoint.x - radius,
                                                   currentPoint.y - radius,
                                                   radius * 2.0,
                                                   radius * 2.0));

        if (self.motionBlurEnabled && self.blurAmount > 0.01) {
            CGFloat blurFactor = MIN(1.5, MAX(0.0, self.blurAmount));
            NSPoint tailPoint = NSMakePoint(currentPoint.x + (prevPoint.x - currentPoint.x) * blurFactor,
                                            currentPoint.y + (prevPoint.y - currentPoint.y) * blurFactor);
            NSColor *tailColor = [color colorWithAlphaComponent:0.55];
            CGContextSetStrokeColorWithColor(ctx, tailColor.CGColor);
            CGContextSetLineWidth(ctx, MAX(0.6, radius * 0.6));
            CGContextMoveToPoint(ctx, currentPoint.x, currentPoint.y);
            CGContextAddLineToPoint(ctx, tailPoint.x, tailPoint.y);
            CGContextStrokePath(ctx);
        }
    }

    [SSKDiagnostics drawOverlayInView:self
                                text:@"Starfield Demo"
                     framesPerSecond:self.animationClock.framesPerSecond];
}

#pragma mark - Simulation

- (void)updateStarsWithDelta:(NSTimeInterval)dt {
    CGFloat speed = MAX(0.05, self.speedMultiplier);
    CGFloat depthVelocity = speed * dt;

    for (NSUInteger i = 0; i < self.stars.count; i++) {
        ClassicStar star;
        [self.stars[i] getValue:&star];

        star.prevX = star.x;
        star.prevY = star.y;
        star.prevZ = star.z;

        star.z -= depthVelocity;
        star.x += self.directionVector.x * depthVelocity * 0.75f;
        star.y += self.directionVector.y * depthVelocity * 0.75f;

        BOOL needsReset = (star.z <= 0.15f) ||
                          (fabs(star.x) > 2.5f) ||
                          (fabs(star.y) > 2.5f);

        if (needsReset) {
            star = [self randomStar];
        }

        self.stars[i] = [NSValue valueWithBytes:&star objCType:@encode(ClassicStar)];
    }
}

- (void)updateDirectionVectorWithDelta:(NSTimeInterval)dt {
    if (!self.directionShiftsEnabled) {
        self.directionVector = NSZeroPoint;
        self.targetDirectionVector = NSZeroPoint;
        self.timeUntilNextDirectionShift = 0.0;
        return;
    }

    self.timeUntilNextDirectionShift -= dt;
    if (self.timeUntilNextDirectionShift <= 0.0) {
        CGFloat angle = ((CGFloat)arc4random() / UINT32_MAX) * (CGFloat)M_PI * 2.0;
        CGFloat magnitude = 0.2f + ((CGFloat)arc4random() / UINT32_MAX) * 0.45f;
        self.targetDirectionVector = NSMakePoint(cos(angle) * magnitude,
                                                 sin(angle) * magnitude * 0.75f);
        self.timeUntilNextDirectionShift = 2.5 + ((CGFloat)arc4random() / UINT32_MAX) * 3.0;
    }

    CGFloat lerpSpeed = MIN(1.0, dt * 1.5);
    self.directionVector = NSMakePoint(self.directionVector.x + (self.targetDirectionVector.x - self.directionVector.x) * lerpSpeed,
                                       self.directionVector.y + (self.targetDirectionVector.y - self.directionVector.y) * lerpSpeed);
}

- (ClassicStar)randomStar {
    ClassicStar star;
    CGFloat angle = ((CGFloat)arc4random() / UINT32_MAX) * (CGFloat)M_PI * 2.0;
    CGFloat radius = sqrt(((CGFloat)arc4random() / UINT32_MAX)) * 1.6f;
    star.x = cos(angle) * radius;
    star.y = sin(angle) * radius;
    star.z = 1.0f + ((CGFloat)arc4random() / UINT32_MAX) * 1.9f;
    star.prevX = star.x;
    star.prevY = star.y;
    star.prevZ = star.z;
    return star;
}

- (void)rebuildStars {
    if (!self.stars) {
        self.stars = [NSMutableArray array];
    } else {
        [self.stars removeAllObjects];
    }
    NSInteger count = MAX(50, self.starCount);
    for (NSInteger i = 0; i < count; i++) {
        ClassicStar star = [self randomStar];
        [self.stars addObject:[NSValue valueWithBytes:&star objCType:@encode(ClassicStar)]];
    }
}

- (NSPoint)projectStarWithX:(float)x
                          y:(float)y
                          z:(float)z
                     centerX:(CGFloat)centerX
                     centerY:(CGFloat)centerY
                      aspect:(CGFloat)aspect
                         fov:(CGFloat)fov {
    CGFloat safeZ = MAX(0.05f, z);
    CGFloat depthScale = fov / safeZ;
    CGFloat horizontalScale = depthScale * aspect * 0.5;
    CGFloat verticalScale = depthScale * 0.5;
    CGFloat projectedX = centerX + (CGFloat)x * horizontalScale * centerX;
    CGFloat projectedY = centerY + (CGFloat)y * verticalScale * centerY;
    return NSMakePoint(projectedX, projectedY);
}

#pragma mark - Preferences

- (void)preferencesDidChange:(NSDictionary<NSString *,id> *)preferences
                 changedKeys:(NSSet<NSString *> *)changedKeys {
    [self applyPreferences:preferences changedKeys:changedKeys];
}

- (void)applyPreferences:(NSDictionary<NSString *,id> *)preferences
             changedKeys:(nullable NSSet<NSString *> *)changedKeys {
    NSDictionary *defaults = [self defaultPreferences];

    NSInteger newCount = [preferences[kPrefStarCount] respondsToSelector:@selector(integerValue)] ?
        [preferences[kPrefStarCount] integerValue] :
        [defaults[kPrefStarCount] integerValue];

    self.speedMultiplier = [preferences[kPrefSpeed] respondsToSelector:@selector(doubleValue)] ?
        [preferences[kPrefSpeed] doubleValue] :
        [defaults[kPrefSpeed] doubleValue];

    self.fieldOfView = [preferences[kPrefFieldOfView] respondsToSelector:@selector(doubleValue)] ?
        [preferences[kPrefFieldOfView] doubleValue] :
        [defaults[kPrefFieldOfView] doubleValue];

    self.motionBlurEnabled = [preferences[kPrefMotionBlur] respondsToSelector:@selector(boolValue)] ?
        [preferences[kPrefMotionBlur] boolValue] :
        [defaults[kPrefMotionBlur] boolValue];

    self.blurAmount = [preferences[kPrefBlurAmount] respondsToSelector:@selector(doubleValue)] ?
        [preferences[kPrefBlurAmount] doubleValue] :
        [defaults[kPrefBlurAmount] doubleValue];

    self.directionShiftsEnabled = [preferences[kPrefDirectionShifts] respondsToSelector:@selector(boolValue)] ?
        [preferences[kPrefDirectionShifts] boolValue] :
        [defaults[kPrefDirectionShifts] boolValue];

    double sizeSetting = [preferences[kPrefStarSize] respondsToSelector:@selector(doubleValue)] ?
        [preferences[kPrefStarSize] doubleValue] :
        [defaults[kPrefStarSize] doubleValue];
    self.starSize = MAX(0.1, sizeSetting);

    NSInteger previousCount = self.starCount;
    BOOL starCountDirty = (newCount != previousCount);
    if (changedKeys && [changedKeys containsObject:kPrefStarCount]) {
        starCountDirty = YES;
    }
    self.starCount = newCount;

    if (starCountDirty) {
        [self rebuildStars];
    }
}

- (BOOL)hasConfigureSheet {
    return YES;
}

- (NSWindow *)configureSheet {
    [self ensureConfigController];
    [self.configController prepareForPresentation];
    return self.configController.window;
}

- (void)ensureConfigController {
    if (self.configController) { return; }

    self.configController = [[SSKConfigurationWindowController alloc] initWithSaverView:self
                                                                                   title:@"Classic Starfield"
                                                                                subtitle:@"Fly through space with adjustable depth effects."];
    SSKPreferenceBinder *binder = self.configController.preferenceBinder;
    NSStackView *stack = self.configController.contentStack;

    [stack addArrangedSubview:[self sliderRowWithTitle:@"Star Count"
                                             minValue:80
                                             maxValue:900
                                                  key:kPrefStarCount
                                               format:@"%.0f"
                                                binder:binder]];

    [stack addArrangedSubview:[self sliderRowWithTitle:@"Speed"
                                             minValue:0.4
                                             maxValue:4.0
                                                  key:kPrefSpeed
                                               format:@"%.2fx"
                                                binder:binder]];

    [stack addArrangedSubview:[self sliderRowWithTitle:@"Field of View"
                                             minValue:0.7
                                             maxValue:2.2
                                                  key:kPrefFieldOfView
                                               format:@"%.2f"
                                                binder:binder]];

    [stack addArrangedSubview:[self sliderRowWithTitle:@"Star Size"
                                             minValue:0.1
                                             maxValue:3.0
                                                  key:kPrefStarSize
                                               format:@"%.2fx"
                                                binder:binder]];

    [stack addArrangedSubview:[self sliderRowWithTitle:@"Motion Blur Length"
                                             minValue:0.0
                                             maxValue:1.5
                                                  key:kPrefBlurAmount
                                               format:@"%.2f"
                                                binder:binder]];

    NSButton *motionBlurToggle = [NSButton checkboxWithTitle:@"Enable motion blur" target:nil action:nil];
    [binder bindCheckbox:motionBlurToggle key:kPrefMotionBlur];
    [stack addArrangedSubview:motionBlurToggle];

    NSButton *directionToggle = [NSButton checkboxWithTitle:@"Enable direction shifts" target:nil action:nil];
    [binder bindCheckbox:directionToggle key:kPrefDirectionShifts];
    [stack addArrangedSubview:directionToggle];
}

- (NSView *)sliderRowWithTitle:(NSString *)title
                      minValue:(double)min
                      maxValue:(double)max
                           key:(NSString *)key
                        format:(NSString *)format
                         binder:(SSKPreferenceBinder *)binder {
    NSTextField *label = [NSTextField labelWithString:title];
    label.font = [NSFont systemFontOfSize:12 weight:NSFontWeightRegular];
    [label setContentHuggingPriority:NSLayoutPriorityDefaultHigh
                       forOrientation:NSLayoutConstraintOrientationHorizontal];

    NSSlider *slider = [[NSSlider alloc] initWithFrame:NSZeroRect];
    slider.minValue = min;
    slider.maxValue = max;
    slider.continuous = YES;

    NSTextField *valueLabel = [NSTextField labelWithString:@"--"];
    valueLabel.font = [NSFont monospacedDigitSystemFontOfSize:12 weight:NSFontWeightMedium];

    NSStackView *row = [[NSStackView alloc] initWithFrame:NSZeroRect];
    row.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    row.spacing = 8;
    row.alignment = NSLayoutAttributeCenterY;
    [row addArrangedSubview:label];
    [row addArrangedSubview:slider];
    [row addArrangedSubview:valueLabel];

    [binder bindSlider:slider key:key valueLabel:valueLabel format:format];
    return row;
}

@end
