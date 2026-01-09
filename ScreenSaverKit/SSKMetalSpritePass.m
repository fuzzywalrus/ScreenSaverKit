/**
 * SSKMetalSpritePass Implementation
 * 
 * This file implements the Metal render pass for 2D sprite rendering. It handles:
 * 
 * Rendering Pipeline:
 *   1. Viewport culling (optional): Skip off-screen sprites for performance
 *   2. Z-sorting (optional): Sort sprites back-to-front for correct depth
 *   3. Instance data building: Convert SSKSprite objects to SSKMetalSpriteData structs
 *   4. UV flip application: Adjust UV coordinates for negative scale (flipping)
 *   5. Metal encoding: Encode instanced draw commands to GPU
 * 
 * Performance Optimizations:
 *   - Instanced rendering: All sprites in a single draw call
 *   - Precomputed sin/cos: Rotation calculated on CPU, not in shader
 *   - Cached color tint: NSColor converted to float4 once, reused
 *   - Reusable buffers: _visibleIndices buffer reused across frames
 *   - Optional culling: Skip off-screen sprites before sorting/rendering
 * 
 * Flip Implementation:
 *   - Flipping uses UV affine mapping (no shader branches)
 *   - Negative scale adjusts textureOffset and negates textureSize
 *   - Shader doesn't need to know about flipping - it just uses UVs as-is
 * 
 * Thread Safety:
 *   - NOT thread-safe - use from a single thread (typically rendering thread)
 *   - Buffers are reused, so concurrent calls would cause race conditions
 */

#import "SSKMetalSpritePass.h"

#import <simd/simd.h>
#import <Foundation/Foundation.h>
#include <stdlib.h>   // qsort_b, malloc, free, realloc
#include <math.h>     // isfinite

#import "SSKDiagnostics.h"
#import "SSKSprite.h"

@interface SSKMetalSpritePass ()
@property (nonatomic, strong) id<MTLDevice> device;
@property (nonatomic, strong) id<MTLRenderPipelineState> alphaPipeline;
@property (nonatomic, strong) id<MTLRenderPipelineState> additivePipeline;
@property (nonatomic, strong) id<MTLRenderPipelineState> alphaSolidPipeline;
@property (nonatomic, strong) id<MTLRenderPipelineState> additiveSolidPipeline;
@property (nonatomic, strong) id<MTLBuffer> quadVertexBuffer;
@property (nonatomic, strong) id<MTLBuffer> instanceBuffer;
@property (nonatomic, strong) id<MTLSamplerState> samplerState;
@property (nonatomic) NSUInteger instanceBufferCapacity;
@property (nonatomic) SSKSpriteSamplerFilter currentSamplerFilter;  // Tracks last-built filter
@end

@implementation SSKMetalSpritePass {
    NSUInteger *_visibleIndices;
    NSUInteger _visibleIndicesCapacity;
}

@synthesize samplerFilter = _samplerFilter;

- (NSString *)passName {
    return @"SpritePass";
}

- (void)dealloc {
    free(_visibleIndices);
}

#pragma mark - Culling and Sorting

/**
 * Ensures _visibleIndices buffer can hold at least `count` entries.
 * 
 * This method grows the internal buffer as needed using a doubling strategy for
 * efficiency. The buffer is reused across frames to avoid frequent allocations.
 * 
 * Allocation strategy:
 *   - Starts at 64 entries if buffer is empty
 *   - Doubles capacity each time until it's large enough
 *   - Protects against integer overflow
 *   - Uses realloc to preserve existing data when growing
 * 
 * @param count Minimum number of entries needed
 * @return YES if buffer is now large enough, NO on allocation failure
 * 
 * Thread safety: NOT thread-safe. Call from a single thread.
 */
- (BOOL)ensureVisibleIndicesCapacity:(NSUInteger)count {
    if (count <= _visibleIndicesCapacity) return YES;
    
    NSUInteger newCap = _visibleIndicesCapacity ? _visibleIndicesCapacity : 64;
    while (newCap < count) {
        if (newCap > NSUIntegerMax / 2) return NO;  // Overflow protection
        newCap *= 2;
    }
    
    void *newBuf = realloc(_visibleIndices, newCap * sizeof(NSUInteger));
    if (!newBuf) return NO;  // Out of memory
    
    _visibleIndices = (NSUInteger *)newBuf;
    _visibleIndicesCapacity = newCap;
    return YES;
}

/**
 * Returns YES if sprite is potentially visible in viewport.
 * 
 * This method performs viewport culling - it determines if a sprite might be
 * visible on screen. Sprites that are completely outside the viewport are culled
 * (skipped) to improve performance.
 * 
 * Culling algorithm:
 *   1. Calculate the sprite's actual size (size * abs(scale))
 *   2. Compute distances from anchor point to each of the 4 corners
 *   3. Find the maximum distance (furthest corner from anchor)
 *   4. Use that as the bounding circle radius
 *   5. Test if the bounding circle intersects the viewport
 * 
 * Why a bounding circle?
 *   - Works correctly for any rotation angle (rotated rectangle fits in circle)
 *   - Works correctly for any anchor point (not just center)
 *   - Fast to compute (just 4 hypot calculations)
 *   - Conservative (may include some off-screen sprites, but never excludes visible ones)
 * 
 * The algorithm is "conservative" meaning it may include sprites that are slightly
 * off-screen, but it will never exclude sprites that are actually visible. This is
 * a performance trade-off - it's better to render a few extra sprites than to miss
 * visible ones and have rendering artifacts.
 * 
 * @param sprite The sprite to test
 * @param viewport The viewport size in pixels
 * @return YES if sprite might be visible, NO if definitely off-screen
 */
- (BOOL)isSpriteVisible:(SSKSprite *)sprite viewportPixels:(CGSize)viewport {
    CGFloat w = sprite.size.width  * fabs(sprite.scale.width);
    CGFloat h = sprite.size.height * fabs(sprite.scale.height);
    
    // Compute distance from anchor to each corner in local space
    CGFloat ax = sprite.anchor.x;
    CGFloat ay = sprite.anchor.y;
    CGFloat dx0 = ax * w;           // distance to left edge
    CGFloat dx1 = (1 - ax) * w;     // distance to right edge
    CGFloat dy0 = ay * h;           // distance to bottom edge
    CGFloat dy1 = (1 - ay) * h;     // distance to top edge
    
    // Max radius is the furthest corner from anchor (conservative for any rotation)
    CGFloat radius = MAX(MAX(hypot(dx0, dy0), hypot(dx0, dy1)),
                         MAX(hypot(dx1, dy0), hypot(dx1, dy1)));
    
    CGPoint pos = sprite.position;
    if (pos.x + radius < 0 || pos.x - radius > viewport.width)  return NO;
    if (pos.y + radius < 0 || pos.y - radius > viewport.height) return NO;
    return YES;
}

/**
 * Sorts visible indices by z (ascending, deterministic tie-break by original index).
 * 
 * This method sorts the _visibleIndices array by the z values of the sprites they
 * reference. The sort is:
 *   - Ascending: Lower z values come first (drawn behind)
 *   - Deterministic: Equal z values maintain original order (stable via index tie-break)
 *   - Safe: Non-finite z values (NaN, infinity) are treated as 0.0
 * 
 * Sorting algorithm:
 *   - Uses qsort_b (Apple's block-based quicksort)
 *   - Comparator does Objective-C messaging (sprite.z) - has overhead
 *   - For large sprite counts (1000+), consider precomputing z into C array
 * 
 * The sort modifies _visibleIndices in-place. After sorting, _visibleIndices[0]
 * references the sprite with the lowest z value, _visibleIndices[visibleCount-1]
 * references the sprite with the highest z value.
 * 
 * @param visibleCount Number of visible sprites to sort
 * @param sprites The original sprite array (for z value lookup)
 */
- (void)sortVisibleIndices:(NSUInteger)visibleCount sprites:(NSArray<SSKSprite *> *)sprites {
    if (visibleCount <= 1) return;
    
    NSArray<SSKSprite *> *spriteArray = sprites;
    qsort_b(_visibleIndices, visibleCount, sizeof(NSUInteger), ^int(const void *a, const void *b) {
        NSUInteger idxA = *(const NSUInteger *)a;
        NSUInteger idxB = *(const NSUInteger *)b;
        
        // Explicit cast to avoid ambiguity (NSArray subscript returns id)
        SSKSprite *sA = spriteArray[idxA];
        SSKSprite *sB = spriteArray[idxB];
        float zA = sA.z;
        float zB = sB.z;
        
        // Handle non-finite values (NaN, infinity): treat as 0
        if (!isfinite(zA)) zA = 0.0f;
        if (!isfinite(zB)) zB = 0.0f;
        
        // Compare z values
        if (zA < zB) return -1;
        if (zA > zB) return 1;
        
        // Equal z: preserve original order via index tie-break
        if (idxA < idxB) return -1;
        if (idxA > idxB) return 1;
        return 0;
    });
}

/// Returns sorted indices for sprites (testing helper).
/// Exposed via SSKMetalSpritePass+Testing.h for unit tests.
- (const NSUInteger *)sortedIndicesForSprites:(NSArray<SSKSprite *> *)sprites
                                        count:(NSUInteger *)outCount {
    NSUInteger count = sprites.count;
    if (count == 0) {
        if (outCount) *outCount = 0;
        return NULL;
    }
    
    if (![self ensureVisibleIndicesCapacity:count]) {
        if (outCount) *outCount = 0;
        return NULL;
    }
    
    // Initialize with all indices
    for (NSUInteger i = 0; i < count; i++) {
        _visibleIndices[i] = i;
    }
    
    // Sort them
    [self sortVisibleIndices:count sprites:sprites];
    
    if (outCount) *outCount = count;
    return _visibleIndices;
}

#pragma mark - Setup

- (BOOL)setupWithDevice:(id<MTLDevice>)device {
    // This method requires a library parameter; use setupWithDevice:library: instead
    return NO;
}

- (BOOL)setupWithDevice:(id<MTLDevice>)device library:(id<MTLLibrary>)library {
    if (!device || !library) {
        return NO;
    }
    
    self.device = device;
    
    // Build quad vertex buffer
    if (![self buildQuadBuffer]) {
        if ([SSKDiagnostics isEnabled]) {
            [SSKDiagnostics log:@"SSKMetalSpritePass: failed to build quad vertex buffer."];
        }
        return NO;
    }
    
    // Build sampler state
    if (![self buildSamplerState]) {
        if ([SSKDiagnostics isEnabled]) {
            [SSKDiagnostics log:@"SSKMetalSpritePass: failed to build sampler state."];
        }
        return NO;
    }
    
    // Build render pipelines
    if (![self buildPipelinesWithLibrary:library]) {
        if ([SSKDiagnostics isEnabled]) {
            [SSKDiagnostics log:@"SSKMetalSpritePass: failed to build render pipelines."];
        }
        return NO;
    }
    
    // Initialize instance buffer with reasonable capacity
    self.instanceBufferCapacity = 64;
    self.instanceBuffer = [device newBufferWithLength:self.instanceBufferCapacity * sizeof(SSKMetalSpriteData)
                                              options:MTLResourceStorageModeShared];
    if (!self.instanceBuffer) {
        if ([SSKDiagnostics isEnabled]) {
            [SSKDiagnostics log:@"SSKMetalSpritePass: failed to create instance buffer."];
        }
        return NO;
    }
    
    return YES;
}

- (BOOL)buildQuadBuffer {
    // Quad vertices in the range -0.5 to 0.5 (will be scaled by sprite size)
    // Triangle strip order: bottom-left, bottom-right, top-left, top-right
    static const vector_float2 quadVertices[] = {
        {-0.5f, -0.5f},  // Bottom-left
        { 0.5f, -0.5f},  // Bottom-right
        {-0.5f,  0.5f},  // Top-left
        { 0.5f,  0.5f},  // Top-right
    };
    
    self.quadVertexBuffer = [self.device newBufferWithBytes:quadVertices
                                                     length:sizeof(quadVertices)
                                                    options:MTLResourceStorageModeShared];
    return self.quadVertexBuffer != nil;
}

- (BOOL)buildSamplerState {
    return [self buildSamplerStateWithFilter:self.samplerFilter];
}

- (BOOL)buildSamplerStateWithFilter:(SSKSpriteSamplerFilter)filter {
    MTLSamplerDescriptor *descriptor = [[MTLSamplerDescriptor alloc] init];
    
    // Select filter mode based on property
    MTLSamplerMinMagFilter mtlFilter = (filter == SSKSpriteSamplerFilterNearest)
        ? MTLSamplerMinMagFilterNearest
        : MTLSamplerMinMagFilterLinear;
    
    descriptor.minFilter = mtlFilter;
    descriptor.magFilter = mtlFilter;
    descriptor.mipFilter = MTLSamplerMipFilterNotMipmapped;
    descriptor.sAddressMode = MTLSamplerAddressModeClampToEdge;
    descriptor.tAddressMode = MTLSamplerAddressModeClampToEdge;
    
    id<MTLSamplerState> newSampler = [self.device newSamplerStateWithDescriptor:descriptor];
    if (newSampler) {
        self.samplerState = newSampler;
        self.currentSamplerFilter = filter;
        return YES;
    }
    return NO;
}

- (void)setSamplerFilter:(SSKSpriteSamplerFilter)samplerFilter {
    if (_samplerFilter != samplerFilter) {
        _samplerFilter = samplerFilter;
        // Rebuild sampler state if device is available (pass has been set up)
        if (self.device) {
            [self buildSamplerStateWithFilter:samplerFilter];
        }
    }
}

- (BOOL)buildPipelinesWithLibrary:(id<MTLLibrary>)library {
    // Load shader functions
    id<MTLFunction> vertexFunction = [library newFunctionWithName:@"spriteVertex"];
    id<MTLFunction> fragmentFunction = [library newFunctionWithName:@"spriteFragment"];
    id<MTLFunction> solidFragmentFunction = [library newFunctionWithName:@"spriteSolidFragment"];
    
    if (!vertexFunction) {
        if ([SSKDiagnostics isEnabled]) {
            [SSKDiagnostics log:@"SSKMetalSpritePass: spriteVertex function not found in library."];
        }
        return NO;
    }
    
    if (!fragmentFunction) {
        if ([SSKDiagnostics isEnabled]) {
            [SSKDiagnostics log:@"SSKMetalSpritePass: spriteFragment function not found in library."];
        }
        return NO;
    }
    
    if (!solidFragmentFunction) {
        if ([SSKDiagnostics isEnabled]) {
            [SSKDiagnostics log:@"SSKMetalSpritePass: spriteSolidFragment function not found in library."];
        }
        return NO;
    }
    
    // Create pipeline descriptor
    MTLRenderPipelineDescriptor *descriptor = [[MTLRenderPipelineDescriptor alloc] init];
    descriptor.vertexFunction = vertexFunction;
    descriptor.colorAttachments[0].pixelFormat = MTLPixelFormatBGRA8Unorm;
    
    NSError *error = nil;
    
    // Alpha blend pipeline (textured) - premultiplied alpha
    // Textures are created with kCGImageAlphaPremultipliedLast, so RGB is already
    // multiplied by alpha. Use One/OneMinusSourceAlpha for correct blending.
    descriptor.fragmentFunction = fragmentFunction;
    descriptor.colorAttachments[0].blendingEnabled = YES;
    descriptor.colorAttachments[0].sourceRGBBlendFactor = MTLBlendFactorOne;
    descriptor.colorAttachments[0].destinationRGBBlendFactor = MTLBlendFactorOneMinusSourceAlpha;
    descriptor.colorAttachments[0].rgbBlendOperation = MTLBlendOperationAdd;
    descriptor.colorAttachments[0].sourceAlphaBlendFactor = MTLBlendFactorOne;
    descriptor.colorAttachments[0].destinationAlphaBlendFactor = MTLBlendFactorOneMinusSourceAlpha;
    descriptor.colorAttachments[0].alphaBlendOperation = MTLBlendOperationAdd;
    
    self.alphaPipeline = [self.device newRenderPipelineStateWithDescriptor:descriptor error:&error];
    if (!self.alphaPipeline) {
        if ([SSKDiagnostics isEnabled]) {
            [SSKDiagnostics log:@"SSKMetalSpritePass: failed to create alpha pipeline: %@", error.localizedDescription];
        }
        return NO;
    }
    
    // Additive blend pipeline (textured) - premultiplied alpha additive
    // For additive blending with premultiplied textures, use One/One
    descriptor.colorAttachments[0].sourceRGBBlendFactor = MTLBlendFactorOne;
    descriptor.colorAttachments[0].destinationRGBBlendFactor = MTLBlendFactorOne;
    descriptor.colorAttachments[0].sourceAlphaBlendFactor = MTLBlendFactorOne;
    descriptor.colorAttachments[0].destinationAlphaBlendFactor = MTLBlendFactorOne;
    
    self.additivePipeline = [self.device newRenderPipelineStateWithDescriptor:descriptor error:&error];
    if (!self.additivePipeline) {
        if ([SSKDiagnostics isEnabled]) {
            [SSKDiagnostics log:@"SSKMetalSpritePass: failed to create additive pipeline: %@", error.localizedDescription];
        }
        return NO;
    }
    
    // Alpha blend pipeline (solid color) - premultiplied alpha output
    descriptor.fragmentFunction = solidFragmentFunction;
    descriptor.colorAttachments[0].sourceRGBBlendFactor = MTLBlendFactorOne;
    descriptor.colorAttachments[0].destinationRGBBlendFactor = MTLBlendFactorOneMinusSourceAlpha;
    descriptor.colorAttachments[0].sourceAlphaBlendFactor = MTLBlendFactorOne;
    descriptor.colorAttachments[0].destinationAlphaBlendFactor = MTLBlendFactorOneMinusSourceAlpha;
    
    self.alphaSolidPipeline = [self.device newRenderPipelineStateWithDescriptor:descriptor error:&error];
    if (!self.alphaSolidPipeline) {
        if ([SSKDiagnostics isEnabled]) {
            [SSKDiagnostics log:@"SSKMetalSpritePass: failed to create alpha solid pipeline: %@", error.localizedDescription];
        }
        return NO;
    }
    
    // Additive blend pipeline (solid color) - premultiplied alpha additive
    descriptor.colorAttachments[0].sourceRGBBlendFactor = MTLBlendFactorOne;
    descriptor.colorAttachments[0].destinationRGBBlendFactor = MTLBlendFactorOne;
    descriptor.colorAttachments[0].sourceAlphaBlendFactor = MTLBlendFactorOne;
    descriptor.colorAttachments[0].destinationAlphaBlendFactor = MTLBlendFactorOne;
    
    self.additiveSolidPipeline = [self.device newRenderPipelineStateWithDescriptor:descriptor error:&error];
    if (!self.additiveSolidPipeline) {
        if ([SSKDiagnostics isEnabled]) {
            [SSKDiagnostics log:@"SSKMetalSpritePass: failed to create additive solid pipeline: %@", error.localizedDescription];
        }
        return NO;
    }
    
    return YES;
}

/**
 * Ensures the instance buffer has capacity for at least `count` sprites.
 * 
 * This method grows the instance buffer if needed. The buffer is used to store
 * SSKMetalSpriteData structs that are uploaded to the GPU for instanced rendering.
 * 
 * @param count The required capacity in number of sprites
 * @return YES if the buffer has sufficient capacity, NO if allocation failed
 * 
 * On allocation failure:
 *   - The existing buffer is preserved (not lost)
 *   - Returns NO so the caller can handle gracefully
 *   - Caller should NOT write more than instanceBufferCapacity entries
 */
- (BOOL)ensureInstanceCapacity:(NSUInteger)count {
    if (count <= self.instanceBufferCapacity) {
        return YES;  // Already have enough capacity
    }
    
    // Grow buffer with some headroom to reduce reallocations
    NSUInteger newCapacity = MAX(count, self.instanceBufferCapacity * 2);
    if (newCapacity < 16) newCapacity = 16;  // Minimum initial capacity
    
    id<MTLBuffer> newBuffer = [self.device newBufferWithLength:newCapacity * sizeof(SSKMetalSpriteData)
                                                       options:MTLResourceStorageModeShared];
    if (!newBuffer) {
        // Allocation failed - keep existing buffer, return failure
        // Caller must check return value and limit writes to instanceBufferCapacity
        if ([SSKDiagnostics isEnabled]) {
            [SSKDiagnostics log:@"SSKMetalSpritePass: Failed to allocate instance buffer for %lu sprites", 
                (unsigned long)count];
        }
        return NO;
    }
    
    self.instanceBuffer = newBuffer;
    self.instanceBufferCapacity = newCapacity;
    return YES;
}

- (BOOL)encodeSprites:(NSArray<SSKSprite *> *)sprites
              texture:(id<MTLTexture>)texture
            blendMode:(SSKParticleBlendMode)blendMode
       viewportPixels:(CGSize)viewportPixels
        commandBuffer:(id<MTLCommandBuffer>)commandBuffer
         renderTarget:(id<MTLTexture>)renderTarget
           loadAction:(MTLLoadAction)loadAction
           clearColor:(MTLClearColor)clearColor {
    // Forward to sortByZ: variant with sorting disabled for backward compatibility
    return [self encodeSprites:sprites
                       texture:texture
                     blendMode:blendMode
                viewportPixels:viewportPixels
                 commandBuffer:commandBuffer
                  renderTarget:renderTarget
                    loadAction:loadAction
                    clearColor:clearColor
                       sortByZ:NO];
}

- (BOOL)encodeSprites:(NSArray<SSKSprite *> *)sprites
              texture:(id<MTLTexture>)texture
            blendMode:(SSKParticleBlendMode)blendMode
       viewportPixels:(CGSize)viewportPixels
        commandBuffer:(id<MTLCommandBuffer>)commandBuffer
         renderTarget:(id<MTLTexture>)renderTarget
           loadAction:(MTLLoadAction)loadAction
           clearColor:(MTLClearColor)clearColor
              sortByZ:(BOOL)sortByZ {
    
    NSUInteger count = sprites.count;
    if (count == 0) {
        return YES; // Nothing to render - early exit for efficiency
    }
    
    // ========================================================================
    // Step 1: Build visible indices (or all indices if culling disabled)
    // ========================================================================
    // 
    // If culling is enabled, we test each sprite against the viewport and only
    // add visible sprites to the _visibleIndices array. This saves CPU time by
    // not processing off-screen sprites in later steps.
    //
    // If culling is disabled, we add all sprite indices to the array.
    //
    // The _visibleIndices array is reused across frames to avoid allocations.
    if (![self ensureVisibleIndicesCapacity:count]) {
        return NO;  // Allocation failed - cannot proceed
    }
    
    NSUInteger visibleCount = 0;
    if (self.cullingEnabled) {
        // Culling enabled: only add visible sprites
        for (NSUInteger i = 0; i < count; i++) {
            if ([self isSpriteVisible:sprites[i] viewportPixels:viewportPixels]) {
                _visibleIndices[visibleCount++] = i;
            }
        }
    } else {
        // Culling disabled: add all sprites
        for (NSUInteger i = 0; i < count; i++) {
            _visibleIndices[i] = i;
        }
        visibleCount = count;
    }
    
    if (visibleCount == 0) {
        return YES;  // Nothing visible, nothing to draw - success (no error)
    }
    
    // ========================================================================
    // Step 2: Sort visible indices by z if requested
    // ========================================================================
    //
    // If z-sorting is enabled, we sort the _visibleIndices array by the z values
    // of the sprites they reference. This ensures sprites are drawn back-to-front
    // (lower z first, higher z last) for correct depth ordering.
    //
    // Sorting happens AFTER culling so we only sort sprites that will actually
    // be rendered. This saves CPU time.
    //
    // The sort is stable - sprites with equal z values maintain their original
    // order (via index tie-break in the comparator).
    if (sortByZ) {
        [self sortVisibleIndices:visibleCount sprites:sprites];
    }
    
    // ========================================================================
    // Step 3: Build instance data from visible sprites
    // ========================================================================
    //
    // Convert SSKSprite objects to SSKMetalSpriteData structs for GPU rendering.
    // We iterate through _visibleIndices (which may be sorted) and build the
    // instance data array. This array is then uploaded to the GPU as an instance
    // buffer for instanced rendering.
    //
    // If allocation fails, we limit the number of sprites to what fits in the
    // existing buffer. This provides graceful degradation rather than crashing.
    if (![self ensureInstanceCapacity:visibleCount]) {
        // Allocation failed - limit to existing capacity
        // This may result in some sprites not being drawn, but is better than crashing
        if (self.instanceBufferCapacity == 0) {
            // No buffer at all - can't render anything
            return NO;
        }
        
        NSUInteger maxSprites = self.instanceBufferCapacity;
        if (visibleCount > maxSprites) {
            // When z-sorting is enabled, _visibleIndices is sorted ascending by z.
            // Index 0 = lowest z (back), index N-1 = highest z (front).
            // If we must drop sprites, drop the BACK-MOST ones (lowest z, least visible).
            // Shift the array to keep the front-most sprites (end of sorted array).
            if (sortByZ) {
                NSUInteger dropCount = visibleCount - maxSprites;
                memmove(_visibleIndices, _visibleIndices + dropCount, maxSprites * sizeof(NSUInteger));
            }
            // If not sorting, just truncate from end (original order)
            visibleCount = maxSprites;
        }
        if ([SSKDiagnostics isEnabled]) {
            [SSKDiagnostics log:@"SSKMetalSpritePass: Limiting render to %lu sprites due to buffer allocation failure",
                (unsigned long)visibleCount];
        }
    }
    SSKMetalSpriteData *instanceData = (SSKMetalSpriteData *)self.instanceBuffer.contents;
    
    for (NSUInteger i = 0; i < visibleCount; i++) {
        NSUInteger srcIndex = _visibleIndices[i];
        SSKSprite *sprite = sprites[srcIndex];
        SSKMetalSpriteData *data = &instanceData[i];
        
        data->position = (vector_float2){(float)sprite.position.x, (float)sprite.position.y};
        
        // Apply scale to size (absolute value for geometry; flip does not change vertex positions)
        // 
        // The size field in the struct represents the actual rendered size in pixels.
        // We use the absolute value of scale because:
        //   - Negative scale is used for flipping (handled via UV coordinates)
        //   - The vertex positions don't change when flipping (quad is always the same)
        //   - Only the UV coordinates change to achieve the flip effect
        //
        // So scale (-1.0, 1.0) renders at normal size but flipped horizontally.
        float scaleX = (float)sprite.scale.width;
        float scaleY = (float)sprite.scale.height;
        data->size = (vector_float2){
            (float)sprite.size.width * fabsf(scaleX),
            (float)sprite.size.height * fabsf(scaleY)
        };
        
        // Precompute sin/cos on CPU to avoid per-vertex trig in shader
        //
        // Computing sin/cos once per sprite on the CPU is much more efficient than
        // computing it 4 times per sprite in the vertex shader (once per vertex).
        // The shader uses these precomputed values for rotation calculations.
        float rotation = (float)sprite.rotation;
        data->sinCos = (vector_float2){cosf(rotation), sinf(rotation)};
        
        // Anchor point for rotation/positioning
        // The anchor determines where the sprite rotates around and what part of
        // the sprite is at the position coordinate.
        data->anchor = (vector_float2){(float)sprite.anchor.x, (float)sprite.anchor.y};
        
        // Use cached float4 color to avoid colorUsingColorSpace: overhead
        //
        // SSKSprite caches the NSColor as a simd_float4 for efficient GPU transfer.
        // This avoids the expensive color space conversion on every frame. The cache
        // is automatically updated when colorTint changes.
        simd_float4 tint = sprite.colorTintFloat4;
        data->colorTint = (vector_float4){tint.x, tint.y, tint.z, tint.w};
        
    // Apply flip via UV affine mapping
    // 
    // Flipping is implemented by adjusting UV coordinates on the CPU, not by adding
    // extra fields to the struct or branching in the shader. This is efficient and
    // works naturally with animation frames.
    //
    // How it works:
    //   - Normal UV mapping: uv = textureOffset + quad01 * textureSize
    //   - Flipped UV mapping: uv = (textureOffset + textureSize) + quad01 * (-textureSize)
    //   
    //   So to flip horizontally (scaleX < 0):
    //     1. Shift textureOffset by textureSize (moves to opposite side)
    //     2. Negate textureSize (reverses the direction)
    //
    //   The shader doesn't need to know about flipping - it just uses the UV coords
    //   as-is, and negative textureSize naturally reverses the sampling direction.
    //
    // Note: textureOffset/textureSize are normalized (0.0-1.0), so this math works correctly.
    float texOffsetX = (float)sprite.textureOffset.x;
    float texOffsetY = (float)sprite.textureOffset.y;
    float texSizeX = (float)sprite.textureSize.width;
    float texSizeY = (float)sprite.textureSize.height;
    
    if (scaleX < 0.0f) {
        // Horizontal flip: shift offset right, negate size
        texOffsetX += texSizeX;
        texSizeX = -texSizeX;
    }
    if (scaleY < 0.0f) {
        // Vertical flip: shift offset down, negate size
        texOffsetY += texSizeY;
        texSizeY = -texSizeY;
    }
        
        data->textureCoord = (vector_float2){texOffsetX, texOffsetY};
        data->textureSize = (vector_float2){texSizeX, texSizeY};
        data->opacity = (float)sprite.opacity;
        data->z = isfinite(sprite.z) ? sprite.z : 0.0f;
        data->textureIndex = 0;  // Reserved for future texture array batching
    }
    
    // Mark buffer as modified
    [self.instanceBuffer didModifyRange:NSMakeRange(0, visibleCount * sizeof(SSKMetalSpriteData))];
    
    return [self encodeSpriteData:instanceData
                            count:visibleCount
                          texture:texture
                        blendMode:blendMode
                   viewportPixels:viewportPixels
                    commandBuffer:commandBuffer
                     renderTarget:renderTarget
                       loadAction:loadAction
                       clearColor:clearColor];
}

- (BOOL)encodeSpriteData:(const SSKMetalSpriteData *)spriteData
                   count:(NSUInteger)count
                 texture:(id<MTLTexture>)texture
               blendMode:(SSKParticleBlendMode)blendMode
          viewportPixels:(CGSize)viewportPixels
           commandBuffer:(id<MTLCommandBuffer>)commandBuffer
            renderTarget:(id<MTLTexture>)renderTarget
              loadAction:(MTLLoadAction)loadAction
              clearColor:(MTLClearColor)clearColor {
    
    if (count == 0) {
        return YES;
    }
    
    if (!commandBuffer || !renderTarget) {
        return NO;
    }
    
    // Verify viewport matches render target dimensions
    // This check runs in both DEBUG and release builds to catch misconfiguration
    BOOL viewportMismatch = fabs(viewportPixels.width - renderTarget.width) >= 1.0 ||
                            fabs(viewportPixels.height - renderTarget.height) >= 1.0;
    if (viewportMismatch) {
        // Log warning in all builds so issues are visible
        if ([SSKDiagnostics isEnabled]) {
            [SSKDiagnostics log:@"SSKMetalSpritePass: viewportPixels (%g x %g) does not match renderTarget (%lu x %lu) - sprites may render incorrectly",
                viewportPixels.width, viewportPixels.height,
                (unsigned long)renderTarget.width, (unsigned long)renderTarget.height];
        }
        // Assert in DEBUG to catch during development
        NSAssert(NO, @"viewportPixels (%g x %g) does not match renderTarget (%lu x %lu)",
                 viewportPixels.width, viewportPixels.height,
                 (unsigned long)renderTarget.width, (unsigned long)renderTarget.height);
        // Continue anyway in release - incorrect rendering is better than no rendering
    }
    
    // If external data provided, copy to instance buffer
    if (spriteData != self.instanceBuffer.contents) {
        if (![self ensureInstanceCapacity:count]) {
            // Allocation failed - can't proceed with the requested count
            if (self.instanceBufferCapacity == 0) {
                return NO;  // No buffer at all
            }
            // Limit to existing capacity (partial render is better than crash)
            count = MIN(count, self.instanceBufferCapacity);
            if ([SSKDiagnostics isEnabled]) {
                [SSKDiagnostics log:@"SSKMetalSpritePass: encodeSpriteData limiting to %lu sprites due to allocation failure",
                    (unsigned long)count];
            }
        }
        memcpy(self.instanceBuffer.contents, spriteData, count * sizeof(SSKMetalSpriteData));
        [self.instanceBuffer didModifyRange:NSMakeRange(0, count * sizeof(SSKMetalSpriteData))];
    }
    
    // Create render pass descriptor
    MTLRenderPassDescriptor *descriptor = [MTLRenderPassDescriptor renderPassDescriptor];
    descriptor.colorAttachments[0].texture = renderTarget;
    descriptor.colorAttachments[0].storeAction = MTLStoreActionStore;
    descriptor.colorAttachments[0].clearColor = clearColor;
    descriptor.colorAttachments[0].loadAction = loadAction;
    
    id<MTLRenderCommandEncoder> encoder = [commandBuffer renderCommandEncoderWithDescriptor:descriptor];
    if (!encoder) {
        return NO;
    }
    
    // Select pipeline based on blend mode and texture availability
    id<MTLRenderPipelineState> pipeline;
    if (texture) {
        pipeline = (blendMode == SSKParticleBlendModeAdditive) ? self.additivePipeline : self.alphaPipeline;
    } else {
        pipeline = (blendMode == SSKParticleBlendModeAdditive) ? self.additiveSolidPipeline : self.alphaSolidPipeline;
    }
    
    if (!pipeline) {
        [encoder endEncoding];
        return NO;
    }
    
    // Set viewport
    MTLViewport viewport = {0.0, 0.0, (double)renderTarget.width, (double)renderTarget.height, 0.0, 1.0};
    [encoder setViewport:viewport];
    
    // Set pipeline state
    [encoder setRenderPipelineState:pipeline];
    
    // Set vertex buffers
    [encoder setVertexBuffer:self.quadVertexBuffer offset:0 atIndex:0];
    [encoder setVertexBuffer:self.instanceBuffer offset:0 atIndex:1];
    
    // Set viewport size uniform (in pixels)
    vector_float2 viewportUniform = {(float)viewportPixels.width, (float)viewportPixels.height};
    [encoder setVertexBytes:&viewportUniform length:sizeof(vector_float2) atIndex:2];
    
    // Set texture and sampler if available
    if (texture) {
        [encoder setFragmentTexture:texture atIndex:0];
        [encoder setFragmentSamplerState:self.samplerState atIndex:0];
    }
    
    // Draw instanced quads
    [encoder drawPrimitives:MTLPrimitiveTypeTriangleStrip
                vertexStart:0
                vertexCount:4
              instanceCount:count];
    
    [encoder endEncoding];
    
    return YES;
}

#pragma mark - Deprecated (viewportSize: forwarders)

- (BOOL)encodeSprites:(NSArray<SSKSprite *> *)sprites
              texture:(id<MTLTexture>)texture
            blendMode:(SSKParticleBlendMode)blendMode
         viewportSize:(CGSize)viewportSize
        commandBuffer:(id<MTLCommandBuffer>)commandBuffer
         renderTarget:(id<MTLTexture>)renderTarget
           loadAction:(MTLLoadAction)loadAction
           clearColor:(MTLClearColor)clearColor {
    return [self encodeSprites:sprites
                       texture:texture
                     blendMode:blendMode
                viewportPixels:viewportSize
                 commandBuffer:commandBuffer
                  renderTarget:renderTarget
                    loadAction:loadAction
                    clearColor:clearColor];
}

- (BOOL)encodeSprites:(NSArray<SSKSprite *> *)sprites
              texture:(id<MTLTexture>)texture
            blendMode:(SSKParticleBlendMode)blendMode
         viewportSize:(CGSize)viewportSize
        commandBuffer:(id<MTLCommandBuffer>)commandBuffer
         renderTarget:(id<MTLTexture>)renderTarget
           loadAction:(MTLLoadAction)loadAction
           clearColor:(MTLClearColor)clearColor
             sortByZ:(BOOL)sortByZ {
    return [self encodeSprites:sprites
                       texture:texture
                     blendMode:blendMode
                viewportPixels:viewportSize
                 commandBuffer:commandBuffer
                  renderTarget:renderTarget
                    loadAction:loadAction
                    clearColor:clearColor
                       sortByZ:sortByZ];
}

- (BOOL)encodeSpriteData:(const SSKMetalSpriteData *)spriteData
                   count:(NSUInteger)count
                 texture:(id<MTLTexture>)texture
               blendMode:(SSKParticleBlendMode)blendMode
            viewportSize:(CGSize)viewportSize
           commandBuffer:(id<MTLCommandBuffer>)commandBuffer
            renderTarget:(id<MTLTexture>)renderTarget
              loadAction:(MTLLoadAction)loadAction
              clearColor:(MTLClearColor)clearColor {
    return [self encodeSpriteData:spriteData
                            count:count
                          texture:texture
                        blendMode:blendMode
                   viewportPixels:viewportSize
                    commandBuffer:commandBuffer
                     renderTarget:renderTarget
                       loadAction:loadAction
                       clearColor:clearColor];
}

@end

