#import <Foundation/Foundation.h>
#import <Metal/Metal.h>

@class SSKMetalTextureCache;

NS_ASSUME_NONNULL_BEGIN

/// GPU-accelerated 2D Stable Fluids simulation (Jos Stam).
/// Manages velocity/pressure textures and dispatches compute kernels.
@interface AmbleFluidSimulation : NSObject

- (nullable instancetype)initWithDevice:(id<MTLDevice>)device
                           textureCache:(SSKMetalTextureCache *)cache
                                 bundle:(NSBundle *)bundle NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;

/// Encode a full simulation step (advect → diffuse → noise → project → fade).
- (void)encodeToCommandBuffer:(id<MTLCommandBuffer>)cmdBuf;

/// Recreate textures for a new grid size. Maintains aspect ratio.
- (void)resizeGrid:(CGSize)gridSize;

/// Current velocity texture (RG32Float). Read by the line renderer.
@property (nonatomic, strong, readonly) id<MTLTexture> velocityTexture;

/// Current grid dimensions.
@property (nonatomic, readonly) CGSize gridSize;

/// Viscosity coefficient (default 5.0). Higher = more diffusion.
@property (nonatomic) float viscosity;

/// Noise force multiplier (default 0.45).
@property (nonatomic) float noiseMultiplier;

/// Velocity dissipation per step (default 0.998). Lower = faster fade.
@property (nonatomic) float dissipation;

/// Number of Jacobi iterations for diffusion (default 3).
@property (nonatomic) NSUInteger diffuseIterations;

/// Number of Jacobi iterations for pressure solve (default 19).
@property (nonatomic) NSUInteger pressureIterations;

@end

NS_ASSUME_NONNULL_END
