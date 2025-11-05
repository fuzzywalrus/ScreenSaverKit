#import "SSKMetalPass.h"

@class SSKMetalTextureCache;

NS_ASSUME_NONNULL_BEGIN

/// Compute-based Gaussian blur pass that can be reused across renderers.
@interface SSKMetalBlurPass : SSKMetalPass

/// Blur radius expressed as Gaussian sigma. Values <= 0.01 are treated as no-op.
@property (nonatomic) CGFloat radius;

/// Prepares compute pipelines using the supplied device/library combo.
- (BOOL)setupWithDevice:(id<MTLDevice>)device library:(id<MTLLibrary>)library;

/// Encodes a blur from `source` into `destination`. Returns NO on failure.
- (BOOL)encodeBlur:(id<MTLTexture>)source
        destination:(id<MTLTexture>)destination
      commandBuffer:(id<MTLCommandBuffer>)commandBuffer
       textureCache:(SSKMetalTextureCache *)textureCache;

@end

NS_ASSUME_NONNULL_END
