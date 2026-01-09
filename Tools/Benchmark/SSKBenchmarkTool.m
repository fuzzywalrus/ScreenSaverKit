#import <Foundation/Foundation.h>
#import "SSKBenchmarkRunner.h"
#import "ScreenSaverKit/SSKParticleSystem.h"

static void printUsage(const char *programName) {
    printf("Usage: %s [options]\n", programName);
    printf("\n");
    printf("Options:\n");
    printf("  --format <json|csv>    Output format (default: json)\n");
    printf("  --output <file>        Output file path (default: stdout)\n");
    printf("  --scenario <name>      Run specific scenario only\n");
    printf("  --list-scenarios        List all available scenarios\n");
    printf("  --help                 Show this help message\n");
    printf("\n");
    printf("Examples:\n");
    printf("  %s --format json --output results.json\n", programName);
    printf("  %s --format csv > results.csv\n", programName);
    printf("  %s --scenario spawn_100_particles_gpu\n", programName);
}

static NSArray<NSString *> *parseArguments(int argc, const char *argv[]) {
    NSMutableArray<NSString *> *args = [NSMutableArray array];
    for (int i = 1; i < argc; i++) {
        [args addObject:[NSString stringWithUTF8String:argv[i]]];
    }
    return args;
}

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        NSArray<NSString *> *args = parseArguments(argc, argv);
        
        if ([args containsObject:@"--help"] || [args containsObject:@"-h"]) {
            printUsage(argv[0]);
            return 0;
        }
        
        if ([args containsObject:@"--list-scenarios"]) {
            printf("Available scenarios:\n");
            printf("  spawn_100_particles_cpu\n");
            printf("  spawn_100_particles_gpu\n");
            printf("  spawn_500_particles_cpu\n");
            printf("  spawn_500_particles_gpu\n");
            printf("  spawn_1000_particles_cpu\n");
            printf("  spawn_1000_particles_gpu\n");
            return 0;
        }
        
        NSString *format = @"json";
        NSString *outputPath = nil;
        NSString *scenarioName = nil;
        
        for (NSUInteger i = 0; i < args.count; i++) {
            NSString *arg = args[i];
            if ([arg isEqualToString:@"--format"] && i + 1 < args.count) {
                format = args[i + 1];
                i++;
            } else if ([arg isEqualToString:@"--output"] && i + 1 < args.count) {
                outputPath = args[i + 1];
                i++;
            } else if ([arg isEqualToString:@"--scenario"] && i + 1 < args.count) {
                scenarioName = args[i + 1];
                i++;
            }
        }
        
        // Initialize particle system
        SSKParticleSystem *particleSystem = [[SSKParticleSystem alloc] initWithCapacity:2000];
        SSKBenchmarkRunner *runner = [[SSKBenchmarkRunner alloc] initWithParticleSystem:particleSystem];
        
        NSArray<SSKBenchmarkResult *> *results;
        
        if (scenarioName) {
            // Run single scenario
            SSKBenchmarkScenario *scenario = [[SSKBenchmarkScenario alloc] init];
            scenario.name = scenarioName;
            
            if ([scenarioName containsString:@"100"]) {
                scenario.particleCount = 100;
            } else if ([scenarioName containsString:@"500"]) {
                scenario.particleCount = 500;
            } else if ([scenarioName containsString:@"1000"]) {
                scenario.particleCount = 1000;
            } else {
                scenario.particleCount = 100;
            }
            
            scenario.useMetalSimulation = [scenarioName containsString:@"gpu"];
            scenario.iterations = 60;
            
            results = @[[runner runScenario:scenario]];
        } else {
            // Run all scenarios
            results = [runner runAllScenarios];
        }
        
        // Export results
        NSData *outputData = nil;
        if ([format isEqualToString:@"json"]) {
            outputData = [runner exportResultsToJSON:results];
        } else if ([format isEqualToString:@"csv"]) {
            NSString *csv = [runner exportResultsToCSV:results];
            outputData = [csv dataUsingEncoding:NSUTF8StringEncoding];
        } else {
            fprintf(stderr, "Error: Unknown format '%s'. Use 'json' or 'csv'.\n", format.UTF8String);
            return 1;
        }
        
        // Write output
        if (outputPath) {
            NSError *error = nil;
            BOOL success = [outputData writeToFile:outputPath options:NSDataWritingAtomic error:&error];
            if (!success) {
                fprintf(stderr, "Error writing to file: %s\n", error.localizedDescription.UTF8String);
                return 1;
            }
            printf("Results written to: %s\n", outputPath.UTF8String);
        } else {
            printf("%s", [[[NSString alloc] initWithData:outputData encoding:NSUTF8StringEncoding] UTF8String]);
        }
        
        return 0;
    }
}


