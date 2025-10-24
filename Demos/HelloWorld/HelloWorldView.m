#import "HelloWorldView.h"

#import <AppKit/AppKit.h>

#import "ScreenSaverKit/SSKConfigurationWindowController.h"
#import "ScreenSaverKit/SSKDiagnostics.h"
#import "ScreenSaverKit/SSKPreferenceBinder.h"

static NSString * const kPrefSpeedMultiplier   = @"helloSpeed";
static NSString * const kPrefColorCycling      = @"helloColorCycling";
static NSString * const kPrefColorCycleSpeed   = @"helloColorCycleSpeed";

@interface HelloWorldView ()
@property (nonatomic) NSPoint position;
@property (nonatomic) NSPoint velocity;
@property (nonatomic) CGFloat hue;
@property (nonatomic) CGFloat hueSpeed;
@property (nonatomic) CGFloat speedMultiplier;
@property (nonatomic) BOOL colorCycling;
@property (nonatomic, strong) SSKConfigurationWindowController *configController;
@property (nonatomic) NSTimeInterval lastPreferenceRefresh;
@end

@implementation HelloWorldView

- (NSDictionary<NSString *,id> *)defaultPreferences {
    return @{
        kPrefSpeedMultiplier: @(1.0),
        kPrefColorCycling: @(YES),
        kPrefColorCycleSpeed: @(0.35)
    };
}

- (instancetype)initWithFrame:(NSRect)frame isPreview:(BOOL)isPreview {
    if ((self = [super initWithFrame:frame isPreview:isPreview])) {
        self.animationTimeInterval = 1.0 / 60.0;
        self.velocity = NSMakePoint(140.0, 120.0);
        self.hueSpeed = 0.35;
        self.colorCycling = YES;
        self.speedMultiplier = 1.0;
    }
    return self;
}

- (BOOL)isOpaque { return YES; }

- (void)animateOneFrame {
    [self refreshPreferencesIfNeeded];
    NSTimeInterval dt = [self advanceAnimationClock];
    if (dt <= 0) { dt = 1.0 / 60.0; }

    NSRect bounds = self.bounds;
    CGFloat halfWidth = 140.0;
    CGFloat halfHeight = 48.0;

    NSPoint pos = self.position;
    NSPoint vel = self.velocity;

    pos.x += vel.x * self.speedMultiplier * dt;
    pos.y += vel.y * self.speedMultiplier * dt;

    if (pos.x - halfWidth < NSMinX(bounds) || pos.x + halfWidth > NSMaxX(bounds)) {
        vel.x = -vel.x;
        pos.x = MIN(MAX(pos.x, NSMinX(bounds) + halfWidth), NSMaxX(bounds) - halfWidth);
    }
    if (pos.y - halfHeight < NSMinY(bounds) || pos.y + halfHeight > NSMaxY(bounds)) {
        vel.y = -vel.y;
        pos.y = MIN(MAX(pos.y, NSMinY(bounds) + halfHeight), NSMaxY(bounds) - halfHeight);
    }

    self.position = pos;
    self.velocity = vel;

    if (self.colorCycling) {
        self.hue += self.hueSpeed * dt;
        if (self.hue > 1.0) { self.hue -= floor(self.hue); }
    }

    [self setNeedsDisplay:YES];
}

- (void)drawRect:(NSRect)dirtyRect {
    [[NSColor blackColor] setFill];
    NSRectFill(dirtyRect);

    NSString *hello = @"Hello, World!";
    NSDictionary *attrs = @{
        NSFontAttributeName: [NSFont systemFontOfSize:48 weight:NSFontWeightBold],
        NSForegroundColorAttributeName: [NSColor whiteColor]
    };
    NSSize textSize = [hello sizeWithAttributes:attrs];
    NSRect textRect = NSMakeRect(self.position.x - textSize.width / 2.0,
                                  self.position.y - textSize.height / 2.0,
                                  textSize.width,
                                  textSize.height);

    NSColor *strokeColor = [NSColor colorWithHue:self.hue
                                      saturation:self.colorCycling ? 0.8 : 0.15
                                      brightness:1.0
                                           alpha:1.0];

    NSRect bubbleRect = NSInsetRect(textRect, -28, -18);
    NSBezierPath *rounded = [NSBezierPath bezierPathWithRoundedRect:bubbleRect xRadius:24 yRadius:24];
    [[strokeColor colorWithAlphaComponent:0.35] setFill];
    [rounded fill];

    [hello drawInRect:textRect withAttributes:attrs];

    [SSKDiagnostics drawOverlayInView:self
                                text:@"HelloWorld Demo"
                     framesPerSecond:self.animationClock.framesPerSecond];
}

- (void)preferencesDidChange:(NSDictionary<NSString *,id> *)preferences
                 changedKeys:(NSSet<NSString *> *)changedKeys {
    [self applyPreferencesDictionary:preferences];
    [SSKDiagnostics setEnabled:YES];
}

- (void)setFrame:(NSRect)frameRect {
    [super setFrame:frameRect];
    self.position = NSMakePoint(NSMidX(frameRect), NSMidY(frameRect));
}

- (BOOL)hasConfigureSheet { return YES; }

- (NSWindow *)configureSheet {
    [self ensureConfigurationController];
    [self.configController prepareForPresentation];
    return self.configController.window;
}

- (void)ensureConfigurationController {
    if (self.configController) { return; }
    self.configController = [[SSKConfigurationWindowController alloc] initWithSaverView:self
                                                                                   title:@"Hello World"
                                                                                subtitle:@"Tweak movement and colour cycling."];
    SSKPreferenceBinder *binder = self.configController.preferenceBinder;
    NSStackView *stack = self.configController.contentStack;

    [stack addArrangedSubview:[self sliderRowWithTitle:@"Speed Multiplier"
                                             minValue:0.2
                                             maxValue:3.0
                                                  key:kPrefSpeedMultiplier
                                               format:@"%.2fx"
                                                binder:binder]];

    NSButton *colorToggle = [NSButton checkboxWithTitle:@"Enable colour cycling" target:nil action:nil];
    [binder bindCheckbox:colorToggle key:kPrefColorCycling];
    [stack addArrangedSubview:colorToggle];

    [stack addArrangedSubview:[self sliderRowWithTitle:@"Colour Cycle Speed"
                                             minValue:0.1
                                             maxValue:2.0
                                                  key:kPrefColorCycleSpeed
                                               format:@"%.2f"
                                                binder:binder]];
}

- (NSView *)sliderRowWithTitle:(NSString *)title
                       minValue:(double)min
                       maxValue:(double)max
                            key:(NSString *)key
                         format:(NSString *)format
                          binder:(SSKPreferenceBinder *)binder {
    NSTextField *label = [NSTextField labelWithString:title];
    label.font = [NSFont systemFontOfSize:12 weight:NSFontWeightRegular];
    [label setContentHuggingPriority:NSLayoutPriorityDefaultHigh forOrientation:NSLayoutConstraintOrientationHorizontal];

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

- (void)refreshPreferencesIfNeeded {
    NSTimeInterval now = [NSDate timeIntervalSinceReferenceDate];
    if (now - self.lastPreferenceRefresh < 0.25) { return; }
    self.lastPreferenceRefresh = now;
    NSDictionary *current = [self currentPreferences];
    [self applyPreferencesDictionary:current];
}

- (void)applyPreferencesDictionary:(NSDictionary<NSString *, id> *)preferences {
    NSNumber *speed = preferences[kPrefSpeedMultiplier];
    if ([speed respondsToSelector:@selector(doubleValue)]) {
        self.speedMultiplier = MAX(0.05, [speed doubleValue]);
    }
    NSNumber *colorToggle = preferences[kPrefColorCycling];
    if ([colorToggle respondsToSelector:@selector(boolValue)]) {
        self.colorCycling = [colorToggle boolValue];
    }
    NSNumber *hueSpeed = preferences[kPrefColorCycleSpeed];
    if ([hueSpeed respondsToSelector:@selector(doubleValue)]) {
        self.hueSpeed = MAX(0.0, [hueSpeed doubleValue]);
    }
}

@end
