#import "SSKLayerEffects.h"

#import <CoreImage/CoreImage.h>

@implementation SSKLayerEffects

+ (void)applyGaussianBlurWithRadius:(CGFloat)radius toLayer:(CALayer *)layer {
    if (!layer) { return; }
    if (radius <= 0.01) {
        layer.backgroundFilters = nil;
        return;
    }
    CIFilter *filter = [CIFilter filterWithName:@"CIGaussianBlur"];
    if (!filter) { return; }
    [filter setValue:@(radius) forKey:kCIInputRadiusKey];
    layer.backgroundFilters = @[filter];
}

@end
