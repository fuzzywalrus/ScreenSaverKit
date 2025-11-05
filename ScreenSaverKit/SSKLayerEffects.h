#import <QuartzCore/QuartzCore.h>

NS_ASSUME_NONNULL_BEGIN

@interface SSKLayerEffects : NSObject

/// Applies (or removes) a Gaussian blur filter on the supplied layer.
/// Passing a radius <= 0 removes the blur.
+ (void)applyGaussianBlurWithRadius:(CGFloat)radius toLayer:(CALayer *)layer;

@end

NS_ASSUME_NONNULL_END
