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

static const NSUInteger kMetalParticleTestBuildNumber = 1;

@interface MetalParticleTestView ()
@property (nonatomic, strong) SSKParticleSystem *particleSystem;
@property (nonatomic, strong) CAMetalLayer *metalLayer;
@property (nonatomic, strong) SSKMetalParticleRenderer *metalRenderer;
@property (nonatomic, strong) CATextLayer *statusLayer;
@property (nonatomic) BOOL metalRenderingActive;
@property (nonatomic) double spawnAccumulator;
@property (nonatomic) NSTimeInterval lastMetalDrawableFailureLog;
@end

@implementation MetalParticleTestView

- (instancetype)initWithFrame:(NSRect)frame isPreview:(BOOL)isPreview {
    if ((self = [super initWithFrame:frame isPreview:isPreview])) {
        self.animationTimeInterval = 1.0 / 60.0;
        _particleSystem = [[SSKParticleSystem alloc] initWithCapacity:512];
        _particleSystem.blendMode = SSKParticleBlendModeAdditive;
        _particleSystem.globalDamping = 0.92;
        _particleSystem.gravity = NSZeroPoint;
        [SSKDiagnostics setEnabled:YES];
        [self setUpMetalIfNeeded];
    }
    return self;
}

- (BOOL)isOpaque {
    return YES;
}

- (void)setFrame:(NSRect)frameRect {
    [super setFrame:frameRect];
    [self updateMetalDrawableSize];
}

- (void)layout {
    [super layout];
    [self updateMetalDrawableSize];
}

- (void)viewDidMoveToWindow {
    [super viewDidMoveToWindow];
    [self setUpMetalIfNeeded];
    [self updateMetalDrawableSize];
}

- (void)animateOneFrame {
    [self setUpMetalIfNeeded];
    [self ensureMetalLayerConsistency];
    NSTimeInterval dt = [self advanceAnimationClock];
    if (dt <= 0.0) {
        dt = 1.0 / 60.0;
    }

    [self spawnParticlesForDelta:dt];
    [self.particleSystem advanceBy:dt];

    BOOL renderedWithMetal = NO;
    if (self.metalRenderer && self.metalLayer) {
        [self updateMetalDrawableSize];
        renderedWithMetal = [self.particleSystem renderWithMetalRenderer:self.metalRenderer
                                                               blendMode:self.particleSystem.blendMode
                                                            viewportSize:self.bounds.size];
    }

    self.metalRenderingActive = renderedWithMetal;
    [self updateStatusText];

    if (!renderedWithMetal && self.metalRenderer) {
        NSTimeInterval now = [NSDate timeIntervalSinceReferenceDate];
        if (now - self.lastMetalDrawableFailureLog > 0.75) {
            [SSKDiagnostics log:@"MetalParticleTestView: CAMetalLayer did not supply a drawable this frame."];
            self.lastMetalDrawableFailureLog = now;
        }
    }

    if (!renderedWithMetal) {
        [self setNeedsDisplay:YES];
    }
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

    NSString *text = nil;
    NSUInteger alive = self.particleSystem.aliveParticleCount;
    NSString *buildStamp = [NSString stringWithFormat:@"Build #%lu", (unsigned long)kMetalParticleTestBuildNumber];
    text = self.metalRenderer ? [NSString stringWithFormat:@"%@ – Metal renderer unavailable (CPU path) · %lu active", buildStamp, (unsigned long)alive] :
           [NSString stringWithFormat:@"%@ – No Metal device detected · %lu active", buildStamp, (unsigned long)alive];
    NSDictionary *attrs = @{
        NSFontAttributeName: [NSFont monospacedDigitSystemFontOfSize:13 weight:NSFontWeightMedium],
        NSForegroundColorAttributeName: [NSColor colorWithCalibratedWhite:0.95 alpha:1.0]
    };
    NSSize label = [text sizeWithAttributes:attrs];
    NSRect panel = NSMakeRect(NSMinX(self.bounds) + 16.0,
                              NSMinY(self.bounds) + 16.0,
                              label.width + 18.0,
                              label.height + 12.0);
    [[NSColor colorWithWhite:0 alpha:0.65] setFill];
    [[NSBezierPath bezierPathWithRoundedRect:panel xRadius:8.0 yRadius:8.0] fill];
    NSPoint origin = NSMakePoint(NSMinX(panel) + 9.0, NSMinY(panel) + 6.0);
    [text drawAtPoint:origin withAttributes:attrs];

    NSString *overlayDetail = self.metalRenderer ? @"CPU fallback (Metal renderer unavailable)" :
                            @"CPU path (no Metal device)";
    NSString *overlayText = [NSString stringWithFormat:@"Metal Particle Test %@ – %@ · %lu active",
                             [NSString stringWithFormat:@"#%lu", (unsigned long)kMetalParticleTestBuildNumber],
                             overlayDetail,
                             (unsigned long)alive];
    [SSKDiagnostics drawOverlayInView:self
                                 text:overlayText
                      framesPerSecond:self.animationClock.framesPerSecond];
}

#pragma mark - Metal setup

- (void)ensureMetalLayerConsistency {
    if (!self.metalLayer || self.layer == self.metalLayer) {
        return;
    }
    self.layer = self.metalLayer;
}

- (void)setUpMetalIfNeeded {
    if (self.metalRenderer && self.metalLayer) {
        return;
    }

    id<MTLDevice> device = MTLCreateSystemDefaultDevice();
    if (!device) {
        [self tearDownMetalLayer];
        return;
    }

    self.wantsLayer = YES;
    CAMetalLayer *metalLayer = [CAMetalLayer layer];
    metalLayer.device = device;
    metalLayer.pixelFormat = MTLPixelFormatBGRA8Unorm;
    metalLayer.framebufferOnly = YES;
    metalLayer.backgroundColor = NSColor.blackColor.CGColor;

    self.layer = metalLayer;
    self.metalLayer = metalLayer;
    self.metalRenderer = [[SSKMetalParticleRenderer alloc] initWithLayer:metalLayer];
    if (!self.metalRenderer) {
        [self tearDownMetalLayer];
        return;
    }

    self.metalRenderer.clearColor = MTLClearColorMake(0.035, 0.035, 0.05, 1.0);
    [self ensureStatusLayer];
    [self updateMetalDrawableSize];
    self.metalRenderingActive = YES;
    [self updateStatusText];
}

- (void)tearDownMetalLayer {
    if (self.statusLayer.superlayer) {
        [self.statusLayer removeFromSuperlayer];
    }
    self.statusLayer = nil;
    self.metalRenderer = nil;
    self.metalLayer = nil;
    self.layer = nil;
    self.wantsLayer = NO;
    self.metalRenderingActive = NO;
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

- (void)updateMetalDrawableSize {
    if (!self.metalLayer) {
        return;
    }
    CGFloat scale = [self currentContentsScale];
    self.metalLayer.contentsScale = scale;
    self.metalLayer.frame = self.bounds;
    self.metalLayer.drawableSize = CGSizeMake(NSWidth(self.bounds) * scale,
                                              NSHeight(self.bounds) * scale);
    if (self.statusLayer) {
        self.statusLayer.contentsScale = scale;
        [self layoutStatusLayer];
    }
}

- (void)ensureStatusLayer {
    if (!self.metalLayer) {
        return;
    }
    if (!self.statusLayer) {
        CATextLayer *textLayer = [CATextLayer layer];
        textLayer.alignmentMode = kCAAlignmentLeft;
        textLayer.foregroundColor = [NSColor colorWithCalibratedWhite:0.95 alpha:1.0].CGColor;
        textLayer.backgroundColor = [NSColor colorWithCalibratedWhite:0 alpha:0.55].CGColor;
        textLayer.cornerRadius = 7.0;
        textLayer.contentsScale = [self currentContentsScale];
        textLayer.font = (__bridge CFTypeRef)[NSFont monospacedDigitSystemFontOfSize:12 weight:NSFontWeightMedium];
        textLayer.fontSize = 12.0;
        textLayer.masksToBounds = YES;
        [self.metalLayer addSublayer:textLayer];
        self.statusLayer = textLayer;
    }
    [self layoutStatusLayer];
}

- (void)layoutStatusLayer {
    if (!self.statusLayer) {
        return;
    }
    CGFloat height = 24.0;
    CGFloat width = MIN(260.0, MAX(180.0, self.bounds.size.width * 0.4));
    self.statusLayer.frame = CGRectMake(16.0,
                                        16.0,
                                        width,
                                        height);
    self.statusLayer.contentsGravity = kCAGravityResizeAspect;
    self.statusLayer.truncationMode = kCATruncationEnd;
}

- (void)updateStatusText {
    NSString *status = nil;
    NSUInteger alive = self.particleSystem.aliveParticleCount;
    NSString *buildStamp = [NSString stringWithFormat:@"Build #%lu", (unsigned long)kMetalParticleTestBuildNumber];
    if (self.metalRenderingActive) {
        status = [NSString stringWithFormat:@"%@ – Metal renderer active · %lu active", buildStamp, (unsigned long)alive];
    } else if (self.metalRenderer) {
        status = [NSString stringWithFormat:@"%@ – Metal renderer fallback (no drawable) · %lu active", buildStamp, (unsigned long)alive];
    } else {
        status = [NSString stringWithFormat:@"%@ – No Metal device detected · %lu active", buildStamp, (unsigned long)alive];
    }
    if (self.statusLayer) {
        NSMutableParagraphStyle *style = [[NSMutableParagraphStyle alloc] init];
        style.alignment = NSTextAlignmentLeft;
        NSDictionary *attributes = @{
            NSParagraphStyleAttributeName: style,
            NSFontAttributeName: [NSFont monospacedDigitSystemFontOfSize:12 weight:NSFontWeightMedium],
            NSForegroundColorAttributeName: [NSColor colorWithCalibratedWhite:0.95 alpha:1.0]
        };
        NSAttributedString *string = [[NSAttributedString alloc] initWithString:status attributes:attributes];
        self.statusLayer.string = string;
        return;
    }

    if (!self.metalRenderingActive) {
        // CPU path overlay handled in drawRect; nothing extra required here.
        return;
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
