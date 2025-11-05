#import "SSKMetalBloomPass.h"

#import <TargetConditionals.h>

#import "SSKDiagnostics.h"
#import "SSKMetalBlurPass.h"

@interface SSKMetalBloomPass ()
@property (nonatomic, strong) id<MTLDevice> device;
@property (nonatomic, strong) id<MTLComputePipelineState> thresholdPipeline;
@property (nonatomic, strong) id<MTLComputePipelineState> compositePipeline;
@property (nonatomic, strong) SSKMetalBlurPass *blurPass;
@property (nonatomic, strong) id<MTLTexture> brightTexture;
@property (nonatomic, strong) id<MTLTexture> blurredTexture;
@property (nonatomic) CGSize textureSize;
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

- (BOOL)setupWithDevice:(id<MTLDevice>)device library:(id<MTLLibrary>)library {
    NSParameterAssert(device);
    NSParameterAssert(library);
    if (!device || !library) {
        return NO;
    }

    self.device = device;

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

    self.blurPass = [[SSKMetalBlurPass alloc] init];
    if (![self.blurPass setupWithDevice:device library:library]) {
        if ([SSKDiagnostics isEnabled]) {
            [SSKDiagnostics log:@"SSKMetalBloomPass: blur pass setup failed."];
        }
        self.blurPass = nil;
        return NO;
    }

    return YES;
}

- (BOOL)encodeBloomWithCommandBuffer:(id<MTLCommandBuffer>)commandBuffer
                              source:(id<MTLTexture>)source
                        renderTarget:(id<MTLTexture>)renderTarget {
    if (!commandBuffer || !source || !renderTarget || !self.device ||
        !self.thresholdPipeline || !self.compositePipeline || !self.blurPass) {
        return NO;
    }

    if (![self ensureIntermediateTexturesMatchingTexture:source]) {
        return NO;
    }

    id<MTLTexture> brightTexture = self.brightTexture;
    id<MTLTexture> blurredTexture = self.blurredTexture;
    if (!brightTexture || !blurredTexture) {
        return NO;
    }

    // Threshold pass
    id<MTLComputeCommandEncoder> encoder = [commandBuffer computeCommandEncoder];
    if (!encoder) { return NO; }
    [encoder setComputePipelineState:self.thresholdPipeline];
    [encoder setTexture:source atIndex:0];
    [encoder setTexture:brightTexture atIndex:1];
    float thresholdValue = (float)MIN(MAX(self.threshold, 0.0), 1.0);
    [encoder setBytes:&thresholdValue length:sizeof(float) atIndex:0];
    MTLSize threadsPerGroup = MTLSizeMake(16, 16, 1);
    MTLSize threadGroups = MTLSizeMake((brightTexture.width + threadsPerGroup.width - 1) / threadsPerGroup.width,
                                       (brightTexture.height + threadsPerGroup.height - 1) / threadsPerGroup.height,
                                       1);
    [encoder dispatchThreadgroups:threadGroups threadsPerThreadgroup:threadsPerGroup];
    [encoder endEncoding];

    // Blur pass (bright -> blurred)
    self.blurPass.radius = (self.blurSigma > 0.01) ? self.blurSigma : 3.0;
    if (![self.blurPass encodeBlur:brightTexture destination:blurredTexture commandBuffer:commandBuffer]) {
        return NO;
    }

    // Composite pass (blurred -> renderTarget)
    encoder = [commandBuffer computeCommandEncoder];
    if (!encoder) { return NO; }
    [encoder setComputePipelineState:self.compositePipeline];
    [encoder setTexture:blurredTexture atIndex:0];
    [encoder setTexture:renderTarget atIndex:1];
    float compositeIntensity = (float)MAX(0.0, self.intensity);
    [encoder setBytes:&compositeIntensity length:sizeof(float) atIndex:0];
    threadGroups = MTLSizeMake((renderTarget.width + threadsPerGroup.width - 1) / threadsPerGroup.width,
                               (renderTarget.height + threadsPerGroup.height - 1) / threadsPerGroup.height,
                               1);
    [encoder dispatchThreadgroups:threadGroups threadsPerThreadgroup:threadsPerGroup];
    [encoder endEncoding];

    return YES;
}

#pragma mark - Helpers

- (BOOL)ensureIntermediateTexturesMatchingTexture:(id<MTLTexture>)texture {
    if (!texture || !self.device) {
        return NO;
    }
    CGSize size = CGSizeMake(texture.width, texture.height);
    if (self.brightTexture &&
        self.blurredTexture &&
        CGSizeEqualToSize(self.textureSize, size) &&
        self.brightTexture.pixelFormat == texture.pixelFormat) {
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

    self.brightTexture = [self.device newTextureWithDescriptor:descriptor];
    self.blurredTexture = [self.device newTextureWithDescriptor:descriptor];
    self.textureSize = size;

    if (!self.brightTexture || !self.blurredTexture) {
        self.brightTexture = nil;
        self.blurredTexture = nil;
        if ([SSKDiagnostics isEnabled]) {
            [SSKDiagnostics log:@"SSKMetalBloomPass: failed to allocate intermediate textures (%lux%lu).",
             (unsigned long)texture.width,
             (unsigned long)texture.height];
        }
        return NO;
    }

    return YES;
}

@end
