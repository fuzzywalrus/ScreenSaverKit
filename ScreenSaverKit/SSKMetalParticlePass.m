#import "SSKMetalParticlePass.h"

#import <simd/simd.h>
#import <TargetConditionals.h>
#import <AppKit/AppKit.h>

#import "SSKDiagnostics.h"

// userScalar mode thresholds — must match constants in SSKParticleShaders.metal buildInstanceData kernel.
// Values > kSSKUserScalarDirectMultiplierThreshold encode a direct length multiplier (no z-depth).
// Values in [kSSKUserScalarZDepthMin, kSSKUserScalarZDepthMax] encode z-depth factor.
static const float kSSKUserScalarDirectMultiplierThreshold = 10.0f;
static const float kSSKUserScalarZDepthMin = 0.1f;
static const float kSSKUserScalarZDepthMax = 1.0f;
static const float kSSKDefaultLengthMultiplier = 8.0f;

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
@property (nonatomic, strong) id<MTLBuffer> quadVertexBuffer;
@property (nonatomic, strong) id<MTLBuffer> instanceBuffer;
@property (nonatomic) NSUInteger instanceCapacity;

// Indirect rendering resources
@property (nonatomic, strong) id<MTLComputePipelineState> buildInstancePipeline;
@property (nonatomic, strong) id<MTLBuffer> indirectArgsBuffer;
@property (nonatomic, strong) id<MTLBuffer> instanceCounterBuffer;
@property (nonatomic) BOOL supportsIndirectRendering;
@end

@implementation SSKMetalParticlePass

- (instancetype)init {
    if ((self = [super init])) {
        _lengthMultiplier = 8.0; // Default value
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
    self.library = library;
    BOOL success = [self buildQuadBuffer] && [self buildRenderPipelines];
    if (success) {
        [self setupIndirectRendering];
    }
    return success;
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
        
        // Calculate length from userScalar (see mode constants above)
        float userScalar = (float)particle.userScalar;
        float lengthMultiplier = kSSKDefaultLengthMultiplier;
        float zDepth = 1.0f;

        if (userScalar > kSSKUserScalarDirectMultiplierThreshold) {
            lengthMultiplier = userScalar - kSSKUserScalarDirectMultiplierThreshold;
            data.length = width * lengthMultiplier;
        } else if (userScalar >= kSSKUserScalarZDepthMin && userScalar <= kSSKUserScalarZDepthMax) {
            zDepth = userScalar;
            lengthMultiplier = (float)self.lengthMultiplier;
            data.length = width * lengthMultiplier * zDepth;
        } else {
            data.length = width * lengthMultiplier;
        }

        data.color = [particle metalColorVector];
        float softness = (userScalar > kSSKUserScalarDirectMultiplierThreshold || userScalar < kSSKUserScalarZDepthMin) ? userScalar : 0.0f;
        if (!isfinite(softness) || softness < 0.0f) {
            softness = 0.0f;
        }
        data.softness = softness;
        instances[index++] = data;
    }

    MTLRenderPassDescriptor *descriptor = [MTLRenderPassDescriptor renderPassDescriptor];
    descriptor.colorAttachments[0].texture = renderTarget;
    descriptor.colorAttachments[0].storeAction = MTLStoreActionStore;
    descriptor.colorAttachments[0].clearColor = clearColor;
    descriptor.colorAttachments[0].loadAction = loadAction;

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

    return YES;
}

- (BOOL)encodeParticlesIndirect:(id<MTLBuffer>)particleBuffer
                       capacity:(NSUInteger)capacity
                      blendMode:(SSKParticleBlendMode)blendMode
                   viewportSize:(CGSize)viewportSize
                  commandBuffer:(id<MTLCommandBuffer>)commandBuffer
                   renderTarget:(id<MTLTexture>)renderTarget
                     loadAction:(MTLLoadAction)loadAction
                     clearColor:(MTLClearColor)clearColor {
    if (!commandBuffer || !renderTarget || !particleBuffer) {
        return NO;
    }

    // Fallback to CPU path if indirect rendering not supported
    if (!self.supportsIndirectRendering) {
        return NO;
    }

    // Ensure instance buffer has enough capacity
    [self ensureInstanceCapacity:capacity];
    if (!self.instanceBuffer) {
        return NO;
    }

    // Reset the instance counter to 0
    uint32_t zero = 0;
    memcpy(self.instanceCounterBuffer.contents, &zero, sizeof(uint32_t));

    // Dispatch compute shader to build instance data
    id<MTLComputeCommandEncoder> computeEncoder = [commandBuffer computeCommandEncoder];
    if (!computeEncoder) {
        return NO;
    }

    [computeEncoder setComputePipelineState:self.buildInstancePipeline];
    [computeEncoder setBuffer:particleBuffer offset:0 atIndex:0];
    [computeEncoder setBuffer:self.instanceBuffer offset:0 atIndex:1];
    [computeEncoder setBuffer:self.instanceCounterBuffer offset:0 atIndex:2];
    [computeEncoder setBytes:&capacity length:sizeof(uint32_t) atIndex:3];

    // Dispatch with 256 threads per threadgroup
    NSUInteger threadGroupSize = 256;
    NSUInteger threadGroups = (capacity + threadGroupSize - 1) / threadGroupSize;

    [computeEncoder dispatchThreadgroups:MTLSizeMake(threadGroups, 1, 1)
                   threadsPerThreadgroup:MTLSizeMake(threadGroupSize, 1, 1)];
    [computeEncoder endEncoding];

    // Copy instance counter to indirect args buffer
    id<MTLBlitCommandEncoder> blitEncoder = [commandBuffer blitCommandEncoder];
    if (!blitEncoder) {
        return NO;
    }

    // Copy counter (instance count) to indirectArgsBuffer at offset 4 (instanceCount field)
    [blitEncoder copyFromBuffer:self.instanceCounterBuffer
                   sourceOffset:0
                       toBuffer:self.indirectArgsBuffer
              destinationOffset:4  // Offset of instanceCount in MTLDrawPrimitivesIndirectArguments
                           size:sizeof(uint32_t)];
    [blitEncoder endEncoding];

    // Render using indirect draw
    MTLRenderPassDescriptor *descriptor = [MTLRenderPassDescriptor renderPassDescriptor];
    descriptor.colorAttachments[0].texture = renderTarget;
    descriptor.colorAttachments[0].storeAction = MTLStoreActionStore;
    descriptor.colorAttachments[0].clearColor = clearColor;
    descriptor.colorAttachments[0].loadAction = loadAction;

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

    // Indirect draw using the populated args buffer
    [encoder drawPrimitives:MTLPrimitiveTypeTriangleStrip
             indirectBuffer:self.indirectArgsBuffer
       indirectBufferOffset:0];

    [encoder endEncoding];

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

    descriptor.colorAttachments[0].sourceRGBBlendFactor = MTLBlendFactorSourceAlpha;
    descriptor.colorAttachments[0].destinationRGBBlendFactor = MTLBlendFactorOneMinusSourceAlpha;
    descriptor.colorAttachments[0].sourceAlphaBlendFactor = MTLBlendFactorSourceAlpha;
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

- (void)ensureInstanceCapacity:(NSUInteger)count {
    if (count <= self.instanceCapacity) {
        return;
    }
    NSUInteger newCapacity = MAX(count, MAX((NSUInteger)128, self.instanceCapacity * 2));
    self.instanceBuffer = [self.device newBufferWithLength:newCapacity * sizeof(SSKMetalInstanceData)
                                                   options:MTLResourceStorageModeShared];
    self.instanceCapacity = newCapacity;
}

- (void)setupIndirectRendering {
    // Attempt to create the buildInstanceData compute pipeline
    NSError *error = nil;
    id<MTLFunction> buildInstanceFunc = [self.library newFunctionWithName:@"buildInstanceData"];
    if (!buildInstanceFunc) {
        if ([SSKDiagnostics isEnabled]) {
            [SSKDiagnostics log:@"SSKMetalParticlePass: buildInstanceData function not found, indirect rendering disabled."];
        }
        self.supportsIndirectRendering = NO;
        return;
    }

    self.buildInstancePipeline = [self.device newComputePipelineStateWithFunction:buildInstanceFunc error:&error];
    if (!self.buildInstancePipeline) {
        if ([SSKDiagnostics isEnabled]) {
            [SSKDiagnostics log:@"SSKMetalParticlePass: failed to create compute pipeline: %@", error.localizedDescription];
        }
        self.supportsIndirectRendering = NO;
        return;
    }

    // Create indirect arguments buffer (MTLDrawPrimitivesIndirectArguments)
    // Structure: { uint32_t vertexCount, uint32_t instanceCount, uint32_t vertexStart, uint32_t baseInstance }
    typedef struct {
        uint32_t vertexCount;
        uint32_t instanceCount;
        uint32_t vertexStart;
        uint32_t baseInstance;
    } MTLDrawPrimitivesIndirectArguments;

    MTLDrawPrimitivesIndirectArguments indirectArgs = {
        .vertexCount = 4,      // Triangle strip quad
        .instanceCount = 0,    // Will be filled by GPU
        .vertexStart = 0,
        .baseInstance = 0
    };

    self.indirectArgsBuffer = [self.device newBufferWithBytes:&indirectArgs
                                                       length:sizeof(MTLDrawPrimitivesIndirectArguments)
                                                      options:MTLResourceStorageModeShared];
    if (!self.indirectArgsBuffer) {
        if ([SSKDiagnostics isEnabled]) {
            [SSKDiagnostics log:@"SSKMetalParticlePass: failed to create indirect args buffer."];
        }
        self.supportsIndirectRendering = NO;
        return;
    }

    // Create instance counter buffer (atomic uint)
    uint32_t zero = 0;
    self.instanceCounterBuffer = [self.device newBufferWithBytes:&zero
                                                          length:sizeof(uint32_t)
                                                         options:MTLResourceStorageModeShared];
    if (!self.instanceCounterBuffer) {
        if ([SSKDiagnostics isEnabled]) {
            [SSKDiagnostics log:@"SSKMetalParticlePass: failed to create instance counter buffer."];
        }
        self.supportsIndirectRendering = NO;
        return;
    }

    self.supportsIndirectRendering = YES;
    if ([SSKDiagnostics isEnabled]) {
        [SSKDiagnostics log:@"SSKMetalParticlePass: indirect rendering enabled."];
    }
}

@end
