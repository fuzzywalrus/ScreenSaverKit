#import "SSKMetalParticlePass.h"

#import <simd/simd.h>
#import <TargetConditionals.h>
#import <AppKit/AppKit.h>

#import "SSKDiagnostics.h"

typedef struct {
    vector_float2 position;
    vector_float2 direction;
    float width;
    float length;
    vector_float4 color;
    float softness;
    float padding[3];
} SSKMetalInstanceData;

@interface SSKMetalParticlePass ()
@property (nonatomic, strong) id<MTLDevice> device;
@property (nonatomic, strong) id<MTLLibrary> library;
@property (nonatomic, strong) id<MTLRenderPipelineState> alphaPipeline;
@property (nonatomic, strong) id<MTLRenderPipelineState> additivePipeline;
@property (nonatomic, strong) id<MTLComputePipelineState> blurPipelineHorizontal;
@property (nonatomic, strong) id<MTLComputePipelineState> blurPipelineVertical;
@property (nonatomic, strong) id<MTLBuffer> quadVertexBuffer;
@property (nonatomic, strong) id<MTLBuffer> instanceBuffer;
@property (nonatomic) NSUInteger instanceCapacity;
@property (nonatomic, strong) id<MTLTexture> blurIntermediateTexture;
@property (nonatomic, strong) id<MTLTexture> blurScratchTexture;
@property (nonatomic) CGSize blurTextureSize;
@end

@implementation SSKMetalParticlePass

- (BOOL)setupWithDevice:(id<MTLDevice>)device library:(id<MTLLibrary>)library {
    NSParameterAssert(device);
    NSParameterAssert(library);
    if (!device || !library) {
        return NO;
    }
    self.device = device;
    self.library = library;
    return [self buildQuadBuffer] && [self buildRenderPipelines] && [self buildBlurPipelines];
}

- (BOOL)encodeParticles:(NSArray<SSKParticle *> *)particles
              blendMode:(SSKParticleBlendMode)blendMode
           viewportSize:(CGSize)viewportSize
          commandBuffer:(id<MTLCommandBuffer>)commandBuffer
           renderTarget:(id<MTLTexture>)renderTarget
             loadAction:(MTLLoadAction)loadAction
             clearColor:(MTLClearColor)clearColor {
    if (!commandBuffer || !renderTarget) {
        return NO;
    }

    if (particles.count == 0) {
        if (loadAction == MTLLoadActionClear) {
            MTLRenderPassDescriptor *descriptor = [MTLRenderPassDescriptor renderPassDescriptor];
            descriptor.colorAttachments[0].texture = renderTarget;
            descriptor.colorAttachments[0].loadAction = MTLLoadActionClear;
            descriptor.colorAttachments[0].storeAction = MTLStoreActionStore;
            descriptor.colorAttachments[0].clearColor = clearColor;
            id<MTLRenderCommandEncoder> encoder = [commandBuffer renderCommandEncoderWithDescriptor:descriptor];
            [encoder endEncoding];
        }
        return YES;
    }

    [self ensureInstanceCapacity:particles.count];
    if (!self.instanceBuffer) {
        return NO;
    }

    SSKMetalInstanceData *instances = self.instanceBuffer.contents;
    NSUInteger index = 0;
    for (SSKParticle *particle in particles) {
        SSKMetalInstanceData data;
        data.position = (vector_float2){(float)particle.position.x, (float)particle.position.y};
        vector_float2 dir = (vector_float2){(float)particle.userVector.x, (float)particle.userVector.y};
        float len = simd_length(dir);
        if (len < 0.0001f) {
            dir = (vector_float2){1.0f, 0.0f};
        } else {
            dir /= len;
        }
        data.direction = dir;
        float width = MAX(1.0f, (float)particle.size);
        data.width = width;
        data.length = width * 12.0f;

        NSColor *color = particle.color ?: [NSColor whiteColor];
        color = [color colorUsingColorSpace:[NSColorSpace extendedSRGBColorSpace]] ?: color;
        data.color = (vector_float4){(float)color.redComponent,
                                     (float)color.greenComponent,
                                     (float)color.blueComponent,
                                     (float)color.alphaComponent};
        float softness = (float)particle.userScalar;
        if (!isfinite(softness) || softness < 0.0f) {
            softness = 0.0f;
        }
        data.softness = softness;
        instances[index++] = data;
    }

    BOOL useBlur = (self.blurRadius > 0.01f);
    id<MTLTexture> drawTexture = renderTarget;
    if (useBlur) {
        drawTexture = [self ensureBlurTexturesForTexture:renderTarget];
        if (!drawTexture) {
            useBlur = NO;
            drawTexture = renderTarget;
        }
    }

    MTLRenderPassDescriptor *descriptor = [MTLRenderPassDescriptor renderPassDescriptor];
    descriptor.colorAttachments[0].texture = drawTexture;
    descriptor.colorAttachments[0].storeAction = MTLStoreActionStore;
    descriptor.colorAttachments[0].clearColor = clearColor;
    descriptor.colorAttachments[0].loadAction = useBlur ? MTLLoadActionClear : loadAction;

    id<MTLRenderCommandEncoder> encoder = [commandBuffer renderCommandEncoderWithDescriptor:descriptor];
    if (!encoder) {
        return NO;
    }

    id<MTLRenderPipelineState> pipeline = (blendMode == SSKParticleBlendModeAdditive) ? self.additivePipeline : self.alphaPipeline;
    if (!pipeline) {
        [encoder endEncoding];
        return NO;
    }

    MTLViewport viewport = {0.0, 0.0, (double)renderTarget.width, (double)renderTarget.height, 0.0, 1.0};
    [encoder setViewport:viewport];
    [encoder setRenderPipelineState:pipeline];
    [encoder setVertexBuffer:self.quadVertexBuffer offset:0 atIndex:0];
    [encoder setVertexBuffer:self.instanceBuffer offset:0 atIndex:1];
    vector_float2 viewportPoints = {(float)viewportSize.width, (float)viewportSize.height};
    [encoder setVertexBytes:&viewportPoints length:sizeof(vector_float2) atIndex:2];
    [encoder drawPrimitives:MTLPrimitiveTypeTriangleStrip vertexStart:0 vertexCount:4 instanceCount:index];
    [encoder endEncoding];

    if (useBlur) {
        [self applyGaussianBlurWithCommandBuffer:commandBuffer
                                    sourceTexture:drawTexture
                               destinationTexture:renderTarget];
    }

    return YES;
}

#pragma mark - Private helpers

- (BOOL)buildQuadBuffer {
    static const vector_float2 quadVertices[] = {
        {-0.5f, -0.5f},
        { 0.5f, -0.5f},
        {-0.5f,  0.5f},
        { 0.5f,  0.5f}
    };
    self.quadVertexBuffer = [self.device newBufferWithBytes:quadVertices
                                                    length:sizeof(quadVertices)
                                                   options:MTLResourceStorageModeShared];
    self.instanceCapacity = 0;
    if (!self.quadVertexBuffer && [SSKDiagnostics isEnabled]) {
        [SSKDiagnostics log:@"SSKMetalParticlePass: failed to create quad vertex buffer."];
    }
    return self.quadVertexBuffer != nil;
}

- (BOOL)buildRenderPipelines {
    NSError *error = nil;
    id<MTLFunction> vertexFunc = [self.library newFunctionWithName:@"particleVertex"];
    id<MTLFunction> fragmentFunc = [self.library newFunctionWithName:@"particleFragment"];
    if (!vertexFunc || !fragmentFunc) {
        if ([SSKDiagnostics isEnabled]) {
            [SSKDiagnostics log:@"SSKMetalParticlePass: missing particle shader functions in library."];
        }
        return NO;
    }

    MTLRenderPipelineDescriptor *descriptor = [MTLRenderPipelineDescriptor new];
    descriptor.vertexFunction = vertexFunc;
    descriptor.fragmentFunction = fragmentFunc;
    descriptor.colorAttachments[0].pixelFormat = MTLPixelFormatBGRA8Unorm;
    descriptor.colorAttachments[0].blendingEnabled = YES;
    descriptor.colorAttachments[0].rgbBlendOperation = MTLBlendOperationAdd;
    descriptor.colorAttachments[0].alphaBlendOperation = MTLBlendOperationAdd;

    descriptor.colorAttachments[0].sourceRGBBlendFactor = MTLBlendFactorOne;
    descriptor.colorAttachments[0].destinationRGBBlendFactor = MTLBlendFactorOneMinusSourceAlpha;
    descriptor.colorAttachments[0].sourceAlphaBlendFactor = MTLBlendFactorOne;
    descriptor.colorAttachments[0].destinationAlphaBlendFactor = MTLBlendFactorOneMinusSourceAlpha;
    self.alphaPipeline = [self.device newRenderPipelineStateWithDescriptor:descriptor error:&error];
    if (!self.alphaPipeline) {
        if ([SSKDiagnostics isEnabled]) {
            [SSKDiagnostics log:@"SSKMetalParticlePass: failed to create alpha pipeline: %@", error.localizedDescription];
        }
        return NO;
    }

    descriptor.colorAttachments[0].sourceRGBBlendFactor = MTLBlendFactorOne;
    descriptor.colorAttachments[0].destinationRGBBlendFactor = MTLBlendFactorOne;
    descriptor.colorAttachments[0].sourceAlphaBlendFactor = MTLBlendFactorOne;
    descriptor.colorAttachments[0].destinationAlphaBlendFactor = MTLBlendFactorOne;
    self.additivePipeline = [self.device newRenderPipelineStateWithDescriptor:descriptor error:&error];
    if (!self.additivePipeline) {
        if ([SSKDiagnostics isEnabled]) {
            [SSKDiagnostics log:@"SSKMetalParticlePass: failed to create additive pipeline: %@", error.localizedDescription];
        }
        return NO;
    }
    return YES;
}

- (BOOL)buildBlurPipelines {
    NSError *error = nil;
    id<MTLFunction> horiz = [self.library newFunctionWithName:@"gaussianBlurHorizontal"];
    id<MTLFunction> vert = [self.library newFunctionWithName:@"gaussianBlurVertical"];
    if (!horiz || !vert) {
        if ([SSKDiagnostics isEnabled]) {
            [SSKDiagnostics log:@"SSKMetalParticlePass: missing blur compute kernels in library."];
        }
        return NO;
    }
    self.blurPipelineHorizontal = [self.device newComputePipelineStateWithFunction:horiz error:&error];
    if (!self.blurPipelineHorizontal) {
        if ([SSKDiagnostics isEnabled]) {
            [SSKDiagnostics log:@"SSKMetalParticlePass: failed to create horizontal blur pipeline: %@", error.localizedDescription];
        }
        return NO;
    }
    self.blurPipelineVertical = [self.device newComputePipelineStateWithFunction:vert error:&error];
    if (!self.blurPipelineVertical) {
        if ([SSKDiagnostics isEnabled]) {
            [SSKDiagnostics log:@"SSKMetalParticlePass: failed to create vertical blur pipeline: %@", error.localizedDescription];
        }
        return NO;
    }
    return YES;
}

- (void)ensureInstanceCapacity:(NSUInteger)count {
    if (count <= self.instanceCapacity) {
        return;
    }
    NSUInteger newCapacity = MAX(count, MAX((NSUInteger)128, self.instanceCapacity * 2));
    self.instanceBuffer = [self.device newBufferWithLength:newCapacity * sizeof(SSKMetalInstanceData)
                                                   options:MTLResourceStorageModeShared];
    self.instanceCapacity = newCapacity;
}

- (id<MTLTexture>)ensureBlurTexturesForTexture:(id<MTLTexture>)texture {
    if (!texture) {
        return nil;
    }
    CGSize size = CGSizeMake(texture.width, texture.height);
    if (self.blurIntermediateTexture && CGSizeEqualToSize(size, self.blurTextureSize)) {
        return self.blurIntermediateTexture;
    }

    MTLTextureDescriptor *descriptor = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:texture.pixelFormat
                                                                                          width:texture.width
                                                                                         height:texture.height
                                                                                      mipmapped:NO];
    descriptor.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead | MTLTextureUsageShaderWrite;
#if TARGET_OS_OSX
    descriptor.storageMode = MTLStorageModePrivate;
#endif
    descriptor.resourceOptions = MTLResourceStorageModePrivate;

    self.blurIntermediateTexture = [self.device newTextureWithDescriptor:descriptor];
    self.blurScratchTexture = [self.device newTextureWithDescriptor:descriptor];
    self.blurTextureSize = size;
    return self.blurIntermediateTexture;
}

- (void)applyGaussianBlurWithCommandBuffer:(id<MTLCommandBuffer>)commandBuffer
                              sourceTexture:(id<MTLTexture>)sourceTexture
                         destinationTexture:(id<MTLTexture>)destinationTexture {
    if (!commandBuffer || !sourceTexture || !destinationTexture ||
        !self.blurPipelineHorizontal || !self.blurPipelineVertical ||
        !self.blurScratchTexture) {
        return;
    }

    float sigma = MAX(0.5f, (float)self.blurRadius);
    MTLSize threadsPerGroup = MTLSizeMake(16, 16, 1);
    MTLSize threadGroups = MTLSizeMake((self.blurScratchTexture.width + threadsPerGroup.width - 1) / threadsPerGroup.width,
                                       (self.blurScratchTexture.height + threadsPerGroup.height - 1) / threadsPerGroup.height,
                                       1);

    id<MTLComputeCommandEncoder> encoder = [commandBuffer computeCommandEncoder];
    if (!encoder) { return; }
    [encoder setComputePipelineState:self.blurPipelineHorizontal];
    [encoder setTexture:sourceTexture atIndex:0];
    [encoder setTexture:self.blurScratchTexture atIndex:1];
    [encoder setBytes:&sigma length:sizeof(float) atIndex:0];
    [encoder dispatchThreadgroups:threadGroups threadsPerThreadgroup:threadsPerGroup];
    [encoder endEncoding];

    threadGroups = MTLSizeMake((destinationTexture.width + threadsPerGroup.width - 1) / threadsPerGroup.width,
                               (destinationTexture.height + threadsPerGroup.height - 1) / threadsPerGroup.height,
                               1);
    encoder = [commandBuffer computeCommandEncoder];
    if (!encoder) { return; }
    [encoder setComputePipelineState:self.blurPipelineVertical];
    [encoder setTexture:self.blurScratchTexture atIndex:0];
    [encoder setTexture:destinationTexture atIndex:1];
    [encoder setBytes:&sigma length:sizeof(float) atIndex:0];
    [encoder dispatchThreadgroups:threadGroups threadsPerThreadgroup:threadsPerGroup];
    [encoder endEncoding];
}

@end
