#import "AmbleFluidSimulation.h"

#import <simd/simd.h>

#import "ScreenSaverKit/SSKShaderLoader.h"
#import "ScreenSaverKit/SSKMetalTextureCache.h"

// Must match FluidUniforms in AmbleFluidShaders.metal
typedef struct {
    simd_float2 gridSize;
    simd_float2 inverseGridSize;
    float dt;
    float viscosity;
    float noiseMultiplier;
    float noiseTime;
    simd_float2 noiseScales[3];
    float dissipation;
} AmbleFluidUniforms;

@interface AmbleFluidSimulation () {
    float _elapsedTime;
}

@property (nonatomic, strong) id<MTLDevice> device;
@property (nonatomic, weak) SSKMetalTextureCache *textureCache;

// Textures (persistent across frames — not pooled)
@property (nonatomic, strong) id<MTLTexture> velocityA;
@property (nonatomic, strong) id<MTLTexture> velocityB;
@property (nonatomic, strong) id<MTLTexture> pressureA;
@property (nonatomic, strong) id<MTLTexture> pressureB;
@property (nonatomic, strong) id<MTLTexture> divergenceTex;

// Pipeline states
@property (nonatomic, strong) id<MTLComputePipelineState> advectPipeline;
@property (nonatomic, strong) id<MTLComputePipelineState> diffusePipeline;
@property (nonatomic, strong) id<MTLComputePipelineState> addNoisePipeline;
@property (nonatomic, strong) id<MTLComputePipelineState> divergencePipeline;
@property (nonatomic, strong) id<MTLComputePipelineState> pressureSolvePipeline;
@property (nonatomic, strong) id<MTLComputePipelineState> subtractGradientPipeline;
@property (nonatomic, strong) id<MTLComputePipelineState> fadeVelocityPipeline;

// Tracks which velocity texture is "current" after ping-pong
@property (nonatomic) BOOL velocityAIsCurrent;
@property (nonatomic) BOOL pressureAIsCurrent;

@end

@implementation AmbleFluidSimulation

- (nullable instancetype)initWithDevice:(id<MTLDevice>)device
                           textureCache:(SSKMetalTextureCache *)cache
                                 bundle:(NSBundle *)bundle {
    if ((self = [super init])) {
        _device = device;
        _textureCache = cache;
        _viscosity = 5.0f;
        _noiseMultiplier = 0.45f;
        _dissipation = 0.998f;
        _diffuseIterations = 3;
        _pressureIterations = 19;
        _velocityAIsCurrent = YES;
        _pressureAIsCurrent = YES;
        _elapsedTime = 0.0f;

        id<MTLLibrary> library = [SSKShaderLoader loadLibraryNamed:@"AmbleFluidShaders"
                                                            device:device
                                                            bundle:bundle];
        if (!library) {
            NSLog(@"AmbleFluidSimulation: Failed to load AmbleFluidShaders library");
            return nil;
        }

        NSError *error = nil;
        if (![self createPipelinesFromLibrary:library error:&error]) {
            NSLog(@"AmbleFluidSimulation: Failed to create pipelines: %@", error);
            return nil;
        }

        // Default grid: 256x256
        [self resizeGrid:CGSizeMake(256, 256)];
    }
    return self;
}

- (BOOL)createPipelinesFromLibrary:(id<MTLLibrary>)library error:(NSError **)error {
    NSArray *names = @[@"advect", @"diffuse", @"addNoise", @"computeDivergence",
                       @"pressureSolve", @"subtractGradient", @"fadeVelocity"];
    NSMutableArray *pipelines = [NSMutableArray arrayWithCapacity:names.count];

    for (NSString *name in names) {
        id<MTLFunction> fn = [library newFunctionWithName:name];
        if (!fn) {
            NSLog(@"AmbleFluidSimulation: Missing kernel function '%@'", name);
            return NO;
        }
        id<MTLComputePipelineState> pso = [self.device newComputePipelineStateWithFunction:fn error:error];
        if (!pso) return NO;
        [pipelines addObject:pso];
    }

    self.advectPipeline = pipelines[0];
    self.diffusePipeline = pipelines[1];
    self.addNoisePipeline = pipelines[2];
    self.divergencePipeline = pipelines[3];
    self.pressureSolvePipeline = pipelines[4];
    self.subtractGradientPipeline = pipelines[5];
    self.fadeVelocityPipeline = pipelines[6];
    return YES;
}

- (void)resizeGrid:(CGSize)gridSize {
    NSUInteger w = (NSUInteger)gridSize.width;
    NSUInteger h = (NSUInteger)gridSize.height;
    if (w == 0 || h == 0) return;

    // Check if already the right size
    if (self.velocityA && self.velocityA.width == w && self.velocityA.height == h) return;

    _gridSize = gridSize;

    // Use Shared storage so we can zero-initialize with replaceRegion
    MTLStorageMode storageMode = MTLStorageModeShared;

    // Velocity textures (RG32Float)
    MTLTextureDescriptor *velDesc = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRG32Float
                                                                                      width:w
                                                                                     height:h
                                                                                  mipmapped:NO];
    velDesc.usage = MTLTextureUsageShaderRead | MTLTextureUsageShaderWrite;
    velDesc.storageMode = storageMode;
    self.velocityA = [self.device newTextureWithDescriptor:velDesc];
    self.velocityB = [self.device newTextureWithDescriptor:velDesc];
    self.velocityA.label = @"Amble VelocityA";
    self.velocityB.label = @"Amble VelocityB";

    // Pressure textures (R32Float)
    MTLTextureDescriptor *presDesc = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatR32Float
                                                                                       width:w
                                                                                      height:h
                                                                                   mipmapped:NO];
    presDesc.usage = MTLTextureUsageShaderRead | MTLTextureUsageShaderWrite;
    presDesc.storageMode = storageMode;
    self.pressureA = [self.device newTextureWithDescriptor:presDesc];
    self.pressureB = [self.device newTextureWithDescriptor:presDesc];
    self.pressureA.label = @"Amble PressureA";
    self.pressureB.label = @"Amble PressureB";

    // Divergence texture (R32Float)
    MTLTextureDescriptor *divDesc = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatR32Float
                                                                                      width:w
                                                                                     height:h
                                                                                   mipmapped:NO];
    divDesc.usage = MTLTextureUsageShaderRead | MTLTextureUsageShaderWrite;
    divDesc.storageMode = storageMode;
    self.divergenceTex = [self.device newTextureWithDescriptor:divDesc];
    self.divergenceTex.label = @"Amble Divergence";

    self.velocityAIsCurrent = YES;
    self.pressureAIsCurrent = YES;

    // Zero-initialize all textures
    [self clearTexture:self.velocityA bytesPerPixel:8]; // RG32Float = 8 bytes
    [self clearTexture:self.velocityB bytesPerPixel:8];
    [self clearTexture:self.pressureA bytesPerPixel:4]; // R32Float = 4 bytes
    [self clearTexture:self.pressureB bytesPerPixel:4];
    [self clearTexture:self.divergenceTex bytesPerPixel:4];
}

- (void)clearTexture:(id<MTLTexture>)texture bytesPerPixel:(NSUInteger)bpp {
    NSUInteger w = texture.width;
    NSUInteger h = texture.height;
    NSUInteger bytesPerRow = w * bpp;
    NSUInteger totalBytes = bytesPerRow * h;
    void *zeros = calloc(1, totalBytes);
    if (zeros) {
        [texture replaceRegion:MTLRegionMake2D(0, 0, w, h)
                   mipmapLevel:0
                     withBytes:zeros
                   bytesPerRow:bytesPerRow];
        free(zeros);
    }
}

- (id<MTLTexture>)velocityTexture {
    return self.velocityAIsCurrent ? self.velocityA : self.velocityB;
}

- (void)encodeToCommandBuffer:(id<MTLCommandBuffer>)cmdBuf {
    if (!self.velocityA || !cmdBuf) return;

    NSUInteger w = (NSUInteger)_gridSize.width;
    NSUInteger h = (NSUInteger)_gridSize.height;

    // Fixed timestep for stability
    float dt = 1.0f / 60.0f;
    _elapsedTime += dt;

    AmbleFluidUniforms uniforms;
    uniforms.gridSize = simd_make_float2((float)w, (float)h);
    uniforms.inverseGridSize = simd_make_float2(1.0f / (float)w, 1.0f / (float)h);
    uniforms.dt = dt;
    uniforms.viscosity = self.viscosity;
    uniforms.noiseMultiplier = self.noiseMultiplier;
    uniforms.noiseTime = _elapsedTime;
    uniforms.noiseScales[0] = simd_make_float2(2.8f, 2.8f);
    uniforms.noiseScales[1] = simd_make_float2(15.0f, 15.0f);
    uniforms.noiseScales[2] = simd_make_float2(30.0f, 30.0f);
    uniforms.dissipation = self.dissipation;

    MTLSize threadGroupSize = MTLSizeMake(16, 16, 1);
    MTLSize gridDims = MTLSizeMake((w + 15) / 16, (h + 15) / 16, 1);

    id<MTLTexture> velCur = self.velocityAIsCurrent ? self.velocityA : self.velocityB;
    id<MTLTexture> velAlt = self.velocityAIsCurrent ? self.velocityB : self.velocityA;

    // 1. Advection: velCur → velAlt
    {
        id<MTLComputeCommandEncoder> enc = [cmdBuf computeCommandEncoder];
        enc.label = @"Amble Advect";
        [enc setComputePipelineState:self.advectPipeline];
        [enc setTexture:velCur atIndex:0];
        [enc setTexture:velAlt atIndex:1];
        [enc setBytes:&uniforms length:sizeof(uniforms) atIndex:0];
        [enc dispatchThreadgroups:gridDims threadsPerThreadgroup:threadGroupSize];
        [enc endEncoding];
    }
    // After advection: velAlt is current
    id<MTLTexture> cur = velAlt;
    id<MTLTexture> alt = velCur;

    // 2. Diffusion: N iterations ping-pong
    for (NSUInteger i = 0; i < self.diffuseIterations; i++) {
        id<MTLComputeCommandEncoder> enc = [cmdBuf computeCommandEncoder];
        enc.label = @"Amble Diffuse";
        [enc setComputePipelineState:self.diffusePipeline];
        [enc setTexture:cur atIndex:0];
        [enc setTexture:alt atIndex:1];
        [enc setBytes:&uniforms length:sizeof(uniforms) atIndex:0];
        [enc dispatchThreadgroups:gridDims threadsPerThreadgroup:threadGroupSize];
        [enc endEncoding];

        // Swap
        id<MTLTexture> tmp = cur;
        cur = alt;
        alt = tmp;
    }

    // 3. Noise injection: cur → alt
    {
        id<MTLComputeCommandEncoder> enc = [cmdBuf computeCommandEncoder];
        enc.label = @"Amble Noise";
        [enc setComputePipelineState:self.addNoisePipeline];
        [enc setTexture:cur atIndex:0];
        [enc setTexture:alt atIndex:1];
        [enc setBytes:&uniforms length:sizeof(uniforms) atIndex:0];
        [enc dispatchThreadgroups:gridDims threadsPerThreadgroup:threadGroupSize];
        [enc endEncoding];
    }
    // Swap after noise
    {
        id<MTLTexture> tmp = cur;
        cur = alt;
        alt = tmp;
    }

    // 4. Compute divergence: cur → divergenceTex
    {
        id<MTLComputeCommandEncoder> enc = [cmdBuf computeCommandEncoder];
        enc.label = @"Amble Divergence";
        [enc setComputePipelineState:self.divergencePipeline];
        [enc setTexture:cur atIndex:0];
        [enc setTexture:self.divergenceTex atIndex:1];
        [enc setBytes:&uniforms length:sizeof(uniforms) atIndex:0];
        [enc dispatchThreadgroups:gridDims threadsPerThreadgroup:threadGroupSize];
        [enc endEncoding];
    }

    // 5. Pressure solve: N iterations ping-pong
    id<MTLTexture> presCur = self.pressureAIsCurrent ? self.pressureA : self.pressureB;
    id<MTLTexture> presAlt = self.pressureAIsCurrent ? self.pressureB : self.pressureA;

    for (NSUInteger i = 0; i < self.pressureIterations; i++) {
        id<MTLComputeCommandEncoder> enc = [cmdBuf computeCommandEncoder];
        enc.label = @"Amble Pressure";
        [enc setComputePipelineState:self.pressureSolvePipeline];
        [enc setTexture:presCur atIndex:0];
        [enc setTexture:presAlt atIndex:1];
        [enc setTexture:self.divergenceTex atIndex:2];
        [enc setBytes:&uniforms length:sizeof(uniforms) atIndex:0];
        [enc dispatchThreadgroups:gridDims threadsPerThreadgroup:threadGroupSize];
        [enc endEncoding];

        id<MTLTexture> tmp = presCur;
        presCur = presAlt;
        presAlt = tmp;
    }
    // presCur is the final pressure

    // 6. Subtract gradient: cur velocity - grad(presCur) → alt velocity
    {
        id<MTLComputeCommandEncoder> enc = [cmdBuf computeCommandEncoder];
        enc.label = @"Amble Gradient";
        [enc setComputePipelineState:self.subtractGradientPipeline];
        [enc setTexture:cur atIndex:0];
        [enc setTexture:alt atIndex:1];
        [enc setTexture:presCur atIndex:2];
        [enc setBytes:&uniforms length:sizeof(uniforms) atIndex:0];
        [enc dispatchThreadgroups:gridDims threadsPerThreadgroup:threadGroupSize];
        [enc endEncoding];
    }
    // After subtractGradient: result is in alt
    id<MTLTexture> tmp2 = cur;
    cur = alt;
    alt = tmp2;

    // 7. Fade: cur → the other texture
    id<MTLTexture> fadeDst = (cur == self.velocityA) ? self.velocityB : self.velocityA;
    {
        id<MTLComputeCommandEncoder> enc = [cmdBuf computeCommandEncoder];
        enc.label = @"Amble Fade";
        [enc setComputePipelineState:self.fadeVelocityPipeline];
        [enc setTexture:cur atIndex:0];
        [enc setTexture:fadeDst atIndex:1];
        [enc setBytes:&uniforms length:sizeof(uniforms) atIndex:0];
        [enc dispatchThreadgroups:gridDims threadsPerThreadgroup:threadGroupSize];
        [enc endEncoding];
    }

    // Update tracking: fadeDst is now the current velocity
    self.velocityAIsCurrent = (fadeDst == self.velocityA);

    // Update pressure tracking
    self.pressureAIsCurrent = (presCur == self.pressureA);
}

@end
