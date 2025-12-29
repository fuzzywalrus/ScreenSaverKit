#import "SSKParticleSystem.h"

#import <Metal/Metal.h>
#import <simd/simd.h>
#import <math.h>

#import "SSKMetalParticleRenderer.h"
#import "SSKMetalRenderer.h"
#import "SSKVectorMath.h"

// Behaviour flag values mirrored in the Metal shader.
static const uint32_t kSSKParticleBehaviorFadeAlpha = (uint32_t)SSKParticleBehaviorOptionFadeAlpha;
static const uint32_t kSSKParticleBehaviorFadeSize  = (uint32_t)SSKParticleBehaviorOptionFadeSize;

typedef struct __attribute__((aligned(16))) {
    vector_float2 position;
    vector_float2 velocity;
    vector_float2 userVector;
    vector_float2 sizeRange;    // start, end multipliers
    vector_float4 color;
    vector_float4 baseColor;
    float life;
    float maxLife;
    float size;
    float baseSize;
    float sizeVelocity;
    float rotation;
    float rotationVelocity;
    float damping;
    float userScalar;
    uint32_t behaviorFlags;
    uint32_t alive;
    uint32_t padding[2];
} SSKParticleState;

typedef struct {
    vector_float2 gravity;
    float dt;
    float globalDamping;
    float padding;
} SSKParticleSimulationUniforms;

static inline BOOL SSKShouldCullParticle(const SSKParticleSystem *system, vector_float2 position) {
    if (!system || !system.isCullingEnabled || CGRectIsEmpty(system.cullingRect)) {
        return NO;
    }
    CGRect expanded = CGRectInset(system.cullingRect, -system.cullingMargin, -system.cullingMargin);
    return !CGRectContainsPoint(expanded, CGPointMake(position.x, position.y));
}

static NSString * const kSSKParticleComputeTemplate =
@"#include <metal_stdlib>\\n"
"using namespace metal;\\n"
"struct ParticleState {\\n"
"    float2 position;\\n"
"    float2 velocity;\\n"
"    float2 userVector;\\n"
"    float2 sizeRange;\\n"
"    float4 color;\\n"
"    float4 baseColor;\\n"
"    float life;\\n"
"    float maxLife;\\n"
"    float size;\\n"
"    float baseSize;\\n"
"    float sizeVelocity;\\n"
"    float rotation;\\n"
"    float rotationVelocity;\\n"
"    float damping;\\n"
"    float userScalar;\\n"
"    uint behaviorFlags;\\n"
"    uint alive;\\n"
"    uint padding0;\\n"
"    uint padding1;\\n"
"};\\n"
"struct SimulationUniforms {\\n"
"    float2 gravity;\\n"
"    float dt;\\n"
"    float globalDamping;\\n"
"    float padding;\\n"
"};\\n"
"constant uint kBehaviorFadeAlpha = %u;\\n"
"constant uint kBehaviorFadeSize  = %u;\\n"
"kernel void simulateParticles(device ParticleState *particles [[buffer(0)]],\\n"
"                             constant SimulationUniforms &uniforms [[buffer(1)]],\\n"
"                             uint id [[thread_position_in_grid]]) {\\n"
"    ParticleState state = particles[id];\\n"
"    if (state.alive == 0u) { return; }\\n"
"    float dt = uniforms.dt;\\n"
"    state.life += dt;\\n"
"    if (state.life >= state.maxLife) {\\n"
"        state.alive = 0u;\\n"
"        particles[id] = state;\\n"
"        return;\\n"
"    }\\n"
"    if (any(uniforms.gravity)) {\\n"
"        state.velocity += uniforms.gravity * dt;\\n"
"    }\\n"
"    float damping = max(0.0f, state.damping + uniforms.globalDamping);\\n"
"    if (damping > 0.0f) {\\n"
"        float factor = pow(max(0.0f, 1.0f - damping), dt);\\n"
"        state.velocity *= factor;\\n"
"    }\\n"
"    state.position += state.velocity * dt;\\n"
"    state.rotation += state.rotationVelocity * dt;\\n"
"    if (fabs(state.sizeVelocity) > 0.0001f) {\\n"
"        state.size = max(0.0f, state.size + state.sizeVelocity * dt);\\n"
"    }\\n"
"    float normalized = (state.maxLife > 0.0f) ? clamp(state.life / state.maxLife, 0.0f, 1.0f) : 0.0f;\\n"
"    if ((state.behaviorFlags & kBehaviorFadeAlpha) != 0u) {\\n"
"        float fade = 1.0f - normalized;\\n"
"        state.color = float4(state.baseColor.rgb, state.baseColor.a * fade);\\n"
"    } else {\\n"
"        state.color = float4(state.color.rgb, state.color.a);\\n"
"    }\\n"
"    if ((state.behaviorFlags & kBehaviorFadeSize) != 0u) {\\n"
"        float multiplier = mix(state.sizeRange.x, state.sizeRange.y, normalized);\\n"
"        state.size = max(0.0f, state.baseSize * multiplier);\\n"
"    }\\n"
"    float velLenSq = length_squared(state.velocity);\\n"
"    if (velLenSq > 0.0001f) {\\n"
"        state.userVector = state.velocity * rsqrt(velLenSq);\\n"
"    }\\n"
"    particles[id] = state;\\n"
"}\\n";

static inline vector_float2 SSKVectorFromPoint(NSPoint point) {
    return (vector_float2){(float)point.x, (float)point.y};
}

static inline NSPoint SSKPointFromVector(vector_float2 v) {
    return NSMakePoint(v.x, v.y);
}

static inline vector_float4 SSKVectorFromColor(NSColor *color) {
    NSColor *srgb = [color colorUsingColorSpace:[NSColorSpace extendedSRGBColorSpace]] ?: color;
    return (vector_float4){(float)srgb.redComponent,
                           (float)srgb.greenComponent,
                           (float)srgb.blueComponent,
                           (float)srgb.alphaComponent};
}

static inline NSColor *SSKColorFromVector(vector_float4 v) {
    CGFloat components[4] = {v.x, v.y, v.z, v.w};
    return [NSColor colorWithColorSpace:[NSColorSpace extendedSRGBColorSpace]
                              components:components
                                   count:4];
}

@interface SSKParticle ()
- (instancetype)initWithState:(SSKParticleState *)state index:(NSUInteger)index;
@property (nonatomic, readonly) NSUInteger index;
@property (nonatomic, assign) SSKParticleState *state;
@property (nonatomic, getter=isAlive) BOOL alive;
@end

@implementation SSKParticle

- (instancetype)initWithState:(SSKParticleState *)state index:(NSUInteger)index {
    if ((self = [super init])) {
        _state = state;
        _index = index;
    }
    return self;
}

- (BOOL)isAlive {
    return self.state->alive != 0;
}

- (void)setAlive:(BOOL)alive {
    self.state->alive = alive ? 1u : 0u;
}

- (NSPoint)position {
    return SSKPointFromVector(self.state->position);
}

- (void)setPosition:(NSPoint)position {
    self.state->position = SSKVectorFromPoint(position);
}

- (NSPoint)velocity {
    return SSKPointFromVector(self.state->velocity);
}

- (void)setVelocity:(NSPoint)velocity {
    self.state->velocity = SSKVectorFromPoint(velocity);
}

- (CGFloat)life {
    return self.state->life;
}

- (void)setLife:(CGFloat)life {
    self.state->life = life;
}

- (CGFloat)maxLife {
    return self.state->maxLife;
}

- (void)setMaxLife:(CGFloat)maxLife {
    self.state->maxLife = maxLife;
}

- (CGFloat)size {
    return self.state->size;
}

- (void)setSize:(CGFloat)size {
    self.state->size = size;
    if (self.state->baseSize <= 0.0f) {
        self.state->baseSize = size;
    }
}

- (NSColor *)color {
    return SSKColorFromVector(self.state->color);
}

- (void)setColor:(NSColor *)color {
    vector_float4 value = SSKVectorFromColor(color ?: [NSColor whiteColor]);
    self.state->color = value;
    self.state->baseColor = value;
}

- (vector_float4)metalColorVector {
    return self.state->color;
}

- (CGFloat)rotation {
    return self.state->rotation;
}

- (void)setRotation:(CGFloat)rotation {
    self.state->rotation = rotation;
}

- (CGFloat)rotationVelocity {
    return self.state->rotationVelocity;
}

- (void)setRotationVelocity:(CGFloat)rotationVelocity {
    self.state->rotationVelocity = rotationVelocity;
}

- (CGFloat)damping {
    return self.state->damping;
}

- (void)setDamping:(CGFloat)damping {
    self.state->damping = damping;
}

- (CGFloat)userScalar {
    return self.state->userScalar;
}

- (void)setUserScalar:(CGFloat)userScalar {
    self.state->userScalar = userScalar;
}

- (NSPoint)userVector {
    return SSKPointFromVector(self.state->userVector);
}

- (void)setUserVector:(NSPoint)userVector {
    self.state->userVector = SSKVectorFromPoint(userVector);
}

- (CGFloat)baseSize {
    return self.state->baseSize;
}

- (void)setBaseSize:(CGFloat)baseSize {
    self.state->baseSize = baseSize;
}

- (CGFloat)sizeVelocity {
    return self.state->sizeVelocity;
}

- (void)setSizeVelocity:(CGFloat)sizeVelocity {
    self.state->sizeVelocity = sizeVelocity;
}

- (SSKScalarRange)sizeOverLifeRange {
    return SSKScalarRangeMake(self.state->sizeRange.x, self.state->sizeRange.y);
}

- (void)setSizeOverLifeRange:(SSKScalarRange)sizeOverLifeRange {
    self.state->sizeRange = (vector_float2){(float)sizeOverLifeRange.start, (float)sizeOverLifeRange.end};
}

- (SSKParticleBehaviorOptions)behaviorOptions {
    return (SSKParticleBehaviorOptions)self.state->behaviorFlags;
}

- (void)setBehaviorOptions:(SSKParticleBehaviorOptions)behaviorOptions {
    self.state->behaviorFlags = (uint32_t)behaviorOptions;
}

@end

@interface SSKParticleSystem ()
@property (nonatomic, assign) NSUInteger capacity;
@property (nonatomic, assign) SSKParticleState *states;
@property (nonatomic, strong) NSMutableArray<SSKParticle *> *particles;
@property (nonatomic, strong) NSMutableArray<SSKParticle *> *aliveScratch;
@property (nonatomic, strong) NSMutableIndexSet *availableIndices; // Kept for compatibility, but optimized access
@property (nonatomic, strong) NSMutableArray<NSNumber *> *freeIndicesStack; // Fast O(1) allocation
@property (nonatomic, strong) dispatch_queue_t particleIndexQueue; // Serial queue for free list updates
@property (nonatomic, strong) NSMutableArray<NSNumber *> *aliveIndicesArray; // Sparse array of alive particle indices
@property (nonatomic, strong) NSMutableDictionary<NSNumber *, NSNumber *> *indexToAlivePosition; // Maps particle index to position in aliveIndicesArray
@property (nonatomic, strong) id<MTLBuffer> previousFrameBuffer; // Buffer storing previous frame's particle data for async rendering
@property (nonatomic) BOOL hasPreviousFrame; // Whether we have valid previous frame data
@property (nonatomic, strong) dispatch_semaphore_t frameFence; // Semaphore ensuring only 1 frame in flight for async mode
@property (nonatomic, strong) id<MTLDevice> metalDevice;
@property (nonatomic, strong) id<MTLCommandQueue> commandQueue;
@property (nonatomic, strong) id<MTLComputePipelineState> computePipeline;
@property (nonatomic, strong) id<MTLComputePipelineState> initializePipeline;
@property (nonatomic, strong) id<MTLBuffer> particleBuffer;
@property (nonatomic, strong) id<MTLBuffer> uniformsBuffer;
@property (nonatomic, strong) id<MTLLibrary> shaderLibrary;
@property (nonatomic) BOOL supportsMetalSimulation;
@property (nonatomic) BOOL updateHandlerForcesCPU;
@property (nonatomic, readonly) NSUInteger stateStride;
- (void)markStateDirtyAtIndex:(NSUInteger)index;
- (void)markAllStatesDirty;
@end

@implementation SSKParticleSystem

- (instancetype)initWithCapacity:(NSUInteger)capacity {
    NSParameterAssert(capacity > 0);
    if ((self = [super init])) {
        _capacity = capacity;
        _particles = [NSMutableArray arrayWithCapacity:capacity];
        _availableIndices = [NSMutableIndexSet indexSetWithIndexesInRange:NSMakeRange(0, capacity)];
        // Phase 3: Optimized index management - use stack for O(1) allocation
        _freeIndicesStack = [NSMutableArray arrayWithCapacity:capacity];
        for (NSUInteger i = 0; i < capacity; i++) {
            [_freeIndicesStack addObject:@(i)];
        }
        _particleIndexQueue = dispatch_queue_create("com.ssk.particleIndex", DISPATCH_QUEUE_SERIAL);
        // Alive particle tracking optimization
        _aliveIndicesArray = [NSMutableArray arrayWithCapacity:MIN(capacity, (NSUInteger)1024)];
        _indexToAlivePosition = [NSMutableDictionary dictionaryWithCapacity:MIN(capacity, (NSUInteger)1024)];
        _blendMode = SSKParticleBlendModeAlpha;
        _gravity = NSZeroPoint;
        _globalDamping = 0.0;
        _cullingEnabled = NO;
        _cullingRect = CGRectZero;
        _cullingMargin = 0.0;
        _lengthMultiplier = 8.0;
        _synchronizesMetalSimulation = YES;
        _synchronizesMetalSpawn = YES;

        [self setUpMetalResourcesWithCapacity:capacity];
        if (!_states) {
            _states = calloc(capacity, sizeof(SSKParticleState));
        }

        for (NSUInteger i = 0; i < capacity; i++) {
            _states[i] = (SSKParticleState){0};
            _states[i].size = 1.0f;
            _states[i].baseSize = 1.0f;
            _states[i].maxLife = 1.0f;
            _states[i].color = (vector_float4){1,1,1,1};
            _states[i].baseColor = (vector_float4){1,1,1,1};
            _states[i].sizeRange = (vector_float2){1,1};
            SSKParticle *particle = [[SSKParticle alloc] initWithState:&_states[i] index:i];
            [_particles addObject:particle];
        }

        _metalSimulationEnabled = self.supportsMetalSimulation;
        if (_metalSimulationEnabled) {
            [self markAllStatesDirty];
        }
    }
    return self;
}

- (void)dealloc {
    if (!self.particleBuffer && self.states) {
        free(self.states);
    }
}

- (void)setUpMetalResourcesWithCapacity:(NSUInteger)capacity {
    id<MTLDevice> device = MTLCreateSystemDefaultDevice();
    if (!device) {
        NSLog(@"SSKParticleSystem: no Metal device available; using CPU path.");
        return;
    }

    id<MTLCommandQueue> queue = [device newCommandQueue];
    if (!queue) {
        NSLog(@"SSKParticleSystem: failed to create Metal command queue; using CPU path.");
        return;
    }

    NSError *error = nil;
    
    // Try to load from bundle first (for initializeParticles kernel)
    id<MTLLibrary> library = nil;
    NSBundle *bundle = [NSBundle bundleForClass:self.class];
    NSString *metallibPath = [bundle pathForResource:@"SSKParticleShaders" ofType:@"metallib"];
    if (metallibPath.length > 0) {
        NSURL *metallibURL = [NSURL fileURLWithPath:metallibPath];
        library = [device newLibraryWithURL:metallibURL error:&error];
    }
    
    // Fallback: compile full shader source if metallib missing
    if (!library) {
        NSString *metalSourcePath = [bundle pathForResource:@"SSKParticleShaders" ofType:@"metal"];
        if (!metalSourcePath) {
            // Walk upwards and check current directory for source (common in tests/demos)
            NSString *probe = bundle.bundlePath;
            for (NSUInteger i = 0; i < 5 && probe.length > 1; i++) {
                NSString *candidate = [probe stringByAppendingPathComponent:@"ScreenSaverKit/Shaders/SSKParticleShaders.metal"];
                if ([[NSFileManager defaultManager] fileExistsAtPath:candidate]) {
                    metalSourcePath = candidate;
                    break;
                }
                probe = [probe stringByDeletingLastPathComponent];
            }
            if (!metalSourcePath) {
                NSString *cwd = [[NSFileManager defaultManager] currentDirectoryPath];
                NSString *candidate = [cwd stringByAppendingPathComponent:@"ScreenSaverKit/Shaders/SSKParticleShaders.metal"];
                if ([[NSFileManager defaultManager] fileExistsAtPath:candidate]) {
                    metalSourcePath = candidate;
                }
            }
        }
        if (metalSourcePath.length > 0) {
            NSError *readError = nil;
            NSString *source = [NSString stringWithContentsOfFile:metalSourcePath encoding:NSUTF8StringEncoding error:&readError];
            if (!source) {
                NSLog(@"SSKParticleSystem: failed to read Metal source at %@ (%@).", metalSourcePath, readError.localizedDescription ?: @"unknown error");
            } else {
                library = [device newLibraryWithSource:source options:nil error:&error];
                if (!library) {
                    NSLog(@"SSKParticleSystem: failed to compile Metal source at %@ (%@).", metalSourcePath, error.localizedDescription ?: @"unknown error");
                }
            }
        }
    }
    
    // Fallback to template for simulateParticles only if nothing else worked
    if (!library) {
        NSString *source = [NSString stringWithFormat:kSSKParticleComputeTemplate,
                            kSSKParticleBehaviorFadeAlpha,
                            kSSKParticleBehaviorFadeSize];
        library = [device newLibraryWithSource:source options:nil error:&error];
        if (!library) {
            NSLog(@"SSKParticleSystem: failed to compile Metal compute shaders: %@", error);
            return;
        }
    }

    id<MTLFunction> kernel = [library newFunctionWithName:@"simulateParticles"];
    if (!kernel) {
        // Some metallib builds may omit the compute kernel; fallback to the built-in template.
        NSString *source = [NSString stringWithFormat:kSSKParticleComputeTemplate,
                            kSSKParticleBehaviorFadeAlpha,
                            kSSKParticleBehaviorFadeSize];
        NSError *compileError = nil;
        id<MTLLibrary> fallbackLibrary = [device newLibraryWithSource:source options:nil error:&compileError];
        if (!fallbackLibrary) {
            NSLog(@"SSKParticleSystem: simulateParticles kernel missing and fallback compile failed: %@", compileError);
            return;
        }
        library = fallbackLibrary;
        kernel = [library newFunctionWithName:@"simulateParticles"];
        if (!kernel) {
            NSLog(@"SSKParticleSystem: simulateParticles kernel missing after fallback compile; using CPU path.");
            return;
        }
    }

    id<MTLComputePipelineState> pipeline = [device newComputePipelineStateWithFunction:kernel error:&error];
    if (!pipeline) {
        NSLog(@"SSKParticleSystem: failed to create compute pipeline: %@", error);
        return;
    }
    
    // Try to create initialization pipeline (may not be available if using source template)
    id<MTLFunction> initKernel = [library newFunctionWithName:@"initializeParticles"];
    id<MTLComputePipelineState> initPipeline = nil;
    if (initKernel) {
        initPipeline = [device newComputePipelineStateWithFunction:initKernel error:&error];
        if (!initPipeline) {
            NSLog(@"SSKParticleSystem: failed to create initialization pipeline: %@", error);
        }
    }

    id<MTLBuffer> particleBuffer = [device newBufferWithLength:capacity * sizeof(SSKParticleState)
                                                       options:MTLResourceStorageModeShared];
    if (!particleBuffer) {
        NSLog(@"SSKParticleSystem: failed to create particle buffer; using CPU path.");
        return;
    }

    id<MTLBuffer> uniformsBuffer = [device newBufferWithLength:sizeof(SSKParticleSimulationUniforms)
                                                       options:MTLResourceStorageModeShared];
    if (!uniformsBuffer) {
        NSLog(@"SSKParticleSystem: failed to create uniforms buffer; using CPU path.");
        return;
    }

    // Create previous frame buffer for async rendering mode
    id<MTLBuffer> previousFrameBuffer = [device newBufferWithLength:capacity * sizeof(SSKParticleState)
                                                            options:MTLResourceStorageModeShared];
    if (!previousFrameBuffer) {
        NSLog(@"SSKParticleSystem: failed to create previous frame buffer; async rendering unavailable.");
    }

    self.metalDevice = device;
    self.commandQueue = queue;
    self.computePipeline = pipeline;
    self.initializePipeline = initPipeline;
    self.shaderLibrary = library;
    self.particleBuffer = particleBuffer;
    self.uniformsBuffer = uniformsBuffer;
    self.previousFrameBuffer = previousFrameBuffer;
    self.frameFence = dispatch_semaphore_create(1);
    self.hasPreviousFrame = NO;
    self.metalSimulationRenderMode = SSKMetalSimulationRenderModeBlocking;
    self.states = particleBuffer.contents;
    self.supportsMetalSimulation = YES;
}

- (void)setUpdateHandler:(SSKParticleUpdater)updateHandler {
    _updateHandler = [updateHandler copy];
    self.updateHandlerForcesCPU = (_updateHandler != nil);
    if (self.updateHandlerForcesCPU) {
        _metalSimulationEnabled = NO;
    } else if (self.supportsMetalSimulation) {
        _metalSimulationEnabled = YES;
        [self markAllStatesDirty];
    }
}

- (void)setMetalSimulationEnabled:(BOOL)metalSimulationEnabled {
    if (metalSimulationEnabled && !self.supportsMetalSimulation && !self.updateHandlerForcesCPU) {
        // Retry Metal setup in case initial init failed (e.g. missing metallib in test bundles).
        [self setUpMetalResourcesWithCapacity:self.capacity];
    }
    if (!self.supportsMetalSimulation || self.updateHandlerForcesCPU) {
        _metalSimulationEnabled = NO;
        return;
    }
    _metalSimulationEnabled = metalSimulationEnabled;
    if (_metalSimulationEnabled) {
        [self markAllStatesDirty];
    }
}

- (NSUInteger)aliveParticleCount {
    NSUInteger freeCount = self.freeIndicesStack.count;
    if (freeCount > self.capacity) {
        freeCount = self.capacity;
    }
    return self.capacity - freeCount;
}

- (void)spawnParticles:(NSUInteger)count initializer:(SSKParticleInitializer)initializer {
    if (count == 0 || !initializer) { return; }
    
    // Phase 1.1 & 3: Batch index collection using optimized stack-based free list
    NSUInteger availableCount = self.freeIndicesStack.count;
    NSUInteger actualCount = MIN(count, availableCount);
    if (actualCount == 0) { return; }
    
    NSUInteger *indices = (NSUInteger *)malloc(actualCount * sizeof(NSUInteger));
    if (!indices) { return; }
    
    // Phase 3: O(1) allocation from stack
    NSUInteger collected = 0;
    while (collected < actualCount && self.freeIndicesStack.count > 0) {
        NSNumber *indexNum = [self.freeIndicesStack lastObject];
        [self.freeIndicesStack removeLastObject];
        NSUInteger index = [indexNum unsignedIntegerValue];
        indices[collected++] = index;
        // Keep availableIndices in sync for compatibility
        [self.availableIndices removeIndex:index];
    }
    
    // Phase 1.4: Optimized state initialization - use direct struct manipulation
    // Default particle state template
    SSKParticleState defaultState = {0};
    defaultState.alive = 1u;
    defaultState.size = 1.0f;
    defaultState.baseSize = 1.0f;
    defaultState.maxLife = 1.0f;
    defaultState.color = (vector_float4){1,1,1,1};
    defaultState.baseColor = (vector_float4){1,1,1,1};
    defaultState.sizeRange = (vector_float2){1,1};
    
    // Phase 1.2: Direct state manipulation - batch initialize states
    NSUInteger minIndex = NSNotFound;
    NSUInteger maxIndex = 0;
    
    for (NSUInteger i = 0; i < collected; i++) {
        NSUInteger idx = indices[i];
        SSKParticleState *state = &self.states[idx];
        
        // Copy default state template
        *state = defaultState;
        
        // Update particle wrapper's state pointer (in case it changed)
        SSKParticle *particle = self.particles[idx];
        particle.state = state;
        
        // Track range for batched dirty marking
        if (minIndex == NSNotFound || idx < minIndex) {
            minIndex = idx;
        }
        if (idx > maxIndex) {
            maxIndex = idx;
        }
        
        // Phase 1.2: Only use property setters for user-provided initializer
        initializer(particle);

        // Ensure baseSize is set if not already
        if (state->baseSize <= 0.0f) {
            state->baseSize = state->size;
        }

        // Add to alive tracking
        [self.aliveIndicesArray addObject:@(idx)];
        [self.indexToAlivePosition setObject:@(self.aliveIndicesArray.count - 1) forKey:@(idx)];
    }
    
    // Phase 1.3: Batched dirty marking - single call for all modified particles
    if (minIndex != NSNotFound && self.particleBuffer) {
        NSUInteger stride = self.stateStride;
        NSUInteger startOffset = minIndex * stride;
        NSUInteger endOffset = (maxIndex + 1) * stride;
        NSUInteger rangeLength = endOffset - startOffset;
        
        if (startOffset + rangeLength <= self.particleBuffer.length) {
            [self.particleBuffer didModifyRange:NSMakeRange(startOffset, rangeLength)];
        } else {
            // Fallback: mark entire buffer if range exceeds bounds
            [self markAllStatesDirty];
        }
    }
    
    free(indices);
}

- (NSUInteger)spawnParticlesGPU:(NSUInteger)count parameters:(SSKParticleSpawnParameters)parameters {
    if (count == 0) { return 0; }
    
    // Fallback to CPU if GPU resources unavailable
    if (!self.initializePipeline || !self.commandQueue || !self.particleBuffer || !self.metalDevice) {
        // Could fall back to CPU spawn here, but for now just return 0
        return 0;
    }
    
    // Phase 3: Collect available indices using optimized stack-based free list
    NSUInteger availableCount = self.freeIndicesStack.count;
    NSUInteger actualCount = MIN(count, availableCount);
    if (actualCount == 0) { return 0; }
    
    NSUInteger *indices = (NSUInteger *)malloc(actualCount * sizeof(NSUInteger));
    if (!indices) { return 0; }
    
    // Phase 3: O(1) allocation from stack
    NSUInteger collected = 0;
    while (collected < actualCount && self.freeIndicesStack.count > 0) {
        NSNumber *indexNum = [self.freeIndicesStack lastObject];
        [self.freeIndicesStack removeLastObject];
        NSUInteger index = [indexNum unsignedIntegerValue];
        indices[collected++] = index;
        // Keep availableIndices in sync for compatibility
        [self.availableIndices removeIndex:index];
    }
    
    // Create buffers for GPU initialization
    NSUInteger indicesBufferSize = actualCount * sizeof(uint32_t);
    id<MTLBuffer> indicesBuffer = [self.metalDevice newBufferWithBytes:indices
                                                                 length:indicesBufferSize
                                                                options:MTLResourceStorageModeShared];
    if (!indicesBuffer) {
        free(indices);
        return 0;
    }
    
    // Convert parameters to Metal-compatible struct (must match shader struct layout exactly)
    typedef struct __attribute__((aligned(16))) {
        uint32_t regionType;
        float padding0; // Align to 16 bytes for vector_float2
        vector_float2 center;
        vector_float2 size;
        vector_float2 velocityXRange;
        vector_float2 velocityYRange;
        vector_float2 speedRange;
        float directionAngle;
        float directionSpread;
        vector_float2 sizeRange;
        vector_float2 lifeRange;
        vector_float4 colorMin;
        vector_float4 colorMax;
        vector_float2 rotationVelocityRange;
        vector_float2 dampingRange;
        uint32_t behaviorOptions;
        float padding1; // Align to 16 bytes for vector_float2
        vector_float2 sizeOverLifeRange;
        uint32_t zDepthEnabled;
        float zDepthScale;
        float lengthMultiplier;
        float padding2; // Align to 16 bytes
    } MetalSpawnParameters;
    
    MetalSpawnParameters metalParams = {0};
    metalParams.regionType = (uint32_t)parameters.regionType;
    metalParams.center = parameters.center;
    metalParams.size = parameters.size;
    metalParams.velocityXRange = parameters.velocityXRange;
    metalParams.velocityYRange = parameters.velocityYRange;
    metalParams.speedRange = parameters.speedRange;
    metalParams.directionAngle = parameters.directionAngle;
    metalParams.directionSpread = parameters.directionSpread;
    metalParams.sizeRange = parameters.sizeRange;
    metalParams.lifeRange = parameters.lifeRange;
    metalParams.colorMin = parameters.colorMin;
    metalParams.colorMax = parameters.colorMax;
    metalParams.rotationVelocityRange = parameters.rotationVelocityRange;
    metalParams.dampingRange = parameters.dampingRange;
    metalParams.behaviorOptions = parameters.behaviorOptions;
    metalParams.sizeOverLifeRange = parameters.sizeOverLifeRange;
    metalParams.zDepthEnabled = parameters.zDepthEnabled;
    // Clamp to reasonable ranges to avoid degenerate lengths or fully collapsed depth.
    float clampedScale = fminf(fmaxf(parameters.zDepthScale, 0.1f), 100.0f);
    float clampedLengthMult = fmaxf(parameters.lengthMultiplier, 0.1f);
    metalParams.zDepthScale = clampedScale;
    metalParams.lengthMultiplier = clampedLengthMult;
    
    // Store length multiplier for renderer access when z-depth is enabled
    if (parameters.zDepthEnabled != 0) {
        self.lengthMultiplier = clampedLengthMult;
    }
    
    id<MTLBuffer> paramsBuffer = [self.metalDevice newBufferWithBytes:&metalParams
                                                                length:sizeof(MetalSpawnParameters)
                                                               options:MTLResourceStorageModeShared];
    if (!paramsBuffer) {
        free(indices);
        return 0;
    }
    
    uint32_t countValue = (uint32_t)actualCount;
    id<MTLBuffer> countBuffer = [self.metalDevice newBufferWithBytes:&countValue
                                                               length:sizeof(uint32_t)
                                                              options:MTLResourceStorageModeShared];
    if (!countBuffer) {
        free(indices);
        return 0;
    }
    
    // Dispatch compute shader
    id<MTLCommandBuffer> commandBuffer = [self.commandQueue commandBuffer];
    if (!commandBuffer) {
        free(indices);
        return 0;
    }
    
    id<MTLComputeCommandEncoder> encoder = [commandBuffer computeCommandEncoder];
    [encoder setComputePipelineState:self.initializePipeline];
    [encoder setBuffer:self.particleBuffer offset:0 atIndex:0];
    [encoder setBuffer:paramsBuffer offset:0 atIndex:1];
    [encoder setBuffer:indicesBuffer offset:0 atIndex:2];
    [encoder setBuffer:countBuffer offset:0 atIndex:3];
    
    NSUInteger threadWidth = MAX(self.initializePipeline.threadExecutionWidth, (NSUInteger)1);
    NSUInteger maxThreads = MAX(self.initializePipeline.maxTotalThreadsPerThreadgroup, (NSUInteger)1);
    NSUInteger threadGroupSize = MIN(maxThreads, threadWidth * 8); // heuristic multiple of SIMD width
    threadGroupSize = MAX(threadGroupSize, (NSUInteger)1);
    NSUInteger threadGroups = (actualCount + threadGroupSize - 1) / threadGroupSize;
    MTLSize threadsPerGroup = MTLSizeMake(threadGroupSize, 1, 1);
    MTLSize threadgroupCount = MTLSizeMake(threadGroups, 1, 1);
    [encoder dispatchThreadgroups:threadgroupCount threadsPerThreadgroup:threadsPerGroup];
    [encoder endEncoding];
    
    // Update particle wrapper state pointers and mark dirty
    NSUInteger minIndex = NSNotFound;
    NSUInteger maxIndex = 0;
    for (NSUInteger i = 0; i < collected; i++) {
        NSUInteger idx = indices[i];
        SSKParticle *particle = self.particles[idx];
        particle.state = &self.states[idx];

        // Add to alive tracking
        [self.aliveIndicesArray addObject:@(idx)];
        [self.indexToAlivePosition setObject:@(self.aliveIndicesArray.count - 1) forKey:@(idx)];

        if (minIndex == NSNotFound || idx < minIndex) {
            minIndex = idx;
        }
        if (idx > maxIndex) {
            maxIndex = idx;
        }
    }
    
    // Batched dirty marking
    __block BOOL hasRange = (minIndex != NSNotFound && self.particleBuffer);
    __block NSUInteger startOffset = 0;
    __block NSUInteger rangeLength = 0;
    if (hasRange) {
        NSUInteger stride = self.stateStride;
        startOffset = minIndex * stride;
        NSUInteger endOffset = (maxIndex + 1) * stride;
        rangeLength = endOffset - startOffset;
        if (startOffset + rangeLength > self.particleBuffer.length) {
            hasRange = NO;
        }
    }

    [commandBuffer addCompletedHandler:^(__unused id<MTLCommandBuffer> buffer) {
        if (!hasRange || !self.particleBuffer) { return; }
        [self.particleBuffer didModifyRange:NSMakeRange(startOffset, rangeLength)];
    }];

    [commandBuffer commit];
    if (self.synchronizesMetalSpawn) {
        [commandBuffer waitUntilCompleted];
    }
    
    free(indices);
    return collected;
}

- (void)advanceBy:(NSTimeInterval)dt {
    if (dt <= 0.0) { return; }
    if (self.isMetalSimulationEnabled && self.supportsMetalSimulation) {
        [self advanceWithMetal:dt];
    } else {
        [self advanceOnCPU:dt];
    }
}

- (void)advanceOnCPU:(NSTimeInterval)dt {
    vector_float2 gravityVec = SSKVectorFromPoint(self.gravity);
    BOOL hasGravity = !simd_equal(gravityVec, (vector_float2){0, 0});

    for (NSUInteger idx = 0; idx < self.capacity; idx++) {
        SSKParticleState *state = &self.states[idx];
        if (!state->alive) { continue; }

        state->life += (float)dt;
        if (state->life >= state->maxLife) {
            state->alive = 0u;
            // Remove from alive tracking
            [self removeFromAliveTracking:idx];
            // Phase 3: O(1) deallocation to stack
            [self.freeIndicesStack addObject:@(idx)];
            [self.availableIndices addIndex:idx];
            continue;
        }

        if (hasGravity) {
            state->velocity += gravityVec * (float)dt;
        }

        float damping = fmaxf(0.0f, state->damping + (float)self.globalDamping);
        if (damping > 0.0f) {
            float factor = powf(fmaxf(0.0f, 1.0f - damping), (float)dt);
            state->velocity *= factor;
        }

        if (self.updateHandler) {
            self.updateHandler(self.particles[idx], dt);
        }

        [self applyAutomaticBehavioursToState:state delta:dt];

        state->position += state->velocity * (float)dt;
        state->rotation += state->rotationVelocity * (float)dt;

        if (SSKShouldCullParticle(self, state->position)) {
            state->alive = 0u;
            // Remove from alive tracking
            [self removeFromAliveTracking:idx];
            [self.freeIndicesStack addObject:@(idx)];
            [self.availableIndices addIndex:idx];
            continue;
        }

        float velocityLengthSquared = simd_length_squared(state->velocity);
        if (velocityLengthSquared > 0.0001f) {
            state->userVector = simd_normalize(state->velocity);
        }
    }
}

- (void)advanceWithMetal:(NSTimeInterval)dt {
    if (!self.computePipeline || !self.commandQueue || !self.particleBuffer || !self.uniformsBuffer) {
        [self advanceOnCPU:dt];
        return;
    }

    // Wait for previous frame's GPU work to complete (async mode only)
    if (self.metalSimulationRenderMode == SSKMetalSimulationRenderModePreviousFrame && self.frameFence) {
        dispatch_semaphore_wait(self.frameFence, DISPATCH_TIME_FOREVER);
    }

    // Copy current state to previous frame buffer (before simulation)
    if (self.metalSimulationRenderMode == SSKMetalSimulationRenderModePreviousFrame &&
        self.previousFrameBuffer && self.particleBuffer) {
        memcpy(self.previousFrameBuffer.contents,
               self.particleBuffer.contents,
               self.capacity * sizeof(SSKParticleState));
        self.hasPreviousFrame = YES;
    }

    SSKParticleSimulationUniforms *uniforms = self.uniformsBuffer.contents;
    uniforms->gravity = SSKVectorFromPoint(self.gravity);
    uniforms->dt = (float)dt;
    uniforms->globalDamping = (float)self.globalDamping;
    uniforms->padding = 0.0f;

    id<MTLCommandBuffer> commandBuffer = [self.commandQueue commandBuffer];
    id<MTLComputeCommandEncoder> encoder = [commandBuffer computeCommandEncoder];
    [encoder setComputePipelineState:self.computePipeline];
    [encoder setBuffer:self.particleBuffer offset:0 atIndex:0];
    [encoder setBuffer:self.uniformsBuffer offset:0 atIndex:1];

    NSUInteger aliveCount = [self aliveParticleCount];
    if (aliveCount == 0) {
        return;
    }
    NSUInteger threadCount = aliveCount;
    NSUInteger threadWidth = MAX(self.computePipeline.threadExecutionWidth, (NSUInteger)1);
    NSUInteger maxThreads = MAX(self.computePipeline.maxTotalThreadsPerThreadgroup, (NSUInteger)1);
    NSUInteger threadGroupSize = MIN(maxThreads, threadWidth * 8); // heuristic multiple of SIMD width
    threadGroupSize = MAX(threadGroupSize, (NSUInteger)1);
    NSUInteger threadGroups = (threadCount + threadGroupSize - 1) / threadGroupSize;
    MTLSize threadsPerGroup = MTLSizeMake(threadGroupSize, 1, 1);
    MTLSize threadgroupCount = MTLSizeMake(threadGroups, 1, 1);
    [encoder dispatchThreadgroups:threadgroupCount threadsPerThreadgroup:threadsPerGroup];
    [encoder endEncoding];

    __weak typeof(self) weakSelf = self;
    [commandBuffer addCompletedHandler:^(__unused id<MTLCommandBuffer> buffer) {
        __strong typeof(self) strongSelf = weakSelf;
        if (!strongSelf) { return; }
        dispatch_async(strongSelf.particleIndexQueue, ^{
            // Only add indices that are dead AND not already in availableIndices
            // This prevents duplicates when particles die, get reused, then die again
            for (NSUInteger idx = 0; idx < strongSelf.capacity; idx++) {
                SSKParticleState *state = &strongSelf.states[idx];
                if (SSKShouldCullParticle(strongSelf, state->position)) {
                    state->alive = 0u;
                }
                if (!state->alive && ![strongSelf.availableIndices containsIndex:idx]) {
                    // Remove from alive tracking
                    [strongSelf removeFromAliveTracking:idx];
                    // Phase 3: O(1) deallocation to stack - only add newly dead particles
                    [strongSelf.freeIndicesStack addObject:@(idx)];
                    [strongSelf.availableIndices addIndex:idx];
                }
            }

            // Signal frame fence for async mode
            if (strongSelf.metalSimulationRenderMode == SSKMetalSimulationRenderModePreviousFrame &&
                strongSelf.frameFence) {
                dispatch_semaphore_signal(strongSelf.frameFence);
            }
        });
    }];

    [commandBuffer commit];
    if (self.synchronizesMetalSimulation ||
        self.metalSimulationRenderMode == SSKMetalSimulationRenderModeBlocking) {
        // Ensure CPU snapshots observe the freshly simulated data this frame.
        [commandBuffer waitUntilCompleted];
    }
    // In PreviousFrame mode, don't wait - let GPU run async
}

- (void)applyAutomaticBehavioursToState:(SSKParticleState *)state delta:(NSTimeInterval)dt {
    if (fabsf(state->sizeVelocity) > 0.0001f) {
        state->size = fmaxf(0.0f, state->size + state->sizeVelocity * (float)dt);
    }

    if (state->behaviorFlags == 0u) { return; }

    float normalized = (state->maxLife > 0.0f) ? fminf(fmaxf(state->life / state->maxLife, 0.0f), 1.0f) : 0.0f;

    if ((state->behaviorFlags & kSSKParticleBehaviorFadeAlpha) != 0u) {
        float fade = 1.0f - normalized;
        state->color = (vector_float4){state->baseColor.x,
                                       state->baseColor.y,
                                       state->baseColor.z,
                                       state->baseColor.w * fade};
    }

    if ((state->behaviorFlags & kSSKParticleBehaviorFadeSize) != 0u) {
        float multiplier = state->sizeRange.x + (state->sizeRange.y - state->sizeRange.x) * normalized;
        state->size = fmaxf(0.0f, state->baseSize * multiplier);
    }
}

- (void)drawInContext:(CGContextRef)ctx {
    if (!ctx) { return; }

    CGContextSaveGState(ctx);
    if (self.blendMode == SSKParticleBlendModeAdditive) {
        CGContextSetBlendMode(ctx, kCGBlendModePlusLighter);
    } else {
        CGContextSetBlendMode(ctx, kCGBlendModeNormal);
    }

    for (NSUInteger idx = 0; idx < self.capacity; idx++) {
        SSKParticleState *state = &self.states[idx];
        if (!state->alive) { continue; }

        SSKParticle *particle = self.particles[idx];
        if (self.renderHandler) {
            self.renderHandler(ctx, particle);
            continue;
        }

        CGFloat size = MAX(0.0, particle.size);
        CGRect rect = CGRectMake(particle.position.x - size * 0.5,
                                 particle.position.y - size * 0.5,
                                 size,
                                 size);

        NSColor *renderColor = particle.color ?: [NSColor whiteColor];
        CGFloat blurScale = (self.blendMode == SSKParticleBlendModeAdditive) ? 0.9 : 0.6;
        CGFloat blurRadius = size * blurScale;
        CGColorRef blurColor = CGColorCreateCopyWithAlpha(renderColor.CGColor, renderColor.alphaComponent * 0.85);

        CGContextSetFillColorWithColor(ctx, renderColor.CGColor);
        if (blurColor) {
            CGContextSetShadowWithColor(ctx, CGSizeZero, blurRadius, blurColor);
        }

        if (fabs(particle.rotation) > 0.001) {
            CGContextSaveGState(ctx);
            CGContextTranslateCTM(ctx, particle.position.x, particle.position.y);
            CGContextRotateCTM(ctx, particle.rotation);
            CGContextTranslateCTM(ctx, -particle.position.x, -particle.position.y);
            CGContextFillEllipseInRect(ctx, rect);
            CGContextRestoreGState(ctx);
        } else {
            CGContextFillEllipseInRect(ctx, rect);
        }

        if (blurColor) {
            CGContextSetShadowWithColor(ctx, CGSizeZero, 0.0, NULL);
            CGColorRelease(blurColor);
        }
    }

    CGContextRestoreGState(ctx);
}

- (void)reset {
    for (NSUInteger idx = 0; idx < self.capacity; idx++) {
        SSKParticleState *state = &self.states[idx];
        *state = (SSKParticleState){0};
        state->size = 1.0f;
        state->baseSize = 1.0f;
        state->maxLife = 1.0f;
        state->color = (vector_float4){1,1,1,1};
        state->baseColor = (vector_float4){1,1,1,1};
        state->sizeRange = (vector_float2){1,1};
    }
    // Phase 3: Reset free indices stack
    [self.freeIndicesStack removeAllObjects];
    for (NSUInteger i = 0; i < self.capacity; i++) {
        [self.freeIndicesStack addObject:@(i)];
    }
    [self.availableIndices removeAllIndexes];
    [self.availableIndices addIndexesInRange:NSMakeRange(0, self.capacity)];
    // Reset alive tracking
    [self.aliveIndicesArray removeAllObjects];
    [self.indexToAlivePosition removeAllObjects];
    [self markAllStatesDirty];
}

- (NSArray<SSKParticle *> *)aliveParticlesSnapshot {
    NSMutableArray<SSKParticle *> *alive = self.aliveScratch;
    if (!alive) {
        alive = [NSMutableArray arrayWithCapacity:MIN(self.capacity, (NSUInteger)64)];
        self.aliveScratch = alive;
    }
    if (alive.count > 0) {
        [alive removeAllObjects];
    }

    // Determine which buffer to read from based on rendering mode
    SSKParticleState *sourceStates = self.states;
    if (self.metalSimulationRenderMode == SSKMetalSimulationRenderModePreviousFrame &&
        self.hasPreviousFrame &&
        self.previousFrameBuffer) {
        sourceStates = (SSKParticleState *)self.previousFrameBuffer.contents;
    }

    // Optimized: iterate only alive indices instead of all capacity
    for (NSNumber *indexNum in self.aliveIndicesArray) {
        NSUInteger idx = [indexNum unsignedIntegerValue];
        if (sourceStates == self.states) {
            // Using current frame data - use existing particle wrappers
            [alive addObject:self.particles[idx]];
        } else {
            // Using previous frame data - create temporary particle wrapper
            SSKParticle *particle = [[SSKParticle alloc] initWithState:&sourceStates[idx] index:idx];
            [alive addObject:particle];
        }
    }

    return alive;
}

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

- (NSUInteger)stateStride {
    return sizeof(SSKParticleState);
}

- (void)markStateDirtyAtIndex:(NSUInteger)index {
    if (!self.particleBuffer) { return; }
    NSUInteger stride = self.stateStride;
    NSUInteger offset = index * stride;
    if (offset + stride > self.particleBuffer.length) { return; }
    [self.particleBuffer didModifyRange:NSMakeRange(offset, stride)];
}

- (void)markAllStatesDirty {
    if (!self.particleBuffer) { return; }
    NSUInteger stride = self.stateStride;
    NSUInteger length = stride * self.capacity;
    length = MIN(length, self.particleBuffer.length);
    if (length == 0) { return; }
    [self.particleBuffer didModifyRange:NSMakeRange(0, length)];
}

- (void)removeFromAliveTracking:(NSUInteger)index {
    NSNumber *indexNum = @(index);
    NSNumber *positionNum = [self.indexToAlivePosition objectForKey:indexNum];
    if (!positionNum) { return; }

    NSUInteger position = [positionNum unsignedIntegerValue];
    NSUInteger lastPos = self.aliveIndicesArray.count - 1;

    if (position != lastPos) {
        // Swap with last element for O(1) removal
        NSNumber *lastIndex = self.aliveIndicesArray[lastPos];
        self.aliveIndicesArray[position] = lastIndex;
        self.indexToAlivePosition[lastIndex] = @(position);
    }

    [self.aliveIndicesArray removeLastObject];
    [self.indexToAlivePosition removeObjectForKey:indexNum];
}

@end
