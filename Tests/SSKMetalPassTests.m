#import <XCTest/XCTest.h>
#import <QuartzCore/QuartzCore.h>
#import "ScreenSaverKit/SSKMetalParticlePass.h"
#import "ScreenSaverKit/SSKMetalBlurPass.h"
#import "ScreenSaverKit/SSKMetalBloomPass.h"
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

@end
