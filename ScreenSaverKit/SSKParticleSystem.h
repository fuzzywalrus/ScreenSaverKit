#import <AppKit/AppKit.h>

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
@end

/// Lightweight particle system supporting additive and standard blending.
@interface SSKParticleSystem : NSObject

- (instancetype)initWithCapacity:(NSUInteger)capacity NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;

/// Blend mode used when rendering.
@property (nonatomic) SSKParticleBlendMode blendMode;

/// Global gravity applied to particles each update (units per second²).
@property (nonatomic) NSPoint gravity;

/// Extra damping applied uniformly to all particles each update (per-second factor).
@property (nonatomic) CGFloat globalDamping;

/// Called for each alive particle every update tick. Assign to customise behaviour.
/// Setting this property disables the Metal simulation path and forces CPU updates.
@property (nonatomic, copy, nullable) SSKParticleUpdater updateHandler;

/// Optional custom renderer used for drawing particles. When nil, a default blur disc is drawn.
@property (nonatomic, copy, nullable) SSKParticleRenderer renderHandler;

/// Emits `count` particles, initialising each with `initializer`.
- (void)spawnParticles:(NSUInteger)count initializer:(SSKParticleInitializer)initializer;

/// Advances the simulation by `dt` seconds, removing expired particles.
- (void)advanceBy:(NSTimeInterval)dt;

/// Renders the particles into `ctx`. Call within `drawRect:` after configuring transforms.
- (void)drawInContext:(CGContextRef)ctx;

/// Convenience helper that pushes particle data through a Metal-backed renderer.
- (BOOL)renderWithMetalRenderer:(SSKMetalParticleRenderer *)renderer
                       blendMode:(SSKParticleBlendMode)blendMode
                    viewportSize:(CGSize)viewportSize;

/// Indicates whether the system should advance using the Metal compute path when possible.
/// Defaults to YES when a Metal device and compute pipeline can be created.
@property (nonatomic, getter=isMetalSimulationEnabled) BOOL metalSimulationEnabled;

/// Returns the number of live particles currently managed by the system.
@property (nonatomic, readonly) NSUInteger aliveParticleCount;

/// Resets and removes all particles.
- (void)reset;

@end

NS_ASSUME_NONNULL_END
