#import "SSKMetalPass.h"

@implementation SSKMetalPass

- (NSString *)passName {
    return NSStringFromClass(self.class);
}

- (BOOL)setupWithDevice:(id<MTLDevice>)device {
    (void)device;
    return YES;
}

- (void)encodeToCommandBuffer:(id<MTLCommandBuffer>)commandBuffer
                  renderTarget:(id<MTLTexture>)renderTarget
                    parameters:(NSDictionary *)params {
    (void)commandBuffer;
    (void)renderTarget;
    (void)params;
    NSAssert(NO, @"%@ must override encodeToCommandBuffer:renderTarget:parameters:", self.passName);
}

@end
