#import <XCTest/XCTest.h>
#import <QuartzCore/QuartzCore.h>
#import <math.h>  // NAN, INFINITY, isfinite
#import "ScreenSaverKit/SSKMetalSpritePass.h"
#import "ScreenSaverKit/SSKSprite.h"
#import "ScreenSaverKit/SSKSpriteAnimationSequence.h"
#import "ScreenSaverKit/SSKParticleSystem.h"
#import "SSKMetalSpritePass+Testing.h"
#import "TestHelpers.h"

@interface SSKSpriteTests : XCTestCase
@end

@implementation SSKSpriteTests

#pragma mark - SSKSprite Tests

- (void)testSpriteDefaultValues {
    SSKSprite *sprite = [[SSKSprite alloc] init];
    
    XCTAssertEqual(sprite.position.x, 0.0);
    XCTAssertEqual(sprite.position.y, 0.0);
    XCTAssertEqual(sprite.size.width, 100.0);
    XCTAssertEqual(sprite.size.height, 100.0);
    XCTAssertEqual(sprite.rotation, 0.0);
    XCTAssertEqual(sprite.anchor.x, 0.5);
    XCTAssertEqual(sprite.anchor.y, 0.5);
    XCTAssertEqual(sprite.scale.width, 1.0);   // Scale defaults to 1,1
    XCTAssertEqual(sprite.scale.height, 1.0);
    XCTAssertEqual(sprite.flipX, NO);          // No flip by default
    XCTAssertEqual(sprite.flipY, NO);
    XCTAssertEqual(sprite.opacity, 1.0);
    XCTAssertEqual(sprite.z, 0.0f);  // Z defaults to 0
    XCTAssertNotNil(sprite.colorTint);
    XCTAssertNil(sprite.image);
    XCTAssertEqual(sprite.textureOffset.x, 0.0);
    XCTAssertEqual(sprite.textureOffset.y, 0.0);
    XCTAssertEqual(sprite.textureSize.width, 1.0);
    XCTAssertEqual(sprite.textureSize.height, 1.0);
    
    // Animation defaults
    XCTAssertNil(sprite.animation);
    XCTAssertEqual(sprite.animationTime, 0.0);
    XCTAssertEqual(sprite.animationRate, 1.0);
    XCTAssertEqual(sprite.animationPlaying, NO);
    
    // Cached color should be white
    simd_float4 color = sprite.colorTintFloat4;
    XCTAssertEqual(color.x, 1.0f);
    XCTAssertEqual(color.y, 1.0f);
    XCTAssertEqual(color.z, 1.0f);
    XCTAssertEqual(color.w, 1.0f);
}

- (void)testSpriteZProperty {
    SSKSprite *sprite = [[SSKSprite alloc] init];
    
    sprite.z = 5.0f;
    XCTAssertEqual(sprite.z, 5.0f);
    
    sprite.z = -10.0f;
    XCTAssertEqual(sprite.z, -10.0f);
    
    sprite.z = 0.0f;
    XCTAssertEqual(sprite.z, 0.0f);
}

- (void)testSpriteWithPosition {
    SSKSprite *sprite = [SSKSprite spriteWithPosition:NSMakePoint(100.0, 200.0) size:NSMakeSize(50.0, 75.0)];
    
    XCTAssertEqual(sprite.position.x, 100.0);
    XCTAssertEqual(sprite.position.y, 200.0);
    XCTAssertEqual(sprite.size.width, 50.0);
    XCTAssertEqual(sprite.size.height, 75.0);
}

- (void)testSpriteWithImage {
    // Create a test image with known pixel dimensions using bitmap representation
    // Using a bitmap rep ensures we get exact pixel dimensions regardless of screen scale
    NSBitmapImageRep *bitmapRep = [[NSBitmapImageRep alloc]
        initWithBitmapDataPlanes:NULL
                      pixelsWide:64
                      pixelsHigh:64
                   bitsPerSample:8
                 samplesPerPixel:4
                        hasAlpha:YES
                        isPlanar:NO
                  colorSpaceName:NSCalibratedRGBColorSpace
                     bytesPerRow:0
                    bitsPerPixel:0];
    NSImage *image = [[NSImage alloc] initWithSize:NSMakeSize(64, 64)];
    [image addRepresentation:bitmapRep];
    
    SSKSprite *sprite = [SSKSprite spriteWithImage:image];
    
    XCTAssertNotNil(sprite.image);
    // SSKSprite uses pixel dimensions, not point dimensions
    XCTAssertEqual(sprite.size.width, 64.0);
    XCTAssertEqual(sprite.size.height, 64.0);
}

- (void)testSpritePropertySetters {
    SSKSprite *sprite = [[SSKSprite alloc] init];
    
    sprite.position = NSMakePoint(150.0, 250.0);
    sprite.size = NSMakeSize(200.0, 100.0);
    sprite.rotation = M_PI / 4.0;
    sprite.anchor = NSMakePoint(0.0, 1.0);  // Top-left anchor
    sprite.opacity = 0.5;
    sprite.colorTint = [NSColor blueColor];
    sprite.textureOffset = NSMakePoint(0.25, 0.25);
    sprite.textureSize = NSMakeSize(0.5, 0.5);
    
    XCTAssertEqual(sprite.position.x, 150.0);
    XCTAssertEqual(sprite.position.y, 250.0);
    XCTAssertEqual(sprite.size.width, 200.0);
    XCTAssertEqual(sprite.size.height, 100.0);
    XCTAssertEqualWithAccuracy(sprite.rotation, M_PI / 4.0, 0.0001);
    XCTAssertEqual(sprite.anchor.x, 0.0);
    XCTAssertEqual(sprite.anchor.y, 1.0);
    XCTAssertEqual(sprite.opacity, 0.5);
    XCTAssertEqualObjects(sprite.colorTint, [NSColor blueColor]);
    XCTAssertEqual(sprite.textureOffset.x, 0.25);
    XCTAssertEqual(sprite.textureOffset.y, 0.25);
    XCTAssertEqual(sprite.textureSize.width, 0.5);
    XCTAssertEqual(sprite.textureSize.height, 0.5);
}

- (void)testSpriteCachedColorTint {
    SSKSprite *sprite = [[SSKSprite alloc] init];
    
    // Set to red
    sprite.colorTint = [NSColor redColor];
    simd_float4 redColor = sprite.colorTintFloat4;
    XCTAssertEqualWithAccuracy(redColor.x, 1.0f, 0.01f);
    XCTAssertEqualWithAccuracy(redColor.y, 0.0f, 0.01f);
    XCTAssertEqualWithAccuracy(redColor.z, 0.0f, 0.01f);
    XCTAssertEqualWithAccuracy(redColor.w, 1.0f, 0.01f);
    
    // Change to green - cache should update
    sprite.colorTint = [NSColor greenColor];
    simd_float4 greenColor = sprite.colorTintFloat4;
    XCTAssertEqualWithAccuracy(greenColor.x, 0.0f, 0.01f);
    XCTAssertEqualWithAccuracy(greenColor.y, 1.0f, 0.01f);
    XCTAssertEqualWithAccuracy(greenColor.z, 0.0f, 0.01f);
    XCTAssertEqualWithAccuracy(greenColor.w, 1.0f, 0.01f);
}

- (void)testSpriteTextureCreation {
    id<MTLDevice> device = MTLCreateSystemDefaultDevice();
    if (!device) {
        XCTSkip(@"Metal not available on this system");
    }
    
    // Create a test image with known pixel dimensions using bitmap representation
    NSBitmapImageRep *bitmapRep = [[NSBitmapImageRep alloc]
        initWithBitmapDataPlanes:NULL
                      pixelsWide:32
                      pixelsHigh:32
                   bitsPerSample:8
                 samplesPerPixel:4
                        hasAlpha:YES
                        isPlanar:NO
                  colorSpaceName:NSCalibratedRGBColorSpace
                     bytesPerRow:0
                    bitsPerPixel:0];
    NSImage *image = [[NSImage alloc] initWithSize:NSMakeSize(32, 32)];
    [image addRepresentation:bitmapRep];
    
    SSKSprite *sprite = [SSKSprite spriteWithImage:image];
    
    // First texture request should create and cache texture
    id<MTLTexture> texture1 = [sprite textureForDevice:device];
    XCTAssertNotNil(texture1);
    XCTAssertEqual(texture1.width, 32);
    XCTAssertEqual(texture1.height, 32);
    
    // Second request should return cached texture
    id<MTLTexture> texture2 = [sprite textureForDevice:device];
    XCTAssertEqual(texture1, texture2, @"Should return cached texture");
}

- (void)testSpriteTextureInvalidation {
    id<MTLDevice> device = MTLCreateSystemDefaultDevice();
    if (!device) {
        XCTSkip(@"Metal not available on this system");
    }
    
    NSImage *image = [[NSImage alloc] initWithSize:NSMakeSize(32, 32)];
    [image lockFocus];
    [[NSColor redColor] setFill];
    NSRectFill(NSMakeRect(0, 0, 32, 32));
    [image unlockFocus];
    
    SSKSprite *sprite = [SSKSprite spriteWithImage:image];
    id<MTLTexture> texture1 = [sprite textureForDevice:device];
    XCTAssertNotNil(texture1);
    
    // Invalidate texture
    [sprite invalidateTexture];
    XCTAssertNil(sprite.cachedTexture);
    
    // New request should create new texture
    id<MTLTexture> texture2 = [sprite textureForDevice:device];
    XCTAssertNotNil(texture2);
    // Note: texture2 may or may not equal texture1 depending on Metal's allocation
}

- (void)testSpriteImageChangeInvalidatesTexture {
    id<MTLDevice> device = MTLCreateSystemDefaultDevice();
    if (!device) {
        XCTSkip(@"Metal not available on this system");
    }
    
    NSImage *image1 = [[NSImage alloc] initWithSize:NSMakeSize(32, 32)];
    [image1 lockFocus];
    [[NSColor redColor] setFill];
    NSRectFill(NSMakeRect(0, 0, 32, 32));
    [image1 unlockFocus];
    
    SSKSprite *sprite = [SSKSprite spriteWithImage:image1];
    id<MTLTexture> texture1 = [sprite textureForDevice:device];
    XCTAssertNotNil(texture1);
    
    // Change image - should invalidate texture
    NSImage *image2 = [[NSImage alloc] initWithSize:NSMakeSize(64, 64)];
    [image2 lockFocus];
    [[NSColor blueColor] setFill];
    NSRectFill(NSMakeRect(0, 0, 64, 64));
    [image2 unlockFocus];
    
    sprite.image = image2;
    XCTAssertNil(sprite.cachedTexture, @"Changing image should invalidate cached texture");
}

- (void)testSpriteNoTextureWithoutImage {
    id<MTLDevice> device = MTLCreateSystemDefaultDevice();
    if (!device) {
        XCTSkip(@"Metal not available on this system");
    }
    
    SSKSprite *sprite = [[SSKSprite alloc] init];
    XCTAssertNil(sprite.image);
    
    id<MTLTexture> texture = [sprite textureForDevice:device];
    XCTAssertNil(texture, @"Should return nil texture when no image is set");
}

#pragma mark - SSKMetalSpriteData Tests

- (void)testSpriteDataMake {
    SSKMetalSpriteData data = SSKMetalSpriteDataMake();
    
    XCTAssertEqual(data.position.x, 0.0f);
    XCTAssertEqual(data.position.y, 0.0f);
    XCTAssertEqual(data.size.x, 100.0f);
    XCTAssertEqual(data.size.y, 100.0f);
    // sinCos should be cos(0), sin(0) = (1, 0)
    XCTAssertEqual(data.sinCos.x, 1.0f);
    XCTAssertEqual(data.sinCos.y, 0.0f);
    // anchor should be center (0.5, 0.5)
    XCTAssertEqual(data.anchor.x, 0.5f);
    XCTAssertEqual(data.anchor.y, 0.5f);
    XCTAssertEqual(data.opacity, 1.0f);
    XCTAssertEqual(data.z, 0.0f);  // Z defaults to 0
    XCTAssertEqual(data.colorTint.x, 1.0f);
    XCTAssertEqual(data.colorTint.y, 1.0f);
    XCTAssertEqual(data.colorTint.z, 1.0f);
    XCTAssertEqual(data.colorTint.w, 1.0f);
    XCTAssertEqual(data.textureCoord.x, 0.0f);
    XCTAssertEqual(data.textureCoord.y, 0.0f);
    XCTAssertEqual(data.textureSize.x, 1.0f);
    XCTAssertEqual(data.textureSize.y, 1.0f);
    XCTAssertEqual(data.textureIndex, 0u);
}

- (void)testSpriteDataStructSize {
    // Verify struct size matches expected value (80 bytes)
    XCTAssertEqual(sizeof(SSKMetalSpriteData), 80);
}

- (void)testSpriteDataMakeWithRotation {
    float rotation = M_PI / 4.0f;  // 45 degrees
    SSKMetalSpriteData data = SSKMetalSpriteDataMakeWithRotation(rotation);
    
    XCTAssertEqualWithAccuracy(data.sinCos.x, cosf(rotation), 0.0001f);
    XCTAssertEqualWithAccuracy(data.sinCos.y, sinf(rotation), 0.0001f);
}

#pragma mark - SSKMetalSpritePass Tests

- (nullable id<MTLLibrary>)makeSpriteLibraryWithDevice:(id<MTLDevice>)device {
    return [SSKTestHelpers loadSpriteShaderLibraryWithDevice:device];
}

- (void)testSpritePassSetup {
    id<MTLDevice> device = MTLCreateSystemDefaultDevice();
    if (!device) {
        XCTSkip(@"Metal not available on this system");
    }
    
    id<MTLLibrary> library = [self makeSpriteLibraryWithDevice:device];
    if (!library) {
        XCTSkip(@"Failed to compile sprite Metal library for tests");
    }
    
    SSKMetalSpritePass *pass = [[SSKMetalSpritePass alloc] init];
    XCTAssertTrue([pass setupWithDevice:device library:library]);
    XCTAssertEqualObjects(pass.passName, @"SpritePass");
}

- (void)testSpritePassSetupFailsWithoutLibrary {
    id<MTLDevice> device = MTLCreateSystemDefaultDevice();
    if (!device) {
        XCTSkip(@"Metal not available on this system");
    }
    
    SSKMetalSpritePass *pass = [[SSKMetalSpritePass alloc] init];
    XCTAssertFalse([pass setupWithDevice:device library:nil]);
}

- (void)testSpritePassEncodesEmptyArray {
    id<MTLDevice> device = MTLCreateSystemDefaultDevice();
    if (!device) {
        XCTSkip(@"Metal not available on this system");
    }
    
    id<MTLLibrary> library = [self makeSpriteLibraryWithDevice:device];
    if (!library) {
        XCTSkip(@"Failed to compile sprite Metal library for tests");
    }
    
    SSKMetalSpritePass *pass = [[SSKMetalSpritePass alloc] init];
    XCTAssertTrue([pass setupWithDevice:device library:library]);
    
    id<MTLCommandQueue> queue = [device newCommandQueue];
    id<MTLCommandBuffer> commandBuffer = [queue commandBuffer];
    
    MTLTextureDescriptor *desc = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm width:32 height:32 mipmapped:NO];
    desc.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead;
    id<MTLTexture> target = [device newTextureWithDescriptor:desc];
    XCTAssertNotNil(target);
    
    // Empty sprite array should succeed (nothing to draw)
    BOOL encoded = [pass encodeSprites:@[]
                               texture:nil
                             blendMode:SSKParticleBlendModeAlpha
                          viewportSize:CGSizeMake(32, 32)
                         commandBuffer:commandBuffer
                          renderTarget:target
                            loadAction:MTLLoadActionClear
                            clearColor:MTLClearColorMake(0, 0, 0, 1)];
    XCTAssertTrue(encoded);
}

- (void)testSpritePassEncodesSpritesWithoutTexture {
    id<MTLDevice> device = MTLCreateSystemDefaultDevice();
    if (!device) {
        XCTSkip(@"Metal not available on this system");
    }
    
    id<MTLLibrary> library = [self makeSpriteLibraryWithDevice:device];
    if (!library) {
        XCTSkip(@"Failed to compile sprite Metal library for tests");
    }
    
    SSKMetalSpritePass *pass = [[SSKMetalSpritePass alloc] init];
    XCTAssertTrue([pass setupWithDevice:device library:library]);
    
    id<MTLCommandQueue> queue = [device newCommandQueue];
    id<MTLCommandBuffer> commandBuffer = [queue commandBuffer];
    
    MTLTextureDescriptor *desc = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm width:32 height:32 mipmapped:NO];
    desc.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead;
    id<MTLTexture> target = [device newTextureWithDescriptor:desc];
    XCTAssertNotNil(target);
    
    // Create sprites
    SSKSprite *sprite1 = [SSKSprite spriteWithPosition:NSMakePoint(16, 16) size:NSMakeSize(10, 10)];
    sprite1.colorTint = [NSColor redColor];
    
    SSKSprite *sprite2 = [SSKSprite spriteWithPosition:NSMakePoint(24, 24) size:NSMakeSize(8, 8)];
    sprite2.colorTint = [NSColor blueColor];
    
    // Encode without texture (solid color mode)
    BOOL encoded = [pass encodeSprites:@[sprite1, sprite2]
                               texture:nil
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

- (void)testSpritePassEncodesSpritesWithTexture {
    id<MTLDevice> device = MTLCreateSystemDefaultDevice();
    if (!device) {
        XCTSkip(@"Metal not available on this system");
    }
    
    id<MTLLibrary> library = [self makeSpriteLibraryWithDevice:device];
    if (!library) {
        XCTSkip(@"Failed to compile sprite Metal library for tests");
    }
    
    SSKMetalSpritePass *pass = [[SSKMetalSpritePass alloc] init];
    XCTAssertTrue([pass setupWithDevice:device library:library]);
    
    id<MTLCommandQueue> queue = [device newCommandQueue];
    id<MTLCommandBuffer> commandBuffer = [queue commandBuffer];
    
    MTLTextureDescriptor *desc = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm width:64 height:64 mipmapped:NO];
    desc.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead;
    id<MTLTexture> target = [device newTextureWithDescriptor:desc];
    XCTAssertNotNil(target);
    
    // Create a test texture
    NSImage *testImage = [[NSImage alloc] initWithSize:NSMakeSize(16, 16)];
    [testImage lockFocus];
    [[NSColor whiteColor] setFill];
    NSRectFill(NSMakeRect(0, 0, 16, 16));
    [testImage unlockFocus];
    
    SSKSprite *sprite = [SSKSprite spriteWithImage:testImage];
    sprite.position = NSMakePoint(32, 32);
    sprite.size = NSMakeSize(20, 20);
    sprite.colorTint = [NSColor greenColor];
    
    id<MTLTexture> spriteTexture = [sprite textureForDevice:device];
    XCTAssertNotNil(spriteTexture);
    
    BOOL encoded = [pass encodeSprites:@[sprite]
                               texture:spriteTexture
                             blendMode:SSKParticleBlendModeAlpha
                          viewportSize:CGSizeMake(64, 64)
                         commandBuffer:commandBuffer
                          renderTarget:target
                            loadAction:MTLLoadActionClear
                            clearColor:MTLClearColorMake(0, 0, 0, 1)];
    XCTAssertTrue(encoded);
    
    [commandBuffer commit];
    [commandBuffer waitUntilCompleted];
    XCTAssertEqual(commandBuffer.status, MTLCommandBufferStatusCompleted);
}

- (void)testSpritePassAdditiveBlendMode {
    id<MTLDevice> device = MTLCreateSystemDefaultDevice();
    if (!device) {
        XCTSkip(@"Metal not available on this system");
    }
    
    id<MTLLibrary> library = [self makeSpriteLibraryWithDevice:device];
    if (!library) {
        XCTSkip(@"Failed to compile sprite Metal library for tests");
    }
    
    SSKMetalSpritePass *pass = [[SSKMetalSpritePass alloc] init];
    XCTAssertTrue([pass setupWithDevice:device library:library]);
    
    id<MTLCommandQueue> queue = [device newCommandQueue];
    id<MTLCommandBuffer> commandBuffer = [queue commandBuffer];
    
    MTLTextureDescriptor *desc = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm width:32 height:32 mipmapped:NO];
    desc.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead;
    id<MTLTexture> target = [device newTextureWithDescriptor:desc];
    
    SSKSprite *sprite = [SSKSprite spriteWithPosition:NSMakePoint(16, 16) size:NSMakeSize(16, 16)];
    sprite.colorTint = [NSColor yellowColor];
    sprite.opacity = 0.5;
    
    // Test additive blend mode
    BOOL encoded = [pass encodeSprites:@[sprite]
                               texture:nil
                             blendMode:SSKParticleBlendModeAdditive
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

- (void)testSpritePassEncodesRawSpriteData {
    id<MTLDevice> device = MTLCreateSystemDefaultDevice();
    if (!device) {
        XCTSkip(@"Metal not available on this system");
    }
    
    id<MTLLibrary> library = [self makeSpriteLibraryWithDevice:device];
    if (!library) {
        XCTSkip(@"Failed to compile sprite Metal library for tests");
    }
    
    SSKMetalSpritePass *pass = [[SSKMetalSpritePass alloc] init];
    XCTAssertTrue([pass setupWithDevice:device library:library]);
    
    id<MTLCommandQueue> queue = [device newCommandQueue];
    id<MTLCommandBuffer> commandBuffer = [queue commandBuffer];
    
    MTLTextureDescriptor *desc = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm width:32 height:32 mipmapped:NO];
    desc.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead;
    id<MTLTexture> target = [device newTextureWithDescriptor:desc];
    
    // Create raw sprite data
    SSKMetalSpriteData data = SSKMetalSpriteDataMake();
    data.position = (vector_float2){16.0f, 16.0f};
    data.size = (vector_float2){12.0f, 12.0f};
    data.colorTint = (vector_float4){1.0f, 0.0f, 0.0f, 1.0f}; // Red
    
    BOOL encoded = [pass encodeSpriteData:&data
                                    count:1
                                  texture:nil
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

#pragma mark - Z-Sorting Tests

- (void)testSortedIndicesBasicOrdering {
    id<MTLDevice> device = MTLCreateSystemDefaultDevice();
    if (!device) {
        XCTSkip(@"Metal not available on this system");
    }
    
    id<MTLLibrary> library = [self makeSpriteLibraryWithDevice:device];
    if (!library) {
        XCTSkip(@"Failed to compile sprite Metal library for tests");
    }
    
    SSKMetalSpritePass *pass = [[SSKMetalSpritePass alloc] init];
    XCTAssertTrue([pass setupWithDevice:device library:library]);
    
    SSKSprite *a = [[SSKSprite alloc] init]; a.z = 5.0f;
    SSKSprite *b = [[SSKSprite alloc] init]; b.z = 1.0f;
    SSKSprite *c = [[SSKSprite alloc] init]; c.z = 10.0f;
    NSArray *sprites = @[a, b, c];
    
    NSUInteger count = 0;
    const NSUInteger *indices = [pass sortedIndicesForSprites:sprites count:&count];
    
    XCTAssertEqual(count, 3);
    XCTAssertNotEqual(indices, (const NSUInteger *)NULL);
    // Should be sorted ascending: b(1), a(5), c(10)
    // Original indices: a=0, b=1, c=2
    // Sorted order: b(idx 1), a(idx 0), c(idx 2)
    XCTAssertEqual(indices[0], 1);  // b first (z=1)
    XCTAssertEqual(indices[1], 0);  // a second (z=5)
    XCTAssertEqual(indices[2], 2);  // c last (z=10)
}

- (void)testSortedIndicesStableForEqualZ {
    id<MTLDevice> device = MTLCreateSystemDefaultDevice();
    if (!device) {
        XCTSkip(@"Metal not available on this system");
    }
    
    id<MTLLibrary> library = [self makeSpriteLibraryWithDevice:device];
    if (!library) {
        XCTSkip(@"Failed to compile sprite Metal library for tests");
    }
    
    SSKMetalSpritePass *pass = [[SSKMetalSpritePass alloc] init];
    XCTAssertTrue([pass setupWithDevice:device library:library]);
    
    // Mixed case: some equal, some different
    SSKSprite *a = [[SSKSprite alloc] init]; a.z = 5.0f;
    SSKSprite *b = [[SSKSprite alloc] init]; b.z = 5.0f;
    SSKSprite *c = [[SSKSprite alloc] init]; c.z = 1.0f;
    SSKSprite *d = [[SSKSprite alloc] init]; d.z = 5.0f;
    NSArray *sprites = @[a, b, c, d];
    
    NSUInteger count = 0;
    const NSUInteger *indices = [pass sortedIndicesForSprites:sprites count:&count];
    
    XCTAssertEqual(count, 4);
    XCTAssertNotEqual(indices, (const NSUInteger *)NULL);
    // c(1) comes first, then a,b,d in original order (all z=5)
    XCTAssertEqual(indices[0], 2);  // c (z=1)
    XCTAssertEqual(indices[1], 0);  // a (z=5, original first)
    XCTAssertEqual(indices[2], 1);  // b (z=5, original second)
    XCTAssertEqual(indices[3], 3);  // d (z=5, original third)
}

- (void)testSortedIndicesHandlesNonFinite {
    id<MTLDevice> device = MTLCreateSystemDefaultDevice();
    if (!device) {
        XCTSkip(@"Metal not available on this system");
    }
    
    id<MTLLibrary> library = [self makeSpriteLibraryWithDevice:device];
    if (!library) {
        XCTSkip(@"Failed to compile sprite Metal library for tests");
    }
    
    SSKMetalSpritePass *pass = [[SSKMetalSpritePass alloc] init];
    XCTAssertTrue([pass setupWithDevice:device library:library]);
    
    SSKSprite *a = [[SSKSprite alloc] init]; a.z = 5.0f;
    SSKSprite *b = [[SSKSprite alloc] init]; b.z = NAN;
    SSKSprite *c = [[SSKSprite alloc] init]; c.z = -1.0f;
    SSKSprite *d = [[SSKSprite alloc] init]; d.z = INFINITY;
    NSArray *sprites = @[a, b, c, d];
    
    NSUInteger count = 0;
    const NSUInteger *indices = [pass sortedIndicesForSprites:sprites count:&count];
    
    XCTAssertEqual(count, 4);
    XCTAssertNotEqual(indices, (const NSUInteger *)NULL);
    // Non-finite treated as 0: order is c(-1), b(0/NaN), d(0/inf), a(5)
    // b and d both become 0, tie-break by original index: b(1) before d(3)
    XCTAssertEqual(indices[0], 2);  // c (z=-1)
    XCTAssertEqual(indices[1], 1);  // b (z=NaN -> 0)
    XCTAssertEqual(indices[2], 3);  // d (z=inf -> 0)
    XCTAssertEqual(indices[3], 0);  // a (z=5)
}

- (void)testSortedIndicesEmptyArray {
    id<MTLDevice> device = MTLCreateSystemDefaultDevice();
    if (!device) {
        XCTSkip(@"Metal not available on this system");
    }
    
    id<MTLLibrary> library = [self makeSpriteLibraryWithDevice:device];
    if (!library) {
        XCTSkip(@"Failed to compile sprite Metal library for tests");
    }
    
    SSKMetalSpritePass *pass = [[SSKMetalSpritePass alloc] init];
    XCTAssertTrue([pass setupWithDevice:device library:library]);
    
    NSUInteger count = 99;
    const NSUInteger *indices = [pass sortedIndicesForSprites:@[] count:&count];
    
    XCTAssertEqual(count, 0);
    XCTAssertEqual(indices, (const NSUInteger *)NULL);
}

- (void)testSpritePassEncodesSortedSprites {
    id<MTLDevice> device = MTLCreateSystemDefaultDevice();
    if (!device) {
        XCTSkip(@"Metal not available on this system");
    }
    
    id<MTLLibrary> library = [self makeSpriteLibraryWithDevice:device];
    if (!library) {
        XCTSkip(@"Failed to compile sprite Metal library for tests");
    }
    
    SSKMetalSpritePass *pass = [[SSKMetalSpritePass alloc] init];
    XCTAssertTrue([pass setupWithDevice:device library:library]);
    
    id<MTLCommandQueue> queue = [device newCommandQueue];
    id<MTLCommandBuffer> commandBuffer = [queue commandBuffer];
    
    MTLTextureDescriptor *desc = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm width:64 height:64 mipmapped:NO];
    desc.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead;
    id<MTLTexture> target = [device newTextureWithDescriptor:desc];
    XCTAssertNotNil(target);
    
    // Create sprites with different z values
    SSKSprite *sprite1 = [SSKSprite spriteWithPosition:NSMakePoint(16, 16) size:NSMakeSize(10, 10)];
    sprite1.z = 10.0f;
    sprite1.colorTint = [NSColor redColor];
    
    SSKSprite *sprite2 = [SSKSprite spriteWithPosition:NSMakePoint(32, 32) size:NSMakeSize(10, 10)];
    sprite2.z = 1.0f;
    sprite2.colorTint = [NSColor blueColor];
    
    SSKSprite *sprite3 = [SSKSprite spriteWithPosition:NSMakePoint(48, 48) size:NSMakeSize(10, 10)];
    sprite3.z = 5.0f;
    sprite3.colorTint = [NSColor greenColor];
    
    // Encode with sorting enabled
    BOOL encoded = [pass encodeSprites:@[sprite1, sprite2, sprite3]
                               texture:nil
                             blendMode:SSKParticleBlendModeAlpha
                          viewportSize:CGSizeMake(64, 64)
                         commandBuffer:commandBuffer
                          renderTarget:target
                            loadAction:MTLLoadActionClear
                            clearColor:MTLClearColorMake(0, 0, 0, 1)
                               sortByZ:YES];
    XCTAssertTrue(encoded);
    
    [commandBuffer commit];
    [commandBuffer waitUntilCompleted];
    XCTAssertEqual(commandBuffer.status, MTLCommandBufferStatusCompleted);
}

#pragma mark - Scale and Flip Tests

- (void)testSpriteScaleProperty {
    SSKSprite *sprite = [[SSKSprite alloc] init];
    
    sprite.scale = CGSizeMake(2.0, 0.5);
    XCTAssertEqual(sprite.scale.width, 2.0);
    XCTAssertEqual(sprite.scale.height, 0.5);
    
    // Negative scale should work
    sprite.scale = CGSizeMake(-1.0, -2.0);
    XCTAssertEqual(sprite.scale.width, -1.0);
    XCTAssertEqual(sprite.scale.height, -2.0);
}

- (void)testSpriteFlipXProperty {
    SSKSprite *sprite = [[SSKSprite alloc] init];
    XCTAssertEqual(sprite.flipX, NO);
    
    sprite.flipX = YES;
    XCTAssertEqual(sprite.flipX, YES);
    XCTAssertLessThan(sprite.scale.width, 0);  // Scale should be negative
    
    sprite.flipX = NO;
    XCTAssertEqual(sprite.flipX, NO);
    XCTAssertGreaterThan(sprite.scale.width, 0);  // Scale should be positive
}

- (void)testSpriteFlipYProperty {
    SSKSprite *sprite = [[SSKSprite alloc] init];
    XCTAssertEqual(sprite.flipY, NO);
    
    sprite.flipY = YES;
    XCTAssertEqual(sprite.flipY, YES);
    XCTAssertLessThan(sprite.scale.height, 0);
    
    sprite.flipY = NO;
    XCTAssertEqual(sprite.flipY, NO);
    XCTAssertGreaterThan(sprite.scale.height, 0);
}

- (void)testFlipPreservesZeroScale {
    SSKSprite *sprite = [[SSKSprite alloc] init];
    
    // Set scale to zero (hidden sprite)
    sprite.scale = CGSizeMake(0, 0);
    
    // Flip should not change zero scale
    sprite.flipX = YES;
    XCTAssertEqual(sprite.scale.width, 0);  // Should stay 0, not become -1 or 1
    
    sprite.flipY = YES;
    XCTAssertEqual(sprite.scale.height, 0);
}

- (void)testFlipPreservesScaleMagnitude {
    SSKSprite *sprite = [[SSKSprite alloc] init];
    sprite.scale = CGSizeMake(2.0, 3.0);
    
    sprite.flipX = YES;
    XCTAssertEqual(sprite.scale.width, -2.0);
    
    sprite.flipY = YES;
    XCTAssertEqual(sprite.scale.height, -3.0);
    
    sprite.flipX = NO;
    XCTAssertEqual(sprite.scale.width, 2.0);
}

#pragma mark - Culling Tests

- (void)testSpriteCullingCenterAnchor {
    id<MTLDevice> device = MTLCreateSystemDefaultDevice();
    if (!device) {
        XCTSkip(@"Metal not available on this system");
    }
    
    id<MTLLibrary> library = [self makeSpriteLibraryWithDevice:device];
    if (!library) {
        XCTSkip(@"Failed to compile sprite Metal library for tests");
    }
    
    SSKMetalSpritePass *pass = [[SSKMetalSpritePass alloc] init];
    XCTAssertTrue([pass setupWithDevice:device library:library]);
    
    CGSize viewport = CGSizeMake(200, 200);
    
    // Sprite fully inside viewport
    SSKSprite *visible = [[SSKSprite alloc] init];
    visible.position = NSMakePoint(100, 100);
    visible.size = NSMakeSize(50, 50);
    visible.scale = CGSizeMake(1, 1);
    visible.anchor = NSMakePoint(0.5, 0.5);
    XCTAssertTrue([pass isSpriteVisible:visible viewportPixels:viewport]);
    
    // Sprite far outside viewport
    SSKSprite *offscreen = [[SSKSprite alloc] init];
    offscreen.position = NSMakePoint(-1000, -1000);
    offscreen.size = NSMakeSize(50, 50);
    offscreen.scale = CGSizeMake(1, 1);
    offscreen.anchor = NSMakePoint(0.5, 0.5);
    XCTAssertFalse([pass isSpriteVisible:offscreen viewportPixels:viewport]);
}

- (void)testSpriteCullingPartiallyVisible {
    id<MTLDevice> device = MTLCreateSystemDefaultDevice();
    if (!device) {
        XCTSkip(@"Metal not available on this system");
    }
    
    id<MTLLibrary> library = [self makeSpriteLibraryWithDevice:device];
    if (!library) {
        XCTSkip(@"Failed to compile sprite Metal library for tests");
    }
    
    SSKMetalSpritePass *pass = [[SSKMetalSpritePass alloc] init];
    XCTAssertTrue([pass setupWithDevice:device library:library]);
    
    CGSize viewport = CGSizeMake(200, 200);
    
    // Sprite at edge, should still be visible
    SSKSprite *edge = [[SSKSprite alloc] init];
    edge.position = NSMakePoint(0, 0);
    edge.size = NSMakeSize(50, 50);
    edge.scale = CGSizeMake(1, 1);
    edge.anchor = NSMakePoint(0.5, 0.5);
    XCTAssertTrue([pass isSpriteVisible:edge viewportPixels:viewport]);
}

- (void)testCullingEnabledProperty {
    id<MTLDevice> device = MTLCreateSystemDefaultDevice();
    if (!device) {
        XCTSkip(@"Metal not available on this system");
    }
    
    id<MTLLibrary> library = [self makeSpriteLibraryWithDevice:device];
    if (!library) {
        XCTSkip(@"Failed to compile sprite Metal library for tests");
    }
    
    SSKMetalSpritePass *pass = [[SSKMetalSpritePass alloc] init];
    XCTAssertTrue([pass setupWithDevice:device library:library]);
    
    XCTAssertFalse(pass.cullingEnabled);  // Default is NO
    
    pass.cullingEnabled = YES;
    XCTAssertTrue(pass.cullingEnabled);
}

#pragma mark - Animation Sequence Tests

- (void)testAnimationSequenceFromGrid {
    SSKSpriteAnimationSequence *seq = [SSKSpriteAnimationSequence sequenceWithGridColumns:4
                                                                                      rows:2
                                                                                frameCount:8
                                                                                  duration:0.1
                                                                                  loopMode:SSKAnimationLoopModeLoop];
    XCTAssertNotNil(seq);
    XCTAssertEqual(seq.frameCount, 8);
    XCTAssertEqual(seq.loopMode, SSKAnimationLoopModeLoop);
    XCTAssertEqualWithAccuracy(seq.defaultFrameDuration, 0.1, 0.001);
    XCTAssertEqualWithAccuracy(seq.totalDuration, 0.8, 0.001);
    
    // Check first frame
    SSKAnimationFrame frame0 = [seq frameAtIndex:0];
    XCTAssertEqualWithAccuracy(frame0.textureOffset.x, 0.0, 0.001);
    XCTAssertEqualWithAccuracy(frame0.textureOffset.y, 0.0, 0.001);
    XCTAssertEqualWithAccuracy(frame0.textureSize.width, 0.25, 0.001);
    XCTAssertEqualWithAccuracy(frame0.textureSize.height, 0.5, 0.001);
    
    // Check second row first frame
    SSKAnimationFrame frame4 = [seq frameAtIndex:4];
    XCTAssertEqualWithAccuracy(frame4.textureOffset.x, 0.0, 0.001);
    XCTAssertEqualWithAccuracy(frame4.textureOffset.y, 0.5, 0.001);
}

- (void)testAnimationSequenceLoopMode {
    SSKSpriteAnimationSequence *seq = [SSKSpriteAnimationSequence sequenceWithGridColumns:4
                                                                                      rows:1
                                                                                frameCount:4
                                                                                  duration:0.25
                                                                                  loopMode:SSKAnimationLoopModeLoop];
    XCTAssertNotNil(seq);
    
    // At t=0, should be frame 0
    BOOL finished = NO;
    NSUInteger idx = [seq frameIndexForTime:0 finished:&finished];
    XCTAssertEqual(idx, 0);
    XCTAssertFalse(finished);
    
    // At t=0.5, should be frame 2
    idx = [seq frameIndexForTime:0.5 finished:&finished];
    XCTAssertEqual(idx, 2);
    
    // At t=1.0 (full cycle), should wrap to frame 0
    idx = [seq frameIndexForTime:1.0 finished:&finished];
    XCTAssertEqual(idx, 0);
}

- (void)testAnimationSequenceOnceMode {
    SSKSpriteAnimationSequence *seq = [SSKSpriteAnimationSequence sequenceWithGridColumns:4
                                                                                      rows:1
                                                                                frameCount:4
                                                                                  duration:0.25
                                                                                  loopMode:SSKAnimationLoopModeOnce];
    XCTAssertNotNil(seq);
    
    // At t=2.0 (past end), should clamp to last frame
    BOOL finished = NO;
    NSUInteger idx = [seq frameIndexForTime:2.0 finished:&finished];
    XCTAssertEqual(idx, 3);
    XCTAssertTrue(finished);
}

- (void)testAnimationSequencePingPongN2 {
    // For N=2, ping-pong should be same as loop: 0,1,0,1...
    SSKSpriteAnimationSequence *seq = [SSKSpriteAnimationSequence sequenceWithGridColumns:2
                                                                                      rows:1
                                                                                frameCount:2
                                                                                  duration:0.5
                                                                                  loopMode:SSKAnimationLoopModePingPong];
    XCTAssertNotNil(seq);
    XCTAssertEqual(seq.frameCount, 2);
    XCTAssertEqualWithAccuracy(seq.totalDuration, 1.0, 0.001);  // 2 frames * 0.5s = 1s
    
    // t=0 -> frame 0
    NSUInteger idx = [seq frameIndexForTime:0 finished:nil];
    XCTAssertEqual(idx, 0);
    
    // t=0.5 -> frame 1
    idx = [seq frameIndexForTime:0.5 finished:nil];
    XCTAssertEqual(idx, 1);
    
    // t=1.0 -> wraps to frame 0
    idx = [seq frameIndexForTime:1.0 finished:nil];
    XCTAssertEqual(idx, 0);
}

- (void)testAnimationSequencePingPongN3 {
    // For N=3, ping-pong visits: 0,1,2,1,0,1,2,1...
    SSKSpriteAnimationSequence *seq = [SSKSpriteAnimationSequence sequenceWithGridColumns:3
                                                                                      rows:1
                                                                                frameCount:3
                                                                                  duration:0.25
                                                                                  loopMode:SSKAnimationLoopModePingPong];
    XCTAssertNotNil(seq);
    XCTAssertEqual(seq.frameCount, 3);
    // periodFrames = 2*3 - 2 = 4; totalDuration = 4 * 0.25 = 1.0
    XCTAssertEqualWithAccuracy(seq.totalDuration, 1.0, 0.001);
    
    // t=0.0 -> frame 0
    NSUInteger idx = [seq frameIndexForTime:0 finished:nil];
    XCTAssertEqual(idx, 0);
    
    // t=0.25 -> frame 1
    idx = [seq frameIndexForTime:0.25 finished:nil];
    XCTAssertEqual(idx, 1);
    
    // t=0.5 -> frame 2
    idx = [seq frameIndexForTime:0.5 finished:nil];
    XCTAssertEqual(idx, 2);
    
    // t=0.75 -> frame 1 (backward)
    idx = [seq frameIndexForTime:0.75 finished:nil];
    XCTAssertEqual(idx, 1);
}

- (void)testAnimationSequenceNegativeTime {
    SSKSpriteAnimationSequence *seq = [SSKSpriteAnimationSequence sequenceWithGridColumns:4
                                                                                      rows:1
                                                                                frameCount:4
                                                                                  duration:0.25
                                                                                  loopMode:SSKAnimationLoopModeLoop];
    
    // Negative time should wrap correctly
    NSUInteger idx = [seq frameIndexForTime:-0.25 finished:nil];
    XCTAssertEqual(idx, 3);  // Should wrap to last frame
}

#pragma mark - Sprite Animation State Tests

- (void)testSpriteAnimationState {
    SSKSpriteAnimationSequence *seq = [SSKSpriteAnimationSequence sequenceWithGridColumns:4
                                                                                      rows:1
                                                                                frameCount:4
                                                                                  duration:0.25
                                                                                  loopMode:SSKAnimationLoopModeLoop];
    
    SSKSprite *sprite = [[SSKSprite alloc] init];
    XCTAssertNil(sprite.animation);
    XCTAssertFalse(sprite.animationPlaying);
    
    // Setting animation should start playing
    sprite.animation = seq;
    XCTAssertNotNil(sprite.animation);
    XCTAssertTrue(sprite.animationPlaying);
    XCTAssertEqual(sprite.animationTime, 0);
    XCTAssertEqual(sprite.animationRate, 1.0);
    
    // Texture should be set to first frame
    XCTAssertEqualWithAccuracy(sprite.textureOffset.x, 0.0, 0.001);
    XCTAssertEqualWithAccuracy(sprite.textureSize.width, 0.25, 0.001);
}

- (void)testSpriteAdvanceAnimation {
    SSKSpriteAnimationSequence *seq = [SSKSpriteAnimationSequence sequenceWithGridColumns:4
                                                                                      rows:1
                                                                                frameCount:4
                                                                                  duration:0.25
                                                                                  loopMode:SSKAnimationLoopModeLoop];
    
    SSKSprite *sprite = [[SSKSprite alloc] init];
    sprite.animation = seq;
    
    // Advance by 0.25s should move to frame 1
    [sprite advanceAnimationByTime:0.25];
    XCTAssertEqualWithAccuracy(sprite.animationTime, 0.25, 0.001);
    XCTAssertEqualWithAccuracy(sprite.textureOffset.x, 0.25, 0.001);
}

- (void)testSpriteAnimationNegativeRate {
    SSKSpriteAnimationSequence *seq = [SSKSpriteAnimationSequence sequenceWithGridColumns:4
                                                                                      rows:1
                                                                                frameCount:4
                                                                                  duration:0.25
                                                                                  loopMode:SSKAnimationLoopModeLoop];
    
    SSKSprite *sprite = [[SSKSprite alloc] init];
    sprite.animation = seq;
    sprite.animationRate = -1.0;
    
    // Advance with negative rate should go backward
    [sprite advanceAnimationByTime:0.25];
    XCTAssertEqualWithAccuracy(sprite.animationTime, -0.25, 0.001);
    // Should wrap to last frame
    XCTAssertEqualWithAccuracy(sprite.textureOffset.x, 0.75, 0.001);
}

- (void)testSpriteAnimationReset {
    SSKSpriteAnimationSequence *seq = [SSKSpriteAnimationSequence sequenceWithGridColumns:4
                                                                                      rows:1
                                                                                frameCount:4
                                                                                  duration:0.25
                                                                                  loopMode:SSKAnimationLoopModeLoop];
    
    SSKSprite *sprite = [[SSKSprite alloc] init];
    sprite.animation = seq;
    [sprite advanceAnimationByTime:0.5];
    
    [sprite resetAnimation];
    XCTAssertEqual(sprite.animationTime, 0);
    XCTAssertTrue(sprite.animationPlaying);
    XCTAssertEqualWithAccuracy(sprite.textureOffset.x, 0.0, 0.001);
}

- (void)testSpriteAnimationOnceStopsAtEnd {
    SSKSpriteAnimationSequence *seq = [SSKSpriteAnimationSequence sequenceWithGridColumns:4
                                                                                      rows:1
                                                                                frameCount:4
                                                                                  duration:0.25
                                                                                  loopMode:SSKAnimationLoopModeOnce];
    
    SSKSprite *sprite = [[SSKSprite alloc] init];
    sprite.animation = seq;
    XCTAssertTrue(sprite.animationPlaying);
    
    // Advance past end
    [sprite advanceAnimationByTime:2.0];
    XCTAssertFalse(sprite.animationPlaying);  // Should stop
    XCTAssertEqualWithAccuracy(sprite.textureOffset.x, 0.75, 0.001);  // Last frame
}

#pragma mark - Texture Rect Helper Tests

- (void)testSetTextureRectInPixelsNormalCase {
    SSKSprite *sprite = [[SSKSprite alloc] init];
    
    // Set a texture rect in a 256x256 texture
    CGRect rect = CGRectMake(64, 128, 64, 64);
    CGSize texSize = CGSizeMake(256, 256);
    
    [sprite setTextureRectInPixels:rect textureSize:texSize];
    
    XCTAssertEqualWithAccuracy(sprite.textureOffset.x, 0.25, 0.001);  // 64/256
    XCTAssertEqualWithAccuracy(sprite.textureOffset.y, 0.5, 0.001);   // 128/256
    XCTAssertEqualWithAccuracy(sprite.textureSize.width, 0.25, 0.001);  // 64/256
    XCTAssertEqualWithAccuracy(sprite.textureSize.height, 0.25, 0.001); // 64/256
}

- (void)testSetTextureRectInPixelsZeroSizeFallback {
    SSKSprite *sprite = [[SSKSprite alloc] init];
    
    // Set initial values
    sprite.textureOffset = NSMakePoint(0.5, 0.5);
    sprite.textureSize = NSMakeSize(0.25, 0.25);
    
    // Zero texture size should fall back to full texture (0,0)-(1,1)
    // In release builds, this will just set to defaults
    // In debug builds, an assertion would fire (but we can't test that here)
    CGRect rect = CGRectMake(64, 64, 32, 32);
    CGSize zeroSize = CGSizeMake(0, 0);
    
    [sprite setTextureRectInPixels:rect textureSize:zeroSize];
    
    // Should fall back to full texture
    XCTAssertEqual(sprite.textureOffset.x, 0.0);
    XCTAssertEqual(sprite.textureOffset.y, 0.0);
    XCTAssertEqual(sprite.textureSize.width, 1.0);
    XCTAssertEqual(sprite.textureSize.height, 1.0);
}

- (void)testSetTextureRectInPixelsNegativeSizeFallback {
    SSKSprite *sprite = [[SSKSprite alloc] init];
    
    // Negative texture size should also fall back
    CGRect rect = CGRectMake(64, 64, 32, 32);
    CGSize negativeSize = CGSizeMake(-256, 256);
    
    [sprite setTextureRectInPixels:rect textureSize:negativeSize];
    
    // Should fall back to full texture
    XCTAssertEqual(sprite.textureOffset.x, 0.0);
    XCTAssertEqual(sprite.textureOffset.y, 0.0);
    XCTAssertEqual(sprite.textureSize.width, 1.0);
    XCTAssertEqual(sprite.textureSize.height, 1.0);
}

- (void)testSetTextureRectInPixelsBottomLeftNormalCase {
    SSKSprite *sprite = [[SSKSprite alloc] init];
    
    // Set a texture rect with bottom-left origin
    CGRect rect = CGRectMake(0, 0, 128, 128);  // Bottom-left quadrant
    CGSize texSize = CGSizeMake(256, 256);
    
    [sprite setTextureRectInPixelsBottomLeft:rect textureSize:texSize];
    
    // Bottom-left origin: Y is flipped
    XCTAssertEqualWithAccuracy(sprite.textureOffset.x, 0.0, 0.001);   // 0/256
    XCTAssertEqualWithAccuracy(sprite.textureOffset.y, 0.5, 0.001);   // (256 - 128) / 256
    XCTAssertEqualWithAccuracy(sprite.textureSize.width, 0.5, 0.001);  // 128/256
    XCTAssertEqualWithAccuracy(sprite.textureSize.height, 0.5, 0.001); // 128/256
}

- (void)testSetTextureRectInPixelsBottomLeftZeroSizeFallback {
    SSKSprite *sprite = [[SSKSprite alloc] init];
    
    CGRect rect = CGRectMake(0, 0, 128, 128);
    CGSize zeroSize = CGSizeMake(256, 0);  // Zero height
    
    [sprite setTextureRectInPixelsBottomLeft:rect textureSize:zeroSize];
    
    // Should fall back to full texture
    XCTAssertEqual(sprite.textureOffset.x, 0.0);
    XCTAssertEqual(sprite.textureOffset.y, 0.0);
    XCTAssertEqual(sprite.textureSize.width, 1.0);
    XCTAssertEqual(sprite.textureSize.height, 1.0);
}

@end
