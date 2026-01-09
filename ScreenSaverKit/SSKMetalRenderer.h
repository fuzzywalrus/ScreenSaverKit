#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import <QuartzCore/CAMetalLayer.h>

#import "SSKParticleSystem.h"
#import "SSKMetalEffectStage.h"

NS_ASSUME_NONNULL_BEGIN

@class SSKMetalParticlePass;
@class SSKMetalSpritePass;
@class SSKMetalTextureCache;
@class SSKSprite;

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

/// Renders particles using GPU-accelerated indirect rendering from a particle buffer.
/// Falls back to CPU path if indirect rendering is not supported.
- (void)drawParticlesIndirect:(id<MTLBuffer>)particleBuffer
                      capacity:(NSUInteger)capacity
                     blendMode:(SSKParticleBlendMode)blendMode
                  viewportSize:(CGSize)viewportSize;

/// Draws a texture into the current render target at the specified rectangle.
///
/// @param texture The Metal texture to draw
/// @param rect The destination rectangle in PIXELS (not points).
///             On Retina displays, multiply point coordinates by backingScaleFactor.
///             The texture is drawn centered at the rect's center with the rect's size.
///
/// @note This is a convenience method that creates a temporary sprite internally.
///       For rendering multiple textures efficiently, use drawSprites: instead.
- (void)drawTexture:(id<MTLTexture>)texture atRect:(CGRect)rect;

/// Renders an array of SSKSprite objects with the specified texture and blend mode.
///
/// @param sprites Array of SSKSprite objects to render. Sprite positions and sizes must be in PIXELS.
/// @param texture The texture to apply to all sprites (or nil for solid color). Must use premultiplied alpha.
/// @param blendMode Blend mode (alpha or additive)
/// @param viewportSize Ignored. Viewport dimensions are taken from the render target's pixel dimensions.
///                     This parameter exists for API compatibility but has no effect.
///
/// @note Sprite coordinates are in pixels. On Retina displays, use sprite.setPositionInPoints:scale: to convert.
/// @note The renderer automatically uses the render target's pixel dimensions for the viewport.
- (void)drawSprites:(NSArray<SSKSprite *> *)sprites
            texture:(nullable id<MTLTexture>)texture
          blendMode:(SSKParticleBlendMode)blendMode
       viewportSize:(CGSize)viewportSize;

/// Renders an array of SSKSprite objects with explicit sort control.
///
/// @param sprites Array of SSKSprite objects to render. Sprite positions and sizes must be in PIXELS.
/// @param texture The texture to apply to all sprites (or nil for solid color). Must use premultiplied alpha.
/// @param blendMode Blend mode (alpha or additive)
/// @param viewportSize Ignored. Viewport dimensions are taken from the render target's pixel dimensions.
/// @param sortByZ If YES, sprites are sorted by z before rendering (lower z first = behind)
///
/// @note Sprite coordinates are in pixels. On Retina displays, use sprite.setPositionInPoints:scale: to convert.
/// @note The renderer automatically uses the render target's pixel dimensions for the viewport.
- (void)drawSprites:(NSArray<SSKSprite *> *)sprites
            texture:(nullable id<MTLTexture>)texture
          blendMode:(SSKParticleBlendMode)blendMode
       viewportSize:(CGSize)viewportSize
            sortByZ:(BOOL)sortByZ;

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

/// Stores the last blur radius passed to applyBlur:.
/// This property is set when applyBlur: is called, before the blur is applied.
/// Use this to read the current blur radius setting or for state inspection.
/// Note: This is set even if blur fails (e.g., blur pass unavailable).
/// Legacy wrappers may use this to request a post-particle blur.
@property (nonatomic) CGFloat particleBlurRadius;

/// Bloom threshold (0-1) used when applyBloom: is invoked. Defaults to 0.8.
@property (nonatomic) CGFloat bloomThreshold;

/// Sigma used for the bloom blur pass. Defaults to 3.0.
@property (nonatomic) CGFloat bloomBlurSigma;

/// Particle pass used for rendering particles. Exposed for configuration.
@property (nonatomic, strong, readonly) SSKMetalParticlePass *particlePass;

/// Sprite pass used for rendering 2D sprites. Exposed for configuration.
@property (nonatomic, strong, readonly, nullable) SSKMetalSpritePass *spritePass;

/// Enable GPU-accelerated indirect rendering for particle systems.
/// When enabled, instance buffer building happens on GPU instead of CPU.
/// Requires Metal device with indirect command support. Defaults to NO.
@property (nonatomic) BOOL useIndirectRendering;

/// When YES, drawSprites: automatically sorts sprites by z (back-to-front).
/// Default is NO for backward compatibility.
@property (nonatomic) BOOL spriteSortingEnabled;

@end

NS_ASSUME_NONNULL_END
