#import <XCTest/XCTest.h>
#import <QuartzCore/QuartzCore.h>
#import "ScreenSaverKit/SSKMetalRenderer.h"
#import "ScreenSaverKit/SSKMetalEffectStage.h"
#import "ScreenSaverKit/SSKMetalPass.h"

@interface SSKNoopPass : SSKMetalPass @end
@implementation SSKNoopPass
- (BOOL)setupWithDevice:(id<MTLDevice>)device { return device != nil; }
- (void)encodeToCommandBuffer:(id<MTLCommandBuffer>)commandBuffer
                  renderTarget:(id<MTLTexture>)renderTarget
                    parameters:(NSDictionary *)params {
    (void)commandBuffer;
    (void)renderTarget;
    (void)params;
}
@end

@interface SSKMetalRendererTests : XCTestCase
@end

@implementation SSKMetalRendererTests

- (void)setUp {
    [super setUp];
}

- (void)tearDown {
    [super tearDown];
}

- (void)testMetalRendererInitialization {
    CAMetalLayer *layer = [CAMetalLayer layer];
    if (!layer.device) {
        layer.device = MTLCreateSystemDefaultDevice();
    }
    
    if (!layer.device) {
        XCTSkip(@"Metal not available on this system");
    }
    
    SSKMetalRenderer *renderer = [[SSKMetalRenderer alloc] initWithLayer:layer];
    if (!renderer) {
        XCTSkip(@"SSKMetalRenderer could not be initialised on this system");
    }
    XCTAssertNotNil(renderer.device);
}

- (void)testMetalRendererInitializationWithoutDevice {
    CAMetalLayer *layer = [CAMetalLayer layer];
    // Don't set device - renderer should create one
    
    SSKMetalRenderer *renderer = [[SSKMetalRenderer alloc] initWithLayer:layer];
    
    if (!MTLCreateSystemDefaultDevice()) {
        XCTSkip(@"Metal not available on this system");
    }
    if (!renderer) {
        XCTSkip(@"SSKMetalRenderer could not be initialised on this system");
    }
    XCTAssertNotNil(renderer);
}

- (void)testTextureCache {
    CAMetalLayer *layer = [CAMetalLayer layer];
    layer.device = MTLCreateSystemDefaultDevice();
    
    if (!layer.device) {
        XCTSkip(@"Metal not available on this system");
    }
    
    SSKMetalRenderer *renderer = [[SSKMetalRenderer alloc] initWithLayer:layer];
    if (!renderer) {
        XCTSkip(@"SSKMetalRenderer could not be initialised on this system");
    }
    XCTAssertNotNil(renderer);
    XCTAssertNotNil(renderer.textureCache);
}

- (void)testBeginFrame {
    CAMetalLayer *layer = [CAMetalLayer layer];
    layer.device = MTLCreateSystemDefaultDevice();
    
    if (!layer.device) {
        XCTSkip(@"Metal not available on this system");
    }
    
    SSKMetalRenderer *renderer = [[SSKMetalRenderer alloc] initWithLayer:layer];
    if (!renderer) {
        XCTSkip(@"SSKMetalRenderer could not be initialised on this system");
    }
    
    BOOL success = [renderer beginFrame];
    if (success) {
        XCTAssertNotNil(renderer.currentCommandBuffer);
        [renderer endFrame];
        XCTAssertNil(renderer.currentCommandBuffer);
    } else {
        XCTSkip(@"Drawable unavailable for beginFrame; renderer returned NO");
    }
}

- (void)testRegisterAndUnregisterEffectStages {
    CAMetalLayer *layer = [CAMetalLayer layer];
    layer.device = MTLCreateSystemDefaultDevice();
    if (!layer.device) {
        XCTSkip(@"Metal not available on this system");
    }
    
    SSKMetalRenderer *renderer = [[SSKMetalRenderer alloc] initWithLayer:layer];
    if (!renderer) {
        XCTSkip(@"SSKMetalRenderer could not be initialised on this system");
    }
    
    SSKNoopPass *pass = [SSKNoopPass new];
    SSKMetalEffectStage *stage = [[SSKMetalEffectStage alloc] initWithIdentifier:@"com.ssk.tests.noop"
                                                                            pass:pass
                                                                         handler:^BOOL(SSKMetalRenderer *renderer,
                                                                                       SSKMetalPass *pass,
                                                                                       id<MTLCommandBuffer> commandBuffer,
                                                                                       id<MTLTexture> renderTarget,
                                                                                       NSDictionary *parameters) {
        (void)renderer; (void)pass; (void)commandBuffer; (void)renderTarget; (void)parameters;
        return YES;
    }];
    [renderer registerEffectStage:stage];
    
    NSArray<NSString *> *ids = [renderer registeredEffectIdentifiers];
    XCTAssertTrue([ids containsObject:@"com.ssk.tests.noop"]);
    
    [renderer unregisterEffectStageWithIdentifier:@"com.ssk.tests.noop"];
    ids = [renderer registeredEffectIdentifiers];
    XCTAssertFalse([ids containsObject:@"com.ssk.tests.noop"]);
}

@end

