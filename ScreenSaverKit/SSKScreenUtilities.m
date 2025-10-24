#import "SSKScreenUtilities.h"

#import <CoreGraphics/CoreGraphics.h>

@implementation SSKScreenUtilities

+ (BOOL)isWallpaperHostWindow:(NSWindow *)window {
    if (!window) { return NO; }
    NSInteger level = window.level;
    NSInteger desktop = CGWindowLevelForKey(kCGDesktopWindowLevelKey);
    NSInteger saver = CGWindowLevelForKey(kCGScreenSaverWindowLevelKey);
    return (level <= desktop + 1) && (level < saver);
}

+ (CGFloat)backingScaleFactorForView:(NSView *)view {
    if (!view) { return 1.0; }
    NSScreen *screen = view.window.screen ?: [NSScreen mainScreen];
    if (@available(macOS 10.7, *)) {
        return screen.backingScaleFactor;
    }
    return 1.0;
}

+ (NSRect)screenBoundsForView:(NSView *)view {
    NSScreen *screen = view.window.screen ?: [NSScreen mainScreen];
    return screen ? screen.frame : NSMakeRect(0, 0, 1024, 768);
}

+ (CGSize)backingPixelSizeForView:(NSView *)view {
    NSRect bounds = view.bounds;
    CGFloat scale = [self backingScaleFactorForView:view];
    return CGSizeMake(bounds.size.width * scale, bounds.size.height * scale);
}

@end
