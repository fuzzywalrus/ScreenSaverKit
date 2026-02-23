#import "SSKMetalTrailPass.h"
#import "SSKDiagnostics.h"

@interface SSKMetalTrailPass () {
    BOOL _needsClear;
}
@property (nonatomic, strong) id<MTLDevice> device;
@property (nonatomic, strong) id<MTLComputePipelineState> fadePipeline;
@property (nonatomic, strong, nullable) id<MTLTexture> trailTexture;
@end

@implementation SSKMetalTrailPass

- (instancetype)initWithDevice:(id<MTLDevice>)device library:(id<MTLLibrary>)library {
    NSParameterAssert(device);
    NSParameterAssert(library);
    if ((self = [super init])) {
        _device = device;

        id<MTLFunction> fadeFunc = [library newFunctionWithName:@"trailFadeKernel"];
        if (!fadeFunc) {
            if ([SSKDiagnostics isEnabled]) {
                [SSKDiagnostics log:@"SSKMetalTrailPass: trailFadeKernel not found in library."];
            }
            return nil;
        }

        NSError *error = nil;
        _fadePipeline = [device newComputePipelineStateWithFunction:fadeFunc error:&error];
        if (!_fadePipeline) {
            if ([SSKDiagnostics isEnabled]) {
                [SSKDiagnostics log:@"SSKMetalTrailPass: failed to create fade pipeline: %@", error];
            }
            return nil;
        }
    }
    return self;
}

- (id<MTLTexture>)trailTextureForSize:(CGSize)size {
    NSUInteger w = (NSUInteger)size.width;
    NSUInteger h = (NSUInteger)size.height;
    if (w == 0 || h == 0) { return nil; }

    // Recreate if size changed
    if (self.trailTexture && self.trailTexture.width == w && self.trailTexture.height == h) {
        return self.trailTexture;
    }

    MTLTextureDescriptor *desc = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm
                                                                                    width:w
                                                                                   height:h
                                                                                mipmapped:NO];
    desc.usage = MTLTextureUsageShaderRead | MTLTextureUsageShaderWrite | MTLTextureUsageRenderTarget;
    desc.storageMode = MTLStorageModePrivate;

    id<MTLTexture> tex = [self.device newTextureWithDescriptor:desc];
    if (!tex) {
        if ([SSKDiagnostics isEnabled]) {
            [SSKDiagnostics log:@"SSKMetalTrailPass: failed to allocate trail texture (%lux%lu).",
             (unsigned long)w, (unsigned long)h];
        }
        return nil;
    }

    self.trailTexture = tex;
    _needsClear = YES;  // Deferred: cleared on next fadeWithRate: call

    return self.trailTexture;
}

- (void)fadeWithRate:(float)fadeRate commandBuffer:(id<MTLCommandBuffer>)commandBuffer {
    if (!self.trailTexture || !self.fadePipeline || !commandBuffer) { return; }

    // Deferred clear: encode on the renderer's command buffer instead of
    // creating a throwaway queue and blocking with waitUntilCompleted.
    if (_needsClear) {
        MTLRenderPassDescriptor *rpd = [MTLRenderPassDescriptor renderPassDescriptor];
        rpd.colorAttachments[0].texture = self.trailTexture;
        rpd.colorAttachments[0].loadAction = MTLLoadActionClear;
        rpd.colorAttachments[0].storeAction = MTLStoreActionStore;
        rpd.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 1);
        id<MTLRenderCommandEncoder> enc = [commandBuffer renderCommandEncoderWithDescriptor:rpd];
        if (enc) { [enc endEncoding]; }
        _needsClear = NO;
    }

    if (fadeRate <= 0.0f) { return; }

    id<MTLComputeCommandEncoder> encoder = [commandBuffer computeCommandEncoder];
    if (!encoder) { return; }

    [encoder setComputePipelineState:self.fadePipeline];
    [encoder setTexture:self.trailTexture atIndex:0];
    [encoder setBytes:&fadeRate length:sizeof(float) atIndex:0];

    NSUInteger w = self.trailTexture.width;
    NSUInteger h = self.trailTexture.height;
    NSUInteger threadWidth = self.fadePipeline.threadExecutionWidth;
    NSUInteger threadHeight = self.fadePipeline.maxTotalThreadsPerThreadgroup / threadWidth;
    MTLSize threadsPerGroup = MTLSizeMake(threadWidth, threadHeight, 1);
    MTLSize threadgroups = MTLSizeMake((w + threadsPerGroup.width - 1) / threadsPerGroup.width,
                                        (h + threadsPerGroup.height - 1) / threadsPerGroup.height,
                                        1);

    [encoder dispatchThreadgroups:threadgroups threadsPerThreadgroup:threadsPerGroup];
    [encoder endEncoding];
}

- (void)blitTo:(id<MTLTexture>)destination commandBuffer:(id<MTLCommandBuffer>)commandBuffer {
    if (!self.trailTexture || !destination || !commandBuffer) { return; }
    if (self.trailTexture.width != destination.width || self.trailTexture.height != destination.height) {
        return;
    }

    id<MTLBlitCommandEncoder> blit = [commandBuffer blitCommandEncoder];
    if (!blit) { return; }

    [blit copyFromTexture:self.trailTexture
              sourceSlice:0
              sourceLevel:0
             sourceOrigin:MTLOriginMake(0, 0, 0)
               sourceSize:MTLSizeMake(self.trailTexture.width, self.trailTexture.height, 1)
                toTexture:destination
         destinationSlice:0
         destinationLevel:0
        destinationOrigin:MTLOriginMake(0, 0, 0)];

    [blit endEncoding];
}

@end
