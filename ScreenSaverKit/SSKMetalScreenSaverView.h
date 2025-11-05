#import "SSKScreenSaverView.h"

@class SSKMetalRenderer;
@class CAMetalLayer;

NS_ASSUME_NONNULL_BEGIN

/// Base class that wires up a `CAMetalLayer` and `SSKMetalRenderer`, allowing
/// saver subclasses to focus on GPU rendering while keeping the CPU fallback
/// path available.
@interface SSKMetalScreenSaverView : SSKScreenSaverView

/// Called once the renderer has been constructed. Subclasses can override to
/// configure pipelines or resources (call `super` first).
- (void)setupMetalRenderer:(SSKMetalRenderer *)renderer;

/// Override to encode drawing commands for the current frame. The default
/// implementation clears the drawable only.
- (void)renderMetalFrame:(SSKMetalRenderer *)renderer
               deltaTime:(NSTimeInterval)dt;

/// Override to render the CPU fallback path. The default implementation just
/// triggers a layer redraw using `setNeedsDisplay:YES`.
- (void)renderCPUFrameWithDeltaTime:(NSTimeInterval)dt;

/// Allows subclasses or callers to opt out of the Metal pipeline temporarily.
@property (nonatomic) BOOL useMetalPipeline;

/// Indicates whether Metal initialisation succeeded.
@property (nonatomic, readonly, getter=isMetalAvailable) BOOL metalAvailable;

/// Renderer associated with the view (nil when Metal could not be initialised).
@property (nonatomic, strong, readonly, nullable) SSKMetalRenderer *metalRenderer;

/// Metal layer backing the view when Metal is available.
@property (nonatomic, strong, readonly, nullable) CAMetalLayer *metalLayer;

@end

NS_ASSUME_NONNULL_END
