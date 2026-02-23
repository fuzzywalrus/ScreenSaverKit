#import "AmbleView.h"

#import <AppKit/AppKit.h>
#import <Metal/Metal.h>

#import "AmblePalettes.h"
#import "AmbleFluidSimulation.h"
#import "AmbleLineRenderer.h"

#import "ScreenSaverKit/SSKConfigurationWindowController.h"
#import "ScreenSaverKit/SSKMetalRenderer.h"
#import "ScreenSaverKit/SSKMetalTextureCache.h"
#import "ScreenSaverKit/SSKPaletteManager.h"
#import "ScreenSaverKit/SSKPreferenceBinder.h"

#pragma mark - Preference Keys

static NSString * const kPrefViscosity        = @"ambleViscosity";
static NSString * const kPrefNoiseMultiplier  = @"ambleNoiseMultiplier";
static NSString * const kPrefDissipation      = @"ambleDissipation";
static NSString * const kPrefGridSpacing      = @"ambleGridSpacing";
static NSString * const kPrefLineLength       = @"ambleLineLength";
static NSString * const kPrefLineWidth        = @"ambleLineWidth";
static NSString * const kPrefPalette          = @"amblePalette";
static NSString * const kPrefBloomIntensity   = @"ambleBloomIntensity";
static NSString * const kPrefBloomThreshold   = @"ambleBloomThreshold";

/// Base fluid grid width (height is aspect-ratio derived).
static const NSUInteger kBaseGridWidth = 256;

@interface AmbleView ()
@property (nonatomic, strong) SSKConfigurationWindowController *configController;
@property (nonatomic, strong) AmbleFluidSimulation *fluidSim;
@property (nonatomic, strong) AmbleLineRenderer *lineRenderer;
@property (nonatomic) CGFloat elapsedTime;
@property (nonatomic) CGSize lastDrawableSize;

// Preference-derived values
@property (nonatomic) float viscosity;
@property (nonatomic) float noiseMultiplier;
@property (nonatomic) float dissipation;
@property (nonatomic) float gridSpacing;
@property (nonatomic) float lineLength;
@property (nonatomic) float lineWidth;
@property (nonatomic, copy) NSString *paletteIdentifier;
@property (nonatomic) CGFloat bloomIntensity;
@property (nonatomic) CGFloat bloomThreshold;
@end

@implementation AmbleView

#pragma mark - Preferences

- (NSDictionary<NSString *, id> *)defaultPreferences {
    AmbleRegisterPalettes();
    return @{
        kPrefViscosity:       @(5.0),
        kPrefNoiseMultiplier: @(0.45),
        kPrefDissipation:     @(0.998),
        kPrefGridSpacing:     @(15.0),
        kPrefLineLength:      @(8.0),
        kPrefLineWidth:       @(2.0),
        kPrefPalette:         AmbleDefaultPaletteIdentifier(),
        kPrefBloomIntensity:  @(0.3),
        kPrefBloomThreshold:  @(0.6),
    };
}

- (void)preferencesDidChange:(NSDictionary<NSString *, id> *)preferences
                 changedKeys:(NSSet<NSString *> *)changedKeys {
    [self applyPreferences:preferences changedKeys:changedKeys];
}

- (void)applyPreferences:(NSDictionary<NSString *, id> *)preferences
             changedKeys:(NSSet<NSString *> *)changedKeys {
    AmbleRegisterPalettes();
    NSDictionary *defaults = [self defaultPreferences];

    // Simulation
    double visc = [preferences[kPrefViscosity] respondsToSelector:@selector(doubleValue)] ?
        [preferences[kPrefViscosity] doubleValue] :
        [defaults[kPrefViscosity] doubleValue];
    self.viscosity = (float)MAX(0.1, visc);

    double noise = [preferences[kPrefNoiseMultiplier] respondsToSelector:@selector(doubleValue)] ?
        [preferences[kPrefNoiseMultiplier] doubleValue] :
        [defaults[kPrefNoiseMultiplier] doubleValue];
    self.noiseMultiplier = (float)MAX(0.0, noise);

    double dissip = [preferences[kPrefDissipation] respondsToSelector:@selector(doubleValue)] ?
        [preferences[kPrefDissipation] doubleValue] :
        [defaults[kPrefDissipation] doubleValue];
    self.dissipation = (float)MIN(MAX(dissip, 0.99), 1.0);

    // Rendering
    double spacing = [preferences[kPrefGridSpacing] respondsToSelector:@selector(doubleValue)] ?
        [preferences[kPrefGridSpacing] doubleValue] :
        [defaults[kPrefGridSpacing] doubleValue];
    self.gridSpacing = (float)MIN(MAX(spacing, 5.0), 30.0);

    double len = [preferences[kPrefLineLength] respondsToSelector:@selector(doubleValue)] ?
        [preferences[kPrefLineLength] doubleValue] :
        [defaults[kPrefLineLength] doubleValue];
    self.lineLength = (float)MIN(MAX(len, 2.0), 20.0);

    double wid = [preferences[kPrefLineWidth] respondsToSelector:@selector(doubleValue)] ?
        [preferences[kPrefLineWidth] doubleValue] :
        [defaults[kPrefLineWidth] doubleValue];
    self.lineWidth = (float)MIN(MAX(wid, 0.5), 5.0);

    NSString *paletteValue = [preferences[kPrefPalette] isKindOfClass:[NSString class]] ?
        preferences[kPrefPalette] : defaults[kPrefPalette];
    if (![paletteValue isKindOfClass:[NSString class]] || paletteValue.length == 0) {
        paletteValue = AmbleDefaultPaletteIdentifier();
    }
    self.paletteIdentifier = paletteValue;

    // Post-processing
    double bloom = [preferences[kPrefBloomIntensity] respondsToSelector:@selector(doubleValue)] ?
        [preferences[kPrefBloomIntensity] doubleValue] :
        [defaults[kPrefBloomIntensity] doubleValue];
    self.bloomIntensity = MAX(0.0, bloom);

    double threshold = [preferences[kPrefBloomThreshold] respondsToSelector:@selector(doubleValue)] ?
        [preferences[kPrefBloomThreshold] doubleValue] :
        [defaults[kPrefBloomThreshold] doubleValue];
    self.bloomThreshold = MIN(MAX(threshold, 0.0), 1.0);

    // Push live changes to subsystems
    if (self.fluidSim) {
        self.fluidSim.viscosity = self.viscosity;
        self.fluidSim.noiseMultiplier = self.noiseMultiplier;
        self.fluidSim.dissipation = self.dissipation;
    }
    if (self.lineRenderer) {
        self.lineRenderer.gridSpacing = self.gridSpacing;
        self.lineRenderer.lineLength = self.lineLength;
        self.lineRenderer.lineWidth = self.lineWidth;
        [self.lineRenderer updateGridForScreenSize:self.lastDrawableSize];
        [self updateLineColor];
    }
    if (self.metalRenderer) {
        self.metalRenderer.bloomThreshold = self.bloomThreshold;
    }
}

#pragma mark - Initialization

- (instancetype)initWithFrame:(NSRect)frame isPreview:(BOOL)isPreview {
    if ((self = [super initWithFrame:frame isPreview:isPreview])) {
        self.animationTimeInterval = 1.0 / 60.0;
        AmbleRegisterPalettes();
    }
    return self;
}

#pragma mark - Metal Lifecycle

- (void)setupMetalRenderer:(SSKMetalRenderer *)renderer {
    [super setupMetalRenderer:renderer];

    renderer.clearColor = MTLClearColorMake(0.0, 0.0, 0.05, 1.0);
    renderer.bloomThreshold = self.bloomThreshold;
    renderer.bloomBlurSigma = 3.0;

    NSBundle *bundle = [NSBundle bundleForClass:[self class]];

    // Create fluid simulation
    self.fluidSim = [[AmbleFluidSimulation alloc] initWithDevice:renderer.device
                                                    textureCache:renderer.textureCache
                                                          bundle:bundle];
    if (self.fluidSim) {
        self.fluidSim.viscosity = self.viscosity;
        self.fluidSim.noiseMultiplier = self.noiseMultiplier;
        self.fluidSim.dissipation = self.dissipation;

        // Set fluid grid to match aspect ratio
        CGSize drawableSize = renderer.drawableSize;
        if (drawableSize.width > 0 && drawableSize.height > 0) {
            CGFloat aspect = drawableSize.width / drawableSize.height;
            NSUInteger gridH = (NSUInteger)(kBaseGridWidth / aspect);
            [self.fluidSim resizeGrid:CGSizeMake(kBaseGridWidth, MAX(gridH, 64))];
        }
    }

    // Create line renderer
    self.lineRenderer = [[AmbleLineRenderer alloc] initWithDevice:renderer.device
                                                     textureCache:renderer.textureCache
                                                           bundle:bundle];
    if (self.lineRenderer) {
        self.lineRenderer.gridSpacing = self.gridSpacing;
        self.lineRenderer.lineLength = self.lineLength;
        self.lineRenderer.lineWidth = self.lineWidth;
        [self updateLineColor];
    }

    // Avoid presenting empty Metal frames when setup failed (usually missing shaders/resources).
    if (!self.fluidSim || !self.lineRenderer) {
        NSLog(@"AmbleView: Metal setup incomplete (fluidSim=%@, lineRenderer=%@). Falling back to CPU path.",
              self.fluidSim ? @"ready" : @"nil",
              self.lineRenderer ? @"ready" : @"nil");
        self.useMetalPipeline = NO;
    }
}

#pragma mark - Animation

- (void)renderMetalFrame:(SSKMetalRenderer *)renderer deltaTime:(NSTimeInterval)dt {
    if (!self.fluidSim || !self.lineRenderer) return;

    self.elapsedTime += dt;

    id<MTLCommandBuffer> cmdBuf = renderer.currentCommandBuffer;
    if (!cmdBuf) return;

    // Acquire the drawable so renderer.drawableSize is set (it's only updated in ensureCurrentDrawable).
    // Without this, drawableSize stays CGSizeZero and we'd acquire a 0x0 texture and never draw.
    [renderer clearWithColor:renderer.clearColor];

    CGSize drawableSize = renderer.drawableSize;
    if (drawableSize.width <= 0 || drawableSize.height <= 0) return;

    // Resize grid if drawable size changed
    if (drawableSize.width != self.lastDrawableSize.width ||
        drawableSize.height != self.lastDrawableSize.height) {
        self.lastDrawableSize = drawableSize;

        CGFloat aspect = drawableSize.width / drawableSize.height;
        NSUInteger gridH = (NSUInteger)(kBaseGridWidth / aspect);
        [self.fluidSim resizeGrid:CGSizeMake(kBaseGridWidth, MAX(gridH, 64))];
        [self.lineRenderer updateGridForScreenSize:drawableSize];
    }

    // 1. Run fluid simulation
    [self.fluidSim encodeToCommandBuffer:cmdBuf];

    // 2. Render lines to intermediate texture
    id<MTLTexture> intermediate = [renderer.textureCache
        acquireTextureWithSize:drawableSize
                   pixelFormat:MTLPixelFormatBGRA8Unorm
                         usage:MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead];
    if (!intermediate) return;

    [self.lineRenderer encodeToCommandBuffer:cmdBuf
                                renderTarget:intermediate
                            velocityTexture:self.fluidSim.velocityTexture
                                  clearColor:renderer.clearColor];

    // 3. Blit intermediate to drawable
    [renderer drawTexture:intermediate
                   atRect:CGRectMake(0, 0, drawableSize.width, drawableSize.height)];
    [renderer.textureCache releaseTexture:intermediate];

    // 4. Post-processing
    if (self.bloomIntensity > 0.01) {
        renderer.bloomThreshold = self.bloomThreshold;
        [renderer applyBloom:self.bloomIntensity];
    }
}

#pragma mark - Color

- (void)updateLineColor {
    SSKPaletteManager *manager = [SSKPaletteManager sharedManager];
    NSString *module = AmblePaletteModuleIdentifier();
    SSKColorPalette *palette = [manager paletteWithIdentifier:self.paletteIdentifier module:module];
    if (!palette) {
        palette = [manager paletteWithIdentifier:AmbleDefaultPaletteIdentifier() module:module];
    }

    // Use the first color from the palette as the base line color
    if (palette) {
        NSColor *color = [manager colorForPalette:palette progress:0.0
                                interpolationMode:SSKPaletteInterpolationModeLoop];
        if (color) {
            self.lineRenderer.lineColor = color;
            return;
        }
    }
    self.lineRenderer.lineColor = [NSColor colorWithRed:0.95 green:0.6 blue:0.3 alpha:0.85];
}

#pragma mark - CPU Fallback

- (void)renderCPUFrameWithDeltaTime:(NSTimeInterval)dt {
    (void)dt;
    [self setNeedsDisplay:YES];
}

- (void)drawRect:(NSRect)dirtyRect {
    if (self.metalAvailable && self.useMetalPipeline) return;

    [[NSColor blackColor] setFill];
    NSRectFill(dirtyRect);

    NSDictionary *attrs = @{
        NSFontAttributeName: [NSFont systemFontOfSize:24.0],
        NSForegroundColorAttributeName: [NSColor colorWithWhite:0.3 alpha:1.0]
    };
    NSString *text = @"Amble (requires Metal)";
    NSSize textSize = [text sizeWithAttributes:attrs];
    CGFloat x = (NSWidth(dirtyRect) - textSize.width) / 2.0;
    CGFloat y = (NSHeight(dirtyRect) - textSize.height) / 2.0;
    [text drawAtPoint:NSMakePoint(x, y) withAttributes:attrs];
}

#pragma mark - Lifecycle

- (void)stopAnimation {
    self.fluidSim = nil;
    self.lineRenderer = nil;
    [super stopAnimation];
}

#pragma mark - Configure Sheet

- (BOOL)hasConfigureSheet {
    return YES;
}

- (NSWindow *)configureSheet {
    [self ensureConfigController];
    [self.configController prepareForPresentation];
    return self.configController.window;
}

- (void)ensureConfigController {
    if (self.configController) return;

    self.configController = [[SSKConfigurationWindowController alloc]
        initWithSaverView:self
                    title:@"Amble"
                 subtitle:@"Fluid dynamics visualized as flowing line particles."];
    SSKPreferenceBinder *binder = self.configController.preferenceBinder;
    NSStackView *stack = self.configController.contentStack;

    // --- Simulation ---
    [stack addArrangedSubview:[self sectionHeaderWithTitle:@"Simulation"]];

    [stack addArrangedSubview:[self sliderRowWithTitle:@"Viscosity"
                                             minValue:0.1
                                             maxValue:20.0
                                                  key:kPrefViscosity
                                               format:@"%.1f"
                                               binder:binder]];

    [stack addArrangedSubview:[self sliderRowWithTitle:@"Noise Multiplier"
                                             minValue:0.0
                                             maxValue:2.0
                                                  key:kPrefNoiseMultiplier
                                               format:@"%.2f"
                                               binder:binder]];

    [stack addArrangedSubview:[self sliderRowWithTitle:@"Dissipation"
                                             minValue:0.99
                                             maxValue:1.0
                                                  key:kPrefDissipation
                                               format:@"%.4f"
                                               binder:binder]];

    // --- Rendering ---
    [stack addArrangedSubview:[self sectionHeaderWithTitle:@"Rendering"]];

    [stack addArrangedSubview:[self sliderRowWithTitle:@"Grid Spacing"
                                             minValue:5.0
                                             maxValue:30.0
                                                  key:kPrefGridSpacing
                                               format:@"%.0f"
                                               binder:binder]];

    [stack addArrangedSubview:[self sliderRowWithTitle:@"Line Length"
                                             minValue:2.0
                                             maxValue:20.0
                                                  key:kPrefLineLength
                                               format:@"%.1f"
                                               binder:binder]];

    [stack addArrangedSubview:[self sliderRowWithTitle:@"Line Width"
                                             minValue:0.5
                                             maxValue:5.0
                                                  key:kPrefLineWidth
                                               format:@"%.1f"
                                               binder:binder]];

    [stack addArrangedSubview:[self paletteRowWithBinder:binder]];

    // --- Post-Processing ---
    [stack addArrangedSubview:[self sectionHeaderWithTitle:@"Post-Processing"]];

    [stack addArrangedSubview:[self sliderRowWithTitle:@"Bloom Intensity"
                                             minValue:0.0
                                             maxValue:1.0
                                                  key:kPrefBloomIntensity
                                               format:@"%.2f"
                                               binder:binder]];

    [stack addArrangedSubview:[self sliderRowWithTitle:@"Bloom Threshold"
                                             minValue:0.0
                                             maxValue:1.0
                                                  key:kPrefBloomThreshold
                                               format:@"%.2f"
                                               binder:binder]];
}

#pragma mark - UI Helpers

- (NSView *)sectionHeaderWithTitle:(NSString *)title {
    NSTextField *header = [NSTextField labelWithString:title];
    header.font = [NSFont systemFontOfSize:13 weight:NSFontWeightSemibold];
    header.textColor = [NSColor labelColor];

    NSView *wrapper = [[NSView alloc] initWithFrame:NSZeroRect];
    wrapper.translatesAutoresizingMaskIntoConstraints = NO;
    header.translatesAutoresizingMaskIntoConstraints = NO;
    [wrapper addSubview:header];
    [NSLayoutConstraint activateConstraints:@[
        [header.leadingAnchor constraintEqualToAnchor:wrapper.leadingAnchor],
        [header.trailingAnchor constraintEqualToAnchor:wrapper.trailingAnchor],
        [header.topAnchor constraintEqualToAnchor:wrapper.topAnchor constant:8],
        [header.bottomAnchor constraintEqualToAnchor:wrapper.bottomAnchor],
    ]];
    return wrapper;
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
    row.spacing = 8.0;
    row.alignment = NSLayoutAttributeCenterY;
    [row addArrangedSubview:label];
    [row addArrangedSubview:slider];
    [row addArrangedSubview:valueLabel];

    [binder bindSlider:slider key:key valueLabel:valueLabel format:format];
    return row;
}

- (NSView *)paletteRowWithBinder:(SSKPreferenceBinder *)binder {
    NSTextField *label = [NSTextField labelWithString:@"Color Palette"];
    label.font = [NSFont systemFontOfSize:12 weight:NSFontWeightRegular];
    [label setContentHuggingPriority:NSLayoutPriorityDefaultHigh
                       forOrientation:NSLayoutConstraintOrientationHorizontal];

    NSPopUpButton *popUp = [[NSPopUpButton alloc] initWithFrame:NSZeroRect pullsDown:NO];
    [popUp removeAllItems];

    AmbleRegisterPalettes();
    NSArray<SSKColorPalette *> *palettes = [[SSKPaletteManager sharedManager]
        palettesForModule:AmblePaletteModuleIdentifier()];
    for (SSKColorPalette *palette in palettes) {
        NSString *title = palette.displayName.length ? palette.displayName : @"Palette";
        [popUp addItemWithTitle:title];
        NSMenuItem *item = [popUp itemAtIndex:popUp.numberOfItems - 1];
        item.representedObject = palette.identifier;
    }
    if (popUp.numberOfItems == 0) {
        NSString *fallback = AmbleDefaultPaletteIdentifier();
        [popUp addItemWithTitle:fallback];
        popUp.lastItem.representedObject = fallback;
    }

    NSStackView *row = [[NSStackView alloc] initWithFrame:NSZeroRect];
    row.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    row.spacing = 8.0;
    row.alignment = NSLayoutAttributeCenterY;
    [row addArrangedSubview:label];
    [row addArrangedSubview:popUp];

    [binder bindPopUpButton:popUp key:kPrefPalette];
    return row;
}

@end
