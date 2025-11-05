#import <Foundation/Foundation.h>
#import <Metal/Metal.h>

NS_ASSUME_NONNULL_BEGIN

/// Abstract base class for individual render passes used by `SSKMetalRenderer`.
/// Subclasses typically prepare pipeline state in `setupWithDevice:` and encode
/// the actual commands in `encodeToCommandBuffer:renderTarget:parameters:`.
@interface SSKMetalPass : NSObject

/// Called once during renderer initialisation. Subclasses set up pipeline state
/// or buffers here. Return `NO` to signal a fatal setup error.
- (BOOL)setupWithDevice:(id<MTLDevice>)device;

/// Encode the pass into `commandBuffer`, writing to `renderTarget`. The default
/// implementation asserts to highlight missing overrides.
- (void)encodeToCommandBuffer:(id<MTLCommandBuffer>)commandBuffer
                  renderTarget:(id<MTLTexture>)renderTarget
                    parameters:(NSDictionary *)params;

/// Human-readable name used when logging diagnostics.
@property (nonatomic, copy, readonly) NSString *passName;

@end

NS_ASSUME_NONNULL_END
