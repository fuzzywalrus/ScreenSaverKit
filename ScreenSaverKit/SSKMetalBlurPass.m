#import "SSKMetalBlurPass.h"

#import <TargetConditionals.h>
#import <math.h>

#import "SSKDiagnostics.h"
#import "SSKMetalTextureCache.h"

static const uint32_t kSSKMetalBlurMaxRadius = 32u;

@interface SSKMetalBlurPass ()
@property (nonatomic, strong) id<MTLDevice> device;
@property (nonatomic, strong) id<MTLComputePipelineState> blurPipelineHorizontal;
@property (nonatomic, strong) id<MTLComputePipelineState> blurPipelineVertical;
@property (nonatomic, strong, nullable) id<MTLBuffer> weightsBuffer;
@property (nonatomic) float cachedSigma;
@property (nonatomic) uint32_t cachedRadius;
@end

@implementation SSKMetalBlurPass

- (instancetype)init {
    if ((self = [super init])) {
        _cachedSigma = -1.0f;
        _cachedRadius = 0;
    }
    return self;
}

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
    uint32_t radius = (uint32_t)ceilf(MAX(1.0f, sigma * 3.0f));
    radius = MIN(radius, kSSKMetalBlurMaxRadius);
    if (![self prepareWeightsForSigma:sigma radius:radius]) {
        [textureCache releaseTexture:scratch];
        return NO;
    }

    id<MTLComputeCommandEncoder> encoder = [commandBuffer computeCommandEncoder];
    if (!encoder) {
        [textureCache releaseTexture:scratch];
        return NO;
    }

    // Horizontal pass: source -> scratch
    MTLSize threadsPerGroup = [self threadgroupSizeForPipeline:self.blurPipelineHorizontal];
    MTLSize threadGroups = [self threadgroupCountForWidth:scratch.width
                                                   height:scratch.height
                                         threadsPerGroup:threadsPerGroup];
    [encoder setComputePipelineState:self.blurPipelineHorizontal];
    [encoder setTexture:source atIndex:0];
    [encoder setTexture:scratch atIndex:1];
    [encoder setBuffer:self.weightsBuffer offset:0 atIndex:0];
    uint32_t radiusValue = radius;
    [encoder setBytes:&radiusValue length:sizeof(uint32_t) atIndex:1];
    [encoder dispatchThreadgroups:threadGroups threadsPerThreadgroup:threadsPerGroup];
    [encoder memoryBarrierWithScope:MTLBarrierScopeTextures];

    // Vertical pass: scratch -> destination
    threadsPerGroup = [self threadgroupSizeForPipeline:self.blurPipelineVertical];
    threadGroups = [self threadgroupCountForWidth:destination.width
                                           height:destination.height
                                 threadsPerGroup:threadsPerGroup];
    [encoder setComputePipelineState:self.blurPipelineVertical];
    [encoder setTexture:scratch atIndex:0];
    [encoder setTexture:destination atIndex:1];
    [encoder setBuffer:self.weightsBuffer offset:0 atIndex:0];
    [encoder setBytes:&radiusValue length:sizeof(uint32_t) atIndex:1];
    [encoder dispatchThreadgroups:threadGroups threadsPerThreadgroup:threadsPerGroup];
    [encoder endEncoding];

    [textureCache releaseTexture:scratch];
    return YES;
}

#pragma mark - Helpers

- (BOOL)prepareWeightsForSigma:(float)sigma radius:(uint32_t)radius {
    if (self.weightsBuffer && fabsf(self.cachedSigma - sigma) < 0.001f && self.cachedRadius == radius) {
        return YES;
    }
    if (radius == 0 || radius > kSSKMetalBlurMaxRadius) {
        return NO;
    }

    float weights[kSSKMetalBlurMaxRadius + 1] = {0.0f};
    float sum = 0.0f;
    weights[0] = 1.0f;
    sum += weights[0];
    float doubleSigmaSq = 2.0f * sigma * sigma;
    for (uint32_t i = 1; i <= radius; ++i) {
        float weight = expf(-(float)(i * i) / doubleSigmaSq);
        weights[i] = weight;
        sum += 2.0f * weight;
    }
    float invSum = sum > 0.00001f ? (1.0f / sum) : 1.0f;
    for (uint32_t i = 0; i <= radius; ++i) {
        weights[i] *= invSum;
    }

    float normalized[kSSKMetalBlurMaxRadius + 1] = {0.0f};
    memcpy(normalized, weights, sizeof(float) * (radius + 1));

    id<MTLBuffer> buffer = [self.device newBufferWithBytes:normalized
                                                   length:sizeof(normalized)
                                                  options:MTLResourceStorageModeShared];
    if (!buffer) {
        return NO;
    }

    self.weightsBuffer = buffer;
    self.cachedSigma = sigma;
    self.cachedRadius = radius;
    return YES;
}

- (MTLSize)threadgroupSizeForPipeline:(id<MTLComputePipelineState>)pipeline {
    if (!pipeline) {
        return MTLSizeMake(32, 1, 1);
    }
    NSUInteger threadWidth = pipeline.threadExecutionWidth;
    NSUInteger maxThreads = pipeline.maxTotalThreadsPerThreadgroup;
    if (threadWidth == 0) {
        threadWidth = 1;
    }
    threadWidth = MIN(threadWidth, maxThreads);
    threadWidth = MIN(threadWidth, (NSUInteger)256);
    threadWidth = MAX(threadWidth, (NSUInteger)1);
    return MTLSizeMake(threadWidth, 1, 1);
}

- (MTLSize)threadgroupCountForWidth:(NSUInteger)width
                             height:(NSUInteger)height
                   threadsPerGroup:(MTLSize)threadsPerGroup {
    NSUInteger groupsX = (width + threadsPerGroup.width - 1) / threadsPerGroup.width;
    NSUInteger groupsY = (height + threadsPerGroup.height - 1) / MAX(threadsPerGroup.height, (NSUInteger)1);
    return MTLSizeMake(groupsX, groupsY, 1);
}

@end
