#import "PerformanceBenchmarkView.h"

#import <AppKit/AppKit.h>
#import <QuartzCore/QuartzCore.h>
#import <Metal/Metal.h>
#import <mach/mach.h>
#if __has_include(<UniformTypeIdentifiers/UniformTypeIdentifiers.h>)
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#endif

#import "ScreenSaverKit/SSKDiagnostics.h"
#import "ScreenSaverKit/SSKParticleSystem.h"
#import "ScreenSaverKit/SSKMetalRenderer.h"
#import "ScreenSaverKit/SSKMetalRenderDiagnostics.h"
#import "ScreenSaverKit/SSKAnimationClock.h"

typedef NS_ENUM(NSUInteger, SSKBenchmarkScenario) {
    SSKBenchmarkScenarioSpawnStress,
    SSKBenchmarkScenarioGPUvsCPU,
    SSKBenchmarkScenarioBloomImpact,
    SSKBenchmarkScenarioBatchSpawn,
    SSKBenchmarkScenarioMemoryLeak
};

@interface PerformanceBenchmarkView ()
@property (nonatomic, strong) SSKParticleSystem *particleSystem;
@property (nonatomic, strong) SSKMetalRenderDiagnostics *renderDiagnostics;

@property (nonatomic) SSKBenchmarkScenario currentScenario;
@property (nonatomic) NSUInteger targetParticleCount;
@property (nonatomic) NSUInteger currentParticleCount;
@property (nonatomic) BOOL useMetalSimulation;
@property (nonatomic) BOOL useBloom;
@property (nonatomic) CGFloat bloomIntensity;

// Performance metrics
@property (nonatomic) double currentFPS;
@property (nonatomic) double averageFPS;
@property (nonatomic) double minFPS;
@property (nonatomic) double maxFPS;
@property (nonatomic) NSTimeInterval frameTime;
@property (nonatomic) NSTimeInterval spawnTime;
@property (nonatomic) NSTimeInterval simulationTime;
@property (nonatomic) NSTimeInterval renderTime;
@property (nonatomic) NSTimeInterval bloomTime;
@property (nonatomic) NSUInteger totalFrames;
@property (nonatomic) NSUInteger totalSpawned;
@property (nonatomic) NSUInteger memoryUsageMB;

// Frame time history for histogram
@property (nonatomic, strong) NSMutableArray<NSNumber *> *frameTimeHistory;
@property (nonatomic) NSUInteger frameTimeHistorySize;

// Export
@property (nonatomic, strong) NSMutableArray<NSDictionary *> *performanceData;
@property (nonatomic) BOOL recordingData;
@end

@implementation PerformanceBenchmarkView

- (instancetype)initWithFrame:(NSRect)frame isPreview:(BOOL)isPreview {
    if ((self = [super initWithFrame:frame isPreview:isPreview])) {
        self.animationTimeInterval = 1.0 / 60.0;
        
        _particleSystem = [[SSKParticleSystem alloc] initWithCapacity:5000];
        _particleSystem.metalSimulationEnabled = YES;
        _useMetalSimulation = YES;
        
        _renderDiagnostics = [[SSKMetalRenderDiagnostics alloc] init];
        _renderDiagnostics.overlayEnabled = YES;
        
        _currentScenario = SSKBenchmarkScenarioSpawnStress;
        _targetParticleCount = 100;
        _currentParticleCount = 0;
        _useBloom = NO;
        _bloomIntensity = 0.0;
        
        _currentFPS = 60.0;
        _averageFPS = 60.0;
        _minFPS = 60.0;
        _maxFPS = 60.0;
        _frameTimeHistory = [NSMutableArray arrayWithCapacity:300]; // 5 seconds at 60fps
        _frameTimeHistorySize = 300;
        _performanceData = [NSMutableArray array];
        _recordingData = NO;
        
        [SSKDiagnostics setEnabled:YES];
    }
    return self;
}

- (void)startAnimation {
    [super startAnimation];
    
    // Re-enable Metal simulation (will lazily recreate resources if they were released)
    self.particleSystem.metalSimulationEnabled = self.useMetalSimulation;
    
    // Reset metrics
    self.totalFrames = 0;
    self.totalSpawned = 0;
    self.currentParticleCount = 0;
    [self.frameTimeHistory removeAllObjects];
    [self.performanceData removeAllObjects];
}

- (void)stopAnimation {
    // Reset particle system to release active particles
    [self.particleSystem reset];
    
    // Release Metal resources when idle to reduce memory footprint
    [self.particleSystem releaseMetalResources];
    
    // Stop recording if active
    self.recordingData = NO;
    
    [super stopAnimation];
}

- (void)setupMetalRenderer:(SSKMetalRenderer *)renderer {
    [super setupMetalRenderer:renderer];
    if (renderer && self.metalLayer) {
        [self.renderDiagnostics attachToMetalLayer:self.metalLayer];
    }
}

- (void)renderCPUFrameWithDeltaTime:(NSTimeInterval)dt {
    // CPU fallback rendering
    [self setNeedsDisplay:YES];
}

- (void)animateOneFrame {
    NSTimeInterval frameStart = [[NSDate date] timeIntervalSince1970];
    
    // Get delta time from parent class
    NSTimeInterval dt = [self advanceAnimationClock];
    if (dt <= 0.0) {
        dt = 1.0 / 60.0;
    }
    
    // Update FPS (approximate from delta time)
    self.currentFPS = dt > 0.0 ? 1.0 / dt : 60.0;
    if (self.totalFrames == 0) {
        self.averageFPS = self.currentFPS;
        self.minFPS = self.currentFPS;
        self.maxFPS = self.currentFPS;
    } else {
        self.averageFPS = (self.averageFPS * self.totalFrames + self.currentFPS) / (self.totalFrames + 1);
        self.minFPS = MIN(self.minFPS, self.currentFPS);
        self.maxFPS = MAX(self.maxFPS, self.currentFPS);
    }
    self.totalFrames++;
    
    // Run current scenario
    [self runCurrentScenario:dt];
    
    // Measure simulation time
    NSTimeInterval simStart = [[NSDate date] timeIntervalSince1970];
    [self.particleSystem advanceBy:dt];
    self.simulationTime = ([[NSDate date] timeIntervalSince1970] - simStart) * 1000.0; // ms
    
    // Rendering happens in renderMetalFrame:deltaTime: or renderCPUFrameWithDeltaTime:
    // Render time will be calculated from frame time
    
    // Calculate frame time
    self.frameTime = ([[NSDate date] timeIntervalSince1970] - frameStart) * 1000.0; // ms
    // Render time is frame time minus simulation time
    self.renderTime = MAX(0.0, self.frameTime - self.simulationTime);
    
    // Update frame time history
    [self.frameTimeHistory addObject:@(self.frameTime)];
    if (self.frameTimeHistory.count > self.frameTimeHistorySize) {
        [self.frameTimeHistory removeObjectAtIndex:0];
    }
    
    // Update memory usage
    [self updateMemoryUsage];
    
    // Record performance data if enabled
    if (self.recordingData) {
        [self recordPerformanceData];
    }
    
    [self updateOverlay];
}

- (void)runCurrentScenario:(NSTimeInterval)dt {
    switch (self.currentScenario) {
        case SSKBenchmarkScenarioSpawnStress: {
            // Gradually increase particle count
            if (self.totalFrames % 60 == 0) { // Every second
                self.targetParticleCount += 50;
                if (self.targetParticleCount > 5000) {
                    self.targetParticleCount = 100;
                }
            }
            
            NSUInteger toSpawn = MAX(0, (NSInteger)self.targetParticleCount - (NSInteger)self.particleSystem.aliveParticleCount);
            if (toSpawn > 0) {
                NSTimeInterval spawnStart = [[NSDate date] timeIntervalSince1970];
                [self.particleSystem spawnParticles:toSpawn initializer:^(SSKParticle *particle) {
                    particle.position = NSMakePoint(NSMidX(self.bounds), NSMidY(self.bounds));
                    particle.velocity = NSMakePoint((CGFloat)arc4random() / UINT32_MAX * 200.0 - 100.0,
                                                    (CGFloat)arc4random() / UINT32_MAX * 200.0 - 100.0);
                    particle.maxLife = 2.0;
                    particle.size = 5.0;
                    particle.color = [NSColor whiteColor];
                }];
                self.spawnTime = ([[NSDate date] timeIntervalSince1970] - spawnStart) * 1000.0; // ms
                self.totalSpawned += toSpawn;
            }
            break;
        }
        case SSKBenchmarkScenarioGPUvsCPU: {
            // Toggle between GPU and CPU every 5 seconds
            if (self.totalFrames % 300 == 0) {
                self.useMetalSimulation = !self.useMetalSimulation;
                self.particleSystem.metalSimulationEnabled = self.useMetalSimulation;
            }
            
            // Maintain constant particle count
            NSUInteger current = self.particleSystem.aliveParticleCount;
            if (current < 500) {
                [self.particleSystem spawnParticles:500 - current initializer:^(SSKParticle *particle) {
                    particle.position = NSMakePoint(NSMidX(self.bounds), NSMidY(self.bounds));
                    particle.velocity = NSMakePoint((CGFloat)arc4random() / UINT32_MAX * 100.0 - 50.0,
                                                    (CGFloat)arc4random() / UINT32_MAX * 100.0 - 50.0);
                    particle.maxLife = 3.0;
                    particle.size = 3.0;
                    particle.color = [NSColor whiteColor];
                }];
            }
            break;
        }
        case SSKBenchmarkScenarioBloomImpact: {
            // Toggle bloom every 5 seconds
            if (self.totalFrames % 300 == 0) {
                self.useBloom = !self.useBloom;
                self.bloomIntensity = self.useBloom ? 0.5 : 0.0;
            }
            
            // Maintain constant particle count
            NSUInteger current = self.particleSystem.aliveParticleCount;
            if (current < 300) {
                [self.particleSystem spawnParticles:300 - current initializer:^(SSKParticle *particle) {
                    particle.position = NSMakePoint(NSMidX(self.bounds), NSMidY(self.bounds));
                    particle.velocity = NSMakePoint((CGFloat)arc4random() / UINT32_MAX * 100.0 - 50.0,
                                                    (CGFloat)arc4random() / UINT32_MAX * 100.0 - 50.0);
                    particle.maxLife = 2.0;
                    particle.size = 4.0;
                    particle.color = [NSColor whiteColor];
                }];
            }
            break;
        }
        case SSKBenchmarkScenarioBatchSpawn: {
            // Spawn in batches vs single particles
            if (self.totalFrames % 60 == 0) {
                NSTimeInterval spawnStart = [[NSDate date] timeIntervalSince1970];
                [self.particleSystem spawnParticles:100 initializer:^(SSKParticle *particle) {
                    particle.position = NSMakePoint(NSMidX(self.bounds), NSMidY(self.bounds));
                    particle.velocity = NSMakePoint((CGFloat)arc4random() / UINT32_MAX * 100.0 - 50.0,
                                                    (CGFloat)arc4random() / UINT32_MAX * 100.0 - 50.0);
                    particle.maxLife = 1.0;
                    particle.size = 3.0;
                    particle.color = [NSColor whiteColor];
                }];
                self.spawnTime = ([[NSDate date] timeIntervalSince1970] - spawnStart) * 1000.0; // ms
                self.totalSpawned += 100;
            }
            break;
        }
        case SSKBenchmarkScenarioMemoryLeak: {
            // Continuously spawn particles to detect memory leaks
            if (self.totalFrames % 10 == 0) {
                [self.particleSystem spawnParticles:10 initializer:^(SSKParticle *particle) {
                    particle.position = NSMakePoint(NSMidX(self.bounds), NSMidY(self.bounds));
                    particle.velocity = NSMakePoint((CGFloat)arc4random() / UINT32_MAX * 50.0 - 25.0,
                                                    (CGFloat)arc4random() / UINT32_MAX * 50.0 - 25.0);
                    particle.maxLife = 5.0;
                    particle.size = 2.0;
                    particle.color = [NSColor whiteColor];
                }];
                self.totalSpawned += 10;
            }
            break;
        }
    }
    
    self.currentParticleCount = self.particleSystem.aliveParticleCount;
}

- (void)renderMetalFrame:(SSKMetalRenderer *)renderer deltaTime:(NSTimeInterval)dt {
    NSArray<SSKParticle *> *particles = [self.particleSystem aliveParticlesSnapshot];
    [renderer drawParticles:particles
                  blendMode:self.particleSystem.blendMode
               viewportSize:self.bounds.size];
    
    // Measure bloom time if enabled
    if (self.useBloom && self.bloomIntensity > 0.01) {
        NSTimeInterval bloomStart = [[NSDate date] timeIntervalSince1970];
        renderer.bloomThreshold = 0.7;
        [renderer applyBloom:self.bloomIntensity];
        self.bloomTime = ([[NSDate date] timeIntervalSince1970] - bloomStart) * 1000.0; // ms
    } else {
        self.bloomTime = 0.0;
    }
}

- (void)updateMemoryUsage {
    struct task_basic_info info;
    mach_msg_type_number_t size = sizeof(info);
    kern_return_t kerr = task_info(mach_task_self(), TASK_BASIC_INFO, (task_info_t)&info, &size);
    if (kerr == KERN_SUCCESS) {
        self.memoryUsageMB = (NSUInteger)(info.resident_size / (1024 * 1024));
    }
}

- (void)recordPerformanceData {
    NSDictionary *data = @{
        @"timestamp": @([[NSDate date] timeIntervalSince1970]),
        @"fps": @(self.currentFPS),
        @"frameTime_ms": @(self.frameTime),
        @"spawnTime_ms": @(self.spawnTime),
        @"simulationTime_ms": @(self.simulationTime),
        @"renderTime_ms": @(self.renderTime),
        @"bloomTime_ms": @(self.bloomTime),
        @"particleCount": @(self.currentParticleCount),
        @"memoryMB": @(self.memoryUsageMB),
        @"scenario": @(self.currentScenario),
        @"useMetalSimulation": @(self.useMetalSimulation),
        @"useBloom": @(self.useBloom)
    };
    [self.performanceData addObject:data];
}

- (void)updateOverlay {
    NSMutableArray<NSString *> *lines = [NSMutableArray array];
    
    [lines addObject:[NSString stringWithFormat:@"FPS: %.1f (avg: %.1f, min: %.1f, max: %.1f)",
                     self.currentFPS, self.averageFPS, self.minFPS, self.maxFPS]];
    [lines addObject:[NSString stringWithFormat:@"Frame Time: %.2f ms", self.frameTime]];
    [lines addObject:[NSString stringWithFormat:@"Particles: %lu alive, %lu total spawned",
                     (unsigned long)self.currentParticleCount, (unsigned long)self.totalSpawned]];
    [lines addObject:[NSString stringWithFormat:@"Simulation: %.2f ms (%@)",
                     self.simulationTime, self.useMetalSimulation ? @"GPU" : @"CPU"]];
    [lines addObject:[NSString stringWithFormat:@"Render: %.2f ms", self.renderTime]];
    if (self.useBloom) {
        [lines addObject:[NSString stringWithFormat:@"Bloom: %.2f ms", self.bloomTime]];
    }
    [lines addObject:[NSString stringWithFormat:@"Memory: %lu MB", (unsigned long)self.memoryUsageMB]];
    [lines addObject:[NSString stringWithFormat:@"Spawn Time: %.2f ms", self.spawnTime]];
    
    NSString *scenarioName = @"Unknown";
    switch (self.currentScenario) {
        case SSKBenchmarkScenarioSpawnStress:
            scenarioName = @"Spawn Stress Test";
            break;
        case SSKBenchmarkScenarioGPUvsCPU:
            scenarioName = @"GPU vs CPU";
            break;
        case SSKBenchmarkScenarioBloomImpact:
            scenarioName = @"Bloom Impact";
            break;
        case SSKBenchmarkScenarioBatchSpawn:
            scenarioName = @"Batch Spawn";
            break;
        case SSKBenchmarkScenarioMemoryLeak:
            scenarioName = @"Memory Leak Detection";
            break;
    }
    [lines addObject:[NSString stringWithFormat:@"Scenario: %@", scenarioName]];
    
    if (self.recordingData) {
        [lines addObject:@"Recording: ON"];
    }
    
    [self.renderDiagnostics updateOverlayWithTitle:@"Performance Benchmark"
                                         extraLines:lines
                                    framesPerSecond:self.currentFPS];
}

- (void)drawRect:(NSRect)dirtyRect {
    [[NSColor blackColor] setFill];
    NSRectFill(dirtyRect);
    
    // Draw frame time histogram
    if (self.frameTimeHistory.count > 1) {
        NSRect bounds = self.bounds;
        CGFloat histWidth = bounds.size.width * 0.3;
        CGFloat histHeight = bounds.size.height * 0.2;
        CGFloat histX = bounds.size.width - histWidth - 20;
        CGFloat histY = 20;
        
        NSBezierPath *path = [NSBezierPath bezierPath];
        CGFloat maxTime = 33.33; // 30fps threshold
        CGFloat barWidth = histWidth / self.frameTimeHistory.count;
        
        for (NSUInteger i = 0; i < self.frameTimeHistory.count; i++) {
            CGFloat time = [self.frameTimeHistory[i] doubleValue];
            CGFloat normalized = MIN(time / maxTime, 1.0);
            CGFloat barHeight = normalized * histHeight;
            CGFloat x = histX + i * barWidth;
            
            NSRect bar = NSMakeRect(x, histY, barWidth - 1, barHeight);
            if (normalized > 1.0) {
                [[NSColor redColor] setFill];
            } else if (normalized > 0.8) {
                [[NSColor yellowColor] setFill];
            } else {
                [[NSColor greenColor] setFill];
            }
            NSRectFill(bar);
        }
        
        // Draw threshold line
        [[NSColor whiteColor] setStroke];
        CGFloat thresholdY = histY + (histHeight * (16.67 / maxTime)); // 60fps line
        [path moveToPoint:NSMakePoint(histX, thresholdY)];
        [path lineToPoint:NSMakePoint(histX + histWidth, thresholdY)];
        [path stroke];
    }
}

- (BOOL)hasConfigureSheet {
    return YES;
}

- (NSWindow *)configureSheet {
    NSWindow *window = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 400, 300)
                                                   styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable
                                                     backing:NSBackingStoreBuffered
                                                       defer:NO];
    window.title = @"Performance Benchmark Configuration";
    
    NSView *contentView = window.contentView;
    NSStackView *stack = [[NSStackView alloc] initWithFrame:contentView.bounds];
    stack.orientation = NSUserInterfaceLayoutOrientationVertical;
    stack.spacing = 10;
    stack.edgeInsets = NSEdgeInsetsMake(20, 20, 20, 20);
    
    NSPopUpButton *scenarioPopup = [[NSPopUpButton alloc] initWithFrame:NSZeroRect pullsDown:NO];
    [scenarioPopup addItemWithTitle:@"Spawn Stress Test"];
    [scenarioPopup addItemWithTitle:@"GPU vs CPU"];
    [scenarioPopup addItemWithTitle:@"Bloom Impact"];
    [scenarioPopup addItemWithTitle:@"Batch Spawn"];
    [scenarioPopup addItemWithTitle:@"Memory Leak Detection"];
    scenarioPopup.target = self;
    scenarioPopup.action = @selector(scenarioChanged:);
    [stack addArrangedSubview:scenarioPopup];
    
    NSButton *recordButton = [NSButton buttonWithTitle:@"Start Recording" target:self action:@selector(toggleRecording:)];
    [stack addArrangedSubview:recordButton];
    
    NSButton *exportButton = [NSButton buttonWithTitle:@"Export Data" target:self action:@selector(exportData:)];
    [stack addArrangedSubview:exportButton];
    
    [contentView addSubview:stack];
    
    return window;
}

- (void)scenarioChanged:(NSPopUpButton *)sender {
    self.currentScenario = (SSKBenchmarkScenario)sender.indexOfSelectedItem;
    [self.particleSystem reset];
    self.totalSpawned = 0;
    self.totalFrames = 0;
}

- (void)toggleRecording:(NSButton *)sender {
    self.recordingData = !self.recordingData;
    sender.title = self.recordingData ? @"Stop Recording" : @"Start Recording";
}

- (void)exportData:(NSButton *)sender {
    if (self.performanceData.count == 0) {
        NSAlert *alert = [[NSAlert alloc] init];
        alert.messageText = @"No Data";
        alert.informativeText = @"No performance data has been recorded yet.";
        [alert runModal];
        return;
    }
    
    NSSavePanel *savePanel = [NSSavePanel savePanel];
    #if __has_include(<UniformTypeIdentifiers/UniformTypeIdentifiers.h>)
    if (@available(macOS 11.0, *)) {
        savePanel.allowedContentTypes = @[[UTType typeWithIdentifier:@"public.json"]];
    } else {
        // Fallback for macOS 10.x
        #pragma clang diagnostic push
        #pragma clang diagnostic ignored "-Wdeprecated-declarations"
        savePanel.allowedFileTypes = @[@"json"];
        #pragma clang diagnostic pop
    }
    #else
    // Fallback for systems without UniformTypeIdentifiers
    #pragma clang diagnostic push
    #pragma clang diagnostic ignored "-Wdeprecated-declarations"
    savePanel.allowedFileTypes = @[@"json"];
    #pragma clang diagnostic pop
    #endif
    savePanel.nameFieldStringValue = @"performance_data.json";
    
    if ([savePanel runModal] == NSModalResponseOK) {
        NSURL *url = savePanel.URL;
        NSData *jsonData = [NSJSONSerialization dataWithJSONObject:self.performanceData
                                                           options:NSJSONWritingPrettyPrinted
                                                             error:nil];
        [jsonData writeToURL:url atomically:YES];
    }
}

@end

