#import <Foundation/Foundation.h>
#import <XCTest/XCTest.h>
#import <Metal/Metal.h>

NS_ASSUME_NONNULL_BEGIN

/// Helper macros and utilities for ScreenSaverKit tests
@interface SSKTestHelpers : NSObject

/// Creates a temporary directory for test artifacts
+ (NSString *)createTempDirectory;

/// Removes a temporary directory
+ (void)removeTempDirectory:(NSString *)path;

/// Asserts two NSPoints are approximately equal (within epsilon)
+ (void)assertPoint:(NSPoint)point1 approximatelyEquals:(NSPoint)point2 epsilon:(CGFloat)epsilon;

/// Asserts two CGFloat values are approximately equal (within epsilon)
+ (void)assertFloat:(CGFloat)value1 approximatelyEquals:(CGFloat)value2 epsilon:(CGFloat)epsilon;

/// Waits for an async operation with timeout
+ (BOOL)waitForCondition:(BOOL(^)(void))condition timeout:(NSTimeInterval)timeout;

/// Attempts to load the particle shader library from source for Metal tests.
/// Returns nil and logs on failure.
+ (nullable id<MTLLibrary>)loadParticleShaderLibraryWithDevice:(id<MTLDevice>)device;

@end

NS_ASSUME_NONNULL_END
