#import "RibbonFlowPalettes.h"

#import "ScreenSaverKit/SSKColorPalette.h"
#import "ScreenSaverKit/SSKPaletteManager.h"

static BOOL gRibbonFlowPalettesRegistered = NO;
static NSString * const kRibbonFlowPaletteModuleIdentifier = @"RibbonFlowSaver";
static NSString * const kRibbonFlowFallbackPalette = @"aurora";

void RibbonFlowRegisterPalettes(void) {
    if (gRibbonFlowPalettesRegistered) { return; }
    gRibbonFlowPalettesRegistered = YES;

    NSArray<SSKColorPalette *> *palettes = @[
        [SSKColorPalette paletteWithIdentifier:@"aurora"
                                     displayName:@"Aurora"
                                          colors:@[
            [NSColor colorWithHue:0.58 saturation:0.55 brightness:1.00 alpha:1.0],
            [NSColor colorWithHue:0.78 saturation:0.65 brightness:1.00 alpha:1.0],
            [NSColor colorWithHue:0.92 saturation:0.75 brightness:1.00 alpha:1.0],
            [NSColor colorWithHue:0.08 saturation:0.80 brightness:1.00 alpha:1.0]
        ]],
        [SSKColorPalette paletteWithIdentifier:@"oceanic"
                                     displayName:@"Oceanic"
                                          colors:@[
            [NSColor colorWithHue:0.50 saturation:0.60 brightness:0.95 alpha:1.0],
            [NSColor colorWithHue:0.60 saturation:0.70 brightness:0.90 alpha:1.0],
            [NSColor colorWithHue:0.48 saturation:0.55 brightness:0.85 alpha:1.0],
            [NSColor colorWithHue:0.40 saturation:0.50 brightness:0.95 alpha:1.0]
        ]],
        [SSKColorPalette paletteWithIdentifier:@"embers"
                                     displayName:@"Embers"
                                          colors:@[
            [NSColor colorWithHue:0.03 saturation:0.85 brightness:1.00 alpha:1.0],
            [NSColor colorWithHue:0.08 saturation:0.70 brightness:0.95 alpha:1.0],
            [NSColor colorWithHue:0.12 saturation:0.60 brightness:0.92 alpha:1.0],
            [NSColor colorWithHue:0.98 saturation:0.65 brightness:0.95 alpha:1.0]
        ]],
        [SSKColorPalette paletteWithIdentifier:@"mono"
                                     displayName:@"Mono"
                                          colors:@[
            [NSColor colorWithCalibratedWhite:0.85 alpha:1.0],
            [NSColor colorWithCalibratedWhite:0.65 alpha:1.0],
            [NSColor colorWithCalibratedWhite:1.0 alpha:1.0]
        ]]
    ];

    [[SSKPaletteManager sharedManager] registerPalettes:palettes forModule:kRibbonFlowPaletteModuleIdentifier];
}

NSString *RibbonFlowDefaultPaletteIdentifier(void) {
    return kRibbonFlowFallbackPalette;
}

NSString *RibbonFlowPaletteModuleIdentifier(void) {
    return kRibbonFlowPaletteModuleIdentifier;
}
