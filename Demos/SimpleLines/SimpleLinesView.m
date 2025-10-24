#import "SimpleLinesView.h"

#import <AppKit/AppKit.h>

#import "ScreenSaverKit/SSKConfigurationWindowController.h"
#import "ScreenSaverKit/SSKDiagnostics.h"
#import "ScreenSaverKit/SSKPreferenceBinder.h"

static NSString * const kPrefLineCount     = @"simpleLineCount";
static NSString * const kPrefSpeed         = @"simpleLineSpeed";
static NSString * const kPrefPalette       = @"simpleLinePalette";
static NSString * const kPrefColorRate     = @"simpleLineColorRate";
static NSString * const kPrefTrailEnabled  = @"simpleLineTrails";

typedef struct {
    NSPoint position;
    NSPoint velocity;
    CGFloat depth;
    CGFloat paletteProgress;
    CGFloat trail;
} SimpleLineParticle;

static NSArray<NSDictionary<NSString *, id> *> *SimpleLinesPaletteDefinitions(void) {
    static NSArray<NSDictionary<NSString *, id> *> *palettes;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        palettes = @[
            @{
                @"title": @"Neon",
                @"value": @"neon",
                @"colors": @[
                    [NSColor colorWithHue:0.57 saturation:0.95 brightness:1.0 alpha:1.0],
                    [NSColor colorWithHue:0.82 saturation:0.85 brightness:1.0 alpha:1.0],
                    [NSColor colorWithHue:0.04 saturation:0.90 brightness:1.0 alpha:1.0]
                ]
            },
            @{
                @"title": @"Sunset",
                @"value": @"sunset",
                @"colors": @[
                    [NSColor colorWithHue:0.02 saturation:0.90 brightness:0.95 alpha:1.0],
                    [NSColor colorWithHue:0.10 saturation:0.85 brightness:0.92 alpha:1.0],
                    [NSColor colorWithHue:0.63 saturation:0.40 brightness:0.90 alpha:1.0]
                ]
            },
            @{
                @"title": @"Ocean",
                @"value": @"ocean",
                @"colors": @[
                    [NSColor colorWithHue:0.55 saturation:0.60 brightness:0.90 alpha:1.0],
                    [NSColor colorWithHue:0.48 saturation:0.70 brightness:0.85 alpha:1.0],
                    [NSColor colorWithHue:0.58 saturation:0.35 brightness:0.95 alpha:1.0]
                ]
            },
            @{
                @"title": @"Monochrome",
                @"value": @"mono",
                @"colors": @[
                    [NSColor colorWithCalibratedWhite:0.85 alpha:1.0],
                    [NSColor colorWithCalibratedWhite:0.60 alpha:1.0],
                    [NSColor colorWithCalibratedWhite:1.0 alpha:1.0]
                ]
            }
        ];
    });
    return palettes;
}

static NSArray<NSColor *> *SimpleLinesColorsForIdentifier(NSString *identifier) {
    for (NSDictionary<NSString *, id> *palette in SimpleLinesPaletteDefinitions()) {
        if ([palette[@"value"] isEqualToString:identifier]) {
            return palette[@"colors"];
        }
    }
    NSDictionary<NSString *, id> *fallback = SimpleLinesPaletteDefinitions().firstObject;
    return fallback ? fallback[@"colors"] : @[ [NSColor whiteColor] ];
}

static NSString *SimpleLinesFallbackPaletteIdentifier(void) {
    NSDictionary<NSString *, id> *palette = SimpleLinesPaletteDefinitions().firstObject;
    return palette[@"value"] ?: @"neon";
}

static NSColor *SimpleLinesColorForProgress(NSArray<NSColor *> *colors, CGFloat progress) {
    if (colors.count == 0) {
        return [NSColor whiteColor];
    }
    if (colors.count == 1) {
        return colors.firstObject;
    }
    CGFloat wrapped = progress - floor(progress);
    CGFloat scaled = wrapped * (CGFloat)colors.count;
    NSInteger index = (NSInteger)floor(scaled);
    CGFloat blendFraction = scaled - (CGFloat)index;
    NSColor *first = colors[(NSUInteger)index % colors.count];
    NSColor *second = colors[(NSUInteger)(index + 1) % colors.count];
    return [first blendedColorWithFraction:blendFraction ofColor:second];
}

@interface SimpleLinesView ()
@property (nonatomic) NSMutableArray<NSValue *> *particles;
@property (nonatomic) NSInteger lineCount;
@property (nonatomic) CGFloat speedMultiplier;
@property (nonatomic) CGFloat colorRate;
@property (nonatomic) BOOL trailsEnabled;
@property (nonatomic, copy) NSString *paletteIdentifier;
@property (nonatomic, strong) SSKConfigurationWindowController *configController;

- (void)applyPreferences:(NSDictionary<NSString *, id> *)preferences
             changedKeys:(nullable NSSet<NSString *> *)changedKeys;
@end

@implementation SimpleLinesView

- (NSDictionary<NSString *,id> *)defaultPreferences {
    return @{
        kPrefLineCount: @(220),
        kPrefSpeed: @(1.0),
        kPrefPalette: SimpleLinesFallbackPaletteIdentifier(),
        kPrefColorRate: @(0.12),
        kPrefTrailEnabled: @(YES)
    };
}

- (instancetype)initWithFrame:(NSRect)frame isPreview:(BOOL)isPreview {
    if ((self = [super initWithFrame:frame isPreview:isPreview])) {
        self.animationTimeInterval = 1.0 / 60.0;
        _particles = [NSMutableArray array];
        NSDictionary *prefs = [self currentPreferences];
        NSSet *allKeys = [NSSet setWithArray:prefs.allKeys];
        [self applyPreferences:prefs changedKeys:allKeys];
        [self rebuildLines];
    }
    return self;
}

- (BOOL)isOpaque {
    return YES;
}

- (void)setFrame:(NSRect)frame {
    [super setFrame:frame];
    [self rebuildLines];
}

- (void)animateOneFrame {
    NSTimeInterval dt = [self advanceAnimationClock];
    if (dt <= 0) { dt = 1.0 / 60.0; }
    [self updateLinesWithDelta:dt];
    [self setNeedsDisplay:YES];
}

- (void)drawRect:(NSRect)dirtyRect {
    [[NSColor blackColor] setFill];
    NSRectFill(dirtyRect);

    CGContextRef ctx = [[NSGraphicsContext currentContext] CGContext];
    if (!ctx) { return; }

    NSArray<NSColor *> *palette = SimpleLinesColorsForIdentifier(self.paletteIdentifier);
    CGSize size = self.bounds.size;
    CGFloat centerX = size.width * 0.5;
    CGFloat centerY = size.height * 0.5;

    CGContextSetLineCap(ctx, kCGLineCapRound);

    for (NSValue *value in self.particles) {
        SimpleLineParticle particle;
        [value getValue:&particle];

        CGFloat depthFactor = 1.0 / MAX(0.05, particle.depth);
        CGFloat speedScale = depthFactor * self.speedMultiplier;

        CGFloat x = (particle.position.x - centerX) * depthFactor + centerX;
        CGFloat y = (particle.position.y - centerY) * depthFactor + centerY;
        CGFloat radius = 1.0 * depthFactor + 0.35;

        NSColor *color = SimpleLinesColorForProgress(palette, particle.paletteProgress);
        CGContextSetFillColorWithColor(ctx, color.CGColor);
        CGContextFillEllipseInRect(ctx, CGRectMake(x - radius, y - radius, radius * 2.0, radius * 2.0));

        CGFloat trailLength = particle.trail * speedScale * 0.45;
        if (self.trailsEnabled && trailLength > 0.0) {
            CGFloat tailX = x - particle.velocity.x * trailLength;
            CGFloat tailY = y - particle.velocity.y * trailLength;
            NSColor *tail = [color colorWithAlphaComponent:0.4];
            CGContextSetStrokeColorWithColor(ctx, tail.CGColor);
            CGContextSetLineWidth(ctx, MAX(0.6, radius * 0.6));
            CGContextMoveToPoint(ctx, x, y);
            CGContextAddLineToPoint(ctx, tailX, tailY);
            CGContextStrokePath(ctx);
        }
    }

    [SSKDiagnostics drawOverlayInView:self
                                text:@"Simple Lines Demo"
                     framesPerSecond:self.animationClock.framesPerSecond];
}

- (void)updateLinesWithDelta:(NSTimeInterval)dt {
    NSRect bounds = self.bounds;
    CGFloat width = NSWidth(bounds);
    CGFloat height = NSHeight(bounds);
    CGFloat centerX = NSMidX(bounds);
    CGFloat centerY = NSMidY(bounds);

    for (NSUInteger i = 0; i < self.particles.count; i++) {
        SimpleLineParticle particle;
        [self.particles[i] getValue:&particle];

        CGFloat depthFactor = 1.0 / MAX(0.05, particle.depth);
        CGFloat speedScale = depthFactor * self.speedMultiplier;

        particle.position.x += particle.velocity.x * speedScale * dt;
        particle.position.y += particle.velocity.y * speedScale * dt;
        particle.trail = MIN(140.0, particle.trail + dt * 90.0);

        if (self.colorRate > 0.0) {
            particle.paletteProgress += dt * self.colorRate * (0.6 + depthFactor * 0.4);
            particle.paletteProgress -= floor(particle.paletteProgress);
        }

        BOOL needsReset = (particle.position.x < -width * 0.25) || (particle.position.x > width * 1.25) ||
                          (particle.position.y < -height * 0.25) || (particle.position.y > height * 1.25);
        if (needsReset) {
            particle.depth = ((CGFloat)arc4random() / UINT32_MAX) * 0.9 + 0.1;
            particle.position = NSMakePoint(centerX + (((CGFloat)arc4random() / UINT32_MAX) - 0.5) * 80.0,
                                            centerY + (((CGFloat)arc4random() / UINT32_MAX) - 0.5) * 80.0);
            CGFloat angle = ((CGFloat)arc4random() / UINT32_MAX) * (CGFloat)M_PI * 2.0;
            particle.velocity = NSMakePoint(cos(angle), sin(angle));
            particle.trail = arc4random_uniform(60);
            particle.paletteProgress = ((CGFloat)arc4random() / UINT32_MAX);
        }

        self.particles[i] = [NSValue valueWithBytes:&particle objCType:@encode(SimpleLineParticle)];
    }
}

- (void)rebuildLines {
    if (!self.particles) {
        self.particles = [NSMutableArray array];
    } else {
        [self.particles removeAllObjects];
    }
    NSInteger count = MAX(50, self.lineCount);
    NSRect bounds = self.bounds;
    CGFloat centerX = NSMidX(bounds);
    CGFloat centerY = NSMidY(bounds);

    for (NSInteger i = 0; i < count; i++) {
        SimpleLineParticle particle;
        particle.depth = ((CGFloat)arc4random() / UINT32_MAX) * 0.9 + 0.1;
        particle.position = NSMakePoint(centerX + (((CGFloat)arc4random() / UINT32_MAX) - 0.5) * NSWidth(bounds),
                                        centerY + (((CGFloat)arc4random() / UINT32_MAX) - 0.5) * NSHeight(bounds));
        CGFloat angle = ((CGFloat)arc4random() / UINT32_MAX) * (CGFloat)M_PI * 2.0;
        particle.velocity = NSMakePoint(cos(angle), sin(angle));
        particle.paletteProgress = ((CGFloat)arc4random() / UINT32_MAX);
        particle.trail = arc4random_uniform(60);
        [self.particles addObject:[NSValue valueWithBytes:&particle objCType:@encode(SimpleLineParticle)]];
    }
}

- (void)preferencesDidChange:(NSDictionary<NSString *,id> *)preferences
                 changedKeys:(NSSet<NSString *> *)changedKeys {
    [self applyPreferences:preferences changedKeys:changedKeys];
}

- (void)applyPreferences:(NSDictionary<NSString *,id> *)preferences
             changedKeys:(NSSet<NSString *> *)changedKeys {
    NSDictionary *defaults = [self defaultPreferences];

    NSInteger newCount = [preferences[kPrefLineCount] respondsToSelector:@selector(integerValue)] ?
        [preferences[kPrefLineCount] integerValue] :
        [defaults[kPrefLineCount] integerValue];

    self.speedMultiplier = [preferences[kPrefSpeed] respondsToSelector:@selector(doubleValue)] ?
        [preferences[kPrefSpeed] doubleValue] :
        [defaults[kPrefSpeed] doubleValue];

    self.colorRate = [preferences[kPrefColorRate] respondsToSelector:@selector(doubleValue)] ?
        [preferences[kPrefColorRate] doubleValue] :
        [defaults[kPrefColorRate] doubleValue];

    NSString *paletteValue = [preferences[kPrefPalette] isKindOfClass:[NSString class]] ?
        preferences[kPrefPalette] : defaults[kPrefPalette];
    if (![paletteValue isKindOfClass:[NSString class]] || paletteValue.length == 0) {
        paletteValue = SimpleLinesFallbackPaletteIdentifier();
    }
    self.paletteIdentifier = paletteValue;

    self.trailsEnabled = [preferences[kPrefTrailEnabled] respondsToSelector:@selector(boolValue)] ?
        [preferences[kPrefTrailEnabled] boolValue] :
        [defaults[kPrefTrailEnabled] boolValue];

    NSInteger previousCount = self.lineCount;
    BOOL lineCountDirty = (newCount != previousCount);
    if (changedKeys && [changedKeys containsObject:kPrefLineCount]) {
        lineCountDirty = YES;
    }
    self.lineCount = newCount;

    if (lineCountDirty) {
        [self rebuildLines];
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
                                                                                   title:@"Simple Lines"
                                                                                subtitle:@"Flowing streaks with layered colour palettes."];
    SSKPreferenceBinder *binder = self.configController.preferenceBinder;
    NSStackView *stack = self.configController.contentStack;

    [stack addArrangedSubview:[self sliderRowWithTitle:@"Line Count"
                                             minValue:50
                                             maxValue:600
                                                  key:kPrefLineCount
                                               format:@"%.0f"
                                                binder:binder]];

    [stack addArrangedSubview:[self sliderRowWithTitle:@"Speed"
                                             minValue:0.2
                                             maxValue:3.0
                                                  key:kPrefSpeed
                                               format:@"%.2fx"
                                                binder:binder]];

    [stack addArrangedSubview:[self sliderRowWithTitle:@"Colour Change Rate"
                                             minValue:0.0
                                             maxValue:1.0
                                                  key:kPrefColorRate
                                               format:@"%.2fx"
                                                binder:binder]];

    [stack addArrangedSubview:[self popUpRowWithTitle:@"Colour Palette"
                                                 key:kPrefPalette
                                              binder:binder]];

    NSButton *trailToggle = [NSButton checkboxWithTitle:@"Enable trailing lines" target:nil action:nil];
    [binder bindCheckbox:trailToggle key:kPrefTrailEnabled];
    [stack addArrangedSubview:trailToggle];
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

- (NSView *)popUpRowWithTitle:(NSString *)title
                          key:(NSString *)key
                       binder:(SSKPreferenceBinder *)binder {
    NSTextField *label = [NSTextField labelWithString:title];
    label.font = [NSFont systemFontOfSize:12 weight:NSFontWeightRegular];
    [label setContentHuggingPriority:NSLayoutPriorityDefaultHigh
                       forOrientation:NSLayoutConstraintOrientationHorizontal];

    NSPopUpButton *popUp = [[NSPopUpButton alloc] initWithFrame:NSZeroRect pullsDown:NO];
    popUp.translatesAutoresizingMaskIntoConstraints = NO;
    [popUp removeAllItems];

    for (NSDictionary<NSString *, id> *palette in SimpleLinesPaletteDefinitions()) {
        NSString *itemTitle = palette[@"title"] ?: @"Palette";
        [popUp addItemWithTitle:itemTitle];
        NSMenuItem *item = [popUp itemAtIndex:popUp.numberOfItems - 1];
        item.representedObject = palette[@"value"];
    }

    NSStackView *row = [[NSStackView alloc] initWithFrame:NSZeroRect];
    row.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    row.spacing = 8;
    row.alignment = NSLayoutAttributeCenterY;
    [row addArrangedSubview:label];
    [row addArrangedSubview:popUp];

    [binder bindPopUpButton:popUp key:key];
    return row;
}

@end
