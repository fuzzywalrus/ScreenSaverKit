#import "SSKParticleSystem.h"

#import <Metal/Metal.h>
#import <simd/simd.h>
#import <math.h>

#import "SSKMetalParticleRenderer.h"
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
@property (nonatomic, strong) NSMutableIndexSet *availableIndices;
@property (nonatomic, strong) id<MTLDevice> metalDevice;
@property (nonatomic, strong) id<MTLCommandQueue> commandQueue;
@property (nonatomic, strong) id<MTLComputePipelineState> computePipeline;
@property (nonatomic, strong) id<MTLBuffer> particleBuffer;
@property (nonatomic, strong) id<MTLBuffer> uniformsBuffer;
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
        _blendMode = SSKParticleBlendModeAlpha;
        _gravity = NSZeroPoint;
        _globalDamping = 0.0;

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
    if (!device) { return; }

    id<MTLCommandQueue> queue = [device newCommandQueue];
    if (!queue) { return; }

    NSError *error = nil;
    NSString *source = [NSString stringWithFormat:kSSKParticleComputeTemplate,
                        kSSKParticleBehaviorFadeAlpha,
                        kSSKParticleBehaviorFadeSize];
    id<MTLLibrary> library = [device newLibraryWithSource:source options:nil error:&error];
    if (!library) {
        NSLog(@"SSKParticleSystem: failed to compile Metal compute shaders: %@", error);
        return;
    }

    id<MTLFunction> kernel = [library newFunctionWithName:@"simulateParticles"];
    if (!kernel) { return; }

    id<MTLComputePipelineState> pipeline = [device newComputePipelineStateWithFunction:kernel error:&error];
    if (!pipeline) {
        NSLog(@"SSKParticleSystem: failed to create compute pipeline: %@", error);
        return;
    }

    id<MTLBuffer> particleBuffer = [device newBufferWithLength:capacity * sizeof(SSKParticleState)
                                                       options:MTLResourceStorageModeShared];
    if (!particleBuffer) { return; }

    id<MTLBuffer> uniformsBuffer = [device newBufferWithLength:sizeof(SSKParticleSimulationUniforms)
                                                       options:MTLResourceStorageModeShared];
    if (!uniformsBuffer) { return; }

    self.metalDevice = device;
    self.commandQueue = queue;
    self.computePipeline = pipeline;
    self.particleBuffer = particleBuffer;
    self.uniformsBuffer = uniformsBuffer;
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
    NSUInteger count = 0;
    for (NSUInteger i = 0; i < self.capacity; i++) {
        if (self.states[i].alive) { count++; }
    }
    return count;
}

- (void)spawnParticles:(NSUInteger)count initializer:(SSKParticleInitializer)initializer {
    if (count == 0 || !initializer) { return; }
    NSUInteger emitted = 0;
    while (emitted < count) {
        NSUInteger index = [self.availableIndices firstIndex];
        if (index == NSNotFound) { break; }
        [self.availableIndices removeIndex:index];

        SSKParticleState *state = &self.states[index];
        *state = (SSKParticleState){0};
        state->alive = 1u;
        state->size = 1.0f;
        state->baseSize = 1.0f;
        state->maxLife = 1.0f;
        state->color = (vector_float4){1,1,1,1};
        state->baseColor = (vector_float4){1,1,1,1};
        state->sizeRange = (vector_float2){1,1};

        SSKParticle *particle = self.particles[index];
        particle.state = state;
        particle.life = 0.0;
        particle.position = NSZeroPoint;
        particle.velocity = NSZeroPoint;
        particle.color = [NSColor whiteColor];
        particle.rotation = 0.0;
        particle.rotationVelocity = 0.0;
        particle.damping = 0.0;
        particle.userScalar = 0.0;
        particle.userVector = NSZeroPoint;
        particle.baseSize = 1.0;
        particle.sizeVelocity = 0.0;
        particle.sizeOverLifeRange = SSKScalarRangeMake(1.0, 1.0);
        particle.behaviorOptions = SSKParticleBehaviorOptionNone;

        initializer(particle);
        if (particle.baseSize <= 0.0) {
            particle.baseSize = particle.size;
        }
        [self markStateDirtyAtIndex:index];
        emitted++;
    }
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

    NSUInteger threadCount = self.capacity;
    NSUInteger threadGroupSize = MIN(self.computePipeline.maxTotalThreadsPerThreadgroup, 128);
    if (threadGroupSize == 0) {
        threadGroupSize = 1;
    }
    NSUInteger threadGroups = (threadCount + threadGroupSize - 1) / threadGroupSize;
    MTLSize threadsPerGroup = MTLSizeMake(threadGroupSize, 1, 1);
    MTLSize threadgroupCount = MTLSizeMake(threadGroups, 1, 1);
    [encoder dispatchThreadgroups:threadgroupCount threadsPerThreadgroup:threadsPerGroup];
    [encoder endEncoding];
    [commandBuffer commit];
    [commandBuffer waitUntilCompleted];

    for (NSUInteger idx = 0; idx < self.capacity; idx++) {
        if (!self.states[idx].alive) {
            [self.availableIndices addIndex:idx];
        }
    }
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
    [self.availableIndices removeAllIndexes];
    [self.availableIndices addIndexesInRange:NSMakeRange(0, self.capacity)];
    [self markAllStatesDirty];
}

- (BOOL)renderWithMetalRenderer:(SSKMetalParticleRenderer *)renderer
                       blendMode:(SSKParticleBlendMode)blendMode
                    viewportSize:(CGSize)viewportSize {
    if (!renderer) { return NO; }

    NSMutableArray<SSKParticle *> *alive = nil;
    for (SSKParticle *particle in self.particles) {
        if (particle.isAlive) {
            if (!alive) {
                alive = [NSMutableArray arrayWithCapacity:16];
            }
            [alive addObject:particle];
        }
    }
    NSArray<SSKParticle *> *snapshot = alive ?: @[];
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

@end
