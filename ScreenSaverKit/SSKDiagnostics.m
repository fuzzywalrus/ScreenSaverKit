#import "SSKDiagnostics.h"

static BOOL SSKDiagnosticsEnabled = NO;

@implementation SSKDiagnostics

+ (void)setEnabled:(BOOL)enabled {
    SSKDiagnosticsEnabled = enabled;
}

+ (BOOL)isEnabled {
    return SSKDiagnosticsEnabled;
}

+ (void)log:(NSString *)format, ... {
    if (!SSKDiagnosticsEnabled || format.length == 0) { return; }
    va_list args;
    va_start(args, format);
    NSString *message = [[NSString alloc] initWithFormat:format arguments:args];
    va_end(args);
    NSLog(@"[ScreenSaverKit] %@", message);
}

+ (void)drawOverlayInView:(NSView *)view text:(NSString *)text framesPerSecond:(double)fps {
    if (!SSKDiagnosticsEnabled || !view) { return; }
    NSString *overlay = text.length ? [NSString stringWithFormat:@"%@\nFPS: %.1f", text, fps] :
    [NSString stringWithFormat:@"FPS: %.1f", fps];
    
    NSDictionary *attrs = @{
        NSFontAttributeName: [NSFont monospacedDigitSystemFontOfSize:12 weight:NSFontWeightMedium],
        NSForegroundColorAttributeName: [NSColor colorWithWhite:1 alpha:0.95]
    };
    
    NSRect bounds = view.bounds;
    NSSize size = [overlay sizeWithAttributes:attrs];
    NSRect panel = NSMakeRect(NSMinX(bounds) + 12,
                              NSMaxY(bounds) - size.height - 20,
                              size.width + 16,
                              size.height + 12);
    
    [[NSColor colorWithWhite:0 alpha:0.55] setFill];
    NSBezierPath *path = [NSBezierPath bezierPathWithRoundedRect:panel xRadius:6 yRadius:6];
    [path fill];
    
    NSPoint textOrigin = NSMakePoint(NSMinX(panel) + 8, NSMinY(panel) + 6);
    [overlay drawAtPoint:textOrigin withAttributes:attrs];
}

@end
