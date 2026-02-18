#import <AppKit/AppKit.h>
#import <Metal/Metal.h>
#import <simd/simd.h>

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSUInteger, SSKParticleBlendMode) {
    /// Standard alpha compositing.
    SSKParticleBlendModeAlpha,
    /// Additive blending for bloom/energy effects.
    SSKParticleBlendModeAdditive
};

typedef NS_OPTIONS(NSUInteger, SSKParticleBehaviorOptions) {
    /// No automatic behaviour – particle values remain as initialised.
    SSKParticleBehaviorOptionNone      = 0,
    /// Fade alpha towards zero as the particle approaches the end of its life.
    SSKParticleBehaviorOptionFadeAlpha = 1 << 0,
    /// Interpolate size using `sizeOverLifeRange` as the particle ages.
    SSKParticleBehaviorOptionFadeSize  = 1 << 1,
};

/// Simple scalar range used by particle behaviours.
typedef struct {
    CGFloat start;
    CGFloat end;
} SSKScalarRange;

NS_INLINE SSKScalarRange SSKScalarRangeMake(CGFloat start, CGFloat end) {
    SSKScalarRange range;
    range.start = start;
    range.end = end;
    return range;
}

NS_INLINE SSKScalarRange SSKScalarRangeZero(void) {
    return SSKScalarRangeMake(0.0, 0.0);
}

/// Spawn region type for GPU-accelerated particle generation.
typedef NS_ENUM(NSUInteger, SSKParticleSpawnRegionType) {
    /// Rectangular spawn region defined by center and size.
    SSKParticleSpawnRegionTypeRectangle,
    /// Circular spawn region defined by center and radius.
    SSKParticleSpawnRegionTypeCircle,
    /// Single point spawn (all particles at same position).
    SSKParticleSpawnRegionTypePoint
};

/// Parameters for GPU-accelerated particle spawning.
typedef struct {
    /// Spawn region type.
    SSKParticleSpawnRegionType regionType;
    /// Center point of spawn region.
    vector_float2 center;
    /// Size/radius of spawn region (width, height for rectangle; radius for circle).
    vector_float2 size;
    /// Velocity range (min, max) in X direction.
    vector_float2 velocityXRange;
    /// Velocity range (min, max) in Y direction.
    vector_float2 velocityYRange;
    /// Speed range (min, max) for directional spawning.
    vector_float2 speedRange;
    /// Direction angle in radians (0 = right, π/2 = up).
    float directionAngle;
    /// Direction spread in radians (cone angle).
    float directionSpread;
    /// Size range (min, max).
    vector_float2 sizeRange;
    /// Life range (min, max) in seconds.
    vector_float2 lifeRange;
    /// Color range (RGBA min, RGBA max) - 8 floats: [rMin, gMin, bMin, aMin, rMax, gMax, bMax, aMax].
    vector_float4 colorMin;
    vector_float4 colorMax;
    /// Rotation velocity range (min, max) in radians per second.
    vector_float2 rotationVelocityRange;
    /// Damping range (min, max) per second.
    vector_float2 dampingRange;
    /// Behavior options flags.
    uint32_t behaviorOptions;
    /// Size over life range (start multiplier, end multiplier).
    vector_float2 sizeOverLifeRange;
    /// Z-depth enabled flag (0 = disabled, 1 = enabled).
    uint32_t zDepthEnabled;
    /// Z-depth scale factor (0.1-100.0).
    float zDepthScale;
    /// Length multiplier for rain drops.
    float lengthMultiplier;
    float padding2; // Align to 16 bytes
} SSKParticleSpawnParameters;

NS_INLINE SSKParticleSpawnParameters SSKParticleSpawnParametersMake(void) {
    SSKParticleSpawnParameters params = {0};
    params.regionType = SSKParticleSpawnRegionTypePoint;
    params.sizeRange = (vector_float2){1.0f, 1.0f};
    params.lifeRange = (vector_float2){1.0f, 1.0f};
    params.colorMin = (vector_float4){1.0f, 1.0f, 1.0f, 1.0f};
    params.colorMax = (vector_float4){1.0f, 1.0f, 1.0f, 1.0f};
    params.sizeOverLifeRange = (vector_float2){1.0f, 1.0f};
    params.zDepthEnabled = 0;
    params.zDepthScale = 1.0f;
    params.lengthMultiplier = 8.0f;
    return params;
}

@class SSKParticle;
@class SSKMetalParticleRenderer;

typedef void (^SSKParticleInitializer)(SSKParticle *particle);
typedef void (^SSKParticleUpdater)(SSKParticle *particle, NSTimeInterval dt);
typedef void (^SSKParticleRenderer)(CGContextRef ctx, SSKParticle *particle);

/// Represents a single particle instance managed by `SSKParticleSystem`.
@interface SSKParticle : NSObject
@property (nonatomic) NSPoint position;
@property (nonatomic) NSPoint velocity;
@property (nonatomic) CGFloat life;
@property (nonatomic) CGFloat maxLife;
@property (nonatomic) CGFloat size;
@property (nonatomic, strong) NSColor *color;
@property (nonatomic) CGFloat rotation;
@property (nonatomic) CGFloat rotationVelocity;
@property (nonatomic) CGFloat damping; // Applied per-second to velocity.
@property (nonatomic) CGFloat userScalar;
@property (nonatomic) NSPoint userVector;
@property (nonatomic) CGFloat baseSize;                         ///< Reference size used by size fading.
@property (nonatomic) CGFloat sizeVelocity;                     ///< Units per second applied to `size`.
@property (nonatomic) SSKScalarRange sizeOverLifeRange;         ///< Multiplier range (start → end) for `SSKParticleBehaviorOptionFadeSize`.
@property (nonatomic) SSKParticleBehaviorOptions behaviorOptions;

- (vector_float4)metalColorVector;
@end

/// Lightweight particle system supporting additive and standard blending.
@interface SSKParticleSystem : NSObject

- (instancetype)initWithCapacity:(NSUInteger)capacity device:(nullable id<MTLDevice>)device NS_DESIGNATED_INITIALIZER;
- (instancetype)initWithCapacity:(NSUInteger)capacity;
- (instancetype)init NS_UNAVAILABLE;

/// Blend mode used when rendering.
@property (nonatomic) SSKParticleBlendMode blendMode;

/// Global gravity applied to particles each update (units per second²).
@property (nonatomic) NSPoint gravity;

/// Extra damping applied uniformly to all particles each update (per-second factor).
@property (nonatomic) CGFloat globalDamping;

/// Optional culling rectangle in particle space; when enabled, particles outside (expanded by
/// `cullingMargin`) are killed to reduce simulation and render cost. Disabled by default.
@property (nonatomic) CGRect cullingRect;
@property (nonatomic) CGFloat cullingMargin;
@property (nonatomic, getter=isCullingEnabled) BOOL cullingEnabled;

/// Length multiplier used for rendering when z-depth is enabled (default: 8.0).
/// This is automatically set when spawning particles with z-depth enabled.
@property (nonatomic) CGFloat lengthMultiplier;

/// Called for each alive particle each update tick. Assign to customise behaviour.
/// Setting this property disables the Metal simulation path and forces CPU updates.
@property (nonatomic, copy, nullable) SSKParticleUpdater updateHandler;

/// Optional custom renderer used for drawing particles. When nil, a default blur disc is drawn.
@property (nonatomic, copy, nullable) SSKParticleRenderer renderHandler;

/// Emits `count` particles, initialising each with `initializer`.
- (void)spawnParticles:(NSUInteger)count initializer:(SSKParticleInitializer)initializer;

/// GPU-accelerated particle spawning using parameterized initialization.
/// This method is significantly faster for large batches (100+ particles) when
/// initialization can be expressed as parameter ranges rather than custom logic.
/// Falls back to CPU path if Metal resources are unavailable.
/// Returns the number of particles actually spawned (may be less than `count` if capacity is exhausted).
- (NSUInteger)spawnParticlesGPU:(NSUInteger)count parameters:(SSKParticleSpawnParameters)parameters;

/// Advances the simulation by `dt` seconds, removing expired particles.
- (void)advanceBy:(NSTimeInterval)dt;

/// Renders the particles into `ctx`. Call within `drawRect:` after configuring transforms.
- (void)drawInContext:(CGContextRef)ctx;

/// Returns a snapshot of all alive particles for external rendering.
- (NSArray<SSKParticle *> *)aliveParticlesSnapshot;

/// Convenience helper that pushes particle data through a Metal-backed renderer.
- (BOOL)renderWithMetalRenderer:(SSKMetalParticleRenderer *)renderer
                       blendMode:(SSKParticleBlendMode)blendMode
                    viewportSize:(CGSize)viewportSize;

/// Indicates whether the system should advance using the Metal compute path when possible.
/// Defaults to YES when a Metal device and compute pipeline can be created.
@property (nonatomic, getter=isMetalSimulationEnabled) BOOL metalSimulationEnabled;

/// When enabled, waits for the Metal simulation command buffer to complete before returning
/// from `advanceBy:`. This guarantees CPU snapshots see up-to-date data at the cost of a
/// sync point each frame. Defaults to YES.
@property (nonatomic) BOOL synchronizesMetalSimulation;

/// When enabled, waits for the GPU spawn command buffer to complete before returning from
/// `spawnParticlesGPU:parameters:`. Disable to make large GPU spawns async. Defaults to YES.
@property (nonatomic) BOOL synchronizesMetalSpawn;

/// Rendering mode for Metal simulation data access.
typedef NS_ENUM(NSUInteger, SSKMetalSimulationRenderMode) {
    /// Block until GPU simulation completes before returning from advanceBy: (default behavior).
    /// Guarantees CPU snapshots see current frame data at the cost of GPU wait time.
    SSKMetalSimulationRenderModeBlocking,
    /// Render previous frame's particle data to eliminate GPU wait.
    /// Adds 1-frame visual latency (imperceptible at 60fps) but allows CPU and GPU to work in parallel.
    SSKMetalSimulationRenderModePreviousFrame,
} NS_SWIFT_NAME(MetalSimulationRenderMode);

/// Metal simulation rendering mode. When set to PreviousFrame mode, eliminates GPU-CPU
/// synchronization wait at the cost of 1-frame visual latency. Defaults to Blocking mode.
@property (nonatomic) SSKMetalSimulationRenderMode metalSimulationRenderMode;

/// Returns the number of live particles currently managed by the system.
@property (nonatomic, readonly) NSUInteger aliveParticleCount;

/// Maximum number of particles the system can hold.
@property (nonatomic, readonly) NSUInteger capacity;

/// Returns the Metal buffer containing particle state data (for indirect rendering).
/// Available only when Metal simulation is supported.
@property (nonatomic, readonly, nullable) id<MTLBuffer> particleBuffer;

/// Resets and removes all particles.
- (void)reset;

/// Releases Metal resources to reduce memory footprint when idle.
/// Call this when the screensaver stops animating. Metal resources will be
/// lazily recreated when the simulation starts again.
- (void)releaseMetalResources;

@end

NS_ASSUME_NONNULL_END
