#import "RibbonFlowView.h"

#import <AppKit/AppKit.h>
#import <QuartzCore/QuartzCore.h>
#import <Metal/Metal.h>

#import "RibbonFlowPalettes.h"

#import "ScreenSaverKit/SSKColorUtilities.h"
#import "ScreenSaverKit/SSKConfigurationWindowController.h"
#import "ScreenSaverKit/SSKDiagnostics.h"
#import "ScreenSaverKit/SSKMetalParticleRenderer.h"
#import "ScreenSaverKit/SSKPaletteManager.h"
#import "ScreenSaverKit/SSKParticleSystem.h"
#import "ScreenSaverKit/SSKPreferenceBinder.h"
#import "ScreenSaverKit/SSKVectorMath.h"

static NSString * const kPrefEmitterCount  = @"ribbonFlowEmitterCount";
static NSString * const kPrefSpeed         = @"ribbonFlowSpeed";
static NSString * const kPrefPalette       = @"ribbonFlowPalette";
static NSString * const kPrefTrailWidth    = @"ribbonFlowTrailWidth";
static NSString * const kPrefAdditiveBlend = @"ribbonFlowAdditiveBlend";
static NSString * const kPrefDiagnostics   = @"ribbonFlowDiagnostics";
static NSString * const kPrefSoftEdges    = @"ribbonFlowSoftEdges";
static NSString * const kPrefFrameRate    = @"ribbonFlowFrameRate";

typedef struct {
    NSPoint position;
    NSPoint velocity;
    NSPoint target;
    CGFloat colorPhase;
    CGFloat intrinsicSpeed;
} RibbonFlowEmitter;

@interface RibbonFlowView ()
@property (nonatomic, strong) SSKConfigurationWindowController *configController;
@property (nonatomic, strong) SSKParticleSystem *particleSystem;
@property (nonatomic, strong) NSMutableArray<NSValue *> *emitters;
@property (nonatomic) NSUInteger emitterCount;
@property (nonatomic) CGFloat speedMultiplier;
@property (nonatomic) CGFloat trailWidth;
@property (nonatomic) BOOL additiveBlend;
@property (nonatomic, copy) NSString *paletteIdentifier;
@property (nonatomic) BOOL metalEnabled;
@property (nonatomic, strong) id<MTLDevice> metalDevice;
@property (nonatomic, strong) CAMetalLayer *metalLayer;
@property (nonatomic, strong) SSKMetalParticleRenderer *metalRenderer;
@property (nonatomic) BOOL metalRenderingActive;
@property (nonatomic) BOOL awaitingMetalDrawable;
@property (nonatomic) NSUInteger metalSuccessCount;
@property (nonatomic) NSUInteger metalFailureCount;
@property (nonatomic, copy) NSString *metalStatusText;
@property (nonatomic, strong) CATextLayer *metalStatusLayer;
@property (nonatomic, getter=isDiagnosticsEnabled) BOOL diagnosticsEnabled;
@property (nonatomic) BOOL softEdgesEnabled;
@property (nonatomic) NSInteger targetFramesPerSecond;
@end

@implementation RibbonFlowView

- (void)dealloc {
    [SSKDiagnostics setEnabled:YES];
}

- (NSDictionary<NSString *,id> *)defaultPreferences {
    RibbonFlowRegisterPalettes();
    return @{
        kPrefEmitterCount: @(5),
        kPrefSpeed: @(1.0),
        kPrefTrailWidth: @(1.0),
        kPrefAdditiveBlend: @(YES),
        kPrefDiagnostics: @(YES),
        kPrefSoftEdges: @(YES),
        kPrefFrameRate: @"30",
        kPrefPalette: RibbonFlowDefaultPaletteIdentifier()
    };
}

- (instancetype)initWithFrame:(NSRect)frame isPreview:(BOOL)isPreview {
    if ((self = [super initWithFrame:frame isPreview:isPreview])) {
        self.animationTimeInterval = 1.0 / 30.0;
        RibbonFlowRegisterPalettes();
        _emitters = [NSMutableArray array];
        _particleSystem = [[SSKParticleSystem alloc] initWithCapacity:2048];
        self.particleSystem.metalSimulationEnabled = NO;
        self.metalEnabled = NO;
        self.metalRenderingActive = NO;
        self.diagnosticsEnabled = YES;
        self.softEdgesEnabled = YES;
        self.targetFramesPerSecond = 30;
        self.metalStatusText = @"Metal: waiting for device";
        _metalSuccessCount = 0;
        _metalFailureCount = 0;

        [self configureParticleRenderHandler];

        NSDictionary *prefs = [self currentPreferences];
        NSSet *keys = [NSSet setWithArray:prefs.allKeys];
        [self applyPreferences:prefs changedKeys:keys];
        [self rebuildEmitters];
    }
    return self;
}

- (void)setMetalStatusText:(NSString *)metalStatusText {
    if ((_metalStatusText == metalStatusText) || [_metalStatusText isEqualToString:metalStatusText]) {
        return;
    }
    _metalStatusText = [metalStatusText copy];
    [self updateMetalStatusLayerString];
}

- (void)setDiagnosticsEnabled:(BOOL)diagnosticsEnabled {
    if (_diagnosticsEnabled == diagnosticsEnabled) { return; }
    _diagnosticsEnabled = diagnosticsEnabled;
    [SSKDiagnostics setEnabled:diagnosticsEnabled];
    if (self.metalStatusLayer) {
        self.metalStatusLayer.hidden = !diagnosticsEnabled;
    }
    if (!diagnosticsEnabled) {
        [self setNeedsDisplay:YES];
    }
    [self updateMetalStatusLayerString];
}

- (void)setSoftEdgesEnabled:(BOOL)softEdgesEnabled {
    if (_softEdgesEnabled == softEdgesEnabled) { return; }
    _softEdgesEnabled = softEdgesEnabled;
    [self configureParticleRenderHandler];
}

- (void)setFrame:(NSRect)frame {
    [super setFrame:frame];
    [self clampEmittersToBounds];
    [self updateMetalSupportIfNeeded];
}

- (void)viewDidMoveToWindow {
    [super viewDidMoveToWindow];
    [self updateMetalSupportIfNeeded];
}

- (void)layout {
    [super layout];
    [self updateMetalLayerDrawableSize];
    [self layoutMetalStatusLayer];
}

- (void)rebuildEmitters {
    [self.emitters removeAllObjects];
    NSRect bounds = self.bounds;
    for (NSUInteger i = 0; i < self.emitterCount; i++) {
        RibbonFlowEmitter emitter;
        emitter.position = [self randomPointInRect:bounds];
        emitter.velocity = NSZeroPoint;
        emitter.target = [self randomPointInRect:bounds];
        emitter.colorPhase = (CGFloat)arc4random() / (CGFloat)UINT32_MAX;
        emitter.intrinsicSpeed = 0.6 + ((CGFloat)arc4random() / UINT32_MAX) * 0.9;
        [self.emitters addObject:[NSValue valueWithBytes:&emitter objCType:@encode(RibbonFlowEmitter)]];
    }
}

- (void)clampEmittersToBounds {
    NSRect bounds = self.bounds;
    for (NSUInteger i = 0; i < self.emitters.count; i++) {
        RibbonFlowEmitter emitter;
        [self.emitters[i] getValue:&emitter];
        emitter.position.x = MIN(MAX(emitter.position.x, NSMinX(bounds)), NSMaxX(bounds));
        emitter.position.y = MIN(MAX(emitter.position.y, NSMinY(bounds)), NSMaxY(bounds));
        self.emitters[i] = [NSValue valueWithBytes:&emitter objCType:@encode(RibbonFlowEmitter)];
    }
}

- (void)animateOneFrame {
    [self ensureMetalDevice];
    [self ensureMetalLayer];
    [self ensureMetalRenderer];
    [self updateMetalLayerDrawableSize];

    NSTimeInterval dt = [self advanceAnimationClock];
    if (dt <= 0.0) { dt = 1.0 / 60.0; }

    [self updateEmittersWithDelta:dt];

    self.particleSystem.blendMode = self.additiveBlend ? SSKParticleBlendModeAdditive : SSKParticleBlendModeAlpha;
    [self.particleSystem advanceBy:dt];

    BOOL renderedWithMetal = NO;
    self.awaitingMetalDrawable = NO;

    if (self.metalRenderer && self.metalLayer) {
        renderedWithMetal = [self.particleSystem renderWithMetalRenderer:self.metalRenderer
                                                               blendMode:(self.additiveBlend ? SSKParticleBlendModeAdditive : SSKParticleBlendModeAlpha)
                                                            viewportSize:self.bounds.size];
        if (renderedWithMetal) {
            self.metalRenderingActive = YES;
            self.metalSuccessCount += 1;
            self.metalFailureCount = 0;
            self.metalStatusText = [NSString stringWithFormat:@"Metal: active (successes %lu)",
                                    (unsigned long)self.metalSuccessCount];
        } else {
            self.awaitingMetalDrawable = YES;
            self.metalRenderingActive = NO;
            self.metalFailureCount += 1;
            self.metalStatusText = [NSString stringWithFormat:@"Metal: waiting for drawable (failures %lu)",
                                    (unsigned long)self.metalFailureCount];
        }
    } else if (!self.metalDevice) {
        self.metalRenderingActive = NO;
        self.metalStatusText = @"Metal: device unavailable";
    } else if (!self.metalLayer) {
        self.metalRenderingActive = NO;
        self.metalStatusText = @"Metal: layer unavailable";
    } else {
        self.metalRenderingActive = NO;
        NSString *error = [SSKMetalParticleRenderer lastCreationErrorMessage];
        self.metalStatusText = error.length ? [NSString stringWithFormat:@"Metal: renderer unavailable (%@)", error] :
                                              @"Metal: renderer unavailable";
    }

    BOOL previousMetalEnabled = self.metalEnabled;
    self.metalEnabled = (self.metalRenderer != nil);
    if (previousMetalEnabled != self.metalEnabled) {
        [self configureParticleRenderHandler];
    }

    if (self.diagnosticsEnabled) {
        [self ensureMetalStatusLayer];
        [self layoutMetalStatusLayer];
        [self updateMetalStatusLayerString];
    } else if (self.metalStatusLayer) {
        self.metalStatusLayer.hidden = YES;
    }

    if (!renderedWithMetal) {
        [self setNeedsDisplay:YES];
    }
}

- (void)drawRect:(NSRect)dirtyRect {
    if (self.metalRenderingActive && self.metalRenderer) { return; }
    [[NSColor blackColor] setFill];
    NSRectFill(dirtyRect);

    CGContextRef ctx = [[NSGraphicsContext currentContext] CGContext];
    if (!ctx) { return; }

    [self.particleSystem drawInContext:ctx];

    if (self.diagnosticsEnabled) {
        NSString *metalLine = self.metalStatusText ?: @"Metal: inactive";
        NSUInteger alive = self.particleSystem.aliveParticleCount;
        NSString *overlay = [NSString stringWithFormat:@"Ribbon Flow Demo - %@ | FPS: %.1f (target %ld) | Alive: %lu | Metal success: %lu",
                             metalLine,
                             self.animationClock.framesPerSecond,
                             (long)self.targetFramesPerSecond,
                             (unsigned long)alive,
                             (unsigned long)self.metalSuccessCount];
        [SSKDiagnostics drawOverlayInView:self
                                    text:overlay
                         framesPerSecond:self.animationClock.framesPerSecond];
    }
}

- (void)updateEmittersWithDelta:(NSTimeInterval)dt {
    if (self.emitters.count == 0) { return; }
    RibbonFlowRegisterPalettes();
    SSKPaletteManager *manager = [SSKPaletteManager sharedManager];
    NSString *module = RibbonFlowPaletteModuleIdentifier();
    SSKColorPalette *palette = [manager paletteWithIdentifier:self.paletteIdentifier module:module];
    if (!palette) {
        NSString *fallback = RibbonFlowDefaultPaletteIdentifier();
        palette = [manager paletteWithIdentifier:fallback module:module];
    }

    NSRect bounds = NSInsetRect(self.bounds, 40.0, 40.0);
    if (bounds.size.width <= 0 || bounds.size.height <= 0) {
        bounds = self.bounds;
    }

    for (NSUInteger i = 0; i < self.emitters.count; i++) {
        RibbonFlowEmitter emitter;
        [self.emitters[i] getValue:&emitter];

        emitter.colorPhase += dt * 0.12;

        NSPoint toTarget = SSKVectorSubtract(emitter.target, emitter.position);
        CGFloat distance = SSKVectorLength(toTarget);
        if (distance < 50.0) {
            emitter.target = [self randomPointInRect:bounds];
            toTarget = SSKVectorSubtract(emitter.target, emitter.position);
            distance = SSKVectorLength(toTarget);
        }

        NSPoint direction = distance > 0.001 ? SSKVectorNormalize(toTarget) : [self randomUnitVector];
        NSPoint acceleration = SSKVectorScale(direction, emitter.intrinsicSpeed * 180.0 * dt);
        emitter.velocity = SSKVectorAdd(emitter.velocity, acceleration);
        emitter.velocity = SSKVectorClampLength(emitter.velocity, 40.0, 260.0);

        NSPoint step = SSKVectorScale(emitter.velocity, dt * self.speedMultiplier);
        emitter.position = SSKVectorAdd(emitter.position, step);

        if (!NSPointInRect(emitter.position, bounds)) {
            if (emitter.position.x < NSMinX(bounds) || emitter.position.x > NSMaxX(bounds)) {
                emitter.velocity.x *= -1.0;
            }
            if (emitter.position.y < NSMinY(bounds) || emitter.position.y > NSMaxY(bounds)) {
                emitter.velocity.y *= -1.0;
            }
            emitter.position.x = MIN(MAX(emitter.position.x, NSMinX(bounds)), NSMaxX(bounds));
            emitter.position.y = MIN(MAX(emitter.position.y, NSMinY(bounds)), NSMaxY(bounds));
            emitter.target = [self randomPointInRect:bounds];
        }

        [self emitParticlesForEmitter:&emitter palette:palette manager:manager module:module];

        self.emitters[i] = [NSValue valueWithBytes:&emitter objCType:@encode(RibbonFlowEmitter)];
    }
}

- (void)emitParticlesForEmitter:(RibbonFlowEmitter *)emitter
                        palette:(SSKColorPalette *)palette
                        manager:(SSKPaletteManager *)manager
                         module:(NSString *)module {
    if (!emitter) { return; }

    NSUInteger spawnCount = 2;
    NSPoint dir = emitter->velocity;
    if (SSKVectorLength(dir) < 0.001) {
        dir = [self randomUnitVector];
    }
    NSPoint unitDir = SSKVectorNormalize(dir);
    CGFloat baseSpeed = SSKVectorLength(dir);

    [self.particleSystem spawnParticles:spawnCount initializer:^(SSKParticle *particle) {
        CGFloat variation = ((CGFloat)arc4random() / UINT32_MAX) * 0.06;
        CGFloat progress = emitter->colorPhase + variation;
    NSColor *paletteColor = palette ?
        [manager colorForPalette:palette progress:progress interpolationMode:SSKPaletteInterpolationModeLoop] :
        [NSColor whiteColor];

    NSColor *srgb = [paletteColor colorUsingColorSpace:[NSColorSpace sRGBColorSpace]] ?: paletteColor;
    CGFloat hue = 0.0;
    CGFloat saturation = 0.0;
    CGFloat brightness = 0.0;
    CGFloat alpha = 1.0;
    if ([srgb colorSpace].colorSpaceModel == NSColorSpaceModelRGB) {
        [srgb getHue:&hue saturation:&saturation brightness:&brightness alpha:&alpha];
        brightness = MIN(brightness, 0.82);
        saturation = MIN(MAX(saturation, 0.45), 1.0);
        srgb = [NSColor colorWithHue:hue saturation:saturation brightness:brightness alpha:1.0];
    }

    CGFloat baseAlpha = self.additiveBlend ? 0.22 : 0.72;
    NSColor *color = [srgb colorWithAlphaComponent:baseAlpha];

    particle.position = emitter->position;
        particle.velocity = SSKVectorScale(unitDir, baseSpeed * 0.35);
        particle.maxLife = 1.15 + ((CGFloat)arc4random() / UINT32_MAX) * 0.45;
        particle.life = 0.0;
        particle.color = color;
        CGFloat sizeBase = self.trailWidth * (7.5 + ((CGFloat)arc4random() / UINT32_MAX) * 3.5);
        particle.size = sizeBase;
        particle.baseSize = sizeBase;
        particle.userScalar = self.softEdgesEnabled ? 4.5 : 0.0;
        particle.userVector = unitDir;
        particle.sizeOverLifeRange = SSKScalarRangeMake(1.0, 0.35);
        particle.behaviorOptions = (SSKParticleBehaviorOptionFadeAlpha | SSKParticleBehaviorOptionFadeSize);
    }];
}

- (NSPoint)randomPointInRect:(NSRect)rect {
    CGFloat x = rect.origin.x + ((CGFloat)arc4random() / UINT32_MAX) * rect.size.width;
    CGFloat y = rect.origin.y + ((CGFloat)arc4random() / UINT32_MAX) * rect.size.height;
    return NSMakePoint(x, y);
}

- (NSPoint)randomUnitVector {
    CGFloat angle = ((CGFloat)arc4random() / UINT32_MAX) * (CGFloat)(M_PI * 2.0);
    return NSMakePoint(cos(angle), sin(angle));
}

- (void)configureParticleRenderHandler {
    __weak typeof(self) weakSelf = self;
    self.particleSystem.renderHandler = ^(CGContextRef ctx, SSKParticle *particle) {
        CGFloat t = particle.life / MAX(0.0001, particle.maxLife);
        CGFloat fade = 1.0 - t;
        CGFloat width = MAX(1.0, particle.size);
        CGFloat length = width * (2.4 + 6.0 * fade);
        NSPoint dir = particle.userVector;
        if (SSKVectorLength(dir) < 0.0001) {
            dir = [weakSelf randomUnitVector];
        }
        CGFloat angle = atan2(dir.y, dir.x);

        NSColor *color = particle.color ?: [NSColor whiteColor];
        CGFloat alpha = color.alphaComponent * fade;
        NSColor *core = [color colorWithAlphaComponent:alpha];

        if (weakSelf.softEdgesEnabled) {
            NSColor *startColor = [core colorUsingColorSpace:[NSColorSpace deviceRGBColorSpace]] ?: core;
            CGFloat startComponents[4] = {startColor.redComponent, startColor.greenComponent, startColor.blueComponent, startColor.alphaComponent};
            CGFloat midComponents[4] = {startComponents[0], startComponents[1], startComponents[2], startComponents[3] * 0.45f};
            CGFloat endComponents[4] = {startComponents[0], startComponents[1], startComponents[2], 0.0f};
            CGFloat components[12] = {
                startComponents[0], startComponents[1], startComponents[2], startComponents[3],
                midComponents[0], midComponents[1], midComponents[2], midComponents[3],
                endComponents[0], endComponents[1], endComponents[2], endComponents[3]
            };
            CGFloat locations[3] = {0.0, 0.55, 1.0};
            CGColorSpaceRef space = CGColorSpaceCreateDeviceRGB();
            if (space) {
                CGGradientRef gradient = CGGradientCreateWithColorComponents(space, components, locations, 3);
                if (gradient) {
                    CGContextSaveGState(ctx);
                    CGContextTranslateCTM(ctx, particle.position.x, particle.position.y);
                    CGContextRotateCTM(ctx, angle);
                    CGContextScaleCTM(ctx, length * 0.5, width * 0.5);
                    CGContextDrawRadialGradient(ctx,
                                                gradient,
                                                CGPointZero,
                                                0.0,
                                                CGPointZero,
                                                1.0,
                                                kCGGradientDrawsAfterEndLocation);
                    CGContextRestoreGState(ctx);
                    CGGradientRelease(gradient);
                }
                CGColorSpaceRelease(space);
            }
            return;
        }

        CGColorRef glow = CGColorCreateCopyWithAlpha(core.CGColor, alpha * 0.75);
        CGContextSaveGState(ctx);
        CGContextTranslateCTM(ctx, particle.position.x, particle.position.y);
        CGContextRotateCTM(ctx, angle);
        if (glow) {
            CGContextSetShadowWithColor(ctx, CGSizeZero, width * 0.9, glow);
        }
        CGRect rect = CGRectMake(-length * 0.5, -width * 0.5, length, width);
        CGMutablePathRef path = CGPathCreateMutable();
        CGPathAddRoundedRect(path, NULL, rect, width * 0.5, width * 0.5);
        CGContextAddPath(ctx, path);
        CGContextSetFillColorWithColor(ctx, core.CGColor);
        CGContextFillPath(ctx);
        CGPathRelease(path);
        if (glow) {
            CGContextSetShadowWithColor(ctx, CGSizeZero, 0.0, NULL);
            CGColorRelease(glow);
        }
        CGContextRestoreGState(ctx);
    };
}

- (void)updateMetalSupportIfNeeded {
    [self ensureMetalDevice];
    [self ensureMetalLayer];
    [self ensureMetalRenderer];
    if (self.metalLayer && self.layer != self.metalLayer) {
        self.layer = self.metalLayer;
    }
    [self updateMetalLayerDrawableSize];
}

- (void)updateMetalLayerDrawableSize {
    if (!self.metalLayer) { return; }
    CGFloat scale = 1.0;
    if (self.window) {
        scale = self.window.backingScaleFactor;
    } else if (NSScreen.mainScreen) {
        scale = NSScreen.mainScreen.backingScaleFactor;
    }
    self.metalLayer.contentsScale = scale;
    self.metalLayer.frame = self.bounds;
    self.metalLayer.drawableSize = CGSizeMake(self.bounds.size.width * scale,
                                              self.bounds.size.height * scale);
}

- (void)ensureMetalDevice {
    if (self.metalDevice) { return; }
    id<MTLDevice> device = MTLCreateSystemDefaultDevice();
    if (!device) {
        self.metalEnabled = NO;
        self.metalStatusText = @"Metal: device unavailable";
        return;
    }
    self.metalDevice = device;
    self.metalStatusText = [NSString stringWithFormat:@"Metal: device %@", device.name];
}

- (void)ensureMetalLayer {
    if (self.metalLayer || !self.metalDevice) { return; }
    if (!self.window) {
        self.metalStatusText = @"Metal: waiting for window";
        return;
    }

    self.wantsLayer = YES;
    CAMetalLayer *layer = [CAMetalLayer layer];
    layer.device = self.metalDevice;
    layer.pixelFormat = MTLPixelFormatBGRA8Unorm;
    layer.framebufferOnly = YES;
    layer.opaque = YES;
    layer.needsDisplayOnBoundsChange = YES;
    layer.backgroundColor = NSColor.blackColor.CGColor;
    if ([layer respondsToSelector:@selector(setPresentsWithTransaction:)]) {
        layer.presentsWithTransaction = NO;
    }
#if defined(__MAC_OS_X_VERSION_MAX_ALLOWED) && __MAC_OS_X_VERSION_MAX_ALLOWED >= 101300
    if (@available(macOS 10.13, *)) {
        layer.displaySyncEnabled = YES;
    }
#endif
    self.layer = layer;
    if ([self respondsToSelector:@selector(setLayerContentsRedrawPolicy:)]) {
        self.layerContentsRedrawPolicy = NSViewLayerContentsRedrawNever;
    }
    self.metalLayer = layer;
    self.metalStatusText = @"Metal: layer attached";
    [self ensureMetalStatusLayer];
}

- (void)ensureMetalRenderer {
    if (!self.metalLayer || self.metalRenderer) { return; }
    SSKMetalParticleRenderer *renderer = [[SSKMetalParticleRenderer alloc] initWithLayer:self.metalLayer];
    if (!renderer) {
        NSString *error = [SSKMetalParticleRenderer lastCreationErrorMessage];
        self.metalEnabled = NO;
        self.metalStatusText = error.length ? [NSString stringWithFormat:@"Metal: renderer init failed (%@)", error] :
                                              @"Metal: renderer init failed";
        return;
    }
    self.metalRenderer = renderer;
    self.metalEnabled = YES;
    self.metalStatusText = @"Metal: renderer initialised";
}

- (void)ensureMetalStatusLayer {
    if (!self.diagnosticsEnabled) { return; }
    if (!self.metalLayer || self.metalStatusLayer) { return; }
    CATextLayer *textLayer = [CATextLayer layer];
    textLayer.alignmentMode = kCAAlignmentLeft;
    textLayer.foregroundColor = [NSColor colorWithCalibratedWhite:0.95 alpha:1.0].CGColor;
    textLayer.backgroundColor = [NSColor colorWithCalibratedWhite:0 alpha:0.55].CGColor;
    textLayer.cornerRadius = 8.0;
    textLayer.masksToBounds = YES;
    textLayer.wrapped = YES;
    CGFloat scale = 1.0;
    if (self.window) {
        scale = self.window.backingScaleFactor;
    } else if (NSScreen.mainScreen) {
        scale = NSScreen.mainScreen.backingScaleFactor;
    }
    textLayer.contentsScale = scale;
    textLayer.font = (__bridge CFTypeRef)[NSFont monospacedDigitSystemFontOfSize:12 weight:NSFontWeightRegular];
    textLayer.fontSize = 12.0;
    [self.metalLayer addSublayer:textLayer];
    self.metalStatusLayer = textLayer;
    [self layoutMetalStatusLayer];
    [self updateMetalStatusLayerString];
}

- (void)layoutMetalStatusLayer {
    if (!self.metalStatusLayer) { return; }
    if (!self.diagnosticsEnabled) {
        self.metalStatusLayer.hidden = YES;
        return;
    }
    CGFloat scale = 1.0;
    if (self.window) {
        scale = self.window.backingScaleFactor;
    } else if (NSScreen.mainScreen) {
        scale = NSScreen.mainScreen.backingScaleFactor;
    }
    CGFloat width = MIN(self.bounds.size.width - 32.0, 420.0);
    CGFloat height = 80.0;
    self.metalStatusLayer.frame = CGRectMake(18.0,
                                             self.bounds.size.height - height - 18.0,
                                             width,
                                             height);
    self.metalStatusLayer.contentsScale = scale;
}

- (void)updateMetalStatusLayerString {
    if (!self.metalStatusLayer) { return; }
    if (!self.diagnosticsEnabled) {
        self.metalStatusLayer.hidden = YES;
        return;
    }
    self.metalStatusLayer.hidden = NO;
    NSString *status = self.metalStatusText.length ? self.metalStatusText : @"Metal: inactive";
    double fps = self.animationClock.framesPerSecond;
    NSUInteger alive = self.particleSystem.aliveParticleCount;
    NSString *metrics = [NSString stringWithFormat:@"FPS: %.1f (target %ld)    Alive: %lu    Metal success: %lu",
                         fps,
                         (long)self.targetFramesPerSecond,
                         (unsigned long)alive,
                         (unsigned long)self.metalSuccessCount];
    self.metalStatusLayer.string = [NSString stringWithFormat:@"%@\n%@",
                                    status,
                                    metrics];
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
                                                                                   title:@"Ribbon Flow"
                                                                                subtitle:@"Flowing ribbons inspired by the classic Apple screensaver."];
    SSKPreferenceBinder *binder = self.configController.preferenceBinder;
    NSStackView *stack = self.configController.contentStack;

    [stack addArrangedSubview:[self sliderRowWithTitle:@"Emitter Count"
                                             minValue:1
                                             maxValue:12
                                                  key:kPrefEmitterCount
                                               format:@"%.0f"
                                                binder:binder]];

    [stack addArrangedSubview:[self sliderRowWithTitle:@"Speed"
                                             minValue:0.4
                                             maxValue:3.0
                                                  key:kPrefSpeed
                                               format:@"%.2fx"
                                                binder:binder]];

    [stack addArrangedSubview:[self sliderRowWithTitle:@"Trail Width"
                                             minValue:0.4
                                             maxValue:3.0
                                                  key:kPrefTrailWidth
                                               format:@"%.2f"
                                                binder:binder]];

    [stack addArrangedSubview:[self paletteRowWithBinder:binder]];

    NSButton *blendToggle = [NSButton checkboxWithTitle:@"Use additive glow" target:nil action:nil];
    [binder bindCheckbox:blendToggle key:kPrefAdditiveBlend];
    [stack addArrangedSubview:blendToggle];

    NSButton *diagnosticsToggle = [NSButton checkboxWithTitle:@"Show diagnostics overlay" target:nil action:nil];
    [binder bindCheckbox:diagnosticsToggle key:kPrefDiagnostics];
    [stack addArrangedSubview:diagnosticsToggle];

    NSButton *softEdgesToggle = [NSButton checkboxWithTitle:@"Use soft-edged trails" target:nil action:nil];
    [binder bindCheckbox:softEdgesToggle key:kPrefSoftEdges];
    [stack addArrangedSubview:softEdgesToggle];

    NSTextField *fpsLabel = [NSTextField labelWithString:@"Frame Rate"];
    fpsLabel.font = [NSFont systemFontOfSize:12 weight:NSFontWeightRegular];
    NSPopUpButton *fpsPopup = [[NSPopUpButton alloc] initWithFrame:NSZeroRect pullsDown:NO];
    [fpsPopup addItemWithTitle:@"30 FPS"];
    fpsPopup.lastItem.representedObject = @"30";
    [fpsPopup addItemWithTitle:@"60 FPS"];
    fpsPopup.lastItem.representedObject = @"60";
    [binder bindPopUpButton:fpsPopup key:kPrefFrameRate];

    NSStackView *fpsRow = [[NSStackView alloc] initWithFrame:NSZeroRect];
    fpsRow.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    fpsRow.spacing = 8.0;
    [fpsRow addArrangedSubview:fpsLabel];
    [fpsRow addArrangedSubview:fpsPopup];
    [fpsPopup setContentHuggingPriority:NSLayoutPriorityDefaultHigh forOrientation:NSLayoutConstraintOrientationHorizontal];
    [stack addArrangedSubview:fpsRow];
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
    NSTextField *label = [NSTextField labelWithString:@"Colour Palette"];
    label.font = [NSFont systemFontOfSize:12 weight:NSFontWeightRegular];
    [label setContentHuggingPriority:NSLayoutPriorityDefaultHigh
                       forOrientation:NSLayoutConstraintOrientationHorizontal];

    NSPopUpButton *popUp = [[NSPopUpButton alloc] initWithFrame:NSZeroRect pullsDown:NO];
    [popUp removeAllItems];

    RibbonFlowRegisterPalettes();
    NSArray<SSKColorPalette *> *palettes = [[SSKPaletteManager sharedManager] palettesForModule:RibbonFlowPaletteModuleIdentifier()];
    for (SSKColorPalette *palette in palettes) {
        NSString *title = palette.displayName.length ? palette.displayName : @"Palette";
        [popUp addItemWithTitle:title];
        NSMenuItem *item = [popUp itemAtIndex:popUp.numberOfItems - 1];
        item.representedObject = palette.identifier;
    }
    if (popUp.numberOfItems == 0) {
        NSString *fallback = RibbonFlowDefaultPaletteIdentifier();
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

- (SSKColorPalette *)currentPalette {
    SSKPaletteManager *manager = [SSKPaletteManager sharedManager];
    NSString *module = RibbonFlowPaletteModuleIdentifier();
    SSKColorPalette *palette = [manager paletteWithIdentifier:self.paletteIdentifier module:module];
    if (!palette) {
        palette = [manager paletteWithIdentifier:RibbonFlowDefaultPaletteIdentifier() module:module];
    }
    if (!palette) {
        palette = [[manager palettesForModule:module] firstObject];
    }
    return palette;
}

- (void)preferencesDidChange:(NSDictionary<NSString *,id> *)preferences
                 changedKeys:(NSSet<NSString *> *)changedKeys {
    [self applyPreferences:preferences changedKeys:changedKeys];
}

- (void)applyPreferences:(NSDictionary<NSString *,id> *)preferences
             changedKeys:(NSSet<NSString *> *)changedKeys {
    RibbonFlowRegisterPalettes();
    NSDictionary *defaults = [self defaultPreferences];

    NSUInteger newEmitterCount = [preferences[kPrefEmitterCount] respondsToSelector:@selector(unsignedIntegerValue)] ?
        [preferences[kPrefEmitterCount] unsignedIntegerValue] :
        [defaults[kPrefEmitterCount] unsignedIntegerValue];
    newEmitterCount = MIN(MAX(newEmitterCount, 1u), 24u);

    double speed = [preferences[kPrefSpeed] respondsToSelector:@selector(doubleValue)] ?
        [preferences[kPrefSpeed] doubleValue] :
        [defaults[kPrefSpeed] doubleValue];
    self.speedMultiplier = MAX(0.2, speed);

    double width = [preferences[kPrefTrailWidth] respondsToSelector:@selector(doubleValue)] ?
        [preferences[kPrefTrailWidth] doubleValue] :
        [defaults[kPrefTrailWidth] doubleValue];
    self.trailWidth = MAX(0.1, width);

    NSString *paletteValue = [preferences[kPrefPalette] isKindOfClass:[NSString class]] ?
        preferences[kPrefPalette] : defaults[kPrefPalette];
    if (![paletteValue isKindOfClass:[NSString class]] || paletteValue.length == 0) {
        paletteValue = RibbonFlowDefaultPaletteIdentifier();
    }
    self.paletteIdentifier = paletteValue;

    BOOL additive = [preferences[kPrefAdditiveBlend] respondsToSelector:@selector(boolValue)] ?
        [preferences[kPrefAdditiveBlend] boolValue] :
        [defaults[kPrefAdditiveBlend] boolValue];
    self.additiveBlend = additive;
    self.particleSystem.globalDamping = additive ? 0.18 : 0.15;

    BOOL diagnostics = [preferences[kPrefDiagnostics] respondsToSelector:@selector(boolValue)] ?
        [preferences[kPrefDiagnostics] boolValue] :
        [defaults[kPrefDiagnostics] boolValue];
    self.diagnosticsEnabled = diagnostics;

    BOOL softEdges = [preferences[kPrefSoftEdges] respondsToSelector:@selector(boolValue)] ?
        [preferences[kPrefSoftEdges] boolValue] :
        [defaults[kPrefSoftEdges] boolValue];
    self.softEdgesEnabled = softEdges;

    NSString *frameRateString = nil;
    id frameRateValue = preferences[kPrefFrameRate];
    if ([frameRateValue isKindOfClass:[NSString class]]) {
        frameRateString = frameRateValue;
    } else if ([frameRateValue respondsToSelector:@selector(stringValue)]) {
        frameRateString = [frameRateValue stringValue];
    } else {
        id defaultFrameRate = defaults[kPrefFrameRate];
        if ([defaultFrameRate isKindOfClass:[NSString class]]) {
            frameRateString = defaultFrameRate;
        }
    }
    NSInteger fps = frameRateString.length ? frameRateString.integerValue : 30;
    if (fps != 60) { fps = 30; }
    self.targetFramesPerSecond = fps;
    self.animationTimeInterval = 1.0 / MAX(1, fps);

    if (newEmitterCount != self.emitterCount || (changedKeys && [changedKeys containsObject:kPrefEmitterCount])) {
        self.emitterCount = newEmitterCount;
        [self rebuildEmitters];
    }

    [self configureParticleRenderHandler];
}

@end
