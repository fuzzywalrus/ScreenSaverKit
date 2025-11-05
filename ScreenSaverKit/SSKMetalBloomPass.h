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
                library:(id<MTLLibrary>)library
               blurPass:(nullable SSKMetalBlurPass *)blurPass;

- (BOOL)encodeBloomWithCommandBuffer:(id<MTLCommandBuffer>)commandBuffer
                              source:(id<MTLTexture>)source
                        renderTarget:(id<MTLTexture>)renderTarget
                        textureCache:(SSKMetalTextureCache *)textureCache;

@end

NS_ASSUME_NONNULL_END
