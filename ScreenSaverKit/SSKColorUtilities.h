#import <AppKit/AppKit.h>

NS_ASSUME_NONNULL_BEGIN

/// Serializes an NSColor for storing in ScreenSaverDefaults.
FOUNDATION_EXPORT NSData *SSKSerializeColor(NSColor *color);

/// Restores an NSColor from a stored defaults value (NSData or NSColor).
FOUNDATION_EXPORT NSColor *SSKDeserializeColor(id value, NSColor *fallback);

NS_ASSUME_NONNULL_END
