/**
 * SSKSprite Implementation
 * 
 * This file implements the SSKSprite class, which represents a single 2D sprite
 * for Metal-accelerated rendering. Key implementation details:
 * 
 * Coordinate System:
 *   - All positions and sizes are in PIXELS (not points)
 *   - Use setPositionInPoints:scale: to convert from points to pixels
 *   - Texture coordinates (UV) are normalized (0.0-1.0)
 * 
 * Scale and Flipping:
 *   - Scale property: (1.0, 1.0) = normal, negative values flip
 *   - Flip is implemented via UV coordinate adjustment in render pass
 *   - Zero scale is preserved (sprite is hidden, flip doesn't change it)
 * 
 * Texture Management:
 *   - Textures are cached per Metal device
 *   - Call invalidateTexture when image changes
 *   - Color tint is cached as float4 for efficient GPU transfer
 * 
 * Animation:
 *   - Animation owns textureOffset/textureSize while active
 *   - Call advanceAnimationByTime: each frame to update
 *   - Animation automatically stops when LoopModeOnce finishes
 * 
 * Thread Safety:
 *   - NOT thread-safe - use from a single thread
 */

#import "SSKSprite.h"
#import "SSKSpriteAnimationSequence.h"
#import <math.h>  // isfinite, fabs

// Epsilon for UV bounds checking (used in DEBUG assertions only)
// Small value to account for floating-point rounding errors when checking
// if textureOffset + textureSize exceeds 1.0
#if DEBUG
static const CGFloat kSSKUV_Epsilon = 1e-6;
#endif

@interface SSKSprite ()
@property (nonatomic, strong, nullable, readwrite) id<MTLTexture> cachedTexture;
@property (nonatomic, weak, nullable) id<MTLDevice> cachedDevice;
@property (nonatomic, readwrite) simd_float4 colorTintFloat4;
@property (nonatomic) BOOL colorTintDirty;
@end

@implementation SSKSprite

+ (instancetype)spriteWithImage:(NSImage *)image {
    return [[self alloc] initWithImage:image];
}

+ (instancetype)spriteWithPosition:(NSPoint)position size:(NSSize)size {
    SSKSprite *sprite = [[self alloc] initWithImage:nil];
    sprite.position = position;
    sprite.size = size;
    return sprite;
}

- (instancetype)init {
    return [self initWithImage:nil];
}

/**
 * Returns the pixel dimensions of an NSImage.
 * 
 * NSImage.size returns the "logical" size in points, which may differ from the
 * actual pixel dimensions on Retina displays or when the image has DPI metadata.
 * 
 * This method inspects the image representations to find the actual pixel size.
 * Falls back to image.size if no bitmap representation is found.
 * 
 * @param image The image to measure
 * @return The pixel dimensions (width x height in pixels)
 */
+ (NSSize)pixelSizeOfImage:(NSImage *)image {
    if (!image) {
        return NSMakeSize(100.0, 100.0);  // Default size
    }
    
    // Try to get pixel dimensions from bitmap representation
    for (NSImageRep *rep in image.representations) {
        if ([rep isKindOfClass:[NSBitmapImageRep class]]) {
            // Bitmap rep has actual pixel dimensions
            return NSMakeSize(rep.pixelsWide, rep.pixelsHigh);
        }
    }
    
    // For vector images or if no bitmap rep, try the first representation
    NSImageRep *firstRep = image.representations.firstObject;
    if (firstRep && firstRep.pixelsWide > 0 && firstRep.pixelsHigh > 0) {
        return NSMakeSize(firstRep.pixelsWide, firstRep.pixelsHigh);
    }
    
    // Fallback: use image.size (points) - less accurate but better than nothing
    // This can happen for newly created NSImages that haven't been drawn yet
    return image.size;
}

- (instancetype)initWithImage:(NSImage *)image {
    if ((self = [super init])) {
        _image = image;
        _position = NSZeroPoint;
        // Use pixel dimensions, not point dimensions, for consistency with pixel coordinate system
        _size = [SSKSprite pixelSizeOfImage:image];
        _rotation = 0.0;
        _anchor = NSMakePoint(0.5, 0.5);  // Center anchor by default
        _scale = CGSizeMake(1.0, 1.0);    // No scaling by default
        _colorTint = [NSColor whiteColor];
        _colorTintFloat4 = simd_make_float4(1.0f, 1.0f, 1.0f, 1.0f);
        _colorTintDirty = NO;
        _opacity = 1.0;
        _z = 0.0f;
        _textureOffset = NSZeroPoint;
        _textureSize = NSMakeSize(1.0, 1.0);
        
        // Animation defaults
        _animation = nil;
        _animationTime = 0;
        _animationRate = 1.0;
        _animationPlaying = NO;
    }
    return self;
}

- (void)setImage:(NSImage *)image {
    if (_image != image) {
        _image = image;
        [self invalidateTexture];
    }
}

- (void)setColorTint:(NSColor *)colorTint {
    if (_colorTint != colorTint) {
        _colorTint = colorTint;
        _colorTintDirty = YES;
    }
}

#pragma mark - Scale and Flip

- (void)setScale:(CGSize)scale {
#if DEBUG
    NSAssert(isfinite(scale.width) && isfinite(scale.height),
             @"scale contains NaN or infinity");
#endif
    _scale = scale;
}

// Use ivars directly to avoid KVO/override surprises
// Note: If scale component is 0, flip setters do nothing (sprite is hidden).
- (BOOL)flipX {
    return _scale.width < 0;
}

- (void)setFlipX:(BOOL)flipX {
    // Get absolute value of current scale (preserves magnitude)
    CGFloat absW = fabs(_scale.width);
    
    // Special case: If scale is 0, don't change it
    // This preserves the "hidden sprite" state (scale 0 = sprite is invisible)
    // If we changed it to 1 or -1, we'd accidentally make the sprite visible
    if (absW == 0) return;  // Preserve zero scale (sprite is hidden)
    
    // Apply flip by negating the scale if flipX is YES, keeping it positive if NO
    // This preserves the scale magnitude (e.g., 2.0 becomes -2.0, not -1.0)
    _scale.width = flipX ? -absW : absW;
}

- (BOOL)flipY {
    return _scale.height < 0;
}

- (void)setFlipY:(BOOL)flipY {
    // Get absolute value of current scale (preserves magnitude)
    CGFloat absH = fabs(_scale.height);
    
    // Special case: If scale is 0, don't change it
    // This preserves the "hidden sprite" state (scale 0 = sprite is invisible)
    if (absH == 0) return;  // Preserve zero scale (sprite is hidden)
    
    // Apply flip by negating the scale if flipY is YES, keeping it positive if NO
    _scale.height = flipY ? -absH : absH;
}

#pragma mark - Texture Coordinates

- (void)setTextureOffset:(NSPoint)textureOffset {
#if DEBUG
    // Validate that values are finite (not NaN or infinity)
    // Non-finite values would cause rendering artifacts or crashes
    NSAssert(isfinite(textureOffset.x) && isfinite(textureOffset.y),
             @"textureOffset contains NaN or infinity");
    
    // Validate that values are in normalized range (0.0 to 1.0)
    // UV coordinates must be normalized for the shader to work correctly
    // Use epsilon for floating-point tolerance on both bounds
    NSAssert(textureOffset.x >= -kSSKUV_Epsilon && textureOffset.x <= 1.0 + kSSKUV_Epsilon &&
             textureOffset.y >= -kSSKUV_Epsilon && textureOffset.y <= 1.0 + kSSKUV_Epsilon,
             @"textureOffset must be normalized (0-1), got (%g, %g)", textureOffset.x, textureOffset.y);
#endif
    _textureOffset = textureOffset;
#if DEBUG
    // If size is already set, ensure the combined offset + size doesn't exceed 1.0
    // This catches common mistakes like:
    //   - Setting offset to (0.8, 0.8) with size (0.3, 0.3) = exceeds 1.0
    //   - Atlas frame coordinates that go outside the texture bounds
    //
    // We use a small epsilon to account for floating-point rounding errors
    NSAssert(_textureOffset.x + _textureSize.width <= 1.0 + kSSKUV_Epsilon &&
             _textureOffset.y + _textureSize.height <= 1.0 + kSSKUV_Epsilon,
             @"textureOffset + textureSize exceeds 1.0 (atlas bounds)");
#endif
}

- (void)setTextureSize:(NSSize)textureSize {
#if DEBUG
    // Validate that values are finite (not NaN or infinity)
    NSAssert(isfinite(textureSize.width) && isfinite(textureSize.height),
             @"textureSize contains NaN or infinity");
    
    // Size must be positive and normalized (0-1)
    // Note: Negative size is NOT used here - negative scale values flip the sprite
    // by adjusting UV coordinates in the render pass, not by making textureSize negative.
    // The textureSize stored here is always positive and normalized.
    // Use epsilon for floating-point tolerance on both bounds
    NSAssert(textureSize.width >= -kSSKUV_Epsilon && textureSize.width <= 1.0 + kSSKUV_Epsilon &&
             textureSize.height >= -kSSKUV_Epsilon && textureSize.height <= 1.0 + kSSKUV_Epsilon,
             @"textureSize must be normalized (0-1), got (%g, %g)", textureSize.width, textureSize.height);
    
    // Catch atlas mistakes: offset + size should not exceed 1.0
    // This ensures the sprite frame fits within the texture bounds
    // Example error: offset=(0.8, 0.8), size=(0.3, 0.3) = goes to (1.1, 1.1) = invalid
    NSAssert(_textureOffset.x + textureSize.width <= 1.0 + kSSKUV_Epsilon &&
             _textureOffset.y + textureSize.height <= 1.0 + kSSKUV_Epsilon,
             @"textureOffset + textureSize exceeds 1.0 (atlas bounds)");
#endif
    _textureSize = textureSize;
}

- (simd_float4)colorTintFloat4 {
    if (_colorTintDirty) {
        [self updateCachedColorTint];
        _colorTintDirty = NO;
    }
    return _colorTintFloat4;
}

- (void)updateCachedColorTint {
    NSColor *color = [_colorTint colorUsingColorSpace:[NSColorSpace extendedSRGBColorSpace]];
    if (color) {
        _colorTintFloat4 = simd_make_float4(
            (float)color.redComponent,
            (float)color.greenComponent,
            (float)color.blueComponent,
            (float)color.alphaComponent
        );
    } else {
        // Fallback to white if color conversion fails
        // This can happen with unusual color spaces or catalog colors
#if DEBUG
        NSLog(@"SSKSprite: colorTint conversion to sRGB failed for %@, falling back to white", _colorTint);
#endif
        _colorTintFloat4 = simd_make_float4(1.0f, 1.0f, 1.0f, 1.0f);
    }
}

- (void)invalidateTexture {
    self.cachedTexture = nil;
    self.cachedDevice = nil;
}

- (id<MTLTexture>)textureForDevice:(id<MTLDevice>)device {
    if (!device) { return nil; }
    if (!self.image) { return nil; }
    
    // Return cached texture if device matches
    if (self.cachedTexture && self.cachedDevice == device) {
        return self.cachedTexture;
    }
    
    // Create texture from image
    id<MTLTexture> texture = [self createTextureFromImage:self.image device:device];
    if (texture) {
        self.cachedTexture = texture;
        self.cachedDevice = device;
    }
    
    return texture;
}

- (id<MTLTexture>)createTextureFromImage:(NSImage *)image device:(id<MTLDevice>)device {
    if (!image || !device) { return nil; }
    
    // Get CGImage from NSImage
    CGImageRef cgImage = [image CGImageForProposedRect:NULL context:nil hints:nil];
    if (!cgImage) { return nil; }
    
    NSUInteger width = CGImageGetWidth(cgImage);
    NSUInteger height = CGImageGetHeight(cgImage);
    if (width == 0 || height == 0) { return nil; }
    
    // Create texture descriptor
    MTLTextureDescriptor *descriptor = [MTLTextureDescriptor
        texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm
                                     width:width
                                    height:height
                                 mipmapped:NO];
    descriptor.usage = MTLTextureUsageShaderRead;
    descriptor.storageMode = MTLStorageModeShared;
    
    id<MTLTexture> texture = [device newTextureWithDescriptor:descriptor];
    if (!texture) { return nil; }
    
    // Copy image data to texture
    CGColorSpaceRef colorSpace = CGColorSpaceCreateDeviceRGB();
    if (!colorSpace) { return nil; }
    
    size_t bytesPerPixel = 4;
    size_t bytesPerRow = bytesPerPixel * width;
    size_t bitsPerComponent = 8;
    
    void *imageData = calloc(height, bytesPerRow);
    if (!imageData) {
        CGColorSpaceRelease(colorSpace);
        return nil;
    }
    
    CGContextRef context = CGBitmapContextCreate(imageData, width, height,
                                                 bitsPerComponent, bytesPerRow,
                                                 colorSpace,
                                                 kCGImageAlphaPremultipliedLast | kCGBitmapByteOrder32Big);
    CGColorSpaceRelease(colorSpace);
    
    if (!context) {
        free(imageData);
        return nil;
    }
    
    // Flip vertically for Metal's coordinate system (origin at top-left)
    CGContextTranslateCTM(context, 0, height);
    CGContextScaleCTM(context, 1.0, -1.0);
    
    // Draw image into context
    CGContextDrawImage(context, CGRectMake(0, 0, width, height), cgImage);
    CGContextRelease(context);
    
    // Copy to texture
    MTLRegion region = MTLRegionMake2D(0, 0, width, height);
    [texture replaceRegion:region mipmapLevel:0 withBytes:imageData bytesPerRow:bytesPerRow];
    
    free(imageData);
    
    return texture;
}

#pragma mark - Coordinate Helpers

- (void)setPositionInPoints:(NSPoint)point scale:(CGFloat)backingScaleFactor {
    // Validate scale factor - must be positive and finite
    // Zero, negative, NaN, or infinity would produce incorrect positions
    if (!isfinite(backingScaleFactor) || backingScaleFactor <= 0) {
        NSAssert(NO, @"setPositionInPoints: invalid backingScaleFactor (%g) - must be positive and finite",
                 backingScaleFactor);
        // Fallback: use scale of 1.0 to avoid NaN/infinity in position
        backingScaleFactor = 1.0;
    }
    
    self.position = NSMakePoint(point.x * backingScaleFactor,
                                point.y * backingScaleFactor);
}

- (void)setTextureRectInPixels:(CGRect)rect textureSize:(CGSize)texSize {
    // Guard against division by zero - invalid texture size
    // If texSize is zero or negative, log in debug and set to full texture (0,0)-(1,1)
    if (texSize.width <= 0 || texSize.height <= 0) {
#if DEBUG
        NSLog(@"SSKSprite: setTextureRectInPixels called with invalid texture size (%g x %g) - must be positive. Falling back to full texture.",
              texSize.width, texSize.height);
#endif
        // Fallback: use full texture to avoid NaN/inf
        _textureOffset = NSMakePoint(0, 0);
        _textureSize = NSMakeSize(1, 1);
        return;
    }
    
    self.textureOffset = NSMakePoint(rect.origin.x / texSize.width,
                                     rect.origin.y / texSize.height);
    self.textureSize = NSMakeSize(rect.size.width / texSize.width,
                                  rect.size.height / texSize.height);
}

- (void)setTextureRectInPixelsBottomLeft:(CGRect)rect textureSize:(CGSize)texSize {
    // Guard against division by zero - invalid texture size
    // If texSize is zero or negative, log in debug and set to full texture (0,0)-(1,1)
    if (texSize.width <= 0 || texSize.height <= 0) {
#if DEBUG
        NSLog(@"SSKSprite: setTextureRectInPixelsBottomLeft called with invalid texture size (%g x %g) - must be positive. Falling back to full texture.",
              texSize.width, texSize.height);
#endif
        // Fallback: use full texture to avoid NaN/inf
        _textureOffset = NSMakePoint(0, 0);
        _textureSize = NSMakeSize(1, 1);
        return;
    }
    
    // Convert pixel coordinates to normalized UV coordinates (bottom-left origin)
    //
    // This is the same as setTextureRectInPixels:textureSize: but assumes the rect
    // coordinates use bottom-left origin (OpenGL convention) instead of top-left.
    //
    // The conversion:
    //   - X coordinate: same as top-left (rect.origin.x / texSize.width)
    //   - Y coordinate: flipped (texSize.height - CGRectGetMaxY(rect)) / texSize.height
    //
    // Why flip Y? Because:
    //   - Bottom-left origin: Y=0 is at bottom, Y increases upward
    //   - Top-left origin (UV): Y=0 is at top, Y increases downward
    //   - So we need to flip: v = (texHeight - rectMaxY) / texHeight
    //
    // Example: 256x256 texture, frame at bottom-left (128, 64) with size (64, 64)
    //   In bottom-left coords: rect = (128, 64, 64, 64), maxY = 128
    //   In top-left UV coords: v = (256 - 128) / 256 = 0.5
    //   So textureOffset = (0.5, 0.5) in normalized UV space
    CGFloat v = (texSize.height - CGRectGetMaxY(rect)) / texSize.height;
    self.textureOffset = NSMakePoint(rect.origin.x / texSize.width, v);
    self.textureSize = NSMakeSize(rect.size.width / texSize.width,
                                  rect.size.height / texSize.height);
}

#pragma mark - Animation

- (void)setAnimation:(SSKSpriteAnimationSequence *)animation {
    _animation = animation;
    _animationTime = 0;
    _animationRate = 1.0;
    _animationPlaying = (animation != nil);
    
    // Apply first frame immediately if animation exists
    if (animation) {
        BOOL finished = NO;
        SSKAnimationFrame frame = [animation frameForTime:0 finished:&finished];
        _textureOffset = NSMakePoint(frame.textureOffset.x, frame.textureOffset.y);
        _textureSize = NSMakeSize(frame.textureSize.width, frame.textureSize.height);
    }
}

- (void)advanceAnimationByTime:(NSTimeInterval)dt {
    // Early exit if animation is not active
    // This is a no-op if:
    //   - No animation sequence is assigned (sprite is static)
    //   - Animation is paused (animationPlaying is NO)
    if (!_animation || !_animationPlaying) {
        return;
    }
    
    // Advance animation time by delta time, scaled by animation rate
    // Positive rate = forward, negative rate = reverse
    // Rate > 1.0 = faster, rate < 1.0 = slower
    _animationTime += dt * _animationRate;
    
    // Normalize time periodically to prevent floating-point precision loss
    // After hours of runtime, large time values cause fmod() precision issues.
    // Normalize when time exceeds 1000 cycles (arbitrary but safe threshold).
    // This keeps time small while preserving animation state.
    NSTimeInterval totalDur = _animation.totalDuration;
    if (totalDur > 0 && fabs(_animationTime) > totalDur * 1000.0) {
        _animationTime = fmod(_animationTime, totalDur);
        if (_animationTime < 0) _animationTime += totalDur;
    }
    
    // Query the animation sequence for the current frame based on time
    // The sequence handles time wrapping based on loop mode (Loop, PingPong, Once)
    BOOL finished = NO;
    SSKAnimationFrame frame = [_animation frameForTime:_animationTime finished:&finished];
    
    // Update texture coordinates (animation owns these while active)
    // 
    // IMPORTANT: While an animation is assigned, the animation system controls
    // textureOffset and textureSize. You should NOT manually set these properties
    // while animation is active - they will be overwritten each frame.
    //
    // If you need to manually control UV coordinates, set animation to nil first.
    _textureOffset = NSMakePoint(frame.textureOffset.x, frame.textureOffset.y);
    _textureSize = NSMakeSize(frame.textureSize.width, frame.textureSize.height);
    
    // Stop if finished (LoopModeOnce)
    // When a "play once" animation completes, automatically pause it
    // The sprite remains on the last frame
    if (finished && _animation.loopMode == SSKAnimationLoopModeOnce) {
        _animationPlaying = NO;
    }
}

- (void)resetAnimation {
    _animationTime = 0;
    _animationPlaying = (_animation != nil);
    
    // Apply first frame
    if (_animation) {
        BOOL finished = NO;
        SSKAnimationFrame frame = [_animation frameForTime:0 finished:&finished];
        _textureOffset = NSMakePoint(frame.textureOffset.x, frame.textureOffset.y);
        _textureSize = NSMakeSize(frame.textureSize.width, frame.textureSize.height);
    }
}

@end

