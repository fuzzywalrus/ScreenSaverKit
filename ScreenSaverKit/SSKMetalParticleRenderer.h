#import <Foundation/Foundation.h>
#import <QuartzCore/CAMetalLayer.h>
#import <Metal/Metal.h>

#import "SSKParticleSystem.h"

NS_ASSUME_NONNULL_BEGIN

/// Lightweight helper that renders `SSKParticleSystem` data using Metal.
/// Clients supply a CAMetalLayer (typically backing their saver view) and
/// call `renderParticles:blendMode:viewportSize:` once per frame.
@interface SSKMetalParticleRenderer : NSObject

/// Returns nil when the supplied layer/device combo cannot compile shaders or pipelines.
- (nullable instancetype)initWithLayer:(CAMetalLayer *)layer;

/// Describes the most recent initialisation failure (if any). Cleared on successful init.
+ (nullable NSString *)lastCreationErrorMessage;

/// Renders the provided particles. `viewportSize` should be in points (same coordinate
/// system as the saver view). Returns YES when rendering succeeded.
- (BOOL)renderParticles:(NSArray<SSKParticle *> *)particles
              blendMode:(SSKParticleBlendMode)blendMode
           viewportSize:(CGSize)viewportSize;

/// Clear colour used when filling the drawable (defaults to opaque black).
@property (nonatomic) MTLClearColor clearColor;

@end

NS_ASSUME_NONNULL_END
