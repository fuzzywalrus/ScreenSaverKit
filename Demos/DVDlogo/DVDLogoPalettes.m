#import "DVDLogoPalettes.h"

#import "ScreenSaverKit/SSKColorPalette.h"
#import "ScreenSaverKit/SSKPaletteManager.h"

static BOOL gDVDPalettesRegistered = NO;
static NSString * const kDVDPaletteModuleIdentifier = @"RetroDVDLogo";
static NSString * const kDVDFallbackPaletteIdentifier = @"neon";

void DVDRegisterRetroPalettes(void) {
    if (gDVDPalettesRegistered) { return; }
    gDVDPalettesRegistered = YES;
    NSArray<SSKColorPalette *> *palettes = @[
        [SSKColorPalette paletteWithIdentifier:@"neon"
                                     displayName:@"Classic Neon"
                                          colors:@[
            [NSColor colorWithHue:0.60 saturation:0.75 brightness:1.00 alpha:1.0],
            [NSColor colorWithHue:0.82 saturation:0.80 brightness:1.00 alpha:1.0],
            [NSColor colorWithHue:0.13 saturation:0.85 brightness:1.00 alpha:1.0]
        ]],
        [SSKColorPalette paletteWithIdentifier:@"sunset"
                                     displayName:@"Sunset"
                                          colors:@[
            [NSColor colorWithHue:0.02 saturation:0.88 brightness:0.96 alpha:1.0],
            [NSColor colorWithHue:0.08 saturation:0.78 brightness:0.93 alpha:1.0],
            [NSColor colorWithHue:0.63 saturation:0.45 brightness:0.92 alpha:1.0]
        ]],
        [SSKColorPalette paletteWithIdentifier:@"crystal"
                                     displayName:@"Crystal"
                                          colors:@[
            [NSColor colorWithHue:0.52 saturation:0.30 brightness:1.00 alpha:1.0],
            [NSColor colorWithHue:0.54 saturation:0.55 brightness:0.95 alpha:1.0],
            [NSColor colorWithHue:0.58 saturation:0.65 brightness:0.90 alpha:1.0]
        ]],
        [SSKColorPalette paletteWithIdentifier:@"arcade"
                                     displayName:@"Arcade"
                                          colors:@[
            [NSColor colorWithHue:0.97 saturation:0.80 brightness:0.95 alpha:1.0],
            [NSColor colorWithHue:0.10 saturation:0.85 brightness:0.98 alpha:1.0],
            [NSColor colorWithHue:0.65 saturation:0.85 brightness:0.95 alpha:1.0]
        ]]
    ];

    [[SSKPaletteManager sharedManager] registerPalettes:palettes forModule:kDVDPaletteModuleIdentifier];
}

NSString *DVDDefaultPaletteIdentifier(void) {
    return kDVDFallbackPaletteIdentifier;
}

NSString *DVDPaletteModuleIdentifier(void) {
    return kDVDPaletteModuleIdentifier;
}
