#import "SSKMetalPass.h"

NS_ASSUME_NONNULL_BEGIN

/// Brightness threshold filter + separable blur used for bloom/glow effects.
@interface SSKMetalBloomPass : SSKMetalPass

@property (nonatomic) CGFloat threshold;
@property (nonatomic) CGFloat intensity;
@property (nonatomic) CGFloat blurSigma;

- (BOOL)setupWithDevice:(id<MTLDevice>)device library:(id<MTLLibrary>)library;

- (BOOL)encodeBloomWithCommandBuffer:(id<MTLCommandBuffer>)commandBuffer
                              source:(id<MTLTexture>)source
                        renderTarget:(id<MTLTexture>)renderTarget;

@end

NS_ASSUME_NONNULL_END
