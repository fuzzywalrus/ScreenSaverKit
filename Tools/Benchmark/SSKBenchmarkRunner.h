#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@class SSKParticleSystem;

/// Benchmark scenario configuration
@interface SSKBenchmarkScenario : NSObject
@property (nonatomic, copy) NSString *name;
@property (nonatomic) NSUInteger particleCount;
@property (nonatomic) BOOL useMetalSimulation;
@property (nonatomic) BOOL useBloom;
@property (nonatomic) NSUInteger iterations;
@end

/// Benchmark result
@interface SSKBenchmarkResult : NSObject
@property (nonatomic, copy) NSString *scenarioName;
@property (nonatomic) NSTimeInterval duration;
@property (nonatomic) NSUInteger particlesSpawned;
@property (nonatomic) NSUInteger particlesAlive;
@property (nonatomic) BOOL usedGPU;
@property (nonatomic) NSUInteger memoryMB;
@property (nonatomic, strong) NSDictionary<NSString *, id> *metrics;
@end

/// Runs automated performance benchmarks
@interface SSKBenchmarkRunner : NSObject

- (instancetype)initWithParticleSystem:(SSKParticleSystem *)particleSystem;

/// Run a single benchmark scenario
- (SSKBenchmarkResult *)runScenario:(SSKBenchmarkScenario *)scenario;

/// Run all predefined benchmark scenarios
- (NSArray<SSKBenchmarkResult *> *)runAllScenarios;

/// Export results to JSON
- (NSData *)exportResultsToJSON:(NSArray<SSKBenchmarkResult *> *)results;

/// Export results to CSV
- (NSString *)exportResultsToCSV:(NSArray<SSKBenchmarkResult *> *)results;

@end

NS_ASSUME_NONNULL_END

