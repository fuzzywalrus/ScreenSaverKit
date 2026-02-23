# ScreenSaverKit Effect Chaining Architecture Analysis

## Executive Summary

ScreenSaverKit uses a **FX Pass-based architecture** for composing effects. Each effect (blur, bloom, particle rendering) is a separate pass that can be chained together within a single Metal command buffer. The architecture is recent (refactored in commit 2a174b8: "Refactor SSKMetal to now have FX Passes") and focuses on sequential post-processing through a unified Metal renderer.

---

## Current Architecture Overview

### 1. Core Components

#### **SSKMetalRenderer** (Main Coordinator)
- **Location**: `../ScreenSaverKit/SSKMetalRenderer.h/m`
- **Role**: Unified Metal renderer that owns the drawable lifecycle and provides higher-level drawing entry points
- **Responsibilities**:
  - Manages command buffers and drawable fetching
  - Coordinates frame lifecycle (beginFrame/endFrame)
  - Owns all FX Pass instances
  - Routes draw calls to appropriate passes
  - Manages texture cache for intermediate renders

**Key Properties** (internal; public API exposes `particlePass`, `spritePass`, `textureCache`, `device`, `currentCommandBuffer`, `drawableSize`):
```objc
@property (nonatomic, strong, readwrite) id<MTLDevice> device;
@property (nonatomic, strong) id<MTLCommandQueue> commandQueue;
@property (nonatomic, strong, readwrite, nullable) id<MTLCommandBuffer> currentCommandBuffer;
@property (nonatomic, strong) SSKMetalParticlePass *particlePass;
@property (nonatomic, strong, nullable) SSKMetalSpritePass *spritePass;
@property (nonatomic, strong, nullable) SSKMetalBlurPass *blurPass;
@property (nonatomic, strong, nullable) SSKMetalBloomPass *bloomPass;
@property (nonatomic, strong, nullable) SSKMetalTrailPass *trailPass;
@property (nonatomic, strong) SSKMetalTextureCache *textureCache;
@property (nonatomic) BOOL needsClearOnNextPass;
```

#### **SSKMetalPass** (Abstract Base Class)
- **Location**: `../ScreenSaverKit/SSKMetalPass.h/m`
- **Role**: Abstract base for all rendering passes
- **Interface**:
```objc
@interface SSKMetalPass : NSObject
- (BOOL)setupWithDevice:(id<MTLDevice>)device;
- (void)encodeToCommandBuffer:(id<MTLCommandBuffer>)commandBuffer
                  renderTarget:(id<MTLTexture>)renderTarget
                    parameters:(NSDictionary *)params;
@property (nonatomic, copy, readonly) NSString *passName;
@end
```

### 2. Effect Passes (FX Passes)

#### **SSKMetalParticlePass**
- **Location**: `../ScreenSaverKit/SSKMetalParticlePass.h/m`
- **Inherits from**: SSKMetalPass
- **Purpose**: Render particle instances using Metal
- **Key Features**:
  - Instanced rendering with quad vertices
  - Supports two blend modes:
    - `SSKParticleBlendModeAlpha` (standard alpha compositing)
    - `SSKParticleBlendModeAdditive` (additive blending for bloom/energy)
  - Dynamic instance buffer allocation
  - Softness/feathering support via fragment shader
  - **GPU-accelerated indirect rendering** — builds instance buffer on GPU for large particle counts
  - **Per-particle rotation** — rotates quads by particle rotation angle in vertex shader
  - **Ribbon mode** — connects sequential particles into ribbon strips via fully GPU-driven pipeline

**Implementation Pattern**:
- Maintains separate render pipelines for alpha and additive blend modes
- Pre-allocates quad vertex buffer once
- Dynamically grows instance buffer as needed
- Encodes particle vertex/fragment shaders from Metal library
- **Indirect rendering pipeline**: `compactAliveIndices` → `buildInstanceData` → indirect draw (single command buffer, no CPU readback)
- **Ribbon rendering pipeline**: `compactAliveIndices` → `prepareRibbonIndirectArgs` → `buildRibbonInstanceData` → indirect draw

**Data Structure** (SSKMetalInstanceData — 56 bytes):
```objc
typedef struct {
    vector_float2 position;      // Particle world position
    vector_float2 direction;     // Direction vector (for trail orientation)
    float width;                 // Trail width
    float length;                // Trail length
    vector_float4 color;         // RGBA color
    float softness;              // Edge softness parameter
    float rotation;              // Per-particle rotation in radians
    float padding[2];            // Alignment
} SSKMetalInstanceData;
```

#### **SSKMetalTrailPass**
- **Location**: `../ScreenSaverKit/SSKMetalTrailPass.h/m`
- **Purpose**: Persistent offscreen texture for trail/persistence effects
- **Key Features**:
  - Owns a persistent trail texture (NOT in texture cache — survives trimming)
  - Each frame: fade previous contents via `trailFadeKernel` compute shader, then new particles render on top
  - Final result blitted to the drawable
  - Texture created lazily on first use, recreated on size change
- **Interface**:
  - `trailTextureForSize:` — returns or creates the persistent trail texture
  - `fadeWithRate:commandBuffer:` — multiplies all pixels by `(1.0 - fadeRate)`
  - `blitTo:destination:commandBuffer:` — copies trail texture onto destination
- **Integration with SSKMetalRenderer**:
  - Enabled via `renderer.trailPersistenceEnabled = YES`
  - Configured via `renderer.trailFadeRate` (0.0-1.0, default 0.05)
  - When enabled, particle draws are redirected to the trail texture, faded, then composited to drawable

#### **SSKMetalBlurPass**
- **Location**: `../ScreenSaverKit/SSKMetalBlurPass.h/m`
- **Inherits from**: SSKMetalPass
- **Purpose**: Separable Gaussian blur (GPU compute-based)
- **Algorithm**:
  1. Horizontal pass: source → scratch texture
  2. Vertical pass: scratch → destination
- **Uses texture cache** to avoid allocation overhead
- **Parameters**:
  - `radius`: Gaussian sigma (values <= 0.01 treated as no-op)

**Implementation Details**:
```objc
- (BOOL)encodeBlur:(id<MTLTexture>)source
        destination:(id<MTLTexture>)destination
      commandBuffer:(id<MTLCommandBuffer>)commandBuffer
       textureCache:(SSKMetalTextureCache *)textureCache
```

#### **SSKMetalBloomPass**
- **Location**: `../ScreenSaverKit/SSKMetalBloomPass.h/m`
- **Inherits from**: SSKMetalPass
- **Purpose**: Brightness threshold + blur for glow effects
- **Algorithm** (3-stage):
  1. **Threshold pass**: Extract bright pixels above threshold into `brightTexture`
  2. **Blur pass**: Blur bright pixels using SSKMetalBlurPass
  3. **Composite pass**: Blend blurred bloom back into render target

**Parameters**:
```objc
@property (nonatomic) CGFloat threshold;      // 0-1, defaults to 0.8
@property (nonatomic) CGFloat intensity;      // Bloom strength
@property (nonatomic) CGFloat blurSigma;      // Blur spread control
```

**Key Design**:
- **Blur integration** – automatically consumes the shared blur stage via the effect registry, falling back to an internal blur pass when none is available
- Uses shared texture cache from renderer
- Owns threshold and composite compute pipelines
- Manages its own intermediate textures (bright, blurred)

### 3. Metal Shader Libraries

#### **SSKParticleShaders.metal** (Rendering + Spawning + Effects)
**Location**: `../ScreenSaverKit/Shaders/SSKParticleShaders.metal`
**Compiled to**: `SSKParticleShaders.metallib`

**Shader Functions**:

1. **Particle Rendering**:
   - `particleVertex`: Transforms quad vertices to world space with orientation and per-particle rotation
   - `particleFragment`: Soft-edged disc with alpha falloff

2. **GPU Instance Building** (Indirect Rendering):
   - `compactAliveIndices`: Atomically compacts alive particle indices into contiguous buffer
   - `buildInstanceData`: Builds per-instance rendering data from particle state on GPU
   - `prepareRibbonIndirectArgs`: Prepares indirect draw arguments for ribbon mode
   - `buildRibbonInstanceData`: Builds ribbon segments connecting adjacent particles

3. **Particle Initialization**:
   - `initializeParticles`: GPU-accelerated batch particle spawning with z-depth support

4. **Blur Kernels**:
   - `gaussianBlurHorizontal`: Horizontal Gaussian convolution
   - `gaussianBlurVertical`: Vertical Gaussian convolution

5. **Bloom Kernels**:
   - `bloomThresholdKernel`: Brightness extraction
   - `bloomCompositeKernel`: Additive blend of bloom back to target

6. **Trail Persistence**:
   - `trailFadeKernel`: Multiplies all pixels by `(1.0 - fadeRate)` for trail fading

#### **SSKSimulationShaders.metal** (GPU Simulation)
**Location**: `../ScreenSaverKit/Shaders/SSKSimulationShaders.metal`
**Compiled to**: `SSKSimulationShaders.metallib`

**Shader Functions**:

1. **Particle Simulation Kernel**:
   - `simulateParticles`: Main simulation step — integrates velocity, applies gravity, damping, and feature-flagged forces

2. **Curl Noise** (when `kFeatureCurlNoise` flag set):
   - 2D simplex noise (Ashima Arts algorithm) sampled at each particle position
   - Gradient rotated 90° for divergence-free (curl) force field
   - Parameters: `noiseScale`, `noiseStrength`, `noiseSpeed`, `noiseTime`

3. **Attractor Forces** (when `kFeatureAttractors` flag set):
   - Up to 4 point attractors with inverse-square falloff
   - `force = normalize(toAttractor) * (strength / dist²) * dt`

4. **Color Gradient** (when `kFeatureColorGradient` flag set):
   - Interpolates particle color from `baseColor` to `endColor` over lifetime
   - End color packed as half-float into particle state (4 channels in 2 floats)

**Simulation Uniforms** (`SSKSimulationUniforms` — 256 bytes):
```c
typedef struct {
    vector_float2 gravity;           // Global gravity
    float dt;                        // Delta time
    float globalDamping;             // Per-second damping
    uint32_t particleCount;          // Active count
    uint32_t featureFlags;           // Bitmask: curlNoise|attractors|colorGradient|velocityHue
    float noiseScale, noiseStrength, noiseSpeed, noiseTime;
    vector_float2 attractors[4];     // Attractor positions
    float attractorStrengths[4];     // Per-attractor strength
    uint32_t attractorCount;         // Active count (0-4)
    float globalTime;                // Total elapsed time
    // ...padding to 256 bytes
} SSKSimulationUniforms;
```

**Compilation Flow**:
1. Metal source (.metal) files compiled to libraries (.metallib) via `xcrun metal`
2. Bundled as saver resources
3. Loaded at runtime by SSKMetalRenderer (rendering) and SSKParticleSystem (simulation)
4. Functions extracted by name and compiled into pipeline states
5. SSKParticleSystem falls back to runtime string compilation if simulation metallib is missing

---

## Effect Chaining Implementation

### Frame Rendering Pipeline (Typical Flow)

```
beginFrame()
  ├─ Create command buffer
  └─ Fetch next drawable

drawParticles() / drawParticlesIndirect()
  ├─ [if trail enabled] Fade trail texture via compute kernel
  ├─ [if trail enabled] Redirect rendering to trail texture
  ├─ Encode particle render pass (CPU or GPU indirect)
  │   ├─ [if indirect] compactAliveIndices → buildInstanceData → indirect draw
  │   └─ [if ribbon] compactAliveIndices → prepareRibbonArgs → buildRibbonData → indirect draw
  ├─ Set blend mode (alpha or additive)
  ├─ [if trail enabled] Blit trail texture to drawable
  └─ Mark "clear not needed"

applyBlur() [optional]
  ├─ Create compute encoder
  ├─ Encode horizontal blur (source → scratch)
  └─ Encode vertical blur (scratch → destination)

applyBloom() [optional]
  ├─ Allocate intermediate textures
  ├─ Encode threshold pass (extract bright pixels)
  ├─ Encode blur pass on bright pixels
  └─ Encode composite pass (blend back in)

endFrame()
  ├─ Present drawable
  └─ Commit command buffer
```

### Usage Example (from RibbonFlowView)

```objc
- (void)renderMetalFrame:(SSKMetalRenderer *)renderer deltaTime:(NSTimeInterval)dt {
    [self stepSimulationWithDeltaTime:dt];
    
    renderer.clearColor = MTLClearColorMake(0.0, 0.0, 0.0, 1.0);
    NSArray<SSKParticle *> *particles = [self.particleSystem aliveParticlesSnapshot];
    
    // Step 1: Draw particles
    [renderer drawParticles:particles
                  blendMode:self.particleSystem.blendMode
               viewportSize:self.bounds.size];
    
    // Step 2: Apply optional blur
    CGFloat blurRadius = self.blurRadius;
    if (blurRadius > 0.01) {
        [renderer applyBlur:blurRadius];
    }
    
    // Step 3: Apply optional bloom
    CGFloat bloomIntensity = self.bloomIntensity;
    if (bloomIntensity > 0.05) {
        renderer.bloomThreshold = self.bloomThreshold;
        renderer.bloomBlurSigma = MAX(2.0, 2.0 + blurRadius * 0.4);
        [renderer applyBloom:MIN(1.5, bloomIntensity)];
    }
}
```

### Render Target Management

The architecture uses **in-place rendering** with render target swapping:

```objc
- (id<MTLTexture>)activeRenderTarget {
    if (self.overrideRenderTarget) {
        return self.overrideRenderTarget;  // Use intermediate texture
    }
    return [self ensureCurrentDrawable].texture;  // Use drawable
}
```

**Pattern**:
1. Particles rendered directly to drawable or intermediate texture
2. Blur and bloom passes read/write to same texture in-place (using scratch textures internally)
3. SSKMetalTextureCache manages scratch texture reuse

---

## Particle System Integration

### SSKParticleSystem
- **Location**: `../ScreenSaverKit/SSKParticleSystem.h/m`
- **Dual Simulation Path**:
  - **CPU Path**: Objective-C integration with gravity, damping, curl noise, attractors, color gradient
  - **GPU Path**: Metal compute kernel (`SSKSimulationShaders.metal`) with feature-flagged forces
- **Dual Rendering Path**:
  - **CPU Path**: CoreGraphics rendering to CGContext
  - **GPU Path**: Metal render pass for instanced drawing (direct or indirect)

**Key Properties**:
```objc
@property (nonatomic) SSKParticleBlendMode blendMode;     // Alpha or Additive
@property (nonatomic) NSPoint gravity;
@property (nonatomic) CGFloat globalDamping;
@property (nonatomic) CGFloat lengthMultiplier;            // For z-depth rendering
@property (nonatomic, copy) SSKParticleUpdater updateHandler;  // Custom CPU updates
@property (nonatomic, copy) SSKParticleRenderer renderHandler; // Custom CPU render
@property (nonatomic) BOOL metalSimulationEnabled;
@property (nonatomic) BOOL synchronizesMetalSimulation;   // Control GPU sync
@property (nonatomic) BOOL synchronizesMetalSpawn;         // Control GPU spawn sync
@property (nonatomic, readonly) NSUInteger aliveParticleCount;
@property (nonatomic) BOOL ribbonModeEnabled;              // Connected ribbon strips
// Curl noise properties
@property (nonatomic) CGFloat noiseScale;                  // Default 0.003
@property (nonatomic) CGFloat noiseStrength;               // Default 0.0 (opt-in)
@property (nonatomic) CGFloat noiseSpeed;                  // Default 0.5
```

**Behavior Options** (bitmask on each particle):
```objc
SSKParticleBehaviorOptionFadeAlpha      = 1 << 0,  // Fade alpha over lifetime
SSKParticleBehaviorOptionFadeSize       = 1 << 1,  // Interpolate size over lifetime
SSKParticleBehaviorOptionColorGradient  = 1 << 2,  // Interpolate baseColor → endColor
SSKParticleBehaviorOptionCurlNoise      = 1 << 3,  // Apply curl noise force field
SSKParticleBehaviorOptionAttractors     = 1 << 4,  // Apply attractor point forces
SSKParticleBehaviorOptionVelocityHue    = 1 << 5,  // Map velocity to hue
SSKParticleBehaviorOptionRibbonMode     = 1 << 6,  // Connected ribbon strips
```

**Attractor Points** (up to 4):
```objc
- (void)setAttractorAtIndex:(NSUInteger)index position:(NSPoint)position strength:(CGFloat)strength;
- (void)clearAttractors;
@property (nonatomic, readonly) NSUInteger attractorCount;
```

**Particle State** (`SSKParticleState` — 128 bytes):
- Core fields: position, velocity, life, maxLife, size, baseSize, rotation, rotationVelocity
- Color fields: baseColor (4 floats), endColor (packed as 2 half-float pairs)
- Behavior: behaviorOptions bitmask, sizeOverLifeRange, damping
- User data: userVector, userScalar

**GPU-Accelerated Particle Spawning**:
- `spawnParticlesGPU:parameters:` - Hardware-accelerated batch particle initialization
- Uses Metal compute shader (`initializeParticles` kernel) for parallel initialization
- Supports parameterized spawning with `SSKParticleSpawnParameters` struct
- **Z-Depth Support**: GPU spawn can calculate z-depth values for perspective effects
- **End Color Support**: `endColorMin`/`endColorMax` in spawn parameters for color gradient
- Thread group sizing optimized for GPU architecture (threadExecutionWidth × 8)
- Asynchronous spawn option via `synchronizesMetalSpawn` property
- Fallback kernel compilation if shader missing from library

**Rendering through Metal**:
```objc
- (BOOL)renderWithMetalRenderer:(SSKMetalParticleRenderer *)renderer
                       blendMode:(SSKParticleBlendMode)blendMode
                    viewportSize:(CGSize)viewportSize
```

### SSKMetalParticleRenderer
- **Location**: `../ScreenSaverKit/SSKMetalParticleRenderer.h/m`
- **Purpose**: Convenient wrapper around SSKMetalRenderer for particle-only workflows
- **Additional Properties**:
  ```objc
  @property (nonatomic) MTLClearColor clearColor;
  @property (nonatomic) CGFloat blurRadius;      // Post-process blur
  @property (nonatomic) CGFloat bloomIntensity;  // Post-process bloom
  @property (nonatomic) CGFloat bloomThreshold;
  @property (nonatomic) CGFloat bloomBlurSigma;
  ```

**Frame Rendering Sequence**:
```objc
- (BOOL)renderParticles:(NSArray<SSKParticle *> *)particles
              blendMode:(SSKParticleBlendMode)blendMode
           viewportSize:(CGSize)viewportSize {
    [self.renderer beginFrame];
    [self.renderer drawParticles:particles blendMode:blendMode viewportSize:viewportSize];
    if (self.blurRadius > 0.01) {
        [self.renderer applyBlur:self.blurRadius];
    }
    if (self.bloomIntensity > 0.01) {
        [self.renderer applyBloom:self.bloomIntensity];
    }
    [self.renderer endFrame];
    return YES;
}
```

---

## Texture Cache Strategy

### SSKMetalTextureCache
- **Location**: `../ScreenSaverKit/SSKMetalTextureCache.h/m`
- **Purpose**: Avoid per-frame texture allocation overhead
- **Storage**:
  - Hash buckets keyed by (width, height, pixelFormat, usage)
  - NSHashTable for efficient pool lookup
  - Insertion-order array for LRU trimming

**Usage in Blur Pass**:
```objc
MTLTextureUsage usage = MTLTextureUsageShaderRead | MTLTextureUsageShaderWrite;
id<MTLTexture> scratch = [textureCache acquireTextureMatchingTexture:source usage:usage];
// ... encode blur work ...
[textureCache releaseTexture:scratch];
```

**Usage in Bloom Pass**:
```objc
id<MTLTexture> brightTexture = [textureCache acquireTextureMatchingTexture:source usage:usage];
id<MTLTexture> blurredTexture = [textureCache acquireTextureMatchingTexture:source usage:usage];
// ... multi-stage processing ...
[textureCache releaseTexture:brightTexture];
[textureCache releaseTexture:blurredTexture];
```

---

## Adding New Effects: Design Patterns

### Pattern 1: Create a New FX Pass Class

```objc
@interface SSKMetalCustomPass : SSKMetalPass
@property (nonatomic) CGFloat customParam;
- (BOOL)setupWithDevice:(id<MTLDevice>)device library:(id<MTLLibrary>)library;
- (BOOL)encodeCustomEffect:(id<MTLCommandBuffer>)commandBuffer
                    source:(id<MTLTexture>)source
              renderTarget:(id<MTLTexture>)renderTarget
              textureCache:(SSKMetalTextureCache *)textureCache;
@end
```

**Implementation Steps**:
1. Inherit from SSKMetalPass
2. Load shader functions in `setupWithDevice:library:`
3. Create compute/render pipeline states
4. Implement `encodeCustomEffect:` to dispatch compute/render work
5. Return BOOL success status

### Pattern 2: Register Pass with SSKMetalRenderer

```objc
// In SSKMetalRenderer.m initialization:
_customPass = [SSKMetalCustomPass new];
if (![_customPass setupWithDevice:device library:_shaderLibrary]) {
    [SSKDiagnostics log:@"SSKMetalRenderer: custom pass failed to setup"];
    _customPass = nil;
}

// Add public method:
- (void)applyCustomEffect:(CGFloat)param {
    if (!self.customPass) return;
    // ... encode work ...
}
```

### Pattern 3: Chain in Frame Rendering

```objc
// In user code:
[renderer drawParticles:particles blendMode:mode viewportSize:size];
[renderer applyBlur:blurRadius];
[renderer applyCustomEffect:customParam];
[renderer applyBloom:bloomIntensity];
```

---

## Coupling and Architectural Issues

### Current Coupling Issues

1. **SSKMetalBloomPass → SSKMetalBlurPass Dependency** ✅
   - Bloom now resolves a shared blur stage from the effect registry at encode time
   - Falls back to an internal blur implementation when no shared stage is registered
   ```objc
   - (void)setSharedBlurPass:(nullable SSKMetalBlurPass *)blurPass;
   ```
   - **Result**: Bloom no longer requires constructor injection and works even when blur is omitted

2. **Renderer Owns All Passes** ⚠️
   - SSKMetalRenderer is responsible for creating and managing all passes
   - Makes it hard to conditionally enable effects or swap implementations
   - Adding a new effect requires modifying SSKMetalRenderer
   - **Better approach**: Pass registry or dependency injection

3. **No Effect Order Flexibility** ⚠️
   - Effect chain is hardcoded in usage (particles → blur → bloom)
   - Cannot reorder effects (e.g., bloom before blur)
   - Each effect is aware of texture cache but not of other effects
   - **Better approach**: Composable pass chain with configurable order

4. **Limited Intermediate Rendering Support**
   - `setRenderTarget:` exists but is rarely used
   - No built-in support for reading from one texture while writing to another
   - Some passes make assumptions about in-place rendering

### Data Flow Complexity

```
Particles → ParticlePass → RenderTarget (drawable)
                    ↓
              [needsClearOnNextPass flag]
                    ↓
           BlurPass (if radius > 0.01)
                    ↓
           BloomPass (if intensity > 0.05)
                    ↓
              Command Buffer
                    ↓
              Present Drawable
```

**Issues**:
- Clear behavior depends on flag set by particle pass
- Each pass must handle its own texture allocation
- No unified configuration format for all passes
- Parameter passing via direct property setters (not batch-safe)

### Recent Refactoring Notes (Commit 2a174b8)

**"Refactor SSKMetal to now have FX Passes"**

This commit introduced:
- Unified SSKMetalPass base class (abstract)
- Individual pass implementations (Particle, Blur, Bloom)
- Renderer coordination of passes
- Texture cache sharing

**What it fixed**:
- Separated concerns (each pass is independent)
- Enabled reusable passes
- Centralized shader library loading

**What remains**:
- Tight coupling between bloom and blur
- Renderer-centric architecture (doesn't scale to many effects)
- No effect scheduling/ordering system

---

## Recent Optimizations

### Commit be49dc9: Async GPU Simulation
- **Title**: "Dropped the blocking waitUntilCompleted from SSKParticleSystem and register a completion handler instead, so the GPU simulation runs asynchronously while the CPU keeps working"
- **Impact**: 
  - CPU no longer blocks waiting for GPU particle simulation
  - Uses `addCompletedHandler:` instead of `waitUntilCompleted`
  - Enables true parallelism between CPU and GPU

### Commit 02d119e: Bloom Intensity
- **Addition**: Configurable bloom intensity parameter
- **Impact**: Finer control over glow effect strength

---

## Integration Points

### 1. With SSKScreenSaverView

```objc
// Savers don't typically interact with SSKMetalRenderer directly
// Instead they use SSKMetalParticleRenderer at the view level
- (void)renderMetalFrame:(SSKMetalRenderer *)renderer deltaTime:(NSTimeInterval)dt {
    // Provided as optional override for savers using Metal
}
```

### 2. With SSKParticleSystem

```objc
NSArray<SSKParticle *> *particles = [self.particleSystem aliveParticlesSnapshot];
[renderer drawParticles:particles blendMode:mode viewportSize:size];
```

### 3. With Preferences

Effects are typically controlled via preferences:
```objc
kPrefBlurRadius: @(0.0)
kPrefBloomIntensity: @(0.75)
kPrefBloomThreshold: @(0.65)
```

---

## Summary: Design Strengths and Weaknesses

### Strengths ✓
- **Clean separation**: Each pass is independent and reusable
- **Shader library abstraction**: Separate Metal libraries for rendering and simulation
- **Efficient texture pooling**: Avoids per-frame allocation overhead
- **Async GPU work**: Particle simulation doesn't block CPU
- **Dual rendering paths**: CPU and Metal options for particles
- **Flexible parameters**: Effects configured via properties, not enums
- **GPU-accelerated spawning**: Hardware-accelerated batch particle initialization
- **Z-depth support**: Perspective effects calculated entirely on GPU
- **Optimized thread groups**: Dynamic sizing based on GPU architecture
- **Thread-safe index management**: Serial queue for free-list updates
- **Curl noise force field**: Divergence-free 2D noise for organic, swirling motion
- **Attractor points**: Up to 4 configurable point attractors with inverse-square falloff
- **Trail persistence**: Persistent offscreen texture for long luminous trails
- **Color gradient**: Half-float packed endColor for smooth lifetime color transitions
- **Per-particle rotation**: Rotation velocity integrated on GPU, applied in vertex shader
- **Ribbon mode**: Fully GPU-driven connected strip rendering (no CPU readback)
- **Indirect rendering**: GPU-side instance buffer building for large particle counts

### Weaknesses ✗
- **Bloom-Blur coupling**: **RESOLVED** – bloom now resolves the blur stage dynamically via the effect registry and falls back to its own blur implementation when necessary.
- **Renderer-centric design**: Doesn't scale to many effects
- **No effect ordering**: Chain is hardcoded
- **Limited parameter schemas**: No unified config format
- **Manual pass enabling**: Must check parameters and conditionally call apply*
- **Texture cache ownership**: Centralized in renderer, hard to customize

### Recommended Improvements
1. Decouple bloom from blur (use internal blur or separate blur concern)
2. Introduce effect chain/registry pattern for dynamic effect composition
3. Standardize pass parameters (e.g., EffectParameters protocol)
4. Add configuration validation and error recovery
5. Support effect ordering via configuration
6. Consider metal pass graph API (Metal 3.1+) for better scheduling

---

## Testing Architecture

### Test Suite Overview

ScreenSaverKit includes a comprehensive test suite using XCTest framework, located in `../Tests/`. The test architecture mirrors the component structure and provides both unit and integration testing.

**Test Organization**:
- **Unit Tests**: Component-level tests for individual classes
- **Integration Tests**: Cross-component interaction tests
- **Performance Tests**: Benchmarking tools (see `PERFORMANCE_TESTING.md`)
- **Metal Tests**: GPU-specific tests (skip automatically when Metal unavailable)

### Test Components

#### SSKParticleSystemTests (51 tests)
- **Location**: `../Tests/SSKParticleSystemTests.m`
- **Coverage**:
  - Initialization and capacity management
  - Particle spawning (CPU and GPU paths)
  - Particle lifecycle (spawn, update, expiration)
  - Index management and free-list reuse
  - Behavior options (fade alpha, fade size, color gradient, combined bitmasks)
  - Metal simulation vs CPU simulation parity
  - **Color gradient**: CPU behavior, CPU/GPU parity, GPU spawn with endColor parameters
  - **Curl noise**: Property defaults, configuration, zero-strength edge case, deflection verification
  - **Attractor points**: Single/multiple attractors, max count, strength comparison, clear
  - **Combined forces**: Curl noise + attractors simultaneously
  - **Per-particle rotation**: Rotation velocity integration, rotation value preservation
  - **Ribbon mode**: Property toggle
  - **GPU spawn with z-depth**: Z-depth parameter encoding and userScalar storage
  - **GPU spawn without z-depth**: Length multiplier sentinel encoding
- **Metal-Specific Tests**: Automatically skip when Metal unavailable

#### SSKMetalRendererTests (8 tests)
- **Location**: `../Tests/SSKMetalRendererTests.m`
- **Coverage**:
  - Device creation and initialization
  - Texture cache functionality
  - Frame lifecycle (begin/end)
  - Effect stage register/unregister
  - **Trail persistence**: Default property values, configuration readback
  - **Indirect rendering**: Property toggle
  - Graceful fallback when Metal unavailable

#### SSKMetalPassTests (12 tests)
- **Location**: `../Tests/SSKMetalPassTests.m`
- **Coverage**:
  - Particle pass: setup, encode, ribbon mode property, length multiplier property
  - Blur pass: setup and encode
  - Bloom pass: setup and encode
  - **Trail pass**: Initialization, texture creation, texture reuse for same size,
    texture recreation on size change, zero-size returns nil, fade kernel encodes,
    blit encodes

#### SSKVectorMathTests
- **Location**: `../Tests/SSKVectorMathTests.m`
- **Coverage**:
  - Vector operations (addition, subtraction, scaling)
  - Vector length and normalization
  - Dot product calculations
  - Edge cases (zero vectors, small vectors)

#### SSKColorPaletteTests
- **Location**: `../Tests/SSKColorPaletteTests.m`
- **Coverage**:
  - Palette creation and factory methods
  - Empty and single-color palettes

#### SSKSpriteTests
- **Location**: `../Tests/SSKSpriteTests.m`
- **Coverage**:
  - Sprite encoding and viewportPixels
  - SSKMetalSpritePass integration (when Metal available)

### Test Infrastructure

#### TestHelpers
- **Location**: `../Tests/TestHelpers.h/m`
- **Utilities**:
  - `createTempDirectory` - Temporary directory management
  - `assertPoint:approximatelyEquals:epsilon:` - Floating-point point comparison
  - `assertFloat:approximatelyEquals:epsilon:` - Floating-point comparison
  - `waitForCondition:timeout:` - Async condition waiting
  - `loadParticleShaderLibraryWithDevice:` - Metal shader library loading for tests

#### Test Build System
- **Location**: `../Tests/Makefile`
- **Features**:
  - Standalone build system (no Xcode project required)
  - Supports both arm64 and x86_64 architectures
  - Links against required frameworks (Metal, XCTest, etc.)
  - Generates `.xctest` bundle for execution

### Running Tests

**Command Line**:
```bash
cd Tests
make test
```

**Xcode**:
- Open project in Xcode
- Create test scheme if needed
- Press Cmd+U to run all tests

### Test Coverage by Component

| Component | Unit Tests | Integration Tests | Metal Tests | Notes |
|-----------|------------|-------------------|-------------|-------|
| SSKParticleSystem | ✓ (51) | ✓ | ✓ | Curl noise, attractors, color gradient, rotation, ribbon mode |
| SSKMetalRenderer | ✓ (8) | - | ✓ | Trail persistence, indirect rendering, effect stages |
| SSKMetalPass | ✓ (12) | - | ✓ | Particle, blur, bloom, trail pass encode tests |
| SSKMetalTrailPass | ✓ | - | ✓ | Texture lifecycle, fade kernel, blit |
| SSKVectorMath | ✓ (18) | - | - | Pure math, no Metal dependency |
| SSKColorPalette | ✓ (4) | - | - | No Metal dependency |
| SSKSprite | ✓ (52) | - | ✓ | Sprite rendering, animation, z-sorting |

### Testing Patterns

1. **Metal Availability Checks**: Tests that require Metal automatically skip when unavailable
   ```objc
   if (![TestHelpers loadParticleShaderLibraryWithDevice:device]) {
       NSLog(@"Skipping Metal test - Metal unavailable");
       return;
   }
   ```

2. **Async Testing**: Uses `waitForCondition:timeout:` for GPU completion handlers
   ```objc
   BOOL completed = [SSKTestHelpers waitForCondition:^BOOL{
       return particleCount > 0;
   } timeout:2.0];
   ```

3. **Floating-Point Comparison**: Uses epsilon-based comparison for particle positions/velocities
   ```objc
   [SSKTestHelpers assertPoint:particle.position 
            approximatelyEquals:expectedPosition 
                       epsilon:0.001];
   ```

### Performance Testing

Separate from unit tests, performance testing is documented in `PERFORMANCE_TESTING.md` and includes:
- **Performance Benchmark Screensaver**: Real-time FPS/metrics visualization
- **Standalone Benchmark Tool**: Automated regression testing
- **Metrics**: FPS, frame time, particle spawn time, GPU utilization

### Test Maintenance

When adding new features:
1. Add unit tests for new functionality
2. Add Metal-specific tests if GPU-accelerated (with availability checks)
3. Update test coverage documentation
4. Ensure tests pass on both architectures (arm64, x86_64)

**Recent Test Additions**:
- Color gradient behavior tests (CPU, CPU/GPU parity, GPU spawn with endColor)
- Curl noise tests (defaults, configuration, zero-strength, deflection)
- Attractor tests (single, multiple, max count, strength comparison, clear, combined with noise)
- Per-particle rotation tests (velocity integration, value preservation)
- Ribbon mode property test
- Behavior option bitmask combination test
- Trail pass tests (init, texture lifecycle, fade encode, blit encode)
- Trail persistence property tests on renderer
- Indirect rendering property test
- Z-depth GPU spawn tests (verify userScalar encoding)
- Length multiplier sentinel tests
