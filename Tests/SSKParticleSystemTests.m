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
    // Force-disable Metal support to hit fallback path (test-only KVC access).
    [system setValue:@(NO) forKey:@"supportsMetalSimulation"];
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
        NSNumber *stackCount = [system valueForKeyPath:@"freeIndicesStack.@count"];
        NSNumber *availableCount = [system valueForKeyPath:@"availableIndices.count"];
        return stackCount.unsignedIntegerValue == 4 && availableCount.unsignedIntegerValue == 4;
    } timeout:1.0];
    XCTAssertTrue(released);
    
    NSArray<NSNumber *> *stack = [system valueForKey:@"freeIndicesStack"];
    NSSet<NSNumber *> *unique = [NSSet setWithArray:stack];
    XCTAssertEqual(stack.count, unique.count);
    XCTAssertEqual(stack.count, 4u);
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
        NSNumber *stackCount = [system valueForKeyPath:@"freeIndicesStack.@count"];
        return stackCount.unsignedIntegerValue >= 3;
    } timeout:1.0];
    XCTAssertTrue(updated);
    
    NSNumber *stackCount = [system valueForKeyPath:@"freeIndicesStack.@count"];
    NSNumber *availableCount = [system valueForKeyPath:@"availableIndices.count"];
    XCTAssertTrue(stackCount.unsignedIntegerValue >= 3);
    XCTAssertTrue(availableCount.unsignedIntegerValue >= 3);
    NSArray<NSNumber *> *stack = [system valueForKey:@"freeIndicesStack"];
    NSSet<NSNumber *> *unique = [NSSet setWithArray:stack];
    XCTAssertEqual(stack.count, unique.count);
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

@end
