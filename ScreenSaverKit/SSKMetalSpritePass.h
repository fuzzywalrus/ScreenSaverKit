#import "SSKMetalPass.h"

#import <simd/simd.h>
#include <stddef.h>  // For offsetof
#include <math.h>    // For cosf/sinf in inline helpers

#import "SSKParticleSystem.h"

NS_ASSUME_NONNULL_BEGIN

/**
 * SSK Coordinate Conventions:
 * - All coordinates and sizes are in PIXELS (not points).
 * - On Retina: multiply points by backingScaleFactor/contentsScale.
 * - View origin and Y direction: defined by vertex transform (verify with test sprite).
 * - Rotation direction: defined by vertex transform (verify with test sprite).
 * - UV origin: depends on texture loader/upload. This project assumes top-left for
 *   atlas rect inputs; use setTextureRectInPixelsBottomLeft: if your atlas tool
 *   produces bottom-left origin rects.
 * 
 * Texture Requirements:
 * - All textures MUST use PREMULTIPLIED ALPHA (RGB * A).
 * - SSKSprite.textureForDevice: creates correctly premultiplied textures.
 * - External textures: use kCGImageAlphaPremultipliedLast or equivalent.
 * - Non-premultiplied textures will cause incorrect blending (halos, color fringing).
 */

/**
 * SSKMetalSpriteData - Per-sprite instance data structure for Metal rendering
 * 
 * This struct contains all the data needed to render a single sprite on the GPU.
 * It's designed for efficient GPU access with 16-byte alignment for SIMD operations.
 * 
 * The struct is 80 bytes total and is used in instanced rendering - one instance
 * per sprite, all drawn in a single draw call for maximum performance.
 * 
 * Layout is optimized for:
 *   - 16-byte alignment (required for efficient GPU memory access)
 *   - SIMD operations (vector_float2, vector_float4)
 *   - Cache-friendly access patterns
 * 
 * Usage:
 *   - Typically you don't create these directly - use SSKSprite objects instead
 *   - SSKMetalSpritePass automatically converts SSKSprite objects to this struct
 *   - For advanced use cases, you can create these directly and use encodeSpriteData:
 * 
 * Example (advanced - direct struct creation):
 *   SSKMetalSpriteData data = SSKMetalSpriteDataMake();
 *   data.position = (vector_float2){100.0f, 200.0f};
 *   data.size = (vector_float2){64.0f, 64.0f};
 *   data.colorTint = (vector_float4){1.0f, 0.0f, 0.0f, 1.0f};  // Red
 *   [pass encodeSpriteData:&data count:1 texture:tex ...];
 */
typedef struct __attribute__((aligned(16))) {
    vector_float2 position;      // Anchor point position in screen coordinates (pixels)
    vector_float2 size;          // Width, height in pixels
    vector_float2 sinCos;        // Precomputed [cos(rotation), sin(rotation)]
    vector_float2 anchor;        // Anchor point (0,0 = bottom-left, 0.5,0.5 = center, 1,1 = top-right)
    vector_float4 colorTint;     // RGBA tint (multiplied with texture color)
    vector_float2 textureCoord;  // UV offset (for sprite sheets, default 0,0)
    vector_float2 textureSize;   // UV size (for sprite sheets, default 1,1)
    float opacity;               // Overall alpha multiplier (0.0-1.0)
    float z;                     // Z-order for sorting (higher = in front)
    uint32_t textureIndex;       // Reserved for future texture array batching; currently unused (always 0)
    float padding[1];            // Padding to maintain 16-byte alignment of float4 and consistent stride
} SSKMetalSpriteData;

// Compile-time struct layout verification
_Static_assert(sizeof(SSKMetalSpriteData) == 80, "SSKMetalSpriteData size must be 80 bytes");
_Static_assert(offsetof(SSKMetalSpriteData, z) == 68, "SSKMetalSpriteData.z offset must be 68");

/**
 * Creates a default sprite data struct with identity transform and white tint.
 * 
 * This helper function creates a SSKMetalSpriteData struct with sensible defaults:
 *   - Position: (0, 0)
 *   - Size: (100, 100) pixels
 *   - Rotation: 0 (sinCos = [cos(0), sin(0)] = [1, 0])
 *   - Anchor: (0.5, 0.5) - center
 *   - Color: White (1, 1, 1, 1) - no tint
 *   - Texture: Full texture (offset 0,0, size 1,1)
 *   - Opacity: 1.0 - fully opaque
 *   - Z: 0.0 - default layer
 * 
 * Use this as a starting point, then modify the fields you need.
 * 
 * @return A new SSKMetalSpriteData struct with default values
 * 
 * Example:
 *   SSKMetalSpriteData data = SSKMetalSpriteDataMake();
 *   data.position = (vector_float2){100.0f, 200.0f};
 *   data.colorTint = (vector_float4){1.0f, 0.0f, 0.0f, 1.0f};  // Red
 */
NS_INLINE SSKMetalSpriteData SSKMetalSpriteDataMake(void) {
    SSKMetalSpriteData data = {0};
    data.position = (vector_float2){0.0f, 0.0f};
    data.size = (vector_float2){100.0f, 100.0f};
    data.sinCos = (vector_float2){1.0f, 0.0f};  // cos(0), sin(0)
    data.anchor = (vector_float2){0.5f, 0.5f};  // Center anchor
    data.colorTint = (vector_float4){1.0f, 1.0f, 1.0f, 1.0f};
    data.textureCoord = (vector_float2){0.0f, 0.0f};
    data.textureSize = (vector_float2){1.0f, 1.0f};
    data.opacity = 1.0f;
    data.z = 0.0f;
    data.textureIndex = 0;
    return data;
}

/**
 * Creates sprite data with a rotation angle (computes sin/cos).
 * 
 * This is a convenience function that creates default sprite data and sets the
 * rotation. The sin/cos values are precomputed on the CPU for efficiency.
 * 
 * @param rotation Rotation angle in radians
 * @return A new SSKMetalSpriteData struct with the specified rotation
 * 
 * Example:
 *   SSKMetalSpriteData data = SSKMetalSpriteDataMakeWithRotation(M_PI / 4.0f);
 *   // data.sinCos = [cos(π/4), sin(π/4)] = [0.707, 0.707] (45 degrees)
 */
NS_INLINE SSKMetalSpriteData SSKMetalSpriteDataMakeWithRotation(float rotation) {
    SSKMetalSpriteData data = SSKMetalSpriteDataMake();
    data.sinCos = (vector_float2){cosf(rotation), sinf(rotation)};
    return data;
}

@class SSKSprite;

/**
 * SSKSpriteSamplerFilter - Texture filtering mode for sprites
 * 
 * Controls how textures are sampled when scaled (magnified or minified).
 * This affects the visual appearance of sprites, especially when scaled.
 */
typedef NS_ENUM(NSInteger, SSKSpriteSamplerFilter) {
    /**
     * Linear filtering (bilinear interpolation) - Default
     * 
     * Produces smooth, anti-aliased results when sprites are scaled.
     * Best for photographic images, gradients, and most modern graphics.
     * Can cause blurring on pixel art.
     */
    SSKSpriteSamplerFilterLinear = 0,
    
    /**
     * Nearest-neighbor filtering (point sampling)
     * 
     * Preserves sharp pixel edges when sprites are scaled.
     * Best for pixel art, retro-style graphics, and crisp text.
     * Can cause visible "blockiness" at non-integer scale factors.
     */
    SSKSpriteSamplerFilterNearest = 1,
};

/**
 * SSKMetalSpritePass - Metal render pass for 2D sprite rendering
 * 
 * This class handles the low-level Metal rendering of 2D sprites. It manages:
 *   - Metal pipeline state (vertex/fragment shaders)
 *   - Instance buffer management (for efficient batch rendering)
 *   - Viewport culling (optional, skips off-screen sprites)
 *   - Z-sorting (optional, for depth ordering)
 *   - Blend mode selection (alpha or additive)
 * 
 * Typical Usage:
 *   1. Create and setup: [pass setupWithDevice:device library:library]
 *   2. Each frame: [pass encodeSprites:texture:blendMode:viewportPixels:...]
 * 
 * You typically don't use this class directly - use SSKMetalRenderer.drawSprites:
 * instead, which provides a higher-level API and handles drawable management.
 * 
 * Direct Usage (advanced):
 *   SSKMetalSpritePass *pass = [[SSKMetalSpritePass alloc] init];
 *   [pass setupWithDevice:device library:library];
 *   [pass encodeSprites:sprites texture:tex blendMode:mode viewportPixels:size
 *         commandBuffer:cmdBuf renderTarget:target loadAction:clear clearColor:color];
 * 
 * Performance Features:
 *   - Instanced rendering: All sprites drawn in a single draw call
 *   - Optional viewport culling: Skips off-screen sprites before rendering
 *   - Optional z-sorting: Sorts sprites back-to-front for correct depth
 *   - Efficient instance data: 80-byte struct, 16-byte aligned
 * 
 * Thread Safety:
 *   - NOT thread-safe. Use from a single thread (typically your rendering thread)
 *   - Multiple threads encoding sprites concurrently will cause race conditions
 */
@interface SSKMetalSpritePass : SSKMetalPass

/**
 * When YES, sprites outside the viewport are skipped before rendering. Default NO.
 * 
 * Viewport culling improves performance by skipping sprites that are completely
 * outside the visible area. This is especially useful when you have many sprites
 * but only a few are visible at any time.
 * 
 * How it works:
 *   - Calculates a conservative bounding circle for each sprite
 *   - Accounts for rotation and anchor point (works for any anchor position)
 *   - Skips sprites whose bounding circle is completely outside the viewport
 *   - Happens before sorting, so off-screen sprites aren't sorted (saves CPU)
 * 
 * When to enable:
 *   - You have many sprites (100+)
 *   - Many sprites are often off-screen
 *   - You want to reduce CPU overhead from sorting/rendering invisible sprites
 * 
 * When to disable:
 *   - You have few sprites (performance gain is negligible)
 *   - All sprites are usually visible (no benefit)
 *   - You need to debug rendering issues (culling can hide problems)
 * 
 * Example:
 *   pass.cullingEnabled = YES;  // Enable culling for performance
 */
@property (nonatomic) BOOL cullingEnabled;

/**
 * Texture filtering mode for sprite sampling. Default is Linear.
 * 
 * Controls how textures are interpolated when sprites are scaled:
 *   - SSKSpriteSamplerFilterLinear: Smooth bilinear filtering (default)
 *     Best for photographic images and most modern graphics
 *   - SSKSpriteSamplerFilterNearest: Sharp nearest-neighbor filtering
 *     Best for pixel art and retro-style graphics
 * 
 * IMPORTANT: Changing this property takes effect on the next frame. The sampler
 * state is rebuilt when this property changes.
 * 
 * Example:
 *   pass.samplerFilter = SSKSpriteSamplerFilterNearest;  // For pixel art
 */
@property (nonatomic) SSKSpriteSamplerFilter samplerFilter;

/// Sets up the sprite pass with the given Metal device and shader library.
/// Returns NO if setup fails (e.g., shaders not found).
- (BOOL)setupWithDevice:(id<MTLDevice>)device library:(id<MTLLibrary>)library;

/**
 * Encodes sprite rendering commands into the command buffer.
 * 
 * This is the main rendering method. It takes an array of SSKSprite objects and
 * encodes Metal draw commands to render them all in a single instanced draw call.
 * 
 * Processing order:
 *   1. If cullingEnabled: Build list of visible sprites (skip off-screen)
 *   2. If sortByZ: Sort visible sprites by z value (back-to-front)
 *   3. Build instance data from sprites (convert SSKSprite to SSKMetalSpriteData)
 *   4. Apply flip transformations (via UV coordinate adjustment)
 *   5. Encode Metal draw command (single instanced draw call)
 * 
 * Texture handling:
 *   - If texture is nil: Uses solid-color fragment shader (colorTint only, no sampling)
 *   - If texture is non-nil: Samples texture and multiplies with colorTint
 *   - All sprites in the array use the same texture (for texture batching, use multiple calls)
 * 
 * IMPORTANT: Premultiplied Alpha Requirement
 *   - Textures MUST use premultiplied alpha format (RGB values pre-multiplied by alpha)
 *   - Textures created via SSKSprite.textureForDevice: are automatically premultiplied
 *   - If you provide your own textures, ensure they are premultiplied
 *   - Non-premultiplied textures will blend incorrectly (halos, wrong colors)
 *   - Common premultiplied formats: MTLPixelFormatBGRA8Unorm with kCGImageAlphaPremultipliedLast
 * 
 * Blend modes:
 *   - SSKParticleBlendModeAlpha: Standard alpha blending (uses premultiplied blend factors)
 *   - SSKParticleBlendModeAdditive: Additive blending (for glow/light effects)
 * 
 * IMPORTANT: viewportPixels must match renderTarget dimensions!
 *   - viewportPixels is in pixels (not points)
 *   - renderTarget.width/height is in pixels
 *   - They must match (within 1 pixel tolerance)
 *   - In DEBUG builds, this is asserted
 * 
 * @param sprites Array of SSKSprite objects to render (can be empty)
 * @param texture The texture to sample, or nil for solid-color sprites (uses colorTint only)
 * @param blendMode Blend mode (SSKParticleBlendModeAlpha or SSKParticleBlendModeAdditive)
 * @param viewportPixels Size of the viewport in pixels (must match renderTarget.width/height)
 * @param commandBuffer Metal command buffer to encode draw commands into
 * @param renderTarget Metal texture to render to (typically a drawable texture)
 * @param loadAction Whether to clear the render target or load existing contents
 * @param clearColor Color to clear with if loadAction is MTLLoadActionClear
 * @return YES if encoding succeeded, NO on failure (check SSKDiagnostics for details)
 * 
 * Example:
 *   id<MTLCommandBuffer> cmdBuf = [commandQueue commandBuffer];
 *   id<MTLTexture> target = drawable.texture;
 *   CGSize viewport = CGSizeMake(target.width, target.height);  // Must match!
 *   
 *   BOOL success = [pass encodeSprites:sprites
 *                             texture:logoTexture
 *                           blendMode:SSKParticleBlendModeAlpha
 *                      viewportPixels:viewport
 *                       commandBuffer:cmdBuf
 *                        renderTarget:target
 *                          loadAction:MTLLoadActionClear
 *                          clearColor:MTLClearColorMake(0, 0, 0, 1)];
 */
- (BOOL)encodeSprites:(NSArray<SSKSprite *> *)sprites
              texture:(nullable id<MTLTexture>)texture
            blendMode:(SSKParticleBlendMode)blendMode
       viewportPixels:(CGSize)viewportPixels
        commandBuffer:(id<MTLCommandBuffer>)commandBuffer
         renderTarget:(id<MTLTexture>)renderTarget
           loadAction:(MTLLoadAction)loadAction
           clearColor:(MTLClearColor)clearColor;

/**
 * Encodes sprite rendering commands with optional z-sorting.
 * 
 * This is the same as encodeSprites:texture:blendMode:viewportPixels:... but with
 * explicit control over z-sorting. Use this when you want to sort some batches but
 * not others, or when you want explicit control over sorting behavior.
 * 
 * Z-sorting behavior:
 *   - If sortByZ is YES: Sprites are sorted ascending by z value before rendering
 *   - Lower z values are drawn first (behind)
 *   - Higher z values are drawn last (on top, in front)
 *   - Equal z values maintain original array order (stable sort via index tie-break)
 *   - Non-finite z values (NaN, infinity) are treated as 0.0
 * 
 * Sorting happens after culling (if enabled), so only visible sprites are sorted.
 * This saves CPU time by not sorting sprites that won't be rendered anyway.
 * 
 * Performance considerations:
 *   - Sorting uses qsort_b with O(n log n) complexity
 *   - For large sprite counts (1000+), consider precomputing z values into a C array
 *   - The comparator does Objective-C messaging (sprite.z), which has overhead
 *   - For best performance with many sprites, use encodeSpriteData: with pre-sorted data
 * 
 * @param sprites Array of SSKSprite objects to render
 * @param texture The texture to sample, or nil for solid-color sprites
 * @param blendMode Blend mode (alpha or additive)
 * @param viewportPixels Size of the viewport in pixels (must match renderTarget dimensions)
 * @param commandBuffer Metal command buffer to encode into
 * @param renderTarget Texture to render to
 * @param loadAction Whether to clear or load existing contents
 * @param clearColor Color to clear with if loadAction is clear
 * @param sortByZ If YES, sprites are sorted ascending by z before rendering
 *                (lower z drawn first = behind, higher z drawn last = on top).
 *                Deterministic: equal-z sprites retain original order.
 * @return YES if encoding succeeded, NO on failure
 * 
 * Example:
 *   // Render with z-sorting enabled
 *   [pass encodeSprites:sprites texture:tex blendMode:mode viewportPixels:size
 *         commandBuffer:cmdBuf renderTarget:target loadAction:clear clearColor:color
 *               sortByZ:YES];  // Enable sorting
 */
- (BOOL)encodeSprites:(NSArray<SSKSprite *> *)sprites
              texture:(nullable id<MTLTexture>)texture
            blendMode:(SSKParticleBlendMode)blendMode
       viewportPixels:(CGSize)viewportPixels
        commandBuffer:(id<MTLCommandBuffer>)commandBuffer
         renderTarget:(id<MTLTexture>)renderTarget
           loadAction:(MTLLoadAction)loadAction
           clearColor:(MTLClearColor)clearColor
             sortByZ:(BOOL)sortByZ;

/**
 * Encodes sprite data directly (for advanced use cases).
 * 
 * This method bypasses SSKSprite objects and works directly with SSKMetalSpriteData
 * structs. Use this when:
 *   - You need maximum performance (no Objective-C overhead)
 *   - You're generating sprite data procedurally
 *   - You want to pre-sort data yourself
 *   - You're building sprite data on a background thread
 * 
 * Advantages:
 *   - Lower overhead (no Objective-C messaging)
 *   - Can be used from background threads (structs are plain C)
 *   - More control over data layout and sorting
 * 
 * Disadvantages:
 *   - More verbose (must fill structs manually)
 *   - No automatic flip handling (you must adjust UVs yourself if using negative scale)
 *   - No automatic animation updates
 *   - Less convenient than SSKSprite API
 * 
 * The spriteData array is copied into an internal buffer, so you can free or modify
 * your array after this call returns.
 * 
 * @param spriteData Array of SSKMetalSpriteData structs (must have at least 'count' elements)
 * @param count Number of sprites to render (can be 0)
 * @param texture The texture to sample, or nil for solid-color sprites
 * @param blendMode Blend mode (alpha or additive)
 * @param viewportPixels Size of the viewport in pixels (must match renderTarget dimensions)
 * @param commandBuffer Metal command buffer to encode into
 * @param renderTarget Texture to render to
 * @param loadAction Whether to clear or load existing contents
 * @param clearColor Color to clear with if loadAction is clear
 * @return YES if encoding succeeded, NO on failure
 * 
 * Example:
 *   SSKMetalSpriteData sprites[10];
 *   for (int i = 0; i < 10; i++) {
 *       sprites[i] = SSKMetalSpriteDataMake();
 *       sprites[i].position = (vector_float2){i * 64.0f, 100.0f};
 *       sprites[i].size = (vector_float2){64.0f, 64.0f};
 *   }
 *   [pass encodeSpriteData:sprites count:10 texture:tex blendMode:mode
 *          viewportPixels:size commandBuffer:cmdBuf renderTarget:target
 *            loadAction:clear clearColor:color];
 */
- (BOOL)encodeSpriteData:(const SSKMetalSpriteData *)spriteData
                   count:(NSUInteger)count
                 texture:(nullable id<MTLTexture>)texture
               blendMode:(SSKParticleBlendMode)blendMode
          viewportPixels:(CGSize)viewportPixels
           commandBuffer:(id<MTLCommandBuffer>)commandBuffer
            renderTarget:(id<MTLTexture>)renderTarget
              loadAction:(MTLLoadAction)loadAction
              clearColor:(MTLClearColor)clearColor;

#pragma mark - Deprecated (use viewportPixels: variants)

/// @deprecated Use encodeSprites:texture:blendMode:viewportPixels:... instead
- (BOOL)encodeSprites:(NSArray<SSKSprite *> *)sprites
              texture:(nullable id<MTLTexture>)texture
            blendMode:(SSKParticleBlendMode)blendMode
         viewportSize:(CGSize)viewportSize
        commandBuffer:(id<MTLCommandBuffer>)commandBuffer
         renderTarget:(id<MTLTexture>)renderTarget
           loadAction:(MTLLoadAction)loadAction
           clearColor:(MTLClearColor)clearColor
    __attribute__((deprecated("Use viewportPixels: variant")));

/// @deprecated Use encodeSprites:texture:blendMode:viewportPixels:...sortByZ: instead
- (BOOL)encodeSprites:(NSArray<SSKSprite *> *)sprites
              texture:(nullable id<MTLTexture>)texture
            blendMode:(SSKParticleBlendMode)blendMode
         viewportSize:(CGSize)viewportSize
        commandBuffer:(id<MTLCommandBuffer>)commandBuffer
         renderTarget:(id<MTLTexture>)renderTarget
           loadAction:(MTLLoadAction)loadAction
           clearColor:(MTLClearColor)clearColor
             sortByZ:(BOOL)sortByZ
    __attribute__((deprecated("Use viewportPixels: variant")));

/// @deprecated Use encodeSpriteData:count:texture:blendMode:viewportPixels:... instead
- (BOOL)encodeSpriteData:(const SSKMetalSpriteData *)spriteData
                   count:(NSUInteger)count
                 texture:(nullable id<MTLTexture>)texture
               blendMode:(SSKParticleBlendMode)blendMode
            viewportSize:(CGSize)viewportSize
           commandBuffer:(id<MTLCommandBuffer>)commandBuffer
            renderTarget:(id<MTLTexture>)renderTarget
              loadAction:(MTLLoadAction)loadAction
              clearColor:(MTLClearColor)clearColor
    __attribute__((deprecated("Use viewportPixels: variant")));

@end

NS_ASSUME_NONNULL_END

