#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import <AppKit/AppKit.h>

@class SSKMetalTextureCache;

NS_ASSUME_NONNULL_BEGIN

/// Renders a grid of oriented lines that visualize a 2D velocity field.
/// Each line's direction and length are determined by sampling the velocity texture.
@interface AmbleLineRenderer : NSObject

- (nullable instancetype)initWithDevice:(id<MTLDevice>)device
                           textureCache:(SSKMetalTextureCache *)cache
                                 bundle:(NSBundle *)bundle NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;

/// Encode line rendering into the command buffer, targeting the supplied texture.
- (void)encodeToCommandBuffer:(id<MTLCommandBuffer>)cmdBuf
                 renderTarget:(id<MTLTexture>)target
             velocityTexture:(id<MTLTexture>)velocityTex
                   clearColor:(MTLClearColor)clearColor;

/// Recalculate grid dimensions for the given screen size.
- (void)updateGridForScreenSize:(CGSize)screenSize;

/// Pixels between grid points (default 15.0).
@property (nonatomic) float gridSpacing;

/// Base half-length of each line in pixels (default 8.0).
@property (nonatomic) float lineLength;

/// Base half-width of each line in pixels (default 2.0).
@property (nonatomic) float lineWidth;

/// Line color (RGBA). Set from palette.
@property (nonatomic, strong) NSColor *lineColor;

/// Current grid dimensions (read-only, updated by updateGridForScreenSize:).
@property (nonatomic, readonly) NSUInteger gridCols;
@property (nonatomic, readonly) NSUInteger gridRows;

@end

NS_ASSUME_NONNULL_END
