#import "SSKMetalBloomPass.h"

#import <TargetConditionals.h>

#import "SSKDiagnostics.h"
#import "SSKMetalBlurPass.h"
#import "SSKMetalTextureCache.h"

@interface SSKMetalBloomPass ()
@property (nonatomic, strong) id<MTLDevice> device;
@property (nonatomic, strong) id<MTLComputePipelineState> thresholdPipeline;
@property (nonatomic, strong) id<MTLComputePipelineState> compositePipeline;
@property (nonatomic, strong) SSKMetalBlurPass *blurPass;
@end

@implementation SSKMetalBloomPass

- (instancetype)init {
    if ((self = [super init])) {
        _threshold = 0.8;
        _intensity = 1.0;
        _blurSigma = 3.0;
    }
    return self;
}

- (BOOL)setupWithDevice:(id<MTLDevice>)device
                library:(id<MTLLibrary>)library
               blurPass:(nullable SSKMetalBlurPass *)blurPass {
    NSParameterAssert(device);
    NSParameterAssert(library);
    if (!device || !library) {
        return NO;
    }

    self.device = device;
    self.blurPass = blurPass;
    if (!self.blurPass) {
        if ([SSKDiagnostics isEnabled]) {
            [SSKDiagnostics log:@"SSKMetalBloomPass: requires a shared blur pass instance."];
        }
        return NO;
    }

    NSError *error = nil;
    id<MTLFunction> thresholdFunc = [library newFunctionWithName:@"bloomThresholdKernel"];
    id<MTLFunction> compositeFunc = [library newFunctionWithName:@"bloomCompositeKernel"];
    if (!thresholdFunc || !compositeFunc) {
        if ([SSKDiagnostics isEnabled]) {
            [SSKDiagnostics log:@"SSKMetalBloomPass: missing bloom kernels in library."];
        }
        return NO;
    }

    self.thresholdPipeline = [device newComputePipelineStateWithFunction:thresholdFunc error:&error];
    if (!self.thresholdPipeline) {
        if ([SSKDiagnostics isEnabled]) {
            [SSKDiagnostics log:@"SSKMetalBloomPass: failed to create threshold pipeline: %@", error.localizedDescription];
        }
        return NO;
    }

    self.compositePipeline = [device newComputePipelineStateWithFunction:compositeFunc error:&error];
    if (!self.compositePipeline) {
        if ([SSKDiagnostics isEnabled]) {
            [SSKDiagnostics log:@"SSKMetalBloomPass: failed to create composite pipeline: %@", error.localizedDescription];
        }
        self.thresholdPipeline = nil;
        return NO;
    }

    return self.blurPass != nil;
}

- (BOOL)encodeBloomWithCommandBuffer:(id<MTLCommandBuffer>)commandBuffer
                              source:(id<MTLTexture>)source
                        renderTarget:(id<MTLTexture>)renderTarget
                        textureCache:(SSKMetalTextureCache *)textureCache {
    if (!commandBuffer || !source || !renderTarget || !textureCache || !self.device ||
        !self.thresholdPipeline || !self.compositePipeline || !self.blurPass) {
        return NO;
    }

    MTLTextureUsage usage = MTLTextureUsageShaderRead | MTLTextureUsageShaderWrite;
    id<MTLTexture> brightTexture = [textureCache acquireTextureMatchingTexture:source usage:usage];
    id<MTLTexture> blurredTexture = [textureCache acquireTextureMatchingTexture:source usage:usage];
    if (!brightTexture || !blurredTexture) {
        if (brightTexture) { [textureCache releaseTexture:brightTexture]; }
        if (blurredTexture) { [textureCache releaseTexture:blurredTexture]; }
        if ([SSKDiagnostics isEnabled]) {
            [SSKDiagnostics log:@"SSKMetalBloomPass: failed to acquire intermediate textures from cache."];
        }
        return NO;
    }

    // Threshold pass
    id<MTLComputeCommandEncoder> encoder = [commandBuffer computeCommandEncoder];
    if (!encoder) {
        [textureCache releaseTexture:brightTexture];
        [textureCache releaseTexture:blurredTexture];
        return NO;
    }
    float thresholdValue = (float)MIN(MAX(self.threshold, 0.0), 1.0);
    MTLSize threadsPerGroup = MTLSizeMake(16, 16, 1);
    MTLSize threadGroups = MTLSizeMake((brightTexture.width + threadsPerGroup.width - 1) / threadsPerGroup.width,
                                       (brightTexture.height + threadsPerGroup.height - 1) / threadsPerGroup.height,
                                       1);
    [encoder setComputePipelineState:self.thresholdPipeline];
    [encoder setTexture:source atIndex:0];
    [encoder setTexture:brightTexture atIndex:1];
    [encoder setBytes:&thresholdValue length:sizeof(float) atIndex:0];
    [encoder dispatchThreadgroups:threadGroups threadsPerThreadgroup:threadsPerGroup];
    [encoder endEncoding];

    // Blur pass (bright -> blurred)
    self.blurPass.radius = (self.blurSigma > 0.01) ? self.blurSigma : 3.0;
    BOOL blurSuccess = [self.blurPass encodeBlur:brightTexture
                                       destination:blurredTexture
                                     commandBuffer:commandBuffer
                                      textureCache:textureCache];
    [textureCache releaseTexture:brightTexture];
    if (!blurSuccess) {
        [textureCache releaseTexture:blurredTexture];
        return NO;
    }

    // Composite pass (blurred -> renderTarget)
    encoder = [commandBuffer computeCommandEncoder];
    if (!encoder) {
        [textureCache releaseTexture:blurredTexture];
        return NO;
    }
    float compositeIntensity = (float)MAX(0.0, self.intensity);
    threadGroups = MTLSizeMake((renderTarget.width + threadsPerGroup.width - 1) / threadsPerGroup.width,
                               (renderTarget.height + threadsPerGroup.height - 1) / threadsPerGroup.height,
                               1);
    [encoder setComputePipelineState:self.compositePipeline];
    [encoder setTexture:blurredTexture atIndex:0];
    [encoder setTexture:renderTarget atIndex:1];
    [encoder setBytes:&compositeIntensity length:sizeof(float) atIndex:0];
    [encoder dispatchThreadgroups:threadGroups threadsPerThreadgroup:threadsPerGroup];
    [encoder endEncoding];

    [textureCache releaseTexture:blurredTexture];
    return YES;
}

@end
