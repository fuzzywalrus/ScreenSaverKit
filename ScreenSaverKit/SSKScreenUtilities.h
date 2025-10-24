#import <AppKit/AppKit.h>

NS_ASSUME_NONNULL_BEGIN

/// Miscellaneous helpers for dealing with hosts, screens, and scaling.
@interface SSKScreenUtilities : NSObject

/// Returns YES when the supplied window is being hosted as a wallpaper rather
/// than a dedicated screensaver window.
+ (BOOL)isWallpaperHostWindow:(nullable NSWindow *)window;

/// Backing scale factor for the view (defaults to 1.0 if unavailable).
+ (CGFloat)backingScaleFactorForView:(NSView *)view;

/// Convenience to get the logical bounds of the active screen for a view.
+ (NSRect)screenBoundsForView:(NSView *)view;

/// Returns the view size in backing pixels (accounts for Retina scaling).
+ (CGSize)backingPixelSizeForView:(NSView *)view;

@end

NS_ASSUME_NONNULL_END
