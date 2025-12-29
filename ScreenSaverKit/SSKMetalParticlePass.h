#import "SSKMetalPass.h"

#import "SSKParticleSystem.h"

NS_ASSUME_NONNULL_BEGIN

/// Render pass responsible for drawing particle instances using Metal.
@interface SSKMetalParticlePass : SSKMetalPass

/// Length multiplier used when rendering particles with z-depth enabled (default: 8.0).
/// Set this to match the length multiplier used during particle spawning.
@property (nonatomic) CGFloat lengthMultiplier;

/// Indicates whether GPU-side indirect rendering is available.
@property (nonatomic, readonly) BOOL supportsIndirectRendering;

- (BOOL)setupWithDevice:(id<MTLDevice>)device library:(id<MTLLibrary>)library;

- (BOOL)encodeParticles:(NSArray<SSKParticle *> *)particles
              blendMode:(SSKParticleBlendMode)blendMode
           viewportSize:(CGSize)viewportSize
          commandBuffer:(id<MTLCommandBuffer>)commandBuffer
           renderTarget:(id<MTLTexture>)renderTarget
             loadAction:(MTLLoadAction)loadAction
             clearColor:(MTLClearColor)clearColor;

/// GPU-accelerated indirect rendering. Builds instance buffer on GPU and uses indirect draw.
/// Significantly faster for large particle counts (1000+) compared to CPU-side instance building.
/// Falls back to CPU path if indirect rendering is not supported.
- (BOOL)encodeParticlesIndirect:(id<MTLBuffer>)particleBuffer
                       capacity:(NSUInteger)capacity
                      blendMode:(SSKParticleBlendMode)blendMode
                   viewportSize:(CGSize)viewportSize
                  commandBuffer:(id<MTLCommandBuffer>)commandBuffer
                   renderTarget:(id<MTLTexture>)renderTarget
                     loadAction:(MTLLoadAction)loadAction
                     clearColor:(MTLClearColor)clearColor;

@end

NS_ASSUME_NONNULL_END
