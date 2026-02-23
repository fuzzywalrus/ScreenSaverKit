# ScreenSaverKit Architecture Diagrams

## 1. Component Hierarchy

```
SSKMetalRenderer (Coordinator)
  ├─ SSKMetalParticlePass
  │   ├─ particleVertex shader (with per-particle rotation)
  │   ├─ particleFragment shader
  │   ├─ Render pipelines (alpha & additive)
  │   ├─ Indirect rendering (compactAliveIndices → buildInstanceData)
  │   └─ Ribbon mode (prepareRibbonIndirectArgs → buildRibbonInstanceData)
  │
  ├─ SSKMetalSpritePass
  │   ├─ spriteVertex / spriteFragment (SSKSpriteShaders.metal)
  │   ├─ Instanced sprite rendering (position, scale, rotation, UV)
  │   └─ Optional viewport culling, z-sort
  │
  ├─ SSKMetalTrailPass (optional, when trailPersistenceEnabled)
  │   ├─ trailFadeKernel (compute)
  │   ├─ Persistent offscreen texture (not in texture cache)
  │   └─ Blit encoder for compositing
  │
  ├─ SSKMetalBlurPass
  │   ├─ gaussianBlurHorizontal kernel
  │   ├─ gaussianBlurVertical kernel
  │   └─ Compute pipelines (2x)
  │
  ├─ SSKMetalBloomPass
  │   ├─ bloomThresholdKernel
  │   ├─ bloomCompositeKernel
  │   ├─ SSKMetalBlurPass (shared instance)
  │   └─ Compute pipelines (2x)
  │
  ├─ SSKMetalTextureCache
  │   └─ Pooled intermediate textures
  │
  ├─ id<MTLCommandBuffer> currentCommandBuffer
  ├─ id<MTLDevice> device
  └─ id<MTLCommandQueue> commandQueue

SSKParticleSystem (Simulation)
  ├─ SSKSimulationShaders.metallib
  │   ├─ simulateParticles kernel
  │   ├─ Curl noise (2D simplex, divergence-free)
  │   ├─ Attractor forces (up to 4, inverse-square)
  │   └─ Color gradient (half-float endColor)
  │
  ├─ SSKParticleShaders.metallib
  │   └─ initializeParticles (GPU spawn kernel)
  │
  ├─ CPU simulation fallback (matching features)
  └─ SSKSimulationUniforms (256 bytes, feature flags bitmask)
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
        │ drawParticles() / Indirect()         │
        │                                      │
        │ [if trail enabled]                   │
        │  ├─ Fade trail texture (compute)     │
        │  └─ Redirect render → trail texture  │
        │                                      │
        │ [if indirect / ribbon]               │
        │  ├─ compactAliveIndices (compute)    │
        │  ├─ buildInstanceData (compute)      │
        │  └─ drawIndexedPrimitives (indirect) │
        │                                      │
        │ [if trail enabled]                   │
        │  └─ Blit trail → drawable            │
        │                                      │
        │ - Set viewport & blend mode          │
        │ - Clear if needed                    │
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

## 4. Particle System Architecture

```
┌──────────────────────────────────────┐
│ SSKParticleSystem                     │
│ (Simulation + Data)                   │
│                                       │
│  Simulation Forces:                   │
│  ├─ Gravity (global)                  │
│  ├─ Damping (per-particle + global)   │
│  ├─ Curl noise force field            │
│  ├─ Attractor points (up to 4)        │
│  └─ Per-particle rotation velocity    │
│                                       │
│  Behavior Flags:                      │
│  ├─ FadeAlpha, FadeSize               │
│  ├─ ColorGradient (baseColor→endColor)│
│  ├─ CurlNoise, Attractors            │
│  ├─ VelocityHue                       │
│  └─ RibbonMode                        │
└──────────────────────────────────────┘
          │
   ┌──────┴──────┐
   │             │
   ▼             ▼
CPU Sim       GPU Sim
(ObjC)    (SSKSimulationShaders.metal)
   │             │
   ├─ gravity    ├─ simulateParticles kernel
   ├─ damping    ├─ curl noise (2D simplex)
   ├─ curl noise ├─ attractor forces
   ├─ attractors ├─ color gradient (half-float)
   ├─ color grad └─ rotation integration
   └─ rotation
          │
   ┌──────┴──────┐
   │             │
   ▼             ▼
CPU Render   GPU Render
(CGContext)  (SSKMetalRenderer)
                 │
    ┌────────────┼───────────────┐
    │            │               │
    ▼            ▼               ▼
  Direct     Indirect        Ribbon
  (CPU       (GPU-built     (GPU-built
   inst.)     inst. buf.)    ribbon segs.)
                 │
    ┌────────────┼───────────────┐
    │            │               │
    ▼            ▼               ▼
  [opt]       [opt]           [opt]
  Trail       Blur            Bloom
  Persist
```

## 5. Metal Shader Organization

```
SSKParticleShaders.metal (Rendering + Effects)
         │
         ├─ Particle Rendering
         │  ├─ particleVertex()
         │  │  └─ Transform quads with per-particle rotation
         │  └─ particleFragment()
         │     └─ Soft disc with Gaussian falloff
         │
         ├─ GPU Instance Building (Indirect)
         │  ├─ compactAliveIndices()
         │  │  └─ Atomically compact alive particle indices
         │  ├─ buildInstanceData()
         │  │  └─ Build per-instance rendering data on GPU
         │  ├─ prepareRibbonIndirectArgs()
         │  │  └─ Set up indirect draw args for ribbon mode
         │  └─ buildRibbonInstanceData()
         │     └─ Build ribbon segments between adjacent particles
         │
         ├─ Particle Spawn
         │  └─ initializeParticles()
         │     └─ Batch spawn with z-depth, endColor support
         │
         ├─ Trail Persistence
         │  └─ trailFadeKernel()
         │     └─ Multiply all pixels by (1.0 - fadeRate)
         │
         ├─ Blur Compute Kernels
         │  ├─ gaussianBlurHorizontal()
         │  └─ gaussianBlurVertical()
         │
         └─ Bloom Compute Kernels
            ├─ bloomThresholdKernel()
            └─ bloomCompositeKernel()

SSKSimulationShaders.metal (GPU Simulation)
         │
         ├─ simulateParticles()
         │  └─ Main simulation kernel
         │     ├─ Velocity integration + gravity + damping
         │     ├─ Curl noise (2D simplex, divergence-free)
         │     ├─ Attractor forces (inverse-square, up to 4)
         │     ├─ Color gradient (half-float endColor lerp)
         │     └─ Rotation velocity integration
         │
         └─ Feature flags (bitmask in SSKSimulationUniforms)
            ├─ kFeatureCurlNoise    (1 << 0)
            ├─ kFeatureAttractors   (1 << 1)
            ├─ kFeatureColorGradient(1 << 2)
            └─ kFeatureVelocityHue  (1 << 3)

                      │
                      ▼
                 Compile (xcrun metal)
                      │
              ┌───────┴───────┐
              ▼               ▼
SSKParticleShaders   SSKSimulationShaders
    .metallib             .metallib
              │               │
              ▼               ▼
      SSKMetalRenderer   SSKParticleSystem
      (rendering)        (simulation)
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
    │   ├─ Direct rendering (CPU instance building)
    │   ├─ Indirect rendering (GPU instance building)
    │   └─ Ribbon rendering (GPU ribbon segments)
    │
    ├─→ SSKMetalTrailPass (optional, when trailPersistenceEnabled)
    │   └─ Persistent offscreen texture + fade kernel
    │
    ├─→ SSKMetalBlurPass
    │
    ├─→ SSKMetalBloomPass
    │   └──→ SSKMetalBlurPass (shared)
    │
    ├─→ SSKMetalTextureCache
    │
    ├─→ MTLDevice
    │
    └─→ MTLLibrary (SSKParticleShaders)

SSKParticleSystem
    │
    ├─→ MTLDevice (simulation compute)
    ├─→ MTLLibrary (SSKSimulationShaders)
    ├─→ SSKSimulationUniforms (256 bytes, feature flags)
    └─→ SSKParticleShaders (initializeParticles kernel for GPU spawn)

User Code (e.g., FluxView)
    │
    └─→ SSKMetalRenderer
        ├─ Call: drawParticlesIndirect() [trail-enabled]
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
      ┌────────────┼──────────────┐
      │            │              │
      ▼            ▼              ▼
  ┌────────────────────────────────────┐
  │ SSKMetalParticlePass               │
  │ - setupWithDevice:library:         │
  │ - encodeParticles:...              │
  │ - encodeParticlesIndirect:...      │
  │ - ribbonModeEnabled                │
  │ - lengthMultiplier                 │
  │ - quadVertexBuffer, instanceBuffer │
  │ - alphaPipeline, additivePipeline  │
  │ - compactPipeline, buildPipeline   │
  │ - ribbonBuildPipeline              │
  └────────────────────────────────────┘

  ┌──────────────────────────────┐
  │ SSKMetalBlurPass             │
  │ - setupWithDevice:library:   │
  │ - encodeBlur:destination:    │
  │ - radius                     │
  └──────────────────────────────┘

  ┌───────────────────────────────────────┐
  │ SSKMetalBloomPass                     │
  │ - setupWithDevice:library:            │
  │ - encodeBloomWithCommandBuffer:       │
  │ - threshold, intensity, blurSigma     │
  │ - blurPass (shared dependency)        │
  └───────────────────────────────────────┘

SSKMetalTrailPass (standalone, not SSKMetalPass subclass)
  │ - initWithDevice:library:
  │ - trailTextureForSize:
  │ - fadeWithRate:commandBuffer:
  │ - blitTo:destination:commandBuffer:
  │ - Persistent offscreen texture (owned)
  └─ fadePipeline (trailFadeKernel)
```

## 11. Trail Persistence Data Flow

```
┌───────────────────────────────────────────────────────┐
│ Frame N                                                │
│                                                        │
│  ┌─────────────┐                                       │
│  │ Trail       │◄── Persistent (survives between frames)│
│  │ Texture     │                                       │
│  └──────┬──────┘                                       │
│         │                                              │
│         ▼                                              │
│  ┌─────────────────────────────────┐                   │
│  │ trailFadeKernel (compute)       │                   │
│  │ pixel *= (1.0 - fadeRate)       │                   │
│  │ (fades previous frame content)  │                   │
│  └──────┬──────────────────────────┘                   │
│         │                                              │
│         ▼                                              │
│  ┌─────────────────────────────────┐                   │
│  │ Render new particles            │                   │
│  │ onto trail texture              │                   │
│  │ (accumulates on faded content)  │                   │
│  └──────┬──────────────────────────┘                   │
│         │                                              │
│         ▼                                              │
│  ┌─────────────────────────────────┐                   │
│  │ Blit trail texture → drawable   │                   │
│  │ (copy to final output)          │                   │
│  └─────────────────────────────────┘                   │
│                                                        │
│  Result: Long luminous trails that slowly fade         │
│  fadeRate 0.02 → ~50 frame trail persistence           │
│  fadeRate 0.10 → ~10 frame trail persistence           │
└───────────────────────────────────────────────────────┘
```

## 12. Indirect Rendering Pipeline

```
GPU-only pipeline (single command buffer, no CPU readback):

┌─────────────────────────────────────────────────────┐
│ Compute Pass 1: compactAliveIndices                  │
│ - Input: particle buffer (all slots, alive + dead)   │
│ - Output: aliveIndices buffer (contiguous)           │
│ - Output: aliveCounter (atomic uint)                 │
│ - Each alive particle writes its index atomically    │
└──────────────────────────┬──────────────────────────┘
                           │
                           ▼
┌─────────────────────────────────────────────────────┐
│ Compute Pass 2: buildInstanceData                    │
│ - Input: particle buffer + aliveIndices              │
│ - Output: instance buffer (InstanceData per alive)   │
│ - Builds position, direction, color, rotation, etc.  │
│ - Output: indirect draw args buffer                  │
└──────────────────────────┬──────────────────────────┘
                           │
                           ▼
┌─────────────────────────────────────────────────────┐
│ Render Pass: drawIndexedPrimitivesIndirect           │
│ - Input: instance buffer (from Pass 2)               │
│ - Input: indirect args buffer (vertexCount, etc.)    │
│ - GPU reads instance count from buffer, not CPU      │
│ - Draws all alive particles in one draw call         │
└─────────────────────────────────────────────────────┘

Ribbon variant replaces Pass 2 with:
  2a. prepareRibbonIndirectArgs  (reads aliveCounter → sets segment count)
  2b. buildRibbonInstanceData    (connects adjacent particles as strips)
```

