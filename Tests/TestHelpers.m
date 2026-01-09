#import "TestHelpers.h"

@implementation SSKTestHelpers

+ (NSString *)createTempDirectory {
    NSString *tempDir = [NSTemporaryDirectory() stringByAppendingPathComponent:
                        [NSString stringWithFormat:@"SSKTests_%lu", (unsigned long)[NSDate date].timeIntervalSince1970]];
    [[NSFileManager defaultManager] createDirectoryAtPath:tempDir
                                withIntermediateDirectories:YES
                                                 attributes:nil
                                                      error:nil];
    return tempDir;
}

+ (void)removeTempDirectory:(NSString *)path {
    [[NSFileManager defaultManager] removeItemAtPath:path error:nil];
}

+ (void)assertPoint:(NSPoint)point1 approximatelyEquals:(NSPoint)point2 epsilon:(CGFloat)epsilon {
    XCTAssertEqualWithAccuracy(point1.x, point2.x, epsilon, @"Point X values should be approximately equal");
    XCTAssertEqualWithAccuracy(point1.y, point2.y, epsilon, @"Point Y values should be approximately equal");
}

+ (void)assertFloat:(CGFloat)value1 approximatelyEquals:(CGFloat)value2 epsilon:(CGFloat)epsilon {
    XCTAssertEqualWithAccuracy(value1, value2, epsilon, @"Float values should be approximately equal");
}

+ (BOOL)waitForCondition:(BOOL(^)(void))condition timeout:(NSTimeInterval)timeout {
    NSDate *startDate = [NSDate date];
    while (!condition()) {
        if ([[NSDate date] timeIntervalSinceDate:startDate] > timeout) {
            return NO;
        }
        [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.01]];
    }
    return YES;
}

+ (nullable id<MTLLibrary>)loadParticleShaderLibraryWithDevice:(id<MTLDevice>)device {
    if (!device) { return nil; }
    NSArray<NSString *> *searchRoots = @[
        [[NSFileManager defaultManager] currentDirectoryPath] ?: @"",
        [[[NSBundle bundleForClass:[self class]] bundlePath] stringByDeletingLastPathComponent] ?: @"",
        [[[NSBundle mainBundle] bundlePath] stringByDeletingLastPathComponent] ?: @""
    ];
    NSString *path = nil;
    for (NSString *root in searchRoots) {
        if (root.length == 0) { continue; }
        NSString *candidate = [root stringByAppendingPathComponent:@"ScreenSaverKit/Shaders/SSKParticleShaders.metal"];
        if ([[NSFileManager defaultManager] fileExistsAtPath:candidate]) {
            path = candidate;
            break;
        }
        NSString *parent = root;
        for (NSUInteger i = 0; i < 4 && parent.length > 1; i++) {
            parent = [parent stringByDeletingLastPathComponent];
            candidate = [parent stringByAppendingPathComponent:@"ScreenSaverKit/Shaders/SSKParticleShaders.metal"];
            if ([[NSFileManager defaultManager] fileExistsAtPath:candidate]) {
                path = candidate;
                break;
            }
        }
        if (path) { break; }
    }
    if (!path) {
        NSLog(@"SSKTestHelpers: could not locate SSKParticleShaders.metal for Metal tests.");
        return nil;
    }
    NSError *readError = nil;
    NSString *source = [NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:&readError];
    if (!source) {
        NSLog(@"SSKTestHelpers: failed to read Metal shader source at %@ (%@)", path, readError.localizedDescription);
        return nil;
    }
    NSError *compileError = nil;
    id<MTLLibrary> library = [device newLibraryWithSource:source options:nil error:&compileError];
    if (!library && compileError) {
        NSLog(@"SSKTestHelpers: Metal shader compilation failed: %@", compileError);
    }
    return library;
}

@end

