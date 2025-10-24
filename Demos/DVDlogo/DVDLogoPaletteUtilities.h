#import <AppKit/AppKit.h>

NS_ASSUME_NONNULL_BEGIN

NSArray<NSDictionary<NSString *, id> *> *DVDLogoPaletteDefinitions(void);
NSArray<NSColor *> *DVDLogoColorsForIdentifier(NSString *identifier);
NSString *DVDLogoPaletteFallbackIdentifier(void);
NSColor *DVDLogoColorForProgress(NSArray<NSColor *> *colors, CGFloat progress);
NSData *DVDLogoSerializeColor(NSColor *color);
NSColor *DVDLogoColorFromPreferenceValue(id value, NSColor *fallback);
NSColor *DVDLogoFallbackSolidColor(void);

NS_ASSUME_NONNULL_END
