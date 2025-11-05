#import "MetalParticleTestView.h"

#import <AppKit/AppKit.h>
#import <QuartzCore/QuartzCore.h>
#import <Metal/Metal.h>
#import <math.h>

#import "ScreenSaverKit/SSKDiagnostics.h"
#import "ScreenSaverKit/SSKParticleSystem.h"
#import "ScreenSaverKit/SSKMetalParticleRenderer.h"

static inline CGFloat SSKRandomUnit(void) {
    return (CGFloat)arc4random() / (CGFloat)UINT32_MAX;
}

static const NSUInteger kMetalParticleTestBuildNumber = 4;

@interface MetalParticleTestView ()
@property (nonatomic, strong) SSKParticleSystem *particleSystem;
@property (nonatomic, strong) id<MTLDevice> metalDevice;
@property (nonatomic, strong) CAMetalLayer *metalLayer;
@property (nonatomic, strong) SSKMetalParticleRenderer *metalRenderer;
@property (nonatomic, strong) CATextLayer *statusLayer;

@property (nonatomic) BOOL metalRenderingActive;
@property (nonatomic) BOOL awaitingMetalDrawable;
@property (nonatomic) double spawnAccumulator;
@property (nonatomic) NSUInteger frameCount;
@property (nonatomic) NSUInteger metalRenderSuccessCount;
@property (nonatomic) NSUInteger metalRenderFailureCount;

@property (nonatomic, copy) NSString *deviceStatus;
@property (nonatomic, copy) NSString *layerStatus;
@property (nonatomic, copy) NSString *rendererStatus;
@property (nonatomic, copy) NSString *drawableStatus;
@property (nonatomic, copy) NSString *overlayString;

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

        _deviceStatus = @"Device: not requested";
        _layerStatus = @"Layer: waiting for device";
        _rendererStatus = @"Renderer: waiting for layer";
        _drawableStatus = @"Drawable: not attempted";
        _overlayString = @"Metal Particle Test – awaiting status…";

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
    [self layoutStatusLayer];
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
            self.metalRenderSuccessCount += 1;
            self.metalRenderingActive = YES;
            self.metalRenderFailureCount = 0;
            self.drawableStatus = [NSString stringWithFormat:@"Drawable: ok (successes %lu)",
                                   (unsigned long)self.metalRenderSuccessCount];
            if (!self.loggedFirstDrawableSuccess) {
                self.loggedFirstDrawableSuccess = YES;
                [SSKDiagnostics log:@"MetalParticleTest: received first successful Metal frame."];
            }
        } else {
            self.awaitingMetalDrawable = YES;
            self.metalRenderingActive = NO;
            self.metalRenderFailureCount += 1;
            self.drawableStatus = [NSString stringWithFormat:@"Drawable: renderer returned NO (failures %lu)",
                                   (unsigned long)self.metalRenderFailureCount];
            if (!self.loggedDrawableFailure || (self.metalRenderFailureCount % 60 == 0)) {
                self.loggedDrawableFailure = YES;
                [SSKDiagnostics log:@"MetalParticleTest: renderWithMetalRenderer returned NO (failure count %lu).",
                 (unsigned long)self.metalRenderFailureCount];
            }
        }
    } else if (self.metalDevice && !self.metalRenderer) {
        self.metalRenderingActive = NO;
        self.drawableStatus = @"Drawable: skipped (renderer unavailable)";
    } else if (!self.metalDevice) {
        self.metalRenderingActive = NO;
        self.drawableStatus = @"Drawable: skipped (no Metal device)";
    } else {
        self.metalRenderingActive = NO;
        self.drawableStatus = @"Drawable: skipped (no Metal layer)";
    }

    if (renderedWithMetal) {
        self.rendererStatus = @"Renderer: active (Metal)";
    } else if (attemptedMetalRender) {
        self.rendererStatus = self.awaitingMetalDrawable ?
            @"Renderer: waiting for drawable (CPU fallback this frame)" :
            @"Renderer: attempted Metal path (CPU fallback this frame)";
    } else if (self.metalDevice && self.metalLayer && !self.metalRenderer) {
        self.rendererStatus = @"Renderer: failed to initialise";
    } else if (!self.metalDevice) {
        self.rendererStatus = @"Renderer: waiting for Metal device";
    } else {
        self.rendererStatus = @"Renderer: waiting for layer";
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

    NSArray<NSString *> *lines = [self.overlayString componentsSeparatedByString:@"\n"];
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
        self.deviceStatus = @"Device: unavailable (MTLCreateSystemDefaultDevice returned nil)";
        if (!self.loggedNoDevice) {
            self.loggedNoDevice = YES;
            [SSKDiagnostics log:@"MetalParticleTest: no Metal device available (MTLCreateSystemDefaultDevice returned nil)."];
        }
        return;
    }

    self.metalDevice = device;
    self.deviceStatus = [NSString stringWithFormat:@"Device: %@ (lowPower=%@ removable=%@)",
                         device.name,
                         device.isLowPower ? @"YES" : @"NO",
                         device.isRemovable ? @"YES" : @"NO"];
    [SSKDiagnostics log:@"MetalParticleTest: obtained Metal device '%@'.", device.name];
}

- (void)ensureMetalLayer {
    if (!self.metalDevice) {
        self.layerStatus = @"Layer: waiting for Metal device";
        return;
    }
    if (!self.window) {
        self.layerStatus = @"Layer: waiting for window attachment";
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
    self.layerStatus = @"Layer: created and attached";
    if (!self.loggedLayerCreation) {
        self.loggedLayerCreation = YES;
        [SSKDiagnostics log:@"MetalParticleTest: created CAMetalLayer and attached to view."];
    }

    [self ensureStatusLayer];
}

- (void)ensureMetalRenderer {
    if (!self.metalLayer || self.metalRenderer) { return; }

    self.rendererStatus = @"Renderer: initialising…";
    SSKMetalParticleRenderer *renderer = [[SSKMetalParticleRenderer alloc] initWithLayer:self.metalLayer];
    if (!renderer) {
        NSString *errorMessage = [SSKMetalParticleRenderer lastCreationErrorMessage];
        if (errorMessage.length == 0) {
            errorMessage = @"unknown error";
        }
        self.rendererStatus = [NSString stringWithFormat:@"Renderer: failed to initialise (%@)", errorMessage];
        if (!self.loggedRendererCreationFailure) {
            self.loggedRendererCreationFailure = YES;
            [SSKDiagnostics log:@"MetalParticleTest: failed to initialise SSKMetalParticleRenderer (see console for shader errors)."];
        }
        return;
    }

    self.metalRenderer = renderer;
    self.rendererStatus = @"Renderer: initialised";
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
    self.layerStatus = [NSString stringWithFormat:@"Layer: attached (drawable %.0fx%.0f @ scale %.2f)",
                        self.metalLayer.drawableSize.width,
                        self.metalLayer.drawableSize.height,
                        scale];
    if (self.statusLayer) {
        self.statusLayer.contentsScale = scale;
        [self layoutStatusLayer];
    }
}

- (void)ensureStatusLayer {
    if (!self.metalLayer || self.statusLayer) { return; }

    CATextLayer *text = [CATextLayer layer];
    text.alignmentMode = kCAAlignmentLeft;
    text.foregroundColor = [NSColor colorWithCalibratedWhite:0.95 alpha:1.0].CGColor;
    text.backgroundColor = [NSColor colorWithCalibratedWhite:0 alpha:0.55].CGColor;
    text.cornerRadius = 8.0;
    text.masksToBounds = YES;
    text.contentsScale = [self currentContentsScale];
    text.font = (__bridge CFTypeRef)[NSFont monospacedDigitSystemFontOfSize:12 weight:NSFontWeightRegular];
    text.fontSize = 12.0;
    [self.metalLayer addSublayer:text];
    self.statusLayer = text;
    [self layoutStatusLayer];
}

- (void)layoutStatusLayer {
    if (!self.statusLayer) { return; }
    CGFloat width = MIN(self.bounds.size.width - 32.0, 520.0);
    CGFloat height = 160.0;
    self.statusLayer.frame = CGRectMake(18.0,
                                        self.bounds.size.height - height - 18.0,
                                        width,
                                        height);
}

- (void)updateOverlayText {
    NSMutableArray<NSString *> *lines = [NSMutableArray array];
    [lines addObject:[NSString stringWithFormat:@"Metal Particle Test – Build #%lu – frame %lu",
                      (unsigned long)kMetalParticleTestBuildNumber,
                      (unsigned long)self.frameCount]];
    [lines addObject:self.deviceStatus ?: @"Device: (unset)"];
    [lines addObject:self.layerStatus ?: @"Layer: (unset)"];
    [lines addObject:self.rendererStatus ?: @"Renderer: (unset)"];
    [lines addObject:self.drawableStatus ?: @"Drawable: (unset)"];
    [lines addObject:[NSString stringWithFormat:@"Metal successes: %lu | Metal fallbacks: %lu",
                      (unsigned long)self.metalRenderSuccessCount,
                      (unsigned long)self.metalRenderFailureCount]];
    [lines addObject:[NSString stringWithFormat:@"Particles alive: %lu | Blend: %@",
                      (unsigned long)self.particleSystem.aliveParticleCount,
                      (self.particleSystem.blendMode == SSKParticleBlendModeAdditive ? @"Additive" : @"Alpha")]];

    self.overlayString = [lines componentsJoinedByString:@"\n"];

    if (self.statusLayer) {
        self.statusLayer.string = self.overlayString;
    }
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
