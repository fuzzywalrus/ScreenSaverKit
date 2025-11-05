#import <Foundation/Foundation.h>
#import <Metal/Metal.h>

NS_ASSUME_NONNULL_BEGIN

/// Simple texture pool that reuses intermediate render targets to avoid the
/// allocation cost of creating new `MTLTexture` instances every frame.
@interface SSKMetalTextureCache : NSObject

- (instancetype)initWithDevice:(id<MTLDevice>)device NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;

/// Attempts to reuse a matching texture or creates a new one when necessary.
- (nullable id<MTLTexture>)acquireTextureWithSize:(CGSize)size
                                      pixelFormat:(MTLPixelFormat)pixelFormat
                                            usage:(MTLTextureUsage)usage;

/// Convenience helper that matches the size/pixelFormat of an existing texture.
- (nullable id<MTLTexture>)acquireTextureMatchingTexture:(id<MTLTexture>)texture
                                                  usage:(MTLTextureUsage)usage;

/// Returns a texture to the cache for reuse.
- (void)releaseTexture:(id<MTLTexture>)texture;

/// Empties the cache and releases all pooled textures.
- (void)clearCache;

/// Trims the cache to `maxCount` textures (oldest ones are discarded first).
- (void)trimToSize:(NSUInteger)maxCount;

@end

NS_ASSUME_NONNULL_END
