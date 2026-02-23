#import "AmblePalettes.h"

#import "ScreenSaverKit/SSKColorPalette.h"
#import "ScreenSaverKit/SSKPaletteManager.h"

static BOOL gAmblePalettesRegistered = NO;
static NSString * const kAmblePaletteModuleIdentifier = @"AmbleSaver";
static NSString * const kAmbleDefaultPalette = @"original";

void AmbleRegisterPalettes(void) {
    if (gAmblePalettesRegistered) { return; }
    gAmblePalettesRegistered = YES;

    NSArray<SSKColorPalette *> *palettes = @[
        // Original: warm oranges fading to cool blues (the classic Flux look)
        [SSKColorPalette paletteWithIdentifier:@"original"
                                     displayName:@"Original"
                                          colors:@[
            [NSColor colorWithRed:0.96 green:0.55 blue:0.25 alpha:1.0],
            [NSColor colorWithRed:0.90 green:0.38 blue:0.20 alpha:1.0],
            [NSColor colorWithRed:0.60 green:0.30 blue:0.50 alpha:1.0],
            [NSColor colorWithRed:0.25 green:0.35 blue:0.70 alpha:1.0],
            [NSColor colorWithRed:0.20 green:0.50 blue:0.80 alpha:1.0]
        ]],
        // Plasma: hot pinks to electric purples to cyans
        [SSKColorPalette paletteWithIdentifier:@"plasma"
                                     displayName:@"Plasma"
                                          colors:@[
            [NSColor colorWithRed:0.95 green:0.20 blue:0.60 alpha:1.0],
            [NSColor colorWithRed:0.80 green:0.15 blue:0.80 alpha:1.0],
            [NSColor colorWithRed:0.45 green:0.20 blue:0.90 alpha:1.0],
            [NSColor colorWithRed:0.20 green:0.65 blue:0.90 alpha:1.0],
            [NSColor colorWithRed:0.30 green:0.85 blue:0.85 alpha:1.0]
        ]],
        // Poolside: aqua, teal, seafoam greens
        [SSKColorPalette paletteWithIdentifier:@"poolside"
                                     displayName:@"Poolside"
                                          colors:@[
            [NSColor colorWithRed:0.15 green:0.80 blue:0.75 alpha:1.0],
            [NSColor colorWithRed:0.20 green:0.65 blue:0.60 alpha:1.0],
            [NSColor colorWithRed:0.30 green:0.85 blue:0.65 alpha:1.0],
            [NSColor colorWithRed:0.50 green:0.90 blue:0.80 alpha:1.0],
            [NSColor colorWithRed:0.25 green:0.70 blue:0.70 alpha:1.0]
        ]],
        // Freedom: red, white, blue
        [SSKColorPalette paletteWithIdentifier:@"freedom"
                                     displayName:@"Freedom"
                                          colors:@[
            [NSColor colorWithRed:0.90 green:0.15 blue:0.20 alpha:1.0],
            [NSColor colorWithRed:0.95 green:0.85 blue:0.85 alpha:1.0],
            [NSColor colorWithRed:0.15 green:0.25 blue:0.75 alpha:1.0],
            [NSColor colorWithRed:0.85 green:0.85 blue:0.95 alpha:1.0],
            [NSColor colorWithRed:0.80 green:0.10 blue:0.15 alpha:1.0]
        ]]
    ];

    [[SSKPaletteManager sharedManager] registerPalettes:palettes forModule:kAmblePaletteModuleIdentifier];
}

NSString *AmbleDefaultPaletteIdentifier(void) {
    return kAmbleDefaultPalette;
}

NSString *AmblePaletteModuleIdentifier(void) {
    return kAmblePaletteModuleIdentifier;
}
