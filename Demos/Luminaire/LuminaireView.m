#import "LuminaireView.h"

#import <AppKit/AppKit.h>
#import <Metal/Metal.h>

#import "LuminairePalettes.h"

#import "ScreenSaverKit/SSKColorUtilities.h"
#import "ScreenSaverKit/SSKConfigurationWindowController.h"
#import "ScreenSaverKit/SSKMetalRenderer.h"
#import "ScreenSaverKit/SSKPaletteManager.h"
#import "ScreenSaverKit/SSKParticleSystem.h"
#import "ScreenSaverKit/SSKPreferenceBinder.h"

#pragma mark - Preference Keys

static NSString * const kPrefParticleCount     = @"luminaireParticleCount";
static NSString * const kPrefTrailEnabled       = @"luminaireTrailEnabled";
static NSString * const kPrefTrailFadeRate      = @"luminaireTrailFadeRate";
static NSString * const kPrefBloomIntensity     = @"luminaireBloomIntensity";
static NSString * const kPrefPalette            = @"luminairePalette";
static NSString * const kPrefColorSpeed         = @"luminaireColorSpeed";
static NSString * const kPrefBackgroundColor    = @"luminaireBackgroundColor";
static NSString * const kPrefNoiseStrength      = @"luminaireNoiseStrength";
static NSString * const kPrefNoiseScale         = @"luminaireNoiseScale";
static NSString * const kPrefDamping            = @"luminaireDamping";
static NSString * const kPrefAttractorForce     = @"luminaireAttractorForce";

/// Emit rate in particles per second (not user-configurable).
static const CGFloat kEmitRate = 200.0;

/// Attractor orbit radius as a fraction of the shorter screen dimension.
static const CGFloat kAttractorOrbitFraction = 0.25;

/// Attractor orbit speed in radians per second.
static const CGFloat kAttractorOrbitSpeed = 0.2;

@interface LuminaireView ()
@property (nonatomic, strong) SSKConfigurationWindowController *configController;
@property (nonatomic, strong) SSKParticleSystem *particleSystem;
@property (nonatomic) CGFloat elapsedTime;
@property (nonatomic) CGFloat emitAccumulator;

// Preference-derived values
@property (nonatomic) NSUInteger particleCapacity;
@property (nonatomic) BOOL trailEnabled;
@property (nonatomic) CGFloat trailFadeRate;
@property (nonatomic) CGFloat bloomIntensity;
@property (nonatomic, copy) NSString *paletteIdentifier;
@property (nonatomic) CGFloat colorCycleSpeed;
@property (nonatomic, strong) NSColor *backgroundColor;
@property (nonatomic) CGFloat noiseStrength;
@property (nonatomic) CGFloat noiseScale;
@property (nonatomic) CGFloat globalDamping;
@property (nonatomic) CGFloat attractorStrength;
@end

@implementation LuminaireView

#pragma mark - Preferences

- (NSDictionary<NSString *, id> *)defaultPreferences {
    LuminaireRegisterPalettes();
    return @{
        kPrefParticleCount:  @(4096),
        kPrefTrailEnabled:   @(YES),
        kPrefTrailFadeRate:  @(0.02),
        kPrefBloomIntensity: @(0.6),
        kPrefPalette:        LuminaireDefaultPaletteIdentifier(),
        kPrefColorSpeed:     @(0.05),
        kPrefBackgroundColor:SSKSerializeColor([NSColor blackColor]),
        kPrefNoiseStrength:  @(250.0),
        kPrefNoiseScale:     @(0.002),
        kPrefDamping:        @(0.97),
        kPrefAttractorForce: @(5000.0),
    };
}

- (void)preferencesDidChange:(NSDictionary<NSString *, id> *)preferences
                 changedKeys:(NSSet<NSString *> *)changedKeys {
    [self applyPreferences:preferences changedKeys:changedKeys];
}

- (void)applyPreferences:(NSDictionary<NSString *, id> *)preferences
             changedKeys:(NSSet<NSString *> *)changedKeys {
    LuminaireRegisterPalettes();
    NSDictionary *defaults = [self defaultPreferences];

    // Core
    NSUInteger newCapacity = [preferences[kPrefParticleCount] respondsToSelector:@selector(unsignedIntegerValue)] ?
        [preferences[kPrefParticleCount] unsignedIntegerValue] :
        [defaults[kPrefParticleCount] unsignedIntegerValue];
    newCapacity = MIN(MAX(newCapacity, 1024u), 8192u);
    self.particleCapacity = newCapacity;

    self.trailEnabled = [preferences[kPrefTrailEnabled] respondsToSelector:@selector(boolValue)] ?
        [preferences[kPrefTrailEnabled] boolValue] :
        [defaults[kPrefTrailEnabled] boolValue];

    double fadeRate = [preferences[kPrefTrailFadeRate] respondsToSelector:@selector(doubleValue)] ?
        [preferences[kPrefTrailFadeRate] doubleValue] :
        [defaults[kPrefTrailFadeRate] doubleValue];
    self.trailFadeRate = MIN(MAX(fadeRate, 0.005), 0.1);

    double bloom = [preferences[kPrefBloomIntensity] respondsToSelector:@selector(doubleValue)] ?
        [preferences[kPrefBloomIntensity] doubleValue] :
        [defaults[kPrefBloomIntensity] doubleValue];
    self.bloomIntensity = MAX(0.0, bloom);

    // Colors
    NSString *paletteValue = [preferences[kPrefPalette] isKindOfClass:[NSString class]] ?
        preferences[kPrefPalette] : defaults[kPrefPalette];
    if (![paletteValue isKindOfClass:[NSString class]] || paletteValue.length == 0) {
        paletteValue = LuminaireDefaultPaletteIdentifier();
    }
    self.paletteIdentifier = paletteValue;

    double colorSpeed = [preferences[kPrefColorSpeed] respondsToSelector:@selector(doubleValue)] ?
        [preferences[kPrefColorSpeed] doubleValue] :
        [defaults[kPrefColorSpeed] doubleValue];
    self.colorCycleSpeed = MAX(0.0, colorSpeed);

    self.backgroundColor = SSKDeserializeColor(preferences[kPrefBackgroundColor], [NSColor blackColor]);

    // Physics
    double strength = [preferences[kPrefNoiseStrength] respondsToSelector:@selector(doubleValue)] ?
        [preferences[kPrefNoiseStrength] doubleValue] :
        [defaults[kPrefNoiseStrength] doubleValue];
    self.noiseStrength = MAX(0.0, strength);

    double scale = [preferences[kPrefNoiseScale] respondsToSelector:@selector(doubleValue)] ?
        [preferences[kPrefNoiseScale] doubleValue] :
        [defaults[kPrefNoiseScale] doubleValue];
    self.noiseScale = MIN(MAX(scale, 0.001), 0.01);

    double damping = [preferences[kPrefDamping] respondsToSelector:@selector(doubleValue)] ?
        [preferences[kPrefDamping] doubleValue] :
        [defaults[kPrefDamping] doubleValue];
    self.globalDamping = MIN(MAX(damping, 0.90), 1.0);

    double attractor = [preferences[kPrefAttractorForce] respondsToSelector:@selector(doubleValue)] ?
        [preferences[kPrefAttractorForce] doubleValue] :
        [defaults[kPrefAttractorForce] doubleValue];
    self.attractorStrength = MAX(0.0, attractor);

    // Apply live changes to renderer
    if (self.metalRenderer) {
        self.metalRenderer.trailPersistenceEnabled = self.trailEnabled;
        self.metalRenderer.trailFadeRate = self.trailFadeRate;

        NSColor *bg = [self.backgroundColor colorUsingColorSpace:[NSColorSpace sRGBColorSpace]]
                      ?: [NSColor blackColor];
        CGFloat r, g, b, a;
        [bg getRed:&r green:&g blue:&b alpha:&a];
        self.metalRenderer.clearColor = MTLClearColorMake(r, g, b, a);
    }

    // Apply live changes to particle system
    if (self.particleSystem) {
        self.particleSystem.noiseStrength = self.noiseStrength;
        self.particleSystem.noiseScale = self.noiseScale;
        self.particleSystem.globalDamping = self.globalDamping;

        // Recreate particle system if capacity changed
        if (newCapacity != self.particleSystem.capacity && self.metalRenderer.device) {
            [self.particleSystem releaseMetalResources];
            _particleSystem = [[SSKParticleSystem alloc] initWithCapacity:newCapacity
                                                                   device:self.metalRenderer.device];
            _particleSystem.blendMode = SSKParticleBlendModeAdditive;
            _particleSystem.gravity = NSZeroPoint;
            _particleSystem.noiseScale = self.noiseScale;
            _particleSystem.noiseStrength = self.noiseStrength;
            _particleSystem.noiseSpeed = 0.3;
            _particleSystem.globalDamping = self.globalDamping;
        }
    }
}

#pragma mark - Initialization

- (instancetype)initWithFrame:(NSRect)frame isPreview:(BOOL)isPreview {
    if ((self = [super initWithFrame:frame isPreview:isPreview])) {
        self.animationTimeInterval = 1.0 / 60.0;
        LuminaireRegisterPalettes();
    }
    return self;
}

#pragma mark - Metal Lifecycle

- (void)setupMetalRenderer:(SSKMetalRenderer *)renderer {
    [super setupMetalRenderer:renderer];

    // Background color from preferences
    NSColor *bg = [self.backgroundColor colorUsingColorSpace:[NSColorSpace sRGBColorSpace]]
                  ?: [NSColor blackColor];
    CGFloat r, g, b, a;
    [bg getRed:&r green:&g blue:&b alpha:&a];
    renderer.clearColor = MTLClearColorMake(r, g, b, a);

    // Trail persistence
    renderer.trailPersistenceEnabled = self.trailEnabled;
    renderer.trailFadeRate = self.trailFadeRate;

    // Bloom
    renderer.bloomThreshold = 0.3;
    renderer.bloomBlurSigma = 4.0;

    // Indirect rendering for GPU-side instance building
    renderer.useIndirectRendering = YES;

    // Particle system
    _particleSystem = [[SSKParticleSystem alloc] initWithCapacity:self.particleCapacity
                                                           device:renderer.device];
    _particleSystem.blendMode = SSKParticleBlendModeAdditive;
    _particleSystem.globalDamping = self.globalDamping;
    _particleSystem.gravity = NSZeroPoint;

    // Curl noise drives organic flow
    _particleSystem.noiseScale = self.noiseScale;
    _particleSystem.noiseStrength = self.noiseStrength;
    _particleSystem.noiseSpeed = 0.3;

    [self updateAttractorsForTime:0.0];
}

#pragma mark - Animation

- (void)renderMetalFrame:(SSKMetalRenderer *)renderer deltaTime:(NSTimeInterval)dt {
    if (!self.particleSystem) { return; }

    self.elapsedTime += dt;

    [self updateAttractorsForTime:self.elapsedTime];
    [self emitParticlesWithDelta:dt];
    [self.particleSystem advanceBy:dt];

    CGSize viewportSize = self.bounds.size;
    NSArray<SSKParticle *> *particles = [self.particleSystem aliveParticlesSnapshot];
    [renderer drawParticles:particles
                  blendMode:self.particleSystem.blendMode
               viewportSize:viewportSize];

    if (self.bloomIntensity > 0.01) {
        [renderer applyBloom:self.bloomIntensity];
    }
}

- (void)emitParticlesWithDelta:(NSTimeInterval)dt {
    self.emitAccumulator += kEmitRate * dt;
    NSUInteger toEmit = (NSUInteger)self.emitAccumulator;
    if (toEmit == 0) { return; }
    self.emitAccumulator -= toEmit;

    CGSize bounds = self.bounds.size;
    if (bounds.width <= 0 || bounds.height <= 0) { return; }

    CGFloat cx = bounds.width * 0.5;
    CGFloat cy = bounds.height * 0.5;

    SSKParticleSpawnParameters params = SSKParticleSpawnParametersMake();
    params.regionType = SSKParticleSpawnRegionTypeCircle;
    params.center = (vector_float2){(float)cx, (float)cy};
    params.size = (vector_float2){(float)(bounds.width * 0.05), 0.0};

    params.speedRange = (vector_float2){10.0f, 40.0f};
    params.directionAngle = (float)(self.elapsedTime * 0.5);
    params.directionSpread = (float)(M_PI * 2.0);

    params.sizeRange = (vector_float2){2.0f, 5.0f};
    params.lifeRange = (vector_float2){4.0f, 8.0f};
    params.dampingRange = (vector_float2){0.0f, 0.0f};

    // Palette-based color cycling
    SSKPaletteManager *manager = [SSKPaletteManager sharedManager];
    NSString *module = LuminairePaletteModuleIdentifier();
    SSKColorPalette *palette = [manager paletteWithIdentifier:self.paletteIdentifier module:module];
    if (!palette) {
        palette = [manager paletteWithIdentifier:LuminaireDefaultPaletteIdentifier() module:module];
    }

    CGFloat progress = fmod(self.elapsedTime * self.colorCycleSpeed, 1.0);
    NSColor *baseColor = palette ?
        [manager colorForPalette:palette progress:progress interpolationMode:SSKPaletteInterpolationModeLoop] :
        [NSColor colorWithCalibratedHue:0.5 saturation:0.7 brightness:1.0 alpha:1.0];
    NSColor *baseColor2 = palette ?
        [manager colorForPalette:palette progress:fmod(progress + 0.15, 1.0) interpolationMode:SSKPaletteInterpolationModeLoop] :
        [NSColor colorWithCalibratedHue:0.65 saturation:0.8 brightness:1.0 alpha:1.0];

    CGFloat r1, g1, b1, a1, r2, g2, b2, a2;
    [[baseColor colorUsingColorSpace:[NSColorSpace sRGBColorSpace]] getRed:&r1 green:&g1 blue:&b1 alpha:&a1];
    [[baseColor2 colorUsingColorSpace:[NSColorSpace sRGBColorSpace]] getRed:&r2 green:&g2 blue:&b2 alpha:&a2];
    params.colorMin = (vector_float4){(float)r1, (float)g1, (float)b1, 1.0f};
    params.colorMax = (vector_float4){(float)r2, (float)g2, (float)b2, 1.0f};

    // Color gradient: bright core fading to dim tail
    params.endColorMin = (vector_float4){(float)(r1 * 0.2f), (float)(g1 * 0.2f), (float)(b1 * 0.2f), 0.0f};
    params.endColorMax = (vector_float4){(float)(r2 * 0.3f), (float)(g2 * 0.3f), (float)(b2 * 0.3f), 0.0f};

    params.behaviorOptions = SSKParticleBehaviorOptionFadeAlpha
                           | SSKParticleBehaviorOptionColorGradient
                           | SSKParticleBehaviorOptionCurlNoise
                           | SSKParticleBehaviorOptionAttractors;

    params.rotationVelocityRange = (vector_float2){-1.0f, 1.0f};
    params.lengthMultiplier = 3.0f;

    [self.particleSystem spawnParticlesGPU:toEmit parameters:params];
}

- (void)updateAttractorsForTime:(CGFloat)time {
    CGSize bounds = self.bounds.size;
    if (bounds.width <= 0 || bounds.height <= 0) { return; }

    CGFloat cx = bounds.width * 0.5;
    CGFloat cy = bounds.height * 0.5;
    CGFloat radius = MIN(bounds.width, bounds.height) * kAttractorOrbitFraction;

    CGFloat angle1 = time * kAttractorOrbitSpeed;
    CGFloat angle2 = angle1 + M_PI;

    NSPoint pos1 = NSMakePoint(cx + cos(angle1) * radius, cy + sin(angle1) * radius);
    NSPoint pos2 = NSMakePoint(cx + cos(angle2) * radius * 0.7, cy + sin(angle2) * radius * 0.7);

    [self.particleSystem setAttractorAtIndex:0 position:pos1 strength:self.attractorStrength];
    [self.particleSystem setAttractorAtIndex:1 position:pos2 strength:self.attractorStrength * 0.6];
}

#pragma mark - CPU Fallback

- (void)renderCPUFrameWithDeltaTime:(NSTimeInterval)dt {
    (void)dt;
    [self setNeedsDisplay:YES];
}

- (void)drawRect:(NSRect)dirtyRect {
    if (self.metalAvailable && self.useMetalPipeline) {
        return;
    }
    [[NSColor blackColor] setFill];
    NSRectFill(dirtyRect);

    NSDictionary *attrs = @{
        NSFontAttributeName: [NSFont systemFontOfSize:24.0],
        NSForegroundColorAttributeName: [NSColor colorWithWhite:0.3 alpha:1.0]
    };
    NSString *text = @"Luminaire (requires Metal)";
    NSSize textSize = [text sizeWithAttributes:attrs];
    CGFloat x = (NSWidth(dirtyRect) - textSize.width) / 2.0;
    CGFloat y = (NSHeight(dirtyRect) - textSize.height) / 2.0;
    [text drawAtPoint:NSMakePoint(x, y) withAttributes:attrs];
}

#pragma mark - Lifecycle

- (void)stopAnimation {
    [self.particleSystem releaseMetalResources];
    self.particleSystem = nil;
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
    if (self.configController) { return; }

    self.configController = [[SSKConfigurationWindowController alloc]
        initWithSaverView:self
                    title:@"Luminaire"
                 subtitle:@"Luminous particle streams shaped by curl noise and attractors."];
    SSKPreferenceBinder *binder = self.configController.preferenceBinder;
    NSStackView *stack = self.configController.contentStack;

    // --- Core Visuals ---
    [stack addArrangedSubview:[self sectionHeaderWithTitle:@"Core Visuals"]];

    [stack addArrangedSubview:[self sliderRowWithTitle:@"Particle Count"
                                             minValue:1024
                                             maxValue:8192
                                                  key:kPrefParticleCount
                                               format:@"%.0f"
                                               binder:binder]];

    NSButton *trailToggle = [NSButton checkboxWithTitle:@"Trail Persistence" target:nil action:nil];
    [binder bindCheckbox:trailToggle key:kPrefTrailEnabled];
    [stack addArrangedSubview:trailToggle];

    [stack addArrangedSubview:[self sliderRowWithTitle:@"Trail Fade Rate"
                                             minValue:0.005
                                             maxValue:0.1
                                                  key:kPrefTrailFadeRate
                                               format:@"%.3f"
                                               binder:binder]];

    [stack addArrangedSubview:[self sliderRowWithTitle:@"Bloom Intensity"
                                             minValue:0.0
                                             maxValue:2.0
                                                  key:kPrefBloomIntensity
                                               format:@"%.2f"
                                               binder:binder]];

    // --- Colors ---
    [stack addArrangedSubview:[self sectionHeaderWithTitle:@"Colors"]];

    [stack addArrangedSubview:[self paletteRowWithBinder:binder]];

    [stack addArrangedSubview:[self sliderRowWithTitle:@"Cycle Speed"
                                             minValue:0.0
                                             maxValue:0.2
                                                  key:kPrefColorSpeed
                                               format:@"%.3f"
                                               binder:binder]];

    [stack addArrangedSubview:[self colorWellRowWithTitle:@"Background"
                                                     key:kPrefBackgroundColor
                                                  binder:binder]];

    // --- Physics ---
    [stack addArrangedSubview:[self sectionHeaderWithTitle:@"Physics"]];

    [stack addArrangedSubview:[self sliderRowWithTitle:@"Noise Strength"
                                             minValue:0.0
                                             maxValue:500.0
                                                  key:kPrefNoiseStrength
                                               format:@"%.0f"
                                               binder:binder]];

    [stack addArrangedSubview:[self sliderRowWithTitle:@"Noise Scale"
                                             minValue:0.001
                                             maxValue:0.01
                                                  key:kPrefNoiseScale
                                               format:@"%.4f"
                                               binder:binder]];

    [stack addArrangedSubview:[self sliderRowWithTitle:@"Damping"
                                             minValue:0.90
                                             maxValue:1.0
                                                  key:kPrefDamping
                                               format:@"%.3f"
                                               binder:binder]];

    [stack addArrangedSubview:[self sliderRowWithTitle:@"Attractor Force"
                                             minValue:0.0
                                             maxValue:10000.0
                                                  key:kPrefAttractorForce
                                               format:@"%.0f"
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

    LuminaireRegisterPalettes();
    NSArray<SSKColorPalette *> *palettes = [[SSKPaletteManager sharedManager]
        palettesForModule:LuminairePaletteModuleIdentifier()];
    for (SSKColorPalette *palette in palettes) {
        NSString *title = palette.displayName.length ? palette.displayName : @"Palette";
        [popUp addItemWithTitle:title];
        NSMenuItem *item = [popUp itemAtIndex:popUp.numberOfItems - 1];
        item.representedObject = palette.identifier;
    }
    if (popUp.numberOfItems == 0) {
        NSString *fallback = LuminaireDefaultPaletteIdentifier();
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

- (NSView *)colorWellRowWithTitle:(NSString *)title
                              key:(NSString *)key
                           binder:(SSKPreferenceBinder *)binder {
    NSTextField *label = [NSTextField labelWithString:title];
    label.font = [NSFont systemFontOfSize:12 weight:NSFontWeightRegular];
    [label setContentHuggingPriority:NSLayoutPriorityDefaultHigh
                       forOrientation:NSLayoutConstraintOrientationHorizontal];

    NSColorWell *well = [[NSColorWell alloc] initWithFrame:NSMakeRect(0, 0, 44, 24)];

    NSStackView *row = [[NSStackView alloc] initWithFrame:NSZeroRect];
    row.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    row.spacing = 8.0;
    row.alignment = NSLayoutAttributeCenterY;
    [row addArrangedSubview:label];
    [row addArrangedSubview:well];

    [binder bindColorWell:well key:key];
    return row;
}

@end
