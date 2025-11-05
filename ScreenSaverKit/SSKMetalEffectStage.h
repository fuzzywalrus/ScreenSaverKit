#import <Foundation/Foundation.h>
#import <Metal/Metal.h>

#import "SSKMetalPass.h"

NS_ASSUME_NONNULL_BEGIN

@class SSKMetalRenderer;

/// Block invoked when an effect stage should encode its work into the current
/// command buffer. Returning `NO` signals a failure so the renderer can log it.
typedef BOOL (^SSKMetalEffectStageHandler)(SSKMetalRenderer *renderer,
                                           SSKMetalPass *pass,
                                           id<MTLCommandBuffer> commandBuffer,
                                           id<MTLTexture> renderTarget,
                                           NSDictionary *parameters);

/// Describes a single post-process stage that can be registered with
/// `SSKMetalRenderer`. Each stage wraps a concrete `SSKMetalPass` instance and
/// a handler block that knows how to invoke it.
@interface SSKMetalEffectStage : NSObject

/// Unique identifier used when registering or requesting the stage.
@property (nonatomic, copy, readonly) NSString *identifier;

/// Concrete pass instance that performs the GPU work for this stage.
@property (nonatomic, strong, readonly) SSKMetalPass *pass;

/// Block responsible for encoding the effect.
@property (nonatomic, copy, readonly) SSKMetalEffectStageHandler handler;

/// Designated initialiser.
- (instancetype)initWithIdentifier:(NSString *)identifier
                              pass:(SSKMetalPass *)pass
                           handler:(SSKMetalEffectStageHandler)handler NS_DESIGNATED_INITIALIZER;

- (instancetype)init NS_UNAVAILABLE;
+ (instancetype)new NS_UNAVAILABLE;

@end

NS_ASSUME_NONNULL_END
