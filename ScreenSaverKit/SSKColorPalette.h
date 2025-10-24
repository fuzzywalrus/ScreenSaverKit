#import <AppKit/AppKit.h>

NS_ASSUME_NONNULL_BEGIN

/// Simple wrapper describing a palette of NSColor instances with an identifier and display name.
@interface SSKColorPalette : NSObject

/// Unique identifier for programmatic lookups.
@property (nonatomic, copy, readonly) NSString *identifier;

/// Human friendly name that can be surfaced in UI.
@property (nonatomic, copy, readonly) NSString *displayName;

/// Ordered list of colours used when interpolating along the palette.
@property (nonatomic, copy, readonly) NSArray<NSColor *> *colors;

- (instancetype)initWithIdentifier:(NSString *)identifier
                       displayName:(NSString *)displayName
                            colors:(NSArray<NSColor *> *)colors NS_DESIGNATED_INITIALIZER;

+ (instancetype)paletteWithIdentifier:(NSString *)identifier
                          displayName:(NSString *)displayName
                               colors:(NSArray<NSColor *> *)colors;

- (instancetype)init NS_UNAVAILABLE;
+ (instancetype)new NS_UNAVAILABLE;

@end

NS_ASSUME_NONNULL_END
