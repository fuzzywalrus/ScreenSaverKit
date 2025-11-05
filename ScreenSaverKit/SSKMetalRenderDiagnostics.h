#import <Foundation/Foundation.h>
#import <QuartzCore/QuartzCore.h>

NS_ASSUME_NONNULL_BEGIN

/// Shared helper that tracks Metal rendering statistics and exposes a reusable
/// diagnostics overlay for saver implementations. Attach it to a CAMetalLayer
/// to render a status text block, or consume the generated strings directly.
@interface SSKMetalRenderDiagnostics : NSObject

/// Attaches the diagnostics overlay to the supplied layer. Passing `nil`
/// detaches the overlay. Safe to call repeatedly when the layer changes.
- (void)attachToMetalLayer:(nullable CAMetalLayer *)layer;

/// Controls whether the overlay layer renders text. Defaults to `YES`.
@property (nonatomic) BOOL overlayEnabled;

/// Current status strings. When nil, sensible defaults are used instead.
@property (nonatomic, copy, nullable) NSString *deviceStatus;
@property (nonatomic, copy, nullable) NSString *layerStatus;
@property (nonatomic, copy, nullable) NSString *rendererStatus;
@property (nonatomic, copy, nullable) NSString *drawableStatus;

/// Metal attempt counters updated via `recordMetalAttemptWithSuccess:`.
@property (nonatomic, readonly) NSUInteger metalSuccessCount;
@property (nonatomic, readonly) NSUInteger metalFailureCount;

/// Convenience flag indicating whether the most recent Metal attempt succeeded.
@property (nonatomic, readonly) BOOL lastAttemptSucceeded;

/// Increments counters for a Metal rendering attempt. Call once per frame
/// whenever the saver attempted to render with Metal.
- (void)recordMetalAttemptWithSuccess:(BOOL)success;

/// Resets all counters and status strings to their defaults.
- (void)reset;

/// Returns the overlay lines (excluding FPS) suitable for display.
- (NSArray<NSString *> *)statusLines;

/// Updates the attached overlay layer (if any) with the supplied title and
/// additional lines (these appear after the default status lines). The FPS is
/// appended automatically.
- (void)updateOverlayWithTitle:(NSString *)title
                    extraLines:(nullable NSArray<NSString *> *)extraLines
               framesPerSecond:(double)fps;

/// Returns the full overlay string in case consumer prefers to render it
/// manually (e.g. via `SSKDiagnostics drawOverlayInView:`).
- (NSString *)overlayStringWithTitle:(NSString *)title
                          extraLines:(nullable NSArray<NSString *> *)extraLines
                     framesPerSecond:(double)fps;

@end

NS_ASSUME_NONNULL_END
