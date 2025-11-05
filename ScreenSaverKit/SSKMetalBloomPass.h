#import "SSKMetalPass.h"

@class SSKMetalBlurPass;
@class SSKMetalTextureCache;

NS_ASSUME_NONNULL_BEGIN

/// Brightness threshold filter + separable blur used for bloom/glow effects.
@interface SSKMetalBloomPass : SSKMetalPass

@property (nonatomic) CGFloat threshold;
@property (nonatomic) CGFloat intensity;
@property (nonatomic) CGFloat blurSigma;

- (BOOL)setupWithDevice:(id<MTLDevice>)device
                library:(id<MTLLibrary>)library;

/// Optionally supply a shared blur pass instance. When nil the bloom pass
/// falls back to its own private blur implementation.
- (void)setSharedBlurPass:(nullable SSKMetalBlurPass *)blurPass;

- (BOOL)encodeBloomWithCommandBuffer:(id<MTLCommandBuffer>)commandBuffer
                              source:(id<MTLTexture>)source
                        renderTarget:(id<MTLTexture>)renderTarget
                        textureCache:(SSKMetalTextureCache *)textureCache;

@end

NS_ASSUME_NONNULL_END
