# ScreenSaverKit Effect Chaining Architecture Analysis

## Executive Summary

ScreenSaverKit uses a **FX Pass-based architecture** for composing effects. Each effect (blur, bloom, particle rendering) is a separate pass that can be chained together within a single Metal command buffer. The architecture is recent (refactored in commit 2a174b8: "Refactor SSKMetal to now have FX Passes") and focuses on sequential post-processing through a unified Metal renderer.

---

## Current Architecture Overview

### 1. Core Components

#### **SSKMetalRenderer** (Main Coordinator)
- **Location**: `/Users/greg/Development/ScreenSaverKit/ScreenSaverKit/SSKMetalRenderer.h/m`
- **Role**: Unified Metal renderer that owns the drawable lifecycle and provides higher-level drawing entry points
- **Responsibilities**:
  - Manages command buffers and drawable fetching
  - Coordinates frame lifecycle (beginFrame/endFrame)
  - Owns all FX Pass instances
  - Routes draw calls to appropriate passes
  - Manages texture cache for intermediate renders

**Key Properties**:
```objc
@property (nonatomic, strong, readwrite) id<MTLDevice> device;
@property (nonatomic, strong) id<MTLCommandQueue> commandQueue;
@property (nonatomic, strong, readwrite, nullable) id<MTLCommandBuffer> currentCommandBuffer;
@property (nonatomic, strong) SSKMetalParticlePass *particlePass;
@property (nonatomic, strong, nullable) SSKMetalBlurPass *blurPass;
@property (nonatomic, strong, nullable) SSKMetalBloomPass *bloomPass;
@property (nonatomic, strong) SSKMetalTextureCache *textureCache;
@property (nonatomic) BOOL needsClearOnNextPass;
```

#### **SSKMetalPass** (Abstract Base Class)
- **Location**: `/Users/greg/Development/ScreenSaverKit/ScreenSaverKit/SSKMetalPass.h/m`
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
- **Location**: `/Users/greg/Development/ScreenSaverKit/ScreenSaverKit/SSKMetalParticlePass.h/m`
- **Inherits from**: SSKMetalPass
- **Purpose**: Render particle instances using Metal
- **Key Features**:
  - Instanced rendering with quad vertices
  - Supports two blend modes:
    - `SSKParticleBlendModeAlpha` (standard alpha compositing)
    - `SSKParticleBlendModeAdditive` (additive blending for bloom/energy)
  - Dynamic instance buffer allocation
  - Softness/feathering support via fragment shader

**Implementation Pattern**:
- Maintains separate render pipelines for alpha and additive blend modes
- Pre-allocates quad vertex buffer once
- Dynamically grows instance buffer as needed
- Encodes particle vertex/fragment shaders from Metal library

**Data Structure** (SSKMetalInstanceData):
```objc
typedef struct {
    vector_float2 position;      // Particle world position
    vector_float2 direction;     // Direction vector (for trail orientation)
    float width;                 // Trail width
    float length;                // Trail length
    vector_float4 color;         // RGBA color
    float softness;              // Edge softness parameter
    float padding[3];            // Alignment
} SSKMetalInstanceData;
```

#### **SSKMetalBlurPass**
- **Location**: `/Users/greg/Development/ScreenSaverKit/ScreenSaverKit/SSKMetalBlurPass.h/m`
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
- **Location**: `/Users/greg/Development/ScreenSaverKit/ScreenSaverKit/SSKMetalBloomPass.h/m`
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

### 3. Metal Shader Library

**Location**: `/Users/greg/Development/ScreenSaverKit/ScreenSaverKit/Shaders/SSKParticleShaders.metal`

**Compiled to**: `SSKParticleShaders.metallib` (in bundle)

**Shader Functions**:

1. **Particle Rendering**:
   - `particleVertex`: Transforms quad vertices to world space with orientation
   - `particleFragment`: Soft-edged disc with alpha falloff
   
2. **Blur Kernels**:
   - `gaussianBlurHorizontal`: Horizontal Gaussian convolution
   - `gaussianBlurVertical`: Vertical Gaussian convolution
   
3. **Bloom Kernels**:
   - `bloomThresholdKernel`: Brightness extraction
   - `bloomCompositeKernel`: Additive blend of bloom back to target

**Compilation Flow**:
1. Metal source (.metal) compiled to library (.metallib)
2. Bundled as app resource
3. Loaded at runtime by SSKMetalRenderer
4. Functions extracted by name and compiled into pipeline states

---

## Effect Chaining Implementation

### Frame Rendering Pipeline (Typical Flow)

```
beginFrame()
  ├─ Create command buffer
  └─ Fetch next drawable
  
drawParticles()
  ├─ Encode particle render pass
  ├─ Set blend mode (alpha or additive)
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
- **Location**: `/Users/greg/Development/ScreenSaverKit/ScreenSaverKit/SSKParticleSystem.h/m`
- **Dual Rendering Path**:
  - **CPU Path**: CoreGraphics rendering to CGContext
  - **GPU Path**: Metal compute shader for simulation + render pass for drawing

**Key Properties**:
```objc
@property (nonatomic) SSKParticleBlendMode blendMode;     // Alpha or Additive
@property (nonatomic) NSPoint gravity;
@property (nonatomic) CGFloat globalDamping;
@property (nonatomic, copy) SSKParticleUpdater updateHandler;  // Custom CPU updates
@property (nonatomic, copy) SSKParticleRenderer renderHandler; // Custom CPU render
@property (nonatomic) BOOL metalSimulationEnabled;
@property (nonatomic, readonly) NSUInteger aliveParticleCount;
```

**Rendering through Metal**:
```objc
- (BOOL)renderWithMetalRenderer:(SSKMetalParticleRenderer *)renderer
                       blendMode:(SSKParticleBlendMode)blendMode
                    viewportSize:(CGSize)viewportSize
```

### SSKMetalParticleRenderer
- **Location**: `/Users/greg/Development/ScreenSaverKit/ScreenSaverKit/SSKMetalParticleRenderer.h/m`
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
- **Location**: `/Users/greg/Development/ScreenSaverKit/ScreenSaverKit/SSKMetalTextureCache.h/m`
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
- **Shader library abstraction**: Single Metal library for all kernels
- **Efficient texture pooling**: Avoids per-frame allocation overhead
- **Async GPU work**: Particle simulation doesn't block CPU
- **Dual rendering paths**: CPU and Metal options for particles
- **Flexible parameters**: Effects configured via properties, not enums

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
