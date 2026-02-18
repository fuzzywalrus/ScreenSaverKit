#import <AppKit/AppKit.h>
#import <Metal/Metal.h>
#import <simd/simd.h>

@class SSKSpriteAnimationSequence;

NS_ASSUME_NONNULL_BEGIN

/**
 * SSK Coordinate Conventions:
 * 
 * IMPORTANT: All coordinates and sizes in SSK are in PIXELS, not points!
 * 
 * - Position, size, and viewport dimensions are all in pixels
 * - On Retina displays (2x, 3x scaling), you must convert points to pixels
 *   by multiplying by window.backingScaleFactor or layer.contentsScale
 * - View origin and Y direction: defined by vertex transform (verify with test sprite)
 * - Rotation direction: defined by vertex transform (verify with test sprite)
 * - UV origin: depends on texture loader/upload. This project assumes top-left for
 *   atlas rect inputs; use setTextureRectInPixelsBottomLeft: if your atlas tool
 *   produces bottom-left origin rects.
 * 
 * Example: Converting points to pixels
 *   CGFloat scale = self.window.backingScaleFactor;  // 1.0, 2.0, or 3.0
 *   [sprite setPositionInPoints:NSMakePoint(100, 200) scale:scale];
 *   // This sets sprite.position to (100*scale, 200*scale) in pixels
 */

/**
 * SSKSprite - A 2D sprite object for Metal-accelerated rendering
 * 
 * SSKSprite represents a single 2D textured quad that can be rendered using the
 * Metal sprite rendering pipeline. It stores all the properties needed to draw
 * a sprite: position, size, rotation, color tinting, opacity, and texture coordinates.
 * 
 * Basic Usage:
 *   1. Create a sprite: SSKSprite *sprite = [[SSKSprite alloc] init];
 *   2. Set properties: sprite.position, sprite.size, sprite.image, etc.
 *   3. Load texture: id<MTLTexture> tex = [sprite textureForDevice:device];
 *   4. Render: Pass sprite to SSKMetalRenderer.drawSprites: or SSKMetalSpritePass.encodeSprites:
 * 
 * Coordinate System:
 *   - All positions and sizes are in PIXELS (not points)
 *   - Position is the anchor point location (default anchor is center 0.5, 0.5)
 *   - Use setPositionInPoints:scale: helper to convert from points to pixels
 * 
 * Texture Coordinates (UV):
 *   - textureOffset and textureSize are normalized (0.0 to 1.0)
 *   - (0,0) = top-left of texture, (1,1) = bottom-right
 *   - Use setTextureRectInPixels: to set from pixel coordinates
 * 
 * Scaling and Flipping:
 *   - scale property: (1.0, 1.0) = normal, (2.0, 2.0) = double size
 *   - Negative scale values flip: (-1.0, 1.0) = horizontal flip
 *   - Use flipX/flipY convenience properties for easier flipping
 * 
 * Animation:
 *   - Assign an SSKSpriteAnimationSequence to sprite.animation
 *   - Call advanceAnimationByTime: each frame to update
 *   - Animation automatically updates textureOffset/textureSize
 * 
 * Thread Safety:
 *   - SSKSprite is NOT thread-safe. Use from a single thread (typically the main thread
 *     or your rendering thread). Multiple threads modifying the same sprite will cause
 *     race conditions.
 * 
 * Performance Notes:
 *   - Textures are cached per device - call invalidateTexture if image changes
 *   - Color tint is cached as float4 for efficient GPU transfer
 *   - For many sprites, consider using SSKMetalSpriteData directly for lower overhead
 */
@interface SSKSprite : NSObject

/**
 * Position of the sprite's anchor point in view coordinates (pixels).
 * 
 * IMPORTANT: This is in PIXELS, not points! On Retina displays, multiply points by
 * window.backingScaleFactor. Use setPositionInPoints:scale: helper for convenience.
 * 
 * The position represents where the anchor point is located. The default anchor is
 * (0.5, 0.5) which means the center of the sprite. So setting position to (100, 200)
 * with default anchor places the sprite's center at pixel coordinates (100, 200).
 * 
 * Example:
 *   sprite.position = NSMakePoint(100, 200);  // Center at (100, 200) pixels
 *   sprite.anchor = NSMakePoint(0, 0);       // Change anchor to bottom-left
 *   // Now position (100, 200) is the bottom-left corner of the sprite
 */
@property (nonatomic) NSPoint position;

/**
 * Size of the sprite in pixels (width, height).
 * 
 * This is the base size before any scaling is applied. The actual rendered size
 * is size * abs(scale). Negative scale values flip the sprite but don't change
 * the rendered size (size always uses absolute value of scale).
 * 
 * Example:
 *   sprite.size = NSMakeSize(100, 50);        // Base size: 100x50 pixels
 *   sprite.scale = CGSizeMake(2.0, 1.0);      // Rendered size: 200x50 pixels
 *   sprite.scale = CGSizeMake(-1.0, 1.0);      // Rendered size: 100x50 pixels (flipped)
 */
@property (nonatomic) NSSize size;

/**
 * Rotation angle in radians.
 * 
 * Rotates the sprite around its anchor point. The direction (clockwise vs
 * counter-clockwise) depends on the coordinate transform used by the vertex shader.
 * 
 * Common values:
 *   - 0.0 = no rotation
 *   - M_PI / 2.0 = 90 degrees
 *   - M_PI = 180 degrees
 *   - M_PI * 2.0 = 360 degrees (full rotation)
 * 
 * The rotation is precomputed as sin/cos on the CPU for efficiency, so changing
 * rotation frequently is fine.
 * 
 * Note: Verify rotation direction with a test sprite before documenting which
 * direction is positive.
 */
@property (nonatomic) CGFloat rotation;

/**
 * Anchor point for rotation and positioning.
 * 
 * The anchor point determines:
 *   1. Where the sprite rotates around
 *   2. What part of the sprite is at the position coordinate
 * 
 * Values are normalized (0.0 to 1.0):
 *   - (0.0, 0.0) = bottom-left corner
 *   - (0.5, 0.5) = center (default)
 *   - (1.0, 1.0) = top-right corner
 *   - (0.0, 1.0) = top-left corner
 *   - (1.0, 0.0) = bottom-right corner
 * 
 * Example:
 *   sprite.anchor = NSMakePoint(0.5, 0.5);  // Center anchor (default)
 *   sprite.position = NSMakePoint(100, 200); // Center of sprite at (100, 200)
 * 
 *   sprite.anchor = NSMakePoint(0, 0);      // Bottom-left anchor
 *   sprite.position = NSMakePoint(100, 200); // Bottom-left corner at (100, 200)
 */
@property (nonatomic) NSPoint anchor;

/**
 * Scale multiplier applied to size. Default is (1.0, 1.0).
 * 
 * The scale property allows you to:
 *   - Make sprites larger or smaller: (2.0, 2.0) = double size, (0.5, 0.5) = half size
 *   - Stretch sprites: (2.0, 1.0) = twice as wide, same height
 *   - Flip sprites: negative values flip the sprite
 * 
 * Flipping:
 *   - scale.width < 0 = horizontal flip (mirror left-right)
 *   - scale.height < 0 = vertical flip (mirror top-bottom)
 *   - Negative scale is the canonical flip mechanism - it's efficient and works
 *     by adjusting UV coordinates on the CPU (no shader branching needed)
 * 
 * Rendered Size:
 *   - The actual rendered size is: size * abs(scale)
 *   - So scale (-1.0, 1.0) renders at normal size but flipped horizontally
 * 
 * Examples:
 *   sprite.scale = CGSizeMake(1.0, 1.0);   // Normal size
 *   sprite.scale = CGSizeMake(2.0, 2.0);   // Double size
 *   sprite.scale = CGSizeMake(-1.0, 1.0);  // Normal size, flipped horizontally
 *   sprite.scale = CGSizeMake(1.0, -1.0); // Normal size, flipped vertically
 *   sprite.scale = CGSizeMake(-2.0, 2.0); // Double size, flipped horizontally
 */
@property (nonatomic) CGSize scale;

/**
 * Convenience property for horizontal flipping.
 * 
 * This is a convenience wrapper around the scale property. Instead of manually
 * negating scale.width, you can use flipX:
 * 
 *   sprite.flipX = YES;   // Same as: sprite.scale = CGSizeMake(-fabs(sprite.scale.width), sprite.scale.height);
 *   sprite.flipX = NO;    // Same as: sprite.scale = CGSizeMake(fabs(sprite.scale.width), sprite.scale.height);
 * 
 * Reading flipX returns YES if scale.width < 0, NO otherwise.
 * 
 * Special case: If scale.width is 0 (sprite is hidden), setting flipX does nothing
 * to preserve the zero scale state.
 * 
 * Example:
 *   sprite.flipX = YES;   // Flip horizontally
 *   BOOL isFlipped = sprite.flipX;  // Check if flipped
 */
@property (nonatomic) BOOL flipX;

/**
 * Convenience property for vertical flipping.
 * 
 * This is a convenience wrapper around the scale property. Instead of manually
 * negating scale.height, you can use flipY:
 * 
 *   sprite.flipY = YES;   // Same as: sprite.scale = CGSizeMake(sprite.scale.width, -fabs(sprite.scale.height));
 *   sprite.flipY = NO;    // Same as: sprite.scale = CGSizeMake(sprite.scale.width, fabs(sprite.scale.height));
 * 
 * Reading flipY returns YES if scale.height < 0, NO otherwise.
 * 
 * Special case: If scale.height is 0 (sprite is hidden), setting flipY does nothing
 * to preserve the zero scale state.
 * 
 * Example:
 *   sprite.flipY = YES;   // Flip vertically
 *   BOOL isFlipped = sprite.flipY;  // Check if flipped
 */
@property (nonatomic) BOOL flipY;

/**
 * Color tint applied to the texture (multiplied with texture color).
 * 
 * The color tint is multiplied with the texture's color values. This allows you
 * to colorize sprites without needing separate texture files for each color.
 * 
 * Color multiplication:
 *   - White (1,1,1) = no tint (texture appears as-is)
 *   - Red (1,0,0) = red tint (texture appears red)
 *   - Gray (0.5,0.5,0.5) = darker (50% brightness)
 *   - Any color = texture is tinted that color
 * 
 * The alpha component of colorTint is multiplied with the sprite's opacity property
 * and the texture's alpha channel to produce the final alpha.
 * 
 * Default is white (no tint). The color is automatically converted to float4
 * and cached for efficient GPU transfer (see colorTintFloat4 property).
 * 
 * Example:
 *   sprite.colorTint = [NSColor redColor];      // Red tint
 *   sprite.colorTint = [NSColor colorWithWhite:0.5 alpha:1.0];  // 50% brightness
 */
@property (nonatomic, strong) NSColor *colorTint;

/**
 * Overall opacity of the sprite (0.0 = transparent, 1.0 = opaque).
 * 
 * Controls the alpha/transparency of the sprite. This is multiplied with:
 *   - The texture's alpha channel
 *   - The colorTint's alpha component
 * 
 * Values:
 *   - 0.0 = completely transparent (invisible)
 *   - 1.0 = fully opaque (default)
 *   - 0.5 = 50% transparent (semi-transparent)
 * 
 * Example:
 *   sprite.opacity = 0.5;  // Make sprite 50% transparent
 *   sprite.opacity = 0.0;  // Hide sprite (but still processes it)
 */
@property (nonatomic) CGFloat opacity;

/**
 * Z-order for depth sorting. Higher values render in front (on top).
 * 
 * When z-sorting is enabled (via sortByZ:YES in encodeSprites: or
 * spriteSortingEnabled on SSKMetalRenderer), sprites are sorted by this value
 * before rendering. Sprites with lower z values are drawn first (behind),
 * sprites with higher z values are drawn last (in front).
 * 
 * Sorting behavior:
 *   - Sprites are sorted ascending by z (lower z first)
 *   - Equal z values maintain original order (stable sort)
 *   - Non-finite values (NaN, infinity) are treated as 0.0
 * 
 * Recommended range: -10000 to +10000 for reliable float precision.
 * 
 * Default is 0.0. All sprites with z=0 will render in the order they appear
 * in the array (when sorting is enabled).
 * 
 * Example:
 *   sprite1.z = -10.0;  // Background layer
 *   sprite2.z = 0.0;    // Middle layer
 *   sprite3.z = 10.0;   // Foreground layer
 *   // When sorted, sprite1 draws first, sprite2 second, sprite3 last (on top)
 */
@property (nonatomic) float z;

/**
 * Source image for the sprite texture.
 * 
 * Setting this property stores the NSImage but does NOT immediately create
 * a Metal texture. The texture is created lazily when you call textureForDevice:.
 * 
 * The image is converted to a Metal texture with:
 *   - RGBA8Unorm pixel format
 *   - Premultiplied alpha (for correct blending)
 *   - Flipped vertically (Metal uses top-left origin, NSImage uses bottom-left)
 * 
 * Texture caching:
 *   - Textures are cached per Metal device
 *   - If you change the image, call invalidateTexture to clear the cache
 *   - The cached texture is available via cachedTexture property
 * 
 * Setting to nil:
 *   - Clears the image
 *   - Does NOT automatically invalidate cached texture (call invalidateTexture)
 *   - Sprite can still be rendered as solid color (if texture is nil in render call)
 * 
 * Example:
 *   sprite.image = [NSImage imageNamed:@"logo"];
 *   id<MTLTexture> tex = [sprite textureForDevice:device];  // Creates texture now
 */
@property (nonatomic, strong, nullable) NSImage *image;

/**
 * Texture coordinates offset for sprite sheets (default: 0,0).
 * 
 * This property, along with textureSize, defines which portion of a texture to use.
 * This is useful for sprite sheets/atlases where multiple sprites are packed into
 * a single texture.
 * 
 * Values are normalized (0.0 to 1.0):
 *   - (0.0, 0.0) = top-left corner of texture
 *   - (0.5, 0.5) = center of texture
 *   - (1.0, 1.0) = bottom-right corner of texture
 * 
 * The textureOffset defines the top-left corner of the region to use.
 * The textureSize defines the width and height of the region.
 * Together they form a rectangle: (offset.x, offset.y) to (offset.x + size.width, offset.y + size.height)
 * 
 * IMPORTANT: These values must be normalized! If you have pixel coordinates, use
 * setTextureRectInPixels:textureSize: helper method instead.
 * 
 * Example (using 4x4 grid sprite sheet, selecting frame at row 1, column 2):
 *   CGFloat frameWidth = 1.0 / 4.0;   // 0.25 (normalized)
 *   CGFloat frameHeight = 1.0 / 4.0; // 0.25 (normalized)
 *   sprite.textureOffset = NSMakePoint(2 * frameWidth, 1 * frameHeight);  // (0.5, 0.25)
 *   sprite.textureSize = NSMakeSize(frameWidth, frameHeight);              // (0.25, 0.25)
 * 
 * Or use the helper:
 *   CGRect frameRect = CGRectMake(128, 64, 64, 64);  // Pixel coordinates
 *   CGSize texSize = CGSizeMake(256, 256);           // Full texture size
 *   [sprite setTextureRectInPixels:frameRect textureSize:texSize];
 */
@property (nonatomic) NSPoint textureOffset;

/**
 * Texture coordinates size for sprite sheets (default: 1,1).
 * 
 * This property, along with textureOffset, defines which portion of a texture to use.
 * This is useful for sprite sheets/atlases where multiple sprites are packed into
 * a single texture.
 * 
 * Values are normalized (0.0 to 1.0):
 *   - (1.0, 1.0) = use entire texture (default)
 *   - (0.5, 0.5) = use a 50% x 50% region
 *   - (0.25, 0.25) = use a 25% x 25% region
 * 
 * The textureOffset defines the top-left corner, textureSize defines the width/height.
 * Together: region = (offset.x, offset.y) to (offset.x + size.width, offset.y + size.height)
 * 
 * IMPORTANT: These values must be normalized! If you have pixel coordinates, use
 * setTextureRectInPixels:textureSize: helper method instead.
 * 
 * Note: When flipping is applied (negative scale), the render pass automatically
 * adjusts these UV coordinates, so you don't need to modify them manually for flipping.
 * 
 * Example: See textureOffset documentation above for complete example.
 */
@property (nonatomic) NSSize textureSize;

/// Cached Metal texture. Created lazily from image when needed.
@property (nonatomic, strong, nullable, readonly) id<MTLTexture> cachedTexture;

/// Cached color tint as float4 for efficient GPU transfer.
/// Updated automatically when colorTint changes.
@property (nonatomic, readonly) simd_float4 colorTintFloat4;

#pragma mark - Animation

/// Current animation sequence (nil = static sprite).
/// When set, textureOffset/textureSize are managed by advanceAnimationByTime:.
/// Setting this resets animationTime to 0, animationPlaying to YES, animationRate to 1.0.
@property (nonatomic, strong, nullable) SSKSpriteAnimationSequence *animation;

/// Current playback time in seconds. Reset to 0 on animation change.
@property (nonatomic) NSTimeInterval animationTime;

/// Playback speed multiplier. Default 1.0. Negative = reverse.
@property (nonatomic) CGFloat animationRate;

/// Whether animation is playing. Default YES when animation is set.
/// When LoopModeOnce finishes, this is automatically set to NO.
@property (nonatomic) BOOL animationPlaying;

/// Advances animation by delta time. Updates textureOffset/textureSize.
/// No-op if animation is nil or animationPlaying is NO.
/// Sets animationPlaying = NO when LoopModeOnce finishes.
/// @param dt Time delta in seconds
- (void)advanceAnimationByTime:(NSTimeInterval)dt;

/// Resets animation to time 0 and starts playing.
- (void)resetAnimation;

/**
 * Creates a sprite with the given image.
 * 
 * Convenience factory method that creates a sprite and sets its image property.
 * The sprite's size defaults to the image size (if image is provided) or 100x100.
 * 
 * @param image The NSImage to use, or nil for a sprite without an image
 * @return A new sprite instance
 * 
 * Example:
 *   SSKSprite *sprite = [SSKSprite spriteWithImage:[NSImage imageNamed:@"logo"]];
 */
+ (instancetype)spriteWithImage:(nullable NSImage *)image;

/**
 * Creates a sprite with position and size.
 * 
 * Convenience factory method that creates a sprite and sets its position and size.
 * The sprite has no image initially (can be set later).
 * 
 * @param position Initial position in pixels
 * @param size Initial size in pixels
 * @return A new sprite instance
 * 
 * Example:
 *   SSKSprite *sprite = [SSKSprite spriteWithPosition:NSMakePoint(100, 200)
 *                                                  size:NSMakeSize(64, 64)];
 */
+ (instancetype)spriteWithPosition:(NSPoint)position size:(NSSize)size;

/**
 * Initializes a sprite with the given image.
 * 
 * Designated initializer. Creates a sprite with default values:
 *   - position: (0, 0)
 *   - size: image pixel dimensions (if image provided) or (100, 100) pixels
 *   - rotation: 0.0
 *   - anchor: (0.5, 0.5) - center
 *   - scale: (1.0, 1.0)
 *   - colorTint: white
 *   - opacity: 1.0
 *   - z: 0.0
 *   - textureOffset: (0, 0)
 *   - textureSize: (1, 1)
 *   - animation: nil
 * 
 * Default Size Behavior:
 *   - If image is provided: size is set to the image's PIXEL dimensions
 *     (not point size, which may differ on Retina displays)
 *   - If image is nil: size defaults to (100, 100) pixels
 *   - You can always override size after initialization
 * 
 * @param image The NSImage to use, or nil for a sprite without an image
 * @return An initialized sprite instance
 */
- (instancetype)initWithImage:(nullable NSImage *)image;

/**
 * Creates or returns the cached Metal texture for the sprite's image.
 * 
 * This method creates a Metal texture from the sprite's image property. The texture
 * is cached per Metal device, so subsequent calls with the same device return the
 * cached texture (unless invalidateTexture was called).
 * 
 * Texture creation:
 *   - Converts NSImage to Metal texture format (RGBA8Unorm)
 *   - Applies premultiplied alpha for correct blending
 *   - Flips vertically (Metal uses top-left origin)
 *   - Caches the result for reuse
 * 
 * Returns nil if:
 *   - No image is set (sprite.image is nil)
 *   - Texture creation fails (out of memory, invalid image data, etc.)
 * 
 * @param device The Metal device to create the texture for
 * @return The Metal texture, or nil if creation fails
 * 
 * Example:
 *   id<MTLDevice> device = MTLCreateSystemDefaultDevice();
 *   id<MTLTexture> tex = [sprite textureForDevice:device];
 *   if (tex) {
 *       // Use texture for rendering
 *   }
 */
- (nullable id<MTLTexture>)textureForDevice:(id<MTLDevice>)device;

/**
 * Invalidates the cached texture (call when image changes).
 * 
 * When you change the sprite's image property, the old cached texture is still
 * valid until you call this method. Call invalidateTexture to force the next
 * textureForDevice: call to create a new texture from the new image.
 * 
 * This is automatically called when you set the image property, but you may
 * want to call it manually if you modify the NSImage object directly.
 * 
 * Example:
 *   sprite.image = newImage;  // Automatically invalidates cache
 *   // Or if you modify the image directly:
 *   [sprite.image lockFocus];
 *   // ... draw into image ...
 *   [sprite.image unlockFocus];
 *   [sprite invalidateTexture];  // Force texture refresh
 */
- (void)invalidateTexture;

#pragma mark - Coordinate Helpers

/**
 * Sets position from point coordinates, converting to pixels.
 * 
 * This helper method converts from Cocoa's point-based coordinate system to
 * SSK's pixel-based coordinate system. Use this when you have point coordinates
 * (e.g., from NSView.bounds or mouse events) and need to set sprite position.
 * 
 * On Retina displays, points are smaller than pixels:
 *   - Non-Retina: 1 point = 1 pixel (scale = 1.0)
 *   - Retina: 1 point = 2 pixels (scale = 2.0)
 *   - Retina HD: 1 point = 3 pixels (scale = 3.0)
 * 
 * @param point Position in points (Cocoa coordinate system)
 * @param backingScaleFactor The backing scale factor, typically from:
 *        - window.backingScaleFactor
 *        - layer.contentsScale
 *        - NSScreen.backingScaleFactor
 * 
 * Example:
 *   CGFloat scale = self.window.backingScaleFactor;
 *   [sprite setPositionInPoints:NSMakePoint(100, 200) scale:scale];
 *   // On Retina (scale=2.0), this sets position to (200, 400) pixels
 * 
 * Example in render loop:
 *   - (void)renderMetalFrame:(SSKMetalRenderer *)renderer deltaTime:(NSTimeInterval)dt {
 *       NSPoint pointPos = NSMakePoint(self.logicX, self.logicY);  // Your logic in points
 *       CGFloat scale = self.window.backingScaleFactor;
 *       [self.sprite setPositionInPoints:pointPos scale:scale];
 *   }
 */
- (void)setPositionInPoints:(NSPoint)point scale:(CGFloat)backingScaleFactor;

/**
 * Sets size from point dimensions, converting to pixels.
 *
 * This helper method converts from Cocoa's point-based sizes to SSK's pixel-based
 * sizes. Use this when you have size values in points and need to set sprite size.
 *
 * On Retina displays, points are smaller than pixels:
 *   - Non-Retina: 1 point = 1 pixel (scale = 1.0)
 *   - Retina: 1 point = 2 pixels (scale = 2.0)
 *
 * @param size Size in points (Cocoa coordinate system)
 * @param backingScaleFactor The backing scale factor (window.backingScaleFactor)
 *
 * Example:
 *   CGFloat scale = self.window.backingScaleFactor;
 *   [sprite setSizeInPoints:NSMakeSize(180, 100) scale:scale];
 *   // On Retina (scale=2.0), this sets size to (360, 200) pixels
 */
- (void)setSizeInPoints:(NSSize)size scale:(CGFloat)backingScaleFactor;

/**
 * Sets texture region from pixel rect, normalizing to UV space.
 * 
 * This helper converts pixel coordinates (from a sprite sheet/atlas) into
 * normalized UV coordinates (0.0 to 1.0) that SSKSprite uses internally.
 * 
 * Assumes top-left origin for rect coordinates (Metal/typical convention):
 *   - rect.origin is the top-left corner in pixel coordinates
 *   - rect.size is the width/height in pixels
 * 
 * The method automatically:
 *   1. Normalizes the rect to 0.0-1.0 range based on textureSize
 *   2. Sets textureOffset and textureSize properties
 *   3. Validates the values are within bounds (in DEBUG builds)
 * 
 * @param rect Frame rectangle in texture pixel coordinates (top-left origin)
 * @param texSize Full texture size in pixels (for normalization)
 * 
 * Example (4x4 grid sprite sheet, selecting frame at row 1, column 2):
 *   CGSize textureSize = CGSizeMake(256, 256);  // Full texture is 256x256 pixels
 *   CGFloat frameSize = 64;  // Each frame is 64x64 pixels
 *   CGRect frameRect = CGRectMake(2 * frameSize, 1 * frameSize, frameSize, frameSize);
 *   // frameRect = (128, 64, 64, 64) - column 2, row 1
 *   [sprite setTextureRectInPixels:frameRect textureSize:textureSize];
 *   // This sets textureOffset to (0.5, 0.25) and textureSize to (0.25, 0.25)
 */
- (void)setTextureRectInPixels:(CGRect)rect textureSize:(CGSize)texSize;

/**
 * Sets texture region from pixel rect with bottom-left origin (OpenGL convention).
 * 
 * This is the same as setTextureRectInPixels:textureSize: but assumes the rect
 * coordinates use bottom-left origin instead of top-left. Use this if your atlas
 * tool or texture loader uses OpenGL-style bottom-left origin coordinates.
 * 
 * The method automatically converts from bottom-left to top-left origin before
 * normalizing to UV coordinates.
 * 
 * @param rect Frame rectangle in texture pixel coordinates (bottom-left origin)
 * @param texSize Full texture size in pixels (for normalization)
 * 
 * Example:
 *   // Your atlas tool gives you bottom-left origin coordinates
 *   CGRect frameRect = CGRectMake(128, 64, 64, 64);  // Bottom-left at (128, 64)
 *   CGSize textureSize = CGSizeMake(256, 256);
 *   [sprite setTextureRectInPixelsBottomLeft:frameRect textureSize:textureSize];
 */
- (void)setTextureRectInPixelsBottomLeft:(CGRect)rect textureSize:(CGSize)texSize;

@end

NS_ASSUME_NONNULL_END

