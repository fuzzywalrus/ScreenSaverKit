#import "SSKMetalRenderer.h"

#import "SSKMetalTextureCache.h"
#import "SSKParticleSystem.h"
#import "SSKDiagnostics.h"
#import "SSKMetalParticlePass.h"
#import "SSKMetalBlurPass.h"
#import "SSKMetalBloomPass.h"

NSString * const SSKMetalEffectIdentifierBlur = @"com.ssk.effects.blur";
NSString * const SSKMetalEffectIdentifierBloom = @"com.ssk.effects.bloom";
NSString * const SSKMetalEffectIdentifierColorGrading = @"com.ssk.effects.colorgrading";

@interface SSKMetalRenderer ()
@property (nonatomic, weak) CAMetalLayer *layer;
@property (nonatomic, strong, readwrite) id<MTLDevice> device;
@property (nonatomic, strong) id<MTLCommandQueue> commandQueue;
@property (nonatomic, strong, readwrite, nullable) id<MTLCommandBuffer> currentCommandBuffer;
@property (nonatomic, strong, nullable) id<CAMetalDrawable> currentDrawable;
@property (nonatomic, strong) id<MTLTexture> overrideRenderTarget;
@property (nonatomic, strong, readwrite) SSKMetalTextureCache *textureCache;
@property (nonatomic, readwrite) CGSize drawableSize;
@property (nonatomic, strong) id<MTLLibrary> shaderLibrary;
@property (nonatomic, strong) SSKMetalParticlePass *particlePass;
@property (nonatomic, strong, nullable) SSKMetalBlurPass *blurPass;
@property (nonatomic, strong, nullable) SSKMetalBloomPass *bloomPass;
@property (nonatomic, strong) NSMutableDictionary<NSString *, SSKMetalEffectStage *> *effectRegistry;
@property (nonatomic) BOOL needsClearOnNextPass;
@end

@implementation SSKMetalRenderer

- (instancetype)initWithLayer:(CAMetalLayer *)layer {
    NSParameterAssert(layer);
    if ((self = [super init])) {
        _layer = layer;
        id<MTLDevice> device = layer.device ?: MTLCreateSystemDefaultDevice();
        if (!device) {
            [SSKDiagnostics log:@"SSKMetalRenderer: no Metal device available during initialisation."];
            return nil;
        }
        _device = device;
        if (!layer.device) {
            layer.device = device;
        }
        layer.pixelFormat = MTLPixelFormatBGRA8Unorm;
        layer.framebufferOnly = NO;
        if (@available(macOS 10.13.2, *)) {
            if ([layer respondsToSelector:@selector(setAllowsNextDrawableTimeout:)]) {
                layer.allowsNextDrawableTimeout = YES;
            }
        }
        _commandQueue = [device newCommandQueue];
        if (!_commandQueue) {
            [SSKDiagnostics log:@"SSKMetalRenderer: failed to create command queue."];
            return nil;
        }
        _clearColor = MTLClearColorMake(0.0, 0.0, 0.0, 1.0);
        _textureCache = [[SSKMetalTextureCache alloc] initWithDevice:device];
        _effectRegistry = [[NSMutableDictionary alloc] init];

        _shaderLibrary = [self loadDefaultLibraryWithDevice:device];
        if (!_shaderLibrary) {
            [SSKDiagnostics log:@"SSKMetalRenderer: failed to load shader library (SSKParticleShaders.metallib)."];
            return nil;
        }

        _particlePass = [SSKMetalParticlePass new];
        if (![_particlePass setupWithDevice:device library:_shaderLibrary]) {
            [SSKDiagnostics log:@"SSKMetalRenderer: failed to set up particle pass."];
            return nil;
        }
        _blurPass = [[SSKMetalBlurPass alloc] init];
        if (![_blurPass setupWithDevice:device library:_shaderLibrary]) {
            if ([SSKDiagnostics isEnabled]) {
                [SSKDiagnostics log:@"SSKMetalRenderer: blur pass unavailable (continuing without blur support)."];
            }
            _blurPass = nil;
        }
        _bloomPass = [[SSKMetalBloomPass alloc] init];
        if (![_bloomPass setupWithDevice:device library:_shaderLibrary]) {
            if ([SSKDiagnostics isEnabled]) {
                [SSKDiagnostics log:@"SSKMetalRenderer: bloom pass unavailable (continuing without bloom support)."];
            }
            _bloomPass = nil;
        } else {
            [_bloomPass setSharedBlurPass:_blurPass];
        }
        [self configureDefaultEffectStages];
        _particleBlurRadius = 0.0;
        _bloomThreshold = 0.8f;
        _bloomBlurSigma = 3.0f;
        _needsClearOnNextPass = YES;
    }
    return self;
}

- (BOOL)beginFrame {
    if (!self.layer || !self.commandQueue) {
        return NO;
    }
    if (!self.layer.device) {
        self.layer.device = self.device;
    }

    self.currentCommandBuffer = [self.commandQueue commandBuffer];
    if (!self.currentCommandBuffer) {
        [SSKDiagnostics log:@"SSKMetalRenderer: failed to create command buffer."];
        return NO;
    }

    self.currentDrawable = nil;
    self.drawableSize = CGSizeZero;
    self.overrideRenderTarget = nil;
    self.needsClearOnNextPass = YES;
    return YES;
}

- (void)endFrame {
    if (!self.currentCommandBuffer) {
        self.currentDrawable = nil;
        self.overrideRenderTarget = nil;
        return;
    }

    if (self.currentDrawable) {
        [self.currentCommandBuffer presentDrawable:self.currentDrawable];
    }
    [self.currentCommandBuffer commit];
    self.currentCommandBuffer = nil;
    self.currentDrawable = nil;
    self.overrideRenderTarget = nil;
    self.needsClearOnNextPass = YES;
}

- (void)clearWithColor:(MTLClearColor)color {
    self.clearColor = color;
    id<MTLCommandBuffer> commandBuffer = self.currentCommandBuffer;
    id<MTLTexture> target = [self activeRenderTarget];
    if (!commandBuffer || !target) {
        return;
    }

    MTLRenderPassDescriptor *descriptor = [MTLRenderPassDescriptor renderPassDescriptor];
    descriptor.colorAttachments[0].texture = target;
    descriptor.colorAttachments[0].loadAction = MTLLoadActionClear;
    descriptor.colorAttachments[0].storeAction = MTLStoreActionStore;
    descriptor.colorAttachments[0].clearColor = color;

    id<MTLRenderCommandEncoder> encoder = [commandBuffer renderCommandEncoderWithDescriptor:descriptor];
    [encoder endEncoding];
    self.needsClearOnNextPass = NO;
}

- (void)drawParticles:(NSArray<SSKParticle *> *)particles
            blendMode:(SSKParticleBlendMode)blendMode
         viewportSize:(CGSize)viewportSize {
    if (!self.particlePass) { return; }
    id<MTLCommandBuffer> commandBuffer = self.currentCommandBuffer;
    id<MTLTexture> target = [self activeRenderTarget];
    if (!commandBuffer || !target) { return; }

    NSArray<SSKParticle *> *liveParticles = particles ?: @[];
    MTLLoadAction loadAction = self.needsClearOnNextPass ? MTLLoadActionClear : MTLLoadActionLoad;
    BOOL success = [self.particlePass encodeParticles:liveParticles
                                            blendMode:blendMode
                                         viewportSize:viewportSize
                                        commandBuffer:commandBuffer
                                         renderTarget:target
                                           loadAction:loadAction
                                           clearColor:self.clearColor];
    if (!success && [SSKDiagnostics isEnabled]) {
        [SSKDiagnostics log:@"SSKMetalRenderer: particle pass failed to encode."];
    }
    self.needsClearOnNextPass = NO;
}

- (void)drawTexture:(id<MTLTexture>)texture atRect:(CGRect)rect {
    (void)texture;
    (void)rect;
    if ([SSKDiagnostics isEnabled]) {
        [SSKDiagnostics log:@"SSKMetalRenderer: drawTexture:atRect: invoked but not yet implemented."];
    }
}

- (void)applyBlur:(CGFloat)radius {
    CGFloat clamped = MAX(0.0, radius);
    self.particleBlurRadius = clamped;
    if (clamped <= 0.01f) {
        return;
    }
    if (![self effectStageWithIdentifier:SSKMetalEffectIdentifierBlur]) {
        if ([SSKDiagnostics isEnabled]) {
            [SSKDiagnostics log:@"SSKMetalRenderer: blur pass unavailable – skipping blur."];
        }
        return;
    }

    BOOL success = [self applyEffectWithIdentifier:SSKMetalEffectIdentifierBlur
                                        parameters:@{ @"radius": @(clamped) }];
    if (!success && [SSKDiagnostics isEnabled]) {
        [SSKDiagnostics log:@"SSKMetalRenderer: blur effect failed to apply."];
    }
}

- (void)applyBloom:(CGFloat)intensity {
    CGFloat clamped = MAX(0.0, intensity);
    if (clamped <= 0.01f) {
        return;
    }
    if (![self effectStageWithIdentifier:SSKMetalEffectIdentifierBloom]) {
        if ([SSKDiagnostics isEnabled]) {
            [SSKDiagnostics log:@"SSKMetalRenderer: bloom pass unavailable – skipping bloom."];
        }
        return;
    }

    NSDictionary *parameters = @{
        @"intensity": @(clamped),
        @"threshold": @(MAX(0.0, self.bloomThreshold)),
        @"sigma": @(MAX(0.1, self.bloomBlurSigma)),
    };
    BOOL success = [self applyEffectWithIdentifier:SSKMetalEffectIdentifierBloom
                                        parameters:parameters];
    if (!success && [SSKDiagnostics isEnabled]) {
        [SSKDiagnostics log:@"SSKMetalRenderer: bloom effect failed to apply."];
    }
}

- (void)applyColorGrading:(id)params {
    SSKMetalEffectStage *stage = [self effectStageWithIdentifier:SSKMetalEffectIdentifierColorGrading];
    if (!stage) {
        (void)params;
        if ([SSKDiagnostics isEnabled]) {
            [SSKDiagnostics log:@"SSKMetalRenderer: applyColorGrading: invoked but no color grading stage registered."];
        }
        return;
    }
    NSDictionary *parameters = nil;
    if ([params isKindOfClass:[NSDictionary class]]) {
        parameters = params;
    } else if (params) {
        parameters = @{ @"payload": params };
    }
    BOOL success = [self applyEffectWithIdentifier:SSKMetalEffectIdentifierColorGrading
                                        parameters:parameters];
    if (!success && [SSKDiagnostics isEnabled]) {
        [SSKDiagnostics log:@"SSKMetalRenderer: color grading effect failed to apply."];
    }
}

- (void)registerEffectStage:(SSKMetalEffectStage *)stage {
    if (!stage || stage.identifier.length == 0) {
        return;
    }
    if (!self.effectRegistry) {
        self.effectRegistry = [[NSMutableDictionary alloc] init];
    }
    self.effectRegistry[stage.identifier] = stage;
    if ([stage.identifier isEqualToString:SSKMetalEffectIdentifierBlur]) {
        if ([stage.pass isKindOfClass:[SSKMetalBlurPass class]]) {
            [self.bloomPass setSharedBlurPass:(SSKMetalBlurPass *)stage.pass];
        }
    } else if ([stage.identifier isEqualToString:SSKMetalEffectIdentifierBloom]) {
        if ([stage.pass isKindOfClass:[SSKMetalBloomPass class]]) {
            SSKMetalEffectStage *blurStage = [self effectStageWithIdentifier:SSKMetalEffectIdentifierBlur];
            if ([blurStage.pass isKindOfClass:[SSKMetalBlurPass class]]) {
                [(SSKMetalBloomPass *)stage.pass setSharedBlurPass:(SSKMetalBlurPass *)blurStage.pass];
            } else if (self.blurPass) {
                [(SSKMetalBloomPass *)stage.pass setSharedBlurPass:self.blurPass];
            }
        }
    }
}

- (void)unregisterEffectStageWithIdentifier:(NSString *)identifier {
    if (identifier.length == 0 || !self.effectRegistry) {
        return;
    }
    [self.effectRegistry removeObjectForKey:identifier];
    if ([identifier isEqualToString:SSKMetalEffectIdentifierBlur]) {
        [self.bloomPass setSharedBlurPass:nil];
    }
}

- (SSKMetalEffectStage *)effectStageWithIdentifier:(NSString *)identifier {
    if (identifier.length == 0 || !self.effectRegistry) {
        return nil;
    }
    return self.effectRegistry[identifier];
}

- (NSArray<NSString *> *)registeredEffectIdentifiers {
    if (!self.effectRegistry.count) {
        return @[];
    }
    return [[self.effectRegistry allKeys] sortedArrayUsingSelector:@selector(compare:)];
}

- (BOOL)applyEffectWithIdentifier:(NSString *)identifier
                       parameters:(NSDictionary *)parameters {
    if (identifier.length == 0) {
        return NO;
    }
    SSKMetalEffectStage *stage = [self effectStageWithIdentifier:identifier];
    if (!stage) {
        return NO;
    }
    id<MTLCommandBuffer> commandBuffer = self.currentCommandBuffer;
    id<MTLTexture> target = [self activeRenderTarget];
    if (!commandBuffer || !target) {
        return NO;
    }
    NSDictionary *effectiveParameters = parameters ?: @{};
    return stage.handler(self, stage.pass, commandBuffer, target, effectiveParameters);
}

- (void)applyEffects:(NSArray<NSString *> *)identifiers
          parameters:(NSDictionary<NSString *, NSDictionary *> *)parameters {
    for (NSString *identifier in identifiers) {
        NSDictionary *params = parameters[identifier];
        [self applyEffectWithIdentifier:identifier parameters:params];
    }
}

- (void)setRenderTarget:(id<MTLTexture>)texture {
    self.overrideRenderTarget = texture;
}

#pragma mark - Helpers

- (void)configureDefaultEffectStages {
    [self unregisterEffectStageWithIdentifier:SSKMetalEffectIdentifierBlur];
    [self unregisterEffectStageWithIdentifier:SSKMetalEffectIdentifierBloom];

    if (self.blurPass) {
        SSKMetalEffectStage *blurStage = [[SSKMetalEffectStage alloc] initWithIdentifier:SSKMetalEffectIdentifierBlur
                                                                                    pass:self.blurPass
                                                                                 handler:^BOOL(SSKMetalRenderer *renderer, SSKMetalPass *pass, id<MTLCommandBuffer> commandBuffer, id<MTLTexture> renderTarget, NSDictionary *parameters) {
            SSKMetalBlurPass *blurPass = (SSKMetalBlurPass *)pass;
            CGFloat radius = MAX(0.0, [parameters[@"radius"] doubleValue]);
            if (radius <= 0.01f) {
                return YES;
            }
            blurPass.radius = radius;
            BOOL success = [blurPass encodeBlur:renderTarget
                                      destination:renderTarget
                                    commandBuffer:commandBuffer
                                     textureCache:renderer.textureCache];
            if (!success && [SSKDiagnostics isEnabled]) {
                [SSKDiagnostics log:@"SSKMetalRenderer: blur pass failed to encode."];
            }
            return success;
        }];
        [self registerEffectStage:blurStage];
    }

    if (self.bloomPass) {
        SSKMetalEffectStage *bloomStage = [[SSKMetalEffectStage alloc] initWithIdentifier:SSKMetalEffectIdentifierBloom
                                                                                     pass:self.bloomPass
                                                                                  handler:^BOOL(SSKMetalRenderer *renderer, SSKMetalPass *pass, id<MTLCommandBuffer> commandBuffer, id<MTLTexture> renderTarget, NSDictionary *parameters) {
            SSKMetalBloomPass *bloomPass = (SSKMetalBloomPass *)pass;
            CGFloat intensity = MAX(0.0, [parameters[@"intensity"] doubleValue]);
            if (intensity <= 0.01f) {
                return YES;
            }
            NSNumber *thresholdNumber = parameters[@"threshold"];
            NSNumber *sigmaNumber = parameters[@"sigma"];
            CGFloat threshold = thresholdNumber ? thresholdNumber.doubleValue : renderer.bloomThreshold;
            CGFloat sigma = sigmaNumber ? sigmaNumber.doubleValue : renderer.bloomBlurSigma;
            bloomPass.intensity = intensity;
            bloomPass.threshold = MAX(0.0, threshold);
            bloomPass.blurSigma = MAX(0.1, sigma);
            BOOL success = [bloomPass encodeBloomWithCommandBuffer:commandBuffer
                                                            source:renderTarget
                                                      renderTarget:renderTarget
                                                      textureCache:renderer.textureCache];
            if (!success && [SSKDiagnostics isEnabled]) {
                [SSKDiagnostics log:@"SSKMetalRenderer: bloom pass failed to encode."];
            }
            return success;
        }];
        [self registerEffectStage:bloomStage];
    }
}

- (nullable id<MTLLibrary>)loadDefaultLibraryWithDevice:(id<MTLDevice>)device {
    NSBundle *bundle = [NSBundle bundleForClass:self.class];
    NSString *metallibPath = [bundle pathForResource:@"SSKParticleShaders" ofType:@"metallib"];
    NSError *error = nil;
    if (metallibPath.length > 0) {
        NSURL *metallibURL = [NSURL fileURLWithPath:metallibPath];
        id<MTLLibrary> library = [device newLibraryWithURL:metallibURL error:&error];
        if (library) {
            return library;
        }
        if ([SSKDiagnostics isEnabled]) {
            [SSKDiagnostics log:@"SSKMetalRenderer: failed to load metallib at %@ (%@).", metallibPath, error.localizedDescription ?: @"unknown error"];
        }
    } else if ([SSKDiagnostics isEnabled]) {
        [SSKDiagnostics log:@"SSKMetalRenderer: SSKParticleShaders.metallib missing from bundle resources."];
    }
    return nil;
}

- (id<MTLTexture>)activeRenderTarget {
    if (self.overrideRenderTarget) {
        return self.overrideRenderTarget;
    }
    id<CAMetalDrawable> drawable = [self ensureCurrentDrawable];
    return drawable.texture;
}

- (id<CAMetalDrawable>)ensureCurrentDrawable {
    if (self.currentDrawable) {
        return self.currentDrawable;
    }
    if (!self.layer) {
        return nil;
    }
    if (@available(macOS 10.13.2, *)) {
        if ([self.layer respondsToSelector:@selector(setAllowsNextDrawableTimeout:)]) {
            self.layer.allowsNextDrawableTimeout = YES;
        }
    }
    id<CAMetalDrawable> drawable = [self.layer nextDrawable];
    if (!drawable) {
        return nil;
    }
    self.currentDrawable = drawable;
    id<MTLTexture> texture = drawable.texture;
    if (texture) {
        self.drawableSize = CGSizeMake(texture.width, texture.height);
    } else {
        self.drawableSize = CGSizeZero;
    }
    return drawable;
}

@end
