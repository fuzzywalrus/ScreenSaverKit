#import "SSKMetalBlurPass.h"

#import <TargetConditionals.h>

#import "SSKDiagnostics.h"

@interface SSKMetalBlurPass ()
@property (nonatomic, strong) id<MTLDevice> device;
@property (nonatomic, strong) id<MTLComputePipelineState> blurPipelineHorizontal;
@property (nonatomic, strong) id<MTLComputePipelineState> blurPipelineVertical;
@property (nonatomic, strong) id<MTLTexture> scratchTexture;
@property (nonatomic) CGSize scratchTextureSize;
@end

@implementation SSKMetalBlurPass

- (BOOL)setupWithDevice:(id<MTLDevice>)device library:(id<MTLLibrary>)library {
    NSParameterAssert(device);
    NSParameterAssert(library);
    if (!device || !library) {
        return NO;
    }

    self.device = device;

    NSError *error = nil;
    id<MTLFunction> horizFunc = [library newFunctionWithName:@"gaussianBlurHorizontal"];
    id<MTLFunction> vertFunc = [library newFunctionWithName:@"gaussianBlurVertical"];
    if (!horizFunc || !vertFunc) {
        if ([SSKDiagnostics isEnabled]) {
            [SSKDiagnostics log:@"SSKMetalBlurPass: missing blur kernels in library."];
        }
        return NO;
    }

    self.blurPipelineHorizontal = [device newComputePipelineStateWithFunction:horizFunc error:&error];
    if (!self.blurPipelineHorizontal) {
        if ([SSKDiagnostics isEnabled]) {
            [SSKDiagnostics log:@"SSKMetalBlurPass: failed to create horizontal blur pipeline: %@", error.localizedDescription];
        }
        return NO;
    }

    self.blurPipelineVertical = [device newComputePipelineStateWithFunction:vertFunc error:&error];
    if (!self.blurPipelineVertical) {
        if ([SSKDiagnostics isEnabled]) {
            [SSKDiagnostics log:@"SSKMetalBlurPass: failed to create vertical blur pipeline: %@", error.localizedDescription];
        }
        self.blurPipelineHorizontal = nil;
        return NO;
    }

    return YES;
}

- (BOOL)encodeBlur:(id<MTLTexture>)source
        destination:(id<MTLTexture>)destination
      commandBuffer:(id<MTLCommandBuffer>)commandBuffer {
    if (!commandBuffer || !source || !destination) {
        return NO;
    }
    if (self.radius <= 0.01f) {
        return YES;
    }
    if (!self.blurPipelineHorizontal || !self.blurPipelineVertical || !self.device) {
        if ([SSKDiagnostics isEnabled]) {
            [SSKDiagnostics log:@"SSKMetalBlurPass: blur pipelines unavailable."];
        }
        return NO;
    }

    if (![self ensureScratchTextureForSource:source]) {
        return NO;
    }

    float sigma = MAX(0.5f, (float)self.radius);
    MTLSize threadsPerGroup = MTLSizeMake(16, 16, 1);

    // Horizontal pass: source -> scratch
    id<MTLComputeCommandEncoder> encoder = [commandBuffer computeCommandEncoder];
    if (!encoder) { return NO; }
    [encoder setComputePipelineState:self.blurPipelineHorizontal];
    [encoder setTexture:source atIndex:0];
    [encoder setTexture:self.scratchTexture atIndex:1];
    [encoder setBytes:&sigma length:sizeof(float) atIndex:0];
    MTLSize threadGroups = MTLSizeMake((self.scratchTexture.width + threadsPerGroup.width - 1) / threadsPerGroup.width,
                                       (self.scratchTexture.height + threadsPerGroup.height - 1) / threadsPerGroup.height,
                                       1);
    [encoder dispatchThreadgroups:threadGroups threadsPerThreadgroup:threadsPerGroup];
    [encoder endEncoding];

    // Vertical pass: scratch -> destination
    encoder = [commandBuffer computeCommandEncoder];
    if (!encoder) { return NO; }
    [encoder setComputePipelineState:self.blurPipelineVertical];
    [encoder setTexture:self.scratchTexture atIndex:0];
    [encoder setTexture:destination atIndex:1];
    [encoder setBytes:&sigma length:sizeof(float) atIndex:0];
    threadGroups = MTLSizeMake((destination.width + threadsPerGroup.width - 1) / threadsPerGroup.width,
                               (destination.height + threadsPerGroup.height - 1) / threadsPerGroup.height,
                               1);
    [encoder dispatchThreadgroups:threadGroups threadsPerThreadgroup:threadsPerGroup];
    [encoder endEncoding];

    return YES;
}

#pragma mark - Helpers

- (BOOL)ensureScratchTextureForSource:(id<MTLTexture>)texture {
    if (!texture || !self.device) { return NO; }
    CGSize size = CGSizeMake(texture.width, texture.height);
    if (self.scratchTexture && CGSizeEqualToSize(self.scratchTextureSize, size) &&
        self.scratchTexture.pixelFormat == texture.pixelFormat) {
        return YES;
    }

    MTLTextureDescriptor *descriptor =
    [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:texture.pixelFormat
                                                       width:texture.width
                                                      height:texture.height
                                                   mipmapped:NO];
    descriptor.usage = MTLTextureUsageShaderRead | MTLTextureUsageShaderWrite;
#if TARGET_OS_OSX
    descriptor.storageMode = MTLStorageModePrivate;
#endif
    descriptor.resourceOptions = MTLResourceStorageModePrivate;
    self.scratchTexture = [self.device newTextureWithDescriptor:descriptor];
    self.scratchTextureSize = size;
    if (!self.scratchTexture && [SSKDiagnostics isEnabled]) {
        [SSKDiagnostics log:@"SSKMetalBlurPass: failed to allocate scratch texture (%lux%lu).",
         (unsigned long)texture.width, (unsigned long)texture.height];
    }
    return self.scratchTexture != nil;
}

@end
