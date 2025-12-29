#import "SSKMetalPass.h"

#import "SSKParticleSystem.h"

NS_ASSUME_NONNULL_BEGIN

/// Render pass responsible for drawing particle instances using Metal.
@interface SSKMetalParticlePass : SSKMetalPass

/// Length multiplier used when rendering particles with z-depth enabled (default: 8.0).
/// Set this to match the length multiplier used during particle spawning.
@property (nonatomic) CGFloat lengthMultiplier;

- (BOOL)setupWithDevice:(id<MTLDevice>)device library:(id<MTLLibrary>)library;

- (BOOL)encodeParticles:(NSArray<SSKParticle *> *)particles
              blendMode:(SSKParticleBlendMode)blendMode
           viewportSize:(CGSize)viewportSize
          commandBuffer:(id<MTLCommandBuffer>)commandBuffer
           renderTarget:(id<MTLTexture>)renderTarget
             loadAction:(MTLLoadAction)loadAction
             clearColor:(MTLClearColor)clearColor;

@end

NS_ASSUME_NONNULL_END
