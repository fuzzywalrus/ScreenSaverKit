# ScreenSaverKit Performance Optimizations

This document describes the performance optimizations available in ScreenSaverKit and how to use them effectively.

## Overview

ScreenSaverKit includes three major performance optimizations for the particle system (December 2024) and several memory leak fixes (February 2025):

1. **Alive Particle Tracking** - Eliminates O(capacity) scans in particle snapshots
2. **Async Rendering Mode** - Removes GPU wait points for parallel CPU/GPU execution
3. **Indirect Rendering** - Moves instance buffer building to GPU

These optimizations are **backward compatible** with safe defaults - existing code continues to work without modifications.

## Performance Impact Summary

| Optimization | Performance Gain | When to Use | Trade-offs |
|--------------|------------------|-------------|------------|
| **Alive Tracking** | ~100x for sparse systems | Automatic (always on) | None - pure improvement |
| **Async Rendering** | -0.1 to -0.3ms per frame | High particle counts | 1-frame visual latency |
| **Indirect Rendering** | -0.2 to -0.5ms per frame | 1000+ particles | Requires Metal support |

**Combined Impact:** 0.4-1.3ms total frame time reduction + massive speedup for sparse particle systems.

---

## Optimization 1: Alive Particle Tracking

### Problem

Previously, `aliveParticlesSnapshot` iterated through **all capacity slots** to find alive particles:

```objc
// Old approach - O(capacity)
for (NSUInteger i = 0; i < capacity; i++) {
    if (particles[i].life > 0) {
        [alive addObject:particles[i]];
    }
}
```

With a capacity of 10,000 but only 100 alive particles, this scanned 9,900 dead particles unnecessarily.

### Solution

Maintains a separate sparse array of alive particle indices using a **dense array + reverse lookup pattern** with raw C arrays (no NSNumber boxing overhead):

- `_aliveList` / `_aliveListCount`: Compact C array of alive particle indices
- `_alivePositionMap`: Maps particle index → position in aliveList (NSNotFound = not alive)
- `_freeStack` / `_freeStackCount`: C array free-list for recycling indices

This enables O(1) add/remove operations and O(alive_count) iteration with zero Objective-C object allocation in the hot path.

### Implementation Details

**Data Structures (SSKParticleSystem.m, C ivars):**
```objc
@interface SSKParticleSystem () {
    NSUInteger *_freeStack;
    NSUInteger _freeStackCount;
    NSUInteger *_aliveList;
    NSUInteger _aliveListCount;
    NSUInteger *_alivePositionMap;   // NSNotFound = not alive
}
```

**Optimized Snapshot:**
```objc
- (NSArray<SSKParticle *> *)aliveParticlesSnapshot {
    NSMutableArray<SSKParticle *> *alive = self.aliveScratch;
    [alive removeAllObjects];

    // Only iterate alive particles — direct C array access, no NSNumber boxing
    for (NSUInteger i = 0; i < _aliveListCount; i++) {
        NSUInteger idx = _aliveList[i];
        [alive addObject:self.particles[idx]];
    }

    return alive;
}
```

**Removal Helper (O(1) swap-remove):**
```objc
- (void)removeFromAliveTracking:(NSUInteger)index {
    NSUInteger position = _alivePositionMap[index];
    if (position == NSNotFound) { return; }

    NSUInteger lastPos = _aliveListCount - 1;

    if (position != lastPos) {
        // Swap with last element for O(1) removal
        NSUInteger lastIndex = _aliveList[lastPos];
        _aliveList[position] = lastIndex;
        _alivePositionMap[lastIndex] = position;
    }

    _aliveListCount--;
    _alivePositionMap[index] = NSNotFound;
}
```

### Usage

**Automatic!** No API changes needed. The optimization is always active.

### Performance Characteristics

| Scenario | Old Performance | New Performance | Speedup |
|----------|----------------|-----------------|---------|
| 100 alive / 10,000 capacity | O(10,000) | O(100) | ~100x |
| 1,000 alive / 10,000 capacity | O(10,000) | O(1,000) | ~10x |
| 10,000 alive / 10,000 capacity | O(10,000) | O(10,000) | ~1x (no benefit) |

**Key Insight:** The sparser your particle system, the bigger the gain!

---

## Optimization 2: Async Rendering Mode

### Problem

By default, the particle system waits for GPU simulation to complete before returning from `advanceBy:`:

```objc
// Old synchronous approach
[commandBuffer commit];
[commandBuffer waitUntilCompleted];  // CPU stalls waiting for GPU!
```

This creates a GPU-CPU synchronization point every frame, preventing parallel execution.

### Solution

Render the **previous frame's particle data** instead of blocking on current frame completion. Uses a frame fence to ensure only 1 frame in flight.

### Implementation Details

**API (SSKParticleSystem.h:203-214):**
```objc
/// Rendering mode for Metal simulation.
typedef NS_ENUM(NSUInteger, SSKMetalSimulationRenderMode) {
    /// Block until GPU simulation completes (current behavior)
    SSKMetalSimulationRenderModeBlocking,
    /// Render previous frame's data (eliminates GPU wait, adds 1-frame latency)
    SSKMetalSimulationRenderModePreviousFrame,
};

@property (nonatomic) SSKMetalSimulationRenderMode metalSimulationRenderMode;
```

**Data Structures:**
```objc
@property (nonatomic, strong) id<MTLBuffer> previousFrameBuffer;
@property (nonatomic) BOOL hasPreviousFrame;
@property (nonatomic, strong) dispatch_semaphore_t frameFence;
```

**Frame Fence Synchronization:**
```objc
- (void)advanceWithMetal:(NSTimeInterval)dt {
    // Wait on fence if async mode
    if (self.metalSimulationRenderMode == SSKMetalSimulationRenderModePreviousFrame && self.frameFence) {
        dispatch_semaphore_wait(self.frameFence, DISPATCH_TIME_FOREVER);
    }

    // Copy current state to previous frame buffer before simulation
    if (self.metalSimulationRenderMode == SSKMetalSimulationRenderModePreviousFrame &&
        self.previousFrameBuffer && self.particleBuffer) {
        memcpy(self.previousFrameBuffer.contents,
               self.particleBuffer.contents,
               self.capacity * sizeof(SSKParticleState));
        self.hasPreviousFrame = YES;
    }

    // ... GPU simulation work ...

    // Signal fence in completion handler
    dispatch_semaphore_signal(strongSelf.frameFence);
}
```

**Snapshot Selection:**
```objc
- (NSArray<SSKParticle *> *)aliveParticlesSnapshot {
    SSKParticleState *sourceStates = self.states;

    // Use previous frame buffer if in async mode
    if (self.metalSimulationRenderMode == SSKMetalSimulationRenderModePreviousFrame &&
        self.hasPreviousFrame && self.previousFrameBuffer) {
        sourceStates = (SSKParticleState *)self.previousFrameBuffer.contents;
    }

    // ... iterate alive particles from sourceStates ...
}
```

### Usage

```objc
SSKParticleSystem *system = [[SSKParticleSystem alloc] initWithCapacity:10000];

// Enable async rendering mode
system.metalSimulationRenderMode = SSKMetalSimulationRenderModePreviousFrame;
```

### Performance Characteristics

**Frame Time Breakdown (Before):**
```
Frame N:
  CPU: Update logic (2ms)
  GPU: Simulate particles (1ms)
  CPU: WAIT for GPU (1ms) ← Wasted time!
  CPU: Snapshot + render (2ms)
  Total: 6ms
```

**Frame Time Breakdown (After):**
```
Frame N:
  CPU: Update logic (2ms)
  GPU: Simulate particles (1ms) ← Runs in parallel!
  CPU: Snapshot previous frame (2ms)
  Total: 4ms (-33% frame time)
```

**Performance Gain:** -0.1 to -0.3ms per frame (GPU wait eliminated)

### Trade-offs

**Visual Latency:** Particles render at their position from 1 frame ago (16ms at 60fps).

**When is this acceptable?**
- ✅ Fast-moving particles (trails, sparks) - imperceptible at 60fps
- ✅ High particle counts where smoothness matters more than precision
- ✅ Effects with motion blur or additive blending

**When to avoid:**
- ❌ Interactive particles responding to mouse input
- ❌ Physics simulations requiring frame-perfect accuracy
- ❌ Slow-moving particles where 1-frame lag is noticeable

### Thread Safety

The frame fence ensures only 1 frame in flight:

1. Frame N starts → Wait on fence
2. Copy current to previous buffer
3. Dispatch GPU simulation
4. Read from previous buffer (safe - simulation writes to current)
5. GPU completes → Signal fence
6. Frame N+1 can start

---

## Optimization 3: Indirect Rendering

### Problem

Instance buffer building happens on CPU every frame:

```objc
// Old CPU-side approach
SSKMetalInstanceData *instances = self.instanceBuffer.contents;
NSUInteger index = 0;
for (SSKParticle *particle in particles) {
    // Convert particle to instance data (12+ operations per particle)
    SSKMetalInstanceData data;
    data.position = particle.position;
    data.direction = normalize(particle.userVector);
    data.width = particle.size;
    data.length = calculateLength(particle);
    data.color = particle.color;
    data.softness = particle.userScalar;
    instances[index++] = data;
}
// Then draw with instanceCount = index
```

For 1000 particles, this is 1000 × 12 operations = 12,000 operations on CPU per frame.

### Solution

Move instance buffer building to GPU using a **compute shader + atomic counter + indirect draw**.

### Implementation Details

**Metal Shader Kernel:**
```metal
kernel void buildInstanceData(device ParticleState *particles [[buffer(0)]],
                              device InstanceData *instances [[buffer(1)]],
                              device atomic_uint *counter [[buffer(2)]],
                              constant uint &capacity [[buffer(3)]],
                              uint id [[thread_position_in_grid]]) {
    if (id >= capacity) { return; }

    ParticleState state = particles[id];
    if (state.alive == 0u) { return; }

    // Allocate instance slot atomically
    uint instanceIndex = atomic_fetch_add_explicit(counter, 1u, memory_order_relaxed);

    // Build instance data (same logic as CPU side)
    InstanceData data;
    data.position = state.position;

    // Direction from normalized velocity
    float2 dir = state.userVector;
    float len = length(dir);
    data.direction = (len < 0.0001f) ? float2(1.0f, 0.0f) : dir / len;

    // Size and length calculations
    float width = max(1.0f, state.size);
    data.width = width;

    float userScalar = state.userScalar;
    if (userScalar > 10.0f) {
        data.length = width * (userScalar - 10.0f);
    } else if (userScalar >= 0.1f && userScalar <= 1.0f) {
        data.length = width * 8.0f * userScalar;  // z-depth
    } else {
        data.length = width * 8.0f;
    }

    data.color = state.color;
    data.softness = (userScalar > 10.0f || userScalar < 0.1f) ? userScalar : 0.0f;

    instances[instanceIndex] = data;
}
```

**Indirect Rendering Setup:**
```objc
- (void)setupIndirectRendering {
    // Create buildInstanceData compute pipeline
    id<MTLFunction> buildInstanceFunc = [self.library newFunctionWithName:@"buildInstanceData"];
    self.buildInstancePipeline = [self.device newComputePipelineStateWithFunction:buildInstanceFunc error:&error];

    // Create indirect arguments buffer
    typedef struct {
        uint32_t vertexCount;
        uint32_t instanceCount;  // GPU writes here
        uint32_t vertexStart;
        uint32_t baseInstance;
    } MTLDrawPrimitivesIndirectArguments;

    MTLDrawPrimitivesIndirectArguments indirectArgs = {
        .vertexCount = 4,      // Triangle strip quad
        .instanceCount = 0,    // Will be filled by GPU
        .vertexStart = 0,
        .baseInstance = 0
    };

    self.indirectArgsBuffer = [self.device newBufferWithBytes:&indirectArgs
                                                       length:sizeof(MTLDrawPrimitivesIndirectArguments)
                                                      options:MTLResourceStorageModeShared];

    // Create instance counter buffer (atomic uint)
    uint32_t zero = 0;
    self.instanceCounterBuffer = [self.device newBufferWithBytes:&zero
                                                          length:sizeof(uint32_t)
                                                         options:MTLResourceStorageModeShared];

    self.supportsIndirectRendering = YES;
}
```

**Indirect Draw Execution:**
```objc
- (BOOL)encodeParticlesIndirect:(id<MTLBuffer>)particleBuffer
                       capacity:(NSUInteger)capacity
                      blendMode:(SSKParticleBlendMode)blendMode
                   viewportSize:(CGSize)viewportSize
                  commandBuffer:(id<MTLCommandBuffer>)commandBuffer
                   renderTarget:(id<MTLTexture>)renderTarget
                     loadAction:(MTLLoadAction)loadAction
                     clearColor:(MTLClearColor)clearColor {

    // Reset counter to 0
    uint32_t zero = 0;
    memcpy(self.instanceCounterBuffer.contents, &zero, sizeof(uint32_t));

    // Dispatch compute shader to build instances
    id<MTLComputeCommandEncoder> computeEncoder = [commandBuffer computeCommandEncoder];
    [computeEncoder setComputePipelineState:self.buildInstancePipeline];
    [computeEncoder setBuffer:particleBuffer offset:0 atIndex:0];
    [computeEncoder setBuffer:self.instanceBuffer offset:0 atIndex:1];
    [computeEncoder setBuffer:self.instanceCounterBuffer offset:0 atIndex:2];
    [computeEncoder setBytes:&capacity length:sizeof(uint32_t) atIndex:3];

    NSUInteger threadGroupSize = 256;
    NSUInteger threadGroups = (capacity + threadGroupSize - 1) / threadGroupSize;
    [computeEncoder dispatchThreadgroups:MTLSizeMake(threadGroups, 1, 1)
                   threadsPerThreadgroup:MTLSizeMake(threadGroupSize, 1, 1)];
    [computeEncoder endEncoding];

    // Copy counter to indirect args
    id<MTLBlitCommandEncoder> blitEncoder = [commandBuffer blitCommandEncoder];
    [blitEncoder copyFromBuffer:self.instanceCounterBuffer
                   sourceOffset:0
                       toBuffer:self.indirectArgsBuffer
              destinationOffset:4  // Offset of instanceCount field
                         length:sizeof(uint32_t)];
    [blitEncoder endEncoding];

    // Render using indirect draw
    id<MTLRenderCommandEncoder> encoder = [commandBuffer renderCommandEncoderWithDescriptor:descriptor];
    [encoder setRenderPipelineState:pipeline];
    [encoder setVertexBuffer:self.quadVertexBuffer offset:0 atIndex:0];
    [encoder setVertexBuffer:self.instanceBuffer offset:0 atIndex:1];
    [encoder setVertexBytes:&viewportPoints length:sizeof(vector_float2) atIndex:2];

    // Indirect draw - GPU reads instance count from buffer!
    [encoder drawPrimitives:MTLPrimitiveTypeTriangleStrip
             indirectBuffer:self.indirectArgsBuffer
       indirectBufferOffset:0];
    [encoder endEncoding];

    return YES;
}
```

**Integration:**
```objc
- (BOOL)renderWithMetalRenderer:(SSKMetalParticleRenderer *)renderer
                       blendMode:(SSKParticleBlendMode)blendMode
                    viewportSize:(CGSize)viewportSize {
    if (!renderer) { return NO; }

    // Try indirect rendering path if available
    if (renderer.useIndirectRendering && self.particleBuffer) {
        SSKMetalRenderer *metalRenderer = [renderer valueForKey:@"renderer"];
        if (metalRenderer && [metalRenderer beginFrame]) {
            [metalRenderer drawParticlesIndirect:self.particleBuffer
                                        capacity:self.capacity
                                       blendMode:blendMode
                                    viewportSize:viewportSize];

            // Apply post-processing effects
            if (renderer.blurRadius > 0.01) {
                [metalRenderer applyBlur:renderer.blurRadius];
            }
            if (renderer.bloomIntensity > 0.01) {
                [metalRenderer applyBloom:renderer.bloomIntensity];
            }

            [metalRenderer endFrame];
            return YES;
        }
    }

    // Fallback to CPU path using snapshot
    NSArray<SSKParticle *> *snapshot = [self aliveParticlesSnapshot];
    return [renderer renderParticles:snapshot blendMode:blendMode viewportSize:viewportSize];
}
```

### Usage

```objc
SSKMetalParticleRenderer *renderer = [[SSKMetalParticleRenderer alloc] initWithLayer:layer];

// Enable indirect rendering
renderer.useIndirectRendering = YES;

// Particle system automatically uses indirect path when rendering
[particleSystem renderWithMetalRenderer:renderer
                              blendMode:SSKParticleBlendModeAdditive
                           viewportSize:self.bounds.size];
```

### Performance Characteristics

**CPU Work (Before):**
```
For each frame with 1000 alive particles:
  Iterate 1000 particles
  Convert each to instance data (12 operations)
  Write to instance buffer
  Total: 12,000 CPU operations
```

**GPU Work (After):**
```
For each frame:
  Dispatch 4 thread groups (256 threads each)
  Each thread checks 1 particle
  Only alive particles write to instance buffer
  Counter incremented atomically
  Total: ~1000 GPU operations (massively parallel)
```

**Performance Gain:** -0.2 to -0.5ms per frame for 1000+ particles

### Requirements

- Metal device with indirect command buffer support (all modern Macs)
- Metal simulation must be enabled (particle buffer must exist)
- Compute shader support (all Metal-capable devices)

### Automatic Fallback

If indirect rendering fails or is not supported:
1. System automatically falls back to CPU path
2. No visual difference
3. Logged to diagnostics if enabled

---

## Recommended Optimization Strategy

### For Maximum Performance

Enable **all three optimizations** for systems with 1000+ particles:

```objc
SSKParticleSystem *system = [[SSKParticleSystem alloc] initWithCapacity:10000];
SSKMetalParticleRenderer *renderer = [[SSKMetalParticleRenderer alloc] initWithLayer:layer];

// Optimization 1: Automatic (alive tracking)

// Optimization 2: Enable async rendering
system.metalSimulationRenderMode = SSKMetalSimulationRenderModePreviousFrame;

// Optimization 3: Enable indirect rendering
renderer.useIndirectRendering = YES;
```

**Expected combined performance gain:** 0.4-1.3ms per frame + 100x snapshot speedup for sparse systems

### For Interactive Applications

Use **alive tracking only** (automatic) if frame-perfect precision is required:

```objc
// Default settings - no async rendering, no indirect rendering
// Alive tracking is automatic
```

### For High-Precision Simulations

Use **alive tracking + indirect rendering** but skip async mode:

```objc
SSKParticleSystem *system = [[SSKParticleSystem alloc] initWithCapacity:10000];
SSKMetalParticleRenderer *renderer = [[SSKMetalParticleRenderer alloc] initWithLayer:layer];

// Optimization 1: Automatic
// Optimization 2: Disabled (default)
// Optimization 3: Enabled
renderer.useIndirectRendering = YES;
```

---

## Benchmarking Your Optimizations

### Before/After Comparison

```objc
// Measure baseline
system.metalSimulationRenderMode = SSKMetalSimulationRenderModeBlocking;
renderer.useIndirectRendering = NO;
// Run for 60 frames, record average frame time

// Measure with optimizations
system.metalSimulationRenderMode = SSKMetalSimulationRenderModePreviousFrame;
renderer.useIndirectRendering = YES;
// Run for 60 frames, record average frame time
```

### Using the Benchmark Tool

```bash
cd Tools/Benchmark
make
./Build/ssk-benchmark --format json --output baseline.json

# Enable optimizations in code, rebuild

./Build/ssk-benchmark --format json --output optimized.json

# Compare results
jq '.scenarios[] | {name, duration_ms, avgSimulationTime_ms}' baseline.json
jq '.scenarios[] | {name, duration_ms, avgSimulationTime_ms}' optimized.json
```

### Performance Targets

| Metric | Target | Good | Needs Work |
|--------|--------|------|------------|
| Frame time (60fps) | < 16.67ms | < 20ms | > 20ms |
| Snapshot (1000 alive) | < 0.1ms | < 0.5ms | > 1ms |
| Instance build (1000) | < 0.5ms | < 1ms | > 2ms |
| GPU wait time | 0ms | < 0.1ms | > 0.5ms |

---

## Migration Guide

### Updating Existing Code

**No changes required!** All optimizations are backward compatible.

**Optional: Enable new features for better performance:**

```objc
// Before (still works)
SSKParticleSystem *system = [[SSKParticleSystem alloc] initWithCapacity:5000];
SSKMetalParticleRenderer *renderer = [[SSKMetalParticleRenderer alloc] initWithLayer:layer];

// After (optimized)
SSKParticleSystem *system = [[SSKParticleSystem alloc] initWithCapacity:5000];
system.metalSimulationRenderMode = SSKMetalSimulationRenderModePreviousFrame;

SSKMetalParticleRenderer *renderer = [[SSKMetalParticleRenderer alloc] initWithLayer:layer];
renderer.useIndirectRendering = YES;
```

### Verification Checklist

- [ ] Code compiles without errors
- [ ] Visual output unchanged (except 1-frame latency in async mode)
- [ ] Frame rate improved (measure with benchmark tool)
- [ ] No memory leaks (check with Instruments)
- [ ] Particles render correctly at high counts (1000+)

---

## Technical Deep Dive

### Why These Optimizations Work

**Alive Tracking:**
- Eliminates O(capacity) scans
- Cache-friendly dense array iteration
- O(1) add/remove with swap-with-last pattern

**Async Rendering:**
- Removes GPU-CPU synchronization barrier
- Allows parallel execution of CPU and GPU work
- Frame fence prevents race conditions

**Indirect Rendering:**
- Moves CPU work to massively parallel GPU
- Atomic counter prevents race conditions
- Indirect draw eliminates CPU-GPU roundtrip for instance count

### Metal Pipeline Flow (Indirect Rendering)

```
CPU Thread                       GPU Timeline
──────────────────────────────────────────────────────────
Reset counter to 0

Dispatch compute encoder ───────→ Compute Shader:
                                   - Thread 0: Check particle 0
                                   - Thread 1: Check particle 1
                                   - ...
                                   - Thread N: Check particle N
                                   - Alive particles write to instance buffer
                                   - Counter incremented atomically

Dispatch blit encoder ──────────→ Blit: Copy counter → indirect args

Dispatch render encoder ────────→ Render:
                                   - Read instanceCount from indirect buffer
                                   - Draw instanceCount instances

Command buffer complete ←──────── GPU done
```

### Memory Layout

**Particle Buffer (Shared Memory):**
```
[ParticleState 0][ParticleState 1]...[ParticleState N]
     alive=1          alive=0              alive=1
     ↓                (skip)               ↓
     Writes to        (no write)           Writes to
     instance[0]                           instance[1]
```

**Instance Buffer (Shared Memory):**
```
[Instance 0][Instance 1][Instance 2]...[Instance aliveCount-1]
  (compact, no gaps - only alive particles)
```

**Indirect Args Buffer:**
```
{
  vertexCount: 4,          // Fixed (triangle strip quad)
  instanceCount: ???,      // Written by GPU (from counter)
  vertexStart: 0,
  baseInstance: 0
}
```

---

## Troubleshooting

### Optimization Not Working?

**Alive Tracking:**
- Always works (automatic)
- If snapshots still slow, check capacity vs alive count ratio

**Async Rendering:**
- Check `metalSimulationRenderMode` is set correctly
- Verify Metal simulation is enabled (`metalSimulationEnabled = YES`)
- Ensure particle buffer exists

**Indirect Rendering:**
- Check `supportsIndirectRendering` property on particle pass
- Verify Metal device supports indirect buffers
- Ensure particle buffer is available (Metal simulation enabled)
- Check diagnostics logs for fallback messages

### Visual Artifacts

**Particles lag behind:**
- Expected with async rendering mode
- Switch to `SSKMetalSimulationRenderModeBlocking` if precision needed

**Particles missing:**
- Check alive tracking is working (`aliveParticleCount` property)
- Verify indirect rendering counter is correct

### Performance Not Improving

**Check:**
1. Metal simulation enabled? (`metalSimulationEnabled`)
2. Sufficient particle count? (< 100 particles won't benefit much from indirect rendering)
3. Bottleneck elsewhere? (use Instruments to profile)
4. Other post-processing? (bloom/blur might dominate frame time)

---

## Memory Leak Fixes (February 2025)

In addition to the performance optimizations above, several memory leaks and resource management issues were identified and fixed that caused gradual performance degradation over time:

### 1. Metal Encoder / Command Buffer Leak

**Problem:** In `advanceWithMetal:`, when the alive particle count was zero, the method created a Metal command buffer and compute encoder but returned early without ending the encoder or committing the buffer. This leaked GPU resources every frame during idle periods and could deadlock the frame fence in async mode.

**Fix:** The alive count check was moved *before* command buffer/encoder creation. When no particles are alive and async rendering is active, the frame fence is explicitly signaled to prevent deadlock.

### 2. NSTimer Retain Cycle

**Problem:** `SSKScreenSaverView` created a repeating `NSTimer` with `self` as the target. Since `NSTimer` retains its target, this created a retain cycle preventing the view from being deallocated.

**Fix:** A lightweight `SSKTimerWeakProxy` class holds a weak reference to the view and forwards timer callbacks. The proxy automatically invalidates the timer if the target is deallocated.

### 3. Strong Self in GPU Completion Handler

**Problem:** `spawnParticlesGPU:parameters:` captured `self` strongly in a Metal command buffer completion handler, preventing deallocation while GPU work was in flight.

**Fix:** Uses standard weak/strong dance pattern in the completion handler.

### 4. NSNumber Boxing in Particle Index Tracking

**Problem:** The particle alive-tracking system used `NSMutableArray<NSNumber *>` and `NSMutableDictionary<NSNumber *, NSNumber *>`, creating thousands of autoreleased `NSNumber` objects per frame during spawn/death cycles. This caused significant autorelease pool pressure and GC overhead.

**Fix:** Replaced all Objective-C collection types with raw C arrays (`NSUInteger *`) and counters. See [Optimization 1](#optimization-1-alive-particle-tracking) above for the updated implementation.

### 5. Unbounded Texture Cache Growth

**Problem:** `SSKMetalTextureCache` could accumulate textures indefinitely if textures were released back to the cache faster than they were trimmed.

**Fix:** Added automatic trimming in `releaseTexture:` when the cache exceeds 8 textures (`kSSKTextureCacheAutoTrimThreshold`).

---

## Future Improvements

Potential optimizations for future releases:

- **Culling on GPU**: Frustum culling in compute shader before instance building
- **LOD System**: Reduce particle detail at distance
- **Persistent Mapped Buffers**: Avoid memcpy overhead
- **Multi-buffering**: Triple buffering for even lower latency

---

## References

- **SSKParticleSystem.h** - Particle system API documentation
- **SSKParticleSystem.m** - Implementation details
- **SSKParticleShaders.metal** - GPU compute shaders
- **SSKMetalParticlePass.m** - Indirect rendering implementation
- **PERFORMANCE_TESTING.md** - Benchmark tools and methodology
- **PERFORMANCE_ANALYSIS.md** - RibbonFlow performance case study

---

**Last Updated:** February 9, 2025
**ScreenSaverKit Version:** Alpha (Post-Performance-Optimization + Memory Leak Fixes)
