#import "LuminairePalettes.h"

#import "ScreenSaverKit/SSKColorPalette.h"
#import "ScreenSaverKit/SSKPaletteManager.h"

static BOOL gLuminairePalettesRegistered = NO;
static NSString * const kLuminairePaletteModuleIdentifier = @"LuminaireSaver";
static NSString * const kLuminaireDefaultPalette = @"rainbow";

void LuminaireRegisterPalettes(void) {
    if (gLuminairePalettesRegistered) { return; }
    gLuminairePalettesRegistered = YES;

    NSArray<SSKColorPalette *> *palettes = @[
        [SSKColorPalette paletteWithIdentifier:@"rainbow"
                                     displayName:@"Rainbow Cycle"
                                          colors:@[
            [NSColor colorWithHue:0.00 saturation:0.75 brightness:1.00 alpha:1.0],
            [NSColor colorWithHue:0.16 saturation:0.75 brightness:1.00 alpha:1.0],
            [NSColor colorWithHue:0.33 saturation:0.75 brightness:1.00 alpha:1.0],
            [NSColor colorWithHue:0.50 saturation:0.75 brightness:1.00 alpha:1.0],
            [NSColor colorWithHue:0.66 saturation:0.75 brightness:1.00 alpha:1.0],
            [NSColor colorWithHue:0.83 saturation:0.75 brightness:1.00 alpha:1.0]
        ]],
        [SSKColorPalette paletteWithIdentifier:@"ocean"
                                     displayName:@"Ocean"
                                          colors:@[
            [NSColor colorWithHue:0.50 saturation:0.60 brightness:0.95 alpha:1.0],
            [NSColor colorWithHue:0.55 saturation:0.70 brightness:0.90 alpha:1.0],
            [NSColor colorWithHue:0.60 saturation:0.65 brightness:0.92 alpha:1.0],
            [NSColor colorWithHue:0.48 saturation:0.55 brightness:0.95 alpha:1.0]
        ]],
        [SSKColorPalette paletteWithIdentifier:@"fire"
                                     displayName:@"Fire"
                                          colors:@[
            [NSColor colorWithHue:0.98 saturation:0.85 brightness:1.00 alpha:1.0],
            [NSColor colorWithHue:0.04 saturation:0.80 brightness:1.00 alpha:1.0],
            [NSColor colorWithHue:0.10 saturation:0.70 brightness:0.95 alpha:1.0],
            [NSColor colorWithHue:0.14 saturation:0.60 brightness:0.92 alpha:1.0]
        ]],
        [SSKColorPalette paletteWithIdentifier:@"aurora"
                                     displayName:@"Aurora"
                                          colors:@[
            [NSColor colorWithHue:0.30 saturation:0.65 brightness:0.95 alpha:1.0],
            [NSColor colorWithHue:0.45 saturation:0.60 brightness:1.00 alpha:1.0],
            [NSColor colorWithHue:0.55 saturation:0.70 brightness:0.95 alpha:1.0],
            [NSColor colorWithHue:0.75 saturation:0.65 brightness:1.00 alpha:1.0]
        ]],
        [SSKColorPalette paletteWithIdentifier:@"neon"
                                     displayName:@"Neon"
                                          colors:@[
            [NSColor colorWithHue:0.85 saturation:0.80 brightness:1.00 alpha:1.0],
            [NSColor colorWithHue:0.50 saturation:0.75 brightness:1.00 alpha:1.0],
            [NSColor colorWithHue:0.70 saturation:0.80 brightness:1.00 alpha:1.0],
            [NSColor colorWithHue:0.85 saturation:0.75 brightness:1.00 alpha:1.0]
        ]],
        [SSKColorPalette paletteWithIdentifier:@"mono"
                                     displayName:@"Monochrome"
                                          colors:@[
            [NSColor colorWithCalibratedWhite:0.85 alpha:1.0],
            [NSColor colorWithCalibratedWhite:0.65 alpha:1.0],
            [NSColor colorWithCalibratedWhite:1.0 alpha:1.0]
        ]]
    ];

    [[SSKPaletteManager sharedManager] registerPalettes:palettes forModule:kLuminairePaletteModuleIdentifier];
}

NSString *LuminaireDefaultPaletteIdentifier(void) {
    return kLuminaireDefaultPalette;
}

NSString *LuminairePaletteModuleIdentifier(void) {
    return kLuminairePaletteModuleIdentifier;
}
