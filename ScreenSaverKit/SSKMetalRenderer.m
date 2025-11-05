#import "SSKMetalRenderer.h"

#import "SSKMetalTextureCache.h"
#import "SSKParticleSystem.h"
#import "SSKDiagnostics.h"
#import "SSKMetalParticlePass.h"
#import "SSKMetalBlurPass.h"
#import "SSKMetalBloomPass.h"

@interface SSKMetalRenderer ()
@property (nonatomic, weak) CAMetalLayer *layer;
@property (nonatomic, strong, readwrite) id<MTLDevice> device;
@property (nonatomic, strong) id<MTLCommandQueue> commandQueue;
@property (nonatomic, strong, readwrite, nullable) id<MTLCommandBuffer> currentCommandBuffer;
@property (nonatomic, strong, nullable) id<CAMetalDrawable> currentDrawable;
@property (nonatomic, strong) id<MTLTexture> overrideRenderTarget;
@property (nonatomic, strong, readwrite) SSKMetalTextureCache *textureCache;
@property (nonatomic, readwrite) CGSize drawableSize;
@property (nonatomic, strong) id<MTLLibrary> shaderLibrary;
@property (nonatomic, strong) SSKMetalParticlePass *particlePass;
@property (nonatomic, strong, nullable) SSKMetalBlurPass *blurPass;
@property (nonatomic, strong, nullable) SSKMetalBloomPass *bloomPass;
@property (nonatomic) BOOL needsClearOnNextPass;
@end

@implementation SSKMetalRenderer

- (instancetype)initWithLayer:(CAMetalLayer *)layer {
    NSParameterAssert(layer);
    if ((self = [super init])) {
        _layer = layer;
        id<MTLDevice> device = layer.device ?: MTLCreateSystemDefaultDevice();
        if (!device) {
            [SSKDiagnostics log:@"SSKMetalRenderer: no Metal device available during initialisation."];
            return nil;
        }
        _device = device;
        if (!layer.device) {
            layer.device = device;
        }
        layer.pixelFormat = MTLPixelFormatBGRA8Unorm;
        layer.framebufferOnly = NO;
        _commandQueue = [device newCommandQueue];
        if (!_commandQueue) {
            [SSKDiagnostics log:@"SSKMetalRenderer: failed to create command queue."];
            return nil;
        }
        _clearColor = MTLClearColorMake(0.0, 0.0, 0.0, 1.0);
        _textureCache = [[SSKMetalTextureCache alloc] initWithDevice:device];

        _shaderLibrary = [self loadDefaultLibraryWithDevice:device];
        if (!_shaderLibrary) {
            [SSKDiagnostics log:@"SSKMetalRenderer: failed to load shader library (SSKParticleShaders.metallib)."];
            return nil;
        }

        _particlePass = [SSKMetalParticlePass new];
        if (![_particlePass setupWithDevice:device library:_shaderLibrary]) {
            [SSKDiagnostics log:@"SSKMetalRenderer: failed to set up particle pass."];
            return nil;
        }
        _blurPass = [[SSKMetalBlurPass alloc] init];
        if (![_blurPass setupWithDevice:device library:_shaderLibrary]) {
            if ([SSKDiagnostics isEnabled]) {
                [SSKDiagnostics log:@"SSKMetalRenderer: blur pass unavailable (continuing without blur support)."];
            }
            _blurPass = nil;
        }
        _bloomPass = [[SSKMetalBloomPass alloc] init];
        if (![_bloomPass setupWithDevice:device library:_shaderLibrary]) {
            if ([SSKDiagnostics isEnabled]) {
                [SSKDiagnostics log:@"SSKMetalRenderer: bloom pass unavailable (continuing without bloom support)."];
            }
            _bloomPass = nil;
        }
        _particleBlurRadius = 0.0;
        _bloomThreshold = 0.8f;
        _bloomBlurSigma = 3.0f;
        _needsClearOnNextPass = YES;
    }
    return self;
}

- (BOOL)beginFrame {
    if (!self.layer || !self.commandQueue) {
        return NO;
    }
    if (!self.layer.device) {
        self.layer.device = self.device;
    }

    self.currentCommandBuffer = [self.commandQueue commandBuffer];
    if (!self.currentCommandBuffer) {
        [SSKDiagnostics log:@"SSKMetalRenderer: failed to create command buffer."];
        return NO;
    }

    self.currentDrawable = [self.layer nextDrawable];
    if (!self.currentDrawable) {
        self.currentCommandBuffer = nil;
        return NO;
    }

    id<MTLTexture> texture = self.currentDrawable.texture;
    if (texture) {
        self.drawableSize = CGSizeMake(texture.width, texture.height);
    } else {
        self.drawableSize = CGSizeZero;
    }
    self.overrideRenderTarget = nil;
    self.needsClearOnNextPass = YES;
    return YES;
}

- (void)endFrame {
    if (!self.currentCommandBuffer) {
        self.currentDrawable = nil;
        self.overrideRenderTarget = nil;
        return;
    }

    if (self.currentDrawable) {
        [self.currentCommandBuffer presentDrawable:self.currentDrawable];
    }
    [self.currentCommandBuffer commit];
    self.currentCommandBuffer = nil;
    self.currentDrawable = nil;
    self.overrideRenderTarget = nil;
    self.needsClearOnNextPass = YES;
}

- (void)clearWithColor:(MTLClearColor)color {
    self.clearColor = color;
    id<MTLCommandBuffer> commandBuffer = self.currentCommandBuffer;
    id<MTLTexture> target = [self activeRenderTarget];
    if (!commandBuffer || !target) {
        return;
    }

    MTLRenderPassDescriptor *descriptor = [MTLRenderPassDescriptor renderPassDescriptor];
    descriptor.colorAttachments[0].texture = target;
    descriptor.colorAttachments[0].loadAction = MTLLoadActionClear;
    descriptor.colorAttachments[0].storeAction = MTLStoreActionStore;
    descriptor.colorAttachments[0].clearColor = color;

    id<MTLRenderCommandEncoder> encoder = [commandBuffer renderCommandEncoderWithDescriptor:descriptor];
    [encoder endEncoding];
    self.needsClearOnNextPass = NO;
}

- (void)drawParticles:(NSArray<SSKParticle *> *)particles
            blendMode:(SSKParticleBlendMode)blendMode
         viewportSize:(CGSize)viewportSize {
    if (!self.particlePass) { return; }
    id<MTLCommandBuffer> commandBuffer = self.currentCommandBuffer;
    id<MTLTexture> target = [self activeRenderTarget];
    if (!commandBuffer || !target) { return; }

    NSArray<SSKParticle *> *liveParticles = particles ?: @[];
    MTLLoadAction loadAction = self.needsClearOnNextPass ? MTLLoadActionClear : MTLLoadActionLoad;
    BOOL success = [self.particlePass encodeParticles:liveParticles
                                            blendMode:blendMode
                                         viewportSize:viewportSize
                                        commandBuffer:commandBuffer
                                         renderTarget:target
                                           loadAction:loadAction
                                           clearColor:self.clearColor];
    if (!success && [SSKDiagnostics isEnabled]) {
        [SSKDiagnostics log:@"SSKMetalRenderer: particle pass failed to encode."];
    }
    self.needsClearOnNextPass = NO;
}

- (void)drawTexture:(id<MTLTexture>)texture atRect:(CGRect)rect {
    (void)texture;
    (void)rect;
    if ([SSKDiagnostics isEnabled]) {
        [SSKDiagnostics log:@"SSKMetalRenderer: drawTexture:atRect: invoked but not yet implemented."];
    }
}

- (void)applyBlur:(CGFloat)radius {
    CGFloat clamped = MAX(0.0, radius);
    self.particleBlurRadius = clamped;
    if (clamped <= 0.01f || !self.blurPass) {
        return;
    }

    id<MTLCommandBuffer> commandBuffer = self.currentCommandBuffer;
    id<MTLTexture> target = [self activeRenderTarget];
    if (!commandBuffer || !target) {
        return;
    }

    MTLTextureUsage usage = MTLTextureUsageShaderRead | MTLTextureUsageShaderWrite | MTLTextureUsageRenderTarget;
    id<MTLTexture> intermediate = [self.textureCache acquireTextureMatchingTexture:target usage:usage];
    if (!intermediate) {
        if ([SSKDiagnostics isEnabled]) {
            [SSKDiagnostics log:@"SSKMetalRenderer: failed to acquire blur intermediate texture."];
        }
        return;
    }

    id<MTLBlitCommandEncoder> blit = [commandBuffer blitCommandEncoder];
    if (!blit) {
        [self.textureCache releaseTexture:intermediate];
        return;
    }
    MTLOrigin origin = {0, 0, 0};
    MTLSize size = {target.width, target.height, 1};
    [blit copyFromTexture:target
             sourceSlice:0
             sourceLevel:0
            sourceOrigin:origin
              sourceSize:size
               toTexture:intermediate
        destinationSlice:0
        destinationLevel:0
       destinationOrigin:origin];
    [blit endEncoding];

    self.blurPass.radius = clamped;
    BOOL success = [self.blurPass encodeBlur:intermediate
                                  destination:target
                                commandBuffer:commandBuffer];
    [self.textureCache releaseTexture:intermediate];
    if (!success && [SSKDiagnostics isEnabled]) {
        [SSKDiagnostics log:@"SSKMetalRenderer: blur pass failed to encode."];
    }
}

- (void)applyBloom:(CGFloat)intensity {
    CGFloat clamped = MAX(0.0, intensity);
    if (clamped <= 0.01f || !self.bloomPass) {
        return;
    }

    id<MTLCommandBuffer> commandBuffer = self.currentCommandBuffer;
    id<MTLTexture> target = [self activeRenderTarget];
    if (!commandBuffer || !target) {
        return;
    }

    self.bloomPass.intensity = clamped;
    self.bloomPass.threshold = MAX(0.0, self.bloomThreshold);
    self.bloomPass.blurSigma = MAX(0.1, self.bloomBlurSigma);
    BOOL success = [self.bloomPass encodeBloomWithCommandBuffer:commandBuffer
                                                         source:target
                                                   renderTarget:target];
    if (!success && [SSKDiagnostics isEnabled]) {
        [SSKDiagnostics log:@"SSKMetalRenderer: bloom pass failed to encode."];
    }
}

- (void)applyColorGrading:(id)params {
    (void)params;
    if ([SSKDiagnostics isEnabled]) {
        [SSKDiagnostics log:@"SSKMetalRenderer: applyColorGrading: invoked but not yet implemented."];
    }
}

- (void)setRenderTarget:(id<MTLTexture>)texture {
    self.overrideRenderTarget = texture;
}

#pragma mark - Helpers

- (nullable id<MTLLibrary>)loadDefaultLibraryWithDevice:(id<MTLDevice>)device {
    NSBundle *bundle = [NSBundle bundleForClass:self.class];
    NSString *metallibPath = [bundle pathForResource:@"SSKParticleShaders" ofType:@"metallib"];
    NSError *error = nil;
    if (metallibPath.length > 0) {
        NSURL *metallibURL = [NSURL fileURLWithPath:metallibPath];
        id<MTLLibrary> library = [device newLibraryWithURL:metallibURL error:&error];
        if (library) {
            return library;
        }
        if ([SSKDiagnostics isEnabled]) {
            [SSKDiagnostics log:@"SSKMetalRenderer: failed to load metallib at %@ (%@).", metallibPath, error.localizedDescription ?: @"unknown error"];
        }
    } else if ([SSKDiagnostics isEnabled]) {
        [SSKDiagnostics log:@"SSKMetalRenderer: SSKParticleShaders.metallib missing from bundle resources."];
    }
    return nil;
}

- (id<MTLTexture>)activeRenderTarget {
    if (self.overrideRenderTarget) {
        return self.overrideRenderTarget;
    }
    return self.currentDrawable.texture;
}

@end
