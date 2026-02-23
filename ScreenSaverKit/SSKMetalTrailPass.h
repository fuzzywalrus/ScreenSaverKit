#import <Foundation/Foundation.h>
#import <Metal/Metal.h>

NS_ASSUME_NONNULL_BEGIN

/// Manages a persistent offscreen texture that accumulates particle trails.
/// Each frame: fades the previous contents, then the caller renders new particles on top.
/// The trail texture can then be composited onto the final drawable.
@interface SSKMetalTrailPass : NSObject

- (nullable instancetype)initWithDevice:(id<MTLDevice>)device
                                library:(id<MTLLibrary>)library NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;

/// Returns the persistent trail texture, creating or resizing if needed.
/// The texture uses MTLLoadActionLoad to preserve previous frame content.
- (nullable id<MTLTexture>)trailTextureForSize:(CGSize)size;

/// Fades the trail texture by multiplying all pixels by (1.0 - fadeRate).
/// Call once per frame before rendering new particles onto the trail texture.
- (void)fadeWithRate:(float)fadeRate commandBuffer:(id<MTLCommandBuffer>)commandBuffer;

/// Copies the trail texture onto the destination using a blit encoder.
- (void)blitTo:(id<MTLTexture>)destination commandBuffer:(id<MTLCommandBuffer>)commandBuffer;

@end

NS_ASSUME_NONNULL_END
