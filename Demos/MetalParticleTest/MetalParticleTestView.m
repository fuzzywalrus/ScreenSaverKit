#import "MetalParticleTestView.h"

#import <AppKit/AppKit.h>
#import <QuartzCore/QuartzCore.h>
#import <Metal/Metal.h>
#import <math.h>

#import "ScreenSaverKit/SSKDiagnostics.h"
#import "ScreenSaverKit/SSKParticleSystem.h"
#import "ScreenSaverKit/SSKMetalParticleRenderer.h"
#import "ScreenSaverKit/SSKMetalRenderDiagnostics.h"

static inline CGFloat SSKRandomUnit(void) {
    return (CGFloat)arc4random() / (CGFloat)UINT32_MAX;
}

static const NSUInteger kMetalParticleTestBuildNumber = 4;

@interface MetalParticleTestView ()
@property (nonatomic, strong) SSKParticleSystem *particleSystem;
@property (nonatomic, strong) id<MTLDevice> metalDevice;
@property (nonatomic, strong) CAMetalLayer *metalLayer;
@property (nonatomic, strong) SSKMetalParticleRenderer *metalRenderer;
@property (nonatomic, strong) SSKMetalRenderDiagnostics *renderDiagnostics;

@property (nonatomic) BOOL metalRenderingActive;
@property (nonatomic) BOOL awaitingMetalDrawable;
@property (nonatomic) double spawnAccumulator;
@property (nonatomic) NSUInteger frameCount;
@property (nonatomic, copy) NSString *cachedOverlayString;

@property (nonatomic) BOOL attemptedDeviceCreation;
@property (nonatomic) BOOL loggedNoDevice;
@property (nonatomic) BOOL loggedLayerCreation;
@property (nonatomic) BOOL loggedRendererCreationFailure;
@property (nonatomic) BOOL loggedDrawableFailure;
@property (nonatomic) BOOL loggedFirstDrawableSuccess;
@end

@implementation MetalParticleTestView

- (instancetype)initWithFrame:(NSRect)frame isPreview:(BOOL)isPreview {
    if ((self = [super initWithFrame:frame isPreview:isPreview])) {
        self.animationTimeInterval = 1.0 / 60.0;
        _particleSystem = [[SSKParticleSystem alloc] initWithCapacity:512];
        _particleSystem.blendMode = SSKParticleBlendModeAdditive;
        _particleSystem.globalDamping = 0.92;
        _particleSystem.gravity = NSZeroPoint;

        _renderDiagnostics = [[SSKMetalRenderDiagnostics alloc] init];
        _renderDiagnostics.deviceStatus = @"Device: not requested";
        _renderDiagnostics.layerStatus = @"Layer: waiting for device";
        _renderDiagnostics.rendererStatus = @"Renderer: waiting for layer";
        _renderDiagnostics.drawableStatus = @"Drawable: not attempted";
        _cachedOverlayString = @"Metal Particle Test – awaiting status…";

        [SSKDiagnostics setEnabled:YES];
    }
    return self;
}

- (BOOL)isOpaque {
    return YES;
}

- (void)viewDidMoveToWindow {
    [super viewDidMoveToWindow];
    [self ensureMetalDevice];
    [self ensureMetalLayer];
    [self ensureMetalRenderer];
    [self updateMetalGeometry];
    [self updateOverlayText];
}

- (void)setFrame:(NSRect)frameRect {
    [super setFrame:frameRect];
    [self updateMetalGeometry];
}

- (void)layout {
    [super layout];
    [self updateMetalGeometry];
    [self updateOverlayText];
}

- (void)animateOneFrame {
    self.frameCount += 1;

    [self ensureMetalDevice];
    [self ensureMetalLayer];
    [self ensureMetalRenderer];
    [self updateMetalGeometry];

    NSTimeInterval dt = [self advanceAnimationClock];
    if (dt <= 0.0) {
        dt = 1.0 / 60.0;
    }

    [self spawnParticlesForDelta:dt];
    [self.particleSystem advanceBy:dt];

    BOOL attemptedMetalRender = NO;
    BOOL renderedWithMetal = NO;
    self.awaitingMetalDrawable = NO;

    if (self.metalRenderer && self.metalLayer) {
        attemptedMetalRender = YES;
        renderedWithMetal = [self.particleSystem renderWithMetalRenderer:self.metalRenderer
                                                               blendMode:self.particleSystem.blendMode
                                                            viewportSize:self.bounds.size];
        if (renderedWithMetal) {
            [self.renderDiagnostics recordMetalAttemptWithSuccess:YES];
            self.metalRenderingActive = YES;
            self.renderDiagnostics.drawableStatus = [NSString stringWithFormat:@"Drawable: ok (successes %lu)",
                                                     (unsigned long)self.renderDiagnostics.metalSuccessCount];
            if (!self.loggedFirstDrawableSuccess) {
                self.loggedFirstDrawableSuccess = YES;
                [SSKDiagnostics log:@"MetalParticleTest: received first successful Metal frame."];
            }
        } else {
            self.awaitingMetalDrawable = YES;
            self.metalRenderingActive = NO;
            [self.renderDiagnostics recordMetalAttemptWithSuccess:NO];
            self.renderDiagnostics.drawableStatus = [NSString stringWithFormat:@"Drawable: renderer returned NO (failures %lu)",
                                                     (unsigned long)self.renderDiagnostics.metalFailureCount];
            if (!self.loggedDrawableFailure || (self.renderDiagnostics.metalFailureCount % 60 == 0)) {
                self.loggedDrawableFailure = YES;
                [SSKDiagnostics log:@"MetalParticleTest: renderWithMetalRenderer returned NO (failure count %lu).",
                 (unsigned long)self.renderDiagnostics.metalFailureCount];
            }
        }
    } else if (self.metalDevice && !self.metalRenderer) {
        self.metalRenderingActive = NO;
        self.renderDiagnostics.drawableStatus = @"Drawable: skipped (renderer unavailable)";
    } else if (!self.metalDevice) {
        self.metalRenderingActive = NO;
        self.renderDiagnostics.drawableStatus = @"Drawable: skipped (no Metal device)";
    } else {
        self.metalRenderingActive = NO;
        self.renderDiagnostics.drawableStatus = @"Drawable: skipped (no Metal layer)";
    }

    if (renderedWithMetal) {
        self.renderDiagnostics.rendererStatus = @"Renderer: active (Metal)";
    } else if (attemptedMetalRender) {
        self.renderDiagnostics.rendererStatus = self.awaitingMetalDrawable ?
            @"Renderer: waiting for drawable (CPU fallback this frame)" :
            @"Renderer: attempted Metal path (CPU fallback this frame)";
    } else if (self.metalDevice && self.metalLayer && !self.metalRenderer) {
        self.renderDiagnostics.rendererStatus = @"Renderer: failed to initialise";
    } else if (!self.metalDevice) {
        self.renderDiagnostics.rendererStatus = @"Renderer: waiting for Metal device";
    } else {
        self.renderDiagnostics.rendererStatus = @"Renderer: waiting for layer";
    }

    if (!renderedWithMetal) {
        [self setNeedsDisplay:YES];
    }

    [self updateOverlayText];
}

- (void)drawRect:(NSRect)dirtyRect {
    if (self.metalRenderingActive && self.metalRenderer) {
        return;
    }

    [[NSColor blackColor] setFill];
    NSRectFill(dirtyRect);

    CGContextRef ctx = [[NSGraphicsContext currentContext] CGContext];
    if (!ctx) {
        return;
    }

    [self.particleSystem drawInContext:ctx];

    NSString *overlay = self.cachedOverlayString ?: @"Metal Particle Test – diagnostics unavailable";
    NSArray<NSString *> *lines = [overlay componentsSeparatedByString:@"\n"];
    NSDictionary *attrs = @{
        NSFontAttributeName: [NSFont monospacedDigitSystemFontOfSize:13 weight:NSFontWeightRegular],
        NSForegroundColorAttributeName: [NSColor colorWithCalibratedWhite:0.95 alpha:1.0]
    };
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
    [[NSBezierPath bezierPathWithRoundedRect:panel xRadius:10 yRadius:10] fill];

    for (NSString *line in lines) {
        [line drawAtPoint:NSMakePoint(x, y) withAttributes:attrs];
        y += lineHeight;
    }
}

#pragma mark - Metal setup helpers

- (void)ensureMetalDevice {
    if (self.metalDevice || self.attemptedDeviceCreation) { return; }
    self.attemptedDeviceCreation = YES;

    id<MTLDevice> device = MTLCreateSystemDefaultDevice();
    if (!device) {
        self.renderDiagnostics.deviceStatus = @"Device: unavailable (MTLCreateSystemDefaultDevice returned nil)";
        if (!self.loggedNoDevice) {
            self.loggedNoDevice = YES;
            [SSKDiagnostics log:@"MetalParticleTest: no Metal device available (MTLCreateSystemDefaultDevice returned nil)."];
        }
        return;
    }

    self.metalDevice = device;
    self.renderDiagnostics.deviceStatus = [NSString stringWithFormat:@"Device: %@ (lowPower=%@ removable=%@)",
                         device.name,
                         device.isLowPower ? @"YES" : @"NO",
                         device.isRemovable ? @"YES" : @"NO"];
    [SSKDiagnostics log:@"MetalParticleTest: obtained Metal device '%@'.", device.name];
}

- (void)ensureMetalLayer {
    if (!self.metalDevice) {
        self.renderDiagnostics.layerStatus = @"Layer: waiting for Metal device";
        return;
    }
    if (!self.window) {
        self.renderDiagnostics.layerStatus = @"Layer: waiting for window attachment";
        return;
    }
    if (self.metalLayer) { return; }

    self.wantsLayer = YES;
    CAMetalLayer *layer = [CAMetalLayer layer];
    layer.device = self.metalDevice;
    layer.pixelFormat = MTLPixelFormatBGRA8Unorm;
    layer.framebufferOnly = YES;
    layer.opaque = YES;
    layer.needsDisplayOnBoundsChange = YES;
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
    self.renderDiagnostics.layerStatus = @"Layer: created and attached";
    if (!self.loggedLayerCreation) {
        self.loggedLayerCreation = YES;
        [SSKDiagnostics log:@"MetalParticleTest: created CAMetalLayer and attached to view."];
    }

    [self.renderDiagnostics attachToMetalLayer:self.metalLayer];
}

- (void)ensureMetalRenderer {
    if (!self.metalLayer || self.metalRenderer) { return; }

    self.renderDiagnostics.rendererStatus = @"Renderer: initialising…";
    SSKMetalParticleRenderer *renderer = [[SSKMetalParticleRenderer alloc] initWithLayer:self.metalLayer];
    if (!renderer) {
        NSString *errorMessage = [SSKMetalParticleRenderer lastCreationErrorMessage];
        if (errorMessage.length == 0) {
            errorMessage = @"unknown error";
        }
        self.renderDiagnostics.rendererStatus = [NSString stringWithFormat:@"Renderer: failed to initialise (%@)", errorMessage];
        if (!self.loggedRendererCreationFailure) {
            self.loggedRendererCreationFailure = YES;
            [SSKDiagnostics log:@"MetalParticleTest: failed to initialise SSKMetalParticleRenderer (see console for shader errors)."];
        }
        return;
    }

    self.metalRenderer = renderer;
    self.renderDiagnostics.rendererStatus = @"Renderer: initialised";
}

- (CGFloat)currentContentsScale {
    if (self.window) {
        return self.window.backingScaleFactor;
    }
    if (NSScreen.mainScreen) {
        return NSScreen.mainScreen.backingScaleFactor;
    }
    return 1.0;
}

- (void)updateMetalGeometry {
    if (!self.metalLayer) { return; }
    CGFloat scale = [self currentContentsScale];
    self.metalLayer.contentsScale = scale;
   self.metalLayer.frame = self.bounds;
    self.metalLayer.drawableSize = CGSizeMake(NSWidth(self.bounds) * scale,
                                              NSHeight(self.bounds) * scale);
    self.renderDiagnostics.layerStatus = [NSString stringWithFormat:@"Layer: attached (drawable %.0fx%.0f @ scale %.2f)",
                                          self.metalLayer.drawableSize.width,
                                          self.metalLayer.drawableSize.height,
                                          scale];
    [self.renderDiagnostics attachToMetalLayer:self.metalLayer];
}

- (void)updateOverlayText {
    NSString *title = [NSString stringWithFormat:@"Metal Particle Test – Build #%lu – frame %lu",
                       (unsigned long)kMetalParticleTestBuildNumber,
                       (unsigned long)self.frameCount];
    NSString *blend = (self.particleSystem.blendMode == SSKParticleBlendModeAdditive ? @"Additive" : @"Alpha");
    NSString *particlesLine = [NSString stringWithFormat:@"Particles alive: %lu | Blend: %@",
                               (unsigned long)self.particleSystem.aliveParticleCount,
                               blend];
    NSArray<NSString *> *extras = @[particlesLine];
    double fps = self.animationClock.framesPerSecond;
    self.cachedOverlayString = [self.renderDiagnostics overlayStringWithTitle:title
                                                                   extraLines:extras
                                                              framesPerSecond:fps];
    [self.renderDiagnostics updateOverlayWithTitle:title
                                         extraLines:extras
                                    framesPerSecond:fps];
}

#pragma mark - Particles

- (void)spawnParticlesForDelta:(NSTimeInterval)dt {
    if (NSIsEmptyRect(self.bounds)) {
        return;
    }

    double spawnRate = 120.0; // particles per second
    self.spawnAccumulator += spawnRate * dt;
    NSUInteger spawnCount = (NSUInteger)floor(self.spawnAccumulator);
    if (spawnCount == 0) {
        return;
    }
    self.spawnAccumulator -= spawnCount;

    NSPoint centre = NSMakePoint(NSMidX(self.bounds), NSMidY(self.bounds));
    CGFloat maxRadius = MIN(NSWidth(self.bounds), NSHeight(self.bounds)) * 0.5;

    [self.particleSystem spawnParticles:spawnCount initializer:^(SSKParticle *particle) {
        CGFloat angle = SSKRandomUnit() * (CGFloat)M_PI * 2.0;
        CGFloat speed = 80.0 + SSKRandomUnit() * 160.0;
        CGFloat radius = maxRadius * 0.12f;
        CGFloat offsetAngle = angle + ((SSKRandomUnit() - 0.5f) * 0.45f);
        particle.position = NSMakePoint(centre.x + cos(offsetAngle) * radius,
                                        centre.y + sin(offsetAngle) * radius);
        particle.velocity = NSMakePoint(cos(angle) * speed,
                                        sin(angle) * speed);

        CGFloat hue = SSKRandomUnit();
        particle.color = [NSColor colorWithCalibratedHue:hue
                                               saturation:0.75
                                               brightness:1.0
                                                    alpha:1.0];
        particle.maxLife = 1.4 + SSKRandomUnit() * 0.8;
        particle.life = 0.0;
        particle.size = 8.0 + SSKRandomUnit() * 12.0;
        particle.baseSize = particle.size;
        particle.behaviorOptions = SSKParticleBehaviorOptionFadeAlpha | SSKParticleBehaviorOptionFadeSize;
        particle.sizeOverLifeRange = SSKScalarRangeMake(1.0, 0.1);
        particle.damping = 0.88;
        particle.rotationVelocity = (SSKRandomUnit() - 0.5) * 2.0;
    }];
}

@end
