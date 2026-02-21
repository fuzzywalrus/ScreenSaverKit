# ScreenSaverKit Effect Implementation Guide

This guide explains how to understand, extend, and work with the effect chaining system in ScreenSaverKit.

## Quick Reference: Key Files

| File | Purpose |
|------|---------|
| `SSKMetalRenderer.h/m` | Main coordinator; manages passes and frame lifecycle |
| `SSKMetalPass.h/m` | Abstract base class for all FX passes |
| `SSKMetalParticlePass.h/m` | Particle rendering (render pipeline) |
| `SSKMetalBlurPass.h/m` | Gaussian blur (compute pipeline) |
| `SSKMetalBloomPass.h/m` | Bloom/glow effect (compute pipeline) |
| `SSKMetalTextureCache.h/m` | Texture pooling for intermediate renders |
| `SSKParticleShaders.metal` | All Metal shaders and compute kernels |
| `SSKParticleSystem.h/m` | CPU-side particle management and simulation |
| `SSKMetalParticleRenderer.h/m` | Convenience wrapper for particle-only workflows |

---

## Understanding the Frame Rendering Flow

### Minimal Example: Particles Only

```objc
// In your saver's renderMetalFrame:deltaTime: method
- (void)renderMetalFrame:(SSKMetalRenderer *)renderer deltaTime:(NSTimeInterval)dt {
    // Update simulation
    [self.particleSystem advanceBy:dt];
    
    // Get snapshot of live particles
    NSArray<SSKParticle *> *particles = [self.particleSystem aliveParticlesSnapshot];
    
    // Render particles to screen
    [renderer drawParticles:particles
                  blendMode:SSKParticleBlendModeAlpha
               viewportSize:self.bounds.size];
}
```

### Example: Particles + Blur

```objc
- (void)renderMetalFrame:(SSKMetalRenderer *)renderer deltaTime:(NSTimeInterval)dt {
    [self.particleSystem advanceBy:dt];
    NSArray<SSKParticle *> *particles = [self.particleSystem aliveParticlesSnapshot];
    
    // Step 1: Render particles
    [renderer drawParticles:particles
                  blendMode:SSKParticleBlendModeAlpha
               viewportSize:self.bounds.size];
    
    // Step 2: Apply blur (motion blur effect)
    if (self.motionBlurRadius > 0.01) {
        [renderer applyBlur:self.motionBlurRadius];
    }
}
```

### Example: Particles + Bloom (Glow)

```objc
- (void)renderMetalFrame:(SSKMetalRenderer *)renderer deltaTime:(NSTimeInterval)dt {
    [self.particleSystem advanceBy:dt];
    NSArray<SSKParticle *> *particles = [self.particleSystem aliveParticlesSnapshot];
    
    // Step 1: Render particles (use additive blending for bloom effect)
    [renderer drawParticles:particles
                  blendMode:SSKParticleBlendModeAdditive
               viewportSize:self.bounds.size];
    
    // Step 2: Apply bloom (extract bright areas and blur them)
    if (self.bloomIntensity > 0.05) {
        renderer.bloomThreshold = 0.7;  // Only bloom pixels above 70% brightness
        renderer.bloomBlurSigma = 3.0;   // Blur spread
        [renderer applyBloom:self.bloomIntensity];
    }
}
```

### Example: Full Chain (Particles → Blur → Bloom)

```objc
- (void)renderMetalFrame:(SSKMetalRenderer *)renderer deltaTime:(NSTimeInterval)dt {
    [self.particleSystem advanceBy:dt];
    NSArray<SSKParticle *> *particles = [self.particleSystem aliveParticlesSnapshot];
    
    // Clear the drawable with a color
    [renderer clearWithColor:MTLClearColorMake(0.0, 0.0, 0.0, 1.0)];
    
    // Step 1: Draw particles
    [renderer drawParticles:particles
                  blendMode:self.particleSystem.blendMode
               viewportSize:self.bounds.size];
    
    // Step 2: Optional blur
    if (self.blurRadius > 0.01) {
        [renderer applyBlur:self.blurRadius];
    }
    
    // Step 3: Optional bloom (depends on blur being available)
    if (self.bloomIntensity > 0.05) {
        renderer.bloomThreshold = self.bloomThreshold;
        renderer.bloomBlurSigma = self.bloomBlurSigma;
        [renderer applyBloom:self.bloomIntensity];
    }
}
```

---

## Understanding Each Pass

### 1. Particle Pass (Rendering)

**What it does**: Renders particle quads to the screen using instanced rendering.

**Key concepts**:
- Uses a **quad vertex buffer** (4 vertices, pre-allocated once)
- Uses an **instance buffer** that grows dynamically as particle count increases
- Supports two blend modes: Alpha compositing or Additive blending
- Each particle becomes a "soft disc" due to fragment shader softness parameter

**Data per particle**:
```objc
typedef struct {
    vector_float2 position;      // World position
    vector_float2 direction;     // Trail direction (for orientation)
    float width;                 // Trail width
    float length;                // Trail length (calculated from z-depth or length multiplier)
    vector_float4 color;         // RGBA
    float softness;              // Edge feathering (from particle.userScalar, 0 for z-depth)
} SSKMetalInstanceData;
```

**Z-Depth Rendering Support**:
- When z-depth is enabled, `userScalar` contains z-depth value (0.01-1.0)
- Length calculated as: `width * lengthMultiplier * zDepth` (far drops are shorter)
- Length multiplier stored in `SSKMetalParticlePass.lengthMultiplier` property
- Softness set to 0 for z-depth particles (hard edges for retro rain effect)
- Color already darkened by z-depth during GPU spawn

**When particles render soft-edged**:
```metal
// Fragment shader applies Gaussian falloff
float alpha = in.color.a * exp(-softness * dist * dist * 4.0);
```

**Blend mode selection**:
```metal
// Alpha mode: standard alpha compositing
src: (one, one_minus_src_alpha)

// Additive mode: for glow/energy effects
src: (one, one)
```

### 2. Blur Pass (Post-Process Compute)

**What it does**: Applies separable Gaussian blur to the render target.

**Two-pass separable design**:
1. **Horizontal pass**: Convolve along X axis (using shared texture cache)
2. **Vertical pass**: Convolve along Y axis

**Why separable**:
- O(n) instead of O(n²) for blur radius n
- Much faster on GPU (fewer memory accesses)

**Key parameters**:
```objc
self.radius = sigma;  // Gaussian standard deviation
```

**Kernel size computed as**:
```metal
float radius = max(1.0f, sigma * 3.0f);  // 3-sigma rule
```

**Usage**:
```objc
if (blurRadius > 0.01) {
    [renderer applyBlur:blurRadius];
}
```

### 3. Bloom Pass (Post-Process Multi-Stage)

**What it does**: Extracts bright pixels, blurs them, and composites back (glow effect).

**Three-stage pipeline**:

1. **Threshold kernel** (compute):
   - Input: Render target
   - Output: brightTexture (only pixels above threshold)
   ```metal
   float lum = bloomLuminance(srcColor.rgb);
   float bloomFactor = max(lum - threshold, 0.0f);
   ```

2. **Blur kernel** (delegates to SSKMetalBlurPass):
   - Input: brightTexture
   - Output: blurredTexture
   - Uses separable Gaussian

3. **Composite kernel** (compute):
   - Input: blurredTexture, render target
   - Output: Blended back to render target
   ```metal
   float glow = bloom.a * intensity;
   dest.rgb = clamp(dest.rgb + bloom.rgb * glow, 0.0, 1.0);
   ```

**Key parameters**:
```objc
renderer.bloomThreshold = 0.8;    // Extract pixels above 80% luminance
renderer.bloomBlurSigma = 3.0;    // Blur spread
[renderer applyBloom:1.0];        // Glow intensity (1.0 = normal)
```

**Luminance formula**:
```metal
float bloomLuminance(float3 color) {
    return dot(color, float3(0.2126f, 0.7152f, 0.0722f));  // ITU-R BT.709
}
```

---

## Texture Cache: The Hidden Hero

### Why Caching Matters

Without caching, each frame allocates new textures for intermediate renders. This is **expensive**:
- Metal texture allocation has CPU overhead
- Fragmentation can occur
- Memory pressure increases

The `SSKMetalTextureCache` solves this by **pooling textures**.

### How Caching Works

```objc
// Inside blur pass:
MTLTextureUsage usage = MTLTextureUsageShaderRead | MTLTextureUsageShaderWrite;

// Acquire or create a scratch texture matching the source
id<MTLTexture> scratch = [textureCache acquireTextureMatchingTexture:source
                                                              usage:usage];

// Use it for horizontal pass
[encoder setTexture:source atIndex:0];
[encoder setTexture:scratch atIndex:1];
[encoder dispatchThreadgroups:...];

// Use it for vertical pass
[encoder setTexture:scratch atIndex:0];
[encoder setTexture:destination atIndex:1];
[encoder dispatchThreadgroups:...];

// Return to pool for reuse next frame
[textureCache releaseTexture:scratch];
```

### Bucket Strategy

Textures are organized in buckets by key:

```objc
// Key = (width, height, pixelFormat, usage)
uint64_t key = ((uint64_t)width << 32) ^ ((uint64_t)height << 16) 
             ^ ((uint64_t)format << 8) ^ (uint64_t)usage;
```

Multiple textures of the same size/format are pooled together. When you need one, the cache returns the first available from the bucket. If none exist, a new one is created.

---

## Adding a New Effect: Step-by-Step

### Example: Color Shift Effect

Let's add a simple effect that shifts colors (hue rotation).

#### Step 1: Create the Pass Class

**File: SSKMetalColorShiftPass.h**
```objc
#import "SSKMetalPass.h"

@class SSKMetalTextureCache;

NS_ASSUME_NONNULL_BEGIN

@interface SSKMetalColorShiftPass : SSKMetalPass

@property (nonatomic) CGFloat hueShift;  // 0-360 degrees

- (BOOL)setupWithDevice:(id<MTLDevice>)device library:(id<MTLLibrary>)library;

- (BOOL)encodeColorShift:(id<MTLCommandBuffer>)commandBuffer
                 source:(id<MTLTexture>)source
           renderTarget:(id<MTLTexture>)renderTarget
           textureCache:(SSKMetalTextureCache *)textureCache;

@end

NS_ASSUME_NONNULL_END
```

**File: SSKMetalColorShiftPass.m**
```objc
#import "SSKMetalColorShiftPass.h"
#import "SSKMetalTextureCache.h"
#import "SSKDiagnostics.h"

@interface SSKMetalColorShiftPass ()
@property (nonatomic, strong) id<MTLDevice> device;
@property (nonatomic, strong) id<MTLComputePipelineState> colorShiftPipeline;
@end

@implementation SSKMetalColorShiftPass

- (BOOL)setupWithDevice:(id<MTLDevice>)device library:(id<MTLLibrary>)library {
    NSParameterAssert(device);
    NSParameterAssert(library);
    if (!device || !library) return NO;
    
    self.device = device;
    
    NSError *error = nil;
    id<MTLFunction> shiftFunc = [library newFunctionWithName:@"colorShiftKernel"];
    if (!shiftFunc) {
        if ([SSKDiagnostics isEnabled]) {
            [SSKDiagnostics log:@"SSKMetalColorShiftPass: missing colorShiftKernel in library"];
        }
        return NO;
    }
    
    self.colorShiftPipeline = [device newComputePipelineStateWithFunction:shiftFunc error:&error];
    if (!self.colorShiftPipeline) {
        if ([SSKDiagnostics isEnabled]) {
            [SSKDiagnostics log:@"SSKMetalColorShiftPass: failed to create pipeline: %@", 
             error.localizedDescription];
        }
        return NO;
    }
    
    return YES;
}

- (BOOL)encodeColorShift:(id<MTLCommandBuffer>)commandBuffer
                 source:(id<MTLTexture>)source
           renderTarget:(id<MTLTexture>)renderTarget
           textureCache:(SSKMetalTextureCache *)textureCache {
    if (!commandBuffer || !source || !renderTarget || !self.colorShiftPipeline) {
        return NO;
    }
    
    id<MTLComputeCommandEncoder> encoder = [commandBuffer computeCommandEncoder];
    if (!encoder) return NO;
    
    float hue = fmod((float)self.hueShift, 360.0f);
    MTLSize threadGroups = MTLSizeMake(
        (source.width + 15) / 16,
        (source.height + 15) / 16,
        1
    );
    MTLSize threadsPerGroup = MTLSizeMake(16, 16, 1);
    
    [encoder setComputePipelineState:self.colorShiftPipeline];
    [encoder setTexture:source atIndex:0];
    [encoder setTexture:renderTarget atIndex:1];
    [encoder setBytes:&hue length:sizeof(float) atIndex:0];
    [encoder dispatchThreadgroups:threadGroups threadsPerThreadgroup:threadsPerGroup];
    [encoder endEncoding];
    
    return YES;
}

@end
```

#### Step 2: Add Shader Function

**Add to SSKParticleShaders.metal**:
```metal
kernel void colorShiftKernel(texture2d<float, access::sample> source [[texture(0)]],
                             texture2d<float, access::write> destination [[texture(1)]],
                             constant float &hueShift [[buffer(0)]],
                             uint2 gid [[thread_position_in_grid]]) {
    if (gid.x >= destination.get_width() || gid.y >= destination.get_height()) {
        return;
    }
    
    constexpr sampler s(address::clamp_to_edge, filter::nearest);
    float4 color = source.sample(s, float2(gid) / float2(source.get_width(), source.get_height()));
    
    // RGB to HSV
    float3 c = color.rgb;
    float maxC = max(max(c.r, c.g), c.b);
    float minC = min(min(c.r, c.g), c.b);
    float delta = maxC - minC;
    
    float h = 0.0f;
    if (delta > 0.0001f) {
        if (maxC == c.r) h = fmod((c.g - c.b) / delta, 6.0f);
        else if (maxC == c.g) h = (c.b - c.r) / delta + 2.0f;
        else h = (c.r - c.g) / delta + 4.0f;
        h = h / 6.0f;
    }
    
    float s = (maxC > 0.0001f) ? (delta / maxC) : 0.0f;
    float v = maxC;
    
    // Apply hue shift
    h = fmod(h + (hueShift / 360.0f), 1.0f);
    
    // HSV back to RGB
    float c_val = v * s;
    float h_prime = h * 6.0f;
    float x = c_val * (1.0f - fabs(fmod(h_prime, 2.0f) - 1.0f));
    
    float3 rgb = float3(0.0f);
    if (h_prime < 1.0f) rgb = float3(c_val, x, 0.0f);
    else if (h_prime < 2.0f) rgb = float3(x, c_val, 0.0f);
    else if (h_prime < 3.0f) rgb = float3(0.0f, c_val, x);
    else if (h_prime < 4.0f) rgb = float3(0.0f, x, c_val);
    else if (h_prime < 5.0f) rgb = float3(x, 0.0f, c_val);
    else rgb = float3(c_val, 0.0f, x);
    
    float3 result = rgb + (v - c_val);
    destination.write(float4(result, color.a), gid);
}
```

#### Step 3: Register the Effect Stage with `SSKMetalRenderer`

With the effect stage system you no longer add hard-coded methods to the renderer. Instead, create a stage and register it with a unique identifier:

```objc
SSKMetalColorShiftPass *colorShiftPass = [SSKMetalColorShiftPass new];
if ([colorShiftPass setupWithDevice:device library:_shaderLibrary]) {
    SSKMetalEffectStage *stage =
        [[SSKMetalEffectStage alloc] initWithIdentifier:@"demo.colorShift"
                                                   pass:colorShiftPass
                                                handler:^BOOL(SSKMetalRenderer *renderer,
                                                              SSKMetalPass *pass,
                                                              id<MTLCommandBuffer> commandBuffer,
                                                              id<MTLTexture> renderTarget,
                                                              NSDictionary *parameters) {
        SSKMetalColorShiftPass *shiftPass = (SSKMetalColorShiftPass *)pass;
        CGFloat hueDegrees = MAX(0.0, [parameters[@"hueShift"] doubleValue]);
        shiftPass.hueShift = fmod(hueDegrees, 360.0);
        return [shiftPass encodeColorShift:commandBuffer
                                    source:renderTarget
                              renderTarget:renderTarget
                              textureCache:renderer.textureCache];
    }];
    [self registerEffectStage:stage];
} else if ([SSKDiagnostics isEnabled]) {
    [SSKDiagnostics log:@"SSKMetalRenderer: color shift pass unavailable"];
}
```

Once registered the stage can be reconfigured or removed at runtime using `registerEffectStage:` and `unregisterEffectStageWithIdentifier:`.

#### Step 4: Use the Stage in Your Saver

```objc
- (void)renderMetalFrame:(SSKMetalRenderer *)renderer deltaTime:(NSTimeInterval)dt {
    [self.particleSystem advanceBy:dt];
    NSArray<SSKParticle *> *particles = [self.particleSystem aliveParticlesSnapshot];

    [renderer drawParticles:particles
                  blendMode:self.particleSystem.blendMode
               viewportSize:self.bounds.size];

    if (self.bloomIntensity > 0.05) {
        [renderer applyBloom:self.bloomIntensity];
    }

    if (self.hueShiftEnabled) {
        NSDictionary *params = @{ @"hueShift": @(self.currentHueShift) };
        [renderer applyEffectWithIdentifier:@"demo.colorShift" parameters:params];
    }
}
```

To chain multiple custom effects, build an ordered array of identifiers and pass it to `applyEffects:parameters:` for a consistent pipeline.

---

## Common Patterns

### Pattern 1: Optional Effect (Check Parameter)

```objc
if (self.effectStrength > 0.01) {
    [renderer applyEffect:self.effectStrength];
}
```

### Pattern 2: Chained Effects

```objc
[renderer drawParticles:...];
[renderer applyEffect1:...];      // Modifies drawable
[renderer applyEffect2:...];      // Modifies drawable (output of Effect1)
[renderer applyEffect3:...];      // Modifies drawable (output of Effect2)
```

### Pattern 3: Conditional Effect Order

```objc
// Different chain based on mode
if (self.useBloomFirst) {
    [renderer applyBloom:intensity];
    [renderer applyBlur:radius];
} else {
    [renderer applyBlur:radius];
    [renderer applyBloom:intensity];
}
```

### Pattern 4: Graceful Degradation

```objc
// Effect is optional; system handles if pass unavailable
if (bloomIntensity > 0.05) {
    [renderer applyBloom:bloomIntensity];
    // If bloom unavailable, applyBloom returns silently (checked internally)
}
```

---

## Debugging Tips

### 1. Check if Pass Initialized

Look at initialization logs:
```objc
[SSKDiagnostics setEnabled:YES];
// ... create renderer ...
// Check console for "SSKMetalRenderer: failed to set up <pass>"
```

### 2. Verify Shader Compilation

```objc
// Check Xcode build log for Metal compilation errors
// Look in Build Phases → Compile Metal Sources
```

### 3. Use Intermediate Render Targets

To see intermediate results:
```objc
// Capture the render target after each pass
id<MTLTexture> intermediateResult = [self captureCurrentRenderTarget];
// Save to disk or examine in debugger
```

### 4. Check Texture Cache Stats

```objc
// Add logging to SSKMetalTextureCache
NSLog(@"Cache has %lu buckets", (unsigned long)self.textureCache.textureBuckets.count);
```

---

## Performance Considerations

### 1. Texture Allocation Cost
- Blur: Creates 1 scratch texture per frame
- Bloom: Creates 2 temporary textures per frame
- **Solution**: Already uses texture cache

### 2. Compute Dispatch Cost
- Each applyEffect* call dispatches a compute kernel
- Kernel setup has overhead
- **Solution**: Combine passes where possible (e.g., bloom already includes blur)

### 3. Memory Bandwidth
- Reading/writing large textures is bottleneck on GPU
- Multiple passes increase bandwidth usage
- **Solution**: Use compute shaders (more cache-friendly than render passes)

### 4. Async GPU Simulation
- Recent optimization (commit be49dc9)
- Particle simulation no longer blocks CPU
- Uses completion handlers instead of waitUntilCompleted
- **Result**: Better GPU/CPU parallelism

---

## Troubleshooting

| Issue | Solution |
|-------|----------|
| Bloom not working | Ensure `bloomIntensity > 0.05` and the blur stage is available (or allow bloom's fallback blur to compile) |
| Blur has no effect | Check `radius > 0.01` |
| Effects render to wrong texture | Verify `setRenderTarget:` not used incorrectly |
| Memory leaks in texture cache | Ensure `releaseTexture:` called for all acquired textures |
| Shader function not found | Check function name in kernel matches library |
| Particles not rendered | Check `drawParticles:` called with non-empty array |
| Performance degradation | Profile texture allocation; check cache hit rate |
| Z-depth not visible | Ensure `zDepthEnabled = 1u` in spawn parameters, check `lengthMultiplier` is set on particle pass |
| GPU spawn returns 0 | Check Metal device available, verify shader library loaded, check particle capacity |
| Z-depth particles too slow | Adjust `zDepthScale` to reduce minimum z-depth (higher scale = more distant drops) |

---

## GPU-Accelerated Particle Spawning

### Using `spawnParticlesGPU:parameters:`

The particle system supports hardware-accelerated batch particle initialization via Metal compute shaders:

```objc
SSKParticleSpawnParameters params = SSKParticleSpawnParametersMake();
params.regionType = SSKParticleSpawnRegionTypeRectangle;
params.center = (vector_float2){width/2, height + 50};
params.size = (vector_float2){(float)width, 20.0f};
params.velocityXRange = (vector_float2){vx * 0.9f, vx * 1.1f};
params.velocityYRange = (vector_float2){vy * 0.9f, vy * 1.1f};
params.sizeRange = (vector_float2){2.0f, 4.0f};
params.lifeRange = (vector_float2){2.0f, 3.0f};
params.colorMin = (vector_float4){0.2f, 0.2f, 0.2f, 1.0f};
params.colorMax = (vector_float4){0.8f, 0.8f, 0.8f, 1.0f};
params.behaviorOptions = SSKParticleBehaviorOptionFadeAlpha;

// Enable z-depth for perspective effect
params.zDepthEnabled = 1u;
params.zDepthScale = 10.0f;  // Moderate depth variation
params.lengthMultiplier = 8.0f;  // Base length for rendering

NSUInteger spawned = [self.particleSystem spawnParticlesGPU:count parameters:params];
```

### Z-Depth Parameters

When `zDepthEnabled` is set:
- **Z-Depth Calculation**: Random z-depth value (minZ to 1.0) calculated per particle
  - `minZ = max(0.2, 1.0 / (zDepthScale + 1.0))`
  - Scale 1.0 → minZ ~0.5 (subtle effect)
  - Scale 100.0 → minZ ~0.2 (strong effect)
- **Velocity Scaling**: `velocity *= zDepth` (far drops move slower)
- **Length Scaling**: Applied during rendering as `length *= zDepth`
- **Color Darkening**: `brightness *= (0.3 + zDepth * 0.7)` (far drops darker)
- **Storage**: Z-depth stored in `particle.userScalar` (0.01-1.0 range)

### Performance Benefits

- **Parallel Initialization**: All particles initialized simultaneously on GPU
- **No CPU Overhead**: Z-depth calculations performed entirely on GPU
- **Async Option**: Set `synchronizesMetalSpawn = NO` for non-blocking spawn
- **Fallback**: Automatically falls back to CPU spawn if GPU unavailable

### Example: Rain Screensaver with Z-Depth

See `../Demos/Rain/RainView.m` for a complete example of z-depth usage:
- GPU spawn with z-depth enabled
- Length multiplier synchronization with renderer
- CPU fallback path with matching z-depth calculations

## Testing Your Implementation

When adding new effects or modifying existing ones, ensure you have test coverage:

### Unit Testing New Effects

1. **Create Test File**: `SSKYourEffectPassTests.m`
2. **Test Initialization**: Verify setup with device/library
3. **Test Encoding**: Verify encode method with valid/invalid inputs
4. **Test Metal Availability**: Skip tests gracefully when Metal unavailable

**Example**:
```objc
- (void)testYourEffectPassSetup {
    id<MTLDevice> device = MTLCreateSystemDefaultDevice();
    if (!device) {
        NSLog(@"Skipping test - Metal unavailable");
        return;
    }
    
    id<MTLLibrary> library = [TestHelpers loadParticleShaderLibraryWithDevice:device];
    SSKYourEffectPass *pass = [[SSKYourEffectPass alloc] init];
    XCTAssertTrue([pass setupWithDevice:device library:library]);
}
```

### Integration Testing

Test your effect in the full rendering pipeline:
```objc
- (void)testYourEffectInPipeline {
    SSKMetalRenderer *renderer = [[SSKMetalRenderer alloc] initWithDevice:device];
    // ... setup particles ...
    [renderer drawParticles:particles ...];
    [renderer applyYourEffect:...];
    [renderer endFrame];
    // Verify result
}
```

### Metal-Specific Tests

Always check Metal availability:
```objc
if (![TestHelpers loadParticleShaderLibraryWithDevice:device]) {
    NSLog(@"Skipping Metal test");
    return;
}
```

See `ARCHITECTURE_ANALYSIS.md` → "Testing Architecture" for more details.

## References

- `ARCHITECTURE_ANALYSIS.md` – Deep dive into design, includes testing architecture
- `ARCHITECTURE_DIAGRAMS.md` – Visual component relationships
- `SSKParticleSystem.md` – Detailed particle system docs
- `tutorial.md` – End-to-end saver creation guide
- `Demos/Rain/README.md` – Z-depth implementation example
- `../Tests/README.md` – Test suite documentation
- `PERFORMANCE_TESTING.md` – Performance benchmarking guide