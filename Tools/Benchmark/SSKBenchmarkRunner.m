#import "SSKBenchmarkRunner.h"
#import "ScreenSaverKit/SSKParticleSystem.h"
#import <Metal/Metal.h>
#import <mach/mach.h>

@implementation SSKBenchmarkScenario
@end

@implementation SSKBenchmarkResult
@end

@interface SSKBenchmarkRunner ()
@property (nonatomic, strong) SSKParticleSystem *particleSystem;
@end

@implementation SSKBenchmarkRunner

- (instancetype)initWithParticleSystem:(SSKParticleSystem *)particleSystem {
    if ((self = [super init])) {
        _particleSystem = particleSystem;
    }
    return self;
}

- (SSKBenchmarkResult *)runScenario:(SSKBenchmarkScenario *)scenario {
    SSKBenchmarkResult *result = [[SSKBenchmarkResult alloc] init];
    result.scenarioName = scenario.name;
    // Check if Metal simulation is actually enabled (it may be disabled if Metal is unavailable)
    BOOL metalRequested = scenario.useMetalSimulation;
    self.particleSystem.metalSimulationEnabled = metalRequested;
    result.usedGPU = metalRequested && self.particleSystem.isMetalSimulationEnabled;
    
    // Configure particle system
    self.particleSystem.metalSimulationEnabled = scenario.useMetalSimulation;
    [self.particleSystem reset];
    
    NSDate *startDate = [NSDate date];
    
    // Spawn particles
    NSTimeInterval spawnStart = [[NSDate date] timeIntervalSince1970];
    [self.particleSystem spawnParticles:scenario.particleCount initializer:^(SSKParticle *particle) {
        particle.position = NSMakePoint(100.0, 100.0);
        particle.velocity = NSMakePoint((CGFloat)arc4random() / UINT32_MAX * 100.0 - 50.0,
                                        (CGFloat)arc4random() / UINT32_MAX * 100.0 - 50.0);
        particle.maxLife = 2.0;
        particle.size = 5.0;
        particle.color = [NSColor whiteColor];
    }];
    NSTimeInterval spawnTime = ([[NSDate date] timeIntervalSince1970] - spawnStart) * 1000.0;
    
    result.particlesSpawned = scenario.particleCount;
    result.particlesAlive = self.particleSystem.aliveParticleCount;
    
    // Run simulation iterations
    NSTimeInterval totalSimTime = 0.0;
    for (NSUInteger i = 0; i < scenario.iterations; i++) {
        NSTimeInterval simStart = [[NSDate date] timeIntervalSince1970];
        [self.particleSystem advanceBy:1.0 / 60.0]; // 60fps delta
        totalSimTime += ([[NSDate date] timeIntervalSince1970] - simStart) * 1000.0;
    }
    
    NSTimeInterval totalDuration = [[NSDate date] timeIntervalSinceDate:startDate] * 1000.0;
    result.duration = totalDuration;
    
    // Get memory usage
    struct task_basic_info info;
    mach_msg_type_number_t size = sizeof(info);
    kern_return_t kerr = task_info(mach_task_self(), TASK_BASIC_INFO, (task_info_t)&info, &size);
    if (kerr == KERN_SUCCESS) {
        result.memoryMB = (NSUInteger)(info.resident_size / (1024 * 1024));
    }
    
    // Build metrics dictionary
    result.metrics = @{
        @"spawnTime_ms": @(spawnTime),
        @"simulationTime_ms": @(totalSimTime),
        @"avgSimulationTime_ms": @(totalSimTime / scenario.iterations),
        @"iterations": @(scenario.iterations),
        @"particlesAlive": @(result.particlesAlive)
    };
    
    return result;
}

- (NSArray<SSKBenchmarkResult *> *)runAllScenarios {
    NSMutableArray<SSKBenchmarkResult *> *results = [NSMutableArray array];
    
    // Scenario 1: Small batch CPU
    SSKBenchmarkScenario *scenario1 = [[SSKBenchmarkScenario alloc] init];
    scenario1.name = @"spawn_100_particles_cpu";
    scenario1.particleCount = 100;
    scenario1.useMetalSimulation = NO;
    scenario1.iterations = 60;
    [results addObject:[self runScenario:scenario1]];
    
    // Scenario 2: Small batch GPU
    SSKBenchmarkScenario *scenario2 = [[SSKBenchmarkScenario alloc] init];
    scenario2.name = @"spawn_100_particles_gpu";
    scenario2.particleCount = 100;
    scenario2.useMetalSimulation = YES;
    scenario2.iterations = 60;
    [results addObject:[self runScenario:scenario2]];
    
    // Scenario 3: Medium batch CPU
    SSKBenchmarkScenario *scenario3 = [[SSKBenchmarkScenario alloc] init];
    scenario3.name = @"spawn_500_particles_cpu";
    scenario3.particleCount = 500;
    scenario3.useMetalSimulation = NO;
    scenario3.iterations = 60;
    [results addObject:[self runScenario:scenario3]];
    
    // Scenario 4: Medium batch GPU
    SSKBenchmarkScenario *scenario4 = [[SSKBenchmarkScenario alloc] init];
    scenario4.name = @"spawn_500_particles_gpu";
    scenario4.particleCount = 500;
    scenario4.useMetalSimulation = YES;
    scenario4.iterations = 60;
    [results addObject:[self runScenario:scenario4]];
    
    // Scenario 5: Large batch CPU
    SSKBenchmarkScenario *scenario5 = [[SSKBenchmarkScenario alloc] init];
    scenario5.name = @"spawn_1000_particles_cpu";
    scenario5.particleCount = 1000;
    scenario5.useMetalSimulation = NO;
    scenario5.iterations = 60;
    [results addObject:[self runScenario:scenario5]];
    
    // Scenario 6: Large batch GPU
    SSKBenchmarkScenario *scenario6 = [[SSKBenchmarkScenario alloc] init];
    scenario6.name = @"spawn_1000_particles_gpu";
    scenario6.particleCount = 1000;
    scenario6.useMetalSimulation = YES;
    scenario6.iterations = 60;
    [results addObject:[self runScenario:scenario6]];
    
    return results;
}

- (NSData *)exportResultsToJSON:(NSArray<SSKBenchmarkResult *> *)results {
    NSMutableDictionary *output = [NSMutableDictionary dictionary];
    output[@"timestamp"] = @([[NSDate date] timeIntervalSince1970]);
    
    // Get device info
    id<MTLDevice> device = MTLCreateSystemDefaultDevice();
    if (device) {
        NSString *deviceName = @"Unknown";
        if ([device respondsToSelector:@selector(name)]) {
            id nameValue = [device performSelector:@selector(name)];
            if ([nameValue isKindOfClass:[NSString class]]) {
                deviceName = (NSString *)nameValue;
            }
        }
        output[@"device"] = deviceName;
        BOOL isLowPower = NO;
        if ([device respondsToSelector:@selector(isLowPower)]) {
            id lowPowerValue = [device performSelector:@selector(isLowPower)];
            if ([lowPowerValue respondsToSelector:@selector(boolValue)]) {
                isLowPower = [lowPowerValue boolValue];
            } else if ([lowPowerValue isKindOfClass:[NSNumber class]]) {
                isLowPower = [(NSNumber *)lowPowerValue boolValue];
            }
        }
        output[@"lowPower"] = @(isLowPower);
    } else {
        output[@"device"] = @"No Metal Device";
    }
    
    NSMutableArray<NSDictionary *> *scenarios = [NSMutableArray array];
    for (SSKBenchmarkResult *result in results) {
        NSMutableDictionary *scenario = [NSMutableDictionary dictionary];
        scenario[@"name"] = result.scenarioName;
        scenario[@"duration_ms"] = @(result.duration);
        scenario[@"particles_spawned"] = @(result.particlesSpawned);
        scenario[@"particles_alive"] = @(result.particlesAlive);
        scenario[@"path"] = result.usedGPU ? @"GPU" : @"CPU";
        scenario[@"memory_mb"] = @(result.memoryMB);
        [scenario addEntriesFromDictionary:result.metrics];
        [scenarios addObject:scenario];
    }
    output[@"scenarios"] = scenarios;
    
    return [NSJSONSerialization dataWithJSONObject:output
                                           options:NSJSONWritingPrettyPrinted
                                             error:nil];
}

- (NSString *)exportResultsToCSV:(NSArray<SSKBenchmarkResult *> *)results {
    NSMutableString *csv = [NSMutableString string];
    
    // Header
    [csv appendString:@"Scenario,Path,Particles Spawned,Particles Alive,Duration (ms),Spawn Time (ms),Avg Sim Time (ms),Memory (MB)\n"];
    
    // Data rows
    for (SSKBenchmarkResult *result in results) {
        NSString *path = result.usedGPU ? @"GPU" : @"CPU";
        NSNumber *spawnTime = result.metrics[@"spawnTime_ms"] ?: @0;
        NSNumber *avgSimTime = result.metrics[@"avgSimulationTime_ms"] ?: @0;
        
        [csv appendFormat:@"%@,%@,%lu,%lu,%.2f,%.2f,%.2f,%lu\n",
         result.scenarioName,
         path,
         (unsigned long)result.particlesSpawned,
         (unsigned long)result.particlesAlive,
         result.duration,
         spawnTime.doubleValue,
         avgSimTime.doubleValue,
         (unsigned long)result.memoryMB];
    }
    
    return csv;
}

@end

