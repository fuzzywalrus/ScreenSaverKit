#import "SSKParticleSystem.h"

#import <Metal/Metal.h>
#import <simd/simd.h>
#import <math.h>

#import "SSKDiagnostics.h"
#import "SSKMetalParticleRenderer.h"
#import "SSKMetalRenderer.h"
#import "SSKShaderLoader.h"
#import "SSKVectorMath.h"

// Behaviour flag values mirrored in the Metal shader.
static const uint32_t kSSKParticleBehaviorFadeAlpha      = (uint32_t)SSKParticleBehaviorOptionFadeAlpha;
static const uint32_t kSSKParticleBehaviorFadeSize       = (uint32_t)SSKParticleBehaviorOptionFadeSize;
static const uint32_t kSSKParticleBehaviorColorGradient  = (uint32_t)SSKParticleBehaviorOptionColorGradient;

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
    float endColor_rg;       // packed half2: r in high 16 bits, g in low 16 bits
    float endColor_ba;       // packed half2: b in high 16 bits, a in low 16 bits
} SSKParticleState;

// Feature flag constants for SSKSimulationUniforms.featureFlags bitmask.
static const uint32_t kSSKFeatureCurlNoise     = (1u << 0);
static const uint32_t kSSKFeatureAttractors    = (1u << 1);
static const uint32_t kSSKFeatureColorGradient = (1u << 2);
static const uint32_t kSSKFeatureVelocityHue   = (1u << 3);

#define SSK_MAX_ATTRACTORS 4

typedef struct __attribute__((aligned(16))) {
    // Legacy fields (offset 0-19) — layout matches old SSKParticleSimulationUniforms
    vector_float2 gravity;           // 0
    float dt;                        // 8
    float globalDamping;             // 12
    uint32_t particleCount;          // 16

    // Feature flags bitmask (offset 20)
    uint32_t featureFlags;

    // Curl noise parameters (offset 24-39)
    float noiseScale;
    float noiseStrength;
    float noiseSpeed;
    float noiseTime;

    // Attractor points (offset 40-103)
    vector_float2 attractors[SSK_MAX_ATTRACTORS];
    float attractorStrengths[SSK_MAX_ATTRACTORS];
    uint32_t attractorCount;

    // Global time (offset 108)
    float globalTime;

    // Padding to 256 bytes
    uint32_t _pad[36];
} SSKSimulationUniforms;

static inline BOOL SSKShouldCullParticle(const SSKParticleSystem *system, vector_float2 position) {
    if (!system || !system.isCullingEnabled || CGRectIsEmpty(system.cullingRect)) {
        return NO;
    }
    CGRect expanded = CGRectInset(system.cullingRect, -system.cullingMargin, -system.cullingMargin);
    return !CGRectContainsPoint(expanded, CGPointMake(position.x, position.y));
}

// Fallback simulation kernel compiled at runtime when no precompiled metallib is available.
// Uses the expanded SSKSimulationUniforms (256 bytes) but only reads the legacy fields,
// so it remains compatible with all demos.
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
"    float endColor_rg;\\n"
"    float endColor_ba;\\n"
"};\\n"
"struct SimulationUniforms {\\n"
"    float2 gravity;\\n"
"    float dt;\\n"
"    float globalDamping;\\n"
"    uint particleCount;\\n"
"    uint featureFlags;\\n"
"    float noiseScale;\\n"
"    float noiseStrength;\\n"
"    float noiseSpeed;\\n"
"    float noiseTime;\\n"
"    float2 attractors[4];\\n"
"    float attractorStrengths[4];\\n"
"    uint attractorCount;\\n"
"    float globalTime;\\n"
"    uint _pad[36];\\n"
"};\\n"
"constant uint kBehaviorFadeAlpha = %u;\\n"
"constant uint kBehaviorFadeSize  = %u;\\n"
"kernel void simulateParticles(device ParticleState *particles [[buffer(0)]],\\n"
"                             constant SimulationUniforms &uniforms [[buffer(1)]],\\n"
"                             uint id [[thread_position_in_grid]]) {\\n"
"    if (id >= uniforms.particleCount) { return; }\\n"
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

// Half-float packing: pack 4 color channels (r,g,b,a) into 2 floats.
// Each float stores two 16-bit half-floats via bit packing.
static inline void SSKPackEndColor(vector_float4 color, float *out_rg, float *out_ba) {
    // Use _Float16 for half-precision conversion
    uint16_t rh, gh, bh, ah;
    _Float16 rf = (_Float16)color.x;
    _Float16 gf = (_Float16)color.y;
    _Float16 bf = (_Float16)color.z;
    _Float16 af = (_Float16)color.w;
    memcpy(&rh, &rf, sizeof(uint16_t));
    memcpy(&gh, &gf, sizeof(uint16_t));
    memcpy(&bh, &bf, sizeof(uint16_t));
    memcpy(&ah, &af, sizeof(uint16_t));
    uint32_t rg_bits = ((uint32_t)rh << 16) | (uint32_t)gh;
    uint32_t ba_bits = ((uint32_t)bh << 16) | (uint32_t)ah;
    memcpy(out_rg, &rg_bits, sizeof(float));
    memcpy(out_ba, &ba_bits, sizeof(float));
}

static inline vector_float4 SSKUnpackEndColor(float rg_packed, float ba_packed) {
    uint32_t rg_bits, ba_bits;
    memcpy(&rg_bits, &rg_packed, sizeof(uint32_t));
    memcpy(&ba_bits, &ba_packed, sizeof(uint32_t));
    uint16_t rh = (uint16_t)(rg_bits >> 16);
    uint16_t gh = (uint16_t)(rg_bits & 0xFFFF);
    uint16_t bh = (uint16_t)(ba_bits >> 16);
    uint16_t ah = (uint16_t)(ba_bits & 0xFFFF);
    _Float16 rf, gf, bf, af;
    memcpy(&rf, &rh, sizeof(uint16_t));
    memcpy(&gf, &gh, sizeof(uint16_t));
    memcpy(&bf, &bh, sizeof(uint16_t));
    memcpy(&af, &ah, sizeof(uint16_t));
    return (vector_float4){(float)rf, (float)gf, (float)bf, (float)af};
}

// --- CPU-side 2D Simplex Noise (matches Metal implementation) ---

static inline float SSKMod289f(float x) { return x - floorf(x * (1.0f / 289.0f)) * 289.0f; }

static inline void SSKPermutev3(float v[3]) {
    for (int i = 0; i < 3; i++) v[i] = SSKMod289f(((v[i] * 34.0f) + 1.0f) * v[i]);
}

static float SSKSimplexNoise2D(float x, float y) {
    const float F2 = 0.366025403784439f;  // 0.5*(sqrt(3.0)-1.0)
    const float G2 = 0.211324865405187f;  // (3.0-sqrt(3.0))/6.0

    float s = (x + y) * F2;
    float ix = floorf(x + s);
    float iy = floorf(y + s);
    float t = (ix + iy) * G2;
    float x0 = x - (ix - t);
    float y0 = y - (iy - t);

    float i1x = (x0 > y0) ? 1.0f : 0.0f;
    float i1y = (x0 > y0) ? 0.0f : 1.0f;

    float x1 = x0 - i1x + G2;
    float y1 = y0 - i1y + G2;
    float x2 = x0 - 1.0f + 2.0f * G2;
    float y2 = y0 - 1.0f + 2.0f * G2;

    float mi = SSKMod289f(ix);
    float miy = SSKMod289f(iy);
    float p[3] = { miy, miy + i1y, miy + 1.0f };
    SSKPermutev3(p);
    p[0] += mi;       p[1] += mi + i1x; p[2] += mi + 1.0f;
    SSKPermutev3(p);

    float m0 = fmaxf(0.0f, 0.5f - (x0*x0 + y0*y0));
    float m1 = fmaxf(0.0f, 0.5f - (x1*x1 + y1*y1));
    float m2 = fmaxf(0.0f, 0.5f - (x2*x2 + y2*y2));
    m0 *= m0; m0 *= m0;
    m1 *= m1; m1 *= m1;
    m2 *= m2; m2 *= m2;

    float C_w = 0.024390243902439f;
    float gx0 = 2.0f * fmodf(p[0] * C_w, 1.0f) - 1.0f;
    float gx1 = 2.0f * fmodf(p[1] * C_w, 1.0f) - 1.0f;
    float gx2 = 2.0f * fmodf(p[2] * C_w, 1.0f) - 1.0f;
    float hy0 = fabsf(gx0) - 0.5f;
    float hy1 = fabsf(gx1) - 0.5f;
    float hy2 = fabsf(gx2) - 0.5f;
    float ox0 = floorf(gx0 + 0.5f); gx0 -= ox0;
    float ox1 = floorf(gx1 + 0.5f); gx1 -= ox1;
    float ox2 = floorf(gx2 + 0.5f); gx2 -= ox2;

    float norm0 = 1.79284291400159f - 0.85373472095314f * (gx0*gx0 + hy0*hy0);
    float norm1 = 1.79284291400159f - 0.85373472095314f * (gx1*gx1 + hy1*hy1);
    float norm2 = 1.79284291400159f - 0.85373472095314f * (gx2*gx2 + hy2*hy2);

    return 130.0f * (m0 * norm0 * (gx0 * x0 + hy0 * y0)
                   + m1 * norm1 * (gx1 * x1 + hy1 * y1)
                   + m2 * norm2 * (gx2 * x2 + hy2 * y2));
}

static inline vector_float2 SSKCurlNoise2D(float x, float y, float time) {
    float eps = 0.001f;
    float n0 = SSKSimplexNoise2D(x + eps + time, y);
    float n1 = SSKSimplexNoise2D(x - eps + time, y);
    float n2 = SSKSimplexNoise2D(x + time, y + eps);
    float n3 = SSKSimplexNoise2D(x + time, y - eps);
    float dndx = (n0 - n1) / (2.0f * eps);
    float dndy = (n2 - n3) / (2.0f * eps);
    return (vector_float2){dndy, -dndx};
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

- (NSColor *)endColor {
    vector_float4 v = SSKUnpackEndColor(self.state->endColor_rg, self.state->endColor_ba);
    // Return nil if the packed value is all zeros (no endColor set)
    if (v.x == 0.0f && v.y == 0.0f && v.z == 0.0f && v.w == 0.0f) {
        return nil;
    }
    return SSKColorFromVector(v);
}

- (void)setEndColor:(NSColor *)endColor {
    if (!endColor) {
        self.state->endColor_rg = 0.0f;
        self.state->endColor_ba = 0.0f;
        return;
    }
    vector_float4 value = SSKVectorFromColor(endColor);
    SSKPackEndColor(value, &self.state->endColor_rg, &self.state->endColor_ba);
}

@end

@interface SSKParticleSystem () {
    // C-array based index tracking (avoids NSNumber boxing overhead).
    // These replace the previous NSMutableArray<NSNumber *> / NSMutableDictionary
    // approach which created thousands of short-lived NSNumber objects per frame.
    NSUInteger *_freeStack;          // Stack of free particle indices
    NSUInteger _freeStackCount;      // Number of entries in free stack
    NSUInteger *_aliveList;          // Compact list of alive particle indices
    NSUInteger _aliveListCount;      // Number of alive particles
    NSUInteger *_alivePositionMap;   // Maps particle index -> position in _aliveList (NSNotFound = not alive)
    NSUInteger *_spawnIndexScratch;  // Reused scratch storage for spawn index collection
    NSUInteger *_snapshotIndexScratch; // Scratch buffer for aliveParticlesSnapshot (avoids per-call allocation)
    id<MTLDevice> _externalDevice;   // Optional device passed via initWithCapacity:device:
    NSMutableArray<SSKParticle *> *_previousFramePool; // Reusable particle objects for previous-frame snapshots

    // Attractor point data (up to SSK_MAX_ATTRACTORS)
    NSPoint _attractorPositions[SSK_MAX_ATTRACTORS];
    CGFloat _attractorStrengths[SSK_MAX_ATTRACTORS];
    NSUInteger _attractorCount;

    // Global elapsed time for noise animation
    float _globalTime;
}
@property (nonatomic, assign) NSUInteger capacity;
@property (nonatomic, assign) SSKParticleState *states;
@property (nonatomic, strong) NSMutableArray<SSKParticle *> *particles;
@property (nonatomic, strong) NSMutableArray<SSKParticle *> *aliveScratch;
@property (nonatomic, strong) dispatch_queue_t particleIndexQueue; // Serial queue for free list updates
@property (nonatomic, strong) id<MTLBuffer> previousFrameBuffer; // Buffer storing previous frame's particle data for async rendering
@property (nonatomic) BOOL hasPreviousFrame; // Whether we have valid previous frame data
@property (nonatomic, strong) dispatch_semaphore_t frameFence; // Semaphore ensuring only 1 frame in flight for async mode
@property (nonatomic, strong) id<MTLDevice> metalDevice;
@property (nonatomic, strong) id<MTLCommandQueue> commandQueue;
@property (nonatomic, strong) id<MTLComputePipelineState> computePipeline;
@property (nonatomic, strong) id<MTLComputePipelineState> initializePipeline;
@property (nonatomic, strong) id<MTLBuffer> particleBuffer;
@property (nonatomic, strong) id<MTLBuffer> uniformsBuffer;
@property (nonatomic, strong) id<MTLBuffer> spawnIndicesBuffer;
@property (nonatomic, strong) id<MTLBuffer> spawnParamsBuffer;
@property (nonatomic, strong) id<MTLBuffer> spawnCountBuffer;
@property (nonatomic, strong) id<MTLLibrary> shaderLibrary;
@property (nonatomic, strong) id<MTLLibrary> simulationLibrary; // SSKSimulationShaders metallib (if available)
@property (nonatomic) BOOL supportsMetalSimulation;
@property (nonatomic) BOOL updateHandlerForcesCPU;
@property (nonatomic, readonly) NSUInteger stateStride;
- (void)markStateDirtyAtIndex:(NSUInteger)index;
- (void)markAllStatesDirty;
@end

@implementation SSKParticleSystem

- (instancetype)initWithCapacity:(NSUInteger)capacity {
    return [self initWithCapacity:capacity device:nil];
}

- (instancetype)initWithCapacity:(NSUInteger)capacity device:(id<MTLDevice>)device {
    NSParameterAssert(capacity > 0);
    if ((self = [super init])) {
        _capacity = capacity;
        _externalDevice = device;
        _particles = [NSMutableArray arrayWithCapacity:capacity];
        // C-array index tracking — zero NSNumber allocations in hot paths
        _freeStack = (NSUInteger *)malloc(capacity * sizeof(NSUInteger));
        _aliveList = (NSUInteger *)malloc(capacity * sizeof(NSUInteger));
        _alivePositionMap = (NSUInteger *)malloc(capacity * sizeof(NSUInteger));
        _spawnIndexScratch = (NSUInteger *)malloc(capacity * sizeof(NSUInteger));
        _snapshotIndexScratch = (NSUInteger *)malloc(capacity * sizeof(NSUInteger));
        if (!_freeStack || !_aliveList || !_alivePositionMap || !_spawnIndexScratch || !_snapshotIndexScratch) {
            free(_freeStack);  _freeStack = NULL;
            free(_aliveList);  _aliveList = NULL;
            free(_alivePositionMap); _alivePositionMap = NULL;
            free(_spawnIndexScratch); _spawnIndexScratch = NULL;
            free(_snapshotIndexScratch); _snapshotIndexScratch = NULL;
            return nil;
        }
        _freeStackCount = capacity;
        for (NSUInteger i = 0; i < capacity; i++) {
            _freeStack[i] = i;
            _alivePositionMap[i] = NSNotFound;
        }
        _aliveListCount = 0;
        _particleIndexQueue = dispatch_queue_create("com.ssk.particleIndex", DISPATCH_QUEUE_SERIAL);
        _blendMode = SSKParticleBlendModeAlpha;
        _gravity = NSZeroPoint;
        _globalDamping = 0.0;
        _cullingEnabled = NO;
        _cullingRect = CGRectZero;
        _cullingMargin = 0.0;
        _lengthMultiplier = 8.0;
        _synchronizesMetalSimulation = YES;
        _synchronizesMetalSpawn = YES;
        _noiseScale = 0.003;
        _noiseStrength = 0.0;  // Opt-in: set > 0 to enable curl noise
        _noiseSpeed = 0.5;
        _attractorCount = 0;
        _globalTime = 0.0f;

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
    free(_freeStack);
    free(_aliveList);
    free(_alivePositionMap);
    free(_spawnIndexScratch);
    free(_snapshotIndexScratch);
}

- (void)setUpMetalResourcesWithCapacity:(NSUInteger)capacity {
    id<MTLDevice> device = _externalDevice ?: MTLCreateSystemDefaultDevice();
    if (!device) {
        [SSKDiagnostics log:@"SSKParticleSystem: no Metal device available; using CPU path."];
        return;
    }

    id<MTLCommandQueue> queue = [device newCommandQueue];
    if (!queue) {
        [SSKDiagnostics log:@"SSKParticleSystem: failed to create Metal command queue; using CPU path."];
        return;
    }

    NSError *error = nil;
    NSBundle *classBundle = [NSBundle bundleForClass:self.class];

    // Load shader libraries via SSKShaderLoader (metallib → source fallback chain).
    // 1. Try SSKSimulationShaders (expanded uniforms, new features)
    // 2. Fall back to SSKParticleShaders (legacy)
    // 3. Fall back to runtime string compilation
    id<MTLLibrary> simLibrary = [SSKShaderLoader loadLibraryNamed:@"SSKSimulationShaders"
                                                            device:device
                                                            bundle:classBundle];

    id<MTLLibrary> library = [SSKShaderLoader loadLibraryNamed:@"SSKParticleShaders"
                                                        device:device
                                                        bundle:classBundle];

    // Determine which library provides simulateParticles
    id<MTLFunction> kernel = nil;
    id<MTLLibrary> simulationSource = nil;

    // Prefer simulation library (supports expanded uniforms)
    if (simLibrary) {
        kernel = [simLibrary newFunctionWithName:@"simulateParticles"];
        if (kernel) {
            simulationSource = simLibrary;
        }
    }

    // Fall back to particle shaders library
    if (!kernel && library) {
        kernel = [library newFunctionWithName:@"simulateParticles"];
        if (kernel) {
            simulationSource = library;
        }
    }

    // Final fallback: runtime string compilation
    if (!kernel) {
        NSString *source = [NSString stringWithFormat:kSSKParticleComputeTemplate,
                            kSSKParticleBehaviorFadeAlpha,
                            kSSKParticleBehaviorFadeSize];
        NSError *compileError = nil;
        id<MTLLibrary> fallbackLibrary = [device newLibraryWithSource:source options:nil error:&compileError];
        if (!fallbackLibrary) {
            [SSKDiagnostics log:@"SSKParticleSystem: all shader loading paths failed: %@", compileError];
            return;
        }
        kernel = [fallbackLibrary newFunctionWithName:@"simulateParticles"];
        if (!kernel) {
            [SSKDiagnostics log:@"SSKParticleSystem: simulateParticles kernel missing after fallback compile; using CPU path."];
            return;
        }
        simulationSource = fallbackLibrary;
        if (!library) {
            library = fallbackLibrary;
        }
    }

    id<MTLComputePipelineState> pipeline = [device newComputePipelineStateWithFunction:kernel error:&error];
    if (!pipeline) {
        [SSKDiagnostics log:@"SSKParticleSystem: failed to create compute pipeline: %@", error];
        return;
    }

    // Try to create initialization pipeline (may not be available if using source template)
    id<MTLFunction> initKernel = [library newFunctionWithName:@"initializeParticles"];
    id<MTLComputePipelineState> initPipeline = nil;
    if (initKernel) {
        initPipeline = [device newComputePipelineStateWithFunction:initKernel error:&error];
        if (!initPipeline) {
            if ([SSKDiagnostics isEnabled]) {
                [SSKDiagnostics log:@"SSKParticleSystem: failed to create initialization pipeline: %@", error];
            }
        }
    }

    id<MTLBuffer> particleBuffer = [device newBufferWithLength:capacity * sizeof(SSKParticleState)
                                                       options:MTLResourceStorageModeShared];
    if (!particleBuffer) {
        [SSKDiagnostics log:@"SSKParticleSystem: failed to create particle buffer; using CPU path."];
        return;
    }

    id<MTLBuffer> uniformsBuffer = [device newBufferWithLength:sizeof(SSKSimulationUniforms)
                                                       options:MTLResourceStorageModeShared];
    if (!uniformsBuffer) {
        [SSKDiagnostics log:@"SSKParticleSystem: failed to create uniforms buffer; using CPU path."];
        return;
    }

    // Create previous frame buffer for async rendering mode
    id<MTLBuffer> previousFrameBuffer = [device newBufferWithLength:capacity * sizeof(SSKParticleState)
                                                            options:MTLResourceStorageModeShared];
    if (!previousFrameBuffer) {
        if ([SSKDiagnostics isEnabled]) {
            [SSKDiagnostics log:@"SSKParticleSystem: failed to create previous frame buffer; async rendering unavailable."];
        }
    }

    self.metalDevice = device;
    self.commandQueue = queue;
    self.computePipeline = pipeline;
    self.initializePipeline = initPipeline;
    self.shaderLibrary = library;
    self.simulationLibrary = simulationSource;
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
    __block NSUInteger count;
    [self withIndexLock:^{
        count = _aliveListCount;
    }];
    return count;
}

- (void)spawnParticles:(NSUInteger)count initializer:(SSKParticleInitializer)initializer {
    if (count == 0 || !initializer) { return; }

    NSUInteger *indices = _spawnIndexScratch;
    if (!indices) { return; }

    // Phase A (synchronized): Pop indices from free stack.
    __block NSUInteger collected = 0;
    [self withIndexLock:^{
        NSUInteger actualCount = MIN(count, _freeStackCount);
        while (collected < actualCount && _freeStackCount > 0) {
            NSUInteger index = _freeStack[--_freeStackCount];
            indices[collected++] = index;
        }
    }];
    if (collected == 0) { return; }

    // THREADING NOTE: In PreviousFrame mode, the GPU kernel may still be reading
    // self.states while we write to newly spawned slots here. This is safe because:
    // 1. We only write to free-stack slots (particles with alive == 0u).
    // 2. The GPU kernel skips dead particles (if (!state->alive) return).
    // 3. On Apple Silicon unified memory, the worst case is the GPU sees a freshly
    //    spawned slot as alive and simulates it one extra frame, which is benign.
    // 4. The index synchronization from withIndexLock ensures the free-stack pop
    //    is serialized with the completion handler's alive-list cleanup.

    // Phase B (unsynchronized): Initialize particle states and call user initializer.
    // User code runs on the calling thread, not on particleIndexQueue.
    SSKParticleState defaultState = {0};
    defaultState.alive = 1u;
    defaultState.size = 1.0f;
    defaultState.baseSize = 1.0f;
    defaultState.maxLife = 1.0f;
    defaultState.color = (vector_float4){1,1,1,1};
    defaultState.baseColor = (vector_float4){1,1,1,1};
    defaultState.sizeRange = (vector_float2){1,1};

    NSUInteger minIndex = NSNotFound;
    NSUInteger maxIndex = 0;

    for (NSUInteger i = 0; i < collected; i++) {
        NSUInteger idx = indices[i];
        SSKParticleState *state = &self.states[idx];

        *state = defaultState;

        SSKParticle *particle = self.particles[idx];
        particle.state = state;

        if (minIndex == NSNotFound || idx < minIndex) {
            minIndex = idx;
        }
        if (idx > maxIndex) {
            maxIndex = idx;
        }

        initializer(particle);

        if (state->baseSize <= 0.0f) {
            state->baseSize = state->size;
        }
    }

    // Phase C (synchronized): Batch push all collected indices into alive list.
    [self withIndexLock:^{
        for (NSUInteger i = 0; i < collected; i++) {
            NSUInteger idx = indices[i];
            _aliveList[_aliveListCount] = idx;
            _alivePositionMap[idx] = _aliveListCount;
            _aliveListCount++;
        }
    }];

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
    
}

- (NSUInteger)spawnParticlesGPU:(NSUInteger)count parameters:(SSKParticleSpawnParameters)parameters {
    if (count == 0) { return 0; }

    // Fallback to CPU if Metal simulation disabled or GPU resources unavailable
    if (!self.isMetalSimulationEnabled || !self.initializePipeline || !self.commandQueue || !self.particleBuffer || !self.metalDevice) {
        // Could fall back to CPU spawn here, but for now just return 0
        return 0;
    }
    
    NSUInteger *indices = _spawnIndexScratch;
    if (!indices) { return 0; }

    // Phase A (synchronized): Pop indices from free stack.
    __block NSUInteger collected = 0;
    [self withIndexLock:^{
        NSUInteger actualCount = MIN(count, _freeStackCount);
        while (collected < actualCount && _freeStackCount > 0) {
            NSUInteger index = _freeStack[--_freeStackCount];
            indices[collected++] = index;
        }
    }];
    if (collected == 0) { return 0; }

    void (^rollbackAllocation)(void) = ^{
        [self withIndexLock:^{
            while (collected > 0) {
                NSUInteger idx = indices[--collected];
                _freeStack[_freeStackCount++] = idx;
            }
        }];
    };
    
    // THREADING NOTE: The GPU initialization kernel writes to particle slots from the
    // free stack (dead particles with alive == 0u). In PreviousFrame mode, the simulation
    // kernel may still be reading these slots, but it skips dead particles. The worst case
    // is the simulation kernel sees a freshly initialized particle and simulates it one
    // extra frame, which is benign. See spawnParticles: for the full rationale.

    // Create/reuse buffers for GPU initialization
    NSUInteger indicesBufferSize = collected * sizeof(uint32_t);
    id<MTLBuffer> indicesBuffer = self.spawnIndicesBuffer;
    if (!indicesBuffer || indicesBuffer.length < indicesBufferSize) {
        indicesBuffer = [self.metalDevice newBufferWithLength:indicesBufferSize
                                                      options:MTLResourceStorageModeShared];
        if (indicesBuffer) {
            self.spawnIndicesBuffer = indicesBuffer;
        }
    }
    if (!indicesBuffer) {
        rollbackAllocation();
        return 0;
    }
    uint32_t *gpuIndices = (uint32_t *)indicesBuffer.contents;
    for (NSUInteger i = 0; i < collected; i++) {
        gpuIndices[i] = (uint32_t)indices[i];
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
        vector_float4 endColorMin;
        vector_float4 endColorMax;
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
    metalParams.endColorMin = parameters.endColorMin;
    metalParams.endColorMax = parameters.endColorMax;

    // Store length multiplier for renderer access when z-depth is enabled
    if (parameters.zDepthEnabled != 0) {
        self.lengthMultiplier = clampedLengthMult;
    }
    
    id<MTLBuffer> paramsBuffer = self.spawnParamsBuffer;
    if (!paramsBuffer) {
        paramsBuffer = [self.metalDevice newBufferWithLength:sizeof(MetalSpawnParameters)
                                                     options:MTLResourceStorageModeShared];
        if (paramsBuffer) {
            self.spawnParamsBuffer = paramsBuffer;
        }
    }
    if (!paramsBuffer) {
        rollbackAllocation();
        return 0;
    }
    memcpy(paramsBuffer.contents, &metalParams, sizeof(MetalSpawnParameters));
    
    uint32_t countValue = (uint32_t)collected;
    id<MTLBuffer> countBuffer = self.spawnCountBuffer;
    if (!countBuffer) {
        countBuffer = [self.metalDevice newBufferWithLength:sizeof(uint32_t)
                                                    options:MTLResourceStorageModeShared];
        if (countBuffer) {
            self.spawnCountBuffer = countBuffer;
        }
    }
    if (!countBuffer) {
        rollbackAllocation();
        return 0;
    }
    *((uint32_t *)countBuffer.contents) = countValue;
    
    // Dispatch compute shader
    id<MTLCommandBuffer> commandBuffer = [self.commandQueue commandBuffer];
    if (!commandBuffer) {
        rollbackAllocation();
        return 0;
    }
    
    id<MTLComputeCommandEncoder> encoder = [commandBuffer computeCommandEncoder];
    if (!encoder) {
        rollbackAllocation();
        return 0;
    }
    [encoder setComputePipelineState:self.initializePipeline];
    [encoder setBuffer:self.particleBuffer offset:0 atIndex:0];
    [encoder setBuffer:paramsBuffer offset:0 atIndex:1];
    [encoder setBuffer:indicesBuffer offset:0 atIndex:2];
    [encoder setBuffer:countBuffer offset:0 atIndex:3];
    
    NSUInteger threadWidth = MAX(self.initializePipeline.threadExecutionWidth, (NSUInteger)1);
    NSUInteger maxThreads = MAX(self.initializePipeline.maxTotalThreadsPerThreadgroup, (NSUInteger)1);
    NSUInteger threadGroupSize = MIN(maxThreads, threadWidth * 8); // heuristic multiple of SIMD width
    threadGroupSize = MAX(threadGroupSize, (NSUInteger)1);
    NSUInteger threadGroups = (collected + threadGroupSize - 1) / threadGroupSize;
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

        if (minIndex == NSNotFound || idx < minIndex) {
            minIndex = idx;
        }
        if (idx > maxIndex) {
            maxIndex = idx;
        }
    }

    // Phase C (synchronized): Batch push to alive tracking.
    [self withIndexLock:^{
        for (NSUInteger i = 0; i < collected; i++) {
            NSUInteger idx = indices[i];
            _aliveList[_aliveListCount] = idx;
            _alivePositionMap[idx] = _aliveListCount;
            _aliveListCount++;
        }
    }];
    
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

    __weak typeof(self) weakSelfSpawn = self;
    [commandBuffer addCompletedHandler:^(__unused id<MTLCommandBuffer> buffer) {
        __strong typeof(weakSelfSpawn) strongSelfSpawn = weakSelfSpawn;
        if (!strongSelfSpawn) { return; }
        if (!hasRange || !strongSelfSpawn.particleBuffer) { return; }
        [strongSelfSpawn.particleBuffer didModifyRange:NSMakeRange(startOffset, rangeLength)];
    }];

    [commandBuffer commit];
    if (self.synchronizesMetalSpawn) {
        [commandBuffer waitUntilCompleted];
    }
    
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
    _globalTime += (float)dt;

    vector_float2 gravityVec = SSKVectorFromPoint(self.gravity);
    BOOL hasGravity = !simd_equal(gravityVec, (vector_float2){0, 0});
    BOOL hasCurlNoise = (self.noiseStrength > 0.0001);
    float noiseTime = _globalTime * (float)self.noiseSpeed;

    // Iterate backwards so O(1) swap-removal cannot skip an element.
    for (NSUInteger i = _aliveListCount; i > 0; i--) {
        NSUInteger idx = _aliveList[i - 1];
        SSKParticleState *state = &self.states[idx];
        if (!state->alive) {
            [self removeFromAliveTracking:idx];
            _freeStack[_freeStackCount++] = idx;
            continue;
        }

        state->life += (float)dt;
        if (state->life >= state->maxLife) {
            state->alive = 0u;
            [self removeFromAliveTracking:idx];
            _freeStack[_freeStackCount++] = idx;
            continue;
        }

        if (hasGravity) {
            state->velocity += gravityVec * (float)dt;
        }

        // Curl noise force field
        if (hasCurlNoise) {
            float sx = state->position.x * (float)self.noiseScale;
            float sy = state->position.y * (float)self.noiseScale;
            vector_float2 curl = SSKCurlNoise2D(sx, sy, noiseTime);
            state->velocity += curl * (float)self.noiseStrength * (float)dt;
        }

        // Attractor points
        for (NSUInteger ai = 0; ai < _attractorCount; ai++) {
            vector_float2 attractorPos = SSKVectorFromPoint(_attractorPositions[ai]);
            vector_float2 toAttractor = attractorPos - state->position;
            float dist = fmaxf(simd_length(toAttractor), 1.0f);
            vector_float2 dir = toAttractor / dist;
            state->velocity += dir * ((float)_attractorStrengths[ai] / (dist * dist)) * (float)dt;
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
            [self removeFromAliveTracking:idx];
            _freeStack[_freeStackCount++] = idx;
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

    // Advance global time for noise animation
    _globalTime += (float)dt;

    SSKSimulationUniforms *uniforms = self.uniformsBuffer.contents;
    memset(uniforms, 0, sizeof(SSKSimulationUniforms));

    // Legacy fields
    uniforms->gravity = SSKVectorFromPoint(self.gravity);
    uniforms->dt = (float)dt;
    uniforms->globalDamping = (float)self.globalDamping;
    uniforms->particleCount = (uint32_t)self.capacity;

    // Feature flags — assembled from system configuration
    uint32_t features = 0;
    if (self.noiseStrength > 0.0001) {
        features |= kSSKFeatureCurlNoise;
    }
    if (_attractorCount > 0) {
        features |= kSSKFeatureAttractors;
    }
    uniforms->featureFlags = features;

    // Curl noise parameters
    uniforms->noiseScale = (float)self.noiseScale;
    uniforms->noiseStrength = (float)self.noiseStrength;
    uniforms->noiseSpeed = (float)self.noiseSpeed;
    uniforms->noiseTime = _globalTime * (float)self.noiseSpeed;

    // Attractor data
    uniforms->attractorCount = (uint32_t)_attractorCount;
    for (NSUInteger i = 0; i < _attractorCount && i < SSK_MAX_ATTRACTORS; i++) {
        uniforms->attractors[i] = SSKVectorFromPoint(_attractorPositions[i]);
        uniforms->attractorStrengths[i] = (float)_attractorStrengths[i];
    }

    // Global time
    uniforms->globalTime = _globalTime;

    NSUInteger aliveCount = [self aliveParticleCount];
    if (aliveCount == 0) {
        // Signal frame fence so the next frame doesn't deadlock in PreviousFrame mode.
        if (self.metalSimulationRenderMode == SSKMetalSimulationRenderModePreviousFrame &&
            self.frameFence) {
            dispatch_semaphore_signal(self.frameFence);
        }
        return;
    }

    id<MTLCommandBuffer> commandBuffer = [self.commandQueue commandBuffer];
    id<MTLComputeCommandEncoder> encoder = [commandBuffer computeCommandEncoder];
    [encoder setComputePipelineState:self.computePipeline];
    [encoder setBuffer:self.particleBuffer offset:0 atIndex:0];
    [encoder setBuffer:self.uniformsBuffer offset:0 atIndex:1];

    NSUInteger threadCount = self.capacity;
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
            // Iterate only alive particles (O(alive) instead of O(capacity)).
            // Walk backwards so swap-removal doesn't skip entries.
            for (NSUInteger i = strongSelf->_aliveListCount; i > 0; i--) {
                NSUInteger idx = strongSelf->_aliveList[i - 1];
                SSKParticleState *state = &strongSelf.states[idx];
                if (SSKShouldCullParticle(strongSelf, state->position)) {
                    state->alive = 0u;
                }
                if (!state->alive) {
                    [strongSelf removeFromAliveTracking:idx];
                    strongSelf->_freeStack[strongSelf->_freeStackCount++] = idx;
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

    if ((state->behaviorFlags & kSSKParticleBehaviorColorGradient) != 0u) {
        vector_float4 endColor = SSKUnpackEndColor(state->endColor_rg, state->endColor_ba);
        float t = normalized;
        vector_float4 blended = (vector_float4){
            state->baseColor.x + (endColor.x - state->baseColor.x) * t,
            state->baseColor.y + (endColor.y - state->baseColor.y) * t,
            state->baseColor.z + (endColor.z - state->baseColor.z) * t,
            state->baseColor.w + (endColor.w - state->baseColor.w) * t,
        };
        // Preserve FadeAlpha if also active
        if ((state->behaviorFlags & kSSKParticleBehaviorFadeAlpha) != 0u) {
            float fade = 1.0f - normalized;
            blended.w *= fade;
        }
        state->color = blended;
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

    for (NSUInteger i = 0; i < _aliveListCount; i++) {
        NSUInteger idx = _aliveList[i];
        SSKParticleState *state = &self.states[idx];
        if (!state->alive) { continue; }

        if (self.renderHandler) {
            self.renderHandler(ctx, self.particles[idx]);
            continue;
        }

        CGFloat size = MAX(0.0, state->size);
        CGRect rect = CGRectMake(state->position.x - size * 0.5f,
                                 state->position.y - size * 0.5f,
                                 size,
                                 size);

        NSColor *renderColor = SSKColorFromVector(state->color) ?: [NSColor whiteColor];
        CGFloat blurScale = (self.blendMode == SSKParticleBlendModeAdditive) ? 0.9 : 0.6;
        CGFloat blurRadius = size * blurScale;
        CGColorRef blurColor = CGColorCreateCopyWithAlpha(renderColor.CGColor, renderColor.alphaComponent * 0.85);

        CGContextSetFillColorWithColor(ctx, renderColor.CGColor);
        if (blurColor) {
            CGContextSetShadowWithColor(ctx, CGSizeZero, blurRadius, blurColor);
        }

        if (fabsf(state->rotation) > 0.001f) {
            CGContextSaveGState(ctx);
            CGContextTranslateCTM(ctx, state->position.x, state->position.y);
            CGContextRotateCTM(ctx, state->rotation);
            CGContextTranslateCTM(ctx, -state->position.x, -state->position.y);
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
    // Reset index tracking — C arrays, zero allocations (synchronized)
    [self withIndexLock:^{
        _freeStackCount = self.capacity;
        for (NSUInteger i = 0; i < self.capacity; i++) {
            _freeStack[i] = i;
            _alivePositionMap[i] = NSNotFound;
        }
        _aliveListCount = 0;
    }];
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

    // Snapshot the alive index list under the lock, then iterate outside it.
    // This avoids holding the lock during NSMutableArray/particle-wrapper work.
    __block NSUInteger snapshotCount = 0;
    NSUInteger *snapshotIndices = _snapshotIndexScratch;
    [self withIndexLock:^{
        snapshotCount = _aliveListCount;
        if (snapshotCount > 0 && snapshotIndices) {
            memcpy(snapshotIndices, _aliveList, snapshotCount * sizeof(NSUInteger));
        }
    }];

    BOOL usePreviousFrame = (sourceStates != self.states);
    if (usePreviousFrame && !_previousFramePool) {
        _previousFramePool = [NSMutableArray arrayWithCapacity:self.capacity];
        for (NSUInteger i = 0; i < self.capacity; i++) {
            SSKParticle *p = [[SSKParticle alloc] initWithState:&sourceStates[i] index:i];
            [_previousFramePool addObject:p];
        }
    }
    for (NSUInteger i = 0; i < snapshotCount; i++) {
        NSUInteger idx = snapshotIndices[i];
        if (!usePreviousFrame) {
            [alive addObject:self.particles[idx]];
        } else {
            SSKParticle *particle = _previousFramePool[idx];
            particle.state = &sourceStates[idx];
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
            // Pass nil — the indirect success path never uses the CPU snapshot.
            // The fallback CPU path below builds its own snapshot if needed.
            [metalRenderer drawParticlesIndirect:self.particleBuffer
                                       capacity:self.capacity
                                      blendMode:blendMode
                                   viewportSize:viewportSize
                                      particles:nil];

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
    NSUInteger position = _alivePositionMap[index];
    if (position == NSNotFound) { return; }

    NSUInteger lastPos = _aliveListCount - 1;
    if (position != lastPos) {
        // Swap with last element for O(1) removal — zero allocations
        NSUInteger lastIndex = _aliveList[lastPos];
        _aliveList[position] = lastIndex;
        _alivePositionMap[lastIndex] = position;
    }

    _aliveListCount--;
    _alivePositionMap[index] = NSNotFound;
}

- (void)releaseMetalResources {
    // Wait for any pending GPU work to complete
    if (self.frameFence) {
        // Try to acquire the fence with a timeout to avoid blocking forever
        dispatch_time_t timeout = dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC));
        dispatch_semaphore_wait(self.frameFence, timeout);
        dispatch_semaphore_signal(self.frameFence); // Release immediately
    }
    
    // Release Metal pipelines and buffers
    self.computePipeline = nil;
    self.initializePipeline = nil;
    self.shaderLibrary = nil;
    self.simulationLibrary = nil;
    self.spawnIndicesBuffer = nil;
    self.spawnParamsBuffer = nil;
    self.spawnCountBuffer = nil;
    
    // Release command queue (this stops any pending commands)
    self.commandQueue = nil;
    
    // Release buffers - but keep states pointer valid by allocating CPU memory
    if (self.particleBuffer) {
        // Copy current state to CPU memory before releasing Metal buffer
        if (self.states == self.particleBuffer.contents) {
            SSKParticleState *cpuStates = calloc(self.capacity, sizeof(SSKParticleState));
            if (cpuStates) {
                memcpy(cpuStates, self.states, self.capacity * sizeof(SSKParticleState));
                self.states = cpuStates;
            }
        }
        self.particleBuffer = nil;
    }
    
    self.uniformsBuffer = nil;
    self.previousFrameBuffer = nil;
    self.hasPreviousFrame = NO;
    _previousFramePool = nil;  // Pool particles reference previousFrameBuffer contents
    
    // Release Metal device last
    self.metalDevice = nil;
    
    // Mark Metal simulation as unavailable until resources are recreated
    self.supportsMetalSimulation = NO;
    _metalSimulationEnabled = NO;
}

#pragma mark - Attractors

- (void)setAttractorAtIndex:(NSUInteger)index position:(NSPoint)position strength:(CGFloat)strength {
    if (index >= SSK_MAX_ATTRACTORS) { return; }
    _attractorPositions[index] = position;
    _attractorStrengths[index] = strength;
    if (index >= _attractorCount) {
        _attractorCount = index + 1;
    }
}

- (void)clearAttractors {
    _attractorCount = 0;
    memset(_attractorPositions, 0, sizeof(_attractorPositions));
    memset(_attractorStrengths, 0, sizeof(_attractorStrengths));
}

- (NSUInteger)attractorCount {
    return _attractorCount;
}

#pragma mark - Index Synchronization

/// Serializes access to index structures (_freeStack, _aliveList, etc.) with the
/// GPU completion handler in PreviousFrame async mode. In Blocking mode the
/// completion handler runs during waitUntilCompleted, so no dispatch is needed.
- (void)withIndexLock:(void (NS_NOESCAPE ^)(void))block {
    if (self.metalSimulationRenderMode == SSKMetalSimulationRenderModePreviousFrame &&
        self.particleIndexQueue) {
        dispatch_sync(self.particleIndexQueue, block);
    } else {
        block();
    }
}

@end
