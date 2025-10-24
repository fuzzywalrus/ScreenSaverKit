#import "TemplateSaverView.h"

#import <AppKit/AppKit.h>

#import "SSKConfigurationWindowController.h"
#import "SSKDiagnostics.h"
#import "SSKPreferenceBinder.h"
#import "SSKScreenUtilities.h"

static NSString * const kTemplatePrefHue        = @"backgroundHue";
static NSString * const kTemplatePrefShapeCount = @"shapeCount";
static NSString * const kTemplatePrefDiagnostics = @"showDiagnostics";

@interface TemplateSaverView ()
@property (nonatomic) CGFloat hue;
@property (nonatomic) NSInteger shapeCount;
@property (nonatomic) NSTimeInterval t;
@property (nonatomic) BOOL showDiagnostics;
@property (nonatomic, strong) SSKConfigurationWindowController *configurationController;
@end

@implementation TemplateSaverView

- (NSDictionary<NSString *,id> *)defaultPreferences {
    return @{
        kTemplatePrefHue: @(0.58),          // pastel blue default
        kTemplatePrefShapeCount: @(8),      // number of shapes to animate
        kTemplatePrefDiagnostics: @(NO)     // diagnostics overlay disabled by default
    };
}

- (instancetype)initWithFrame:(NSRect)frame isPreview:(BOOL)isPreview {
    if ((self = [super initWithFrame:frame isPreview:isPreview])) {
        self.animationTimeInterval = 1.0 / 30.0;
        self.wantsLayer = YES;
    }
    return self;
}

- (void)animateOneFrame {
    NSTimeInterval dt = [self advanceAnimationClock];
    self.t += dt;
    [self setNeedsDisplay:YES];
}

- (BOOL)isOpaque {
    return YES;
}

- (void)drawRect:(NSRect)rect {
    // Optionally draw a texture overlay if provided by the host project.
    NSImage *backgroundTexture = [self.assetManager imageNamed:@"template-background"
                                            fallbackExtensions:@[@"png", @"jpg", @"jpeg"]];
    if (backgroundTexture) {
        [backgroundTexture drawInRect:rect
                              fromRect:NSZeroRect
                             operation:NSCompositingOperationSourceOver
                              fraction:0.35
                        respectFlipped:YES
                                 hints:nil];
    } else {
        NSColor *background = [NSColor colorWithHue:self.hue
                                          saturation:0.35
                                          brightness:self.isPreview ? 0.9 : 0.15
                                               alpha:1.0];
        [background setFill];
        NSRectFill(rect);
    }
    
    CGContextRef ctx = [[NSGraphicsContext currentContext] CGContext];
    if (!ctx || self.shapeCount <= 0) {
        return;
    }
    
    CGFloat time = self.t;
    CGSize size = self.bounds.size;
    CGFloat spacing = MAX(size.width, size.height) / (CGFloat)(self.shapeCount + 1);
    CGFloat scale = [SSKScreenUtilities backingScaleFactorForView:self];
    CGFloat baseLineWidth = (self.isPreview ? 2.0 : 3.0) / MAX(scale, 0.5);
    
    for (NSInteger i = 0; i < self.shapeCount; i++) {
        CGFloat phase = time + (CGFloat)i * 0.37;
        CGFloat radius = 30.0 + 12.0 * sin(phase * 0.75);
        CGFloat x = (CGFloat)(i + 1) * spacing * 0.7 + 30.0 * sin(phase);
        CGFloat y = size.height * 0.5 + 40.0 * cos(phase * 0.6);
        
        NSColor *stroke = [NSColor colorWithHue:fmod(self.hue + 0.05 * i, 1.0)
                                      saturation:0.6
                                      brightness:0.95
                                           alpha:0.85];
        CGContextSetStrokeColorWithColor(ctx, stroke.CGColor);
        CGContextSetLineWidth(ctx, baseLineWidth);
        CGContextStrokeEllipseInRect(ctx, CGRectMake(x, y, radius * 2.0, radius * 2.0));
    }
    
    if (self.showDiagnostics) {
        [SSKDiagnostics drawOverlayInView:self text:@"Template Saver" framesPerSecond:self.animationClock.framesPerSecond];
    }
}

- (void)preferencesDidChange:(NSDictionary<NSString *,id> *)preferences
                 changedKeys:(NSSet<NSString *> *)changedKeys {
    self.hue = [preferences[kTemplatePrefHue] respondsToSelector:@selector(doubleValue)] ?
        [preferences[kTemplatePrefHue] doubleValue] : [self.defaultPreferences[kTemplatePrefHue] doubleValue];
    self.shapeCount = [preferences[kTemplatePrefShapeCount] respondsToSelector:@selector(integerValue)] ?
        [preferences[kTemplatePrefShapeCount] integerValue] : [self.defaultPreferences[kTemplatePrefShapeCount] integerValue];
    self.showDiagnostics = [preferences[kTemplatePrefDiagnostics] respondsToSelector:@selector(boolValue)] ?
        [preferences[kTemplatePrefDiagnostics] boolValue] : NO;
    [SSKDiagnostics setEnabled:self.showDiagnostics];
}

#pragma mark - Configuration sheet

- (BOOL)hasConfigureSheet {
    return YES;
}

- (NSWindow *)configureSheet {
    [self ensureConfigurationController];
    [self.configurationController prepareForPresentation];
    return self.configurationController.window;
}

- (void)ensureConfigurationController {
    if (self.configurationController) { return; }
    self.configurationController = [[SSKConfigurationWindowController alloc] initWithSaverView:self
                                                                                           title:@"Template Saver"
                                                                                        subtitle:@"Adjust colours, counts, and diagnostics."];
    SSKPreferenceBinder *binder = self.configurationController.preferenceBinder;
    NSStackView *stack = self.configurationController.contentStack;
    
    NSView *hueRow = [self sliderRowWithTitle:@"Background Hue"
                                       minValue:0.0
                                       maxValue:1.0
                                            key:kTemplatePrefHue
                                         format:@"%.2f"
                                          binder:binder];
    [stack addArrangedSubview:hueRow];
    
    NSView *shapeRow = [self sliderRowWithTitle:@"Shape Count"
                                         minValue:1
                                         maxValue:20
                                              key:kTemplatePrefShapeCount
                                           format:@"%.0f"
                                            binder:binder];
    [stack addArrangedSubview:shapeRow];
    
    NSButton *diagnosticsCheckbox = [NSButton checkboxWithTitle:@"Show diagnostics overlay" target:nil action:nil];
    [binder bindCheckbox:diagnosticsCheckbox key:kTemplatePrefDiagnostics];
    [stack addArrangedSubview:diagnosticsCheckbox];
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
    [slider setContentHuggingPriority:NSLayoutPriorityDefaultLow forOrientation:NSLayoutConstraintOrientationHorizontal];
    
    NSTextField *valueLabel = [NSTextField labelWithString:@"--"];
    valueLabel.font = [NSFont monospacedDigitSystemFontOfSize:12 weight:NSFontWeightMedium];
    [valueLabel setContentHuggingPriority:NSLayoutPriorityRequired forOrientation:NSLayoutConstraintOrientationHorizontal];
    
    NSStackView *row = [[NSStackView alloc] initWithFrame:NSZeroRect];
    row.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    row.spacing = 8;
    row.alignment = NSLayoutAttributeCenterY;
    row.translatesAutoresizingMaskIntoConstraints = NO;
    [row addArrangedSubview:label];
    [row addArrangedSubview:slider];
    [row addArrangedSubview:valueLabel];
    
    [binder bindSlider:slider key:key valueLabel:valueLabel format:format];
    return row;
}

@end
