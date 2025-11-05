#import "SSKMetalParticleRenderer.h"

#import <simd/simd.h>

#import "SSKParticleSystem.h"
#import "SSKDiagnostics.h"

static NSString * const kSSKMetalShaderSource =
@"#include <metal_stdlib>\n"
"using namespace metal;\n"
"struct InstanceData {\n"
"    float2 position;\n"
"    float2 direction;\n"
"    float width;\n"
"    float length;\n"
"    float4 color;\n"
"    float softness;\n"
"};\n"
"struct ParticleVertexOut {\n"
"    float4 position [[position]];\n"
"    float4 color;\n"
"    float2 quad;\n"
"    float2 extent;\n"
"    float softness;\n"
"};\n"
"vertex ParticleVertexOut particleVertex(uint vertexID [[vertex_id]],\n"
"                            uint instanceID [[instance_id]],\n"
"                            constant float2 *quadVertices [[buffer(0)]],\n"
"                            constant InstanceData *instances [[buffer(1)]],\n"
"                            constant float2 &viewport [[buffer(2)]]) {\n"
"    InstanceData data = instances[instanceID];\n"
"    float2 forward = normalize(data.direction);\n"
"    if (!isfinite(forward.x) || !isfinite(forward.y)) {\n"
"        forward = float2(1.0, 0.0);\n"
"    }\n"
"    float2 right = float2(-forward.y, forward.x);\n"
"    float2 quad = quadVertices[vertexID];\n"
"    float2 offset = right * quad.x * data.width + forward * quad.y * data.length;\n"
"    float2 world = data.position + offset;\n"
"    float2 clip = float2((world.x / viewport.x) * 2.0 - 1.0,\n"
"                         (world.y / viewport.y) * 2.0 - 1.0);\n"
"    clip.y = -clip.y;\n"
"    ParticleVertexOut out;\n"
"    out.position = float4(clip, 0.0, 1.0);\n"
"    out.color = data.color;\n"
"    out.quad = quad;\n"
"    out.extent = float2(data.length * 0.5, data.width * 0.5);\n"
"    out.softness = data.softness;\n"
"    return out;\n"
"}\n"
"fragment float4 particleFragment(ParticleVertexOut in [[stage_in]]) {\n"
"    float softness = in.softness;\n"
"    if (softness <= 0.01) {\n"
"        return in.color;\n"
"    }\n"
"    float2 extent = max(in.extent, float2(0.0001));\n"
"    float2 local = float2(in.quad.x * extent.x, in.quad.y * extent.y);\n"
"    float2 norm = float2(local.x / extent.x, local.y / extent.y);\n"
"    float dist = length(norm);\n"
"    float alpha = in.color.a * exp(-max(softness, 0.01) * dist * dist * 4.0);\n"
"    return float4(in.color.rgb, alpha);\n"
"}\n";

typedef struct {
    vector_float2 position;
    vector_float2 direction;
    float width;
    float length;
    vector_float4 color;
    float softness;
    float padding[3];
} SSKMetalInstanceData;

static NSString *SSKMetalParticleRendererLastErrorMessage = nil;

static void SSKMetalParticleRendererSetLastErrorMessage(NSString *message) {
    SSKMetalParticleRendererLastErrorMessage = [message copy];
    if (message.length > 0 && [SSKDiagnostics isEnabled]) {
        [SSKDiagnostics log:@"%@", message];
    }
    if (message.length > 0) {
        NSLog(@"%@", message);
    }
}

@interface SSKMetalParticleRenderer ()
@property (nonatomic, weak) CAMetalLayer *layer;
@property (nonatomic, strong) id<MTLDevice> device;
@property (nonatomic, strong) id<MTLCommandQueue> commandQueue;
@property (nonatomic, strong) id<MTLRenderPipelineState> alphaPipeline;
@property (nonatomic, strong) id<MTLRenderPipelineState> additivePipeline;
@property (nonatomic, strong) id<MTLBuffer> quadVertexBuffer;
@property (nonatomic, strong) id<MTLBuffer> instanceBuffer;
@property (nonatomic) NSUInteger instanceCapacity;
@end

@implementation SSKMetalParticleRenderer

- (instancetype)initWithLayer:(CAMetalLayer *)layer {
    SSKMetalParticleRendererSetLastErrorMessage(nil);
    NSParameterAssert(layer);
    if ((self = [super init])) {
        _layer = layer;
        _device = layer.device ?: MTLCreateSystemDefaultDevice();
        if (!_device) {
            SSKMetalParticleRendererSetLastErrorMessage(@"SSKMetalParticleRenderer: no Metal device available during initialisation.");
            return nil;
        }
        if (!layer.device) {
            layer.device = _device;
        }
        layer.pixelFormat = MTLPixelFormatBGRA8Unorm;
        layer.framebufferOnly = YES;
        _commandQueue = [_device newCommandQueue];
        if (!_commandQueue) {
            SSKMetalParticleRendererSetLastErrorMessage(@"SSKMetalParticleRenderer: failed to create Metal command queue.");
            return nil;
        }
        _clearColor = MTLClearColorMake(0, 0, 0, 1);
        if (![self buildPipelinesWithDevice:_device] || ![self buildQuadBuffer]) {
            return nil;
        }
    }
    return self;
}

- (BOOL)buildPipelinesWithDevice:(id<MTLDevice>)device {
    NSError *error = nil;
    id<MTLLibrary> library = [device newLibraryWithSource:kSSKMetalShaderSource
                                                  options:nil
                                                    error:&error];
    if (!library) {
        SSKMetalParticleRendererSetLastErrorMessage([NSString stringWithFormat:@"SSKMetalParticleRenderer: failed to compile Metal shaders: %@", error.localizedDescription ?: @"unknown error"]);
        NSLog(@"SSKMetalParticleRenderer: failed to compile Metal shaders: %@", error);
        return NO;
    }
    id<MTLFunction> vertexFunc = [library newFunctionWithName:@"particleVertex"];
    id<MTLFunction> fragmentFunc = [library newFunctionWithName:@"particleFragment"];
    if (!vertexFunc || !fragmentFunc) {
        SSKMetalParticleRendererSetLastErrorMessage(@"SSKMetalParticleRenderer: missing shader functions in compiled library.");
        return NO;
    }

    MTLRenderPipelineDescriptor *descriptor = [MTLRenderPipelineDescriptor new];
    descriptor.vertexFunction = vertexFunc;
    descriptor.fragmentFunction = fragmentFunc;
    descriptor.colorAttachments[0].pixelFormat = self.layer.pixelFormat;
    descriptor.colorAttachments[0].blendingEnabled = YES;
    descriptor.colorAttachments[0].rgbBlendOperation = MTLBlendOperationAdd;
    descriptor.colorAttachments[0].alphaBlendOperation = MTLBlendOperationAdd;
    descriptor.colorAttachments[0].sourceRGBBlendFactor = MTLBlendFactorOne;
    descriptor.colorAttachments[0].destinationRGBBlendFactor = MTLBlendFactorOneMinusSourceAlpha;
    descriptor.colorAttachments[0].sourceAlphaBlendFactor = MTLBlendFactorOne;
    descriptor.colorAttachments[0].destinationAlphaBlendFactor = MTLBlendFactorOneMinusSourceAlpha;

    _alphaPipeline = [device newRenderPipelineStateWithDescriptor:descriptor error:&error];
    if (!_alphaPipeline) {
        SSKMetalParticleRendererSetLastErrorMessage([NSString stringWithFormat:@"SSKMetalParticleRenderer: failed to create alpha pipeline: %@", error.localizedDescription ?: @"unknown error"]);
        NSLog(@"SSKMetalParticleRenderer: failed to create alpha pipeline: %@", error);
        return NO;
    }

    descriptor.colorAttachments[0].sourceRGBBlendFactor = MTLBlendFactorOne;
    descriptor.colorAttachments[0].destinationRGBBlendFactor = MTLBlendFactorOne;
    descriptor.colorAttachments[0].sourceAlphaBlendFactor = MTLBlendFactorOne;
    descriptor.colorAttachments[0].destinationAlphaBlendFactor = MTLBlendFactorOne;
    _additivePipeline = [device newRenderPipelineStateWithDescriptor:descriptor error:&error];
    if (!_additivePipeline) {
        SSKMetalParticleRendererSetLastErrorMessage([NSString stringWithFormat:@"SSKMetalParticleRenderer: failed to create additive pipeline: %@", error.localizedDescription ?: @"unknown error"]);
        NSLog(@"SSKMetalParticleRenderer: failed to create additive pipeline: %@", error);
        return NO;
    }
    return YES;
}

- (BOOL)buildQuadBuffer {
    static const vector_float2 quadVertices[] = {
        {-0.5f, -0.5f},
        { 0.5f, -0.5f},
        {-0.5f,  0.5f},
        { 0.5f,  0.5f}
    };
    _quadVertexBuffer = [self.device newBufferWithBytes:quadVertices
                                                 length:sizeof(quadVertices)
                                                options:MTLResourceStorageModeShared];
    _instanceCapacity = 0;
    if (!_quadVertexBuffer) {
        SSKMetalParticleRendererSetLastErrorMessage(@"SSKMetalParticleRenderer: failed to create quad vertex buffer.");
    }
    return _quadVertexBuffer != nil;
}

+ (NSString *)lastCreationErrorMessage {
    return SSKMetalParticleRendererLastErrorMessage;
}

- (void)ensureInstanceCapacity:(NSUInteger)count {
    if (count <= self.instanceCapacity) { return; }
    NSUInteger newCapacity = MAX(count, MAX((NSUInteger)128, self.instanceCapacity * 2));
    _instanceBuffer = [self.device newBufferWithLength:newCapacity * sizeof(SSKMetalInstanceData)
                                               options:MTLResourceStorageModeShared];
    self.instanceCapacity = newCapacity;
}

- (BOOL)renderParticles:(NSArray<SSKParticle *> *)particles
              blendMode:(SSKParticleBlendMode)blendMode
           viewportSize:(CGSize)viewportSize {
    if (!self.layer || !self.device || !self.commandQueue) { return NO; }

    [self ensureInstanceCapacity:particles.count];
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

    CGFloat scale = self.layer.contentsScale > 0.0 ? self.layer.contentsScale : 1.0;
    CGSize drawableSize = CGSizeMake(MAX(viewportSize.width * scale, 1.0),
                                     MAX(viewportSize.height * scale, 1.0));
    if (!CGSizeEqualToSize(self.layer.drawableSize, drawableSize)) {
        self.layer.drawableSize = drawableSize;
    }

    id<CAMetalDrawable> drawable = [self.layer nextDrawable];
    if (!drawable) { return NO; }

    MTLRenderPassDescriptor *passDescriptor = [MTLRenderPassDescriptor renderPassDescriptor];
    passDescriptor.colorAttachments[0].texture = drawable.texture;
    passDescriptor.colorAttachments[0].loadAction = MTLLoadActionClear;
    passDescriptor.colorAttachments[0].storeAction = MTLStoreActionStore;
    passDescriptor.colorAttachments[0].clearColor = self.clearColor;

    id<MTLCommandBuffer> commandBuffer = [self.commandQueue commandBuffer];
    id<MTLRenderPipelineState> pipeline = (blendMode == SSKParticleBlendModeAdditive) ? self.additivePipeline : self.alphaPipeline;
    if (!pipeline) {
        [commandBuffer commit];
        return NO;
    }

    if (index == 0) {
        [commandBuffer presentDrawable:drawable];
        [commandBuffer commit];
        return YES;
    }

    id<MTLRenderCommandEncoder> encoder = [commandBuffer renderCommandEncoderWithDescriptor:passDescriptor];
    MTLViewport viewport = {0.0, 0.0, drawableSize.width, drawableSize.height, 0.0, 1.0};
    [encoder setViewport:viewport];
    [encoder setRenderPipelineState:pipeline];
    [encoder setVertexBuffer:self.quadVertexBuffer offset:0 atIndex:0];
    [encoder setVertexBuffer:self.instanceBuffer offset:0 atIndex:1];
    vector_float2 viewportPoints = {(float)viewportSize.width, (float)viewportSize.height};
    [encoder setVertexBytes:&viewportPoints length:sizeof(vector_float2) atIndex:2];
    [encoder drawPrimitives:MTLPrimitiveTypeTriangleStrip vertexStart:0 vertexCount:4 instanceCount:index];
    [encoder endEncoding];

    [commandBuffer presentDrawable:drawable];
    [commandBuffer commit];
    return YES;
}

@end
