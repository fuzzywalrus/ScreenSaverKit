#import <XCTest/XCTest.h>
#import <QuartzCore/QuartzCore.h>
#import "ScreenSaverKit/SSKMetalParticlePass.h"
#import "ScreenSaverKit/SSKMetalBlurPass.h"
#import "ScreenSaverKit/SSKMetalBloomPass.h"
#import "ScreenSaverKit/SSKMetalTrailPass.h"
#import "ScreenSaverKit/SSKMetalTextureCache.h"
#import "ScreenSaverKit/SSKParticleSystem.h"
#import "TestHelpers.h"

@interface SSKMetalPassTests : XCTestCase
@end

@implementation SSKMetalPassTests

- (nullable id<MTLLibrary>)makeTestLibraryWithDevice:(id<MTLDevice>)device {
    return [SSKTestHelpers loadParticleShaderLibraryWithDevice:device];
}

- (void)testParticlePassEncodes {
    id<MTLDevice> device = MTLCreateSystemDefaultDevice();
    if (!device) {
        XCTSkip(@"Metal not available on this system");
    }
    id<MTLLibrary> library = [self makeTestLibraryWithDevice:device];
    if (!library) {
        XCTSkip(@"Failed to compile Metal library for tests");
    }
    SSKMetalParticlePass *pass = [SSKMetalParticlePass new];
    XCTAssertTrue([pass setupWithDevice:device library:library]);
    
    id<MTLCommandQueue> queue = [device newCommandQueue];
    id<MTLCommandBuffer> commandBuffer = [queue commandBuffer];
    
    // Use a tiny particle system to provide instances.
    SSKParticleSystem *system = [[SSKParticleSystem alloc] initWithCapacity:4];
    system.metalSimulationEnabled = NO;
    [system spawnParticles:1 initializer:^(SSKParticle *particle) {
        particle.position = NSMakePoint(4.0, 4.0);
        particle.velocity = NSMakePoint(1.0, 0.0);
        particle.maxLife = 1.0;
        particle.size = 6.0;
        particle.userScalar = 2.0;
    }];
    NSArray<SSKParticle *> *particles = [system aliveParticlesSnapshot];
    
    MTLTextureDescriptor *desc = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm width:32 height:32 mipmapped:NO];
    desc.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead | MTLTextureUsageShaderWrite;
    id<MTLTexture> target = [device newTextureWithDescriptor:desc];
    XCTAssertNotNil(target);
    
    BOOL encoded = [pass encodeParticles:particles
                               blendMode:SSKParticleBlendModeAlpha
                            viewportSize:CGSizeMake(32, 32)
                           commandBuffer:commandBuffer
                            renderTarget:target
                              loadAction:MTLLoadActionClear
                              clearColor:MTLClearColorMake(0, 0, 0, 1)];
    XCTAssertTrue(encoded);
    [commandBuffer commit];
    [commandBuffer waitUntilCompleted];
    XCTAssertEqual(commandBuffer.status, MTLCommandBufferStatusCompleted);
}

- (void)testBlurPassEncodes {
    id<MTLDevice> device = MTLCreateSystemDefaultDevice();
    if (!device) {
        XCTSkip(@"Metal not available on this system");
    }
    id<MTLLibrary> library = [self makeTestLibraryWithDevice:device];
    if (!library) {
        XCTSkip(@"Failed to compile Metal library for tests");
    }
    SSKMetalBlurPass *blur = [SSKMetalBlurPass new];
    XCTAssertTrue([blur setupWithDevice:device library:library]);
    blur.radius = 2.0;
    
    SSKMetalTextureCache *cache = [[SSKMetalTextureCache alloc] initWithDevice:device];
    CGSize size = CGSizeMake(32, 32);
    MTLTextureUsage usage = MTLTextureUsageShaderRead | MTLTextureUsageShaderWrite;
    id<MTLTexture> source = [cache acquireTextureWithSize:size pixelFormat:MTLPixelFormatBGRA8Unorm usage:usage];
    id<MTLTexture> dest = [cache acquireTextureWithSize:size pixelFormat:MTLPixelFormatBGRA8Unorm usage:usage];
    XCTAssertNotNil(source);
    XCTAssertNotNil(dest);
    
    id<MTLCommandQueue> queue = [device newCommandQueue];
    id<MTLCommandBuffer> commandBuffer = [queue commandBuffer];
    BOOL encoded = [blur encodeBlur:source destination:dest commandBuffer:commandBuffer textureCache:cache];
    XCTAssertTrue(encoded);
    [commandBuffer commit];
    [commandBuffer waitUntilCompleted];
    XCTAssertEqual(commandBuffer.status, MTLCommandBufferStatusCompleted);
    
    [cache releaseTexture:source];
    [cache releaseTexture:dest];
}

- (void)testBloomPassEncodes {
    id<MTLDevice> device = MTLCreateSystemDefaultDevice();
    if (!device) {
        XCTSkip(@"Metal not available on this system");
    }
    id<MTLLibrary> library = [self makeTestLibraryWithDevice:device];
    if (!library) {
        XCTSkip(@"Failed to compile Metal library for tests");
    }
    
    SSKMetalBlurPass *blur = [SSKMetalBlurPass new];
    XCTAssertTrue([blur setupWithDevice:device library:library]);
    
    SSKMetalBloomPass *bloom = [SSKMetalBloomPass new];
    XCTAssertTrue([bloom setupWithDevice:device library:library]);
    [bloom setSharedBlurPass:blur];
    bloom.threshold = 0.5;
    bloom.intensity = 1.0;
    bloom.blurSigma = 2.0;
    
    SSKMetalTextureCache *cache = [[SSKMetalTextureCache alloc] initWithDevice:device];
    CGSize size = CGSizeMake(32, 32);
    MTLTextureUsage usage = MTLTextureUsageShaderRead | MTLTextureUsageShaderWrite;
    id<MTLTexture> source = [cache acquireTextureWithSize:size pixelFormat:MTLPixelFormatBGRA8Unorm usage:usage];
    id<MTLTexture> target = [cache acquireTextureWithSize:size pixelFormat:MTLPixelFormatBGRA8Unorm usage:usage];
    XCTAssertNotNil(source);
    XCTAssertNotNil(target);
    
    id<MTLCommandQueue> queue = [device newCommandQueue];
    id<MTLCommandBuffer> commandBuffer = [queue commandBuffer];
    BOOL encoded = [bloom encodeBloomWithCommandBuffer:commandBuffer
                                                source:source
                                          renderTarget:target
                                          textureCache:cache];
    XCTAssertTrue(encoded);
    [commandBuffer commit];
    [commandBuffer waitUntilCompleted];
    XCTAssertEqual(commandBuffer.status, MTLCommandBufferStatusCompleted);
    
    [cache releaseTexture:source];
    [cache releaseTexture:target];
}

#pragma mark - Trail Pass

- (void)testTrailPassInitialization {
    id<MTLDevice> device = MTLCreateSystemDefaultDevice();
    if (!device) {
        XCTSkip(@"Metal not available on this system");
    }
    id<MTLLibrary> library = [self makeTestLibraryWithDevice:device];
    if (!library) {
        XCTSkip(@"Failed to compile Metal library for tests");
    }

    SSKMetalTrailPass *trail = [[SSKMetalTrailPass alloc] initWithDevice:device library:library];
    XCTAssertNotNil(trail);
}

- (void)testTrailTextureCreation {
    id<MTLDevice> device = MTLCreateSystemDefaultDevice();
    if (!device) {
        XCTSkip(@"Metal not available on this system");
    }
    id<MTLLibrary> library = [self makeTestLibraryWithDevice:device];
    if (!library) {
        XCTSkip(@"Failed to compile Metal library for tests");
    }

    SSKMetalTrailPass *trail = [[SSKMetalTrailPass alloc] initWithDevice:device library:library];
    XCTAssertNotNil(trail);

    id<MTLTexture> texture = [trail trailTextureForSize:CGSizeMake(64, 64)];
    XCTAssertNotNil(texture);
    XCTAssertEqual(texture.width, 64u);
    XCTAssertEqual(texture.height, 64u);
}

- (void)testTrailTextureReusedForSameSize {
    id<MTLDevice> device = MTLCreateSystemDefaultDevice();
    if (!device) {
        XCTSkip(@"Metal not available on this system");
    }
    id<MTLLibrary> library = [self makeTestLibraryWithDevice:device];
    if (!library) {
        XCTSkip(@"Failed to compile Metal library for tests");
    }

    SSKMetalTrailPass *trail = [[SSKMetalTrailPass alloc] initWithDevice:device library:library];
    XCTAssertNotNil(trail);

    id<MTLTexture> texture1 = [trail trailTextureForSize:CGSizeMake(64, 64)];
    id<MTLTexture> texture2 = [trail trailTextureForSize:CGSizeMake(64, 64)];
    // Same size should return the same texture object
    XCTAssertEqual(texture1, texture2);
}

- (void)testTrailTextureRecreatedOnSizeChange {
    id<MTLDevice> device = MTLCreateSystemDefaultDevice();
    if (!device) {
        XCTSkip(@"Metal not available on this system");
    }
    id<MTLLibrary> library = [self makeTestLibraryWithDevice:device];
    if (!library) {
        XCTSkip(@"Failed to compile Metal library for tests");
    }

    SSKMetalTrailPass *trail = [[SSKMetalTrailPass alloc] initWithDevice:device library:library];
    XCTAssertNotNil(trail);

    id<MTLTexture> small = [trail trailTextureForSize:CGSizeMake(32, 32)];
    XCTAssertNotNil(small);
    XCTAssertEqual(small.width, 32u);

    id<MTLTexture> large = [trail trailTextureForSize:CGSizeMake(128, 128)];
    XCTAssertNotNil(large);
    XCTAssertEqual(large.width, 128u);
    // Different size should create a new texture
    XCTAssertNotEqual(small, large);
}

- (void)testTrailTextureZeroSizeReturnsNil {
    id<MTLDevice> device = MTLCreateSystemDefaultDevice();
    if (!device) {
        XCTSkip(@"Metal not available on this system");
    }
    id<MTLLibrary> library = [self makeTestLibraryWithDevice:device];
    if (!library) {
        XCTSkip(@"Failed to compile Metal library for tests");
    }

    SSKMetalTrailPass *trail = [[SSKMetalTrailPass alloc] initWithDevice:device library:library];
    XCTAssertNotNil(trail);

    id<MTLTexture> texture = [trail trailTextureForSize:CGSizeMake(0, 0)];
    XCTAssertNil(texture);
}

- (void)testTrailFadeEncodes {
    id<MTLDevice> device = MTLCreateSystemDefaultDevice();
    if (!device) {
        XCTSkip(@"Metal not available on this system");
    }
    id<MTLLibrary> library = [self makeTestLibraryWithDevice:device];
    if (!library) {
        XCTSkip(@"Failed to compile Metal library for tests");
    }

    SSKMetalTrailPass *trail = [[SSKMetalTrailPass alloc] initWithDevice:device library:library];
    XCTAssertNotNil(trail);

    // Create the trail texture first
    id<MTLTexture> texture = [trail trailTextureForSize:CGSizeMake(32, 32)];
    XCTAssertNotNil(texture);

    id<MTLCommandQueue> queue = [device newCommandQueue];
    id<MTLCommandBuffer> commandBuffer = [queue commandBuffer];

    // Fade should encode without crashing
    [trail fadeWithRate:0.05f commandBuffer:commandBuffer];

    [commandBuffer commit];
    [commandBuffer waitUntilCompleted];
    XCTAssertEqual(commandBuffer.status, MTLCommandBufferStatusCompleted);
}

- (void)testTrailBlitEncodes {
    id<MTLDevice> device = MTLCreateSystemDefaultDevice();
    if (!device) {
        XCTSkip(@"Metal not available on this system");
    }
    id<MTLLibrary> library = [self makeTestLibraryWithDevice:device];
    if (!library) {
        XCTSkip(@"Failed to compile Metal library for tests");
    }

    SSKMetalTrailPass *trail = [[SSKMetalTrailPass alloc] initWithDevice:device library:library];
    XCTAssertNotNil(trail);

    id<MTLTexture> texture = [trail trailTextureForSize:CGSizeMake(32, 32)];
    XCTAssertNotNil(texture);

    // Create a destination texture matching the trail size
    MTLTextureDescriptor *desc = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm
                                                                                     width:32
                                                                                    height:32
                                                                                 mipmapped:NO];
    desc.usage = MTLTextureUsageShaderRead | MTLTextureUsageShaderWrite | MTLTextureUsageRenderTarget;
    id<MTLTexture> destination = [device newTextureWithDescriptor:desc];
    XCTAssertNotNil(destination);

    id<MTLCommandQueue> queue = [device newCommandQueue];
    id<MTLCommandBuffer> commandBuffer = [queue commandBuffer];

    [trail blitTo:destination commandBuffer:commandBuffer];

    [commandBuffer commit];
    [commandBuffer waitUntilCompleted];
    XCTAssertEqual(commandBuffer.status, MTLCommandBufferStatusCompleted);
}

- (void)testTrailClearDeferredToFirstFade {
    id<MTLDevice> device = MTLCreateSystemDefaultDevice();
    if (!device) {
        XCTSkip(@"Metal not available on this system");
    }
    id<MTLLibrary> library = [self makeTestLibraryWithDevice:device];
    if (!library) {
        XCTSkip(@"Failed to compile Metal library for tests");
    }

    SSKMetalTrailPass *trail = [[SSKMetalTrailPass alloc] initWithDevice:device library:library];
    XCTAssertNotNil(trail);

    // Texture creation should return immediately (no blocking waitUntilCompleted).
    id<MTLTexture> texture = [trail trailTextureForSize:CGSizeMake(64, 64)];
    XCTAssertNotNil(texture);

    // First fade encodes the deferred clear + the fade kernel.
    id<MTLCommandQueue> queue = [device newCommandQueue];
    id<MTLCommandBuffer> cb1 = [queue commandBuffer];
    [trail fadeWithRate:0.05f commandBuffer:cb1];
    [cb1 commit];
    [cb1 waitUntilCompleted];
    XCTAssertEqual(cb1.status, MTLCommandBufferStatusCompleted,
                   @"First fade (with deferred clear) should complete without error");

    // Second fade should also succeed (no double-clear).
    id<MTLCommandBuffer> cb2 = [queue commandBuffer];
    [trail fadeWithRate:0.05f commandBuffer:cb2];
    [cb2 commit];
    [cb2 waitUntilCompleted];
    XCTAssertEqual(cb2.status, MTLCommandBufferStatusCompleted,
                   @"Second fade should complete without error");

    // Resize triggers the clear flag again.
    id<MTLTexture> resized = [trail trailTextureForSize:CGSizeMake(128, 128)];
    XCTAssertNotNil(resized);
    XCTAssertNotEqual(texture, resized);

    id<MTLCommandBuffer> cb3 = [queue commandBuffer];
    [trail fadeWithRate:0.05f commandBuffer:cb3];
    [cb3 commit];
    [cb3 waitUntilCompleted];
    XCTAssertEqual(cb3.status, MTLCommandBufferStatusCompleted,
                   @"Fade after resize (with deferred clear) should complete without error");
}

#pragma mark - Particle Pass Properties

- (void)testParticlePassRibbonModeProperty {
    SSKMetalParticlePass *pass = [SSKMetalParticlePass new];
    XCTAssertFalse(pass.ribbonModeEnabled);
    pass.ribbonModeEnabled = YES;
    XCTAssertTrue(pass.ribbonModeEnabled);
}

- (void)testParticlePassLengthMultiplierProperty {
    SSKMetalParticlePass *pass = [SSKMetalParticlePass new];
    pass.lengthMultiplier = 12.0;
    XCTAssertEqualWithAccuracy(pass.lengthMultiplier, 12.0, 0.01);
}

@end
