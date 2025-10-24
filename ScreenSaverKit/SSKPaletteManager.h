#import <AppKit/AppKit.h>

#import "SSKColorPalette.h"

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSUInteger, SSKPaletteInterpolationMode) {
    /// Loops smoothly from the last colour back to the first.
    SSKPaletteInterpolationModeLoop,
    /// Clamps progress to the end of the palette.
    SSKPaletteInterpolationModeClamp
};

/// Registry of colour palettes associated with saver modules.
@interface SSKPaletteManager : NSObject

/// Shared singleton manager.
+ (instancetype)sharedManager;

/// Registers palettes for a given module identifier (usually your saver preference domain).
- (void)registerPalettes:(NSArray<SSKColorPalette *> *)palettes
              forModule:(NSString *)moduleIdentifier;

/// Returns all palettes associated with the module. Empty array if none.
- (NSArray<SSKColorPalette *> *)palettesForModule:(NSString *)moduleIdentifier;

/// Looks up a palette by identifier within a module.
- (nullable SSKColorPalette *)paletteWithIdentifier:(NSString *)identifier
                                            module:(NSString *)moduleIdentifier;

/// Returns an interpolated colour at `progress` for the given palette.
- (NSColor *)colorForPalette:(SSKColorPalette *)palette
                    progress:(CGFloat)progress
            interpolationMode:(SSKPaletteInterpolationMode)mode;

@end

NS_ASSUME_NONNULL_END
