# ScreenSaverKit Architecture Diagrams

## 1. Component Hierarchy

```
SSKMetalRenderer (Coordinator)
  ├─ SSKMetalParticlePass
  │   ├─ particleVertex shader
  │   ├─ particleFragment shader
  │   └─ Render pipelines (alpha & additive)
  │
  ├─ SSKMetalBlurPass
  │   ├─ gaussianBlurHorizontal kernel
  │   ├─ gaussianBlurVertical kernel
  │   └─ Compute pipelines (2x)
  │
  ├─ SSKMetalBloomPass
  │   ├─ bloomThresholdKernel
  │   ├─ bloomCompositeKernel
  │   ├─ SSKMetalBlurPass (shared instance) ← DEPENDENCY
  │   └─ Compute pipelines (2x)
  │
  ├─ SSKMetalTextureCache
  │   └─ Pooled intermediate textures
  │
  ├─ id<MTLCommandBuffer> currentCommandBuffer
  ├─ id<MTLDevice> device
  └─ id<MTLCommandQueue> commandQueue
```

## 2. Frame Rendering Pipeline

```
┌──────────────────────────────────────────────────────────────┐
│ SSKMetalRenderer renderFrame(particles, options)              │
└──────────────────────────────────────────────────────────────┘
                           │
                           ▼
        ┌─────────────────────────────────────┐
        │ beginFrame()                         │
        │ - Create command buffer              │
        │ - Fetch next drawable                │
        │ - Reset render target override       │
        └─────────────────────────────────────┘
                           │
                           ▼
        ┌─────────────────────────────────────┐
        │ drawParticles()                      │
        │ - Encode particle render pass        │
        │ - Set viewport & blend mode          │
        │ - Clear if needed                    │
        │ - Set needsClearOnNextPass = NO      │
        └─────────────────────────────────────┘
                           │
                ┌──────────┴──────────┐
                │                     │
                ▼ (if blur > 0.01)    │
        ┌──────────────────────┐      │
        │ applyBlur()          │      │
        │ - Horiz blur kernel  │      │
        │ - Vert blur kernel   │      │
        │ - Use texture cache  │      │
        └──────────────────────┘      │
                │                     │
                ▼                     │
        ┌──────────────────────┐      │
        │ applyBloom()         │◄─────┘
        │ - Threshold kernel   │
        │ - Blur bright pixels │
        │ - Composite kernel   │
        │ - Allocate temps     │
        └──────────────────────┘
                │
                ▼
        ┌─────────────────────────────────────┐
        │ endFrame()                           │
        │ - Present drawable                   │
        │ - Commit command buffer              │
        │ - Reset state for next frame         │
        └─────────────────────────────────────┘
```

## 3. Texture Flow in Effect Chain

```
                 [Drawable Texture]
                         │
                         ▼
              ┌──────────────────────┐
              │ Particle Render Pass │
              │ (render pipeline)    │
              └──────────────────────┘
                         │
                         ▼
                   [Drawable Texture]  ◄─── Particles written directly to drawable
                         │
              ┌──────────┴───────────┐
              │                      │
              ▼ (if blur)            │
          ┌─────────────┐            │
          │ Acquire     │            │
          │ Scratch tex │            │
          └─────────────┘            │
              │                      │
              ├─ H-blur: drawable → scratch
              ├─ V-blur: scratch → drawable
              │                      │
              └──────┬───────────────┘
                     │
                     ▼
              [Blurred Drawable]  ◄─── In-place blur on same texture
                     │
         ┌───────────┴──────────┐
         │ (if bloom)           │
         ▼                      │
    Allocate:                   │
    - brightTex          (cache)│
    - blurredTex         (cache)│
         │                      │
         ├─ Threshold: drawable → brightTex
         ├─ Blur: brightTex → blurredTex
         ├─ Composite: blend blurredTex onto drawable
         │                      │
         └──────────┬───────────┘
                    │
                    ▼
            [Bloom + Blur Result]
                    │
                    ▼
          Commit to Command Buffer
```

## 4. Particle System Rendering Paths

```
┌─────────────────────────┐
│ SSKParticleSystem       │
│ (CPU-side particle data)│
└─────────────────────────┘
           │
    ┌──────┴──────┐
    │             │
    ▼             ▼
CPU Path      GPU Path
(CGContext)   (Metal)
    │             │
    │             ▼
    │   SSKMetalParticleRenderer
    │         │
    │         ├─ Core: SSKMetalRenderer
    │         │
    │         ├─ Frame sequence:
    │         │  ├─ beginFrame()
    │         │  ├─ drawParticles()
    │         │  ├─ applyBlur() [opt]
    │         │  ├─ applyBloom() [opt]
    │         │  └─ endFrame()
    │         │
    │         └─ Properties:
    │            ├─ clearColor
    │            ├─ blurRadius
    │            ├─ bloomIntensity
    │            ├─ bloomThreshold
    │            └─ bloomBlurSigma
    │
    ▼
Composite to screen
```

## 5. Metal Shader Organization

```
SSKParticleShaders.metal (source)
         │
         ├─ Particle Vertex Shader
         │  └─ particleVertex()
         │     - Transform quad vertices
         │     - Apply softness falloff
         │
         ├─ Particle Fragment Shader
         │  └─ particleFragment()
         │     - Compute soft disc with Gaussian
         │
         ├─ Blur Compute Kernels
         │  ├─ gaussianBlurHorizontal()
         │  │  └─ 1D horizontal convolution
         │  └─ gaussianBlurVertical()
         │     └─ 1D vertical convolution
         │
         └─ Bloom Compute Kernels
            ├─ bloomThresholdKernel()
            │  └─ Extract bright pixels
            └─ bloomCompositeKernel()
               └─ Additive blend onto target

                      │
                      ▼
                 Compile (xcrun)
                      │
                      ▼
         SSKParticleShaders.metallib
            (Bundled resource)
                      │
                      ▼
         SSKMetalRenderer.loadDefaultLibrary()
                      │
                      ▼
        Extract functions by name:
        - newFunctionWithName:@"particleVertex"
        - newFunctionWithName:@"particleFragment"
        - newFunctionWithName:@"gaussianBlurHorizontal"
        - newFunctionWithName:@"gaussianBlurVertical"
        - newFunctionWithName:@"bloomThresholdKernel"
        - newFunctionWithName:@"bloomCompositeKernel"
                      │
                      ▼
        Create pipeline/compute states
```

## 6. Texture Cache Management

```
SSKMetalTextureCache
     │
     ├─ textureBuckets
     │  └─ NSMutableDictionary<NSNumber, NSHashTable<MTLTexture>>
     │     │
     │     Key: (width, height, pixelFormat, usage)
     │     Value: Pool of reusable textures
     │
     └─ allTexturesInInsertionOrder
        └─ Track for LRU trimming

Usage Flow:

┌─────────────────────────────────────┐
│ Blur Pass needs scratch texture     │
└─────────────────────────────────────┘
        │
        ▼
┌─────────────────────────────────────┐
│ acquireTextureMatchingTexture()     │
│ - Compute key from source texture   │
│ - Check bucket for cached texture   │
└─────────────────────────────────────┘
        │
    ┌───┴───┐
    │       │
    YES     NO
    │       │
    ▼       ▼
  Reuse   Create
  (pool)  (device)
    │       │
    └───┬───┘
        │
        ▼
┌─────────────────────────────────────┐
│ Use texture in compute kernel       │
└─────────────────────────────────────┘
        │
        ▼
┌─────────────────────────────────────┐
│ releaseTexture()                    │
│ - Return to pool for next frame     │
└─────────────────────────────────────┘
```

## 7. Dependency Graph (Current)

```
SSKMetalRenderer
    │
    ├─→ SSKMetalParticlePass
    │
    ├─→ SSKMetalBlurPass
    │
    ├─→ SSKMetalBloomPass
    │   │
    │   └──→ SSKMetalBlurPass (SHARED) ◄──── TIGHT COUPLING ⚠️
    │
    ├─→ SSKMetalTextureCache
    │
    ├─→ MTLDevice
    │
    └─→ MTLLibrary (SSKParticleShaders)

User Code (e.g., RibbonFlowView)
    │
    └─→ SSKMetalRenderer
        ├─ Call: drawParticles()
        ├─ Call: applyBlur() [conditional]
        └─ Call: applyBloom() [conditional]
```

## 8. Recent Changes Timeline

```
be49dc9 ← Current: Async GPU simulation
  │ "Dropped blocking waitUntilCompleted, use completion handler"
  │ Impact: CPU/GPU parallelism
  │
02d119e
  │ "Adding bloom intensity"
  │ Impact: Configurable bloom strength
  │
4a3ff3c
  │ "Create parallelism between GPU and CPU"
  │
a0e472a
  │ "Optimization"
  │
2a174b8 ← Key refactor: "Refactor SSKMetal to now have FX Passes"
  │ Introduction of:
  │  ├─ SSKMetalPass base class
  │  ├─ Individual pass implementations
  │  ├─ Renderer coordination
  │  └─ Texture cache
  │
204e50a
  │ "Entire refactor of pixel pipeline"
  │
534d46d ← Previous: "Metal update"
```

## 9. Effect Chain Ordering (Current Hardcoded)

```
Start
  │
  ├─ [REQUIRED] drawParticles() ────────┐
  │                                      │
  ├─ [OPTIONAL] applyBlur() ─────────┐  │
  │                                   │  │
  ├─ [OPTIONAL] applyBloom() ◄───────┘  │
  │                                      │
  └─ endFrame() ◄──────────────────────┘

Constraints:
- Particle pass MUST be first (sets up clear)
- Blur and Bloom are independent (can be reordered)
- Bloom can only run if Bloom pass initialized
- Blur can only run if Blur pass initialized
- Effect chain cannot be configured dynamically

Desired (Future):
  Effect chain configuration
       │
       ▼
  [1] ParticlePass
  [2] BlurPass
  [3] BloomPass
  [4] (Custom effects)
  [5] endFrame()
```

## 10. Class Relationships

```
┌──────────────────────────────┐
│    SSKMetalPass (abstract)   │
│  ──────────────────────────  │
│ + setupWithDevice()          │
│ + encodeToCommandBuffer()    │
│ + passName                   │
└──────────────────┬───────────┘
                   │
        ┌──────────┼──────────┐
        │          │          │
        ▼          ▼          ▼
    ┌─────────────────────────────────┐
    │ SSKMetalParticlePass            │
    │ - setupWithDevice:library:      │
    │ - encodeParticles:...           │
    │ - quadVertexBuffer              │
    │ - instanceBuffer                │
    │ - alphaPipeline                 │
    │ - additivePipeline              │
    └─────────────────────────────────┘

    ┌──────────────────────────────┐
    │ SSKMetalBlurPass             │
    │ - setupWithDevice:library:   │
    │ - encodeBlur:destination:    │
    │ - radius                     │
    │ - blurPipelineHorizontal     │
    │ - blurPipelineVertical       │
    └──────────────────────────────┘

    ┌───────────────────────────────────────┐
    │ SSKMetalBloomPass                     │
    │ - setupWithDevice:library:blurPass:   │
    │ - encodeBloomWithCommandBuffer:       │
    │ - threshold, intensity, blurSigma     │
    │ - thresholdPipeline                   │
    │ - compositePipeline                   │
    │ - blurPass (dependency!)              │
    └───────────────────────────────────────┘
```

