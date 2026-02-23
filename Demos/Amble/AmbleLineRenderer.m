#import "AmbleLineRenderer.h"

#import <simd/simd.h>

#import "ScreenSaverKit/SSKShaderLoader.h"
#import "ScreenSaverKit/SSKMetalTextureCache.h"

// Must match LineUniforms in AmbleLineShaders.metal
typedef struct {
    simd_float2 screenSize;
    simd_float2 gridOrigin;
    float gridSpacing;
    float _pad0;              // align gridDimensions to 8 bytes (matches uint2 in Metal)
    simd_uint2 gridDimensions; // (cols, rows)
    float lineLength;
    float lineWidth;
    simd_float4 color;
} AmbleLineUniforms;

@interface AmbleLineRenderer ()

@property (nonatomic, strong) id<MTLDevice> device;
@property (nonatomic, weak) SSKMetalTextureCache *textureCache;
@property (nonatomic, strong) id<MTLRenderPipelineState> renderPipeline;
@property (nonatomic) CGSize currentScreenSize;

@end

@implementation AmbleLineRenderer

- (nullable instancetype)initWithDevice:(id<MTLDevice>)device
                           textureCache:(SSKMetalTextureCache *)cache
                                 bundle:(NSBundle *)bundle {
    if ((self = [super init])) {
        _device = device;
        _textureCache = cache;
        _gridSpacing = 15.0f;
        _lineLength = 8.0f;
        _lineWidth = 2.0f;
        _lineColor = [NSColor colorWithRed:0.95 green:0.6 blue:0.3 alpha:0.85];

        id<MTLLibrary> library = [SSKShaderLoader loadLibraryNamed:@"AmbleLineShaders"
                                                            device:device
                                                            bundle:bundle];
        if (!library) {
            NSLog(@"AmbleLineRenderer: Failed to load AmbleLineShaders library");
            return nil;
        }

        id<MTLFunction> vertexFn = [library newFunctionWithName:@"ambleLineVertex"];
        id<MTLFunction> fragmentFn = [library newFunctionWithName:@"ambleLineFragment"];
        if (!vertexFn || !fragmentFn) {
            NSLog(@"AmbleLineRenderer: Missing shader functions");
            return nil;
        }

        MTLRenderPipelineDescriptor *desc = [[MTLRenderPipelineDescriptor alloc] init];
        desc.label = @"Amble Line Pipeline";
        desc.vertexFunction = vertexFn;
        desc.fragmentFunction = fragmentFn;
        desc.colorAttachments[0].pixelFormat = MTLPixelFormatBGRA8Unorm;

        // Additive blending with premultiplied alpha
        desc.colorAttachments[0].blendingEnabled = YES;
        desc.colorAttachments[0].sourceRGBBlendFactor = MTLBlendFactorOne;
        desc.colorAttachments[0].destinationRGBBlendFactor = MTLBlendFactorOne;
        desc.colorAttachments[0].rgbBlendOperation = MTLBlendOperationAdd;
        desc.colorAttachments[0].sourceAlphaBlendFactor = MTLBlendFactorOne;
        desc.colorAttachments[0].destinationAlphaBlendFactor = MTLBlendFactorOne;
        desc.colorAttachments[0].alphaBlendOperation = MTLBlendOperationAdd;

        NSError *error = nil;
        _renderPipeline = [device newRenderPipelineStateWithDescriptor:desc error:&error];
        if (!_renderPipeline) {
            NSLog(@"AmbleLineRenderer: Failed to create pipeline: %@", error);
            return nil;
        }
    }
    return self;
}

- (void)updateGridForScreenSize:(CGSize)screenSize {
    if (screenSize.width <= 0 || screenSize.height <= 0) return;
    self.currentScreenSize = screenSize;

    _gridCols = (NSUInteger)(screenSize.width / self.gridSpacing) + 1;
    _gridRows = (NSUInteger)(screenSize.height / self.gridSpacing) + 1;
}

- (void)encodeToCommandBuffer:(id<MTLCommandBuffer>)cmdBuf
                 renderTarget:(id<MTLTexture>)target
             velocityTexture:(id<MTLTexture>)velocityTex
                   clearColor:(MTLClearColor)clearColor {
    if (!cmdBuf || !target || !velocityTex) return;
    if (self.gridCols == 0 || self.gridRows == 0) return;

    MTLRenderPassDescriptor *passDesc = [MTLRenderPassDescriptor new];
    passDesc.colorAttachments[0].texture = target;
    passDesc.colorAttachments[0].loadAction = MTLLoadActionClear;
    passDesc.colorAttachments[0].storeAction = MTLStoreActionStore;
    passDesc.colorAttachments[0].clearColor = clearColor;

    id<MTLRenderCommandEncoder> enc = [cmdBuf renderCommandEncoderWithDescriptor:passDesc];
    if (!enc) return;
    enc.label = @"Amble Lines";

    [enc setRenderPipelineState:self.renderPipeline];

    // Build uniforms
    AmbleLineUniforms uniforms;
    uniforms.screenSize = simd_make_float2((float)target.width, (float)target.height);

    // Center the grid on screen
    float totalGridW = (float)(self.gridCols - 1) * self.gridSpacing;
    float totalGridH = (float)(self.gridRows - 1) * self.gridSpacing;
    uniforms.gridOrigin = simd_make_float2(
        ((float)target.width - totalGridW) * 0.5f,
        ((float)target.height - totalGridH) * 0.5f
    );
    uniforms.gridSpacing = self.gridSpacing;
    uniforms._pad0 = 0.0f;
    uniforms.gridDimensions = simd_make_uint2((uint32_t)self.gridCols, (uint32_t)self.gridRows);
    uniforms.lineLength = self.lineLength;
    uniforms.lineWidth = self.lineWidth;

    // Convert NSColor to float4
    NSColor *srgb = [self.lineColor colorUsingColorSpace:[NSColorSpace sRGBColorSpace]];
    if (srgb) {
        CGFloat r, g, b, a;
        [srgb getRed:&r green:&g blue:&b alpha:&a];
        uniforms.color = simd_make_float4((float)r, (float)g, (float)b, (float)a);
    } else {
        uniforms.color = simd_make_float4(0.95f, 0.6f, 0.3f, 0.85f);
    }

    [enc setVertexBytes:&uniforms length:sizeof(uniforms) atIndex:0];
    [enc setVertexTexture:velocityTex atIndex:0];

    NSUInteger instanceCount = self.gridCols * self.gridRows;
    [enc drawPrimitives:MTLPrimitiveTypeTriangleStrip
            vertexStart:0
            vertexCount:4
          instanceCount:instanceCount];

    [enc endEncoding];
}

@end
