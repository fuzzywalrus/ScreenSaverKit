#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import <QuartzCore/CAMetalLayer.h>

#import "SSKParticleSystem.h"
#import "SSKMetalEffectStage.h"

NS_ASSUME_NONNULL_BEGIN

@class SSKMetalParticlePass;
@class SSKMetalTextureCache;

FOUNDATION_EXPORT NSString * const SSKMetalEffectIdentifierBlur;
FOUNDATION_EXPORT NSString * const SSKMetalEffectIdentifierBloom;
FOUNDATION_EXPORT NSString * const SSKMetalEffectIdentifierColorGrading;

/// Unified Metal renderer that owns the drawable lifecycle and provides
/// higher-level drawing entry points for saver implementations.
@interface SSKMetalRenderer : NSObject

/// Designated initialiser. Returns `nil` when no Metal device or command queue
/// can be created for the supplied layer.
- (nullable instancetype)initWithLayer:(CAMetalLayer *)layer NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;

/// Begins a new frame by fetching the next drawable and creating a command buffer.
/// Returns `NO` when a drawable is unavailable (e.g. window offscreen).
- (BOOL)beginFrame;

/// Commits the current command buffer and presents the drawable.
/// Safe to call even when `beginFrame` failed (no-ops in that case).
- (void)endFrame;

/// Clears the active render target using the supplied colour.
- (void)clearWithColor:(MTLClearColor)color;

/// Renders the provided particles using the specified blend mode and viewport.
- (void)drawParticles:(NSArray<SSKParticle *> *)particles
            blendMode:(SSKParticleBlendMode)blendMode
         viewportSize:(CGSize)viewportSize;

/// Draws a texture into the current render target.
- (void)drawTexture:(id<MTLTexture>)texture atRect:(CGRect)rect;

/// Applies a separable Gaussian blur to the current render target.
- (void)applyBlur:(CGFloat)radius;

/// Applies a bloom/glow effect with the given intensity.
- (void)applyBloom:(CGFloat)intensity;

/// Applies colour grading parameters represented as a dictionary or future struct.
- (void)applyColorGrading:(nullable id)params;

/// Registers (or replaces) a custom effect stage.
- (void)registerEffectStage:(SSKMetalEffectStage *)stage;

/// Removes the stage for the supplied identifier.
- (void)unregisterEffectStageWithIdentifier:(NSString *)identifier;

/// Returns the stage registered for the identifier, if any.
- (nullable SSKMetalEffectStage *)effectStageWithIdentifier:(NSString *)identifier;

/// Returns the identifiers for all registered effect stages.
- (NSArray<NSString *> *)registeredEffectIdentifiers;

/// Applies a registered effect using the supplied parameters dictionary.
- (BOOL)applyEffectWithIdentifier:(NSString *)identifier
                       parameters:(nullable NSDictionary *)parameters;

/// Applies multiple effects in the order provided. Parameters are looked up
/// (optionally) using the effect identifier as the key.
- (void)applyEffects:(NSArray<NSString *> *)identifiers
          parameters:(nullable NSDictionary<NSString *, NSDictionary *> *)parameters;

/// Sets the intermediate render target. Pass `nil` to restore the drawable.
- (void)setRenderTarget:(nullable id<MTLTexture>)texture;

/// Colour used when clearing the drawable if no explicit clear is requested.
@property (nonatomic) MTLClearColor clearColor;

/// Size of the drawable in pixels. Updated after a successful `beginFrame`.
@property (nonatomic, readonly) CGSize drawableSize;

/// Metal device backing the renderer.
@property (nonatomic, strong, readonly) id<MTLDevice> device;

/// Current command buffer (valid between `beginFrame` and `endFrame`).
@property (nonatomic, strong, readonly, nullable) id<MTLCommandBuffer> currentCommandBuffer;

/// Texture cache shared by render passes for intermediate allocations.
@property (nonatomic, strong, readonly) SSKMetalTextureCache *textureCache;

/// Convenience property used by legacy wrappers to request a post-particle blur.
@property (nonatomic) CGFloat particleBlurRadius;

/// Bloom threshold (0-1) used when applyBloom: is invoked. Defaults to 0.8.
@property (nonatomic) CGFloat bloomThreshold;

/// Sigma used for the bloom blur pass. Defaults to 3.0.
@property (nonatomic) CGFloat bloomBlurSigma;

@end

NS_ASSUME_NONNULL_END
