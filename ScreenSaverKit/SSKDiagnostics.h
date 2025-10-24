#import <AppKit/AppKit.h>

NS_ASSUME_NONNULL_BEGIN

/// Global diagnostics utilities for conditional logging and lightweight
/// drawing overlays (FPS counters, debug text, etc).
@interface SSKDiagnostics : NSObject

+ (void)setEnabled:(BOOL)enabled;
+ (BOOL)isEnabled;

/// Writes to NSLog only when diagnostics are enabled.
+ (void)log:(NSString *)format, ... NS_FORMAT_FUNCTION(1,2);

/// Draws an informational overlay in the supplied view. Safe to call during
/// `-drawRect:`. When diagnostics are disabled this is a no-op.
+ (void)drawOverlayInView:(NSView *)view
                     text:(NSString *)text
              framesPerSecond:(double)fps;

@end

NS_ASSUME_NONNULL_END
