#import "SSKMetalRenderer.h"

#import "SSKMetalTextureCache.h"
#import "SSKParticleSystem.h"
#import "SSKDiagnostics.h"
#import "SSKShaderLoader.h"
#import "SSKMetalParticlePass.h"
#import "SSKMetalSpritePass.h"
#import "SSKSprite.h"
#import "SSKMetalBlurPass.h"
#import "SSKMetalBloomPass.h"
#import "SSKMetalTrailPass.h"

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
@property (nonatomic, strong, readwrite) SSKMetalParticlePass *particlePass;
@property (nonatomic, strong, readwrite, nullable) SSKMetalSpritePass *spritePass;
@property (nonatomic, strong, nullable) id<MTLLibrary> spriteShaderLibrary;
@property (nonatomic, strong, nullable) SSKMetalBlurPass *blurPass;
@property (nonatomic, strong, nullable) SSKMetalBloomPass *bloomPass;
@property (nonatomic, strong, nullable) SSKMetalTrailPass *trailPass;
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
        _trailFadeRate = 0.05;
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
        
        // Initialize sprite pass (optional - continues without it if shaders unavailable)
        _spriteShaderLibrary = [self loadSpriteShaderLibraryWithDevice:device];
        if (_spriteShaderLibrary) {
            _spritePass = [[SSKMetalSpritePass alloc] init];
            if (![_spritePass setupWithDevice:device library:_spriteShaderLibrary]) {
                if ([SSKDiagnostics isEnabled]) {
                    [SSKDiagnostics log:@"SSKMetalRenderer: sprite pass unavailable (continuing without sprite support)."];
                }
                _spritePass = nil;
            }
        } else if ([SSKDiagnostics isEnabled]) {
            [SSKDiagnostics log:@"SSKMetalRenderer: sprite shaders unavailable (continuing without sprite support)."];
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

    if (self.trailPersistenceEnabled) {
        [self drawParticlesWithTrail:liveParticles
                           blendMode:blendMode
                        viewportSize:viewportSize
                       commandBuffer:commandBuffer
                              target:target];
        return;
    }

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

- (void)drawParticlesIndirect:(id<MTLBuffer>)particleBuffer
                     capacity:(NSUInteger)capacity
                    blendMode:(SSKParticleBlendMode)blendMode
                 viewportSize:(CGSize)viewportSize
                    particles:(NSArray<SSKParticle *> *)particles {
    if (!self.particlePass) { return; }
    id<MTLCommandBuffer> commandBuffer = self.currentCommandBuffer;
    id<MTLTexture> target = [self activeRenderTarget];
    if (!commandBuffer || !target || !particleBuffer) { return; }

    // Resolve trail texture if trail persistence is enabled
    id<MTLTexture> renderTarget = target;
    SSKMetalTrailPass *trail = nil;
    if (self.trailPersistenceEnabled) {
        trail = [self ensureTrailPass];
        if (trail) {
            id<MTLTexture> trailTex = [trail trailTextureForSize:CGSizeMake(target.width, target.height)];
            if (trailTex) {
                [trail fadeWithRate:(float)self.trailFadeRate commandBuffer:commandBuffer];
                renderTarget = trailTex;
            }
        }
    }

    // Try indirect rendering if enabled and supported
    if (self.useIndirectRendering && self.particlePass.supportsIndirectRendering) {
        BOOL success = [self.particlePass encodeParticlesIndirect:particleBuffer
                                                          capacity:capacity
                                                         blendMode:blendMode
                                                      viewportSize:viewportSize
                                                     commandBuffer:commandBuffer
                                                      renderTarget:renderTarget
                                                        loadAction:MTLLoadActionLoad
                                                        clearColor:self.clearColor];
        if (success) {
            if (trail && renderTarget != target) {
                if (self.needsClearOnNextPass) {
                    MTLRenderPassDescriptor *rpd = [MTLRenderPassDescriptor renderPassDescriptor];
                    rpd.colorAttachments[0].texture = target;
                    rpd.colorAttachments[0].loadAction = MTLLoadActionClear;
                    rpd.colorAttachments[0].storeAction = MTLStoreActionStore;
                    rpd.colorAttachments[0].clearColor = self.clearColor;
                    id<MTLRenderCommandEncoder> enc = [commandBuffer renderCommandEncoderWithDescriptor:rpd];
                    [enc endEncoding];
                }
                [trail blitTo:target commandBuffer:commandBuffer];
            }
            self.needsClearOnNextPass = NO;
            return;
        }

        if ([SSKDiagnostics isEnabled]) {
            [SSKDiagnostics log:@"SSKMetalRenderer: indirect particle pass failed, falling back to CPU path."];
        }
    }

    // Fallback to CPU path if particles array is provided
    if (particles) {
        [self drawParticles:particles blendMode:blendMode viewportSize:viewportSize];
        return;
    }

    if ([SSKDiagnostics isEnabled]) {
        [SSKDiagnostics log:@"SSKMetalRenderer: drawParticlesIndirect called but indirect rendering not available and no CPU fallback particles provided."];
    }
}

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-implementations"
- (void)drawParticlesIndirect:(id<MTLBuffer>)particleBuffer
                      capacity:(NSUInteger)capacity
                     blendMode:(SSKParticleBlendMode)blendMode
                  viewportSize:(CGSize)viewportSize {
    [self drawParticlesIndirect:particleBuffer
                       capacity:capacity
                      blendMode:blendMode
                   viewportSize:viewportSize
                      particles:nil];
}
#pragma clang diagnostic pop

- (void)drawTexture:(id<MTLTexture>)texture atRect:(CGRect)rect {
    if (!texture) { return; }

    // Fallback path when sprite shaders/pass are unavailable.
    // This covers full-frame copies (e.g. Amble intermediate -> drawable) so the
    // frame is still presented instead of appearing blank/magenta.
    if (!self.spritePass) {
        id<MTLCommandBuffer> commandBuffer = self.currentCommandBuffer;
        id<MTLTexture> target = [self activeRenderTarget];
        if (!commandBuffer || !target) { return; }

        CGRect targetRect = CGRectMake(0.0, 0.0, (CGFloat)target.width, (CGFloat)target.height);
        BOOL fullFrameCopy = CGRectEqualToRect(rect, targetRect);
        BOOL sizeMatches = (texture.width == target.width && texture.height == target.height);
        if (!fullFrameCopy || !sizeMatches) {
            if ([SSKDiagnostics isEnabled]) {
                [SSKDiagnostics log:@"SSKMetalRenderer: drawTexture fallback requires full-frame same-size copy (src %lux%lu, dst %lux%lu).",
                 (unsigned long)texture.width,
                 (unsigned long)texture.height,
                 (unsigned long)target.width,
                 (unsigned long)target.height];
            }
            return;
        }

        if (self.needsClearOnNextPass) {
            MTLRenderPassDescriptor *rpd = [MTLRenderPassDescriptor renderPassDescriptor];
            rpd.colorAttachments[0].texture = target;
            rpd.colorAttachments[0].loadAction = MTLLoadActionClear;
            rpd.colorAttachments[0].storeAction = MTLStoreActionStore;
            rpd.colorAttachments[0].clearColor = self.clearColor;
            id<MTLRenderCommandEncoder> enc = [commandBuffer renderCommandEncoderWithDescriptor:rpd];
            [enc endEncoding];
        }

        id<MTLBlitCommandEncoder> blit = [commandBuffer blitCommandEncoder];
        if (!blit) { return; }
        [blit copyFromTexture:texture
                  sourceSlice:0
                  sourceLevel:0
                 sourceOrigin:MTLOriginMake(0, 0, 0)
                   sourceSize:MTLSizeMake(texture.width, texture.height, 1)
                    toTexture:target
             destinationSlice:0
             destinationLevel:0
            destinationOrigin:MTLOriginMake(0, 0, 0)];
        [blit endEncoding];
        self.needsClearOnNextPass = NO;
        return;
    }
    
    // Create a single sprite to render the texture
    // NOTE: rect is expected to be in PIXELS, not points.
    // On Retina displays, callers must multiply point coordinates by backingScaleFactor.
    SSKSprite *sprite = [[SSKSprite alloc] init];
    sprite.position = NSMakePoint(NSMidX(rect), NSMidY(rect));  // Center of rect in pixels
    sprite.size = rect.size;  // Size in pixels
    sprite.rotation = 0.0;
    sprite.colorTint = [NSColor whiteColor];
    sprite.opacity = 1.0;
    
    [self drawSprites:@[sprite]
              texture:texture
            blendMode:SSKParticleBlendModeAlpha];
}

- (void)drawSprites:(NSArray<SSKSprite *> *)sprites
            texture:(id<MTLTexture>)texture
          blendMode:(SSKParticleBlendMode)blendMode {
    [self drawSprites:sprites texture:texture blendMode:blendMode sortByZ:self.spriteSortingEnabled];
}

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-implementations"
- (void)drawSprites:(NSArray<SSKSprite *> *)sprites
            texture:(id<MTLTexture>)texture
          blendMode:(SSKParticleBlendMode)blendMode
       viewportSize:(CGSize)viewportSize {
    (void)viewportSize;
    [self drawSprites:sprites texture:texture blendMode:blendMode sortByZ:self.spriteSortingEnabled];
}

- (void)drawSprites:(NSArray<SSKSprite *> *)sprites
            texture:(id<MTLTexture>)texture
          blendMode:(SSKParticleBlendMode)blendMode
       viewportSize:(CGSize)viewportSize
            sortByZ:(BOOL)sortByZ {
    (void)viewportSize;
    [self drawSprites:sprites texture:texture blendMode:blendMode sortByZ:sortByZ];
}
#pragma clang diagnostic pop

- (void)drawSprites:(NSArray<SSKSprite *> *)sprites
            texture:(id<MTLTexture>)texture
          blendMode:(SSKParticleBlendMode)blendMode
            sortByZ:(BOOL)sortByZ {
    if (!self.spritePass) {
        if ([SSKDiagnostics isEnabled]) {
            [SSKDiagnostics log:@"SSKMetalRenderer: drawSprites called but sprite pass is unavailable."];
        }
        return;
    }
    
    id<MTLCommandBuffer> commandBuffer = self.currentCommandBuffer;
    id<MTLTexture> target = [self activeRenderTarget];
    if (!commandBuffer || !target) { return; }
    
    // Always use the render target's pixel dimensions for viewportPixels.
    // This is the only reliable source of truth for the actual rendering size.
    //
    // The viewportSize parameter is in points for backward compatibility,
    // but the sprite pass requires pixels. Using target.width/height directly
    // handles both normal drawable rendering and overrideRenderTarget cases.
    CGSize viewportPixels = CGSizeMake(target.width, target.height);
    if (viewportPixels.width <= 0 || viewportPixels.height <= 0) {
        // Render target has invalid dimensions - this shouldn't happen.
        // Log and return rather than drawing with incorrect scaling.
        if ([SSKDiagnostics isEnabled]) {
            [SSKDiagnostics log:@"SSKMetalRenderer: render target has invalid dimensions (%g x %g), skipping draw",
                viewportPixels.width, viewportPixels.height];
        }
        NSAssert(NO, @"SSKMetalRenderer: render target has invalid dimensions (%g x %g)",
                 viewportPixels.width, viewportPixels.height);
        return;  // Don't draw with incorrect dimensions
    }
    
    MTLLoadAction loadAction = self.needsClearOnNextPass ? MTLLoadActionClear : MTLLoadActionLoad;
    BOOL success = [self.spritePass encodeSprites:sprites
                                          texture:texture
                                        blendMode:blendMode
                                   viewportPixels:viewportPixels
                                    commandBuffer:commandBuffer
                                     renderTarget:target
                                       loadAction:loadAction
                                       clearColor:self.clearColor
                                          sortByZ:sortByZ];
    if (!success && [SSKDiagnostics isEnabled]) {
        [SSKDiagnostics log:@"SSKMetalRenderer: sprite pass failed to encode."];
    }
    self.needsClearOnNextPass = NO;
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
    
    // Effect Stage Coupling: Blur and Bloom
    //
    // The bloom effect depends on the blur effect internally (it uses blur for the glow).
    // When either effect is registered, we automatically connect them:
    //   - When blur is registered: Tell bloom to use this blur pass
    //   - When bloom is registered: Find blur and connect them
    //
    // This coupling is intentional - it ensures bloom works correctly without requiring
    // callers to manually wire up the dependency. If you replace the blur stage, the
    // bloom will automatically use the new blur pass.
    //
    // If you need bloom without blur, or with a different blur implementation, you can:
    //   1. Register a custom bloom stage that doesn't use blur
    //   2. Call [bloomPass setSharedBlurPass:nil] after registration
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
    return [SSKShaderLoader loadLibraryNamed:@"SSKParticleShaders"
                                      device:device
                                      bundle:[NSBundle bundleForClass:self.class]];
}

- (nullable id<MTLLibrary>)loadSpriteShaderLibraryWithDevice:(id<MTLDevice>)device {
    return [SSKShaderLoader loadLibraryNamed:@"SSKSpriteShaders"
                                      device:device
                                      bundle:[NSBundle bundleForClass:self.class]];
}

- (SSKMetalTrailPass *)ensureTrailPass {
    if (!self.trailPass) {
        self.trailPass = [[SSKMetalTrailPass alloc] initWithDevice:self.device
                                                           library:self.shaderLibrary];
    }
    return self.trailPass;
}

- (void)drawParticlesWithTrail:(NSArray<SSKParticle *> *)particles
                     blendMode:(SSKParticleBlendMode)blendMode
                  viewportSize:(CGSize)viewportSize
                 commandBuffer:(id<MTLCommandBuffer>)commandBuffer
                        target:(id<MTLTexture>)target {
    SSKMetalTrailPass *trail = [self ensureTrailPass];
    if (!trail) {
        // Fall back to normal drawing if trail pass creation failed
        MTLLoadAction loadAction = self.needsClearOnNextPass ? MTLLoadActionClear : MTLLoadActionLoad;
        [self.particlePass encodeParticles:particles
                                 blendMode:blendMode
                              viewportSize:viewportSize
                             commandBuffer:commandBuffer
                              renderTarget:target
                                loadAction:loadAction
                                clearColor:self.clearColor];
        self.needsClearOnNextPass = NO;
        return;
    }

    CGSize trailSize = CGSizeMake(target.width, target.height);
    id<MTLTexture> trailTexture = [trail trailTextureForSize:trailSize];
    if (!trailTexture) {
        self.needsClearOnNextPass = NO;
        return;
    }

    // 1. Fade the trail texture
    [trail fadeWithRate:(float)self.trailFadeRate commandBuffer:commandBuffer];

    // 2. Draw new particles onto the trail texture (preserving existing trails)
    [self.particlePass encodeParticles:particles
                             blendMode:blendMode
                          viewportSize:viewportSize
                         commandBuffer:commandBuffer
                          renderTarget:trailTexture
                            loadAction:MTLLoadActionLoad
                            clearColor:MTLClearColorMake(0, 0, 0, 1)];

    // 3. Clear the drawable if needed, then blit trail onto it
    if (self.needsClearOnNextPass) {
        MTLRenderPassDescriptor *rpd = [MTLRenderPassDescriptor renderPassDescriptor];
        rpd.colorAttachments[0].texture = target;
        rpd.colorAttachments[0].loadAction = MTLLoadActionClear;
        rpd.colorAttachments[0].storeAction = MTLStoreActionStore;
        rpd.colorAttachments[0].clearColor = self.clearColor;
        id<MTLRenderCommandEncoder> enc = [commandBuffer renderCommandEncoderWithDescriptor:rpd];
        [enc endEncoding];
    }
    [trail blitTo:target commandBuffer:commandBuffer];
    self.needsClearOnNextPass = NO;
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
