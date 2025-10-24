#import "SSKParticleSystem.h"

#import "SSKVectorMath.h"

@interface SSKParticle ()
@property (nonatomic, getter=isAlive) BOOL alive;
@end

@implementation SSKParticle
@end

@interface SSKParticleSystem ()
@property (nonatomic, strong) NSMutableArray<SSKParticle *> *particles;
@property (nonatomic, strong) NSMutableIndexSet *availableIndices;
@end

@implementation SSKParticleSystem

- (instancetype)initWithCapacity:(NSUInteger)capacity {
    NSParameterAssert(capacity > 0);
    if ((self = [super init])) {
        _particles = [NSMutableArray arrayWithCapacity:capacity];
        _availableIndices = [NSMutableIndexSet indexSetWithIndexesInRange:NSMakeRange(0, capacity)];
        for (NSUInteger i = 0; i < capacity; i++) {
            [_particles addObject:[SSKParticle new]];
        }
        _blendMode = SSKParticleBlendModeAlpha;
        _gravity = NSZeroPoint;
    }
    return self;
}

- (NSUInteger)aliveParticleCount {
    __block NSUInteger count = 0;
    [_particles enumerateObjectsUsingBlock:^(SSKParticle *particle, NSUInteger idx, BOOL *stop) {
        (void)idx;
        (void)stop;
        if (particle.isAlive) { count++; }
    }];
    return count;
}

- (void)spawnParticles:(NSUInteger)count initializer:(SSKParticleInitializer)initializer {
    if (count == 0 || !initializer) { return; }
    NSUInteger emitted = 0;
    while (emitted < count) {
        NSUInteger index = [_availableIndices firstIndex];
        if (index == NSNotFound) {
            break;
        }
        [_availableIndices removeIndex:index];
        SSKParticle *particle = self.particles[index];
        particle.alive = YES;
        particle.life = 0.0;
        particle.maxLife = 1.0;
        particle.position = NSZeroPoint;
        particle.velocity = NSZeroPoint;
        particle.size = 1.0;
        particle.color = [NSColor whiteColor];
        particle.rotation = 0.0;
        particle.rotationVelocity = 0.0;
        particle.damping = 0.0;
        particle.userScalar = 0.0;
        particle.userVector = NSZeroPoint;
        initializer(particle);
        emitted++;
    }
}

- (void)advanceBy:(NSTimeInterval)dt {
    if (dt <= 0.0) { return; }
    [_particles enumerateObjectsUsingBlock:^(SSKParticle *particle, NSUInteger idx, BOOL *stop) {
        (void)stop;
        if (!particle.isAlive) { return; }
        particle.life += dt;
        if (particle.life >= particle.maxLife) {
            particle.alive = NO;
            [self.availableIndices addIndex:idx];
            return;
        }
        if (!NSEqualPoints(self.gravity, NSZeroPoint)) {
            particle.velocity = SSKVectorAdd(particle.velocity, SSKVectorScale(self.gravity, dt));
        }
        if (particle.damping > 0.0) {
            CGFloat factor = pow(fmax(0.0, 1.0 - particle.damping), dt);
            particle.velocity = SSKVectorScale(particle.velocity, factor);
        }
        if (self.updateHandler) {
            self.updateHandler(particle, dt);
        }
        particle.position = SSKVectorAdd(particle.position, SSKVectorScale(particle.velocity, dt));
        particle.rotation += particle.rotationVelocity * dt;
    }];
}

- (void)drawInContext:(CGContextRef)ctx {
    if (!ctx) { return; }
    CGContextSaveGState(ctx);
    if (self.blendMode == SSKParticleBlendModeAdditive) {
        CGContextSetBlendMode(ctx, kCGBlendModePlusLighter);
    } else {
        CGContextSetBlendMode(ctx, kCGBlendModeNormal);
    }
    [_particles enumerateObjectsUsingBlock:^(SSKParticle *particle, NSUInteger idx, BOOL *stop) {
        (void)idx;
        (void)stop;
        if (!particle.isAlive) { return; }
        if (self.renderHandler) {
            self.renderHandler(ctx, particle);
            return;
        }

        CGFloat remaining = 1.0 - (particle.life / MAX(0.0001, particle.maxLife));
        NSColor *color = particle.color ?: [NSColor whiteColor];
        NSColor *renderColor = [color colorWithAlphaComponent:color.alphaComponent * remaining];

        CGFloat size = MAX(0.0, particle.size);
        CGRect rect = CGRectMake(particle.position.x - size * 0.5,
                                 particle.position.y - size * 0.5,
                                 size,
                                 size);

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
    }];
    CGContextRestoreGState(ctx);
}

- (void)reset {
    [_particles enumerateObjectsUsingBlock:^(SSKParticle *particle, NSUInteger idx, BOOL *stop) {
        (void)idx;
        (void)stop;
        particle.alive = NO;
        particle.userScalar = 0.0;
        particle.userVector = NSZeroPoint;
    }];
    [self.availableIndices removeAllIndexes];
    [self.availableIndices addIndexesInRange:NSMakeRange(0, self.particles.count)];
}

@end
