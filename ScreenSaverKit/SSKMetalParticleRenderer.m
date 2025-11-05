#import "SSKMetalParticleRenderer.h"

#import <QuartzCore/QuartzCore.h>

#import "SSKDiagnostics.h"
#import "SSKMetalRenderer.h"

static NSString *SSKMetalParticleRendererLastErrorMessage = nil;

static void SSKMetalParticleRendererSetLastErrorMessage(NSString *message) {
    SSKMetalParticleRendererLastErrorMessage = [message copy];
    if (message.length > 0 && [SSKDiagnostics isEnabled]) {
        [SSKDiagnostics log:@"%@", message];
    }
    if (message.length > 0) {
        NSLog(@"%@", message);
    }
}

@interface SSKMetalParticleRenderer ()
@property (nonatomic, weak) CAMetalLayer *layer;
@property (nonatomic, strong) SSKMetalRenderer *renderer;
@end

@implementation SSKMetalParticleRenderer

- (instancetype)initWithLayer:(CAMetalLayer *)layer {
    SSKMetalParticleRendererSetLastErrorMessage(nil);
    NSParameterAssert(layer);
    if ((self = [super init])) {
        _layer = layer;
        SSKMetalRenderer *renderer = [[SSKMetalRenderer alloc] initWithLayer:layer];
        if (!renderer) {
            SSKMetalParticleRendererSetLastErrorMessage(@"SSKMetalParticleRenderer: failed to create unified Metal renderer.");
            return nil;
        }
        _renderer = renderer;
        _clearColor = MTLClearColorMake(0.0, 0.0, 0.0, 1.0);
        _blurRadius = 0.0;
        _bloomIntensity = 0.0;
        _bloomThreshold = 0.8f;
        _bloomBlurSigma = 3.0f;
        _renderer.clearColor = _clearColor;
        _renderer.particleBlurRadius = _blurRadius;
    }
    return self;
}

+ (nullable NSString *)lastCreationErrorMessage {
    return SSKMetalParticleRendererLastErrorMessage;
}

- (void)setClearColor:(MTLClearColor)clearColor {
    _clearColor = clearColor;
    self.renderer.clearColor = clearColor;
}

- (void)setBlurRadius:(CGFloat)blurRadius {
    CGFloat clamped = MAX(0.0, blurRadius);
    _blurRadius = clamped;
    self.renderer.particleBlurRadius = clamped;
}

- (void)setBloomIntensity:(CGFloat)bloomIntensity {
    _bloomIntensity = MAX(0.0, bloomIntensity);
}

- (void)setBloomThreshold:(CGFloat)bloomThreshold {
    _bloomThreshold = MIN(MAX(bloomThreshold, 0.0), 1.0);
}

- (void)setBloomBlurSigma:(CGFloat)bloomBlurSigma {
    _bloomBlurSigma = MAX(0.1, bloomBlurSigma);
}

- (BOOL)renderParticles:(NSArray<SSKParticle *> *)particles
              blendMode:(SSKParticleBlendMode)blendMode
           viewportSize:(CGSize)viewportSize {
    if (!self.renderer || !self.layer) {
        return NO;
    }

    CGFloat scale = self.layer.contentsScale > 0.0 ? self.layer.contentsScale : 1.0;
    CGSize drawableSize = CGSizeMake(MAX(viewportSize.width * scale, 1.0),
                                     MAX(viewportSize.height * scale, 1.0));
    if (!CGSizeEqualToSize(self.layer.drawableSize, drawableSize)) {
        self.layer.drawableSize = drawableSize;
    }

    self.renderer.clearColor = self.clearColor;
    self.renderer.particleBlurRadius = self.blurRadius;
    self.renderer.bloomThreshold = self.bloomThreshold;
    self.renderer.bloomBlurSigma = self.bloomBlurSigma;

    if (![self.renderer beginFrame]) {
        return NO;
    }

    [self.renderer drawParticles:particles ?: @[]
                       blendMode:blendMode
                    viewportSize:viewportSize];
    if (self.blurRadius > 0.01) {
        [self.renderer applyBlur:self.blurRadius];
    }
    if (self.bloomIntensity > 0.01) {
        [self.renderer applyBloom:self.bloomIntensity];
    }
    [self.renderer endFrame];
    return YES;
}

@end
