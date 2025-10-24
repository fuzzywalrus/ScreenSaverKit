#import <AppKit/AppKit.h>

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSUInteger, SSKParticleBlendMode) {
    /// Standard alpha compositing.
    SSKParticleBlendModeAlpha,
    /// Additive blending for bloom/energy effects.
    SSKParticleBlendModeAdditive
};

@class SSKParticle;

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
@end

/// Lightweight particle system supporting additive and standard blending.
@interface SSKParticleSystem : NSObject

- (instancetype)initWithCapacity:(NSUInteger)capacity NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;

/// Blend mode used when rendering.
@property (nonatomic) SSKParticleBlendMode blendMode;

/// Global gravity applied to particles each update (units per second²).
@property (nonatomic) NSPoint gravity;

/// Called for each alive particle every update tick. Assign to customise behaviour.
@property (nonatomic, copy, nullable) SSKParticleUpdater updateHandler;

/// Optional custom renderer used for drawing particles. When nil, a default blur disc is drawn.
@property (nonatomic, copy, nullable) SSKParticleRenderer renderHandler;

/// Emits `count` particles, initialising each with `initializer`.
- (void)spawnParticles:(NSUInteger)count initializer:(SSKParticleInitializer)initializer;

/// Advances the simulation by `dt` seconds, removing expired particles.
- (void)advanceBy:(NSTimeInterval)dt;

/// Renders the particles into `ctx`. Call within `drawRect:` after configuring transforms.
- (void)drawInContext:(CGContextRef)ctx;

/// Returns the number of live particles currently managed by the system.
@property (nonatomic, readonly) NSUInteger aliveParticleCount;

/// Resets and removes all particles.
- (void)reset;

@end

NS_ASSUME_NONNULL_END
