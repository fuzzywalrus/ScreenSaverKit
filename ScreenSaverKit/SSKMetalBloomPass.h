#import "SSKMetalPass.h"

@class SSKMetalBlurPass;
@class SSKMetalTextureCache;

NS_ASSUME_NONNULL_BEGIN

/// Brightness threshold filter + separable blur used for bloom/glow effects.
@interface SSKMetalBloomPass : SSKMetalPass

@property (nonatomic) CGFloat threshold;
@property (nonatomic) CGFloat intensity;
@property (nonatomic) CGFloat blurSigma;
/// When YES, bloom threshold and blur passes run at half resolution (4x fewer pixels).
/// Composite still runs at full resolution. Defaults to YES for better performance.
@property (nonatomic) BOOL useHalfResolution;
/// Minimum intensity threshold below which bloom is skipped entirely. Defaults to 0.01.
@property (nonatomic) CGFloat minimumIntensity;

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
