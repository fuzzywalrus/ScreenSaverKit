#import "SSKMetalBlurPass.h"

#import <TargetConditionals.h>

#import "SSKDiagnostics.h"
#import "SSKMetalTextureCache.h"

@interface SSKMetalBlurPass ()
@property (nonatomic, strong) id<MTLDevice> device;
@property (nonatomic, strong) id<MTLComputePipelineState> blurPipelineHorizontal;
@property (nonatomic, strong) id<MTLComputePipelineState> blurPipelineVertical;
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
      commandBuffer:(id<MTLCommandBuffer>)commandBuffer
       textureCache:(SSKMetalTextureCache *)textureCache {
    if (!commandBuffer || !source || !destination || !textureCache) {
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

    MTLTextureUsage usage = MTLTextureUsageShaderRead | MTLTextureUsageShaderWrite;
    id<MTLTexture> scratch = [textureCache acquireTextureMatchingTexture:source usage:usage];
    if (!scratch) {
        if ([SSKDiagnostics isEnabled]) {
            [SSKDiagnostics log:@"SSKMetalBlurPass: failed to acquire scratch texture from cache."];
        }
        return NO;
    }

    float sigma = MAX(0.5f, (float)self.radius);

    // Horizontal pass: source -> scratch
    id<MTLComputeCommandEncoder> encoder = [commandBuffer computeCommandEncoder];
    if (!encoder) {
        [textureCache releaseTexture:scratch];
        return NO;
    }
    MTLSize threadsPerGroup = [self threadgroupSizeForPipeline:self.blurPipelineHorizontal];
    MTLSize threadGroups = MTLSizeMake((scratch.width + threadsPerGroup.width - 1) / threadsPerGroup.width,
                                       (scratch.height + threadsPerGroup.height - 1) / threadsPerGroup.height,
                                       1);
    [encoder setComputePipelineState:self.blurPipelineHorizontal];
    [encoder setTexture:source atIndex:0];
    [encoder setTexture:scratch atIndex:1];
    [encoder setBytes:&sigma length:sizeof(float) atIndex:0];
    [encoder dispatchThreadgroups:threadGroups threadsPerThreadgroup:threadsPerGroup];
    [encoder endEncoding];

    // Vertical pass: scratch -> destination
    encoder = [commandBuffer computeCommandEncoder];
    if (!encoder) {
        [textureCache releaseTexture:scratch];
        return NO;
    }
    threadsPerGroup = [self threadgroupSizeForPipeline:self.blurPipelineVertical];
    threadGroups = MTLSizeMake((destination.width + threadsPerGroup.width - 1) / threadsPerGroup.width,
                               (destination.height + threadsPerGroup.height - 1) / threadsPerGroup.height,
                               1);
    [encoder setComputePipelineState:self.blurPipelineVertical];
    [encoder setTexture:scratch atIndex:0];
    [encoder setTexture:destination atIndex:1];
    [encoder setBytes:&sigma length:sizeof(float) atIndex:0];
    [encoder dispatchThreadgroups:threadGroups threadsPerThreadgroup:threadsPerGroup];
    [encoder endEncoding];

    [textureCache releaseTexture:scratch];
    return YES;
}

#pragma mark - Helpers

- (MTLSize)threadgroupSizeForPipeline:(id<MTLComputePipelineState>)pipeline {
    if (!pipeline) {
        return MTLSizeMake(16, 16, 1);
    }
    NSUInteger threadWidth = pipeline.threadExecutionWidth;
    NSUInteger maxThreads = pipeline.maxTotalThreadsPerThreadgroup;
    NSUInteger height = MAX(1, MIN(16u, maxThreads / MAX(threadWidth, (NSUInteger)1)));
    NSUInteger width = MIN(16u, threadWidth);
    return MTLSizeMake(width, height, 1);
}

@end
