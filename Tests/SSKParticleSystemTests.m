#import <XCTest/XCTest.h>
#import "ScreenSaverKit/SSKParticleSystem.h"
#import "TestHelpers.h"

@interface SSKParticleSystemTests : XCTestCase
@end

@implementation SSKParticleSystemTests

- (void)setUp {
    [super setUp];
}

- (void)tearDown {
    [super tearDown];
}

#pragma mark - Initialization

- (void)testInitialization {
    SSKParticleSystem *system = [[SSKParticleSystem alloc] initWithCapacity:100];
    XCTAssertNotNil(system);
    XCTAssertEqual(system.aliveParticleCount, 0);
}

- (void)testInitializationWithZeroCapacity {
    // Should assert or handle gracefully - testing that it doesn't crash
    XCTAssertThrows([[SSKParticleSystem alloc] initWithCapacity:0]);
}

#pragma mark - Particle Spawning

- (void)testSpawnSingleParticle {
    SSKParticleSystem *system = [[SSKParticleSystem alloc] initWithCapacity:100];
    
    [system spawnParticles:1 initializer:^(SSKParticle *particle) {
        particle.position = NSMakePoint(10.0, 20.0);
        particle.velocity = NSMakePoint(1.0, 2.0);
        particle.maxLife = 1.0;
        particle.life = 0.0;
    }];
    
    XCTAssertEqual(system.aliveParticleCount, 1);
    NSArray<SSKParticle *> *particles = [system aliveParticlesSnapshot];
    XCTAssertEqual(particles.count, 1);
    XCTAssertEqual(particles.firstObject.position.x, 10.0);
    XCTAssertEqual(particles.firstObject.position.y, 20.0);
}

- (void)testSpawnMultipleParticles {
    SSKParticleSystem *system = [[SSKParticleSystem alloc] initWithCapacity:100];
    
    [system spawnParticles:10 initializer:^(SSKParticle *particle) {
        particle.position = NSMakePoint(5.0, 5.0);
        particle.maxLife = 1.0;
    }];
    
    XCTAssertEqual(system.aliveParticleCount, 10);
}

- (void)testSpawnBeyondCapacity {
    SSKParticleSystem *system = [[SSKParticleSystem alloc] initWithCapacity:5];
    
    [system spawnParticles:10 initializer:^(SSKParticle *particle) {
        particle.maxLife = 1.0;
    }];
    
    // Should only spawn up to capacity
    XCTAssertEqual(system.aliveParticleCount, 5);
}

- (void)testSpawnWithZeroCount {
    SSKParticleSystem *system = [[SSKParticleSystem alloc] initWithCapacity:100];
    
    [system spawnParticles:0 initializer:^(SSKParticle *particle) {
        particle.maxLife = 1.0;
    }];
    
    XCTAssertEqual(system.aliveParticleCount, 0);
}

- (void)testSpawnWithNilInitializer {
    SSKParticleSystem *system = [[SSKParticleSystem alloc] initWithCapacity:100];
    
    #pragma clang diagnostic push
    #pragma clang diagnostic ignored "-Wnonnull"
    [system spawnParticles:5 initializer:nil];
    #pragma clang diagnostic pop
    
    // Should not spawn any particles with nil initializer
    XCTAssertEqual(system.aliveParticleCount, 0);
}

#pragma mark - Particle Lifecycle

- (void)testParticleExpiration {
    SSKParticleSystem *system = [[SSKParticleSystem alloc] initWithCapacity:100];
    
    [system spawnParticles:1 initializer:^(SSKParticle *particle) {
        particle.maxLife = 0.5;
        particle.life = 0.0;
    }];
    
    XCTAssertEqual(system.aliveParticleCount, 1);
    
    // Advance time beyond maxLife
    [system advanceBy:0.6];
    
    XCTAssertEqual(system.aliveParticleCount, 0);
}

- (void)testParticleUpdate {
    SSKParticleSystem *system = [[SSKParticleSystem alloc] initWithCapacity:100];
    
    __block NSPoint initialPosition = NSMakePoint(0.0, 0.0);
    __block NSPoint initialVelocity = NSMakePoint(10.0, 20.0);
    
    [system spawnParticles:1 initializer:^(SSKParticle *particle) {
        particle.position = initialPosition;
        particle.velocity = initialVelocity;
        particle.maxLife = 1.0;
        particle.life = 0.0;
    }];
    
    // Advance by 0.1 seconds
    [system advanceBy:0.1];
    
    NSArray<SSKParticle *> *particles = [system aliveParticlesSnapshot];
    XCTAssertEqual(particles.count, 1);
    
    SSKParticle *particle = particles.firstObject;
    // Position should have moved: position += velocity * dt
    XCTAssertGreaterThan(particle.position.x, initialPosition.x);
    XCTAssertGreaterThan(particle.position.y, initialPosition.y);
}

- (void)testParticleGravity {
    SSKParticleSystem *system = [[SSKParticleSystem alloc] initWithCapacity:100];
    system.gravity = NSMakePoint(0.0, -9.8);
    
    [system spawnParticles:1 initializer:^(SSKParticle *particle) {
        particle.velocity = NSMakePoint(0.0, 0.0);
        particle.maxLife = 1.0;
    }];
    
    [system advanceBy:0.1];
    
    NSArray<SSKParticle *> *particles = [system aliveParticlesSnapshot];
    SSKParticle *particle = particles.firstObject;
    // Velocity should have changed due to gravity
    XCTAssertLessThan(particle.velocity.y, 0.0);
}

#pragma mark - Index Management

- (void)testIndexReuse {
    SSKParticleSystem *system = [[SSKParticleSystem alloc] initWithCapacity:5];
    // Force CPU path — this test verifies index management, not GPU simulation.
    system.metalSimulationEnabled = NO;

    // Spawn 5 particles (fill capacity)
    [system spawnParticles:5 initializer:^(SSKParticle *particle) {
        particle.maxLife = 0.1;
    }];

    XCTAssertEqual(system.aliveParticleCount, 5);

    // Let them expire
    [system advanceBy:0.2];
    XCTAssertEqual(system.aliveParticleCount, 0);

    // Spawn new particles - should reuse indices
    [system spawnParticles:3 initializer:^(SSKParticle *particle) {
        particle.maxLife = 1.0;
    }];

    XCTAssertEqual(system.aliveParticleCount, 3);
}

- (void)testNoDuplicateIndices {
    SSKParticleSystem *system = [[SSKParticleSystem alloc] initWithCapacity:10];
    
    // Spawn particles
    [system spawnParticles:5 initializer:^(SSKParticle *particle) {
        particle.maxLife = 0.1;
    }];
    
    // Let them expire
    [system advanceBy:0.2];
    
    // Spawn more - should not have duplicates in free list
    [system spawnParticles:5 initializer:^(SSKParticle *particle) {
        particle.maxLife = 1.0;
    }];
    
    XCTAssertEqual(system.aliveParticleCount, 5);
    
    // Verify all particles are unique
    NSArray<SSKParticle *> *particles = [system aliveParticlesSnapshot];
    XCTAssertEqual(particles.count, 5);
}

#pragma mark - Reset

- (void)testReset {
    SSKParticleSystem *system = [[SSKParticleSystem alloc] initWithCapacity:100];
    
    [system spawnParticles:10 initializer:^(SSKParticle *particle) {
        particle.maxLife = 1.0;
    }];
    
    XCTAssertEqual(system.aliveParticleCount, 10);
    
    [system reset];
    
    XCTAssertEqual(system.aliveParticleCount, 0);
    
    // Should be able to spawn again after reset
    [system spawnParticles:5 initializer:^(SSKParticle *particle) {
        particle.maxLife = 1.0;
    }];
    
    XCTAssertEqual(system.aliveParticleCount, 5);
}

#pragma mark - Behavior Options

- (void)testFadeAlphaBehavior {
    SSKParticleSystem *system = [[SSKParticleSystem alloc] initWithCapacity:100];
    
    [system spawnParticles:1 initializer:^(SSKParticle *particle) {
        particle.maxLife = 1.0;
        particle.life = 0.0;
        particle.color = [NSColor colorWithCalibratedRed:1.0 green:1.0 blue:1.0 alpha:1.0];
        particle.behaviorOptions = SSKParticleBehaviorOptionFadeAlpha;
    }];
    
    NSArray<SSKParticle *> *particles = [system aliveParticlesSnapshot];
    SSKParticle *particle = particles.firstObject;
    CGFloat initialAlpha = particle.color.alphaComponent;
    XCTAssertEqualWithAccuracy(initialAlpha, 1.0, 0.01);
    
    // Advance to middle of life
    [system advanceBy:0.5];
    
    particles = [system aliveParticlesSnapshot];
    particle = particles.firstObject;
    CGFloat midAlpha = particle.color.alphaComponent;
    XCTAssertLessThan(midAlpha, initialAlpha);
}

- (void)testFadeSizeBehavior {
    SSKParticleSystem *system = [[SSKParticleSystem alloc] initWithCapacity:100];
    
    [system spawnParticles:1 initializer:^(SSKParticle *particle) {
        particle.maxLife = 1.0;
        particle.life = 0.0;
        particle.size = 10.0;
        particle.baseSize = 10.0;
        particle.sizeOverLifeRange = SSKScalarRangeMake(1.0, 0.5);
        particle.behaviorOptions = SSKParticleBehaviorOptionFadeSize;
    }];
    
    NSArray<SSKParticle *> *particles = [system aliveParticlesSnapshot];
    SSKParticle *particle = particles.firstObject;
    CGFloat initialSize = particle.size;
    
    // Advance to end of life
    [system advanceBy:0.9];
    
    particles = [system aliveParticlesSnapshot];
    particle = particles.firstObject;
    CGFloat endSize = particle.size;
    XCTAssertLessThan(endSize, initialSize);
}

- (void)testColorGradientBehavior {
    SSKParticleSystem *system = [[SSKParticleSystem alloc] initWithCapacity:4];
    system.metalSimulationEnabled = NO;

    [system spawnParticles:1 initializer:^(SSKParticle *particle) {
        particle.maxLife = 1.0;
        particle.life = 0.0;
        particle.color = [NSColor colorWithCalibratedRed:1.0 green:0.0 blue:0.0 alpha:1.0];
        particle.endColor = [NSColor colorWithCalibratedRed:0.0 green:0.0 blue:1.0 alpha:1.0];
        particle.behaviorOptions = SSKParticleBehaviorOptionColorGradient;
    }];

    // At start: should be red
    NSArray<SSKParticle *> *particles = [system aliveParticlesSnapshot];
    SSKParticle *particle = particles.firstObject;
    XCTAssertEqualWithAccuracy(particle.color.redComponent, 1.0, 0.05);
    XCTAssertEqualWithAccuracy(particle.color.blueComponent, 0.0, 0.05);

    // Advance to ~80% of life
    [system advanceBy:0.8];

    particles = [system aliveParticlesSnapshot];
    particle = particles.firstObject;
    // Color should have shifted toward blue
    XCTAssertLessThan(particle.color.redComponent, 0.5);
    XCTAssertGreaterThan(particle.color.blueComponent, 0.5);
}

- (void)testColorGradientCPUGPUParity {
    SSKParticleSystem *cpuSystem = [[SSKParticleSystem alloc] initWithCapacity:4];
    SSKParticleSystem *gpuSystem = [[SSKParticleSystem alloc] initWithCapacity:4];
    if (!gpuSystem.isMetalSimulationEnabled) {
        XCTSkip(@"Metal simulation unavailable on this system");
    }
    gpuSystem.metalSimulationEnabled = YES;
    gpuSystem.synchronizesMetalSimulation = YES;
    cpuSystem.metalSimulationEnabled = NO;

    void (^initializer)(SSKParticle *) = ^(SSKParticle *particle) {
        particle.position = NSZeroPoint;
        particle.velocity = NSZeroPoint;
        particle.maxLife = 1.0;
        particle.life = 0.0;
        particle.color = [NSColor colorWithCalibratedRed:1.0 green:0.0 blue:0.0 alpha:1.0];
        particle.endColor = [NSColor colorWithCalibratedRed:0.0 green:1.0 blue:0.0 alpha:1.0];
        particle.behaviorOptions = SSKParticleBehaviorOptionColorGradient;
    };

    [cpuSystem spawnParticles:1 initializer:initializer];
    [gpuSystem spawnParticles:1 initializer:initializer];

    [cpuSystem advanceBy:0.5];
    [gpuSystem advanceBy:0.5];

    NSArray<SSKParticle *> *cpuP = [cpuSystem aliveParticlesSnapshot];
    NSArray<SSKParticle *> *gpuP = [gpuSystem aliveParticlesSnapshot];
    XCTAssertEqual(cpuP.count, gpuP.count);

    // Half-float packing introduces some precision loss — use wider epsilon
    CGFloat epsilon = 0.02;
    [SSKTestHelpers assertFloat:cpuP.firstObject.color.redComponent
           approximatelyEquals:gpuP.firstObject.color.redComponent epsilon:epsilon];
    [SSKTestHelpers assertFloat:cpuP.firstObject.color.greenComponent
           approximatelyEquals:gpuP.firstObject.color.greenComponent epsilon:epsilon];
    [SSKTestHelpers assertFloat:cpuP.firstObject.color.blueComponent
           approximatelyEquals:gpuP.firstObject.color.blueComponent epsilon:epsilon];
}

- (void)testAttractorPullsParticles {
    SSKParticleSystem *system = [[SSKParticleSystem alloc] initWithCapacity:4];
    system.metalSimulationEnabled = NO;

    // Place attractor at (200, 200)
    [system setAttractorAtIndex:0 position:NSMakePoint(200.0, 200.0) strength:5000.0];

    [system spawnParticles:1 initializer:^(SSKParticle *particle) {
        particle.position = NSMakePoint(100.0, 100.0);
        particle.velocity = NSMakePoint(0.0, 0.0);
        particle.maxLife = 2.0;
        particle.life = 0.0;
    }];

    [system advanceBy:0.1];

    NSArray<SSKParticle *> *particles = [system aliveParticlesSnapshot];
    XCTAssertEqual(particles.count, 1);
    SSKParticle *p = particles.firstObject;
    // Particle should have moved toward the attractor
    XCTAssertGreaterThan(p.position.x, 100.0);
    XCTAssertGreaterThan(p.position.y, 100.0);
}

- (void)testClearAttractors {
    SSKParticleSystem *system = [[SSKParticleSystem alloc] initWithCapacity:4];
    [system setAttractorAtIndex:0 position:NSMakePoint(100.0, 100.0) strength:1000.0];
    [system setAttractorAtIndex:1 position:NSMakePoint(200.0, 200.0) strength:2000.0];
    XCTAssertEqual(system.attractorCount, 2);

    [system clearAttractors];
    XCTAssertEqual(system.attractorCount, 0);
}

- (void)testCurlNoiseDeflectsParticles {
    SSKParticleSystem *system = [[SSKParticleSystem alloc] initWithCapacity:4];
    system.metalSimulationEnabled = NO;
    system.noiseStrength = 200.0;
    system.noiseScale = 0.003;
    system.noiseSpeed = 0.5;

    [system spawnParticles:1 initializer:^(SSKParticle *particle) {
        particle.position = NSMakePoint(100.0, 100.0);
        particle.velocity = NSMakePoint(0.0, 0.0);
        particle.maxLife = 2.0;
        particle.life = 0.0;
    }];

    [system advanceBy:0.1];

    NSArray<SSKParticle *> *particles = [system aliveParticlesSnapshot];
    XCTAssertEqual(particles.count, 1);
    SSKParticle *p = particles.firstObject;
    // Curl noise should have moved the stationary particle
    CGFloat displacement = hypot(p.position.x - 100.0, p.position.y - 100.0);
    XCTAssertGreaterThan(displacement, 0.01);
}

- (void)testCurlNoiseDefaultProperties {
    SSKParticleSystem *system = [[SSKParticleSystem alloc] initWithCapacity:4];
    XCTAssertEqualWithAccuracy(system.noiseScale, 0.003, 0.0001);
    XCTAssertEqualWithAccuracy(system.noiseStrength, 0.0, 0.001);  // Opt-in: 0 by default
    XCTAssertEqualWithAccuracy(system.noiseSpeed, 0.5, 0.01);
}

- (void)testCurlNoisePropertyConfiguration {
    SSKParticleSystem *system = [[SSKParticleSystem alloc] initWithCapacity:4];
    system.noiseScale = 0.01;
    system.noiseStrength = 500.0;
    system.noiseSpeed = 1.5;

    XCTAssertEqualWithAccuracy(system.noiseScale, 0.01, 0.0001);
    XCTAssertEqualWithAccuracy(system.noiseStrength, 500.0, 0.1);
    XCTAssertEqualWithAccuracy(system.noiseSpeed, 1.5, 0.01);
}

- (void)testCurlNoiseZeroStrengthProducesNoForce {
    SSKParticleSystem *system = [[SSKParticleSystem alloc] initWithCapacity:4];
    system.metalSimulationEnabled = NO;
    system.noiseStrength = 0.0;
    system.noiseScale = 0.003;
    system.noiseSpeed = 0.5;

    [system spawnParticles:1 initializer:^(SSKParticle *particle) {
        particle.position = NSMakePoint(100.0, 100.0);
        particle.velocity = NSMakePoint(0.0, 0.0);
        particle.maxLife = 2.0;
        particle.life = 0.0;
    }];

    [system advanceBy:0.1];

    NSArray<SSKParticle *> *particles = [system aliveParticlesSnapshot];
    XCTAssertEqual(particles.count, 1);
    SSKParticle *p = particles.firstObject;
    // Zero noise strength should not move the particle
    CGFloat displacement = hypot(p.position.x - 100.0, p.position.y - 100.0);
    XCTAssertEqualWithAccuracy(displacement, 0.0, 0.001);
}

- (void)testMultipleAttractors {
    SSKParticleSystem *system = [[SSKParticleSystem alloc] initWithCapacity:4];
    system.metalSimulationEnabled = NO;

    // Place two attractors on opposite sides
    [system setAttractorAtIndex:0 position:NSMakePoint(200.0, 100.0) strength:5000.0];
    [system setAttractorAtIndex:1 position:NSMakePoint(100.0, 200.0) strength:5000.0];
    XCTAssertEqual(system.attractorCount, 2);

    // Particle at origin equidistant from both
    [system spawnParticles:1 initializer:^(SSKParticle *particle) {
        particle.position = NSMakePoint(100.0, 100.0);
        particle.velocity = NSMakePoint(0.0, 0.0);
        particle.maxLife = 2.0;
        particle.life = 0.0;
    }];

    [system advanceBy:0.1];

    NSArray<SSKParticle *> *particles = [system aliveParticlesSnapshot];
    XCTAssertEqual(particles.count, 1);
    SSKParticle *p = particles.firstObject;
    // Particle should be pulled toward both attractors (upward and to the right)
    XCTAssertGreaterThan(p.position.x, 100.0);
    XCTAssertGreaterThan(p.position.y, 100.0);
}

- (void)testAttractorMaxCount {
    SSKParticleSystem *system = [[SSKParticleSystem alloc] initWithCapacity:4];

    // Set all 4 attractor slots
    for (NSUInteger i = 0; i < 4; i++) {
        [system setAttractorAtIndex:i
                           position:NSMakePoint((CGFloat)(i * 100), (CGFloat)(i * 100))
                           strength:1000.0];
    }
    XCTAssertEqual(system.attractorCount, 4);
}

- (void)testAttractorStrengthAffectsForce {
    // Stronger attractor should produce larger displacement
    SSKParticleSystem *weakSystem = [[SSKParticleSystem alloc] initWithCapacity:4];
    weakSystem.metalSimulationEnabled = NO;
    [weakSystem setAttractorAtIndex:0 position:NSMakePoint(200.0, 100.0) strength:100.0];

    SSKParticleSystem *strongSystem = [[SSKParticleSystem alloc] initWithCapacity:4];
    strongSystem.metalSimulationEnabled = NO;
    [strongSystem setAttractorAtIndex:0 position:NSMakePoint(200.0, 100.0) strength:10000.0];

    void (^initializer)(SSKParticle *) = ^(SSKParticle *particle) {
        particle.position = NSMakePoint(100.0, 100.0);
        particle.velocity = NSMakePoint(0.0, 0.0);
        particle.maxLife = 2.0;
        particle.life = 0.0;
    };

    [weakSystem spawnParticles:1 initializer:initializer];
    [strongSystem spawnParticles:1 initializer:initializer];

    [weakSystem advanceBy:0.1];
    [strongSystem advanceBy:0.1];

    SSKParticle *weakP = [weakSystem aliveParticlesSnapshot].firstObject;
    SSKParticle *strongP = [strongSystem aliveParticlesSnapshot].firstObject;

    CGFloat weakDisplacement = hypot(weakP.position.x - 100.0, weakP.position.y - 100.0);
    CGFloat strongDisplacement = hypot(strongP.position.x - 100.0, strongP.position.y - 100.0);
    XCTAssertGreaterThan(strongDisplacement, weakDisplacement);
}

- (void)testCurlNoiseAndAttractorsCombined {
    SSKParticleSystem *system = [[SSKParticleSystem alloc] initWithCapacity:4];
    system.metalSimulationEnabled = NO;
    system.noiseStrength = 200.0;
    system.noiseScale = 0.003;
    system.noiseSpeed = 0.5;
    [system setAttractorAtIndex:0 position:NSMakePoint(200.0, 200.0) strength:5000.0];

    [system spawnParticles:1 initializer:^(SSKParticle *particle) {
        particle.position = NSMakePoint(100.0, 100.0);
        particle.velocity = NSMakePoint(0.0, 0.0);
        particle.maxLife = 2.0;
        particle.life = 0.0;
    }];

    [system advanceBy:0.1];

    NSArray<SSKParticle *> *particles = [system aliveParticlesSnapshot];
    XCTAssertEqual(particles.count, 1);
    SSKParticle *p = particles.firstObject;
    // Both curl noise and attractor should have moved the particle
    CGFloat displacement = hypot(p.position.x - 100.0, p.position.y - 100.0);
    XCTAssertGreaterThan(displacement, 0.01);
}

#pragma mark - Color Gradient Extended

- (void)testColorGradientWithNilEndColorUsesBaseColor {
    SSKParticleSystem *system = [[SSKParticleSystem alloc] initWithCapacity:4];
    system.metalSimulationEnabled = NO;

    [system spawnParticles:1 initializer:^(SSKParticle *particle) {
        particle.maxLife = 1.0;
        particle.life = 0.0;
        particle.color = [NSColor colorWithCalibratedRed:1.0 green:0.0 blue:0.0 alpha:1.0];
        particle.endColor = nil;
        particle.behaviorOptions = SSKParticleBehaviorOptionColorGradient;
    }];

    [system advanceBy:0.5];

    NSArray<SSKParticle *> *particles = [system aliveParticlesSnapshot];
    XCTAssertEqual(particles.count, 1);
    // With nil endColor, the color should remain essentially the base color
    SSKParticle *p = particles.firstObject;
    XCTAssertGreaterThan(p.color.redComponent, 0.5);
}

- (void)testColorGradientGPUSpawnWithEndColor {
    SSKParticleSystem *system = [[SSKParticleSystem alloc] initWithCapacity:32];
    if (!system.isMetalSimulationEnabled) {
        XCTSkip(@"Metal simulation unavailable on this system");
    }

    SSKParticleSpawnParameters params = SSKParticleSpawnParametersMake();
    params.regionType = SSKParticleSpawnRegionTypePoint;
    params.center = (vector_float2){50.0f, 50.0f};
    params.lifeRange = (vector_float2){1.0f, 1.0f};
    params.colorMin = (vector_float4){1.0f, 0.0f, 0.0f, 1.0f};
    params.colorMax = (vector_float4){1.0f, 0.0f, 0.0f, 1.0f};
    params.endColorMin = (vector_float4){0.0f, 0.0f, 1.0f, 1.0f};
    params.endColorMax = (vector_float4){0.0f, 0.0f, 1.0f, 1.0f};
    params.behaviorOptions = SSKParticleBehaviorOptionColorGradient;

    NSUInteger spawned = [system spawnParticlesGPU:8 parameters:params];
    XCTAssertGreaterThan(spawned, 0u);

    NSArray<SSKParticle *> *particles = [system aliveParticlesSnapshot];
    XCTAssertGreaterThan(particles.count, 0u);

    for (SSKParticle *p in particles) {
        // At spawn time, color should be red (base color)
        XCTAssertGreaterThan(p.color.redComponent, 0.5);
        // endColor should be set to blue
        if (p.endColor) {
            XCTAssertGreaterThan(p.endColor.blueComponent, 0.5);
        }
    }
}

#pragma mark - Per-Particle Rotation

- (void)testRotationVelocityIntegrates {
    SSKParticleSystem *system = [[SSKParticleSystem alloc] initWithCapacity:4];
    system.metalSimulationEnabled = NO;

    [system spawnParticles:1 initializer:^(SSKParticle *particle) {
        particle.position = NSMakePoint(50.0, 50.0);
        particle.velocity = NSMakePoint(0.0, 0.0);
        particle.maxLife = 2.0;
        particle.life = 0.0;
        particle.rotation = 0.0;
        particle.rotationVelocity = M_PI;  // 180 degrees per second
    }];

    [system advanceBy:0.5];

    NSArray<SSKParticle *> *particles = [system aliveParticlesSnapshot];
    XCTAssertEqual(particles.count, 1);
    SSKParticle *p = particles.firstObject;
    // After 0.5 seconds at PI rad/s, rotation should be ~PI/2
    XCTAssertEqualWithAccuracy(p.rotation, M_PI_2, 0.05);
}

- (void)testRotationPropertyPreserved {
    SSKParticleSystem *system = [[SSKParticleSystem alloc] initWithCapacity:4];
    system.metalSimulationEnabled = NO;

    [system spawnParticles:1 initializer:^(SSKParticle *particle) {
        particle.position = NSMakePoint(50.0, 50.0);
        particle.velocity = NSMakePoint(0.0, 0.0);
        particle.maxLife = 2.0;
        particle.life = 0.0;
        particle.rotation = 1.5;
        particle.rotationVelocity = 0.0;
    }];

    [system advanceBy:0.1];

    NSArray<SSKParticle *> *particles = [system aliveParticlesSnapshot];
    XCTAssertEqual(particles.count, 1);
    // With zero rotation velocity, rotation should stay at 1.5
    XCTAssertEqualWithAccuracy(particles.firstObject.rotation, 1.5, 0.01);
}

#pragma mark - Ribbon Mode

- (void)testRibbonModeEnabledProperty {
    SSKParticleSystem *system = [[SSKParticleSystem alloc] initWithCapacity:4];
    XCTAssertFalse(system.ribbonModeEnabled);
    system.ribbonModeEnabled = YES;
    XCTAssertTrue(system.ribbonModeEnabled);
}

#pragma mark - Behavior Option Combinations

- (void)testBehaviorOptionBitmaskCombinations {
    SSKParticleSystem *system = [[SSKParticleSystem alloc] initWithCapacity:4];
    system.metalSimulationEnabled = NO;

    SSKParticleBehaviorOptions combined =
        SSKParticleBehaviorOptionFadeAlpha |
        SSKParticleBehaviorOptionFadeSize |
        SSKParticleBehaviorOptionColorGradient;

    [system spawnParticles:1 initializer:^(SSKParticle *particle) {
        particle.position = NSMakePoint(50.0, 50.0);
        particle.velocity = NSMakePoint(0.0, 0.0);
        particle.maxLife = 1.0;
        particle.life = 0.0;
        particle.color = [NSColor colorWithCalibratedRed:1.0 green:0.0 blue:0.0 alpha:1.0];
        particle.endColor = [NSColor colorWithCalibratedRed:0.0 green:0.0 blue:1.0 alpha:1.0];
        particle.size = 10.0;
        particle.baseSize = 10.0;
        particle.sizeOverLifeRange = SSKScalarRangeMake(1.0, 0.3);
        particle.behaviorOptions = combined;
    }];

    [system advanceBy:0.7];

    NSArray<SSKParticle *> *particles = [system aliveParticlesSnapshot];
    XCTAssertEqual(particles.count, 1);
    SSKParticle *p = particles.firstObject;
    // FadeAlpha: alpha should have decreased
    XCTAssertLessThan(p.color.alphaComponent, 1.0);
    // FadeSize: size should have decreased
    XCTAssertLessThan(p.size, 10.0);
    // ColorGradient: color should have shifted toward blue
    XCTAssertGreaterThan(p.color.blueComponent, 0.3);
}

#pragma mark - Metal Simulation

- (void)testMetalSimulationEnabled {
    SSKParticleSystem *system = [[SSKParticleSystem alloc] initWithCapacity:100];
    
    if (!system.isMetalSimulationEnabled) {
        XCTSkip(@"Metal simulation unavailable on this system");
    }
    
    system.metalSimulationEnabled = YES;
    XCTAssertTrue(system.isMetalSimulationEnabled);
    
    // Spawn and advance - should use Metal path
    [system spawnParticles:10 initializer:^(SSKParticle *particle) {
        particle.maxLife = 1.0;
        particle.velocity = NSMakePoint(10.0, 10.0);
    }];
    
    [system advanceBy:0.1];
    
    // Particles should have moved
    NSArray<SSKParticle *> *particles = [system aliveParticlesSnapshot];
    XCTAssertEqual(particles.count, 10);
}

- (void)testCPUSimulationFallback {
    SSKParticleSystem *system = [[SSKParticleSystem alloc] initWithCapacity:100];
    
    // Force CPU path
    system.metalSimulationEnabled = NO;
    
    [system spawnParticles:10 initializer:^(SSKParticle *particle) {
        particle.maxLife = 1.0;
        particle.velocity = NSMakePoint(10.0, 10.0);
    }];
    
    [system advanceBy:0.1];
    
    NSArray<SSKParticle *> *particles = [system aliveParticlesSnapshot];
    XCTAssertEqual(particles.count, 10);
}

- (void)testCullingRemovesParticlesOutsideRectOnCPU {
    SSKParticleSystem *system = [[SSKParticleSystem alloc] initWithCapacity:4];
    system.metalSimulationEnabled = NO;
    system.cullingEnabled = YES;
    system.cullingRect = CGRectMake(0, 0, 100, 100);
    system.cullingMargin = 0.0;
    
    [system spawnParticles:2 initializer:^(SSKParticle *particle) {
        particle.position = NSMakePoint(200.0, 200.0); // well outside
        particle.velocity = NSZeroPoint;
        particle.maxLife = 10.0;
    }];
    
    [system advanceBy:0.016];
    
    XCTAssertEqual(system.aliveParticleCount, 0u);
    XCTAssertEqual(system.aliveParticlesSnapshot.count, 0u);
}

- (void)testCullingKeepsParticlesInsideRectAndRemovesOutside {
    SSKParticleSystem *system = [[SSKParticleSystem alloc] initWithCapacity:4];
    system.metalSimulationEnabled = NO;
    system.cullingEnabled = YES;
    system.cullingRect = CGRectMake(0, 0, 100, 100);
    system.cullingMargin = 5.0;
    
    [system spawnParticles:2 initializer:^(SSKParticle *particle) {
        static BOOL first = YES;
        if (first) {
            particle.position = NSMakePoint(50.0, 50.0); // inside
            first = NO;
        } else {
            particle.position = NSMakePoint(150.0, 150.0); // outside
        }
        particle.velocity = NSZeroPoint;
        particle.maxLife = 10.0;
    }];
    
    [system advanceBy:0.016];
    
    XCTAssertEqual(system.aliveParticleCount, 1u);
    NSArray<SSKParticle *> *alive = [system aliveParticlesSnapshot];
    XCTAssertEqual(alive.count, 1u);
    XCTAssertEqualWithAccuracy(alive.firstObject.position.x, 50.0, 0.001);
    XCTAssertEqualWithAccuracy(alive.firstObject.position.y, 50.0, 0.001);
}

- (void)testMetalSimulationSynchronizesSnapshotWhenEnabled {
    SSKParticleSystem *system = [[SSKParticleSystem alloc] initWithCapacity:8];
    if (!system.isMetalSimulationEnabled) {
        XCTSkip(@"Metal simulation unavailable on this system");
    }
    system.metalSimulationEnabled = YES;
    system.synchronizesMetalSimulation = YES;
    
    [system spawnParticles:1 initializer:^(SSKParticle *particle) {
        particle.position = NSZeroPoint;
        particle.velocity = NSMakePoint(10.0, 0.0);
        particle.maxLife = 1.0;
        particle.life = 0.0;
    }];
    
    [system advanceBy:0.05];
    
    NSArray<SSKParticle *> *particles = [system aliveParticlesSnapshot];
    XCTAssertEqual(particles.count, 1);
    SSKParticle *particle = particles.firstObject;
    XCTAssertGreaterThan(particle.position.x, 0.0);
    XCTAssertGreaterThan(particle.life, 0.0);
}

- (void)testMetalSimulationAsyncWhenSyncDisabledCompletes {
    SSKParticleSystem *system = [[SSKParticleSystem alloc] initWithCapacity:8];
    if (!system.isMetalSimulationEnabled) {
        XCTSkip(@"Metal simulation unavailable on this system");
    }
    system.metalSimulationEnabled = YES;
    system.synchronizesMetalSimulation = NO;
    
    [system spawnParticles:1 initializer:^(SSKParticle *particle) {
        particle.position = NSZeroPoint;
        particle.velocity = NSMakePoint(5.0, 0.0);
        particle.maxLife = 1.0;
        particle.life = 0.0;
    }];
    
    [system advanceBy:0.02];
    
    BOOL completed = [SSKTestHelpers waitForCondition:^BOOL{
        NSArray<SSKParticle *> *particles = [system aliveParticlesSnapshot];
        if (particles.count != 1) { return NO; }
        SSKParticle *particle = particles.firstObject;
        return particle.position.x > 0.0 && particle.life > 0.0;
    } timeout:1.0];
    XCTAssertTrue(completed);
}

- (void)testSynchronizesMetalSimulationDefaultsEnabled {
    SSKParticleSystem *system = [[SSKParticleSystem alloc] initWithCapacity:4];
    XCTAssertTrue(system.synchronizesMetalSimulation);
}

- (void)testSynchronizesMetalSimulationToggleMidSimulation {
    SSKParticleSystem *system = [[SSKParticleSystem alloc] initWithCapacity:4];
    if (!system.isMetalSimulationEnabled) {
        XCTSkip(@"Metal simulation unavailable on this system");
    }
    system.metalSimulationEnabled = YES;
    system.synchronizesMetalSimulation = YES;
    
    [system spawnParticles:1 initializer:^(SSKParticle *particle) {
        particle.position = NSZeroPoint;
        particle.velocity = NSMakePoint(4.0, 0.0);
        particle.maxLife = 1.0;
        particle.life = 0.0;
    }];
    
    [system advanceBy:0.01];
    system.synchronizesMetalSimulation = NO;
    [system advanceBy:0.01];
    
    BOOL progressed = [SSKTestHelpers waitForCondition:^BOOL{
        NSArray<SSKParticle *> *particles = [system aliveParticlesSnapshot];
        if (particles.count != 1) { return NO; }
        return particles.firstObject.position.x > 0.0 && particles.firstObject.life > 0.0;
    } timeout:1.0];
    XCTAssertTrue(progressed);
}

- (void)testMetalAndCPUSimulationParityForSimpleParticles {
    SSKParticleSystem *cpuSystem = [[SSKParticleSystem alloc] initWithCapacity:16];
    SSKParticleSystem *gpuSystem = [[SSKParticleSystem alloc] initWithCapacity:16];
    if (!gpuSystem.isMetalSimulationEnabled) {
        XCTSkip(@"Metal simulation unavailable on this system");
    }
    gpuSystem.metalSimulationEnabled = YES;
    gpuSystem.synchronizesMetalSimulation = YES;
    cpuSystem.metalSimulationEnabled = NO;
    cpuSystem.gravity = NSMakePoint(0.0, -9.8);
    gpuSystem.gravity = NSMakePoint(0.0, -9.8);
    cpuSystem.globalDamping = 0.1;
    gpuSystem.globalDamping = 0.1;
    
    NSArray<NSValue *> *initialVelocities = @[
        [NSValue valueWithPoint:NSMakePoint(10.0, 0.0)],
        [NSValue valueWithPoint:NSMakePoint(0.0, 5.0)],
        [NSValue valueWithPoint:NSMakePoint(3.0, 4.0)]
    ];
    
    for (NSValue *velocityValue in initialVelocities) {
        NSPoint velocity = velocityValue.pointValue;
        [cpuSystem spawnParticles:1 initializer:^(SSKParticle *particle) {
            particle.position = NSMakePoint(1.0, 2.0);
            particle.velocity = velocity;
            particle.maxLife = 1.0;
            particle.life = 0.0;
            particle.color = [NSColor colorWithCalibratedRed:0.5 green:0.6 blue:0.7 alpha:1.0];
            particle.size = 5.0;
            particle.baseSize = 5.0;
            particle.behaviorOptions = SSKParticleBehaviorOptionNone;
        }];
        [gpuSystem spawnParticles:1 initializer:^(SSKParticle *particle) {
            particle.position = NSMakePoint(1.0, 2.0);
            particle.velocity = velocity;
            particle.maxLife = 1.0;
            particle.life = 0.0;
            particle.color = [NSColor colorWithCalibratedRed:0.5 green:0.6 blue:0.7 alpha:1.0];
            particle.size = 5.0;
            particle.baseSize = 5.0;
            particle.behaviorOptions = SSKParticleBehaviorOptionNone;
        }];
    }
    
    NSTimeInterval dt = 0.05;
    [cpuSystem advanceBy:dt];
    [gpuSystem advanceBy:dt];
    [cpuSystem advanceBy:dt];
    [gpuSystem advanceBy:dt];
    
    NSArray<SSKParticle *> *cpuParticles = [cpuSystem aliveParticlesSnapshot];
    NSArray<SSKParticle *> *gpuParticles = [gpuSystem aliveParticlesSnapshot];
    XCTAssertEqual(cpuParticles.count, gpuParticles.count);
    
    CGFloat epsilon = 0.001;
    for (NSUInteger i = 0; i < cpuParticles.count; i++) {
        SSKParticle *cpu = cpuParticles[i];
        SSKParticle *gpu = gpuParticles[i];
        [SSKTestHelpers assertPoint:cpu.position approximatelyEquals:gpu.position epsilon:epsilon];
        [SSKTestHelpers assertPoint:cpu.velocity approximatelyEquals:gpu.velocity epsilon:epsilon];
        [SSKTestHelpers assertFloat:cpu.life approximatelyEquals:gpu.life epsilon:epsilon];
        [SSKTestHelpers assertFloat:cpu.size approximatelyEquals:gpu.size epsilon:epsilon];
        [SSKTestHelpers assertPoint:cpu.userVector approximatelyEquals:gpu.userVector epsilon:epsilon];
    }
}

- (void)testMetalAndCPUSimulationParityWithBehaviours {
    SSKParticleSystem *cpuSystem = [[SSKParticleSystem alloc] initWithCapacity:4];
    SSKParticleSystem *gpuSystem = [[SSKParticleSystem alloc] initWithCapacity:4];
    if (!gpuSystem.isMetalSimulationEnabled) {
        XCTSkip(@"Metal simulation unavailable on this system");
    }
    gpuSystem.metalSimulationEnabled = YES;
    gpuSystem.synchronizesMetalSimulation = YES;
    cpuSystem.metalSimulationEnabled = NO;
    
    void (^initializer)(SSKParticle *) = ^(SSKParticle *particle) {
        particle.position = NSMakePoint(0.0, 0.0);
        particle.velocity = NSMakePoint(2.0, 3.0);
        particle.maxLife = 0.5;
        particle.life = 0.0;
        particle.baseSize = 4.0;
        particle.size = 4.0;
        particle.behaviorOptions = SSKParticleBehaviorOptionFadeAlpha | SSKParticleBehaviorOptionFadeSize;
        particle.sizeOverLifeRange = SSKScalarRangeMake(1.0, 0.2);
        particle.color = [NSColor colorWithCalibratedRed:1.0 green:1.0 blue:1.0 alpha:1.0];
    };
    
    [cpuSystem spawnParticles:1 initializer:initializer];
    [gpuSystem spawnParticles:1 initializer:initializer];
    
    [cpuSystem advanceBy:0.1];
    [gpuSystem advanceBy:0.1];
    [cpuSystem advanceBy:0.1];
    [gpuSystem advanceBy:0.1];
    
    NSArray<SSKParticle *> *cpuParticles = [cpuSystem aliveParticlesSnapshot];
    NSArray<SSKParticle *> *gpuParticles = [gpuSystem aliveParticlesSnapshot];
    XCTAssertEqual(cpuParticles.count, gpuParticles.count);
    CGFloat epsilon = 0.01;
    for (NSUInteger i = 0; i < cpuParticles.count; i++) {
        SSKParticle *cpu = cpuParticles[i];
        SSKParticle *gpu = gpuParticles[i];
        [SSKTestHelpers assertPoint:cpu.position approximatelyEquals:gpu.position epsilon:epsilon];
        [SSKTestHelpers assertFloat:cpu.size approximatelyEquals:gpu.size epsilon:epsilon];
        [SSKTestHelpers assertFloat:cpu.color.alphaComponent approximatelyEquals:gpu.color.alphaComponent epsilon:epsilon];
    }
}

- (void)testMetalSimulationDisabledWhenUnsupportedFallsBackToCPU {
    SSKParticleSystem *system = [[SSKParticleSystem alloc] initWithCapacity:4];
    // Setting an updateHandler forces CPU simulation — the setter rejects metalSimulationEnabled = YES.
    system.updateHandler = ^(SSKParticle *p __unused, NSTimeInterval dt __unused) {};
    system.metalSimulationEnabled = YES;
    XCTAssertFalse(system.isMetalSimulationEnabled);

    [system spawnParticles:1 initializer:^(SSKParticle *particle) {
        particle.position = NSZeroPoint;
        particle.velocity = NSMakePoint(3.0, 0.0);
        particle.maxLife = 0.1;
        particle.life = 0.0;
    }];

    [system advanceBy:0.05];
    NSArray<SSKParticle *> *particles = [system aliveParticlesSnapshot];
    XCTAssertEqual(particles.count, 1);
    XCTAssertGreaterThan(particles.firstObject.position.x, 0.0);
}

- (void)testMetalFreeListDeduplicationAfterComputeCompletion {
    SSKParticleSystem *system = [[SSKParticleSystem alloc] initWithCapacity:4];
    if (!system.isMetalSimulationEnabled) {
        XCTSkip(@"Metal simulation unavailable on this system");
    }
    system.metalSimulationEnabled = YES;
    system.synchronizesMetalSimulation = YES;
    
    [system spawnParticles:4 initializer:^(SSKParticle *particle) {
        particle.position = NSZeroPoint;
        particle.velocity = NSZeroPoint;
        particle.maxLife = 0.01;
        particle.life = 0.0;
    }];
    
    [system advanceBy:0.05];
    
    BOOL released = [SSKTestHelpers waitForCondition:^BOOL{
        return system.aliveParticleCount == 0;
    } timeout:1.0];
    XCTAssertTrue(released);
    XCTAssertEqual(system.aliveParticleCount, 0u);
}

- (void)testMetalFreeListDeduplicationWithPartialExpiration {
    SSKParticleSystem *system = [[SSKParticleSystem alloc] initWithCapacity:6];
    if (!system.isMetalSimulationEnabled) {
        XCTSkip(@"Metal simulation unavailable on this system");
    }
    system.metalSimulationEnabled = YES;
    system.synchronizesMetalSimulation = YES;
    
    // First three expire quickly, next three live longer
    __block NSUInteger spawnCounter = 0;
    [system spawnParticles:6 initializer:^(SSKParticle *particle) {
        NSUInteger idx = spawnCounter++;
        particle.position = NSZeroPoint;
        particle.velocity = NSZeroPoint;
        particle.maxLife = (idx < 3) ? 0.01 : 1.0;
        particle.life = 0.0;
    }];
    
    // Advance enough to expire the first three only
    [system advanceBy:0.05];
    
    BOOL updated = [SSKTestHelpers waitForCondition:^BOOL{
        return system.aliveParticleCount <= 3;
    } timeout:1.0];
    XCTAssertTrue(updated);
    XCTAssertEqual(system.aliveParticleCount, 3u);
}

#pragma mark - Batch Operations

- (void)testBatchSpawnPerformance {
    [self measureBlock:^{
        SSKParticleSystem *system = [[SSKParticleSystem alloc] initWithCapacity:1000];
        [system spawnParticles:500 initializer:^(SSKParticle *particle) {
            particle.maxLife = 1.0;
        }];
        XCTAssertEqual(system.aliveParticleCount, 500);
    }];
}

#pragma mark - GPU Spawn (if available)

- (void)testGPUSpawnParameters {
    SSKParticleSystem *system = [[SSKParticleSystem alloc] initWithCapacity:100];
    
    SSKParticleSpawnParameters params = SSKParticleSpawnParametersMake();
    params.regionType = SSKParticleSpawnRegionTypeCircle;
    params.center = (vector_float2){100.0f, 100.0f};
    params.size = (vector_float2){50.0f, 50.0f}; // radius
    params.sizeRange = (vector_float2){5.0f, 10.0f};
    params.lifeRange = (vector_float2){0.5f, 1.5f};
    params.colorMin = (vector_float4){1.0f, 0.0f, 0.0f, 1.0f};
    params.colorMax = (vector_float4){1.0f, 1.0f, 0.0f, 1.0f};
    params.behaviorOptions = SSKParticleBehaviorOptionFadeAlpha;
    
    NSUInteger spawned = [system spawnParticlesGPU:50 parameters:params];
    
    // GPU spawn may not be available, so just verify it doesn't crash
    XCTAssertLessThanOrEqual(spawned, 50);
    if (spawned > 0) {
        XCTAssertGreaterThan(system.aliveParticleCount, 0);
    }
}

- (void)testGPUSpawnReturnsZeroWhenMetalDisabled {
    SSKParticleSystem *system = [[SSKParticleSystem alloc] initWithCapacity:50];
    system.metalSimulationEnabled = NO;
    
    SSKParticleSpawnParameters params = SSKParticleSpawnParametersMake();
    params.regionType = SSKParticleSpawnRegionTypePoint;
    params.center = (vector_float2){0.0f, 0.0f};
    NSUInteger spawned = [system spawnParticlesGPU:10 parameters:params];
    XCTAssertEqual(spawned, 0u);
    XCTAssertEqual(system.aliveParticleCount, 0u);
}

- (void)testGPUSpawnWithZDepthEncodesDepthInUserScalar {
    SSKParticleSystem *system = [[SSKParticleSystem alloc] initWithCapacity:32];
    if (!system.isMetalSimulationEnabled) {
        XCTSkip(@"Metal simulation unavailable on this system");
    }
    
    SSKParticleSpawnParameters params = SSKParticleSpawnParametersMake();
    params.zDepthEnabled = 1;
    params.zDepthScale = 1.5f;       // allow some spread
    params.lengthMultiplier = 6.0f;  // independent length control
    
    NSUInteger spawned = [system spawnParticlesGPU:16 parameters:params];
    XCTAssertGreaterThan(spawned, 0u);
    
    NSArray<SSKParticle *> *particles = [system aliveParticlesSnapshot];
    XCTAssertGreaterThan(particles.count, 0u);
    
    for (SSKParticle *particle in particles) {
        // userScalar stores z-depth in [~0.01, 1.0] when z-depth is enabled
        XCTAssertGreaterThanOrEqual(particle.userScalar, 0.01);
        XCTAssertLessThanOrEqual(particle.userScalar, 1.0);
    }
}

- (void)testGPUSpawnWithoutZDepthEncodesLengthMultiplierInUserScalar {
    SSKParticleSystem *system = [[SSKParticleSystem alloc] initWithCapacity:32];
    if (!system.isMetalSimulationEnabled) {
        XCTSkip(@"Metal simulation unavailable on this system");
    }
    
    SSKParticleSpawnParameters params = SSKParticleSpawnParametersMake();
    params.zDepthEnabled = 0;
    params.lengthMultiplier = 7.5f;
    
    NSUInteger spawned = [system spawnParticlesGPU:8 parameters:params];
    XCTAssertGreaterThan(spawned, 0u);
    
    NSArray<SSKParticle *> *particles = [system aliveParticlesSnapshot];
    XCTAssertGreaterThan(particles.count, 0u);
    
    for (SSKParticle *particle in particles) {
        // Sentinel encoding: >10 means no z-depth; value minus 10 is the length multiplier
        XCTAssertGreaterThan(particle.userScalar, 10.0);
        CGFloat decoded = particle.userScalar - 10.0;
        XCTAssertEqualWithAccuracy(decoded, params.lengthMultiplier, 0.5);
    }
}

#pragma mark - PreviousFrame Mode Index Consistency

- (void)testPreviousFrameModeIndexConsistency {
    SSKParticleSystem *system = [[SSKParticleSystem alloc] initWithCapacity:64];
    if (!system.isMetalSimulationEnabled) {
        XCTSkip(@"Metal simulation unavailable on this system");
    }

    system.metalSimulationRenderMode = SSKMetalSimulationRenderModePreviousFrame;

    // Run 20 spawn-advance cycles with short-lived particles.
    // In PreviousFrame mode the GPU completion handler runs asynchronously,
    // so this exercises the withIndexLock: synchronization on every call to
    // aliveParticleCount and aliveParticlesSnapshot.
    for (NSUInteger cycle = 0; cycle < 20; cycle++) {
        [system spawnParticles:8 initializer:^(SSKParticle *p) {
            p.position = NSMakePoint(0, 0);
            p.velocity = NSMakePoint(1, 0);
            p.maxLife = 0.05;  // very short-lived
            p.life = 0.0;
            p.size = 4.0;
        }];

        [system advanceBy:0.016];

        // These must not crash or return inconsistent values.
        NSUInteger count = system.aliveParticleCount;
        NSArray<SSKParticle *> *snapshot = [system aliveParticlesSnapshot];
        XCTAssertEqual(snapshot.count, count,
                       @"Snapshot count mismatch at cycle %lu", (unsigned long)cycle);
    }

    // Drain all particles.
    BOOL drained = [SSKTestHelpers waitForCondition:^BOOL{
        [system advanceBy:0.1];
        return system.aliveParticleCount == 0;
    } timeout:2.0];
    XCTAssertTrue(drained, @"Particles should drain within timeout");
}

@end

