#import "RibbonFlowView.h"

#import <AppKit/AppKit.h>
#import <QuartzCore/QuartzCore.h>
#import <CoreImage/CoreImage.h>
#import <Metal/Metal.h>

#import "RibbonFlowPalettes.h"

#import "ScreenSaverKit/SSKColorUtilities.h"
#import "ScreenSaverKit/SSKConfigurationWindowController.h"
#import "ScreenSaverKit/SSKDiagnostics.h"
#import "ScreenSaverKit/SSKMetalRenderer.h"
#import "ScreenSaverKit/SSKLayerEffects.h"
#import "ScreenSaverKit/SSKMetalRenderDiagnostics.h"
#import "ScreenSaverKit/SSKPaletteManager.h"
#import "ScreenSaverKit/SSKParticleSystem.h"
#import "ScreenSaverKit/SSKPreferenceBinder.h"
#import "ScreenSaverKit/SSKVectorMath.h"

static NSString * const kPrefEmitterCount    = @"ribbonFlowEmitterCount";
static NSString * const kPrefSpeed           = @"ribbonFlowSpeed";
static NSString * const kPrefPalette         = @"ribbonFlowPalette";
static NSString * const kPrefTrailWidth      = @"ribbonFlowTrailWidth";
static NSString * const kPrefAdditiveBlend   = @"ribbonFlowAdditiveBlend";
static NSString * const kPrefDiagnostics     = @"ribbonFlowDiagnostics";
static NSString * const kPrefSoftEdges       = @"ribbonFlowSoftEdges";
static NSString * const kPrefFrameRate       = @"ribbonFlowFrameRate";
static NSString * const kPrefTrailOpacity    = @"ribbonFlowTrailOpacity";
static NSString * const kPrefBlurRadius      = @"ribbonFlowBlurRadius";
static NSString * const kPrefBloomIntensity  = @"ribbonFlowBloomIntensity";
static NSString * const kPrefBloomThreshold  = @"ribbonFlowBloomThreshold";

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
@property (nonatomic) BOOL metalRenderingActive;
@property (nonatomic, strong) SSKMetalRenderDiagnostics *renderDiagnostics;
@property (nonatomic, copy) NSString *metalStatusText;
@property (nonatomic, copy) NSString *cachedOverlayString;
@property (nonatomic, getter=isDiagnosticsEnabled) BOOL diagnosticsEnabled;
@property (nonatomic) BOOL softEdgesEnabled;
@property (nonatomic) NSInteger targetFramesPerSecond;
@property (nonatomic) CGFloat trailOpacity;
@property (nonatomic) CGFloat blurRadius;
@property (nonatomic) CGFloat bloomIntensity;
@property (nonatomic) CGFloat bloomThreshold;
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
        kPrefTrailOpacity: @(0.6),
        kPrefBlurRadius: @(0.0),
        kPrefBloomIntensity: @(0.25),
        kPrefBloomThreshold: @(0.85),
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
        self.metalRenderingActive = NO;
        self.diagnosticsEnabled = YES;
        self.softEdgesEnabled = YES;
        self.targetFramesPerSecond = 30;
        self.trailOpacity = 0.6;
        self.blurRadius = 0.0;
        self.bloomIntensity = 0.25;
        self.bloomThreshold = 0.85;
        _renderDiagnostics = [[SSKMetalRenderDiagnostics alloc] init];
        _renderDiagnostics.overlayEnabled = self.diagnosticsEnabled;
        _renderDiagnostics.deviceStatus = @"Device: pending";
        _renderDiagnostics.layerStatus = @"Layer: awaiting attachment";
        _renderDiagnostics.rendererStatus = @"Renderer: idle";
        _renderDiagnostics.drawableStatus = @"Drawable: not attempted";
        self.metalStatusText = @"Metal: initialising";
        _cachedOverlayString = @"Ribbon Flow Demo – diagnostics pending";

        [self configureParticleRenderHandler];

        NSDictionary *prefs = [self currentPreferences];
        NSSet *keys = [NSSet setWithArray:prefs.allKeys];
        [self applyPreferences:prefs changedKeys:keys];
        [self rebuildEmitters];
    }
    return self;
}

- (void)setupMetalRenderer:(SSKMetalRenderer *)renderer {
    [super setupMetalRenderer:renderer];
    renderer.clearColor = MTLClearColorMake(0.0, 0.0, 0.0, 1.0);
    renderer.bloomThreshold = self.bloomThreshold;
    [self.renderDiagnostics attachToMetalLayer:self.metalLayer];
    id<MTLDevice> device = renderer.device;
    if (device) {
        self.renderDiagnostics.deviceStatus = [NSString stringWithFormat:@"Device: %@ (lowPower=%@ removable=%@)",
                                               device.name ?: @"Unknown",
                                               device.isLowPower ? @"YES" : @"NO",
                                               device.isRemovable ? @"YES" : @"NO"];
    } else {
        self.renderDiagnostics.deviceStatus = @"Device: unavailable";
    }
    self.renderDiagnostics.layerStatus = @"Layer: CAMetalLayer attached";
    self.renderDiagnostics.rendererStatus = @"Renderer: initialised";
    self.renderDiagnostics.drawableStatus = @"Drawable: awaiting frame";
    [self updateDiagnosticsOverlay];
}

- (void)setMetalStatusText:(NSString *)metalStatusText {
    if ((_metalStatusText == metalStatusText) || [_metalStatusText isEqualToString:metalStatusText]) {
        return;
    }
    _metalStatusText = [metalStatusText copy];
    [self updateDiagnosticsOverlay];
}

- (void)setDiagnosticsEnabled:(BOOL)diagnosticsEnabled {
    if (_diagnosticsEnabled == diagnosticsEnabled) { return; }
    _diagnosticsEnabled = diagnosticsEnabled;
    [SSKDiagnostics setEnabled:diagnosticsEnabled];
    self.renderDiagnostics.overlayEnabled = diagnosticsEnabled;
    if (!diagnosticsEnabled) {
        [self setNeedsDisplay:YES];
    }
    [self updateDiagnosticsOverlay];
}

- (void)setSoftEdgesEnabled:(BOOL)softEdgesEnabled {
    if (_softEdgesEnabled == softEdgesEnabled) { return; }
    _softEdgesEnabled = softEdgesEnabled;
    [self configureParticleRenderHandler];
    [self setNeedsDisplay:YES];
}

- (void)setBlurRadius:(CGFloat)blurRadius {
    CGFloat clamped = MAX(0.0, blurRadius);
    if (fabs(_blurRadius - clamped) < 0.001) { return; }
    _blurRadius = clamped;
    [self updateLayerBlurFilter];
    if (_blurRadius > 0.01) {
        self.metalStatusText = @"Metal: gaussian blur active";
    }
    [self setNeedsDisplay:YES];
    [self updateDiagnosticsOverlay];
}

- (void)setBloomIntensity:(CGFloat)bloomIntensity {
    CGFloat clamped = MAX(0.0, bloomIntensity);
    if (fabs(_bloomIntensity - clamped) < 0.001) { return; }
    _bloomIntensity = clamped;
    if (self.metalRenderer) {
        // No direct property, applied on demand via applyBloom:
        // but we update renderer's threshold/blur below when threshold setter fires.
    }
    [self updateDiagnosticsOverlay];
}

- (void)setBloomThreshold:(CGFloat)bloomThreshold {
    CGFloat clamped = MIN(MAX(bloomThreshold, 0.0), 1.0);
    if (fabs(_bloomThreshold - clamped) < 0.001) { return; }
    _bloomThreshold = clamped;
    if (self.metalRenderer) {
        self.metalRenderer.bloomThreshold = clamped;
    }
    [self updateDiagnosticsOverlay];
}

- (void)setTrailOpacity:(CGFloat)trailOpacity {
    CGFloat clamped = MIN(MAX(trailOpacity, 0.05), 1.0);
    if (fabs(_trailOpacity - clamped) < 0.001) { return; }
    _trailOpacity = clamped;
    [self setNeedsDisplay:YES];
}

- (void)setFrame:(NSRect)frame {
    [super setFrame:frame];
    [self clampEmittersToBounds];
}

- (void)viewDidMoveToWindow {
    [super viewDidMoveToWindow];
    [self updateDiagnosticsOverlay];
}

- (void)layout {
    [super layout];
    [self updateDiagnosticsOverlay];
    if (!self.metalLayer && self.layer) {
        self.layer.frame = self.bounds;
        [self updateLayerBlurFilter];
    }
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

- (void)stepSimulationWithDeltaTime:(NSTimeInterval)dt {
    NSTimeInterval clamped = (dt <= 0.0) ? (1.0 / MAX(self.targetFramesPerSecond, 1)) : dt;
    [self updateEmittersWithDelta:clamped];
    self.particleSystem.blendMode = self.additiveBlend ? SSKParticleBlendModeAdditive : SSKParticleBlendModeAlpha;
    [self.particleSystem advanceBy:clamped];
}

- (void)renderMetalFrame:(SSKMetalRenderer *)renderer deltaTime:(NSTimeInterval)dt {
    [self stepSimulationWithDeltaTime:dt];

    renderer.clearColor = MTLClearColorMake(0.0, 0.0, 0.0, 1.0);
    NSArray<SSKParticle *> *particles = [self.particleSystem aliveParticlesSnapshot];
    [renderer drawParticles:particles
                  blendMode:self.particleSystem.blendMode
               viewportSize:self.bounds.size];

    CGFloat blurRadius = self.blurRadius;
    if (blurRadius > 0.01) {
        [renderer applyBlur:blurRadius];
    }

    CGFloat bloomIntensity = self.bloomIntensity;
    if (bloomIntensity > 0.01) {
        renderer.bloomThreshold = self.bloomThreshold;
        // Scale bloom intensity down when using additive blend to prevent white blowout
        CGFloat effectiveIntensity = self.additiveBlend ? bloomIntensity * 0.5 : bloomIntensity;
        renderer.bloomBlurSigma = 2.5;  // Fixed moderate blur
        [renderer applyBloom:effectiveIntensity];
    }

    self.metalRenderingActive = YES;
    [self.renderDiagnostics recordMetalAttemptWithSuccess:YES];
    self.renderDiagnostics.rendererStatus = @"Renderer: active (Metal)";
    self.renderDiagnostics.drawableStatus = [NSString stringWithFormat:@"Drawable: presented (successes %lu)",
                                             (unsigned long)self.renderDiagnostics.metalSuccessCount];
    if (self.metalLayer) {
        [self.renderDiagnostics attachToMetalLayer:self.metalLayer];
    }
    if (blurRadius > 0.01) {
        self.metalStatusText = [NSString stringWithFormat:@"Metal: active (blur %.1f, successes %lu)",
                                blurRadius,
                                (unsigned long)self.renderDiagnostics.metalSuccessCount];
    } else {
        self.metalStatusText = [NSString stringWithFormat:@"Metal: active (successes %lu)",
                                (unsigned long)self.renderDiagnostics.metalSuccessCount];
    }
    [self updateDiagnosticsOverlay];
}

- (void)renderCPUFrameWithDeltaTime:(NSTimeInterval)dt {
    [self stepSimulationWithDeltaTime:dt];

    self.metalRenderingActive = NO;
    if (self.useMetalPipeline) {
        [self.renderDiagnostics recordMetalAttemptWithSuccess:NO];
        if (self.metalAvailable) {
            self.metalStatusText = [NSString stringWithFormat:@"Metal: fallback (failures %lu)",
                                    (unsigned long)self.renderDiagnostics.metalFailureCount];
            self.renderDiagnostics.rendererStatus = @"Renderer: CPU fallback";
        } else {
            self.metalStatusText = @"Metal: unavailable";
            self.renderDiagnostics.rendererStatus = @"Renderer: waiting for Metal availability";
        }
        self.renderDiagnostics.drawableStatus = [NSString stringWithFormat:@"Drawable: fallback (failures %lu)",
                                                 (unsigned long)self.renderDiagnostics.metalFailureCount];
    } else {
        self.metalStatusText = @"Metal: disabled";
        self.renderDiagnostics.rendererStatus = @"Renderer: Metal disabled";
        self.renderDiagnostics.drawableStatus = @"Drawable: CPU-only mode";
    }
    [self updateDiagnosticsOverlay];
    [self ensureFallbackLayer];
    [self updateLayerBlurFilter];
    [self setNeedsDisplay:YES];
}

- (void)updateDiagnosticsOverlay {
    if (!self.renderDiagnostics) { return; }
    if (!self.diagnosticsEnabled) {
        self.renderDiagnostics.overlayEnabled = NO;
        self.cachedOverlayString = nil;
        return;
    }
    self.renderDiagnostics.overlayEnabled = YES;
    if (self.metalLayer) {
        [self.renderDiagnostics attachToMetalLayer:self.metalLayer];
        CGSize drawableSize = self.metalLayer.drawableSize;
        if (drawableSize.width > 0.0 && drawableSize.height > 0.0) {
            self.renderDiagnostics.layerStatus = [NSString stringWithFormat:@"Layer: CAMetalLayer %.0fx%.0f",
                                                  drawableSize.width,
                                                  drawableSize.height];
        } else {
            self.renderDiagnostics.layerStatus = @"Layer: CAMetalLayer (awaiting drawable)";
        }
    } else {
        self.renderDiagnostics.layerStatus = @"Layer: fallback CALayer";
    }
    NSString *statusLine = self.metalStatusText.length ? self.metalStatusText : @"Metal: inactive";
    NSString *particlesLine = [NSString stringWithFormat:@"Alive: %lu | Target FPS: %ld | Blend: %@",
                               (unsigned long)self.particleSystem.aliveParticleCount,
                               (long)self.targetFramesPerSecond,
                               self.additiveBlend ? @"Additive" : @"Alpha"];
    NSArray<NSString *> *extraLines = @[statusLine, particlesLine];
    double fps = self.animationClock.framesPerSecond;
    NSString *title = @"Ribbon Flow Demo";
    self.cachedOverlayString = [self.renderDiagnostics overlayStringWithTitle:title
                                                                   extraLines:extraLines
                                                              framesPerSecond:fps];
    [self.renderDiagnostics updateOverlayWithTitle:title
                                         extraLines:extraLines
                                    framesPerSecond:fps];
}

- (void)drawRect:(NSRect)dirtyRect {
    if (self.metalRenderingActive && self.metalRenderer) { return; }
    [self ensureFallbackLayer];
    [self updateLayerBlurFilter];

    CGContextRef ctx = [[NSGraphicsContext currentContext] CGContext];
    if (!ctx) { return; }

    [[NSColor blackColor] setFill];
    NSRectFill(dirtyRect);

    [self.particleSystem drawInContext:ctx];

    if (self.diagnosticsEnabled && self.cachedOverlayString.length > 0) {
        NSArray<NSString *> *lines = [self.cachedOverlayString componentsSeparatedByString:@"\n"];
        NSDictionary *attrs = @{ NSFontAttributeName: [NSFont monospacedDigitSystemFontOfSize:12 weight:NSFontWeightRegular],
                                  NSForegroundColorAttributeName: [NSColor colorWithCalibratedWhite:0.95 alpha:1.0] };
        CGFloat lineHeight = 18.0;
        CGFloat totalHeight = lineHeight * lines.count;
        CGFloat padding = 18.0;
        CGFloat x = NSMinX(self.bounds) + padding;
        CGFloat y = NSMaxY(self.bounds) - totalHeight - padding;

        CGFloat maxWidth = 0.0;
        for (NSString *line in lines) {
            NSSize size = [line sizeWithAttributes:attrs];
            maxWidth = MAX(maxWidth, size.width);
        }

        NSRect panel = NSMakeRect(x - 10.0,
                                  y - 10.0,
                                  MIN(maxWidth + 20.0, self.bounds.size.width - 20.0),
                                  totalHeight + 20.0);
        [[NSColor colorWithCalibratedWhite:0 alpha:0.6] setFill];
        [[NSBezierPath bezierPathWithRoundedRect:panel xRadius:8 yRadius:8] fill];

        for (NSString *line in lines) {
            [line drawAtPoint:NSMakePoint(x, y) withAttributes:attrs];
            y += lineHeight;
        }
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
        // Reduce brightness more when additive to prevent bloom blowout
        brightness = self.additiveBlend ? MIN(brightness, 0.65) : MIN(brightness, 0.82);
        saturation = MIN(MAX(saturation, 0.45), 1.0);
        srgb = [NSColor colorWithHue:hue saturation:saturation brightness:brightness alpha:1.0];
    }

    CGFloat alphaScale = self.additiveBlend ? 0.4 : 1.0;
    CGFloat baseAlpha = MIN(1.0, MAX(0.02, self.trailOpacity) * alphaScale);
    NSColor *color = [srgb colorWithAlphaComponent:baseAlpha];

    particle.position = emitter->position;
        particle.velocity = SSKVectorScale(unitDir, baseSpeed * 0.35);
        particle.maxLife = 1.15 + ((CGFloat)arc4random() / UINT32_MAX) * 0.45;
        particle.life = 0.0;
        particle.color = color;
        CGFloat sizeBase = self.trailWidth * (7.5 + ((CGFloat)arc4random() / UINT32_MAX) * 3.5);
        particle.size = sizeBase;
        particle.baseSize = sizeBase;
        particle.userScalar = self.softEdgesEnabled ? 6.0 : 0.0;
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
            CGContextSaveGState(ctx);
            CGContextSetBlendMode(ctx, weakSelf.additiveBlend ? kCGBlendModePlusLighter : kCGBlendModeNormal);
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
                    CGGradientRelease(gradient);
                }
                CGColorSpaceRelease(space);
            }
            CGContextRestoreGState(ctx);
            return;
        }

        CGColorRef glow = CGColorCreateCopyWithAlpha(core.CGColor, alpha * 0.75);
        CGContextSaveGState(ctx);
        CGContextSetBlendMode(ctx, weakSelf.additiveBlend ? kCGBlendModePlusLighter : kCGBlendModeNormal);
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

- (void)ensureFallbackLayer {
    if (self.metalLayer) { return; }
    if (!self.layer) {
        self.wantsLayer = YES;
        CALayer *layer = [CALayer layer];
        layer.backgroundColor = NSColor.blackColor.CGColor;
        CGFloat scale = 1.0;
        if (self.window) {
            scale = self.window.backingScaleFactor;
        } else if (NSScreen.mainScreen) {
            scale = NSScreen.mainScreen.backingScaleFactor;
        }
        layer.contentsScale = scale;
        layer.frame = self.bounds;
        self.layer = layer;
    }
    [self updateLayerBlurFilter];
}

- (void)updateLayerBlurFilter {
    CGFloat radius = MAX(0.0, self.blurRadius);
    if (self.metalLayer) {
        [SSKLayerEffects applyGaussianBlurWithRadius:0.0 toLayer:self.metalLayer];
    }
    if (self.layer && self.layer != self.metalLayer) {
        [SSKLayerEffects applyGaussianBlurWithRadius:radius toLayer:self.layer];
    }
}

// Placeholder methods removed - blur handled via layer filters now.

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

    [stack addArrangedSubview:[self sliderRowWithTitle:@"Trail Opacity"
                                             minValue:0.1
                                             maxValue:1.0
                                                  key:kPrefTrailOpacity
                                               format:@"%.2f"
                                                binder:binder]];

    [stack addArrangedSubview:[self sliderRowWithTitle:@"Blur Radius"
                                             minValue:0.0
                                             maxValue:8.0
                                                  key:kPrefBlurRadius
                                               format:@"%.1f"
                                                binder:binder]];

    [stack addArrangedSubview:[self sliderRowWithTitle:@"Bloom Intensity"
                                             minValue:0.0
                                             maxValue:0.8
                                                  key:kPrefBloomIntensity
                                               format:@"%.2f"
                                                binder:binder]];

    [stack addArrangedSubview:[self sliderRowWithTitle:@"Bloom Threshold"
                                             minValue:0.5
                                             maxValue:0.95
                                                  key:kPrefBloomThreshold
                                               format:@"%.2f"
                                                binder:binder]];

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

    double blur = [preferences[kPrefBlurRadius] respondsToSelector:@selector(doubleValue)] ?
        [preferences[kPrefBlurRadius] doubleValue] :
        [defaults[kPrefBlurRadius] doubleValue];
    self.blurRadius = MAX(0.0, blur);

    double bloomIntensity = [preferences[kPrefBloomIntensity] respondsToSelector:@selector(doubleValue)] ?
        [preferences[kPrefBloomIntensity] doubleValue] :
        [defaults[kPrefBloomIntensity] doubleValue];
    self.bloomIntensity = MAX(0.0, bloomIntensity);

    double bloomThreshold = [preferences[kPrefBloomThreshold] respondsToSelector:@selector(doubleValue)] ?
        [preferences[kPrefBloomThreshold] doubleValue] :
        [defaults[kPrefBloomThreshold] doubleValue];
    self.bloomThreshold = MIN(MAX(bloomThreshold, 0.0), 1.0);

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

    double opacityValue = [preferences[kPrefTrailOpacity] respondsToSelector:@selector(doubleValue)] ?
        [preferences[kPrefTrailOpacity] doubleValue] :
        [defaults[kPrefTrailOpacity] doubleValue];
    self.trailOpacity = MAX(0.05, MIN(1.0, opacityValue));

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
    [self updateLayerBlurFilter];
}

@end
